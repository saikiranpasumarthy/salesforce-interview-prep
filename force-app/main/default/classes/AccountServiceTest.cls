/**
 * @description Test class for AccountService. Covers all three service methods with
 *              positive, negative, and bulk (200-record) scenarios.
 *
 *              Test isolation strategy:
 *                - setRatingFromRevenue tests use @TestVisible applyRatingFromRevenue()
 *                  with in-memory CMDT configs (no SOQL dependency on org CMDT records).
 *                - preventDelete and syncCaseOwner tests use DML since they require
 *                  real record Ids (after-context) and child record queries.
 *
 *              Coverage target: 90%+
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
@IsTest
private class AccountServiceTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // setRatingFromRevenue / applyRatingFromRevenue
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void applyRating_revenueAboveHotThreshold_setsHot() {
        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'AnnualRevenue' => 15000000 }, false
        );
        List<Account_Rating_Config__mdt> configs = TestDataFactory.getDefaultRatingConfigs();

        Test.startTest();
        AccountService.applyRatingFromRevenue(new List<Account>{ acc }, configs);
        Test.stopTest();

        System.assertEquals('Hot', acc.Rating,
            'Revenue of 15M (>= 10M threshold) should produce Hot rating');
    }

    @IsTest
    static void applyRating_revenueBetweenWarmAndHot_setsWarm() {
        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'AnnualRevenue' => 5000000 }, false
        );
        List<Account_Rating_Config__mdt> configs = TestDataFactory.getDefaultRatingConfigs();

        Test.startTest();
        AccountService.applyRatingFromRevenue(new List<Account>{ acc }, configs);
        Test.stopTest();

        System.assertEquals('Warm', acc.Rating,
            'Revenue of 5M (>= 1M but < 10M) should produce Warm rating');
    }

    @IsTest
    static void applyRating_revenueBelowAllThresholds_setsCold() {
        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'AnnualRevenue' => 500000 }, false
        );
        List<Account_Rating_Config__mdt> configs = TestDataFactory.getDefaultRatingConfigs();

        Test.startTest();
        AccountService.applyRatingFromRevenue(new List<Account>{ acc }, configs);
        Test.stopTest();

        System.assertEquals('Cold', acc.Rating,
            'Revenue of 500K (>= 0 threshold) should produce Cold rating');
    }

    @IsTest
    static void applyRating_nullRevenue_ratingUnchanged() {
        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'AnnualRevenue' => null, 'Rating' => 'Warm' }, false
        );
        List<Account_Rating_Config__mdt> configs = TestDataFactory.getDefaultRatingConfigs();

        Test.startTest();
        AccountService.applyRatingFromRevenue(new List<Account>{ acc }, configs);
        Test.stopTest();

        System.assertEquals('Warm', acc.Rating,
            'Null AnnualRevenue should leave existing Rating unchanged');
    }

    @IsTest
    static void applyRating_emptyConfigList_noRatingSet() {
        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'AnnualRevenue' => 5000000 }, false
        );

        Test.startTest();
        AccountService.applyRatingFromRevenue(
            new List<Account>{ acc },
            new List<Account_Rating_Config__mdt>()
        );
        Test.stopTest();

        System.assertEquals(null, acc.Rating,
            'Empty config list should leave Rating as null');
    }

    @IsTest
    static void applyRating_bulk200Records_allRatingsAssigned() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accounts.add(TestDataFactory.createAccount(
                new Map<String, Object>{ 'AnnualRevenue' => 1000000 * (i + 1) }, false
            ));
        }
        List<Account_Rating_Config__mdt> configs = TestDataFactory.getDefaultRatingConfigs();

        Test.startTest();
        AccountService.applyRatingFromRevenue(accounts, configs);
        Test.stopTest();

        for (Account acc : accounts) {
            System.assertNotEquals(null, acc.Rating,
                'Every account with AnnualRevenue set should receive a Rating');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // preventDeleteWithOpenOpportunities
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void preventDelete_openOppExists_deleteFails() {
        Account acc = TestDataFactory.createAccount(true);
        TestDataFactory.createOpportunity(acc.Id, false, true);

        Test.startTest();
        Database.DeleteResult result = Database.delete(acc, false);
        Test.stopTest();

        System.assert(!result.isSuccess(),
            'Delete should fail when account has at least one open opportunity');
        System.assert(
            result.getErrors()[0].getMessage().contains('open opportunity'),
            'Error message should reference open opportunities'
        );
    }

    @IsTest
    static void preventDelete_onlyClosedOpps_deleteSucceeds() {
        Account acc = TestDataFactory.createAccount(true);
        TestDataFactory.createOpportunity(acc.Id, true, true); // Closed Won

        Test.startTest();
        Database.DeleteResult result = Database.delete(acc, false);
        Test.stopTest();

        System.assert(result.isSuccess(),
            'Delete should succeed when all related opportunities are closed');
    }

    @IsTest
    static void preventDelete_noOpps_deleteSucceeds() {
        Account acc = TestDataFactory.createAccount(true);

        Test.startTest();
        Database.DeleteResult result = Database.delete(acc, false);
        Test.stopTest();

        System.assert(result.isSuccess(),
            'Delete should succeed when account has no opportunities at all');
    }

    @IsTest
    static void preventDelete_bulk200Accounts_allBlockedWithOpenOpps() {
        List<Account> accounts = TestDataFactory.createAccounts(200, true);

        List<Opportunity> opps = new List<Opportunity>();
        for (Account acc : accounts) {
            opps.add(new Opportunity(
                Name      = 'Bulk Open Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            ));
        }
        insert opps;

        Test.startTest();
        List<Database.DeleteResult> results = Database.delete(accounts, false);
        Test.stopTest();

        Integer failCount = 0;
        for (Database.DeleteResult dr : results) {
            if (!dr.isSuccess()) { failCount++; }
        }
        System.assertEquals(200, failCount,
            'All 200 deletes should be blocked — each account has an open opportunity');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // syncCaseOwnerOnAccountOwnerChange
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void syncCaseOwner_ownerChanges_openCasesUpdated() {
        User originalOwner = TestDataFactory.createUser('Standard User', true);
        User newOwner      = TestDataFactory.createUser('Standard User', true);

        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'OwnerId' => originalOwner.Id }, true
        );
        Case openCase = TestDataFactory.createCase(acc.Id, originalOwner.Id, true);

        Test.startTest();
        acc.OwnerId = newOwner.Id;
        update acc;
        Test.stopTest();

        Case result = [SELECT OwnerId FROM Case WHERE Id = :openCase.Id];
        System.assertEquals(newOwner.Id, result.OwnerId,
            'Open case owner should match the new account owner after sync');
    }

    @IsTest
    static void syncCaseOwner_closedCaseNotUpdated() {
        User originalOwner = TestDataFactory.createUser('Standard User', true);
        User newOwner      = TestDataFactory.createUser('Standard User', true);

        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'OwnerId' => originalOwner.Id }, true
        );
        Case closedCase = new Case(
            AccountId = acc.Id,
            Subject   = 'Closed Case',
            Status    = 'Closed',
            OwnerId   = originalOwner.Id
        );
        insert closedCase;

        Test.startTest();
        acc.OwnerId = newOwner.Id;
        update acc;
        Test.stopTest();

        Case result = [SELECT OwnerId FROM Case WHERE Id = :closedCase.Id];
        System.assertEquals(originalOwner.Id, result.OwnerId,
            'Closed cases should NOT be updated when account owner changes');
    }

    @IsTest
    static void syncCaseOwner_ownerUnchanged_caseOwnerPreserved() {
        Account acc       = TestDataFactory.createAccount(true);
        Case openCase     = TestDataFactory.createCase(acc.Id, UserInfo.getUserId(), true);

        Test.startTest();
        acc.Name = 'Name-Only Update';
        update acc;
        Test.stopTest();

        Case result = [SELECT OwnerId FROM Case WHERE Id = :openCase.Id];
        System.assertEquals(UserInfo.getUserId(), result.OwnerId,
            'Case owner must not change when only non-owner fields change on the account');
    }

    @IsTest
    static void syncCaseOwner_bulk200Accounts_allOpenCasesUpdated() {
        User originalOwner = TestDataFactory.createUser('Standard User', true);
        User newOwner      = TestDataFactory.createUser('Standard User', true);

        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accounts.add(new Account(
                Name    = 'Bulk Account ' + i,
                OwnerId = originalOwner.Id
            ));
        }
        insert accounts;

        List<Case> cases = new List<Case>();
        for (Account acc : accounts) {
            cases.add(new Case(
                AccountId = acc.Id,
                Subject   = 'Bulk Case',
                Status    = 'New',
                OwnerId   = originalOwner.Id
            ));
        }
        insert cases;

        Test.startTest();
        for (Account acc : accounts) {
            acc.OwnerId = newOwner.Id;
        }
        update accounts; // single DML — trigger fires once with all 200 in Trigger.new
        Test.stopTest();

        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();
        List<Case> updatedCases = [
            SELECT OwnerId FROM Case WHERE AccountId IN :accountIds
        ];
        System.assertEquals(200, updatedCases.size(), 'Expect 200 cases to be returned');
        for (Case c : updatedCases) {
            System.assertEquals(newOwner.Id, c.OwnerId,
                'Every open case should reflect the new account owner');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountDomain.validateTypeDowngrade
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validateTypeDowngrade_withClosedWonOpp_downgradeBlocked() {
        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'Type' => 'Customer' }, true
        );
        TestDataFactory.createOpportunity(acc.Id, true, true); // Closed Won

        Test.startTest();
        acc.Type = 'Prospect';
        Database.SaveResult result = Database.update(acc, false);
        Test.stopTest();

        System.assert(!result.isSuccess(),
            'Downgrade Customer → Prospect should fail when Closed Won opps exist');
        System.assert(
            result.getErrors()[0].getMessage().contains('Closed Won'),
            'Error message should mention Closed Won opportunities'
        );
    }

    @IsTest
    static void validateTypeDowngrade_noClosedWonOpp_downgradeAllowed() {
        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'Type' => 'Customer' }, true
        );
        // No Closed Won opps — open opp only
        TestDataFactory.createOpportunity(acc.Id, false, true);

        Test.startTest();
        acc.Type = 'Prospect';
        Database.SaveResult result = Database.update(acc, false);
        Test.stopTest();

        System.assert(result.isSuccess(),
            'Downgrade should succeed when no Closed Won opportunities exist');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TriggerHandler bypass mechanism
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void triggerHandlerBypass_handlerBypassed_noServiceExecution() {
        TriggerHandler.bypass('AccountTriggerHandler');

        Account acc = TestDataFactory.createAccount(
            new Map<String, Object>{ 'AnnualRevenue' => 20000000 }, true
        );

        TriggerHandler.clearBypass('AccountTriggerHandler');

        // Rating should not have been auto-set because handler was bypassed at insert
        Account inserted = [SELECT Rating FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, inserted.Rating,
            'Rating should remain null when AccountTriggerHandler is bypassed');
    }
}
