/**
 * AccountChangeTrigger
 * ══════════════════════════════════════════════════════════════════════════════
 * CDC subscriber trigger for AccountChangeEvent.
 *
 * CDC TRIGGER NOTES:
 * ═══════════════════
 * • Fires after ANY change to an Account record (insert/update/delete/undelete)
 * • Only fires if CDC is enabled for Account in Setup → Change Data Capture
 * • Trigger.new contains AccountChangeEvent objects (NOT Account records)
 * • Each AccountChangeEvent has a ChangeEventHeader + only the CHANGED fields
 *   (not the full record) — use header.getRecordIds() to get affected record IDs
 * • For field values: event.Name contains the new Name ONLY if Name was changed;
 *   otherwise it is null (check changedFields to know what was included)
 * • Bulk operations: multiple record IDs can appear in a single event
 *   (e.g. a mass-update may produce one event with 200 recordIds)
 *
 * GOVERNOR LIMITS:
 * ════════════════
 * • 250,000 CDC trigger invocations per hour per org
 * • DML allowed; callouts NOT allowed (use Queueable)
 * • Up to 2,000 events per trigger invocation
 *
 * ENABLING:
 * ══════════
 * This trigger only works if Account CDC is enabled:
 *   Setup → Integrations → Change Data Capture → select Account
 */
trigger AccountChangeTrigger on AccountChangeEvent (after insert) {
    CdcEventHandler.handleAccountChanges(Trigger.new);
}
