/**
 * PlatformEventService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 18 — Platform Events: publishing, subscribing, and reliable messaging.
 *
 * ARCHITECTURE OVERVIEW:
 * ═══════════════════════
 *   Publisher  →  EventBus.publish()  →  Salesforce Event Bus
 *                                              ↓
 *                              ┌───────────────┴───────────────┐
 *                        Apex Trigger        Flow Trigger       CometD/SSE
 *                     (after insert)       (Platform Event    (external subscribers:
 *                                           trigger element)   LWC, Node.js, Java)
 *
 * DELIVERY GUARANTEES:
 * ═════════════════════
 * At-least-once delivery — subscribers may receive the same event more than once.
 * Use correlation ID + idempotency key in subscriber to deduplicate.
 *
 * REPLAY:
 * ════════
 * StandardVolume events are stored for 72 hours.
 * Subscribers can replay from:
 *   -2  = earliest (all events in the 72hr window)
 *   -1  = latest (only new events from now)
 *   <n> = specific replayId (all events after that Id)
 *
 * PUBLISHING LIMITS:
 * ═══════════════════
 * • Max 2,000 EventBus.publish() calls per transaction (single or bulk)
 * • Max 500,000 StandardVolume events/hour per org
 * • PublishAfterCommit: transaction must commit for events to be sent
 * • PublishImmediately: events sent even if transaction rolls back
 */
