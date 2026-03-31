/**
 * @description Tests for getOpportunityMetrics — the imperative Apex method
 *              added in Day 9 for the opportunityMetricsTile LWC subscriber.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
@IsTest
private class AccountDashboardControllerDay9Test {

    @TestSetup
    static void makeData() {
        Account acc = new TestDataBuilder.AccountBuilder()
            .withName('Metrics Test Account')
            .withRevenue(1000000)
            .buildAndInsert();

        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        List<Opportunity> opps = new List<Opportunity>{
            new TestDataBuilder.OpportunityBuilder(acc.Id)
                .withName('Prospecting Opp')
                .withAmount(50000)
                .withStage('Prospecting')
                .build(),
            new TestDataBuilder.OpportunityBuilder(acc.Id)
                .withName('Qualification Opp')
                .withAmount(150000)
                .withStage('Qualification')
                .build(),
            new TestDataBuilder.OpportunityBuilder(acc.Id)
                .withName('Closed Won Opp')
                .withAmount(100000)
                .asClosedWon()
                .build()
        };
        insert opps;
    }

    @IsTest
    static void getMetrics_noFilter_returnsOpenOppsOnly() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        AccountDashboardController.MetricsWrapper result =
            AccountDashboardController.getOpportunityMetrics(acc.Id, 'All', 0);
        Test.stopTest();

        // Only 2 open Opps (Prospecting + Qualification); Closed Won excluded
        System.assertEquals(2, result.openCount,
            'Only open Opportunities should be counted');
        System.assertEquals(200000, result.totalPipeline,
            'Total pipeline = 50,000 + 150,000');
    }

    @IsTest
    static void getMetrics_stageFilter_returnsFilteredOpps() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        AccountDashboardController.MetricsWrapper result =
            AccountDashboardController.getOpportunityMetrics(acc.Id, 'Prospecting', 0);
        Test.stopTest();

        System.assertEquals(1, result.openCount,
            'Stage filter should return only Prospecting Opp');
        System.assertEquals(50000, result.totalPipeline,
            'Pipeline should be 50,000 for the Prospecting Opp only');
    }

    @IsTest
    static void getMetrics_minAmountFilter_excludesSmallOpps() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        AccountDashboardController.MetricsWrapper result =
            AccountDashboardController.getOpportunityMetrics(acc.Id, 'All', 100000);
        Test.stopTest();

        System.assertEquals(1, result.openCount,
            'Only the 150,000 Opp should exceed the 100,000 min threshold');
        System.assertEquals(150000, result.totalPipeline,
            'Pipeline = 150,000 (only Qualification Opp qualifies)');
    }

    @IsTest
    static void getMetrics_nullAccountId_returnsZeroWrapper() {
        Test.startTest();
        AccountDashboardController.MetricsWrapper result =
            AccountDashboardController.getOpportunityMetrics(null, 'All', 0);
        Test.stopTest();

        System.assertEquals(0, result.openCount, 'Null accountId should return 0 count');
        System.assertEquals(0, result.totalPipeline, 'Null accountId should return 0 pipeline');
    }

    @IsTest
    static void getMetrics_discountFieldsPopulated() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        // Prospecting Opp (50,000) → 5% TieredDiscount; Qualification (150,000) → 15%

        Test.startTest();
        AccountDashboardController.MetricsWrapper result =
            AccountDashboardController.getOpportunityMetrics(acc.Id, 'All', 0);
        Test.stopTest();

        System.assert(result.avgDiscount >= 0,
            'avgDiscount should be non-negative');
        System.assert(result.discountedPipeline >= 0,
            'discountedPipeline should be non-negative');
        System.assert(result.discountedPipeline <= result.totalPipeline,
            'discountedPipeline should not exceed totalPipeline');
    }
}
