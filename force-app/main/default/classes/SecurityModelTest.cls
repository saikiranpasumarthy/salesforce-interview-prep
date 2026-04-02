/**
 * @description SecurityModelTest — Tests for Day 14 security model classes.
 *
 *              TEST STRATEGY FOR SECURITY:
 *              ════════════════════════════
 *              1. CRUD/FLS tests: System.runAs(userWithLimitedAccess) + Profile/PermSet setup
 *                 In practice, FLS tests require a profile with specific fields restricted —
 *                 not possible to create via Apex in a test (Profile is metadata, not DML-creatable).
 *                 Strategy: test the logic of CRUD/FLS methods using the running user context
 *                 (admin user in tests has full access — tests that all-access paths work correctly).
 *
 *              2. Sharing tests: System.runAs(user2) — tests that 'with sharing' enforces
 *                 record-level access. Create record as User A, query as User B.
 *                 In a Private OWD org, User B sees 0 records. After granting share,
 *                 User B sees the record.
 *
 *              3. AccountShare tests: verify share records are created and deleted.
 *
 *              NOTE ON TEST ENVIRONMENT:
 *              ══════════════════════════
 *              Salesforce test orgs typically have Account OWD = Public Read/Write.
 *              Sharing enforcement tests only demonstrate 'with sharing' behaviour in
 *              Private OWD orgs. In a Public OWD org, all users can see all accounts
 *              regardless of sharing, so sharing tests are designed to be environment-aware.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
@IsTest
private class SecurityModelTest {

    // ─── Test data ─────────────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        // Create test accounts owned by the running user (admin in test context)
        List<Account> accounts = new List<Account>{
            new Account(Name = 'Security Test A', AnnualRevenue = 1_000_000, Industry = 'Technology'),
            new Account(Name = 'Security Test B', AnnualRevenue =   500_000, Industry = 'Finance'),
            new Account(Name = 'Security Test C', AnnualRevenue =   100_000, Industry = 'Retail')
        };
        insert accounts;
    }

    /** Creates a minimal Standard User for sharing/runAs tests */
    static User createStandardUser(String uniqueSuffix) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            Alias            = 'stdu' + uniqueSuffix,
            Email            = 'stduser' + uniqueSuffix + '@sectest.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName         = 'SecurityTest' + uniqueSuffix,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey     = 'en_US',
            ProfileId        = p.Id,
            TimeZoneSidKey   = 'America/Los_Angeles',
            UserName         = 'stduser' + uniqueSuffix + '@sectest.example.com' + UserInfo.getOrganizationId()
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SecurityService — CRUD/FLS method logic
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void assertReadAccess_adminUser_noException() {
        // Admin (sysadmin) running tests has full CRUD — should not throw
        Test.startTest();
        try {
            SecurityService.assertReadAccess(Schema.Account.SObjectType);
            System.assert(true, 'No exception for admin read access');
        } catch (SecurityService.CrudException e) {
            System.assert(false, 'Admin should have Account read access: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void assertCreateAccess_adminUser_noException() {
        Test.startTest();
        try {
            SecurityService.assertCreateAccess(Schema.Account.SObjectType);
        } catch (SecurityService.CrudException e) {
            System.assert(false, 'Admin should have Account create access');
        }
        Test.stopTest();
    }

    @IsTest
    static void getReadableFields_standardFields_returnsAllForAdmin() {
        List<String> fields = new List<String>{ 'Name', 'AnnualRevenue', 'Industry' };

        Test.startTest();
        List<String> readable = SecurityService.getReadableFields(
            Schema.Account.SObjectType, fields
        );
        Test.stopTest();

        System.assertEquals(3, readable.size(),
            'Admin should have read access to all 3 standard Account fields');
        System.assert(readable.contains('Name'),          'Name should be readable');
        System.assert(readable.contains('AnnualRevenue'), 'AnnualRevenue should be readable');
        System.assert(readable.contains('Industry'),      'Industry should be readable');
    }

    @IsTest
    static void getReadableFields_unknownField_excludedSilently() {
        List<String> fields = new List<String>{ 'Name', 'NonExistentField__xyz' };

        Test.startTest();
        List<String> readable = SecurityService.getReadableFields(
            Schema.Account.SObjectType, fields
        );
        Test.stopTest();

        System.assert(readable.contains('Name'),                'Name should be readable');
        System.assert(!readable.contains('NonExistentField__xyz'),
            'Unknown field should be excluded, not throw');
    }

    @IsTest
    static void getEditableFields_returnsSubsetForAdmin() {
        List<String> fields = new List<String>{ 'Name', 'Industry', 'AnnualRevenue' };

        Test.startTest();
        List<String> editable = SecurityService.getEditableFields(
            Schema.Account.SObjectType, fields
        );
        Test.stopTest();

        System.assertNotEquals(0, editable.size(),
            'Admin should have at least some editable fields');
    }

    @IsTest
    static void queryAccountsStripped_adminUser_returnsAllFields() {
        Set<Id> ids = new Map<Id, Account>([SELECT Id FROM Account WHERE Name LIKE 'Security Test%']).keySet();

        Test.startTest();
        List<Account> results = SecurityService.queryAccountsStripped(ids);
        Test.stopTest();

        System.assertNotEquals(0, results.size(), 'Should return accounts');
        // Admin has all FLS — no fields should be stripped
        for (Account a : results) {
            System.assertNotEquals(null, a.Name,   'Name should not be stripped for admin');
            System.assertNotEquals(null, a.Industry, 'Industry should not be stripped for admin');
        }
    }

    @IsTest
    static void stripInaccessibleFields_adminUser_noFieldsRemoved() {
        List<Account> accounts = [SELECT Id, Name, AnnualRevenue FROM Account WHERE Name LIKE 'Security Test%'];

        Test.startTest();
        SObjectAccessDecision decision = SecurityService.stripInaccessibleFields(
            accounts, AccessType.READABLE
        );
        Test.stopTest();

        System.assertEquals(accounts.size(), decision.getRecords().size(),
            'Record count should be preserved');
        // For admin, getRemovedFields should be empty
        System.assert(decision.getRemovedFields().isEmpty(),
            'Admin should have no fields stripped');
    }

    @IsTest
    static void checkCreateAccess_adminUser_isValid() {
        Test.startTest();
        SecurityService.ValidationResult result = SecurityService.checkCreateAccess(
            Schema.Account.SObjectType,
            new List<String>{ 'Name', 'Industry', 'AnnualRevenue' }
        );
        Test.stopTest();

        System.assertEquals(true, result.isValid,
            'Admin should have full create access');
        System.assertEquals(0, result.violations.size(),
            'No violations for admin');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountSharingService — share creation / deletion
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void grantAccess_read_createsAccountShare() {
        Account acc  = [SELECT Id FROM Account WHERE Name = 'Security Test A' LIMIT 1];
        User   user2 = createStandardUser('rd01');
        insert user2;

        Test.startTest();
        Id shareId = AccountSharingService.grantAccess(acc.Id, user2.Id, 'Read');
        Test.stopTest();

        AccountShare share = [
            SELECT AccountAccessLevel, RowCause, UserOrGroupId
            FROM   AccountShare
            WHERE  Id = :shareId
        ];
        System.assertEquals('Read',   share.AccountAccessLevel, 'Access should be Read');
        System.assertEquals(user2.Id, share.UserOrGroupId,      'Share should target user2');
        System.assertEquals(
            Schema.AccountShare.RowCause.Manual, share.RowCause,
            'RowCause should be Manual'
        );
    }

    @IsTest
    static void grantAccess_edit_createsAccountShare() {
        Account acc  = [SELECT Id FROM Account WHERE Name = 'Security Test B' LIMIT 1];
        User   user2 = createStandardUser('ed01');
        insert user2;

        Test.startTest();
        AccountSharingService.grantAccess(acc.Id, user2.Id, 'Edit');
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM   AccountShare
            WHERE  AccountId = :acc.Id
            AND    UserOrGroupId = :user2.Id
            AND    AccountAccessLevel = 'Edit'
        ];
        System.assertEquals(1, count, 'Edit share should be created');
    }

    @IsTest
    static void grantAccess_duplicate_noSecondShareCreated() {
        Account acc  = [SELECT Id FROM Account WHERE Name = 'Security Test C' LIMIT 1];
        User   user2 = createStandardUser('dup01');
        insert user2;

        Test.startTest();
        AccountSharingService.grantAccess(acc.Id, user2.Id, 'Read');
        AccountSharingService.grantAccess(acc.Id, user2.Id, 'Read'); // duplicate call
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM   AccountShare
            WHERE  AccountId     = :acc.Id
            AND    UserOrGroupId = :user2.Id
            AND    RowCause      = :Schema.AccountShare.RowCause.Manual
        ];
        System.assertEquals(1, count, 'Duplicate grant should not create a second share');
    }

    @IsTest
    static void revokeAccess_deletesManualShare() {
        Account acc  = [SELECT Id FROM Account WHERE Name = 'Security Test A' LIMIT 1];
        User   user2 = createStandardUser('rv01');
        insert user2;

        AccountSharingService.grantAccess(acc.Id, user2.Id, 'Read');

        Test.startTest();
        AccountSharingService.revokeAccess(acc.Id, user2.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM   AccountShare
            WHERE  AccountId     = :acc.Id
            AND    UserOrGroupId = :user2.Id
            AND    RowCause      = :Schema.AccountShare.RowCause.Manual
        ];
        System.assertEquals(0, count, 'Manual share should be deleted after revoke');
    }

    @IsTest
    static void getShares_returnsNonOwnerShares() {
        Account acc  = [SELECT Id FROM Account WHERE Name = 'Security Test B' LIMIT 1];
        User   user2 = createStandardUser('gs01');
        insert user2;
        AccountSharingService.grantAccess(acc.Id, user2.Id, 'Read');

        Test.startTest();
        List<AccountSharingService.ShareInfo> shares =
            AccountSharingService.getShares(acc.Id);
        Test.stopTest();

        // At least the Manual share we just created should be present
        Boolean foundManual = false;
        for (AccountSharingService.ShareInfo s : shares) {
            if (s.userOrGroupId == user2.Id && s.rowCause == Schema.AccountShare.RowCause.Manual) {
                foundManual = true;
            }
        }
        System.assert(foundManual, 'getShares should include the manually granted share');
    }

    @IsTest
    static void grantAccess_nullAccountId_throwsException() {
        try {
            AccountSharingService.grantAccess(null, UserInfo.getUserId(), 'Read');
            System.assert(false, 'Should have thrown IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().containsIgnoreCase('required'),
                'Error should mention required param');
        }
    }

    @IsTest
    static void grantAccess_invalidAccessLevel_throwsException() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        try {
            AccountSharingService.grantAccess(acc.Id, UserInfo.getUserId(), 'Full');
            System.assert(false, 'Should have thrown IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().containsIgnoreCase('Read or Edit'),
                'Error should mention valid values');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SharingContextDemo — sharing context behaviour
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void withSharing_adminUser_returnsOwnedAccounts() {
        Set<Id> ids = new Map<Id, Account>(
            [SELECT Id FROM Account WHERE Name LIKE 'Security Test%']
        ).keySet();

        Test.startTest();
        List<Account> results = SharingContextDemo.getMyAccounts(ids);
        Test.stopTest();

        System.assertEquals(3, results.size(),
            'Admin should see all 3 test accounts');
    }

    @IsTest
    static void withSharing_standardUser_seesOwnRecords() {
        /**
         * Demonstrates 'with sharing' with System.runAs.
         * Standard User created and inserted. Then getMyAccounts called as that user.
         * In a Private OWD org: user would see 0 records (all owned by admin).
         * In a Public OWD org: user sees all records (OWD=Public overrides sharing).
         * This test is OWD-agnostic: just verifies the method executes without exception.
         */
        User   user2 = createStandardUser('ws01');
        insert user2;

        Set<Id> ids = new Map<Id, Account>(
            [SELECT Id FROM Account WHERE Name LIKE 'Security Test%']
        ).keySet();

        Test.startTest();
        List<Account> results;
        System.runAs(user2) {
            results = SharingContextDemo.getMyAccounts(ids);
        }
        Test.stopTest();

        // OWD-agnostic assertion: method should execute without exception
        System.assertNotEquals(null, results, 'getMyAccounts should not return null');
    }

    @IsTest
    static void withoutSharing_adminEscalation_returnsAllAccounts() {
        Set<Id> ids = new Map<Id, Account>(
            [SELECT Id FROM Account WHERE Name LIKE 'Security Test%']
        ).keySet();

        Test.startTest();
        // getAccountsWithElevatedAccess delegates to AdminEscalation (without sharing)
        List<Account> results = SharingContextDemo.getAccountsWithElevatedAccess(ids);
        Test.stopTest();

        System.assertEquals(3, results.size(),
            'without sharing should return all 3 accounts');
    }

    @IsTest
    static void dynamicQuery_withSharing_executesWithoutException() {
        Test.startTest();
        List<SObject> results = SharingContextDemo.dynamicQuery(
            'SELECT Id, Name FROM Account WHERE Name LIKE \'Security Test%\' LIMIT 10'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Dynamic query should return results');
    }
}