public with sharing class PlatformEventService {

    // ─────────────────────────────────────────────────────────────────────────
    // Publishing — single event
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Publishes a single Platform Event.
     * Returns the SaveResult — check isSuccess() before proceeding.
     */
    public static Database.SaveResult publishOne(Integration_Event__e event) {
        Database.SaveResult result = EventBus.publish(event);
        if (!result.isSuccess()) {
            String errors = buildErrorString(result.getErrors());
            throw new EventPublishException('Failed to publish event: ' + errors);
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Publishing — bulk (recommended for high-volume scenarios)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Publishes a list of Platform Events in bulk.
     * Returns all SaveResults so callers can inspect partial failures.
     *
     * Unlike DML, EventBus.publish() does NOT throw on failure — it returns
     * SaveResult[].isSuccess() = false for each failed event.
     * Always check results; silent failures are a common pitfall.
     */
    public static List<Database.SaveResult> publishBulk(
            List<Integration_Event__e> events) {

        List<Database.SaveResult> results = EventBus.publish(events);
        List<String> failures = new List<String>();

        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                failures.add('Event[' + i + ']: ' + buildErrorString(results[i].getErrors()));
            }
        }
        if (!failures.isEmpty()) {
            System.debug(LoggingLevel.ERROR,
                'Platform Event publish failures: ' + String.join(failures, ' | '));
        }
        return results;
    }

    /**
     * Publishes in chunks of 2,000 to stay within governor limits when the input
     * list could exceed the per-transaction publish limit.
     * Each chunk is published in the SAME transaction (no async needed for ≤2,000).
     */
    public static List<Database.SaveResult> publishChunked(
            List<Integration_Event__e> events) {

        List<Database.SaveResult> allResults = new List<Database.SaveResult>();
        Integer chunkSize = 2000;
        for (Integer i = 0; i < events.size(); i += chunkSize) {
            Integer end = Math.min(i + chunkSize, events.size());
            List<Integration_Event__e> chunk = new List<Integration_Event__e>();
            for (Integer j = i; j < end; j++) { chunk.add(events[j]); }
            allResults.addAll(EventBus.publish(chunk));
        }
        return allResults;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Event factory methods
    // ─────────────────────────────────────────────────────────────────────────

    public static Integration_Event__e accountSyncEvent(Id accountId, String changeType) {
        return new Integration_Event__e(
            Event_Type__c    = 'ACCOUNT_SYNC',
            Source_System__c = 'Salesforce',
            Correlation_Id__c = accountId,
            Payload__c       = JSON.serialize(new Map<String, String>{
                'accountId'  => accountId,
                'changeType' => changeType
            }, true)
        );
    }

    public static Integration_Event__e errorEvent(String source, String message, String correlationId) {
        return new Integration_Event__e(
            Event_Type__c    = 'ERROR',
            Source_System__c = source,
            Correlation_Id__c = correlationId,
            Payload__c       = JSON.serialize(new Map<String, String>{
                'message'       => message,
                'correlationId' => correlationId,
                'timestamp'     => String.valueOf(Datetime.now())
            }, true)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Subscriber / trigger handler — called from IntegrationEventTrigger
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Processes a batch of Platform Events from the trigger.
     *
     * RELIABLE MESSAGING PATTERN:
     *  1. Process each event individually with try/catch
     *  2. After successful processing, setResumeCheckpoint(replayId)
     *     → If the trigger fails AFTER this point, replay starts from here
     *     → Events before the checkpoint are NOT re-delivered
     *  3. For unrecoverable errors, log and set checkpoint to SKIP the event
     *     → This prevents the event bus from retrying a permanently-bad event
     *     → For transient errors, consider NOT setting checkpoint (allow retry)
     *
     * TRIGGER RETRY BEHAVIOUR:
     *  • If the trigger throws an unhandled exception: event bus retries
     *    the entire batch from the last checkpoint (or from beginning if none set)
     *  • After ~3 failed retries: event is marked as "stuck" and sent to Dead Letter Queue
     *    (requires Event Monitoring to inspect)
     */
    public static void handleEvents(List<Integration_Event__e> events) {
        List<Integration_Event__e> accountSyncEvents = new List<Integration_Event__e>();
        List<Integration_Event__e> errorEvents       = new List<Integration_Event__e>();

        for (Integration_Event__e event : events) {
            try {
                routeEvent(event, accountSyncEvents, errorEvents);
                // Mark this event as successfully routed — replay starts AFTER this on failure
                EventBus.TriggerContext.currentContext()
                    .setResumeCheckpoint(event.ReplayId);
            } catch (Exception e) {
                // Log error but set checkpoint to skip this bad event on retry
                System.debug(LoggingLevel.ERROR,
                    'Failed to route event ReplayId=' + event.ReplayId
                    + ' Type=' + event.Event_Type__c + ': ' + e.getMessage());
                EventBus.TriggerContext.currentContext()
                    .setResumeCheckpoint(event.ReplayId);
            }
        }

        // Batch-process grouped events — one SOQL/DML per type
        if (!accountSyncEvents.isEmpty()) {
            processAccountSyncEvents(accountSyncEvents);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static void routeEvent(
            Integration_Event__e event,
            List<Integration_Event__e> accountSyncEvents,
            List<Integration_Event__e> errorEvents) {

        String eventType = event.Event_Type__c;
        if (eventType == 'ACCOUNT_SYNC') {
            accountSyncEvents.add(event);
        } else if (eventType == 'ERROR') {
            errorEvents.add(event);
            System.debug(LoggingLevel.ERROR, 'Error event received: ' + event.Payload__c);
        } else {
            System.debug(LoggingLevel.WARN, 'Unknown event type: ' + eventType);
        }
    }

    private static void processAccountSyncEvents(List<Integration_Event__e> events) {
        Set<Id> accountIds = new Set<Id>();
        for (Integration_Event__e e : events) {
            if (String.isNotBlank(e.Correlation_Id__c)) {
                try {
                    accountIds.add((Id) e.Correlation_Id__c);
                } catch (Exception ex) { /* invalid Id format */ }
            }
        }
        if (accountIds.isEmpty()) { return; }

        // Example: queue accounts for external sync
        List<Account> accounts = [
            SELECT Id, Name, Type, Sync_Status__c
            FROM   Account
            WHERE  Id IN :accountIds
            WITH   SECURITY_ENFORCED
        ];
        List<Account> toUpdate = new List<Account>();
        for (Account acc : accounts) {
            if (acc.Sync_Status__c != 'Synced') {
                toUpdate.add(new Account(Id = acc.Id, Sync_Status__c = 'Pending'));
            }
        }
        if (!toUpdate.isEmpty()) { update toUpdate; }
    }

    private static String buildErrorString(List<Database.Error> errors) {
        List<String> msgs = new List<String>();
        for (Database.Error e : errors) {
            msgs.add(e.getStatusCode() + ': ' + e.getMessage());
        }
        return String.join(msgs, ', ');
    }

    public class EventPublishException extends Exception {}
}
