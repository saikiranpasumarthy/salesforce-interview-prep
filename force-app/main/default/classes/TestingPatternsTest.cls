/**
 * @description Comprehensive test class for Day 7: Apex Testing Deep Dive.
 *
 *              Covers every Salesforce test pattern needed for Senior / Architect interviews:
 *
 *              Section 1 — Pure unit tests with MockUnitOfWork (zero DML)
 *                Verifies service logic by inspecting what was registered — not what
 *                was persisted. Tests run without touching the database.
 *
 *              Section 2 — Pure unit tests with MockSelector (zero SOQL)
 *                Injects pre-built Account data. Tests can assert Limits.getQueries() == 0
 *                inside startTest/stopTest proving no unintended queries were issued.
 *
 *              Section 3 — System.StubProvider via ApexMockFramework
 *                Generates stubs for interfaces without a dedicated mock class.
 *                Demonstrates handleMethodCall interception and call-count verification.
 *
 *              Section 4 — TestDataBuilder fluency and boundary data
 *                Verifies builder defaults, method chaining, and bulk helpers.
 *                Includes 200-record bulk test and boundary string lengths.
 *
 *              Section 5 — Test isolation patterns
 *                Verifies @TestSetup data isolation, static cache reset between tests,
 *                and governor-limit assertions with Test.startTest()/stopTest().
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
@IsTest
private class TestingPatternsTest {

    // ─── Shared test data ─────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        // @TestSetup data is committed before each test method runs.
        // Each test sees a fresh copy — mutations in one test do not bleed into another.
        Account acc = new TestDataBuilder.AccountBuilder()
            .withName('Setup Account')
            .withRevenue(500000)
            .buildAndInsert();

        new TestDataBuilder.OpportunityBuilder(acc.Id)
            .withAmount(75000)
            .buildAndInsert();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 1 — MockUnitOfWork: pure unit tests of AccountOnboardingService
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void mockUow_onboard_registersThreeNewRecordsNoDml() {
        MockUnitOfWork    mockUow = new MockUnitOfWork();
        AccountOnboardingService svc =
            new AccountOnboardingService(mockUow, new AccountsSelector());

        AccountOnboardingService.OnboardingRequest req =
            new AccountOnboardingService.OnboardingRequest();
        req.accountName         = 'Mock Corp';
        req.accountType         = 'Customer';
        req.annualRevenue       = 200000;
        req.opportunityName     = 'Mock Deal';
        req.opportunityAmount   = 50000;
        req.closeDate           = Date.today().addDays(30);
        req.followUpTaskSubject = 'Mock follow-up';

        Test.startTest();
        AccountOnboardingService.OnboardingResult result = svc.onboard(req);
        Test.stopTest();

        // Verify service registered exactly 3 records — no DML assertions needed
        System.assertEquals(3, mockUow.newRecords.size(),
            'Three records should be registered: Account, Opportunity, Task');
        System.assertEquals(1, mockUow.countNewOf(Account.SObjectType),
            'Exactly one Account should be registered new');
        System.assertEquals(1, mockUow.countNewOf(Opportunity.SObjectType),
            'Exactly one Opportunity should be registered new');
        System.assertEquals(1, mockUow.countNewOf(Task.SObjectType),
            'Exactly one Task should be registered new');

        // Verify commitWork was called — all work reaches commit
        System.assertEquals(true, mockUow.wasCommitted(),
            'commitWork() must be called to persist the registrations');
        System.assertEquals(1, mockUow.commitCount,
            'commitWork() should be called exactly once');

        // Result is optimistic (mock does not persist real Ids)
        System.assertEquals(true, result.success, 'Result should indicate success');
    }

    @IsTest
    static void mockUow_onboard_registersOppAccountIdRelationship() {
        MockUnitOfWork mockUow = new MockUnitOfWork();
        AccountOnboardingService svc =
            new AccountOnboardingService(mockUow, new AccountsSelector());

        AccountOnboardingService.OnboardingRequest req =
            new AccountOnboardingService.OnboardingRequest();
        req.accountName         = 'Relationship Test Corp';
        req.opportunityName     = 'Test Deal';
        req.opportunityAmount   = 10000;
        req.followUpTaskSubject = 'Follow up';

        Test.startTest();
        svc.onboard(req);
        Test.stopTest();

        // The Opportunity should have Opportunity.AccountId relationship registered to the Account
        SObject opp = mockUow.getNewOf(Opportunity.SObjectType)[0];
        SObject acc = mockUow.getNewOf(Account.SObjectType)[0];

        System.assert(
            mockUow.hasRelationship(opp, Opportunity.AccountId),
            'Opportunity.AccountId relationship should be registered with UoW');

        SObject parent = mockUow.getRelationshipParent(opp, Opportunity.AccountId);
        System.assertEquals(acc, parent,
            'The registered parent for opp.AccountId should be the Account instance');
    }

    @IsTest
    static void mockUow_onboard_registersTaskWhatIdRelationship() {
        MockUnitOfWork mockUow = new MockUnitOfWork();
        AccountOnboardingService svc =
            new AccountOnboardingService(mockUow, new AccountsSelector());

        AccountOnboardingService.OnboardingRequest req =
            new AccountOnboardingService.OnboardingRequest();
        req.accountName         = 'Task Rel Corp';
        req.opportunityName     = 'Task Rel Deal';
        req.opportunityAmount   = 10000;
        req.followUpTaskSubject = 'Task follow-up';

        Test.startTest();
        svc.onboard(req);
        Test.stopTest();

        SObject task = mockUow.getNewOf(Task.SObjectType)[0];
        SObject opp  = mockUow.getNewOf(Opportunity.SObjectType)[0];

        System.assert(
            mockUow.hasRelationship(task, Task.WhatId),
            'Task.WhatId relationship should be registered with UoW');

        SObject parent = mockUow.getRelationshipParent(task, Task.WhatId);
        System.assertEquals(opp, parent,
            'The registered parent for task.WhatId should be the Opportunity instance');
    }

    @IsTest
    static void mockUow_commitFailure_returnsErrorResult() {
        MockUnitOfWork mockUow = new MockUnitOfWork();
        mockUow.shouldThrowOnCommit = true; // simulate a DML failure

        AccountOnboardingService svc =
            new AccountOnboardingService(mockUow, new AccountsSelector());

        AccountOnboardingService.OnboardingRequest req =
            new AccountOnboardingService.OnboardingRequest();
        req.accountName         = 'Failing Corp';
        req.opportunityName     = 'Failing Deal';
        req.opportunityAmount   = 10000;
        req.followUpTaskSubject = 'Fail follow-up';

        Test.startTest();
        AccountOnboardingService.OnboardingResult result = svc.onboard(req);
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Result.success should be false when commitWork throws');
        System.assertNotEquals(null, result.errorMessage,
            'errorMessage should be populated with the exception message');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 2 — MockSelector: pure unit tests of AccountHealthService
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void mockSelector_hotAccount_registersRatingUpdateNoDml() {
        // Build fake Account in memory — no INSERT
        Id fakeId = MockSelector.fakeId(Account.SObjectType, 1);
        Account hotAccount = new Account(
            Id            = fakeId,
            Name          = 'Hot Corp',
            AnnualRevenue = 2000000, // above Hot threshold
            Rating        = 'Cold'   // wrong rating — service should correct it
        );

        MockSelector   mockSel = new MockSelector(
            Account.SObjectType, new List<SObject>{ hotAccount });
        MockUnitOfWork mockUow = new MockUnitOfWork();
        AccountHealthService svc = new AccountHealthService(mockSel, mockUow);

        Test.startTest();
        Integer updated = svc.refreshRatings(new Set<Id>{ fakeId });
        Test.stopTest();

        System.assertEquals(1, updated, 'One Account should be updated');
        System.assertEquals(1, mockUow.countDirtyOf(Account.SObjectType),
            'Account should be registered dirty for Rating update');
        System.assertEquals('Hot', hotAccount.Rating,
            'Rating should be stamped Hot by the service');
        System.assertEquals(true, mockUow.wasCommitted(),
            'commitWork() must be called when an update is needed');

        // Verify EXACTLY 1 call to selectById — no extra SOQL
        System.assertEquals(1, mockSel.selectByIdCallCount,
            'selectById should be called exactly once');
    }

    @IsTest
    static void mockSelector_alreadyCorrectRating_noRegisterDirtyNoDml() {
        Id fakeId = MockSelector.fakeId(Account.SObjectType, 2);
        Account warmAccount = new Account(
            Id            = fakeId,
            Name          = 'Already Warm Corp',
            AnnualRevenue = 200000, // Warm threshold
            Rating        = 'Warm'  // already correct — service should skip
        );

        MockSelector   mockSel = new MockSelector(
            Account.SObjectType, new List<SObject>{ warmAccount });
        MockUnitOfWork mockUow = new MockUnitOfWork();
        AccountHealthService svc = new AccountHealthService(mockSel, mockUow);

        Test.startTest();
        Integer updated = svc.refreshRatings(new Set<Id>{ fakeId });
        Test.stopTest();

        System.assertEquals(0, updated,
            'No update should occur when Rating is already correct');
        System.assertEquals(0, mockUow.countDirtyOf(Account.SObjectType),
            'registerDirty should not be called when Rating is unchanged');
        System.assertEquals(false, mockUow.wasCommitted(),
            'commitWork should not be called when no records need updating');
    }

    @IsTest
    static void mockSelector_zeroQueriesInsideStartStopTest() {
        Id fakeId = MockSelector.fakeId(Account.SObjectType, 3);
        MockSelector   mockSel = new MockSelector(Account.SObjectType,
            new List<SObject>{ new Account(Id = fakeId, AnnualRevenue = 50000, Rating = 'Cold') });
        MockUnitOfWork mockUow = new MockUnitOfWork();
        AccountHealthService svc = new AccountHealthService(mockSel, mockUow);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        svc.refreshRatings(new Set<Id>{ fakeId });
        Integer queriesAfter  = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(queriesBefore, queriesAfter,
            'MockSelector fires zero SOQL — query count should not change');
    }

    @IsTest
    static void mockSelector_resolveRating_allThreeTiers() {
        // Test @TestVisible helper directly — pure unit, zero infrastructure
        System.assertEquals('Hot',  AccountHealthService.resolveRating(1500000));
        System.assertEquals('Warm', AccountHealthService.resolveRating(500000));
        System.assertEquals('Cold', AccountHealthService.resolveRating(50000));
        System.assertEquals('Cold', AccountHealthService.resolveRating(null));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 3 — System.StubProvider via ApexMockFramework
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void stubProvider_interceptsSelectById_returnsConfiguredList() {
        Id fakeId = MockSelector.fakeId(Account.SObjectType, 10);
        List<SObject> stubbedAccounts = new List<SObject>{
            new Account(Id = fakeId, Name = 'Stubbed Account')
        };

        ApexMockFramework.GenericStubProvider provider =
            new ApexMockFramework.GenericStubProvider();
        provider.whenCalled('selectById').thenReturn(stubbedAccounts);

        // Test.createStub() must be called from @IsTest context
        ISelector stub = (ISelector) Test.createStub(ISelector.class, provider);

        Test.startTest();
        List<SObject> result = stub.selectById(new Set<Id>{ fakeId });
        Test.stopTest();

        System.assertEquals(stubbedAccounts, result,
            'StubProvider should return the configured list');
        System.assertEquals(1, provider.getCallCount('selectById'),
            'selectById should be recorded as called once');
    }

    @IsTest
    static void stubProvider_unconfiguredMethod_returnsNull() {
        ApexMockFramework.GenericStubProvider provider =
            new ApexMockFramework.GenericStubProvider();
        ISelector stub = (ISelector) Test.createStub(ISelector.class, provider);

        Test.startTest();
        SObjectType result = stub.getSObjectType();
        Test.stopTest();

        System.assertEquals(null, result,
            'Unconfigured method should return null from StubProvider');
        System.assertEquals(true, provider.wasCalled('getSObjectType'),
            'wasCalled should be true even for unconfigured methods');
    }

    @IsTest
    static void stubProvider_multipleCallsSamMethod_tracksCount() {
        ApexMockFramework.GenericStubProvider provider =
            new ApexMockFramework.GenericStubProvider();
        provider.whenCalled('selectById').thenReturn(new List<SObject>());
        ISelector stub = (ISelector) Test.createStub(ISelector.class, provider);

        Test.startTest();
        stub.selectById(new Set<Id>());
        stub.selectById(new Set<Id>());
        stub.selectById(new Set<Id>());
        Test.stopTest();

        System.assertEquals(3, provider.getCallCount('selectById'),
            'Call count should reflect three invocations');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 4 — TestDataBuilder: fluency, defaults, bulk, boundary
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void accountBuilder_fluentChaining_setsAllFields() {
        Account acc = new TestDataBuilder.AccountBuilder()
            .withName('Fluent Corp')
            .asPartner()
            .withRevenue(1000000)
            .withRating('Hot')
            .build();

        System.assertEquals('Fluent Corp', acc.Name);
        System.assertEquals('Partner',     acc.Type);
        System.assertEquals(1000000,        acc.AnnualRevenue);
        System.assertEquals('Hot',          acc.Rating);
        System.assertEquals(null,           acc.Id,
            'build() should not insert — Id remains null');
    }

    @IsTest
    static void opportunityBuilder_defaultsAreValid() {
        // Build an Account first so the Opportunity FK is valid
        Account acc = new TestDataBuilder.AccountBuilder().buildAndInsert();
        Opportunity opp = new TestDataBuilder.OpportunityBuilder(acc.Id).build();

        System.assertNotEquals(null, opp.AccountId, 'AccountId should be set');
        System.assertNotEquals(null, opp.StageName,  'Default StageName should be set');
        System.assertNotEquals(null, opp.CloseDate,  'Default CloseDate should be set');
        System.assertEquals(50000, opp.Amount,       'Default Amount should be 50,000');
    }

    @IsTest
    static void caseBuilder_asClosedHighPriority_setsCorrectFields() {
        Account acc = new TestDataBuilder.AccountBuilder().buildAndInsert();
        Case c = new TestDataBuilder.CaseBuilder(acc.Id)
            .withSubject('Critical Issue')
            .asClosed()
            .asHighPriority()
            .build();

        System.assertEquals('Critical Issue', c.Subject);
        System.assertEquals('Closed',         c.Status);
        System.assertEquals('High',           c.Priority);
    }

    @IsTest
    static void bulkBuilder_creates200Accounts_withinGovernorLimits() {
        Test.startTest();
        List<Account> accs = TestDataBuilder.buildAccounts(200, true);
        Test.stopTest();

        System.assertEquals(200, accs.size(), '200 Accounts should be created');
        for (Account acc : accs) {
            System.assertNotEquals(null, acc.Id,
                'Every Account should have an Id after buildAndInsert');
        }
    }

    @IsTest
    static void bulkBuilder_200Opportunities_allLinkedToAccount() {
        Account acc = new TestDataBuilder.AccountBuilder().buildAndInsert();

        // Inject factory cache so OpportunityTrigger pricing pipeline uses default
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        Test.startTest();
        List<Opportunity> opps = TestDataBuilder.buildOpportunities(acc.Id, 200, true);
        Test.stopTest();

        System.assertEquals(200, opps.size(), '200 Opportunities should be created');
        System.assertEquals(200,
            [SELECT COUNT() FROM Opportunity WHERE AccountId = :acc.Id],
            'All 200 Opportunities should be linked to the Account');
    }

    @IsTest
    static void buildStringOfLength_exactBoundaryLength() {
        String result255 = TestDataBuilder.buildStringOfLength(255, 'A');
        String result256 = TestDataBuilder.buildStringOfLength(256, 'B');

        System.assertEquals(255, result255.length(),
            'buildStringOfLength(255) should return exactly 255 characters');
        System.assertEquals(256, result256.length(),
            'buildStringOfLength(256) should return exactly 256 characters');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 5 — Test isolation patterns
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testSetup_dataAccessibleInEachTest_noBleedBetweenTests() {
        // @TestSetup creates 1 Account + 1 Opportunity before this test runs.
        // Previous tests may have inserted additional records but they are rolled back.
        Integer accCount = [SELECT COUNT() FROM Account WHERE Name = 'Setup Account'];
        Integer oppCount = [SELECT COUNT() FROM Opportunity WHERE Amount = 75000];

        System.assertEquals(1, accCount,
            '@TestSetup Account should be visible in every test method');
        System.assertEquals(1, oppCount,
            '@TestSetup Opportunity should be visible in every test method');
    }

    @IsTest
    static void staticCache_resetBetweenTests_factoryCacheIsNull() {
        // DiscountStrategyFactory.configCache is static — it resets to null
        // at the start of each test transaction. This test verifies the cache
        // starts null (not polluted from a previous test).
        System.assertEquals(null, DiscountStrategyFactory.configsByType,
            'Static CMDT cache should be null at the start of each test transaction');
    }

    @IsTest
    static void startStopTest_resetsGovernorLimits_allowsAdditionalDml() {
        // Consume some DML before startTest
        List<Account> preDml = TestDataBuilder.buildAccounts(5, true);
        Integer dmlBefore = Limits.getDmlStatements();

        // startTest() resets governor counters for the code under test
        Test.startTest();
        Integer dmlAfterReset = Limits.getDmlStatements();
        List<Account> postDml = TestDataBuilder.buildAccounts(5, true);
        Test.stopTest();

        System.assertEquals(0, dmlAfterReset,
            'Test.startTest() should reset DML statement count to 0');
        System.assert(dmlBefore > 0,
            'DML should have been consumed before startTest()');
    }

    @IsTest
    static void selectorQueryCount_oneBulkSelect_isSingleQuery() {
        List<Id> ids = new List<Id>();
        for (Account acc : [SELECT Id FROM Account]) {
            ids.add(acc.Id);
        }
        AccountsSelector sel = new AccountsSelector();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        sel.selectById(new Set<Id>(ids));
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(1, queriesAfter - queriesBefore,
            'selectById() on any number of Ids should cost exactly 1 SOQL query');
    }

    @IsTest
    static void negativeTest_mockUow_shouldThrowOnCommit_configuredCorrectly() {
        MockUnitOfWork mockUow = new MockUnitOfWork();
        mockUow.shouldThrowOnCommit = true;

        Boolean threw = false;
        try {
            mockUow.commitWork();
        } catch (UnitOfWork.UnitOfWorkException e) {
            threw = true;
        }

        System.assert(threw,
            'MockUnitOfWork.commitWork() should throw when shouldThrowOnCommit = true');
    }
}
