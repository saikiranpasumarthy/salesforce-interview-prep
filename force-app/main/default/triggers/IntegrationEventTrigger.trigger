/**
 * IntegrationEventTrigger
 * ══════════════════════════════════════════════════════════════════════════════
 * Platform Event subscriber trigger for Integration_Event__e.
 *
 * PLATFORM EVENT TRIGGER RULES:
 * ═══════════════════════════════
 * • Only 'after insert' is supported (Platform Events are immutable)
 * • Trigger.new contains the batch of events delivered in this invocation
 * • Trigger.new may contain up to 2,000 events per invocation
 * • Each invocation is a separate transaction from the publisher's transaction
 * • DML is allowed in Platform Event triggers (unlike some async contexts)
 * • Callouts are NOT allowed in Platform Event triggers (use Queueable if needed)
 *
 * ORDERING:
 * ══════════
 * Events are delivered in the order they were published within a transaction.
 * Across transactions, order is not guaranteed.
 *
 * ONE TRIGGER PER OBJECT:
 * ════════════════════════
 * Best practice: one trigger per Platform Event, delegating to a handler class.
 * This follows the same pattern as sObject triggers (Day 1).
 */
trigger IntegrationEventTrigger on Integration_Event__e (after insert) {
    PlatformEventService.handleEvents(Trigger.new);
}
