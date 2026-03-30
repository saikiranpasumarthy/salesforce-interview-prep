/**
 * @description Account-age loyalty discount strategy.
 *
 *              Rewards long-standing customers with progressively higher discounts
 *              based on how long their Account record has existed in Salesforce.
 *              Uses month arithmetic (not millisecond subtraction) to avoid DST
 *              and leap-year edge cases.
 *
 *              Tier table (months since Account.CreatedDate):
 *              ┌───────────────────┬────────────┐
 *              │ Account Age       │  Discount  │
 *              ├───────────────────┼────────────┤
 *              │ null Account      │    0%      │
 *              │ < 12 months       │    0%      │
 *              │ 12 – 35 months    │    5%      │
 *              │ 36 – 59 months    │   10%      │
 *              │ ≥ 60 months       │   15%      │
 *              └───────────────────┴────────────┘
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class LoyaltyDiscountStrategy implements IDiscountStrategy {

    @TestVisible private static final Integer MONTHS_SENIOR   = 60;
    @TestVisible private static final Integer MONTHS_MID      = 36;
    @TestVisible private static final Integer MONTHS_JUNIOR   = 12;

    @TestVisible private static final Decimal DISCOUNT_SENIOR = 0.15;
    @TestVisible private static final Decimal DISCOUNT_MID    = 0.10;
    @TestVisible private static final Decimal DISCOUNT_JUNIOR = 0.05;
    @TestVisible private static final Decimal DISCOUNT_NONE   = 0.00;

    public Decimal calculate(Opportunity opp, Account acc) {
        if (acc == null || acc.CreatedDate == null) {
            return DISCOUNT_NONE;
        }
        Integer ageMonths = monthsBetween(acc.CreatedDate, System.now());
        if (ageMonths >= MONTHS_SENIOR) return DISCOUNT_SENIOR;
        if (ageMonths >= MONTHS_MID)    return DISCOUNT_MID;
        if (ageMonths >= MONTHS_JUNIOR) return DISCOUNT_JUNIOR;
        return DISCOUNT_NONE;
    }

    /**
     * @description Calculates whole months between two DateTimes using year/month
     *              arithmetic. Avoids fractional-month errors from millisecond subtraction.
     *
     * @param earlier  The earlier DateTime (e.g., Account.CreatedDate).
     * @param later    The later DateTime (e.g., System.now()).
     * @return         Integer month count — may be negative if earlier > later.
     */
    @TestVisible
    private static Integer monthsBetween(DateTime earlier, DateTime later) {
        return ((later.year() - earlier.year()) * 12)
               + (later.month() - earlier.month());
    }
}
