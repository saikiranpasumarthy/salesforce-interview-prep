/**
 * @description Entry point for all Account trigger events. Contains zero business logic —
 *              delegates entirely to AccountTriggerHandler via the TriggerHandler framework.
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
trigger AccountTrigger on Account (
    before insert, before update, before delete,
    after insert,  after update,  after delete,  after undelete
) {
    new AccountTriggerHandler().run();
}
