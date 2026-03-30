/**
 * @description Amount-based tiered discount strategy.
 *
 *              Incentivises larger deals with progressively higher discounts.
 *              Tiers are hardcoded as @TestVisible constants — in a production system
 *              with frequently-changing thresholds, load them from a child CMDT instead.
 *
 *              Tier table:
 *              ┌──────────────────────┬────────────┐
 *              │ Opportunity Amount   │  Discount  │
 *              ├──────────────────────┼────────────┤
 *              │ null or ≤ 0          │    0%      │
 *              │ > 0 and < 10,000     │    5%      │
 *              │ 10,000 – 99,999      │   10%      │
 *              │ ≥ 100,000            │   15%      │
 *              └──────────────────────┴────────────┘
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class TieredDiscountStrategy implements IDiscountStrategy {

    @TestVisible private static final Decimal TIER_HIGH_THRESHOLD = 100000;
    @TestVisible private static final Decimal TIER_MED_THRESHOLD  = 10000;

    @TestVisible private static final Decimal DISCOUNT_HIGH       = 0.15;
    @TestVisible private static final Decimal DISCOUNT_MED        = 0.10;
    @TestVisible private static final Decimal DISCOUNT_LOW        = 0.05;
    @TestVisible private static final Decimal DISCOUNT_NONE       = 0.00;

    public Decimal calculate(Opportunity opp, Account acc) {
        if (opp.Amount == null || opp.Amount <= 0) {
            return DISCOUNT_NONE;
        }
        if (opp.Amount >= TIER_HIGH_THRESHOLD) {
            return DISCOUNT_HIGH;
        }
        if (opp.Amount >= TIER_MED_THRESHOLD) {
            return DISCOUNT_MED;
        }
        return DISCOUNT_LOW;
    }
}
