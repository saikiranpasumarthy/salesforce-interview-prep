/**
 * @description Tests for LoyaltyMemberTriggerHandler → LoyaltyMemberService
 *              and TierManagementService (trigger-driven paths).
 *
 *              Coverage targets (85%+):
 *                LoyaltyMemberTriggerHandler — 100%
 *                LoyaltyMemberService.initializeMemberLedger — 100%
 *                TierManagementService.evaluateTierChange — 90%+
 *
 *              Test strategy:
 *                • @testSetup creates a Contact and Loyalty Program record shared
 *                  across all tests — avoids repeat DML overhead.
 *                • Trigger fires naturally on insert/update — full stack tested.
 *                • Bulk test at 200 members verifies no governor limit violations.
 *                • Tier evaluation test checks only fires when points change —
 *                  guards against unnecessary DML on unrelated field updates.
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
@isTest
private class LoyaltyMemberTriggerHandlerTest {

    static final Integer BULK_SIZE = 200;

    // ── Shared test data ──────────────────────────────────────────────────────
    @testSetup
    static void setup() {
        // Contact for enrollment tests
        Contact c = new Contact(
            FirstName = 'Test',
            LastName  = 'LoyaltyMember',
            Email     = 'loyalty.test@example.com'
        );
        insert c;
    }

    static Contact getContact() {
        return [SELECT Id, Email FROM Contact WHERE LastName = 'LoyaltyMember' LIMIT 1];
    }

    static LoyaltyProgramMember__c insertMember(Id contactId, Decimal balance) {
        LoyaltyProgramMember__c m = new LoyaltyProgramMember__c(
            Contact__c        = contactId,
            Current_Tier__c   = 'Silver',
            Member_Number__c  = 'LM2025' + String.valueOf(Math.mod(Math.abs(Crypto.getRandomInteger()), 999999)).leftPad(6,'0'),
            Points_Balance__c = balance,
            Annual_Points__c  = balance,
            Lifetime_Points__c = balance,
            Member_Status__c  = 'Active',
            Enrollment_Date__c = Date.today()
        );
        insert m;
        return m;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — initializeMemberLedger: currency records created on insert
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testInitializeLedger_onMemberInsert() {
        Contact c = getContact();

        Test.startTest();
        LoyaltyProgramMember__c member = insertMember(c.Id, 0);
        Test.stopTest();

        List<Loyalty_Member_Currency__c> currencies = [
            SELECT Id, Currency_Type__c, Points_Balance__c
            FROM   Loyalty_Member_Currency__c
            WHERE  Loyalty_Program_Member__c = :member.Id
            ORDER BY Currency_Type__c
        ];

        System.assertEquals(2, currencies.size(),
            'Two currency records (Base and Bonus) should be created on member insert.');

        Set<String> types = new Set<String>();
        for (Loyalty_Member_Currency__c curr : currencies) {
            types.add(curr.Currency_Type__c);
            System.assertEquals(0, curr.Points_Balance__c,
                'Initial points balance should be 0 for currency type: ' + curr.Currency_Type__c);
        }
        System.assert(types.contains('Base'),  'Base currency record should exist.');
        System.assert(types.contains('Bonus'), 'Bonus currency record should exist.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — initializeMemberLedger: bulk 200 members — no governor limit breach
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testInitializeLedger_bulk200Members() {
        // Create 200 contacts
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < BULK_SIZE; i++) {
            contacts.add(new Contact(
                FirstName = 'Bulk',
                LastName  = 'Member' + i,
                Email     = 'bulk' + i + '@example.com'
            ));
        }
        insert contacts;

        // Build 200 member records
        List<LoyaltyProgramMember__c> members = new List<LoyaltyProgramMember__c>();
        for (Integer i = 0; i < BULK_SIZE; i++) {
            members.add(new LoyaltyProgramMember__c(
                Contact__c         = contacts[i].Id,
                Current_Tier__c    = 'Silver',
                Member_Number__c   = 'LM2025' + String.valueOf(i).leftPad(6, '0'),
                Points_Balance__c  = 0,
                Annual_Points__c   = 0,
                Lifetime_Points__c = 0,
                Member_Status__c   = 'Active',
                Enrollment_Date__c = Date.today()
            ));
        }

        Test.startTest();
        insert members;
        Test.stopTest();

        Integer currencyCount = [
            SELECT COUNT() FROM Loyalty_Member_Currency__c
            WHERE Loyalty_Program_Member__c IN :members
        ];

        // Each member gets Base + Bonus = 2 per member
        System.assertEquals(BULK_SIZE * 2, currencyCount,
            'Expected ' + (BULK_SIZE * 2) + ' currency records for ' + BULK_SIZE +
            ' members. Got: ' + currencyCount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — evaluateTierChange: tier upgrade fires when points cross threshold
    //
    // Member at 900 pts (Silver) → update to 1100 pts → should upgrade to Gold.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testTierEvaluation_triggersOnPointsChange() {
        Contact c  = getContact();
        // Start below Gold threshold (default: 1000)
        LoyaltyProgramMember__c member = insertMember(c.Id, 900);

        Test.startTest();
        member.Points_Balance__c = 1100;   // crosses Gold threshold
        member.Annual_Points__c  = 1100;
        update member;
        Test.stopTest();

        LoyaltyProgramMember__c result = [
            SELECT Current_Tier__c FROM LoyaltyProgramMember__c WHERE Id = :member.Id
        ];
        System.assertEquals('Gold', result.Current_Tier__c,
            'Member should be upgraded to Gold after crossing 1000-point threshold.');

        // Verify Tier_Change_Log__c was created
        List<Tier_Change_Log__c> logs = [
            SELECT Old_Tier__c, New_Tier__c, Change_Reason__c
            FROM   Tier_Change_Log__c
            WHERE  Loyalty_Program_Member__c = :member.Id
        ];
        System.assertEquals(1, logs.size(), 'One Tier_Change_Log__c should be created.');
        System.assertEquals('Silver', logs[0].Old_Tier__c, 'Old tier should be Silver.');
        System.assertEquals('Gold',   logs[0].New_Tier__c, 'New tier should be Gold.');
        System.assert(logs[0].Change_Reason__c.containsIgnoreCase('Upgrade'),
            'Change reason should mention Upgrade.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — evaluateTierChange: does NOT fire when unrelated field updated
    //
    // Update Member_Status__c (no points change) → no tier change log created.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testTierEvaluation_noFireWhenPointsUnchanged() {
        Contact c = getContact();
        LoyaltyProgramMember__c member = insertMember(c.Id, 500);

        Test.startTest();
        // Update a non-points field — tier evaluation should NOT fire
        member.Enrollment_Source__c = 'InStore';
        update member;
        Test.stopTest();

        Integer logCount = [
            SELECT COUNT() FROM Tier_Change_Log__c
            WHERE Loyalty_Program_Member__c = :member.Id
        ];
        System.assertEquals(0, logCount,
            'No Tier_Change_Log__c should be created when points did not change.');
    }
}
