/**
 * @description Centralised test data factory. A single source of truth for all test
 *              record creation across the entire test suite. Prevents duplicated setup
 *              logic and ensures consistent field values across test classes.
 *
 *              Design rules:
 *                - All methods accept an overrides Map so callers can change specific
 *                  fields without needing a separate factory method per variation.
 *                - doInsert=false for unit tests (no DML, faster); true for integration tests.
 *                - Static userCounter prevents username collisions when creating multiple
 *                  users in the same transaction (System.currentTimeMillis() can collide).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
@IsTest
public class TestDataFactory {

    private static Integer userCounter = 0;

    // ─── Account ──────────────────────────────────────────────────────────────

    public static Account createAccount(Boolean doInsert) {
        return createAccount(new Map<String, Object>(), doInsert);
    }

    public static Account createAccount(Map<String, Object> overrides, Boolean doInsert) {
        Account acc = new Account(
            Name          = 'Test Account',
            AnnualRevenue = 1000000,
            Industry      = 'Technology',
            Type          = 'Prospect',
            OwnerId       = UserInfo.getUserId()
        );
        for (String field : overrides.keySet()) {
            acc.put(field, overrides.get(field));
        }
        if (doInsert) { insert acc; }
        return acc;
    }

    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(
                Name          = 'Test Account ' + i,
                AnnualRevenue = 500000 * (i + 1),
                Industry      = 'Technology',
                Type          = 'Prospect',
                OwnerId       = UserInfo.getUserId()
            ));
        }
        if (doInsert) { insert accounts; }
        return accounts;
    }

    // ─── Opportunity ─────────────────────────────────────────────────────────

    public static Opportunity createOpportunity(Id accountId, Boolean isClosed, Boolean doInsert) {
        Opportunity opp = new Opportunity(
            Name      = 'Test Opportunity',
            AccountId = accountId,
            StageName = isClosed ? 'Closed Won' : 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        if (doInsert) { insert opp; }
        return opp;
    }

    // ─── Case ─────────────────────────────────────────────────────────────────

    public static Case createCase(Id accountId, Id ownerId, Boolean doInsert) {
        Case c = new Case(
            AccountId = accountId,
            Subject   = 'Test Case',
            Status    = 'New',
            OwnerId   = ownerId
        );
        if (doInsert) { insert c; }
        return c;
    }

    // ─── User ─────────────────────────────────────────────────────────────────

    public static User createUser(String profileName, Boolean doInsert) {
        userCounter++;
        Profile p = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        User u = new User(
            FirstName          = 'Test',
            LastName           = 'User' + userCounter,
            Email              = 'sfdc.test.user' + userCounter + '@example.invalid',
            Username           = 'sfdc.test.user' + userCounter + '@example.invalid',
            Alias              = 'tu' + userCounter,
            TimeZoneSidKey     = 'America/Los_Angeles',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id
        );
        if (doInsert) { insert u; }
        return u;
    }

    // ─── Custom Metadata helpers (test-only config injection) ─────────────────

    /**
     * @description Builds in-memory Account_Rating_Config__mdt records for unit tests.
     *              Bypasses SOQL so tests are not dependent on CMDT records in the org.
     *              Mirrors the production records deployed in customMetadata/.
     */
    public static List<Account_Rating_Config__mdt> getDefaultRatingConfigs() {
        return new List<Account_Rating_Config__mdt>{
            new Account_Rating_Config__mdt(
                Revenue_Threshold__c = 10000000,
                Rating_Value__c      = 'Hot'
            ),
            new Account_Rating_Config__mdt(
                Revenue_Threshold__c = 1000000,
                Rating_Value__c      = 'Warm'
            ),
            new Account_Rating_Config__mdt(
                Revenue_Threshold__c = 0,
                Rating_Value__c      = 'Cold'
            )
        };
    }
}
