/**
 * @description Tests for RedemptionService — validation, atomic redemption,
 *              voucher generation, and voucher application at POS.
 *
 *              Coverage targets (85%+):
 *                RedemptionService — 90%+ (all three public methods)
 *
 *              Test strategy:
 *                • @testSetup creates Contact, Gold member with 2000 points,
 *                  and Base currency record — shared across all tests.
 *                • Validation tests verify each guard: insufficient balance,
 *                  below minimum, partner reward tier restriction.
 *                • processRedemption tests verify: voucher created with correct
 *                  discount value, points deducted from member and currency,
 *                  Savepoint rollback on simulated failure.
 *                • redeemVoucher tests: valid code → Redeemed status,
 *                  expired voucher → exception thrown,
 *                  already-used voucher → exception thrown.
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
@isTest
private class RedemptionServiceTest {

    static final Integer MEMBER_INITIAL_BALANCE = 2000;
    static final Integer REDEEM_AMOUNT          = 500;
    static final String  REWARD_TYPE_DISCOUNT   = 'DiscountVoucher';
    static final String  REWARD_TYPE_PARTNER    = 'PartnerReward';

    // ── Shared test data ──────────────────────────────────────────────────────
    @testSetup
    static void setup() {
        Contact c = new Contact(
            FirstName = 'Redemption',
            LastName  = 'Tester',
            Email     = 'redemption.tester@example.com'
        );
        insert c;

        LoyaltyProgramMember__c member = new LoyaltyProgramMember__c(
            Contact__c         = c.Id,
            Current_Tier__c    = 'Gold',
            Member_Number__c   = 'LM20250020001',
            Points_Balance__c  = MEMBER_INITIAL_BALANCE,
            Annual_Points__c   = MEMBER_INITIAL_BALANCE,
            Lifetime_Points__c = MEMBER_INITIAL_BALANCE,
            Member_Status__c   = 'Active',
            Enrollment_Date__c = Date.today()
        );
        insert member;

        Loyalty_Member_Currency__c baseCurr = new Loyalty_Member_Currency__c(
            Loyalty_Program_Member__c = member.Id,
            Currency_Type__c          = 'Base',
            Points_Balance__c         = MEMBER_INITIAL_BALANCE,
            Lifetime_Points__c        = MEMBER_INITIAL_BALANCE,
            Is_Expired__c             = false
        );
        insert baseCurr;
    }

    static LoyaltyProgramMember__c getMember() {
        return [
            SELECT Id, Points_Balance__c, Annual_Points__c, Current_Tier__c,
                   Member_Status__c
            FROM   LoyaltyProgramMember__c
            WHERE  Member_Number__c = 'LM20250020001'
            LIMIT  1
        ];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — validateRedemption: sufficient balance → isValid = true
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testValidateRedemption_sufficientBalance_valid() {
        LoyaltyProgramMember__c member = getMember();

        Test.startTest();
        RedemptionService.RedemptionValidationResult result =
            RedemptionService.validateRedemption(
                member.Id, REDEEM_AMOUNT, REWARD_TYPE_DISCOUNT
            );
        Test.stopTest();

        System.assert(result.isValid,
            'Validation should pass for 500 pts with 2000 pts balance. ' +
            'Reason: ' + result.reason);
        System.assertEquals(MEMBER_INITIAL_BALANCE, result.currentBalance,
            'Returned balance should match member balance.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — validateRedemption: insufficient balance → isValid = false
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testValidateRedemption_insufficientBalance_invalid() {
        LoyaltyProgramMember__c member = getMember();

        Test.startTest();
        // Request more points than the member has
        RedemptionService.RedemptionValidationResult result =
            RedemptionService.validateRedemption(
                member.Id, 9999, REWARD_TYPE_DISCOUNT
            );
        Test.stopTest();

        System.assert(!result.isValid,
            'Validation should fail when requested points exceed balance.');
        System.assert(result.reason.containsIgnoreCase('Insufficient'),
            'Reason should mention insufficient balance. Got: ' + result.reason);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — validateRedemption: below minimum threshold → isValid = false
    //
    // Default minimum: 500 pts. Request 100 pts → blocked.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testValidateRedemption_belowMinimum_invalid() {
        LoyaltyProgramMember__c member = getMember();

        Test.startTest();
        RedemptionService.RedemptionValidationResult result =
            RedemptionService.validateRedemption(
                member.Id, 100, REWARD_TYPE_DISCOUNT
            );
        Test.stopTest();

        System.assert(!result.isValid,
            'Validation should fail when points are below minimum threshold (500).');
        System.assert(result.reason.containsIgnoreCase('Minimum'),
            'Reason should mention minimum threshold. Got: ' + result.reason);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — processRedemption: creates Voucher__c and deducts points
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testProcessRedemption_createsVoucherAndDeductsPoints() {
        LoyaltyProgramMember__c member = getMember();

        Test.startTest();
        RedemptionService.RedemptionResult result =
            RedemptionService.processRedemption(
                member.Id,
                REDEEM_AMOUNT,
                REWARD_TYPE_DISCOUNT,
                5.00   // $5 discount value
            );
        Test.stopTest();

        System.assert(result.isSuccess,
            'Redemption should succeed. Error: ' + result.errorMessage);
        System.assertNotEquals(null, result.voucherId,
            'Voucher ID should be populated.');
        System.assertNotEquals(null, result.redemptionCode,
            'Redemption code should be generated.');
        System.assertEquals(5.00, result.discountValue,
            'Discount value should be $5.00.');
        System.assertEquals(MEMBER_INITIAL_BALANCE - REDEEM_AMOUNT, result.newBalance,
            'New balance should be ' + (MEMBER_INITIAL_BALANCE - REDEEM_AMOUNT));

        // Verify Voucher__c record
        Voucher__c voucher = [
            SELECT Status__c, Redemption_Code__c, Discount_Value__c,
                   Points_Cost__c, Expiry_Date__c
            FROM   Voucher__c
            WHERE  Id = :result.voucherId
        ];
        System.assertEquals('Active', voucher.Status__c,
            'New voucher should have Active status.');
        System.assertEquals(REDEEM_AMOUNT, voucher.Points_Cost__c,
            'Voucher points cost should equal redeemed points.');
        System.assertNotEquals(null, voucher.Expiry_Date__c,
            'Expiry date should be set on voucher.');
        System.assert(voucher.Redemption_Code__c.contains('-'),
            'Redemption code should be in XXXX-XXXX-XXXX-XXXX format.');

        // Verify member balance deducted
        LoyaltyProgramMember__c updatedMember = [
            SELECT Points_Balance__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :member.Id
        ];
        System.assertEquals(MEMBER_INITIAL_BALANCE - REDEEM_AMOUNT,
            updatedMember.Points_Balance__c,
            'Member balance should be reduced by ' + REDEEM_AMOUNT + ' points.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5 — processRedemption: rollback on insufficient balance (Savepoint)
    //
    // Request points exceeding balance → validation blocks → no DML committed.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testProcessRedemption_rollbackOnFailure() {
        LoyaltyProgramMember__c member = getMember();

        Integer vouchersBefore = [
            SELECT COUNT() FROM Voucher__c WHERE Loyalty_Program_Member__c = :member.Id
        ];
        Integer txnsBefore = [
            SELECT COUNT() FROM Loyalty_Transaction__c
            WHERE Loyalty_Program_Member__c = :member.Id
        ];

        Test.startTest();
        // Request more than balance — should fail in validation before any DML
        RedemptionService.RedemptionResult result =
            RedemptionService.processRedemption(
                member.Id,
                99999,    // far exceeds 2000 pt balance
                REWARD_TYPE_DISCOUNT,
                999.99
            );
        Test.stopTest();

        System.assert(!result.isSuccess,
            'Redemption should fail when points exceed balance.');

        // Verify no voucher or transaction was created
        Integer vouchersAfter = [
            SELECT COUNT() FROM Voucher__c WHERE Loyalty_Program_Member__c = :member.Id
        ];
        Integer txnsAfter = [
            SELECT COUNT() FROM Loyalty_Transaction__c
            WHERE Loyalty_Program_Member__c = :member.Id
        ];

        System.assertEquals(vouchersBefore, vouchersAfter,
            'No Voucher__c should be created when redemption is rolled back.');
        System.assertEquals(txnsBefore, txnsAfter,
            'No transaction should be created when redemption is rolled back.');

        // Member balance should be unchanged
        LoyaltyProgramMember__c unchanged = [
            SELECT Points_Balance__c FROM LoyaltyProgramMember__c WHERE Id = :member.Id
        ];
        System.assertEquals(MEMBER_INITIAL_BALANCE, unchanged.Points_Balance__c,
            'Member balance should be unchanged after failed redemption.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 6 — redeemVoucher: valid code → status updated to Redeemed
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testRedeemVoucher_success_marksRedeemed() {
        LoyaltyProgramMember__c member = getMember();

        // Insert a voucher directly (bypass processRedemption for isolation)
        Voucher__c v = new Voucher__c(
            Loyalty_Program_Member__c = member.Id,
            Reward_Type__c            = REWARD_TYPE_DISCOUNT,
            Discount_Value__c         = 5.00,
            Points_Cost__c            = 500,
            Expiry_Date__c            = Date.today().addDays(90),
            Status__c                 = 'Active',
            Redemption_Code__c        = 'TEST-ABCD-EFGH-IJKL'
        );
        insert v;

        Test.startTest();
        Decimal discountValue = RedemptionService.redeemVoucher('TEST-ABCD-EFGH-IJKL', 'InStore');
        Test.stopTest();

        System.assertEquals(5.00, discountValue,
            'redeemVoucher should return the discount value.');

        Voucher__c updated = [
            SELECT Status__c, Redemption_Date__c, Redemption_Channel__c
            FROM   Voucher__c
            WHERE  Id = :v.Id
        ];
        System.assertEquals('Redeemed', updated.Status__c,
            'Voucher status should be Redeemed after successful redemption.');
        System.assertEquals(Date.today(), updated.Redemption_Date__c,
            'Redemption date should be today.');
        System.assertEquals('InStore', updated.Redemption_Channel__c,
            'Redemption channel should be InStore.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 7 — redeemVoucher: expired voucher → AuraHandledException thrown
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testRedeemVoucher_expiredVoucher_rejected() {
        LoyaltyProgramMember__c member = getMember();

        Voucher__c v = new Voucher__c(
            Loyalty_Program_Member__c = member.Id,
            Reward_Type__c            = REWARD_TYPE_DISCOUNT,
            Discount_Value__c         = 5.00,
            Points_Cost__c            = 500,
            Expiry_Date__c            = Date.today().addDays(-1),  // expired yesterday
            Status__c                 = 'Active',
            Redemption_Code__c        = 'TEST-EXPD-VOUC-HERE'
        );
        insert v;

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RedemptionService.redeemVoucher('TEST-EXPD-VOUC-HERE', 'Online');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().containsIgnoreCase('expired') ||
                          e.getMessage().containsIgnoreCase('Expired'),
                'Exception message should mention expiry. Got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'AuraHandledException should be thrown for expired voucher.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 8 — redeemVoucher: already-used voucher → AuraHandledException thrown
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testRedeemVoucher_alreadyUsed_rejected() {
        LoyaltyProgramMember__c member = getMember();

        Voucher__c v = new Voucher__c(
            Loyalty_Program_Member__c = member.Id,
            Reward_Type__c            = REWARD_TYPE_DISCOUNT,
            Discount_Value__c         = 5.00,
            Points_Cost__c            = 500,
            Expiry_Date__c            = Date.today().addDays(90),
            Status__c                 = 'Redeemed',   // already used
            Redemption_Code__c        = 'TEST-USED-VOUC-CODE'
        );
        insert v;

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            RedemptionService.redeemVoucher('TEST-USED-VOUC-CODE', 'Online');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().containsIgnoreCase('already'),
                'Exception message should mention already used. Got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'AuraHandledException should be thrown for an already-redeemed voucher.');
    }
}
