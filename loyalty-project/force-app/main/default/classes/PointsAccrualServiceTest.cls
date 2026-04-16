/**
 * @description Tests for PointsAccrualService — purchase accrual, referral bonus,
 *              idempotency guard, and bulk batch processing.
 *
 *              Coverage targets (85%+):
 *                PointsAccrualService — 90%+ (all three public methods)
 *
 *              Test strategy:
 *                • @testSetup creates one Contact, one LoyaltyProgramMember__c, and
 *                  two Loyalty_Member_Currency__c records (Base + Bonus) shared
 *                  across all tests.
 *                • Idempotency test calls accruePointsForPurchase twice with the
 *                  same externalOrderId — verifies only one transaction is created.
 *                • Promotion test inserts an active Promotion__c record with
 *                  3x multiplier and verifies bonusPoints = basePoints * 2.
 *                • Bulk test at 200 transactions verifies processTransactionBulk
 *                  produces correct balance delta with no governor limit breach.
 *                • Referral tests: self-referral blocked, duplicate blocked,
 *                  valid referral creates transaction and updates balance.
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
@isTest
private class PointsAccrualServiceTest {

    static final Decimal PURCHASE_AMOUNT    = 100.00;
    static final String  CHANNEL_ONLINE     = 'Online';
    static final String  EXT_ORDER_ID       = 'ORD-TEST-20250001';
    static final Integer BULK_TXN_COUNT     = 200;

    // ── Shared test data ──────────────────────────────────────────────────────
    @testSetup
    static void setup() {
        Contact c = new Contact(
            FirstName = 'Points',
            LastName  = 'Tester',
            Email     = 'points.tester@example.com'
        );
        insert c;

        LoyaltyProgramMember__c member = new LoyaltyProgramMember__c(
            Contact__c         = c.Id,
            Current_Tier__c    = 'Silver',
            Member_Number__c   = 'LM20250000001',
            Points_Balance__c  = 500,
            Annual_Points__c   = 500,
            Lifetime_Points__c = 500,
            Member_Status__c   = 'Active',
            Enrollment_Date__c = Date.today()
        );
        insert member;

        List<Loyalty_Member_Currency__c> currencies = new List<Loyalty_Member_Currency__c>{
            new Loyalty_Member_Currency__c(
                Loyalty_Program_Member__c = member.Id,
                Currency_Type__c          = 'Base',
                Points_Balance__c         = 500,
                Lifetime_Points__c        = 500,
                Is_Expired__c             = false
            ),
            new Loyalty_Member_Currency__c(
                Loyalty_Program_Member__c = member.Id,
                Currency_Type__c          = 'Bonus',
                Points_Balance__c         = 0,
                Lifetime_Points__c        = 0,
                Is_Expired__c             = false
            )
        };
        insert currencies;
    }

    static LoyaltyProgramMember__c getMember() {
        return [
            SELECT Id, Points_Balance__c, Annual_Points__c, Lifetime_Points__c,
                   Current_Tier__c, Member_Status__c
            FROM   LoyaltyProgramMember__c
            WHERE  Member_Number__c = 'LM20250000001'
            LIMIT  1
        ];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — accruePointsForPurchase: base purchase, correct point calculation
    //
    // $100 purchase × 1.0 pts/$ (default) = 100 base points, 0 bonus, 100 total.
    // Member balance: 500 + 100 = 600.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAccruePoints_basePurchase_correctCalculation() {
        LoyaltyProgramMember__c member = getMember();

        Test.startTest();
        PointsAccrualService.PointsAccrualResult result =
            PointsAccrualService.accruePointsForPurchase(
                member.Id,
                PURCHASE_AMOUNT,
                CHANNEL_ONLINE,
                'ORD-BASELINE-001'
            );
        Test.stopTest();

        System.assert(result.isSuccess,
            'Accrual should succeed. Error: ' + result.errorMessage);
        System.assertEquals(100, result.basePoints,
            '$100 purchase × 1 pt/$ should award 100 base points.');
        System.assertEquals(0, result.bonusPoints,
            'No active promotion — bonus points should be 0.');
        System.assertEquals(100, result.totalPoints,
            'Total points should equal base points when no promotion.');
        System.assertEquals(600, result.newBalance,
            'Balance should be 500 + 100 = 600.');

        // Verify transaction record created
        List<Loyalty_Transaction__c> txns = [
            SELECT Total_Points__c, Transaction_Type__c, ECommerce_Order_Id__c
            FROM   Loyalty_Transaction__c
            WHERE  Loyalty_Program_Member__c = :member.Id
              AND  ECommerce_Order_Id__c     = 'ORD-BASELINE-001'
        ];
        System.assertEquals(1, txns.size(), 'One transaction record should be created.');
        System.assertEquals('Earn', txns[0].Transaction_Type__c,
            'Transaction type should be Earn.');
        System.assertEquals(100, (Integer) txns[0].Total_Points__c,
            'Transaction should record 100 total points.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — accruePointsForPurchase: active 3x promotion, bonus applied
    //
    // 3x multiplier: base = 100, bonus = 200 (100 × (3-1)), total = 300.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAccruePoints_withActivePromotion_bonusApplied() {
        LoyaltyProgramMember__c member = getMember();

        // Insert active 3x promotion eligible for all tiers
        Promotion__c promo = new Promotion__c(
            Name               = 'Test 3x All Members',
            Start_Date__c      = Date.today().addDays(-1),
            End_Date__c        = Date.today().addDays(30),
            Bonus_Multiplier__c = 3.0,
            Eligible_Tier__c   = 'All Tiers',
            Eligible_Channel__c = 'All Channels',
            Is_Active__c       = true,
            Is_Stackable__c    = false,
            Max_Uses__c        = 0,
            Current_Uses__c    = 0
        );
        insert promo;

        Test.startTest();
        PointsAccrualService.PointsAccrualResult result =
            PointsAccrualService.accruePointsForPurchase(
                member.Id,
                PURCHASE_AMOUNT,
                CHANNEL_ONLINE,
                'ORD-PROMO-001'
            );
        Test.stopTest();

        System.assert(result.isSuccess,
            'Accrual with promotion should succeed. Error: ' + result.errorMessage);
        System.assertEquals(100, result.basePoints,
            'Base points should be 100 regardless of promotion.');
        System.assertEquals(200, result.bonusPoints,
            '3x promo: bonus = 100 × (3.0 - 1.0) = 200.');
        System.assertEquals(300, result.totalPoints,
            'Total should be base (100) + bonus (200) = 300.');
        System.assert(result.promotionApplied,
            'promotionApplied flag should be true.');
        System.assertEquals(800, result.newBalance,
            'Balance: 500 + 300 = 800.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — accruePointsForPurchase: duplicate order ID → idempotent
    //
    // Second call with same EXT_ORDER_ID returns the existing transaction result
    // without creating a second transaction or awarding extra points.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAccruePoints_duplicateOrderId_idempotent() {
        LoyaltyProgramMember__c member = getMember();

        Test.startTest();
        // First call — creates transaction
        PointsAccrualService.PointsAccrualResult firstResult =
            PointsAccrualService.accruePointsForPurchase(
                member.Id, PURCHASE_AMOUNT, CHANNEL_ONLINE, EXT_ORDER_ID
            );
        // Second call with same orderId — should return existing, not create new
        PointsAccrualService.PointsAccrualResult secondResult =
            PointsAccrualService.accruePointsForPurchase(
                member.Id, PURCHASE_AMOUNT, CHANNEL_ONLINE, EXT_ORDER_ID
            );
        Test.stopTest();

        System.assert(firstResult.isSuccess,
            'First accrual should succeed.');
        System.assert(secondResult.isSuccess,
            'Duplicate accrual should return success (idempotent).');
        System.assertEquals(firstResult.transactionId, secondResult.transactionId,
            'Both calls should reference the same transaction record.');

        // Only one transaction should exist for this order ID
        Integer txnCount = [
            SELECT COUNT() FROM Loyalty_Transaction__c
            WHERE ECommerce_Order_Id__c = :EXT_ORDER_ID
        ];
        System.assertEquals(1, txnCount,
            'Idempotency: only one transaction should exist for duplicate order ID.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — processTransactionBulk: 200 pending transactions processed correctly
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAccruePoints_bulk200Transactions() {
        LoyaltyProgramMember__c member = getMember();

        // Create 200 pending transactions
        List<Loyalty_Transaction__c> pending = new List<Loyalty_Transaction__c>();
        for (Integer i = 0; i < BULK_TXN_COUNT; i++) {
            pending.add(new Loyalty_Transaction__c(
                Loyalty_Program_Member__c = member.Id,
                Transaction_Type__c      = 'Earn',
                Transaction_Date__c      = Datetime.now(),
                Purchase_Amount__c       = 10.00,  // $10 each → 10 base pts each
                Bonus_Points_Awarded__c  = 0,
                Status__c                = 'Pending',
                Source_Channel__c        = 'Online',
                Description__c           = 'Bulk test txn ' + i
            ));
        }
        insert pending;

        Test.startTest();
        PointsAccrualService.processTransactionBulk(pending);
        Test.stopTest();

        // All 200 should now be Processed
        Integer processedCount = [
            SELECT COUNT() FROM Loyalty_Transaction__c
            WHERE Loyalty_Program_Member__c = :member.Id
              AND Status__c = 'Processed'
              AND Description__c LIKE 'Bulk test txn%'
        ];
        System.assertEquals(BULK_TXN_COUNT, processedCount,
            'All 200 pending transactions should be marked Processed.');

        // Balance: 500 (initial) + 200 × 10 pts = 2500
        LoyaltyProgramMember__c updated = [
            SELECT Points_Balance__c FROM LoyaltyProgramMember__c WHERE Id = :member.Id
        ];
        System.assertEquals(2500, updated.Points_Balance__c,
            'Balance should be 500 + (200 × 10) = 2500 after bulk processing.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5 — accruePointsForReferral: valid referral awards bonus points
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAccrueReferralPoints_success() {
        LoyaltyProgramMember__c referrer = getMember();

        // Create a second member (the referred member)
        Contact c2 = new Contact(FirstName = 'Referred', LastName = 'Member',
                                  Email = 'referred@example.com');
        insert c2;
        LoyaltyProgramMember__c referred = new LoyaltyProgramMember__c(
            Contact__c         = c2.Id,
            Current_Tier__c    = 'Silver',
            Member_Number__c   = 'LM20250000002',
            Points_Balance__c  = 0,
            Annual_Points__c   = 0,
            Lifetime_Points__c = 0,
            Member_Status__c   = 'Active',
            Enrollment_Date__c = Date.today()
        );
        insert referred;

        Decimal initialBalance = referrer.Points_Balance__c;

        Test.startTest();
        PointsAccrualService.PointsAccrualResult result =
            PointsAccrualService.accruePointsForReferral(referrer.Id, referred.Id);
        Test.stopTest();

        System.assert(result.isSuccess,
            'Referral accrual should succeed. Error: ' + result.errorMessage);
        System.assert(result.basePoints > 0,
            'Referral bonus points should be positive.');

        LoyaltyProgramMember__c updatedReferrer = [
            SELECT Points_Balance__c FROM LoyaltyProgramMember__c WHERE Id = :referrer.Id
        ];
        System.assertEquals(initialBalance + result.basePoints,
            updatedReferrer.Points_Balance__c,
            'Referrer balance should increase by the referral bonus.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 6 — accruePointsForReferral: self-referral blocked
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAccrueReferralPoints_selfReferral_blocked() {
        LoyaltyProgramMember__c member = getMember();

        Test.startTest();
        PointsAccrualService.PointsAccrualResult result =
            PointsAccrualService.accruePointsForReferral(member.Id, member.Id);
        Test.stopTest();

        System.assert(!result.isSuccess,
            'Self-referral should be blocked.');
        System.assert(result.errorMessage.containsIgnoreCase('self'),
            'Error message should mention self-referral. Got: ' + result.errorMessage);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 7 — accruePointsForReferral: duplicate referral blocked
    //
    // Second call for the same referrer/referred pair returns failure.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testAccrueReferralPoints_alreadyAwarded_blocked() {
        LoyaltyProgramMember__c referrer = getMember();

        Contact c2 = new Contact(FirstName = 'Dup', LastName = 'Referred',
                                  Email = 'dup.referred@example.com');
        insert c2;
        LoyaltyProgramMember__c referred = new LoyaltyProgramMember__c(
            Contact__c         = c2.Id,
            Current_Tier__c    = 'Silver',
            Member_Number__c   = 'LM20250000003',
            Points_Balance__c  = 0,
            Annual_Points__c   = 0,
            Lifetime_Points__c = 0,
            Member_Status__c   = 'Active',
            Enrollment_Date__c = Date.today()
        );
        insert referred;

        // First referral — should succeed
        PointsAccrualService.accruePointsForReferral(referrer.Id, referred.Id);

        Test.startTest();
        // Second referral for same pair — should be blocked
        PointsAccrualService.PointsAccrualResult result =
            PointsAccrualService.accruePointsForReferral(referrer.Id, referred.Id);
        Test.stopTest();

        System.assert(!result.isSuccess,
            'Duplicate referral bonus should be blocked.');
        System.assert(
            result.errorMessage.containsIgnoreCase('already'),
            'Error should mention already awarded. Got: ' + result.errorMessage);
    }
}
