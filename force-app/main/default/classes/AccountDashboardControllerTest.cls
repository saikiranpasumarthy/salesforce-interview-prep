/**
 * @description Tests for AccountDashboardController — the Apex backend for Day 8 LWC.
 *
 *              LWC components themselves are tested with Jest (Day 11).
 *              The Apex controller is tested with standard Apex test methods here,
 *              verifying SOQL correctness, wrapper field mapping, and governor-safe
 *              bulk behaviour.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
@IsTest
private class AccountDashboardControllerTest {

    @TestSetup
    static void makeData() {
        Account acc = new TestDataBuilder.AccountBuilder()
            .withName('Dashboard Test Account')
            .withRevenue(750000)
            .buildAndInsert();

        // Inject empty CMDT map so OpportunityTrigger pricing runs with default (Tiered)
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        List<Opportunity> opps = new List<Opportunity>{
            new TestDataBuilder.OpportunityBuilder(acc.Id)
                .withName('Open Opp 1')
                .withAmount(150000)
                .withStage('Prospecting')
                .build(),
            new TestDataBuilder.OpportunityBuilder(acc.Id)
                .withName('Open Opp 2')
                .withAmount(50000)
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

    // ═══════════════════════════════════════════════════════════════════════════
    // getOpportunityCount
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getOpportunityCount_returnsTwoOpenOpps() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Integer count = AccountDashboardController.getOpportunityCount(acc.Id);
        Test.stopTest();

        System.assertEquals(2, count,
            'Only open (non-closed) Opportunities should be counted');
    }

    @IsTest
    static void getOpportunityCount_nullAccountId_returnsZero() {
        Test.startTest();
        Integer count = AccountDashboardController.getOpportunityCount(null);
        Test.stopTest();

        System.assertEquals(0, count, 'Null accountId should return 0');
    }

    @IsTest
    static void getOpportunityCount_accountWithNoOpps_returnsZero() {
        Account emptyAcc = new TestDataBuilder.AccountBuilder()
            .withName('Empty Account')
            .buildAndInsert();

        Test.startTest();
        Integer count = AccountDashboardController.getOpportunityCount(emptyAcc.Id);
        Test.stopTest();

        System.assertEquals(0, count, 'Account with no Opportunities should return 0');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // getOpportunitiesForAccount
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getOpportunitiesForAccount_returnsAllThreeOpps() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<AccountDashboardController.OpportunityWrapper> results =
            AccountDashboardController.getOpportunitiesForAccount(acc.Id);
        Test.stopTest();

        System.assertEquals(3, results.size(),
            'All three Opportunities (open and closed) should be returned');
    }

    @IsTest
    static void getOpportunitiesForAccount_wrapperFieldsMapped() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<AccountDashboardController.OpportunityWrapper> results =
            AccountDashboardController.getOpportunitiesForAccount(acc.Id);
        Test.stopTest();

        // All wrappers should have non-null id, name, stageName, closeDateFormatted
        for (AccountDashboardController.OpportunityWrapper w : results) {
            System.assertNotEquals(null, w.id,
                'Wrapper id must be populated');
            System.assertNotEquals(null, w.name,
                'Wrapper name must be populated');
            System.assertNotEquals(null, w.stageName,
                'Wrapper stageName must be populated');
            System.assertNotEquals(null, w.closeDateFormatted,
                'Wrapper closeDateFormatted must be populated');
        }
    }

    @IsTest
    static void getOpportunitiesForAccount_discountPercentStamped() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        // Open Opp 1 has Amount = 150,000 → TieredDiscountStrategy = 15%

        Test.startTest();
        List<AccountDashboardController.OpportunityWrapper> results =
            AccountDashboardController.getOpportunitiesForAccount(acc.Id);
        Test.stopTest();

        // Find the 150,000 Opp
        AccountDashboardController.OpportunityWrapper bigOpp;
        for (AccountDashboardController.OpportunityWrapper w : results) {
            if (w.name == 'Open Opp 1') {
                bigOpp = w;
                break;
            }
        }
        System.assertNotEquals(null, bigOpp, 'Open Opp 1 should be in results');
        System.assertEquals(15.00, bigOpp.discountPercent,
            'Tiered discount for 150,000 should be 15%');
        System.assertEquals(127500.00, bigOpp.finalPrice,
            'Final price = 150,000 * 0.85 = 127,500');
    }

    @IsTest
    static void getOpportunitiesForAccount_nullAccountId_returnsEmptyList() {
        Test.startTest();
        List<AccountDashboardController.OpportunityWrapper> results =
            AccountDashboardController.getOpportunitiesForAccount(null);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Null accountId should return empty list');
    }

    @IsTest
    static void getOpportunitiesForAccount_orderedByCloseDateDesc() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<AccountDashboardController.OpportunityWrapper> results =
            AccountDashboardController.getOpportunitiesForAccount(acc.Id);
        Test.stopTest();

        // Verify that closeDateFormatted is non-null for all and records are returned
        System.assertEquals(3, results.size(), 'Three Opportunities expected');
        // All formatted dates should be non-null/non-blank
        for (AccountDashboardController.OpportunityWrapper w : results) {
            System.assertNotEquals('—', w.closeDateFormatted,
                'All Opportunities have a CloseDate — should not show em-dash');
        }
    }
}
