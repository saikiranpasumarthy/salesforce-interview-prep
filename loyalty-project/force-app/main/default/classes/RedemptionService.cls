/**
 * @description Points redemption service for the Loyalty Rewards Platform.
 *
 *              Methods:
 *                validateRedemption  — pre-flight check before any DML
 *                processRedemption   — atomic redemption with Savepoint rollback
 *                redeemVoucher       — POS/checkout voucher application
 *
 *              Patterns:
 *                • Database.Savepoint used for atomicity across 3 DML operations
 *                • Voucher codes generated from Crypto.generateAESKey (128-bit)
 *                • Minimum redemption threshold from Loyalty_Config__mdt
 *                • No SOQL or DML in loops
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
public with sharing class RedemptionService {

    // ── Fallback config ───────────────────────────────────────────────────────
    @TestVisible static final Integer DEFAULT_MIN_REDEMPTION_POINTS = 500;
    @TestVisible static final Integer DEFAULT_VOUCHER_EXPIRY_DAYS   = 90;
    @TestVisible static final Decimal DEFAULT_POINTS_TO_DOLLAR_RATE = 0.01; // 100 pts = $1

    // ─────────────────────────────────────────────────────────────────────────
    // Inner Classes
    // ─────────────────────────────────────────────────────────────────────────

    public class RedemptionValidationResult {
        public Boolean isValid        { get; set; }
        public String  reason         { get; set; }
        public Decimal currentBalance { get; set; }
        public Integer minimumPoints  { get; set; }

        public RedemptionValidationResult() {
            this.isValid = false;
        }
    }

    public class RedemptionResult {
        @AuraEnabled public Boolean isSuccess      { get; set; }
        @AuraEnabled public Id      voucherId      { get; set; }
        @AuraEnabled public String  redemptionCode { get; set; }
        @AuraEnabled public Date    expiryDate     { get; set; }
        @AuraEnabled public Decimal discountValue  { get; set; }
        @AuraEnabled public Decimal newBalance     { get; set; }
        @AuraEnabled public String  errorMessage   { get; set; }

        public RedemptionResult() {
            this.isSuccess = false;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 1 — validateRedemption
    // ─────────────────────────────────────────────────────────────────────────

    public static RedemptionValidationResult validateRedemption(
        Id      memberId,
        Integer pointsToRedeem,
        String  rewardType
    ) {
        RedemptionValidationResult result = new RedemptionValidationResult();

        if (memberId == null || pointsToRedeem == null || pointsToRedeem <= 0) {
            result.reason = 'Member ID and a positive points amount are required.';
            return result;
        }

        Integer minimumPoints = getMinRedemptionPoints();
        result.minimumPoints  = minimumPoints;

        // Minimum threshold check
        if (pointsToRedeem < minimumPoints) {
            result.reason = 'Minimum redemption is ' + minimumPoints +
                ' points. Requested: ' + pointsToRedeem;
            return result;
        }

        // Load member
        List<LoyaltyProgramMember__c> members = [
            SELECT Id, Points_Balance__c, Current_Tier__c, Member_Status__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :memberId
              AND  Member_Status__c = 'Active'
            WITH   USER_MODE
            LIMIT  1
        ];
        if (members.isEmpty()) {
            result.reason = 'Active loyalty member not found.';
            return result;
        }
        LoyaltyProgramMember__c member = members[0];
        result.currentBalance = member.Points_Balance__c != null
            ? member.Points_Balance__c : 0;

        // Sufficient balance check
        if (result.currentBalance < pointsToRedeem) {
            result.reason = 'Insufficient points balance. Available: ' +
                result.currentBalance.intValue() + ', Requested: ' + pointsToRedeem;
            return result;
        }

        // Tier eligibility check for Partner Rewards (Platinum only)
        if (rewardType == 'PartnerReward' && member.Current_Tier__c != 'Platinum') {
            result.reason = 'Partner Rewards are available to Platinum members only. ' +
                'Current tier: ' + member.Current_Tier__c;
            return result;
        }

        // No pending redemption in progress for this member
        Integer pendingCount = [
            SELECT COUNT()
            FROM   Loyalty_Transaction__c
            WHERE  Loyalty_Program_Member__c = :memberId
              AND  Transaction_Type__c       = 'Redeem'
              AND  Status__c                 = 'Pending'
            WITH   USER_MODE
        ];
        if (pendingCount > 0) {
            result.reason = 'A redemption is already in progress for this member. ' +
                'Please wait for it to complete before submitting another.';
            return result;
        }

        result.isValid = true;
        result.reason  = 'Redemption is valid.';
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 2 — processRedemption
    // Atomic: Savepoint created at start; rollback on any failure.
    // ─────────────────────────────────────────────────────────────────────────

    @AuraEnabled
    public static RedemptionResult processRedemption(
        Id      memberId,
        Integer pointsToRedeem,
        String  rewardType,
        Decimal rewardValue
    ) {
        RedemptionResult result = new RedemptionResult();

        // Pre-flight validation
        RedemptionValidationResult validation =
            validateRedemption(memberId, pointsToRedeem, rewardType);
        if (!validation.isValid) {
            result.errorMessage = validation.reason;
            return result;
        }

        // Create savepoint for atomicity
        Savepoint sp = Database.setSavepoint();

        try {
            // Load member + base currency record
            LoyaltyProgramMember__c member = [
                SELECT Id, Points_Balance__c, Current_Tier__c, Annual_Points__c,
                       (SELECT Id, Currency_Type__c, Points_Balance__c
                        FROM   Loyalty_Member_Currencies__r
                        WHERE  Currency_Type__c = 'Base'
                          AND  Is_Expired__c    = false
                        LIMIT  1)
                FROM   LoyaltyProgramMember__c
                WHERE  Id = :memberId
                WITH   USER_MODE
                LIMIT  1
            ];

            // Step 1: Create redemption transaction (negative points)
            Loyalty_Transaction__c txn = new Loyalty_Transaction__c(
                Loyalty_Program_Member__c = memberId,
                Transaction_Type__c       = 'Redeem',
                Transaction_Date__c       = Datetime.now(),
                Base_Points__c            = -pointsToRedeem,
                Bonus_Points_Awarded__c   = 0,
                Total_Points__c           = -pointsToRedeem,
                Source_Channel__c         = 'Portal',
                Status__c                 = 'Processed',
                Description__c            = 'Redemption — ' + rewardType +
                                            ' — ' + pointsToRedeem + ' points'
            );
            Database.SaveResult txnSr = Database.insert(txn, false);
            if (!txnSr.isSuccess()) {
                Database.rollback(sp);
                result.errorMessage = 'Redemption transaction failed: ' +
                    txnSr.getErrors()[0].getMessage();
                return result;
            }

            // Step 2: Deduct points from member balance
            Decimal newBalance = (member.Points_Balance__c != null
                ? member.Points_Balance__c : 0) - pointsToRedeem;
            member.Points_Balance__c = newBalance;
            member.Annual_Points__c  = Math.max(0,
                (member.Annual_Points__c != null ? member.Annual_Points__c : 0)
                - pointsToRedeem);

            Database.SaveResult memberSr = Database.update(member, false);
            if (!memberSr.isSuccess()) {
                Database.rollback(sp);
                result.errorMessage = 'Balance deduction failed: ' +
                    memberSr.getErrors()[0].getMessage();
                return result;
            }

            // Update base currency record
            if (!member.Loyalty_Member_Currencies__r.isEmpty()) {
                Loyalty_Member_Currency__c baseCurr =
                    member.Loyalty_Member_Currencies__r[0];
                baseCurr.Points_Balance__c = Math.max(0,
                    (baseCurr.Points_Balance__c != null ? baseCurr.Points_Balance__c : 0)
                    - pointsToRedeem);
                Database.update(baseCurr, false);
            }

            // Step 3: Create Voucher__c with unique redemption code
            Date   expiryDate     = Date.today().addDays(getVoucherExpiryDays());
            String redemptionCode = generateRedemptionCode();
            Decimal discountVal   = rewardValue != null
                ? rewardValue
                : (pointsToRedeem * DEFAULT_POINTS_TO_DOLLAR_RATE);

            Voucher__c voucher = new Voucher__c(
                Loyalty_Program_Member__c  = memberId,
                Reward_Type__c             = rewardType,
                Discount_Value__c          = discountVal,
                Points_Cost__c             = pointsToRedeem,
                Expiry_Date__c             = expiryDate,
                Status__c                  = 'Active',
                Redemption_Code__c         = redemptionCode,
                Redemption_Transaction__c  = txnSr.getId()
            );
            Database.SaveResult voucherSr = Database.insert(voucher, false);
            if (!voucherSr.isSuccess()) {
                Database.rollback(sp);
                result.errorMessage = 'Voucher creation failed: ' +
                    voucherSr.getErrors()[0].getMessage();
                return result;
            }

            // Re-evaluate tier after deduction (balance may have dropped)
            TierManagementService.evaluateTierChange(
                new List<LoyaltyProgramMember__c>{ member },
                new Map<Id, LoyaltyProgramMember__c>{
                    member.Id => new LoyaltyProgramMember__c(
                        Id              = member.Id,
                        Points_Balance__c = (member.Points_Balance__c + pointsToRedeem),
                        Annual_Points__c  = member.Annual_Points__c + pointsToRedeem,
                        Current_Tier__c  = member.Current_Tier__c
                    )
                }
            );

            // Send voucher delivery email
            sendVoucherEmail(memberId, redemptionCode, discountVal, expiryDate);

            result.isSuccess      = true;
            result.voucherId      = voucherSr.getId();
            result.redemptionCode = redemptionCode;
            result.expiryDate     = expiryDate;
            result.discountValue  = discountVal;
            result.newBalance     = newBalance;

        } catch (Exception e) {
            Database.rollback(sp);
            result.errorMessage = 'Unexpected error during redemption: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR,
                'RedemptionService.processRedemption exception: ' + e.getStackTraceString());
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 3 — redeemVoucher
    // Called by POS or e-commerce checkout to apply a voucher.
    // ─────────────────────────────────────────────────────────────────────────

    public static Decimal redeemVoucher(String redemptionCode, String channel) {
        if (String.isBlank(redemptionCode)) {
            throw new AuraHandledException('Redemption code is required.');
        }

        List<Voucher__c> vouchers = [
            SELECT Id, Status__c, Expiry_Date__c, Discount_Value__c,
                   Loyalty_Program_Member__c
            FROM   Voucher__c
            WHERE  Redemption_Code__c = :redemptionCode.trim().toUpperCase()
            WITH   USER_MODE
            LIMIT  1
        ];

        if (vouchers.isEmpty()) {
            throw new AuraHandledException('Voucher not found for code: ' + redemptionCode);
        }

        Voucher__c v = vouchers[0];

        if (v.Status__c == 'Redeemed') {
            throw new AuraHandledException('This voucher has already been used.');
        }
        if (v.Status__c == 'Expired' || v.Status__c == 'Void') {
            throw new AuraHandledException('This voucher is no longer valid (status: ' + v.Status__c + ').');
        }
        if (v.Expiry_Date__c < Date.today()) {
            // Expire it
            v.Status__c = 'Expired';
            Database.update(v, false);
            throw new AuraHandledException('This voucher expired on ' + v.Expiry_Date__c.format() + '.');
        }

        // Mark as redeemed
        v.Status__c             = 'Redeemed';
        v.Redemption_Date__c    = Date.today();
        v.Redemption_Channel__c = channel;
        Database.SaveResult sr  = Database.update(v, false);

        if (!sr.isSuccess()) {
            throw new AuraHandledException(
                'Voucher redemption update failed: ' + sr.getErrors()[0].getMessage()
            );
        }

        return v.Discount_Value__c;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    @TestVisible
    private static String generateRedemptionCode() {
        // 128-bit cryptographically random key → base64 → 16 alphanumeric chars
        Blob   rawKey    = Crypto.generateAESKey(128);
        String encoded   = EncodingUtil.base64Encode(rawKey)
            .replaceAll('[^A-Z0-9]', '')
            .substring(0, 16);
        // Format as XXXX-XXXX-XXXX-XXXX
        return encoded.substring(0, 4) + '-' +
               encoded.substring(4, 8) + '-' +
               encoded.substring(8, 12) + '-' +
               encoded.substring(12, 16);
    }

    private static Integer getMinRedemptionPoints() {
        Loyalty_Config__mdt config = Loyalty_Config__mdt.getInstance('Points_Config');
        return (config != null && config.Min_Redemption_Points__c != null)
            ? Integer.valueOf(config.Min_Redemption_Points__c)
            : DEFAULT_MIN_REDEMPTION_POINTS;
    }

    private static Integer getVoucherExpiryDays() {
        Loyalty_Config__mdt config = Loyalty_Config__mdt.getInstance('Expiry_Config');
        return (config != null && config.Voucher_Expiry_Days__c != null)
            ? Integer.valueOf(config.Voucher_Expiry_Days__c)
            : DEFAULT_VOUCHER_EXPIRY_DAYS;
    }

    private static void sendVoucherEmail(
        Id memberId, String code, Decimal value, Date expiry
    ) {
        List<LoyaltyProgramMember__c> members = [
            SELECT Contact__r.Email, Contact__r.FirstName
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :memberId
            WITH   USER_MODE
            LIMIT  1
        ];
        if (members.isEmpty() || members[0].Contact__r == null
            || String.isBlank(members[0].Contact__r.Email)) {
            return;
        }

        Contact c = members[0].Contact__r;
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ c.Email });
        mail.setSubject('Your Loyalty Reward Voucher — $' + value.setScale(2) + ' off!');
        mail.setPlainTextBody(
            'Dear ' + c.FirstName + ',\n\n' +
            'Your reward voucher is ready to use!\n\n' +
            'Voucher Code: ' + code + '\n' +
            'Discount Value: $' + value.setScale(2) + '\n' +
            'Valid Until: ' + expiry.format() + '\n\n' +
            'Use this code at checkout online or show it to a store associate.\n\n' +
            'Thank you for your loyalty!'
        );

        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'RedemptionService.sendVoucherEmail failed: ' + e.getMessage());
        }
    }
}
