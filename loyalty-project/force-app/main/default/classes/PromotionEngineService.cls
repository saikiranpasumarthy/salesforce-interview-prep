/**
 * @description Promotion evaluation engine for the Loyalty Rewards Platform.
 *
 *              Methods:
 *                getApplicableMultiplier   — single SOQL promo evaluation
 *                incrementPromotionUsage   — FOR UPDATE atomic counter
 *                getActiveMemberPromotions — AuraEnabled for promotionBanner LWC
 *
 *              Patterns:
 *                • One SOQL for all active promotion candidates
 *                • FOR UPDATE lock prevents race condition on Max_Uses__c
 *                • Stacking rules: exclusive promotions override all stackable
 *                • No SOQL or DML in loops
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
public with sharing class PromotionEngineService {

    // ─────────────────────────────────────────────────────────────────────────
    // Inner Classes
    // ─────────────────────────────────────────────────────────────────────────

    public class MultiplierResult {
        public Decimal      multiplier      { get; set; }
        public Id           promotionId     { get; set; }
        public String       promotionName   { get; set; }
        public List<Id>     appliedIds      { get; set; }

        public MultiplierResult() {
            this.multiplier  = 1.0;
            this.appliedIds  = new List<Id>();
        }
    }

    public class PromotionDisplayDTO {
        @AuraEnabled public String  promotionId       { get; set; }
        @AuraEnabled public String  name              { get; set; }
        @AuraEnabled public String  bonusMultiplier   { get; set; }
        @AuraEnabled public Date    startDate         { get; set; }
        @AuraEnabled public Date    endDate           { get; set; }
        @AuraEnabled public String  eligibleTier      { get; set; }
        @AuraEnabled public String  productCategory   { get; set; }
        @AuraEnabled public String  ctaUrl            { get; set; }
        @AuraEnabled public String  description       { get; set; }
    }

    public class PromotionUsageResult {
        public Boolean success      { get; set; }
        public String  errorMessage { get; set; }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 1 — getApplicableMultiplier
    // ─────────────────────────────────────────────────────────────────────────

    public static MultiplierResult getApplicableMultiplier(
        Id      memberId,
        Decimal purchaseAmount,
        String  productCategory,
        String  channel
    ) {
        MultiplierResult result = new MultiplierResult();

        if (memberId == null) {
            return result;
        }

        // Get member tier (one SOQL — may be already known by caller but kept
        // here for standalone use; production callers pass tier to avoid this SOQL)
        List<LoyaltyProgramMember__c> members = [
            SELECT Current_Tier__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :memberId
              AND  Member_Status__c = 'Active'
            WITH   USER_MODE
            LIMIT  1
        ];
        if (members.isEmpty()) {
            return result;
        }
        String memberTier = members[0].Current_Tier__c;
        Date   today      = Date.today();

        // Single SOQL for all applicable active promotions
        List<Promotion__c> candidates = [
            SELECT Id, Name, Bonus_Multiplier__c, Is_Stackable__c,
                   Eligible_Tier__c, Product_Category__c, Eligible_Channel__c,
                   Current_Uses__c, Max_Uses__c
            FROM   Promotion__c
            WHERE  Is_Active__c    = true
              AND  Start_Date__c  <= :today
              AND  End_Date__c    >= :today
            WITH   USER_MODE
        ];

        // Filter in Apex (to avoid dynamic SOQL and to apply stacking logic)
        List<Promotion__c> exclusiveApplicable  = new List<Promotion__c>();
        List<Promotion__c> stackableApplicable  = new List<Promotion__c>();

        for (Promotion__c p : candidates) {
            // Usage cap check
            if (p.Max_Uses__c != null && p.Max_Uses__c > 0
                && p.Current_Uses__c >= p.Max_Uses__c) {
                continue;
            }
            // Tier eligibility
            if (p.Eligible_Tier__c != 'All Tiers' && p.Eligible_Tier__c != memberTier) {
                continue;
            }
            // Category eligibility
            if (String.isNotBlank(p.Product_Category__c)
                && p.Product_Category__c != 'All Categories'
                && String.isNotBlank(productCategory)
                && p.Product_Category__c != productCategory) {
                continue;
            }
            // Channel eligibility
            if (String.isNotBlank(p.Eligible_Channel__c)
                && p.Eligible_Channel__c != 'All Channels'
                && String.isNotBlank(channel)
                && p.Eligible_Channel__c != channel) {
                continue;
            }

            if (p.Is_Stackable__c) {
                stackableApplicable.add(p);
            } else {
                exclusiveApplicable.add(p);
            }
        }

        // Stacking logic:
        // If any exclusive promotion applies → use the highest exclusive multiplier only
        // If only stackable → sum of (multiplier - 1) additive bonuses + 1.0 base
        if (!exclusiveApplicable.isEmpty()) {
            Promotion__c best = exclusiveApplicable[0];
            for (Promotion__c p : exclusiveApplicable) {
                if (p.Bonus_Multiplier__c > best.Bonus_Multiplier__c) {
                    best = p;
                }
            }
            result.multiplier    = best.Bonus_Multiplier__c != null
                ? best.Bonus_Multiplier__c : 1.0;
            result.promotionId   = best.Id;
            result.promotionName = best.Name;
            result.appliedIds.add(best.Id);
            // Increment usage counter for the winning exclusive promotion
            incrementPromotionUsage(new List<Id>{ best.Id });
        } else if (!stackableApplicable.isEmpty()) {
            Decimal additiveBonus = 0;
            for (Promotion__c p : stackableApplicable) {
                Decimal mult = p.Bonus_Multiplier__c != null ? p.Bonus_Multiplier__c : 1.0;
                additiveBonus += (mult - 1.0);
                result.appliedIds.add(p.Id);
                if (result.promotionId == null) {
                    result.promotionId   = p.Id;
                    result.promotionName = p.Name;
                }
            }
            result.multiplier = 1.0 + additiveBonus;
            incrementPromotionUsage(result.appliedIds);
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 2 — incrementPromotionUsage
    // Atomically increments Current_Uses__c using FOR UPDATE lock.
    // ─────────────────────────────────────────────────────────────────────────

    public static List<PromotionUsageResult> incrementPromotionUsage(
        List<Id> promotionIds
    ) {
        List<PromotionUsageResult> usageResults = new List<PromotionUsageResult>();

        if (promotionIds == null || promotionIds.isEmpty()) {
            return usageResults;
        }

        // FOR UPDATE: locks these rows for the duration of this transaction
        // Any concurrent transaction claiming these rows will wait up to 10s
        List<Promotion__c> promos = [
            SELECT Id, Current_Uses__c, Max_Uses__c
            FROM   Promotion__c
            WHERE  Id IN :promotionIds
            FOR UPDATE
        ];

        List<Promotion__c> promosToUpdate = new List<Promotion__c>();

        for (Promotion__c p : promos) {
            PromotionUsageResult ur = new PromotionUsageResult();

            // Re-check cap after locking (another transaction may have filled it)
            if (p.Max_Uses__c != null && p.Max_Uses__c > 0
                && p.Current_Uses__c >= p.Max_Uses__c) {
                ur.success      = false;
                ur.errorMessage = 'Promotion ' + p.Id + ' has reached max usage.';
                usageResults.add(ur);
                continue;
            }

            p.Current_Uses__c = (p.Current_Uses__c != null ? p.Current_Uses__c : 0) + 1;
            promosToUpdate.add(p);
            ur.success = true;
            usageResults.add(ur);
        }

        if (!promosToUpdate.isEmpty()) {
            Database.update(promosToUpdate, false);
        }

        return usageResults;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 3 — getActiveMemberPromotions
    // AuraEnabled — called by promotionBanner LWC.
    // Returns active promotions applicable to the calling member's tier.
    // ─────────────────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<PromotionDisplayDTO> getActiveMemberPromotions(Id memberId) {
        List<PromotionDisplayDTO> displayList = new List<PromotionDisplayDTO>();

        if (memberId == null) {
            return displayList;
        }

        // Get member tier
        List<LoyaltyProgramMember__c> members = [
            SELECT Current_Tier__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :memberId
              AND  Member_Status__c = 'Active'
            WITH   USER_MODE
            LIMIT  1
        ];
        if (members.isEmpty()) {
            return displayList;
        }
        String memberTier = members[0].Current_Tier__c;
        Date   today      = Date.today();

        List<Promotion__c> promos = [
            SELECT Id, Name, Bonus_Multiplier__c, Start_Date__c, End_Date__c,
                   Eligible_Tier__c, Product_Category__c, Description__c, CTA_URL__c
            FROM   Promotion__c
            WHERE  Is_Active__c    = true
              AND  Start_Date__c  <= :today
              AND  End_Date__c    >= :today
              AND  (Eligible_Tier__c = :memberTier
                   OR Eligible_Tier__c = 'All Tiers')
            WITH   USER_MODE
            ORDER BY Bonus_Multiplier__c DESC
            LIMIT  10
        ];

        for (Promotion__c p : promos) {
            PromotionDisplayDTO dto = new PromotionDisplayDTO();
            dto.promotionId     = p.Id;
            dto.name            = p.Name;
            dto.bonusMultiplier = p.Bonus_Multiplier__c != null
                ? p.Bonus_Multiplier__c.setScale(1) + 'x Points' : '1x Points';
            dto.startDate       = p.Start_Date__c;
            dto.endDate         = p.End_Date__c;
            dto.eligibleTier    = p.Eligible_Tier__c;
            dto.productCategory = p.Product_Category__c;
            dto.description     = p.Description__c;
            dto.ctaUrl          = p.CTA_URL__c;
            displayList.add(dto);
        }

        return displayList;
    }
}
