/**
 * @description Points accrual engine for the Loyalty Rewards Platform.
 *
 *              Methods:
 *                accruePointsForPurchase   — real-time accrual, idempotency-safe
 *                accruePointsForReferral   — referral bonus, prevents self/duplicate
 *                processTransactionBulk    — batch processing path
 *
 *              Patterns:
 *                • ECommerce_Order_Id__c external ID prevents duplicate awards on retry
 *                • PromotionEngineService called for every accrual
 *                • One SOQL → points calc → one DML on LoyaltyMemberCurrency update
 *                • No SOQL or DML in loops
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
public with sharing class PointsAccrualService {

    // ── Fallback config values (used when CMDT not deployed) ─────────────────
    @TestVisible static final Decimal DEFAULT_POINTS_PER_DOLLAR    = 1.0;
    @TestVisible static final Integer DEFAULT_REFERRAL_BONUS_POINTS = 200;

    // ─────────────────────────────────────────────────────────────────────────
    // Inner Classes
    // ─────────────────────────────────────────────────────────────────────────

    public class PointsAccrualResult {
        public Boolean isSuccess        { get; set; }
        public Integer basePoints       { get; set; }
        public Integer bonusPoints      { get; set; }
        public Integer totalPoints      { get; set; }
        public Boolean promotionApplied { get; set; }
        public String  promotionName    { get; set; }
        public Decimal newBalance       { get; set; }
        public Id      transactionId    { get; set; }
        public String  errorMessage     { get; set; }

        public PointsAccrualResult() {
            this.isSuccess        = false;
            this.basePoints       = 0;
            this.bonusPoints      = 0;
            this.totalPoints      = 0;
            this.promotionApplied = false;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 1 — accruePointsForPurchase
    // ─────────────────────────────────────────────────────────────────────────

    public static PointsAccrualResult accruePointsForPurchase(
        Id      loyaltyMemberId,
        Decimal purchaseAmount,
        String  sourceChannel,
        String  externalOrderId
    ) {
        PointsAccrualResult result = new PointsAccrualResult();

        if (loyaltyMemberId == null || purchaseAmount == null || purchaseAmount <= 0) {
            result.errorMessage = 'Member ID and a positive purchase amount are required.';
            return result;
        }

        // ── Idempotency check ─────────────────────────────────────────────────
        if (String.isNotBlank(externalOrderId)) {
            List<Loyalty_Transaction__c> existing = [
                SELECT Id, Total_Points__c, Base_Points__c, Bonus_Points_Awarded__c,
                       Loyalty_Program_Member__r.Points_Balance__c
                FROM   Loyalty_Transaction__c
                WHERE  ECommerce_Order_Id__c = :externalOrderId
                WITH   USER_MODE
                LIMIT  1
            ];
            if (!existing.isEmpty()) {
                Loyalty_Transaction__c dup = existing[0];
                result.isSuccess        = true;
                result.transactionId    = dup.Id;
                result.totalPoints      = dup.Total_Points__c != null
                    ? Integer.valueOf(dup.Total_Points__c) : 0;
                result.basePoints       = dup.Base_Points__c != null
                    ? Integer.valueOf(dup.Base_Points__c) : 0;
                result.bonusPoints      = dup.Bonus_Points_Awarded__c != null
                    ? Integer.valueOf(dup.Bonus_Points_Awarded__c) : 0;
                result.newBalance       = dup.Loyalty_Program_Member__r.Points_Balance__c;
                result.promotionApplied = result.bonusPoints > 0;
                result.errorMessage     = 'Duplicate order — returning existing transaction.';
                return result;
            }
        }

        // ── Load member and currency records ──────────────────────────────────
        List<LoyaltyProgramMember__c> members = [
            SELECT Id, Current_Tier__c, Points_Balance__c, Annual_Points__c,
                   Lifetime_Points__c,
                   (SELECT Id, Currency_Type__c, Points_Balance__c
                    FROM   Loyalty_Member_Currencies__r
                    WHERE  Currency_Type__c IN ('Base','Bonus')
                      AND  Is_Expired__c = false
                    LIMIT  2)
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :loyaltyMemberId
              AND  Member_Status__c = 'Active'
            WITH   USER_MODE
            LIMIT  1
        ];

        if (members.isEmpty()) {
            result.errorMessage = 'Active loyalty member not found: ' + loyaltyMemberId;
            return result;
        }
        LoyaltyProgramMember__c member = members[0];

        // ── Points calculation ────────────────────────────────────────────────
        Decimal pointsPerDollar = getPointsPerDollar();
        Integer basePoints = Integer.valueOf(
            Math.floor(purchaseAmount * pointsPerDollar)
        );

        // Apply promotion multiplier
        PromotionEngineService.MultiplierResult promoResult =
            PromotionEngineService.getApplicableMultiplier(
                loyaltyMemberId,
                purchaseAmount,
                null,      // productCategory — passed by caller if available
                sourceChannel
            );

        Integer bonusPoints = 0;
        if (promoResult != null && promoResult.multiplier > 1.0) {
            bonusPoints = Integer.valueOf(
                Math.floor(basePoints * (promoResult.multiplier - 1.0))
            );
        }
        Integer totalPoints = basePoints + bonusPoints;

        // ── Create transaction record ─────────────────────────────────────────
        Loyalty_Transaction__c txn = new Loyalty_Transaction__c(
            Loyalty_Program_Member__c = loyaltyMemberId,
            Transaction_Type__c       = 'Earn',
            Transaction_Date__c       = Datetime.now(),
            Purchase_Amount__c        = purchaseAmount,
            Base_Points__c            = basePoints,
            Bonus_Points_Awarded__c   = bonusPoints,
            Total_Points__c           = totalPoints,
            Source_Channel__c         = sourceChannel,
            ECommerce_Order_Id__c     = externalOrderId,
            Promotion_Applied__c      = (promoResult != null && promoResult.promotionId != null)
                                        ? promoResult.promotionId : null,
            Status__c                 = 'Processed',
            Description__c            = 'Purchase accrual — ' + (sourceChannel != null
                                        ? sourceChannel : 'Unknown') +
                                        ' — $' + purchaseAmount.setScale(2)
        );

        Database.SaveResult txnSr = Database.insert(txn, false);
        if (!txnSr.isSuccess()) {
            result.errorMessage = 'Transaction insert failed: ' +
                txnSr.getErrors()[0].getMessage();
            return result;
        }

        // ── Update member balance and currency records ─────────────────────────
        Decimal newBalance     = (member.Points_Balance__c  != null
            ? member.Points_Balance__c  : 0) + totalPoints;
        Decimal newAnnualPts   = (member.Annual_Points__c   != null
            ? member.Annual_Points__c   : 0) + totalPoints;
        Decimal newLifetimePts = (member.Lifetime_Points__c != null
            ? member.Lifetime_Points__c : 0) + totalPoints;

        member.Points_Balance__c  = newBalance;
        member.Annual_Points__c   = newAnnualPts;
        member.Lifetime_Points__c = newLifetimePts;

        // Update currency sub-records
        List<Loyalty_Member_Currency__c> currenciesToUpdate =
            new List<Loyalty_Member_Currency__c>();
        if (member.Loyalty_Member_Currencies__r != null) {
            for (Loyalty_Member_Currency__c curr : member.Loyalty_Member_Currencies__r) {
                if (curr.Currency_Type__c == 'Base') {
                    curr.Points_Balance__c = (curr.Points_Balance__c != null
                        ? curr.Points_Balance__c : 0) + basePoints;
                    curr.Lifetime_Points__c = (curr.Lifetime_Points__c != null
                        ? curr.Lifetime_Points__c : 0) + basePoints;
                    currenciesToUpdate.add(curr);
                } else if (curr.Currency_Type__c == 'Bonus' && bonusPoints > 0) {
                    curr.Points_Balance__c = (curr.Points_Balance__c != null
                        ? curr.Points_Balance__c : 0) + bonusPoints;
                    curr.Lifetime_Points__c = (curr.Lifetime_Points__c != null
                        ? curr.Lifetime_Points__c : 0) + bonusPoints;
                    currenciesToUpdate.add(curr);
                }
            }
        }

        Database.SaveResult memberSr = Database.update(member, false);
        if (!memberSr.isSuccess()) {
            result.errorMessage = 'Member balance update failed: ' +
                memberSr.getErrors()[0].getMessage();
            return result;
        }

        if (!currenciesToUpdate.isEmpty()) {
            Database.update(currenciesToUpdate, false);
        }

        // ── Populate result ───────────────────────────────────────────────────
        result.isSuccess        = true;
        result.transactionId    = txnSr.getId();
        result.basePoints       = basePoints;
        result.bonusPoints      = bonusPoints;
        result.totalPoints      = totalPoints;
        result.newBalance       = newBalance;
        result.promotionApplied = bonusPoints > 0;
        result.promotionName    = (promoResult != null)
            ? promoResult.promotionName : null;

        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 2 — accruePointsForReferral
    // ─────────────────────────────────────────────────────────────────────────

    public static PointsAccrualResult accruePointsForReferral(
        Id referrerMemberId,
        Id referredMemberId
    ) {
        PointsAccrualResult result = new PointsAccrualResult();

        // Self-referral guard
        if (referrerMemberId == referredMemberId) {
            result.errorMessage = 'Self-referral is not permitted.';
            return result;
        }

        // Load both members in one SOQL
        Map<Id, LoyaltyProgramMember__c> memberMap = new Map<Id, LoyaltyProgramMember__c>([
            SELECT Id, Points_Balance__c, Annual_Points__c, Lifetime_Points__c,
                   Member_Status__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id IN (:referrerMemberId, :referredMemberId)
              AND  Member_Status__c = 'Active'
            WITH   USER_MODE
        ]);

        if (!memberMap.containsKey(referrerMemberId)) {
            result.errorMessage = 'Referrer member not found or not active.';
            return result;
        }
        if (!memberMap.containsKey(referredMemberId)) {
            result.errorMessage = 'Referred member not found or not active.';
            return result;
        }

        // Duplicate check — referral bonus already awarded for this pair
        Integer existingReferralCount = [
            SELECT COUNT()
            FROM   Loyalty_Transaction__c
            WHERE  Loyalty_Program_Member__c = :referrerMemberId
              AND  Transaction_Type__c       = 'Referral'
              AND  Referral_Member__c        = :referredMemberId
            WITH   USER_MODE
        ];
        if (existingReferralCount > 0) {
            result.errorMessage = 'Referral bonus already awarded for this member pair.';
            return result;
        }

        Integer referralBonus = getReferralBonusPoints();
        LoyaltyProgramMember__c referrer = memberMap.get(referrerMemberId);

        // Create referral transaction
        Loyalty_Transaction__c referralTxn = new Loyalty_Transaction__c(
            Loyalty_Program_Member__c = referrerMemberId,
            Transaction_Type__c       = 'Referral',
            Transaction_Date__c       = Datetime.now(),
            Base_Points__c            = referralBonus,
            Bonus_Points_Awarded__c   = 0,
            Total_Points__c           = referralBonus,
            Referral_Member__c        = referredMemberId,
            Source_Channel__c         = 'Referral',
            Status__c                 = 'Processed',
            Description__c            = 'Referral bonus — referred member enrolled and completed first purchase'
        );
        Database.SaveResult txnSr = Database.insert(referralTxn, false);
        if (!txnSr.isSuccess()) {
            result.errorMessage = 'Referral transaction insert failed: ' +
                txnSr.getErrors()[0].getMessage();
            return result;
        }

        // Update referrer balance
        Decimal newBalance = (referrer.Points_Balance__c != null
            ? referrer.Points_Balance__c : 0) + referralBonus;
        referrer.Points_Balance__c  = newBalance;
        referrer.Annual_Points__c   = (referrer.Annual_Points__c   != null
            ? referrer.Annual_Points__c   : 0) + referralBonus;
        referrer.Lifetime_Points__c = (referrer.Lifetime_Points__c != null
            ? referrer.Lifetime_Points__c : 0) + referralBonus;

        Database.SaveResult memberSr = Database.update(referrer, false);
        if (!memberSr.isSuccess()) {
            result.errorMessage = 'Referrer balance update failed: ' +
                memberSr.getErrors()[0].getMessage();
            return result;
        }

        result.isSuccess     = true;
        result.transactionId = txnSr.getId();
        result.basePoints    = referralBonus;
        result.totalPoints   = referralBonus;
        result.newBalance    = newBalance;
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 3 — processTransactionBulk
    // Called from LoyaltyTransactionBatch.execute().
    // ─────────────────────────────────────────────────────────────────────────

    public static void processTransactionBulk(
        List<Loyalty_Transaction__c> pendingTransactions
    ) {
        if (pendingTransactions == null || pendingTransactions.isEmpty()) {
            return;
        }

        // Collect all member IDs — one SOQL for all members
        Set<Id> memberIds = new Set<Id>();
        for (Loyalty_Transaction__c txn : pendingTransactions) {
            memberIds.add(txn.Loyalty_Program_Member__c);
        }

        Map<Id, LoyaltyProgramMember__c> memberMap = new Map<Id, LoyaltyProgramMember__c>([
            SELECT Id, Points_Balance__c, Annual_Points__c, Lifetime_Points__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id IN :memberIds
            WITH   USER_MODE
        ]);

        // Accumulate balance deltas per member
        Map<Id, Decimal> balanceDelta = new Map<Id, Decimal>();
        List<Loyalty_Transaction__c> txnsToUpdate = new List<Loyalty_Transaction__c>();

        Decimal pointsPerDollar = getPointsPerDollar();

        for (Loyalty_Transaction__c txn : pendingTransactions) {
            if (!memberMap.containsKey(txn.Loyalty_Program_Member__c)) {
                txn.Status__c          = 'Failed';
                txn.Processing_Notes__c = 'Member not found or inactive.';
                txnsToUpdate.add(txn);
                continue;
            }

            Integer basePoints = Integer.valueOf(
                Math.floor((txn.Purchase_Amount__c != null ? txn.Purchase_Amount__c : 0)
                           * pointsPerDollar)
            );
            Integer totalPoints = basePoints + Integer.valueOf(
                txn.Bonus_Points_Awarded__c != null ? txn.Bonus_Points_Awarded__c : 0
            );

            txn.Base_Points__c  = basePoints;
            txn.Total_Points__c = totalPoints;
            txn.Status__c       = 'Processed';

            Decimal currentDelta = balanceDelta.containsKey(txn.Loyalty_Program_Member__c)
                ? balanceDelta.get(txn.Loyalty_Program_Member__c) : 0;
            balanceDelta.put(txn.Loyalty_Program_Member__c, currentDelta + totalPoints);
            txnsToUpdate.add(txn);
        }

        // One DML to update all transactions
        if (!txnsToUpdate.isEmpty()) {
            Database.update(txnsToUpdate, false);
        }

        // Update all member balances in one DML
        List<LoyaltyProgramMember__c> membersToUpdate = new List<LoyaltyProgramMember__c>();
        for (Id mId : balanceDelta.keySet()) {
            LoyaltyProgramMember__c m = memberMap.get(mId);
            m.Points_Balance__c  = (m.Points_Balance__c  != null ? m.Points_Balance__c  : 0)
                                   + balanceDelta.get(mId);
            m.Annual_Points__c   = (m.Annual_Points__c   != null ? m.Annual_Points__c   : 0)
                                   + balanceDelta.get(mId);
            m.Lifetime_Points__c = (m.Lifetime_Points__c != null ? m.Lifetime_Points__c : 0)
                                   + balanceDelta.get(mId);
            membersToUpdate.add(m);
        }
        if (!membersToUpdate.isEmpty()) {
            Database.update(membersToUpdate, false);
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    @TestVisible
    private static Decimal getPointsPerDollar() {
        Loyalty_Config__mdt config = Loyalty_Config__mdt.getInstance('Points_Config');
        return (config != null && config.Points_Per_Dollar__c != null)
            ? config.Points_Per_Dollar__c
            : DEFAULT_POINTS_PER_DOLLAR;
    }

    @TestVisible
    private static Integer getReferralBonusPoints() {
        Loyalty_Config__mdt config = Loyalty_Config__mdt.getInstance('Points_Config');
        return (config != null && config.Referral_Bonus_Points__c != null)
            ? Integer.valueOf(config.Referral_Bonus_Points__c)
            : DEFAULT_REFERRAL_BONUS_POINTS;
    }
}
