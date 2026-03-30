/**
 * @description Service layer that orchestrates discount pricing for a list of
 *              Opportunity records.
 *
 *              Orchestration steps (all within a single SOQL query):
 *              1. Collect the unique AccountIds from the incoming Opportunities.
 *              2. Query Account fields needed by loyalty/flat-rate strategies in bulk.
 *              3. For each Opportunity:
 *                 a. Resolve the correct IDiscountStrategy via DiscountStrategyFactory.
 *                 b. Call strategy.calculate(opp, acc) to get the discount fraction.
 *                 c. Delegate field mutation to OpportunityPricingDomain.applyPricing().
 *
 *              Governor limit profile:
 *                - 1 SOQL query regardless of how many Opportunities are in the batch.
 *                - 0 DML (before-trigger context — fields are written to Trigger.new in memory).
 *                - Factory cache ensures CMDT is loaded at most once per transaction.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class OpportunityPricingService {

    /**
     * @description Calculates and stamps Discount_Percent__c and Final_Price__c
     *              on each Opportunity in the list.
     *              Safe to call from a before insert or before update context.
     *
     * @param opps  Opportunity records from Trigger.new (must be mutable).
     */
    public static void applyDiscounts(List<Opportunity> opps) {
        Map<Id, Account> accountsById = fetchAccounts(opps);

        for (Opportunity opp : opps) {
            Account acc = accountsById.get(opp.AccountId);
            IDiscountStrategy strategy =
                DiscountStrategyFactory.getStrategy(opp.Type);
            Decimal discount = strategy.calculate(opp, acc);
            OpportunityPricingDomain.applyPricing(opp, discount);
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────────
    /**
     * @description Bulk-fetches Account records for all Opportunities in one SOQL.
     *              Returns an empty map when no AccountIds are present so callers
     *              can use .get() safely (returns null — strategies handle null acc).
     *
     * @param opps  Opportunity list to extract AccountIds from.
     * @return      Map<Id, Account> keyed by Account.Id.
     */
    private static Map<Id, Account> fetchAccounts(List<Opportunity> opps) {
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }
        if (accountIds.isEmpty()) {
            return new Map<Id, Account>();
        }
        return new Map<Id, Account>([
            SELECT Id, Type, CreatedDate
            FROM   Account
            WHERE  Id IN :accountIds
            WITH   SECURITY_ENFORCED
        ]);
    }
}
