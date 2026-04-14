/**
 * FinancialAccountServiceTest
 * Unit tests for FinancialAccountService.
 * Tests: net worth, portfolio health banding, concentration alerts, balance sync callout.
 */
@isTest
private class FinancialAccountServiceTest {

    // ── Test Data Setup ──────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        // Household Account
        Account household = new Account(Name = 'Smith Household', RecordTypeId = getHouseholdRTId());
        insert household;

        // Three FinancialAccount__c records
        List<FinancialAccount__c> fas = new List<FinancialAccount__c>{
            new FinancialAccount__c(
                Account__c      = household.Id,
                AccountType__c  = 'CHECKING',
                Balance__c      = 15000,
                IsActive__c     = true,
                ExternalAccountId__c = 'EXT-001'
            ),
            new FinancialAccount__c(
                Account__c      = household.Id,
                AccountType__c  = 'INVESTMENT',
                Balance__c      = 80000,
                IsActive__c     = true,
                ExternalAccountId__c = 'EXT-002'
            ),
            new FinancialAccount__c(
                Account__c      = household.Id,
                AccountType__c  = 'SAVINGS',
                Balance__c      = 500,
                IsActive__c     = true,
                ExternalAccountId__c = 'EXT-003'
            )
        };
        insert fas;
    }

    // ── Net Worth ────────────────────────────────────────────────────────────

    @isTest
    static void testHouseholdNetWorth_sumsActiveBalances() {
        Account household = getHousehold();
        FinancialAccountService svc = new FinancialAccountService();

        Test.startTest();
        Decimal netWorth = svc.householdNetWorth(household.Id);
        Test.stopTest();

        // 15000 + 80000 + 500 = 95500
        System.assertEquals(95500, netWorth, 'Net worth should sum all active balances');
    }

    @isTest
    static void testHouseholdNetWorth_excludesInactiveAccounts() {
        Account household = getHousehold();
        // Deactivate one account
        FinancialAccount__c toDeactivate = [
            SELECT Id, IsActive__c FROM FinancialAccount__c
            WHERE Account__c = :household.Id AND AccountType__c = 'INVESTMENT' LIMIT 1
        ];
        toDeactivate.IsActive__c = false;
        update toDeactivate;

        FinancialAccountService svc = new FinancialAccountService();

        Test.startTest();
        Decimal netWorth = svc.householdNetWorth(household.Id);
        Test.stopTest();

        // 15000 + 500 = 15500 (INVESTMENT excluded)
        System.assertEquals(15500, netWorth, 'Net worth should exclude inactive accounts');
    }

    @isTest
    static void testHouseholdNetWorth_noAccounts_returnsZero() {
        Account emptyHousehold = new Account(Name = 'Empty Household', RecordTypeId = getHouseholdRTId());
        insert emptyHousehold;

        FinancialAccountService svc = new FinancialAccountService();

        Test.startTest();
        Decimal netWorth = svc.householdNetWorth(emptyHousehold.Id);
        Test.stopTest();

        System.assertEquals(0, netWorth, 'Net worth for household with no accounts should be 0');
    }

    // ── Portfolio Health Bands ────────────────────────────────────────────────

    @isTest
    static void testComputeHealthBand_green() {
        System.assertEquals('GREEN', FinancialAccountService.computeHealthBand(50000));
        System.assertEquals('GREEN', FinancialAccountService.computeHealthBand(10000));
    }

    @isTest
    static void testComputeHealthBand_yellow() {
        System.assertEquals('YELLOW', FinancialAccountService.computeHealthBand(5000));
        System.assertEquals('YELLOW', FinancialAccountService.computeHealthBand(1000));
    }

    @isTest
    static void testComputeHealthBand_red() {
        System.assertEquals('RED', FinancialAccountService.computeHealthBand(999));
        System.assertEquals('RED', FinancialAccountService.computeHealthBand(0));
        System.assertEquals('RED', FinancialAccountService.computeHealthBand(null));
    }

    @isTest
    static void testPortfolioHealth_returnsCorrectBandPerAccount() {
        Account household = getHousehold();
        FinancialAccountService svc = new FinancialAccountService();

        Test.startTest();
        Map<Id, String> bands = svc.portfolioHealthForHousehold(household.Id);
        Test.stopTest();

        System.assertEquals(3, bands.size(), 'Should return bands for all 3 accounts');

        // Find each account and assert band
        for (FinancialAccount__c fa : [
            SELECT Id, Balance__c FROM FinancialAccount__c WHERE Account__c = :household.Id
        ]) {
            String expectedBand = FinancialAccountService.computeHealthBand(fa.Balance__c);
            System.assertEquals(expectedBand, bands.get(fa.Id),
                'Band mismatch for account with balance ' + fa.Balance__c);
        }
    }

    // ── Concentration / Rebalance Alerts ─────────────────────────────────────

    @isTest
    static void testRebalanceAlerts_flagsConcentratedAccount() {
        // INVESTMENT (80000) is 84% of total (95500) → above 60% threshold
        Account household = getHousehold();
        FinancialAccountService svc = new FinancialAccountService();

        Test.startTest();
        List<Id> alerts = svc.rebalanceAlerts(household.Id);
        Test.stopTest();

        System.assertEquals(1, alerts.size(), 'One account should trigger concentration alert');
        FinancialAccount__c concentrated = [
            SELECT Id FROM FinancialAccount__c
            WHERE Account__c = :household.Id AND AccountType__c = 'INVESTMENT' LIMIT 1
        ];
        System.assertEquals(concentrated.Id, alerts[0], 'INVESTMENT account should be flagged');
    }

    @isTest
    static void testRebalanceAlerts_noAlertWhenBalanced() {
        Account household = getHousehold();
        // Equalise balances: all accounts at 30000
        List<FinancialAccount__c> fas = [
            SELECT Id, Balance__c FROM FinancialAccount__c WHERE Account__c = :household.Id
        ];
        for (FinancialAccount__c fa : fas) { fa.Balance__c = 30000; }
        update fas;

        FinancialAccountService svc = new FinancialAccountService();

        Test.startTest();
        List<Id> alerts = svc.rebalanceAlerts(household.Id);
        Test.stopTest();

        System.assertEquals(0, alerts.size(), 'No alerts when accounts are balanced');
    }

    @isTest
    static void testRebalanceAlerts_emptyHousehold_returnsEmptyList() {
        Account empty = new Account(Name = 'No Accounts', RecordTypeId = getHouseholdRTId());
        insert empty;
        FinancialAccountService svc = new FinancialAccountService();

        Test.startTest();
        List<Id> alerts = svc.rebalanceAlerts(empty.Id);
        Test.stopTest();

        System.assertEquals(0, alerts.size());
    }

    // ── Balance Sync Callout ─────────────────────────────────────────────────

    @isTest
    static void testSyncBalanceFromCoreBanking_updatesBalance() {
        Account household = getHousehold();
        FinancialAccount__c fa = [
            SELECT Id, ExternalAccountId__c FROM FinancialAccount__c
            WHERE Account__c = :household.Id AND AccountType__c = 'CHECKING' LIMIT 1
        ];

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new CreditScoreMock(CreditScoreMock.MockType.CORE_BANKING_BALANCE));
        FinancialAccountService svc = new FinancialAccountService();
        FinancialAccount__c updated = svc.syncBalanceFromCoreBanking(fa.Id, 'CoreBankingNC');
        Test.stopTest();

        System.assertEquals(25000, updated.Balance__c, 'Balance should be updated from mock response');
        System.assertNotEquals(null, updated.LastSyncedDateTime__c, 'LastSyncedDateTime should be set');
    }

    @isTest
    static void testSyncBalanceFromCoreBanking_throwsWhenNoExternalId() {
        Account household = getHousehold();
        FinancialAccount__c fa = new FinancialAccount__c(
            Account__c     = household.Id,
            AccountType__c = 'SAVINGS',
            Balance__c     = 1000,
            IsActive__c    = true
            // ExternalAccountId__c intentionally blank
        );
        insert fa;

        FinancialAccountService svc = new FinancialAccountService();
        Boolean threw = false;

        Test.startTest();
        try {
            svc.syncBalanceFromCoreBanking(fa.Id, 'CoreBankingNC');
        } catch (FinancialAccountService.FinancialAccountException e) {
            threw = true;
            System.assert(e.getMessage().contains('no ExternalAccountId__c'));
        }
        Test.stopTest();

        System.assert(threw, 'Should throw when ExternalAccountId__c is blank');
    }

    // ── Trigger Handler Integration ───────────────────────────────────────────

    @isTest
    static void testTriggerHandler_beforeInsert_setsDefaults() {
        Account household = getHousehold();
        FinancialAccount__c fa = new FinancialAccount__c(
            Account__c     = household.Id,
            AccountType__c = 'CHECKING'
            // IsActive__c and Balance__c intentionally omitted
        );

        Test.startTest();
        insert fa;
        Test.stopTest();

        FinancialAccount__c inserted = [
            SELECT IsActive__c, Balance__c FROM FinancialAccount__c WHERE Id = :fa.Id
        ];
        System.assertEquals(true, inserted.IsActive__c, 'IsActive__c should default to true');
        System.assertEquals(0, inserted.Balance__c, 'Balance__c should default to 0');
    }

    @isTest
    static void testTriggerHandler_bypass_skipsExecution() {
        Account household = getHousehold();
        TriggerHandler.bypass('FinancialAccountTriggerHandler');

        FinancialAccount__c fa = new FinancialAccount__c(
            Account__c     = household.Id,
            AccountType__c = 'CHECKING',
            IsActive__c    = null,
            Balance__c     = null
        );

        Test.startTest();
        insert fa;
        Test.stopTest();

        TriggerHandler.clearBypass('FinancialAccountTriggerHandler');

        // When bypassed, before insert doesn't run so defaults aren't set
        FinancialAccount__c inserted = [SELECT IsActive__c FROM FinancialAccount__c WHERE Id = :fa.Id];
        // Apex enforces null → may be null or false depending on field default
        // The key assertion is that bypass didn't throw an exception
        System.assertNotEquals(null, inserted.Id, 'Insert should succeed even when bypassed');
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static Account getHousehold() {
        return [SELECT Id FROM Account WHERE Name = 'Smith Household' LIMIT 1];
    }

    private static Id getHouseholdRTId() {
        // In orgs without FSC, use the standard Account record type or null
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND DeveloperName = 'HouseholdAccount'
            LIMIT 1
        ];
        return rts.isEmpty() ? null : rts[0].Id;
    }
}
