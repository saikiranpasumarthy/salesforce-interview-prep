/**
 * @description Trigger for RetailVisit__c object.
 *              Delegates all logic to RetailVisitTriggerHandler.
 *              Events: before update (check-in validation),
 *                      after insert (activity task creation),
 *                      after update (visit completion handling).
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 */
trigger RetailVisitTrigger on RetailVisit__c (before update, after insert, after update) {
    new RetailVisitTriggerHandler().run();
}
