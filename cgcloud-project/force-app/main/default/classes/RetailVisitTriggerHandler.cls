/**
 * @description Trigger handler for RetailVisit__c.
 *              Extends the shared TriggerHandler base class (bypass-registry pattern).
 *              Routes each trigger context to the appropriate RetailVisitService method.
 *
 *              beforeUpdate  → validateVisitCheckIn (time-window gate)
 *              afterInsert   → createActivityTasks  (Activity Plan Template → Tasks)
 *              afterUpdate   → handleVisitCompletion (duration, follow-up, Platform Event)
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
public with sharing class RetailVisitTriggerHandler extends TriggerHandler {

    protected override String getHandlerName() {
        return 'RetailVisitTriggerHandler';
    }

    // ─── Before Update ────────────────────────────────────────────────────────
    protected override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
        RetailVisitService.validateVisitCheckIn(
            (List<RetailVisit__c>) newRecords,
            (Map<Id, RetailVisit__c>) oldMap
        );
    }

    // ─── After Insert ─────────────────────────────────────────────────────────
    protected override void afterInsert(List<SObject> newRecords) {
        RetailVisitService.createActivityTasks(
            (List<RetailVisit__c>) newRecords
        );
    }

    // ─── After Update ─────────────────────────────────────────────────────────
    protected override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
        RetailVisitService.handleVisitCompletion(
            (List<RetailVisit__c>) newRecords,
            (Map<Id, RetailVisit__c>) oldMap
        );
    }
}
