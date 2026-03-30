/**
 * @description Trigger handler for Opportunity — extends TriggerHandler base class
 *              (established Day 1) to participate in the bypass framework.
 *
 *              Routing table:
 *              ┌──────────────────┬────────────────────────────────────────────────┐
 *              │  Event           │  Action                                        │
 *              ├──────────────────┼────────────────────────────────────────────────┤
 *              │  before insert   │  validateAmount → applyDiscounts               │
 *              │  before update   │  validateAmount → applyDiscounts               │
 *              └──────────────────┴────────────────────────────────────────────────┘
 *
 *              Both events call the same two methods — demonstrating DRY extraction
 *              into a private helper rather than copy-pasting logic across overrides.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class OpportunityTriggerHandler extends TriggerHandler {

    private List<Opportunity> newList;
    private Map<Id, Opportunity> oldMap;

    public OpportunityTriggerHandler() {
        this.newList = (List<Opportunity>) Trigger.new;
        this.oldMap  = (Map<Id, Opportunity>) Trigger.oldMap;
    }

    // ─── Event hooks ──────────────────────────────────────────────────────────────
    public override void beforeInsert() {
        handlePricing(newList);
    }

    public override void beforeUpdate() {
        // Only reprice if Amount or Type changed — avoids unnecessary recalculation
        List<Opportunity> changed = new List<Opportunity>();
        for (Opportunity opp : newList) {
            Opportunity old = oldMap.get(opp.Id);
            if (opp.Amount != old.Amount || opp.Type != old.Type) {
                changed.add(opp);
            }
        }
        if (!changed.isEmpty()) {
            handlePricing(changed);
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────────
    private static void handlePricing(List<Opportunity> opps) {
        OpportunityPricingDomain.validateAmount(opps);
        OpportunityPricingService.applyDiscounts(opps);
    }
}
