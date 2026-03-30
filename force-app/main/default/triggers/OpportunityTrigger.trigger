/**
 * @description Single-method Opportunity trigger — delegates immediately to the
 *              handler class, keeping all logic out of the trigger file itself.
 *              Follows the same one-trigger-per-object pattern established in Day 1.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
trigger OpportunityTrigger on Opportunity (
    before insert,
    before update
) {
    new OpportunityTriggerHandler().run();
}
