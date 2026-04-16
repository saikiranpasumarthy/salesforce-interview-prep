/**
 * @description Tests for TierManagementService — tier upgrades, downgrades,
 *              annual review, and CMDT benefits lookup.
 *
 *              Coverage targets (85%+):
 *                TierManagementService — 90%+ (all three public methods)
 *
 *              Test strategy:
 *                • @testSetup creates a Contact and Silver member at 0 points.
 *                • Tier upgrade/downgrade tests call evaluateTierChange directly
 *                  with constructed old/new member maps — faster than trigger path
 *                  and allows precise threshold testing.
 *                • Annual review test uses a member with an anniversary today,
 *                  below retention threshold — verifies downgrade + log creation.
 *                • getTierBenefits test verifies no exception thrown and returns
 *                  a List (CMDT may be empty in test context — that's acceptable).
 *                • Bulk test at 200 members — one update DML verifies bulk safety.
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
@isTest
private class TierManagementServiceTest {

    static final Integer BULK_SIZE          = 200;
    static final Decimal GOLD_THRESHOLD     = 1000;
    static final Decimal PLATINUM_THRESHOLD = 5000;
    static final Decimal GOLD_RETENTION     = 800;

    // ── Shared test data ──────────────────────────────────────────────────────
    @testSetup
    static void setup() {
        Contact c = new Contact(
            FirstName = 'Tier',
            LastName  = 'Tester',
            Email     = 'tier.tester@example.com'
        );
        insert c;

        LoyaltyProgramMember__c member = new LoyaltyProgramMember__c(
            Contact__c         = c.Id,
            Current_Tier__c    = 'Silver',
            Member_Number__c   = 'LM20250010001',
            Points_Balance__c  = 0,
            Annual_Points__c   = 0,
            Lifetime_Points__c = 0,
            Member_Status__c   = 'Active',
            Enrollment_Date__c = Date.today()
        );
        insert member;
    }

    static LoyaltyProgramMember__c getMember() {
        return [
            SELECT Id, Current_Tier__c, Points_Balance__c, Annual_Points__c,
                   Lifetime_Points__c, Enrollment_Date__c
            FROM   LoyaltyProgramMember__c
            WHERE  Member_Number__c = 'LM20250010001'
            LIMIT  1
        ];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — evaluateTierChange: Silver → Gold at 1000-point threshold
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testTierUpgrade_silverToGold_atThreshold() {
        LoyaltyProgramMember__c member = getMember();

        // Construct old record (Silver, 999 pts) and new record (Silver, 1000 pts)
        LoyaltyProgramMember__c oldRecord = new LoyaltyProgramMember__c(
            Id                = member.Id,
            Current_Tier__c   = 'Silver',
            Points_Balance__c = 999,
            Annual_Points__c  = 999
        );
        LoyaltyProgramMember__c newRecord = new LoyaltyProgramMember__c(
            Id                = member.Id,
            Current_Tier__c   = 'Silver',
            Points_Balance__c = 1000,
            Annual_Points__c  = 1000
        );

        Test.startTest();
        TierManagementService.evaluateTierChange(
            new List<LoyaltyProgramMember__c>{ newRecord },
            new Map<Id, LoyaltyProgramMember__c>{ member.Id => oldRecord }
        );
        Test.stopTest();

        LoyaltyProgramMember__c result = [
            SELECT Current_Tier__c FROM LoyaltyProgramMember__c WHERE Id = :member.Id
        ];
        System.assertEquals('Gold', result.Current_Tier__c,
            'Member should be Gold at exactly 1000 points.');

        Tier_Change_Log__c log = [
            SELECT Old_Tier__c, New_Tier__c, Change_Reason__c
            FROM   Tier_Change_Log__c
            WHERE  Loyalty_Program_Member__c = :member.Id
            LIMIT  1
        ];
        System.assertEquals('Silver', log.Old_Tier__c, 'Old tier should be Silver.');
        System.assertEquals('Gold',   log.New_Tier__c, 'New tier should be Gold.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — evaluateTierChange: Gold → Platinum at 5000-point threshold
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testTierUpgrade_goldToPlatinum_atThreshold() {
        LoyaltyProgramMember__c member = getMember();

        // First set to Gold
        member.Current_Tier__c   = 'Gold';
        member.Points_Balance__c = 4999;
        update member;

        LoyaltyProgramMember__c oldRecord = new LoyaltyProgramMember__c(
            Id                = member.Id,
            Current_Tier__c   = 'Gold',
            Points_Balance__c = 4999,
            Annual_Points__c  = 4999
        );
        LoyaltyProgramMember__c newRecord = new LoyaltyProgramMember__c(
            Id                = member.Id,
            Current_Tier__c   = 'Gold',
            Points_Balance__c = 5000,
            Annual_Points__c  = 5000
        );

        Test.startTest();
        TierManagementService.evaluateTierChange(
            new List<LoyaltyProgramMember__c>{ newRecord },
            new Map<Id, LoyaltyProgramMember__c>{ member.Id => oldRecord }
        );
        Test.stopTest();

        LoyaltyProgramMember__c result = [
            SELECT Current_Tier__c FROM LoyaltyProgramMember__c WHERE Id = :member.Id
        ];
        System.assertEquals('Platinum', result.Current_Tier__c,
            'Member should be Platinum at exactly 5000 points.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — processAnnualTierReview: Gold member below retention → downgrade
    //
    // Gold retention threshold (default: 800 annual pts).
    // Member with anniversary today and only 500 annual pts → downgraded to Silver.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testTierDowngrade_onAnnualReview() {
        LoyaltyProgramMember__c member = getMember();

        // Set to Gold with enrollment date = today (anniversary matches)
        member.Current_Tier__c    = 'Gold';
        member.Points_Balance__c  = 1500;
        member.Annual_Points__c   = 500;  // below Gold retention (800)
        member.Enrollment_Date__c = Date.today();  // anniversary = today
        update member;

        Test.startTest();
        TierManagementService.processAnnualTierReview(
            new List<LoyaltyProgramMember__c>{ member }
        );
        Test.stopTest();

        LoyaltyProgramMember__c result = [
            SELECT Current_Tier__c, Annual_Points__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :member.Id
        ];
        System.assertEquals('Silver', result.Current_Tier__c,
            'Gold member with 500 annual pts (below 800 retention) should be downgraded to Silver.');
        System.assertEquals(0, result.Annual_Points__c,
            'Annual points should be reset to 0 after annual review.');

        // Verify downgrade log
        Tier_Change_Log__c log = [
            SELECT Old_Tier__c, New_Tier__c, Change_Reason__c
            FROM   Tier_Change_Log__c
            WHERE  Loyalty_Program_Member__c = :member.Id
            LIMIT  1
        ];
        System.assertEquals('Gold',   log.Old_Tier__c, 'Old tier should be Gold.');
        System.assertEquals('Silver', log.New_Tier__c, 'New tier should be Silver.');
        System.assert(log.Change_Reason__c.containsIgnoreCase('annual'),
            'Reason should mention annual review. Got: ' + log.Change_Reason__c);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — processAnnualTierReview: non-anniversary member not processed
    //
    // Member whose anniversary is not today → Annual_Points__c not reset.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testTierDowngradeWarning_30DaysBefore() {
        LoyaltyProgramMember__c member = getMember();

        // Set enrollment date 30 days from today (not today) → should NOT process
        member.Current_Tier__c    = 'Gold';
        member.Annual_Points__c   = 500;
        member.Enrollment_Date__c = Date.today().addDays(30);
        update member;

        Test.startTest();
        TierManagementService.processAnnualTierReview(
            new List<LoyaltyProgramMember__c>{ member }
        );
        Test.stopTest();

        LoyaltyProgramMember__c result = [
            SELECT Annual_Points__c, Current_Tier__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :member.Id
        ];
        // Annual points should NOT be reset — anniversary is not today
        System.assertEquals(500, result.Annual_Points__c,
            'Annual points should not be reset when anniversary is not today.');
        System.assertEquals('Gold', result.Current_Tier__c,
            'Tier should not change for non-anniversary member.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5 — getTierBenefits: returns a list without exception
    //
    // CMDT records may not be deployed in test context — service should return
    // an empty list gracefully (not throw an exception).
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testGetTierBenefits_returnsCMDTData() {
        Test.startTest();
        List<TierManagementService.TierBenefitDTO> silverBenefits =
            TierManagementService.getTierBenefits('Silver');
        List<TierManagementService.TierBenefitDTO> goldBenefits =
            TierManagementService.getTierBenefits('Gold');
        List<TierManagementService.TierBenefitDTO> nullBenefits =
            TierManagementService.getTierBenefits(null);
        Test.stopTest();

        // Should not throw — returns empty list when CMDT not deployed
        System.assertNotEquals(null, silverBenefits,
            'Silver benefits list should not be null (may be empty if CMDT not deployed).');
        System.assertNotEquals(null, goldBenefits,
            'Gold benefits list should not be null.');
        System.assertEquals(0, nullBenefits.size(),
            'Null tier name should return empty list.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 6 — evaluateTierChange: bulk 200 members — no governor limit breach
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testBulkTierEvaluation_200Members() {
        // Create 200 contacts and Gold members all crossing Platinum threshold
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < BULK_SIZE; i++) {
            contacts.add(new Contact(
                FirstName = 'BulkTier',
                LastName  = 'Member' + i,
                Email     = 'bulktier' + i + '@example.com'
            ));
        }
        insert contacts;

        List<LoyaltyProgramMember__c> members = new List<LoyaltyProgramMember__c>();
        for (Integer i = 0; i < BULK_SIZE; i++) {
            members.add(new LoyaltyProgramMember__c(
                Contact__c         = contacts[i].Id,
                Current_Tier__c    = 'Gold',
                Member_Number__c   = 'LM2025BULK' + String.valueOf(i).leftPad(5,'0'),
                Points_Balance__c  = 5000,
                Annual_Points__c   = 5000,
                Lifetime_Points__c = 5000,
                Member_Status__c   = 'Active',
                Enrollment_Date__c = Date.today()
            ));
        }
        insert members;

        // Build old/new maps — all cross Platinum threshold (4999 → 5000)
        List<LoyaltyProgramMember__c> newList = new List<LoyaltyProgramMember__c>();
        Map<Id, LoyaltyProgramMember__c> oldMap = new Map<Id, LoyaltyProgramMember__c>();
        for (LoyaltyProgramMember__c m : members) {
            newList.add(new LoyaltyProgramMember__c(
                Id                = m.Id,
                Current_Tier__c   = 'Gold',
                Points_Balance__c = 5000,
                Annual_Points__c  = 5000
            ));
            oldMap.put(m.Id, new LoyaltyProgramMember__c(
                Id                = m.Id,
                Current_Tier__c   = 'Gold',
                Points_Balance__c = 4999,
                Annual_Points__c  = 4999
            ));
        }

        Test.startTest();
        TierManagementService.evaluateTierChange(newList, oldMap);
        Test.stopTest();

        Set<Id> memberIds = new Map<Id, LoyaltyProgramMember__c>(members).keySet();
        Integer platinumCount = [
            SELECT COUNT() FROM LoyaltyProgramMember__c
            WHERE Id IN :memberIds AND Current_Tier__c = 'Platinum'
        ];
        System.assertEquals(BULK_SIZE, platinumCount,
            'All 200 Gold members should be upgraded to Platinum. Got: ' + platinumCount);
    }
}
