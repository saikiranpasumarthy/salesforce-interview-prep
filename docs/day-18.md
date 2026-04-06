# Day 18 — Platform Events Deep Dive, CDC, Pub/Sub API

## Topics Covered
1. Platform Events — architecture and event types
2. Publishing: `EventBus.publish()` — single, bulk, chunked
3. Subscribing: Apex trigger, Flow, CometD/SSE
4. Reliable messaging: `setResumeCheckpoint`
5. Change Data Capture (CDC) — header fields, gap events
6. Pub/Sub API — gRPC, external subscribers
7. Platform Events vs CDC comparison

---

## 1. Platform Event Architecture

```
Publisher                    Salesforce Event Bus               Subscribers
─────────                    ────────────────────               ───────────
EventBus.publish(event)  →   persists (72hr)  →  Apex Trigger (after insert)
                                              →  Flow Trigger element
                                              →  CometD / SSE (LWC, Node.js)
                                              →  Pub/Sub API (gRPC — external)
```

### Event Types

| Type | Retention | Delivery | Protocol |
|------|-----------|----------|----------|
| `StandardVolume` | 72 hours | CometD replay, Apex trigger | CometD / SSE |
| `HighVolume` | None | Pub/Sub API only | gRPC (Pub/Sub API) |

### Publish Behavior

| Value | When events are sent |
|-------|----------------------|
| `PublishAfterCommit` | Only when the originating transaction **commits** |
| `PublishImmediately` | Sent immediately — even if transaction **rolls back** |

Use `PublishAfterCommit` (the default) for transactional events tied to data changes.
Use `PublishImmediately` for fire-and-forget monitoring/logging events where rollback doesn't matter.

---

## 2. Publishing

### Single event — `EventBus.publish(event)`

```apex
Database.SaveResult result = EventBus.publish(event);
// IMPORTANT: EventBus.publish does NOT throw on failure
// Check result.isSuccess() explicitly
if (!result.isSuccess()) {
    for (Database.Error e : result.getErrors()) {
        System.debug(e.getStatusCode() + ': ' + e.getMessage());
    }
}
```

### Bulk publish — `EventBus.publish(List<events>)`

```apex
List<Database.SaveResult> results = EventBus.publish(events);
// Partial failures are possible — always iterate results
for (Integer i = 0; i < results.size(); i++) {
    if (!results[i].isSuccess()) {
        System.debug('Event[' + i + '] failed: ' + results[i].getErrors());
    }
}
```

### Governor Limits
- Max **2,000** `EventBus.publish()` calls per transaction
- Max **500,000** StandardVolume events/hour per org
- Chunking is needed only if you exceed 2,000 in a single transaction

---

## 3. Platform Event Trigger

```apex
// Only 'after insert' is supported
trigger IntegrationEventTrigger on Integration_Event__e (after insert) {
    PlatformEventService.handleEvents(Trigger.new);
}
```

Rules:
- **Only `after insert`** — Platform Events are immutable; no before/update/delete
- **No callouts** — use Queueable+AllowsCallouts from within the handler
- **DML is allowed**
- Up to **2,000 events** per trigger invocation
- Separate transaction from the publisher

---

## 4. Reliable Messaging — `setResumeCheckpoint`

```apex
public static void handleEvents(List<Integration_Event__e> events) {
    for (Integration_Event__e event : events) {
        try {
            process(event);
            // Mark as successfully processed — replay resumes AFTER this event
            EventBus.TriggerContext.currentContext()
                .setResumeCheckpoint(event.ReplayId);
        } catch (Exception e) {
            System.debug('Failed: ' + e.getMessage());
            // Set checkpoint to SKIP this event on retry (skip permanently-bad events)
            EventBus.TriggerContext.currentContext()
                .setResumeCheckpoint(event.ReplayId);
        }
    }
}
```

### Retry Behavior
- If trigger throws unhandled exception → event bus retries from last checkpoint
- After ~3 retries → event goes to **Dead Letter Queue** (visible in Event Monitoring)
- Setting checkpoint on bad events = intentional skip ("poison message" pattern)

### Replay IDs
- `-2` = replay from earliest (full 72hr window)
- `-1` = replay from latest (only new events)
- `<n>` = replay all events after that ReplayId

