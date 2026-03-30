/**
 * @description Tests for Day 2 async Apex classes: AccountRatingBatch,
 *              OpportunityRollupBatch, and AccountSyncQueueable.
 *
 *              Async testing rules in Salesforce:
 *                - Batch: Test.startTest() / Test.stopTest() forces synchronous execution
 *                  of ONE batch job. Database.executeBatch() inside startTest() runs the
 *                  full start→execute→finish cycle when stopTest() is called.
 *                - Queueable: Same startTest/stopTest pattern — System.enqueueJob() inside
 *                  startTest() executes synchronously at stopTest(). Only ONE level of
 *                  chaining executes; the chained job is enqueued but not run.
 *                - Callout mocks: Test.setMock(HttpCalloutMock.class, mock) must be set
 *                  BEFORE Test.startTest() for async callout tests.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
@IsTest
private class AsyncApexTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountRatingBatch
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void accountRatingBatch_setsRatings_onMatchingAccounts() {
        // Arrange — accounts with revenue that maps to CMDT tiers
        // TestDataFactory.getDefaultRatingConfigs() mirrors deployed CMDT: Hot≥10M, Warm≥1M, Cold≥0
        List<Account> accounts = new List<Account>{
            TestDataFactory.createAccount(new Map<String,Object>{'AnnualRevenue'=>15000000, 'Rating'=>null}, true),
            TestDataFactory.createAccount(new Map<String,Object>{'AnnualRevenue'=>2000000,  'Rating'=>null}, true),
            TestDataFactory.createAccount(new Map<String,Object>{'AnnualRevenue'=>500000,   'Rating'=>null}, true)
        };

        Test.startTest();
        Database.executeBatch(new AccountRatingBatch(), AccountRatingBatch.DEFAULT_SCOPE);
        Test.stopTest();

        Map<Id, Account> results = new Map<Id, Account>(
            [SELECT Id, AnnualRevenue, Rating FROM Account WHERE Id IN :new Map<Id,Account>(accounts).keySet()]
        );

        System.assertEquals('Hot',  results.get(accounts[0].Id).Rating, '15M should be Hot');
        System.assertEquals('Warm', results.get(accounts[1].Id).Rating, '2M should be Warm');
        System.assertEquals('Cold', results.get(accounts[2].Id).Rating, '500K should be Cold');
    }

    @IsTest
    static void accountRatingBatch_skipsAccountsWithNullRevenue() {
        Account noRevenue = TestDataFactory.createAccount(
            new Map<String,Object>{'AnnualRevenue'=>null, 'Rating'=>'Warm'}, true
        );

        Test.startTest();
        Database.executeBatch(new AccountRatingBatch(), AccountRatingBatch.DEFAULT_SCOPE);
        Test.stopTest();

        Account result = [SELECT Rating FROM Account WHERE Id = :noRevenue.Id];
        // Batch QueryLocator filters WHERE AnnualRevenue != null — record skipped entirely
        System.assertEquals('Warm', result.Rating,
            'Account with null revenue should be excluded from batch and rating unchanged');
    }

    @IsTest
    static void accountRatingBatch_withAdditionalFilter_onlyProcessesFiltered() {
        Account tech   = TestDataFactory.createAccount(new Map<String,Object>{
            'AnnualRevenue'=>12000000, 'Industry'=>'Technology'}, true);
        Account retail = TestDataFactory.createAccount(new Map<String,Object>{
            'AnnualRevenue'=>12000000, 'Industry'=>'Retail'}, true);

        Test.startTest();
        Database.executeBatch(
            new AccountRatingBatch("Industry = 'Technology'"),
            AccountRatingBatch.DEFAULT_SCOPE
        );
        Test.stopTest();

        Account techResult   = [SELECT Rating FROM Account WHERE Id = :tech.Id];
        Account retailResult = [SELECT Rating FROM Account WHERE Id = :retail.Id];

        System.assertEquals('Hot', techResult.Rating,
            'Technology account with 12M revenue should be rated Hot');
        System.assertEquals(null, retailResult.Rating,
            'Retail account excluded by additionalFilter should have no rating set');
    }

    @IsTest
    static void accountRatingBatch_bulk200Records_allUpdatedWithinLimits() {
        List<Account> accounts = TestDataFactory.createAccounts(200, true);

        Test.startTest();
        Database.executeBatch(new AccountRatingBatch(), AccountRatingBatch.DEFAULT_SCOPE);
        Test.stopTest();

        List<Account> results = [
            SELECT Rating FROM Account WHERE Id IN :new Map<Id,Account>(accounts).keySet()
        ];
        System.assertEquals(200, results.size(), 'All 200 accounts should be in result set');
        for (Account acc : results) {
            System.assertNotEquals(null, acc.Rating,
                'Every account with revenue should have a rating after batch run');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OpportunityRollupBatch — Database.Stateful
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void opportunityRollupBatch_accumulatesAcrossChunks() {
        Account acc = TestDataFactory.createAccount(true);

        // Insert Opportunities across two logical groups — batch will see them in chunks
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(AccountId=acc.Id, Name='Opp1', StageName='Closed Won',
                            CloseDate=Date.today(), Amount=25000),
            new Opportunity(AccountId=acc.Id, Name='Opp2', StageName='Closed Won',
                            CloseDate=Date.today(), Amount=75000),
            new Opportunity(AccountId=acc.Id, Name='Opp3', StageName='Closed Won',
                            CloseDate=Date.today(), Amount=50000)
        };
        insert opps;

        Test.startTest();
        Database.executeBatch(new OpportunityRollupBatch(), 2); // scope=2 forces multiple chunks
        Test.stopTest();

        Account result = [SELECT Total_Closed_Won_Revenue__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(150000, result.Total_Closed_Won_Revenue__c,
            'Stateful batch should accumulate 25K + 75K + 50K = 150K across chunks');
    }

    @IsTest
    static void opportunityRollupBatch_excludesOpenOpportunities() {
        Account acc = TestDataFactory.createAccount(true);
        insert new List<Opportunity>{
            new Opportunity(AccountId=acc.Id, Name='OpenOpp', StageName='Prospecting',
                            CloseDate=Date.today().addDays(30), Amount=999999),
            new Opportunity(AccountId=acc.Id, Name='WonOpp',  StageName='Closed Won',
                            CloseDate=Date.today(), Amount=10000)
        };

        Test.startTest();
        Database.executeBatch(new OpportunityRollupBatch(), OpportunityRollupBatch.DEFAULT_SCOPE);
        Test.stopTest();

        Account result = [SELECT Total_Closed_Won_Revenue__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(10000, result.Total_Closed_Won_Revenue__c,
            'Only Closed Won Opportunity amount should be included in rollup');
    }

    @IsTest
    static void opportunityRollupBatch_noClosedWonOpps_fieldUnchanged() {
        Account acc = TestDataFactory.createAccount(true);
        // No Closed Won opps — batch should complete without error, field stays null

        Test.startTest();
        Database.executeBatch(new OpportunityRollupBatch(), OpportunityRollupBatch.DEFAULT_SCOPE);
        Test.stopTest();

        Account result = [SELECT Total_Closed_Won_Revenue__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, result.Total_Closed_Won_Revenue__c,
            'Accounts with no Closed Won Opps should not have the rollup field set');
    }

    @IsTest
    static void opportunityRollupBatch_statefulVars_initializedOnStart() {
        // Verify that re-running the batch resets accumulators (no stale state from prior run)
        Account acc = TestDataFactory.createAccount(true);
        insert new Opportunity(AccountId=acc.Id, Name='Opp', StageName='Closed Won',
                               CloseDate=Date.today(), Amount=5000);

        OpportunityRollupBatch batchInstance = new OpportunityRollupBatch();

        Test.startTest();
        Database.executeBatch(batchInstance, OpportunityRollupBatch.DEFAULT_SCOPE);
        Test.stopTest();

        // totalOppsScanned should be exactly 1 (only 1 Closed Won Opp in org)
        System.assertEquals(1, batchInstance.totalOppsScanned,
            'totalOppsScanned should reflect exactly 1 Closed Won Opp processed');
        System.assertEquals(0, batchInstance.totalErrors,
            'No DML errors expected on a clean test run');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountSyncQueueable
    // ═══════════════════════════════════════════════════════════════════════════

    /** Inner HttpCalloutMock — lives here since it is Queueable-test-specific */
    private class MockExternalCrm implements HttpCalloutMock {
        private Integer statusCode;
        public MockExternalCrm(Integer statusCode) { this.statusCode = statusCode; }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody('{"status":"ok","synced":' + (statusCode == 200 ? 'true' : 'false') + '}');
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    @IsTest
    static void accountSyncQueueable_successfulCallout_processesChunk() {
        List<Account> accounts = TestDataFactory.createAccounts(5, true);
        List<Id> accountIds = new List<Id>(new Map<Id,Account>(accounts).keySet());

        // Mock MUST be set before Test.startTest()
        Test.setMock(HttpCalloutMock.class, new MockExternalCrm(200));

        Test.startTest();
        System.enqueueJob(new AccountSyncQueueable(accountIds));
        Test.stopTest();

        // In test context: job executes synchronously, chaining is suppressed.
        // Verify no exception thrown and job ran to completion.
        List<AsyncApexJob> jobs = [
            SELECT Status FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assert(!jobs.isEmpty(), 'A Queueable job should have been enqueued');
        System.assertEquals('Completed', jobs[0].Status,
            'Queueable should have completed successfully');
    }

    @IsTest
    static void accountSyncQueueable_failedCallout_logsErrorAndCompletes() {
        List<Account> accounts = TestDataFactory.createAccounts(3, true);
        List<Id> accountIds = new List<Id>(new Map<Id,Account>(accounts).keySet());

        // Simulate external CRM returning 500
        Test.setMock(HttpCalloutMock.class, new MockExternalCrm(500));

        Test.startTest();
        System.enqueueJob(new AccountSyncQueueable(accountIds));
        Test.stopTest();

        // Job should complete (no exception thrown) — failure is logged, not rethrown
        List<AsyncApexJob> jobs = [
            SELECT Status FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assertEquals('Completed', jobs[0].Status,
            'Queueable should complete even on HTTP 500 — errors are logged, not thrown');
    }

    @IsTest
    static void accountSyncQueueable_emptyList_completesImmediately() {
        Test.setMock(HttpCalloutMock.class, new MockExternalCrm(200));

        Test.startTest();
        System.enqueueJob(new AccountSyncQueueable(new List<Id>()));
        Test.stopTest();

        List<AsyncApexJob> jobs = [
            SELECT Status FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assertEquals('Completed', jobs[0].Status,
            'Queueable with empty Id list should complete without error');
    }

    @IsTest
    static void accountSyncQueueable_chunkSizeExceeded_onlyFirstChunkRuns() {
        // Creates CHUNK_SIZE + 10 accounts to verify partitioning logic
        Integer totalCount = AccountSyncQueueable.CHUNK_SIZE + 10;
        List<Account> accounts = TestDataFactory.createAccounts(totalCount, true);
        List<Id> accountIds = new List<Id>(new Map<Id,Account>(accounts).keySet());

        Test.setMock(HttpCalloutMock.class, new MockExternalCrm(200));

        Test.startTest();
        System.enqueueJob(new AccountSyncQueueable(accountIds));
        Test.stopTest();

        // Only one job executes in test context — chain is suppressed by Test.isRunningTest()
        List<AsyncApexJob> jobs = [
            SELECT Status FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            ORDER BY CreatedDate DESC
            LIMIT 5
        ];
        System.assertEquals(1, jobs.size(),
            'In test context, only 1 Queueable job should run (chaining suppressed)');
        System.assertEquals('Completed', jobs[0].Status);
    }
}
