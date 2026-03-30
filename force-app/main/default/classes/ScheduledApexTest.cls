/**
 * @description Tests for Scheduled Apex (AccountRatingScheduler, OpportunityRollupScheduler)
 *              and @future service (AccountFutureService).
 *
 *              Scheduled Apex testing rules:
 *                - System.schedule() inside Test.startTest() registers the job but does
 *                  not execute it. Query CronTrigger to assert registration.
 *                - To test the execute() logic directly: call scheduler.execute(null).
 *                  SchedulableContext is not used in our implementations so null is safe.
 *                - Always abort scheduled jobs in test teardown to avoid orphaned
 *                  CronTrigger records (they count against the 100-job org limit).
 *
 *              @future testing rules:
 *                - @future methods execute synchronously at Test.stopTest().
 *                - HttpCalloutMock must be registered before Test.startTest().
 *                - Cannot call @future from within another @future in tests.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
@IsTest
private class ScheduledApexTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountRatingScheduler
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void accountRatingScheduler_scheduleMe_registersCronTrigger() {
        Test.startTest();
        String jobId = AccountRatingScheduler.scheduleMe();
        Test.stopTest();

        System.assertNotEquals(null, jobId,
            'scheduleMe() should return a non-null CronTrigger Id');

        CronTrigger ct = [
            SELECT Id, CronExpression, State, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  Id = :jobId
        ];
        System.assertEquals(AccountRatingScheduler.DEFAULT_CRON, ct.CronExpression,
            'Registered cron expression should match DEFAULT_CRON constant');
        System.assertEquals('WAITING', ct.State,
            'Newly scheduled job should be in WAITING state');
        System.assertEquals(AccountRatingScheduler.JOB_NAME, ct.CronJobDetail.Name,
            'Job name should match JOB_NAME constant');

        // Cleanup — abort to avoid polluting org CronTrigger count
        System.abortJob(jobId);
    }

    @IsTest
    static void accountRatingScheduler_scheduleWith_usesCustomCron() {
        String customCron = '0 30 4 ? * MON-FRI'; // 4:30 AM weekdays only

        Test.startTest();
        String jobId = AccountRatingScheduler.scheduleWith(customCron);
        Test.stopTest();

        CronTrigger ct = [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId];
        System.assertEquals(customCron, ct.CronExpression,
            'scheduleWith() should register the provided custom cron expression');

        System.abortJob(jobId);
    }

    @IsTest
    static void accountRatingScheduler_execute_launchesBatchAndSetsRatings() {
        // Arrange
        List<Account> accounts = new List<Account>{
            TestDataFactory.createAccount(new Map<String,Object>{'AnnualRevenue'=>15000000}, true),
            TestDataFactory.createAccount(new Map<String,Object>{'AnnualRevenue'=>500000},   true)
        };

        Test.startTest();
        // Call execute() directly — SchedulableContext not used so null is safe
        new AccountRatingScheduler().execute(null);
        Test.stopTest();

        Map<Id, Account> results = new Map<Id, Account>(
            [SELECT Id, Rating FROM Account WHERE Id IN :new Map<Id,Account>(accounts).keySet()]
        );
        System.assertEquals('Hot',  results.get(accounts[0].Id).Rating, '15M account should be Hot');
        System.assertEquals('Cold', results.get(accounts[1].Id).Rating, '500K account should be Cold');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OpportunityRollupScheduler
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void opportunityRollupScheduler_scheduleMe_registersCronTrigger() {
        Test.startTest();
        String jobId = OpportunityRollupScheduler.scheduleMe();
        Test.stopTest();

        CronTrigger ct = [
            SELECT CronExpression, State, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  Id = :jobId
        ];
        System.assertEquals(OpportunityRollupScheduler.DEFAULT_CRON, ct.CronExpression,
            'Rollup scheduler cron should match DEFAULT_CRON');
        System.assertEquals('WAITING', ct.State);

        System.abortJob(jobId);
    }

    @IsTest
    static void opportunityRollupScheduler_execute_rollsUpRevenueCorrectly() {
        Account acc = TestDataFactory.createAccount(true);
        insert new List<Opportunity>{
            new Opportunity(AccountId=acc.Id, Name='O1', StageName='Closed Won',
                            CloseDate=Date.today(), Amount=40000),
            new Opportunity(AccountId=acc.Id, Name='O2', StageName='Closed Won',
                            CloseDate=Date.today(), Amount=60000)
        };

        Test.startTest();
        new OpportunityRollupScheduler().execute(null);
        Test.stopTest();

        Account result = [SELECT Total_Closed_Won_Revenue__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(100000, result.Total_Closed_Won_Revenue__c,
            'Scheduler should launch rollup batch which sums 40K + 60K = 100K');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountFutureService (@future)
    // ═══════════════════════════════════════════════════════════════════════════

    /** Mock SIC code service — returns 7372 (Prepackaged Software) for Technology */
    private class MockSicCodeService implements HttpCalloutMock {
        private Integer statusCode;

        public MockSicCodeService(Integer statusCode) {
            this.statusCode = statusCode;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            if (statusCode == 200) {
                res.setBody('{"sicCode":"7372","description":"Prepackaged Software"}');
            } else {
                res.setBody('{"error":"Service unavailable"}');
            }
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    @IsTest
    static void futureService_successfulCallout_populatesSicCode() {
        Account acc = TestDataFactory.createAccount(
            new Map<String,Object>{'Industry' => 'Technology'}, true
        );

        // Mock must be registered before startTest when testing @future callouts
        Test.setMock(HttpCalloutMock.class, new MockSicCodeService(200));

        Test.startTest();
        // @future executes synchronously at stopTest()
        AccountFutureService.enrichWithSicCode(new Set<Id>{ acc.Id });
        Test.stopTest();

        Account result = [SELECT Sic FROM Account WHERE Id = :acc.Id];
        System.assertEquals('7372', result.Sic,
            'Technology industry should receive SIC code 7372 from mock service');
    }

    @IsTest
    static void futureService_httpError_completesGracefully_noSicSet() {
        Account acc = TestDataFactory.createAccount(
            new Map<String,Object>{'Industry' => 'Technology'}, true
        );

        Test.setMock(HttpCalloutMock.class, new MockSicCodeService(503));

        Test.startTest();
        AccountFutureService.enrichWithSicCode(new Set<Id>{ acc.Id });
        Test.stopTest();

        Account result = [SELECT Sic FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, result.Sic,
            'HTTP 503 response should result in null Sic — no update attempted');
    }

    @IsTest
    static void futureService_accountWithNoIndustry_skippedByQuery() {
        // Account with no Industry — filtered out in the @future SOQL
        Account acc = TestDataFactory.createAccount(
            new Map<String,Object>{'Industry' => null}, true
        );

        Test.setMock(HttpCalloutMock.class, new MockSicCodeService(200));

        Test.startTest();
        AccountFutureService.enrichWithSicCode(new Set<Id>{ acc.Id });
        Test.stopTest();

        Account result = [SELECT Sic FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, result.Sic,
            'Account with null Industry should be excluded from enrichment query');
    }

    @IsTest
    static void futureService_triggeredViaInsert_handlerCallsFuture() {
        // End-to-end: insert Account with Industry → handler fires afterInsert → @future runs at stopTest
        Test.setMock(HttpCalloutMock.class, new MockSicCodeService(200));

        Test.startTest();
        Account acc = TestDataFactory.createAccount(
            new Map<String,Object>{'Industry' => 'Technology'}, true
        );
        Test.stopTest();

        Account result = [SELECT Sic FROM Account WHERE Id = :acc.Id];
        System.assertEquals('7372', result.Sic,
            'Trigger → afterInsert → @future chain should populate SIC on insert');
    }
}