---

## 5. Change Data Capture (CDC)

CDC automatically publishes change events whenever Salesforce records are created, updated, deleted, or undeleted.

### Enabling CDC
Setup → Integrations → Change Data Capture → select objects
OR metadata `<changedObjects>` in a `ChangeDataCapture` configuration.

### CDC Trigger

```apex
trigger AccountChangeTrigger on AccountChangeEvent (after insert) {
    CdcEventHandler.handleAccountChanges(Trigger.new);
}
```

### `EventBus.ChangeEventHeader` Fields

| Field | Type | Description |
|-------|------|-------------|
| `changeType` | String | `CREATE \| UPDATE \| DELETE \| UNDELETE` |
| `getChangedFields()` | `List<String>` | API names of changed fields (UPDATE only) |
| `getRecordIds()` | `List<String>` | IDs of affected records (NOT `List<Id>`) |
| `entityName` | String | sObject API name (e.g., `'Account'`) |
| `transactionKey` | String | Unique key for the originating transaction |
| `commitUser` | String | ID of user who triggered the change |
| `nulledFields` | `List<String>` | Fields explicitly set to null |

### Processing CDC Events

```apex
public static void handleAccountChanges(List<AccountChangeEvent> events) {
    for (AccountChangeEvent event : events) {
        EventBus.ChangeEventHeader header = event.ChangeEventHeader;
        Set<Id> recordIds = toIdSet(header.getRecordIds());

        if (isGapEvent(header)) {
            // Re-query for full state — do not trust partial payload
            processGaps(recordIds);
            continue;
        }

        switch on header.changeType {
            when 'CREATE'   { processCreates(recordIds); }
            when 'UPDATE'   { routeUpdate(event, header, updateIds); }
            when 'DELETE'   { processDeletions(recordIds); }
            when 'UNDELETE' { processCreates(recordIds); }
        }
    }
}
```

### Gap Events

A gap event occurs when:
1. The subscriber falls behind — event bus fast-forwards with a gap marker
2. The changed payload exceeds the max event size

**Detection:** `changedFields` contains `'_SystemModstamp'`

```apex
static Boolean isGapEvent(EventBus.ChangeEventHeader header) {
    if (header.changeType != 'UPDATE') { return false; }
    List<String> changedFields = header.getChangedFields();
    return changedFields != null && changedFields.contains('_SystemModstamp');
}
```

**Response:** Re-query the full record(s) for current state.

### `getRecordIds()` Returns `List<String>`, Not `List<Id>`

```apex
// WRONG — compile error
List<Id> ids = header.getRecordIds();

// CORRECT — cast each string to Id
static Set<Id> toIdSet(List<String> idStrings) {
    Set<Id> ids = new Set<Id>();
    for (String s : idStrings) {
        if (String.isNotBlank(s)) {
            try { ids.add((Id) s); } catch (Exception e) { /* skip malformed */ }
        }
    }
    return ids;
}
```

### Bulk CDC Events

A single CDC event can contain **multiple record IDs** (e.g., a mass-update triggers one event with up to 200 record IDs). Always call `header.getRecordIds()` — never assume a single ID.

---

## 6. Platform Events vs CDC

| Aspect | Platform Events | Change Data Capture |
|--------|----------------|---------------------|
| **Trigger** | Manual `EventBus.publish()` | Automatic — any DML on enabled object |
| **Payload** | Custom fields you define | Changed field values + header metadata |
| **Event object** | `Your_Event__e` | `AccountChangeEvent`, `Order__ChangeEvent`, etc. |
| **Change metadata** | None | `changeType`, `changedFields`, `transactionKey` |
| **Use case** | Business process events | Sync, audit, integration — data change awareness |
| **Replay** | StandardVolume: 72hr | 3 days |
| **Gap events** | N/A | Yes — `_SystemModstamp` sentinel |

---

## 7. Pub/Sub API

The Pub/Sub API is a **gRPC-based** interface for external systems to subscribe to Salesforce events.

