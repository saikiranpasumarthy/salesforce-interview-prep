/**
 * @description Flat-rate partner discount strategy.
 *
 *              Applies a fixed, configurable discount percentage to all Opportunities
 *              from partner accounts (Account.Type = 'Partner'). Non-partner accounts
 *              receive no discount.
 *
 *              The flat rate is injected at construction time by DiscountStrategyFactory,
 *              which reads Discount_Strategy_Config__mdt.Flat_Rate__c — making the rate
 *              source-controlled without a code deploy when business requirements change.
 *
 *              This pattern demonstrates constructor injection (Dependency Injection):
 *              the strategy's behaviour is fully configurable from outside the class,
 *              making it independently testable without SOQL in unit tests.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class FlatRateDiscountStrategy implements IDiscountStrategy {

    @TestVisible private static final String PARTNER_TYPE = 'Partner';

    private final Decimal flatRate;

    /**
     * @param flatRate  Discount fraction 0.0–1.0 (e.g. 0.20 = 20%).
     *                  Enforced to [0.0, 0.50] by OpportunityPricingDomain.
     */
    public FlatRateDiscountStrategy(Decimal flatRate) {
        this.flatRate = flatRate == null ? 0.0 : flatRate;
    }

    public Decimal calculate(Opportunity opp, Account acc) {
        if (acc == null || acc.Type != PARTNER_TYPE) {
            return 0.0;
        }
        return flatRate;
    }
}
