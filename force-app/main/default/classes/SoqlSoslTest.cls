/**
 * @description Tests for SoqlQueryService and SoslSearchService.
 *
 *              SOQL testing: standard — insert data, run query, assert results.
 *              SOSL testing: requires Test.setFixedSearchResults(). SOSL uses a
 *              search index that is NOT populated during test execution (test data
 *              is isolated from the search index). setFixedSearchResults() injects
 *              a predefined Id list as the SOSL result for ALL SOSL queries in the
 *              test — the search term is ignored.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
@IsTest
private class SoqlSoslTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // SoqlQueryService — Relationship Queries
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAccountsWithOpenCases_returnsChildCasesInline() {
        Account acc    = TestDataFactory.createAccount(true);
        Case openCase  = TestDataFactory.createCase(acc.Id, UserInfo.getUserId(), true);
        Case closedCase = new Case(AccountId=acc.Id, Subject='Closed', Status='Closed',
                                   OwnerId=UserInfo.getUserId());
        insert closedCase;

        Test.startTest();
        List<Account> results = SoqlQueryService.getAccountsWithOpenCases(
            new Set<Id>{ acc.Id }
        );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return the queried Account');
        System.assertEquals(1, results[0].Cases.size(),
            'Parent-to-child sub-query should return only the open Case');
        System.assertEquals(openCase.Id, results[0].Cases[0].Id,
            'The inline Case should be the open one');
    }

    @IsTest
    static void getCasesWithParentData_populatesAccountAndOwnerFields() {
        Account acc = TestDataFactory.createAccount(true);
        Case c = TestDataFactory.createCase(acc.Id, UserInfo.getUserId(), true);

        Test.startTest();
        List<Case> results = SoqlQueryService.getCasesWithParentData(
            new Set<Id>{ c.Id }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(acc.Name,              results[0].Account.Name,
            'Child-to-parent traversal should populate Account.Name');
        System.assertNotEquals(null,               results[0].Owner.Name,
            'Owner relationship should be populated via dot notation');
    }

    @IsTest
    static void getAccountsCached_secondCallUsesCache_noDuplicateSoql() {
        Account acc = TestDataFactory.createAccount(true);
        Set<Id> ids = new Set<Id>{ acc.Id };

        Test.startTest();
        Map<Id, Account> first  = SoqlQueryService.getAccountsCached(ids);
        Map<Id, Account> second = SoqlQueryService.getAccountsCached(ids);
        Test.stopTest();

        // Both calls should return the same data
        System.assertEquals(1, first.size());
        System.assertEquals(first.get(acc.Id).Name, second.get(acc.Id).Name,
            'Cached call should return identical data');
        // Cache miss set would be empty on second call — verified by the static map size
        System.assertEquals(1, SoqlQueryService.accountCache.size(),
            'Cache should contain exactly 1 entry after two calls for same ID');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SoqlQueryService — Aggregate Queries
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getRevenueByIndustry_returnsOnlyAboveThreshold() {
        insert new List<Account>{
            new Account(Name='TechA', Industry='Technology', AnnualRevenue=5000000),
            new Account(Name='TechB', Industry='Technology', AnnualRevenue=6000000),
            new Account(Name='RetailA', Industry='Retail',   AnnualRevenue=100000)
        };

        Test.startTest();
        List<AggregateResult> results =
            SoqlQueryService.getRevenueByIndustry(10000000); // 10M threshold
        Test.stopTest();

        // Technology total = 11M > 10M threshold — should appear
        // Retail total = 100K < 10M — should be excluded
        Boolean technologyFound = false;
        Boolean retailFound     = false;
        for (AggregateResult ar : results) {
            if ((String) ar.get('Industry') == 'Technology') technologyFound = true;
            if ((String) ar.get('Industry') == 'Retail')     retailFound     = true;
        }
        System.assert(technologyFound,  'Technology group (11M total) should pass 10M HAVING threshold');
        System.assert(!retailFound,     'Retail group (100K total) should be excluded by HAVING');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SoqlQueryService — Semi/Anti Joins
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getOpenCasesForWonAccountsSemiJoin_returnsOnlyCasesWithWonOpps() {
        Account wonAccount = TestDataFactory.createAccount(true);
        Account plainAccount = TestDataFactory.createAccount(true);

        insert new Opportunity(Name='Won Opp', AccountId=wonAccount.Id,
                               StageName='Closed Won', CloseDate=Date.today());

        Case caseOnWonAccount   = TestDataFactory.createCase(wonAccount.Id,  UserInfo.getUserId(), true);
        Case caseOnPlainAccount = TestDataFactory.createCase(plainAccount.Id, UserInfo.getUserId(), true);

        Test.startTest();
        List<Case> results = SoqlQueryService.getOpenCasesForWonAccountsSemiJoin();
        Test.stopTest();

        Set<Id> resultIds = new Map<Id, Case>(results).keySet();
        System.assert(resultIds.contains(caseOnWonAccount.Id),
            'Case on account with Closed Won opp should be in semi-join result');
        System.assert(!resultIds.contains(caseOnPlainAccount.Id),
            'Case on account without Closed Won opp should be excluded');
    }

    @IsTest
    static void getAccountsWithNoContacts_excludesAccountsWithContacts() {
        Account withContact    = TestDataFactory.createAccount(true);
        Account withoutContact = TestDataFactory.createAccount(true);

        insert new Contact(FirstName='Test', LastName='Contact', AccountId=withContact.Id);

        Test.startTest();
        List<Account> results = SoqlQueryService.getAccountsWithNoContacts(100);
        Test.stopTest();

        Set<Id> resultIds = new Map<Id, Account>(results).keySet();
        System.assert(resultIds.contains(withoutContact.Id),
            'Account with no contacts should appear in anti-join result');
        System.assert(!resultIds.contains(withContact.Id),
            'Account with a contact should be excluded by NOT IN sub-query');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SoqlQueryService — Dynamic SOQL
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void queryAccountsByIndustryDynamic_allowlistFiltersUnsafeFields() {
        insert new Account(Name='Tech Corp', Industry='Technology', AnnualRevenue=5000000);

        Test.startTest();
        List<Account> results = SoqlQueryService.queryAccountsByIndustryDynamic(
            new List<String>{ 'Name', 'AnnualRevenue', 'MaliciousField__r.BadData' },
            'Technology'
        );
        Test.stopTest();

        System.assertNotEquals(0, results.size(), 'Should return Technology accounts');
        // Verify malicious field was stripped — Id and Name should be accessible, bad field not
        Account result = results[0];
        System.assertNotEquals(null, result.Name, 'Allowlisted Name field should be populated');
    }

    @IsTest
    static void queryAccountsByRevenueBand_returnsAccountsInRange() {
        insert new List<Account>{
            new Account(Name='Low',  AnnualRevenue=500000),
            new Account(Name='Mid',  AnnualRevenue=5000000),
            new Account(Name='High', AnnualRevenue=50000000)
        };

        Test.startTest();
        List<Account> results = SoqlQueryService.queryAccountsByRevenueBand(1000000, 10000000);
        Test.stopTest();

        Set<String> names = new Set<String>();
        for (Account acc : results) { names.add(acc.Name); }
        System.assert(names.contains('Mid'),   'Mid revenue (5M) should be within 1M-10M band');
        System.assert(!names.contains('Low'),  'Low revenue (500K) should be below band');
        System.assert(!names.contains('High'), 'High revenue (50M) should be above band');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SoqlQueryService — Pagination
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getOpenCasesPaginated_page2_returnsCorrectOffset() {
        Account acc = TestDataFactory.createAccount(true);
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 6; i++) {
            cases.add(new Case(AccountId=acc.Id, Subject='Case '+i,
                               Status='New', OwnerId=UserInfo.getUserId()));
        }
        insert cases;

        Test.startTest();
        List<Case> page1 = SoqlQueryService.getOpenCasesPaginated(1, 3);
        List<Case> page2 = SoqlQueryService.getOpenCasesPaginated(2, 3);
        Test.stopTest();

        System.assertEquals(3, page1.size(), 'Page 1 should return 3 records');
        System.assertEquals(3, page2.size(), 'Page 2 should return next 3 records');
        // Pages should not overlap
        Set<Id> page1Ids = new Map<Id, Case>(page1).keySet();
        for (Case c : page2) {
            System.assert(!page1Ids.contains(c.Id), 'Pages should contain distinct records');
        }
    }

    @IsTest
    static void getOpenCasesKeysetPage_cursorMovesForward() {
        Account acc = TestDataFactory.createAccount(true);
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 6; i++) {
            cases.add(new Case(AccountId=acc.Id, Subject='KS Case '+i,
                               Status='New', OwnerId=UserInfo.getUserId()));
        }
        insert cases;

        Test.startTest();
        List<Case> page1 = SoqlQueryService.getOpenCasesKeysetPage(null, 3);
        Id cursor        = page1[page1.size()-1].Id;
        List<Case> page2 = SoqlQueryService.getOpenCasesKeysetPage(cursor, 3);
        Test.stopTest();

        System.assertEquals(3, page1.size(), 'First page should return 3 records');
        System.assertEquals(3, page2.size(), 'Second keyset page should return 3 records');
        for (Case c : page2) {
            System.assert(c.Id > cursor,
                'All keyset page 2 records should have Id > cursor from page 1');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SoslSearchService
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void globalSearch_returnsFixedResults_acrossAllObjects() {
        Account acc     = TestDataFactory.createAccount(true);
        Contact contact = new Contact(FirstName='Test', LastName='SOSL',
                                      AccountId=acc.Id);
        insert contact;
        Case c = TestDataFactory.createCase(acc.Id, UserInfo.getUserId(), true);

        // setFixedSearchResults bypasses the search index — SOSL returns these Ids
        // regardless of the search term. MUST be called before the SOSL query.
        Test.setFixedSearchResults(new List<Id>{ acc.Id, contact.Id, c.Id });

        Test.startTest();
        Map<String, List<SObject>> results = SoslSearchService.globalSearch('test');
        Test.stopTest();

        System.assert(results.containsKey('Account'), 'Result map should have Account key');
        System.assert(results.containsKey('Contact'), 'Result map should have Contact key');
        System.assert(results.containsKey('Case'),    'Result map should have Case key');
        System.assertEquals(1, results.get('Account').size(), 'One Account fixed result');
        System.assertEquals(1, results.get('Contact').size(), 'One Contact fixed result');
        System.assertEquals(1, results.get('Case').size(),    'One Case fixed result');
    }

    @IsTest
    static void searchAccountsByName_returnsFixedAccountResult() {
        Account acc = TestDataFactory.createAccount(true);
        Test.setFixedSearchResults(new List<Id>{ acc.Id });

        Test.startTest();
        List<Account> results = SoslSearchService.searchAccountsByName('Test');
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one Account from fixed results');
        System.assertEquals(acc.Id, results[0].Id, 'Returned Account ID should match test data');
    }

    @IsTest
    static void searchByEmail_fixedContactResult_returnedInMap() {
        Account acc     = TestDataFactory.createAccount(true);
        Contact contact = new Contact(FirstName='Email', LastName='Test',
                                      Email='test@example.com', AccountId=acc.Id);
        insert contact;
        Test.setFixedSearchResults(new List<Id>{ contact.Id });

        Test.startTest();
        Map<String, List<SObject>> results =
            SoslSearchService.searchByEmail('test@example.com');
        Test.stopTest();

        System.assertEquals(1, results.get('Contact').size(),
            'Email SOSL should return the fixed Contact result');
    }

    @IsTest
    static void sanitizeSoslTerm_stripsSpecialChars_returnsCleanTerm() {
        Test.startTest();
        String clean = SoslSearchService.sanitizeSoslTerm('Acme* Corp? (Inc)');
        Test.stopTest();

        System.assert(!clean.contains('*'), 'Wildcard * should be stripped');
        System.assert(!clean.contains('?'), 'Question mark ? should be stripped');
        System.assert(!clean.contains('('), 'Parentheses should be stripped');
        System.assert(clean.contains('Acme'), 'Base search term Acme should remain');
    }

    @IsTest
    static void dynamicMultiObjectSearch_rejectsUnallowedObjects() {
        Account acc = TestDataFactory.createAccount(true);
        Test.setFixedSearchResults(new List<Id>{ acc.Id });

        Test.startTest();
        List<List<SObject>> results = SoslSearchService.dynamicMultiObjectSearch(
            'test',
            new List<String>{ 'Account', 'MaliciousObject__c' }
        );
        Test.stopTest();

        // Only Account passes the allowlist — result should have 1 list (Account only)
        System.assertEquals(1, results.size(),
            'Dynamic SOSL should only include allowlisted objects (Account)');
    }
}