### Key Facts
- Uses **Apache Avro** binary serialization (not JSON)
- Supports **HighVolume** events only (StandardVolume supported in newer releases)
- External clients: Java, Node.js, Python using gRPC stubs generated from Salesforce proto files
- Supports **flow control** (subscriber requests N events at a time)
- Authentication: OAuth 2.0 access token in `Authorization: Bearer` header

### When to Use
- External systems (outside Salesforce) need to subscribe to events
- High-throughput scenarios where CometD overhead is undesirable
- Event-driven architecture with microservices

---

## 8. Testing Platform Events

```apex
// Publishing — use Test.startTest()/stopTest() to flush event queue
@IsTest
static void testTriggerFires() {
    Integration_Event__e event = new Integration_Event__e(...);
    Test.startTest();
    EventBus.publish(event);
    Test.stopTest(); // trigger fires here synchronously
    // Assert on side-effects (DML performed in trigger handler)
}

// CDC — requires Test.enableChangeDataCapture()
@IsTest
static void testCdcCreate() {
    Test.enableChangeDataCapture();
    Test.startTest();
    Account acc = new Account(Name = 'Test');
    insert acc;
    Test.stopTest(); // AccountChangeTrigger fires here
    // Assert no exception = success (or assert DML side-effects)
}
```

---

## Interview Q&A

**Q: What is the difference between `PublishAfterCommit` and `PublishImmediately`?**
A: `PublishAfterCommit` (default) sends events only when the publishing transaction commits — if the transaction rolls back, no event is sent. `PublishImmediately` sends events right away, regardless of whether the publishing transaction commits. Use `PublishImmediately` for fire-and-forget observability events; use `PublishAfterCommit` for events that carry data-driven meaning (the downstream should only act on committed data).

**Q: Why doesn't `EventBus.publish()` throw an exception on failure?**
A: By design — publishing is treated as a best-effort async operation. The method returns `Database.SaveResult[]` where you must check `isSuccess()`. This is a common pitfall: teams assume publish succeeded and never inspect results. Always iterate the results and log or re-queue failures.

**Q: What is a gap event and how do you handle it?**
A: A gap event is a CDC event where `changedFields` contains `'_SystemModstamp'`. It signals the subscriber fell behind (event bus skipped events) or the payload exceeded max size. The correct response is to re-query the full record(s) for current state rather than relying on the partial payload. The handler should treat a gap event like a full refresh signal.

**Q: Why does `header.getRecordIds()` return `List<String>` instead of `List<Id>`?**
A: CDC is a platform-level mechanism that must work across API versions and potential future object types where IDs might not be 15/18-char Salesforce IDs. The type is `List<String>` by design. In Apex, cast each element individually: `(Id) idString`, wrapped in try/catch to handle malformed values.

**Q: How does `setResumeCheckpoint` prevent infinite retry loops on bad events?**
A: When the trigger processes each event, it calls `setResumeCheckpoint(event.ReplayId)` after handling it — success or failure. If a later event causes an unhandled exception and the trigger retries, replay starts from the last checkpoint, skipping already-processed events. For permanently bad events (parse errors, invalid payload), deliberately setting the checkpoint before re-throwing skips that event on the next replay attempt.

**Q: Can you make callouts inside a Platform Event trigger?**
A: No. Platform Event triggers run in an async context that doesn't allow callouts. To make a callout in response to a Platform Event, enqueue a `Queueable` that implements `Database.AllowsCallouts` from within the trigger handler.

**Q: What is the difference between Platform Events and CDC?**
A: Platform Events require explicit `EventBus.publish()` calls and carry a custom payload you define. CDC is automatic — the platform generates events for every DML on enabled objects, with a structured header (`changeType`, `changedFields`, `getRecordIds()`). Use Platform Events for business-logic events (order placed, payment received). Use CDC for integration / audit scenarios where you need to react to any data change without modifying the DML code.

**Q: How does the Pub/Sub API differ from CometD?**
A: CometD is HTTP long-polling (Bayeux protocol), suitable for browser clients and simple external subscribers. The Pub/Sub API uses gRPC with Avro binary serialization — it's more efficient for high-throughput external system subscriptions. It also supports HighVolume events (no retention) and flow control (subscriber requests N events). Choose CometD for existing tooling/browser use; choose Pub/Sub API for new microservice integrations needing performance.
