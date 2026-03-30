/**
 * @description Domain layer for Opportunity pricing validation and computation.
 *
 *              Separation of Concerns in this architecture:
 *              ┌──────────────────────────────────────────────────────┐
 *              │  Layer              │  Responsibility                │
 *              ├──────────────────────────────────────────────────────┤
 *              │  Trigger            │  Invocation only               │
 *              │  TriggerHandler     │  Event routing, bulk prep      │
 *              │  Domain (this)      │  Field validation, bounds, SoC │
 *              │  Service            │  Orchestration, Account query  │
 *              │  Strategy           │  Discount algorithm            │
 *              │  Factory            │  Strategy resolution via CMDT  │
 *              └──────────────────────────────────────────────────────┘
 *
 *              The Domain class owns:
 *                - Guard: Amount must be positive
 *                - Guard: Discount must be in [0%, 50%] (business rule cap)
 *                - Computation: apply discount to Amount → Final_Price__c
 *                - Computation: store discount percentage → Discount_Percent__c
 *
 *              It deliberately does NOT query the database — that is the Service's job.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class OpportunityPricingDomain {

    @TestVisible private static final Decimal MAX_DISCOUNT = 0.50;
    @TestVisible private static final Decimal MIN_DISCOUNT = 0.00;

    /**
     * @description Validates that Amount is positive.
     *              Called by the handler before applyPricing().
     *
     * @param opps  Opportunity records from Trigger.new.
     */
    public static void validateAmount(List<Opportunity> opps) {
        for (Opportunity opp : opps) {
            if (opp.Amount != null && opp.Amount < 0) {
                opp.Amount.addError(
                    'Opportunity Amount cannot be negative.');
            }
        }
    }

    /**
     * @description Applies a discount fraction to an Opportunity record in place.
     *              Enforces the [0%, 50%] business-rule cap before writing fields.
     *
     *              Final_Price__c = Amount × (1 - clampedDiscount)
     *              Discount_Percent__c = clampedDiscount × 100 (rounded 2 dp)
     *
     * @param opp       Opportunity to mutate (must have Amount populated).
     * @param discount  Raw discount fraction from IDiscountStrategy.calculate().
     */
    public static void applyPricing(Opportunity opp, Decimal discount) {
        if (opp.Amount == null || opp.Amount <= 0) {
            opp.Discount_Percent__c = 0;
            opp.Final_Price__c      = opp.Amount;
            return;
        }

        Decimal clamped = clamp(discount, MIN_DISCOUNT, MAX_DISCOUNT);
        opp.Discount_Percent__c = (clamped * 100).setScale(2);
        opp.Final_Price__c      = (opp.Amount * (1 - clamped)).setScale(2);
    }

    // ─── Private helpers ──────────────────────────────────────────────────────────
    private static Decimal clamp(Decimal value, Decimal min, Decimal max) {
        if (value == null) return min;
        return value < min ? min : (value > max ? max : value);
    }
}
