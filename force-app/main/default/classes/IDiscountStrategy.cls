/**
 * @description Strategy interface for Opportunity discount calculation.
 *
 *              Every discount algorithm — tiered by amount, loyalty by account age,
 *              flat-rate partner — implements this single contract. The Strategy Pattern
 *              eliminates branching (if/else, switch) from the service layer: the service
 *              asks the Factory for the right implementation and calls calculate(); it
 *              never inspects the strategy type at runtime.
 *
 *              Adding a new discount algorithm requires:
 *                1. A new class that implements IDiscountStrategy
 *                2. A new Discount_Strategy_Config__mdt record pointing to that class
 *                3. Zero changes to DiscountStrategyFactory, OpportunityPricingService,
 *                   or OpportunityTriggerHandler  ← Open/Closed Principle in practice
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public interface IDiscountStrategy {

    /**
     * @param opp  Opportunity with at minimum Amount populated.
     * @param acc  Account associated with the Opportunity; null if no AccountId.
     * @return     Discount multiplier in the range 0.0–1.0.
     *             0.10 means 10% off; 0.0 means no discount.
     *             Callers (via OpportunityPricingDomain) enforce the 0–50% bound.
     */
    Decimal calculate(Opportunity opp, Account acc);
}
