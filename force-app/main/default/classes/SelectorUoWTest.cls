/**
 * @description Test class for Day 6: Selector Pattern, Unit of Work Pattern,
 *              and the AccountOnboardingService integration.
 *
 *              Coverage strategy:
 *                - Selector tests: DML setup → query → assertion on returned data
 *                - UnitOfWork tests: register → commitWork → SOQL verification
 *                - Service tests: full integration using real UoW + real Selector
 *
 *              No mocking of UoW — using the real implementation verifies the
 *              pattern end-to-end and catches relationship resolution bugs.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
@IsTest
private class SelectorUoWTest {

    // ─── Shared test data ─────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        Account acc = TestDataFactory.createAccount(false);
        acc.AnnualRevenue = 500000;
        acc.Type = 'Customer';
        insert acc;

        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name      = 'Open Opp 1',
                AccountId = acc.Id,
                Amount    = 50000,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            ),
            new Opportunity(
                Name      = 'Closed Won Opp',
                AccountId = acc.Id,
                Amount    = 100000,
                StageName = 'Closed Won',
                CloseDate = Date.today().addDays(-10)
            )
        };
        insert opps;

        Case c = TestDataFactory.createCase(acc.Id, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountsSelector
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void accountsSelector_selectById_returnsMatchingFields() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        AccountsSelector sel = new AccountsSelector();

        Test.startTest();
        List<SObject> results = sel.selectById(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return exactly one Account');
        Account fetched = (Account) results[0];
        System.assertNotEquals(null, fetched.AnnualRevenue, 'AnnualRevenue should be in the default field set');
    }

    @IsTest
    static void accountsSelector_selectByOwnerId_filtersCorrectly() {
        Account acc = [SELECT OwnerId FROM Account LIMIT 1];
        AccountsSelector sel = new AccountsSelector();

        Test.startTest();
        List<Account> results = sel.selectByOwnerId(new Set<Id>{ acc.OwnerId });
        Test.stopTest();

        System.assertNotEquals(0, results.size(), 'Should return accounts for the given owner');
    }

    @IsTest
    static void accountsSelector_selectWithOpenOpportunities_populatesSubquery() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        AccountsSelector sel = new AccountsSelector();

        Test.startTest();
        List<Account> results = sel.selectWithOpenOpportunities(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(1, results.size());
        // The open Opportunity should appear in the sub-query
        System.assertNotEquals(null, results[0].Opportunities,
            'Opportunities sub-query should be populated');
        System.assertNotEquals(0, results[0].Opportunities.size(),
            'At least one open Opportunity should be returned');
    }

    @IsTest
    static void accountsSelector_selectByMinRevenue_filtersLowRevenueAccounts() {
        AccountsSelector sel = new AccountsSelector();

        Test.startTest();
        List<Account> aboveThreshold = sel.selectByMinRevenue(100000);
        List<Account> aboveHighBar   = sel.selectByMinRevenue(10000000);
        Test.stopTest();

        System.assertNotEquals(0, aboveThreshold.size(),
            'Account with 500K revenue should exceed 100K threshold');
        System.assertEquals(0, aboveHighBar.size(),
            'No account should exceed 10M revenue threshold in test data');
    }

    @IsTest
    static void accountsSelector_getSObjectType_returnsAccountType() {
        System.assertEquals(Account.SObjectType,
            new AccountsSelector().getSObjectType(),
            'getSObjectType() should return Account.SObjectType');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OpportunitiesSelector
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void opportunitiesSelector_selectByAccountId_returnsAllOpps() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        OpportunitiesSelector sel = new OpportunitiesSelector();

        Test.startTest();
        List<Opportunity> results = sel.selectByAccountId(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(2, results.size(),
            'Both open and closed Opportunities should be returned');
    }

    @IsTest
    static void opportunitiesSelector_selectClosedWon_filtersOpenOpps() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        OpportunitiesSelector sel = new OpportunitiesSelector();

        Test.startTest();
        List<Opportunity> closedWon = sel.selectClosedWonByAccountId(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(1, closedWon.size(),
            'Only the Closed Won Opportunity should be returned');
        System.assertEquals(true, closedWon[0].IsWon, 'Returned Opportunity must be Won');
    }

    @IsTest
    static void opportunitiesSelector_selectRevenueByAccount_aggregatesCorrectly() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        OpportunitiesSelector sel = new OpportunitiesSelector();

        Test.startTest();
        List<AggregateResult> results = sel.selectRevenueByAccount(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'One AggregateResult per Account expected');
        System.assertEquals(100000, (Decimal) results[0].get('totalRevenue'),
            'Total revenue should equal Amount of the Closed Won Opportunity');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CasesSelector
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void casesSelector_selectOpenByAccountId_excludesClosedCases() {
        Account acc  = [SELECT Id FROM Account LIMIT 1];
        Case openCase = [SELECT Id FROM Case WHERE AccountId = :acc.Id LIMIT 1];
        // Close the case to test the filter
        openCase.Status = 'Closed';
        update openCase;

        CasesSelector sel = new CasesSelector();

        Test.startTest();
        List<Case> results = sel.selectOpenByAccountId(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'Closed case should be excluded from selectOpenByAccountId');
    }

    @IsTest
    static void casesSelector_countOpenCasesByAccount_returnsCorrectCount() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        CasesSelector sel = new CasesSelector();

        Test.startTest();
        List<AggregateResult> results = sel.countOpenCasesByAccount(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One aggregate row per account expected');
        System.assertEquals(1, (Integer) results[0].get('openCaseCount'),
            'One open case exists in test data');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UnitOfWork
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void uow_registerNew_insertsRecordWithId() {
        UnitOfWork uow = new UnitOfWork(
            new List<SObjectType>{ Account.SObjectType });

        Account acc = new Account(Name = 'UoW Test Account');
        uow.registerNew(acc);

        Test.startTest();
        uow.commitWork();
        Test.stopTest();

        System.assertNotEquals(null, acc.Id,
            'Account.Id should be populated after UoW commitWork()');
        List<Account> verify = [SELECT Id FROM Account WHERE Id = :acc.Id];
        System.assertEquals(1, verify.size(), 'Account should exist in database after commit');
    }

    @IsTest
    static void uow_registerNew_withRelationship_resolvesParentId() {
        UnitOfWork uow = new UnitOfWork(
            new List<SObjectType>{
                Account.SObjectType,
                Opportunity.SObjectType
            });

        Account acc = new Account(Name = 'UoW Parent Account');
        uow.registerNew(acc);

        Opportunity opp = new Opportunity(
            Name      = 'UoW Child Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        // Relationship registration — do NOT set opp.AccountId manually
        uow.registerNew(opp, Opportunity.AccountId, acc);

        Test.startTest();
        uow.commitWork();
        Test.stopTest();

        // Verify parent ID was resolved and both records exist
        Opportunity inserted = [SELECT Id, AccountId FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(acc.Id, inserted.AccountId,
            'UoW should have set opp.AccountId = acc.Id after Account INSERT');
    }

    @IsTest
    static void uow_registerDirty_updatesExistingRecord() {
        Account acc = [SELECT Id, Rating FROM Account LIMIT 1];
        String newRating = acc.Rating == 'Hot' ? 'Warm' : 'Hot';

        UnitOfWork uow = new UnitOfWork(
            new List<SObjectType>{ Account.SObjectType });

        acc.Rating = newRating;
        uow.registerDirty(acc);

        Test.startTest();
        uow.commitWork();
        Test.stopTest();

        Account updated = [SELECT Rating FROM Account WHERE Id = :acc.Id];
        System.assertEquals(newRating, updated.Rating,
            'registerDirty() should UPDATE the field value');
    }

    @IsTest
    static void uow_registerDeleted_deletesRecord() {
        Case c = [SELECT Id FROM Case LIMIT 1];
        UnitOfWork uow = new UnitOfWork(new List<SObjectType>{ Case.SObjectType });
        uow.registerDeleted(c);

        Test.startTest();
        uow.commitWork();
        Test.stopTest();

        List<Case> remaining = [SELECT Id FROM Case WHERE Id = :c.Id];
        System.assertEquals(0, remaining.size(),
            'registerDeleted() should DELETE the Case record');
    }

    @IsTest
    static void uow_unregisteredType_throwsUnitOfWorkException() {
        UnitOfWork uow = new UnitOfWork(
            new List<SObjectType>{ Account.SObjectType }
        );
        Boolean threw = false;

        Test.startTest();
        try {
            uow.registerNew(new Opportunity(Name = 'Not Registered'));
        } catch (UnitOfWork.UnitOfWorkException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'Registering an unregistered SObjectType should throw UnitOfWorkException');
    }

    @IsTest
    static void uow_commitWork_rollsBackOnException() {
        UnitOfWork uow = new UnitOfWork(
            new List<SObjectType>{ Account.SObjectType });

        // Register a record that will fail validation (Name = null violates required field)
        Account badAcc = new Account(); // Name is required — DML will fail
        uow.registerNew(badAcc);

        Integer countBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        Boolean threw = false;
        try {
            uow.commitWork();
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Integer countAfter = [SELECT COUNT() FROM Account];
        System.assert(threw, 'commitWork() should re-throw the DML exception');
        System.assertEquals(countBefore, countAfter,
            'Savepoint rollback should prevent any Account from being inserted');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountOnboardingService — Selector + UoW integration
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void onboardingService_onboard_createsAllThreeRecordsAtomically() {
        // Inject real UoW with correct dependency order
        IUnitOfWork uow = new UnitOfWork(new List<SObjectType>{
            Account.SObjectType,
            Opportunity.SObjectType,
            Task.SObjectType
        });
        AccountOnboardingService svc =
            new AccountOnboardingService(uow, new AccountsSelector());

        AccountOnboardingService.OnboardingRequest req =
            new AccountOnboardingService.OnboardingRequest();
        req.accountName          = 'Onboarded Corp';
        req.accountType          = 'Customer';
        req.annualRevenue        = 750000;
        req.opportunityName      = 'First Deal';
        req.opportunityAmount    = 50000;
        req.closeDate            = Date.today().addDays(45);
        req.followUpTaskSubject  = 'Schedule kickoff call';

        Test.startTest();
        AccountOnboardingService.OnboardingResult result = svc.onboard(req);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'Onboarding should succeed');
        System.assertNotEquals(null, result.accountId,     'accountId must be populated');
        System.assertNotEquals(null, result.opportunityId, 'opportunityId must be populated');
        System.assertNotEquals(null, result.taskId,        'taskId must be populated');

        // Verify DB state
        Opportunity opp = [SELECT AccountId FROM Opportunity WHERE Id = :result.opportunityId];
        System.assertEquals(result.accountId, opp.AccountId,
            'Opportunity.AccountId should equal the newly created Account.Id');

        Task t = [SELECT WhatId FROM Task WHERE Id = :result.taskId];
        System.assertEquals(result.opportunityId, t.WhatId,
            'Task.WhatId should equal the newly created Opportunity.Id');
    }

    @IsTest
    static void onboardingService_enrichHighRevenueAccounts_updatesRating() {
        IUnitOfWork uow = new UnitOfWork(
            new List<SObjectType>{ Account.SObjectType });
        AccountOnboardingService svc =
            new AccountOnboardingService(uow, new AccountsSelector());

        Test.startTest();
        // Account in @TestSetup has AnnualRevenue = 500,000; threshold = 100,000
        svc.enrichHighRevenueAccounts(100000, 'Hot');
        Test.stopTest();

        Account updated = [SELECT Rating FROM Account LIMIT 1];
        System.assertEquals('Hot', updated.Rating,
            'Account exceeding revenue threshold should have Rating = Hot');
    }
}
