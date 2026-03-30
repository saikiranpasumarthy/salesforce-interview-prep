/**
 * @description Platform Event subscriber trigger for Integration_Error_Log__e.
 *              Fires in a separate async transaction whenever IntegrationErrorLogger
 *              publishes one or more events. Writes events to Integration_Error_Log__c
 *              for persistent, queryable error history.
 *
 *              Key Platform Event trigger behaviours:
 *                - Context is always AFTER INSERT — Platform Events are insert-only;
 *                  there is no before insert, no update, no delete.
 *                - Trigger.new contains all events published in the same micro-batch
 *                  (up to 2,000 events per trigger invocation for HighVolume events).
 *                - This trigger runs in its own governor limit context — failures here
 *                  do NOT roll back the original publishing transaction.
 *                - ReplayId on each event record provides the event stream position.
 *                  Store it on the log record for replay debugging.
 *                - EventUuid (API 55+) is the globally unique event identifier used
 *                  for deduplication — Event_UUID__c is set as externalId=true, unique=true.
 *
 *              Error handling:
 *                Database.insert(list, false) — partial success so one bad log record
 *                does not abort the rest. Failures here use System.debug only (can't
 *                recurse back into IntegrationErrorLogger).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
trigger IntegrationErrorLogTrigger on Integration_Error_Log__e (after insert) {

    List<Integration_Error_Log__c> logRecords = new List<Integration_Error_Log__c>();

    for (Integration_Error_Log__e event : Trigger.new) {
        logRecords.add(new Integration_Error_Log__c(
            Context__c        = event.Context__c,
            Error_Message__c  = event.Error_Message__c,
            Record_Id__c      = event.Record_Id__c,
            Status_Code__c    = event.Status_Code__c,
            Replay_Id__c      = event.ReplayId,
            Event_UUID__c     = event.EventUuid
        ));
    }

    if (logRecords.isEmpty()) { return; }

    List<Database.SaveResult> results = Database.insert(logRecords, false);

    for (Database.SaveResult sr : results) {
        if (!sr.isSuccess()) {
            for (Database.Error err : sr.getErrors()) {
                // Cannot use IntegrationErrorLogger here — would cause infinite recursion
                System.debug(LoggingLevel.ERROR,
                    'IntegrationErrorLogTrigger: Failed to insert log record. '
                    + err.getStatusCode() + ' | ' + err.getMessage()
                );
            }
        }
    }
}
