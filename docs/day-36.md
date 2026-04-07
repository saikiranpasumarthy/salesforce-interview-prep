# Day 36 — End-to-End System Design, Multi-Cloud Architecture, Full Solution

## Topics Covered

- System Design principles for large-scale Salesforce
- Multi-Cloud Architecture patterns (Sales + Service + Marketing + Data Cloud + Agentforce)
- Circuit Breaker pattern — preventing cascading failures
- Saga Pattern — distributed transactions without 2PC
- Event-Driven Architecture — Platform Events as integration backbone
- Governor limit-aware bulk processing with Queueable chaining
- Idempotency at scale — deduplicating event processing
- Retry with exponential backoff — non-retryable error detection
- Dead Letter Queue — failed message management
- Lead 360 and Case routing orchestration

---

## Multi-Cloud Architecture — Full Data Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                     SALESFORCE MULTI-CLOUD                           │
│                                                                      │
│  ┌─────────────┐    Platform Events    ┌──────────────────────────┐  │
│  │  Sales Cloud │ ──────────────────► │  Data Cloud              │  │
│  │  (Lead, Opp) │                     │  (Unified Profile)       │  │
│  └──────┬───────┘                     └─────────┬────────────────┘  │
│         │                                       │                   │
│  Einstein Scoring                        Data Actions              │
│         │                                       │                   │
│  ┌──────▼───────┐    Platform Events    ┌───────▼────────────────┐  │
│  │  Agentforce  │ ◄──────────────────  │  Marketing Cloud       │  │
│  │  (AI Agent)  │                     │  (Journey Builder)      │  │
│  └──────┬───────┘                     └────────────────────────┘  │
│         │                                                           │
│  PendingServiceRouting                                              │
│         │                                                           │
│  ┌──────▼───────┐                                                   │
│  │ Service Cloud│                                                   │
│  │  (Case/Chat) │                                                   │
│  └──────────────┘                                                   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 1. Circuit Breaker Pattern

### Problem
When an external service (ERP, payment gateway, shipping API) starts failing, Apex callouts will exhaust governor limits or time out — causing a cascade that affects unrelated functionality.

### Solution: Three-State Circuit Breaker

```
CLOSED ──(failureCount >= threshold)──► OPEN
  ▲                                       │
  │                                   (timeout elapsed)
  │                                       ▼
  └────(recordSuccess)────────────── HALF_OPEN
                                     (probe 1-2 requests)
```

```apex
// Before every callout:
if (!SystemDesignService.allowRequest('PaymentGateway')) {
    throw new CircuitOpenException('PaymentGateway circuit is OPEN. Fast-fail.');
}
try {
    HttpResponse resp = http.send(req);
    SystemDesignService.recordSuccess('PaymentGateway');
    return resp;
} catch (Exception e) {
    SystemDesignService.recordFailure('PaymentGateway');
    throw e;
}
```

### Configuration
| Parameter | Default | Purpose |
|-----------|---------|---------|
| `FAILURE_THRESHOLD` | 5 | Failures to trip circuit to OPEN |
| `RESET_TIMEOUT_SECS` | 60 | Seconds before testing recovery (HALF_OPEN) |
| `HALF_OPEN_PROBE_MAX` | 2 | Max probe requests before re-opening |

### Storage
In production, store circuit state in **Custom Settings** (org-wide) or **Platform Cache** for persistence across transactions. The static map implementation in this codebase resets per transaction — sufficient for within-transaction protection.

---

## 2. Saga Pattern — Distributed Transactions

### Problem
Salesforce's DML is atomic within a single transaction, but multi-step business processes that span multiple systems (Salesforce + ERP + inventory + fulfillment) cannot use a single transaction. **2PC (Two-Phase Commit) is not available** across distributed systems.

### Solution: Compensating Transactions

```
Step 1: Validate Quote      ──► (read-only, no compensation)
Step 2: Reserve Inventory   ──► compensate: release reservation
Step 3: Create Order        ──► compensate: delete Order
Step 4: Notify Fulfillment  ──► compensate: send cancellation event

On failure at Step 3:
  → compensate Step 2 (release inventory)
  → compensate Step 1 (no-op)
  → return SagaResult.failure(error)
```

```apex
SagaOrchestrator saga = new SagaOrchestrator('Q2O_' + quoteId);
saga.addStep(new ValidateQuoteStep(quoteId));
saga.addStep(new ReserveInventoryStep(quoteId));
saga.addStep(new CreateOrderStep(quoteId));
saga.addStep(new NotifyFulfillmentStep(quoteId));
SagaResult result = saga.execute();

if (!result.isSuccess) {
    // Compensation already ran automatically
    // Log + notify ops team
}
```

### Saga vs 2PC

| | Saga | 2PC |
|--|------|-----|
| Locking | No cross-step locks | Locks all resources until commit |
| Failure handling | Compensating transactions | Rollback |
| Availability | High | Lower (locks block other operations) |
| Complexity | Higher (must write compensations) | Lower (DB handles rollback) |
| Supported in SF | ✅ Yes | ❌ No |

---

## 3. Governor Limit-Aware Bulk Processing

### Problem
Batch Apex has a 2-minute governor. Synchronous Apex has 10 seconds. Processing 10,000 records in a trigger or Queueable can hit DML, SOQL, or CPU limits.

### Solution: Chunk + Monitor + Chain

```apex
// Process in chunks; hand off remainder to Queueable when limits approach 85%
for (Integer offset = 0; offset < recordIds.size(); offset += chunkSize) {
    LimitSnapshot snap = SystemDesignService.snapshotLimits();
    if (!SystemDesignService.hasHeadroom(snap.dmlPct(), snap.cpuPct())) {
        // Enqueue remainder — fresh transaction = fresh limits
        System.enqueueJob(new ChainedQueueable(remainingIds, chunkSize, processorClass));
        return; // Stop processing in this transaction
    }
    // Process chunk...
}
```

### Governor Limit Quick Reference

| Limit | Synchronous | Asynchronous |
|-------|------------|-------------|
| SOQL queries | 100 | 200 |
| DML statements | 150 | 150 |
| DML rows | 10,000 | 10,000 |
| CPU time | 10,000 ms | 60,000 ms |
| Heap size | 6 MB | 12 MB |
| Callouts | 100 | 100 |
| Queueable jobs | 50 | 50 |
| Future calls | 50 | — |

---

## 4. Retry with Exponential Backoff

### Backoff Schedule

| Attempt | Wait |
|---------|------|
| 1 | 1 s |
| 2 | 2 s |
| 3 | 4 s |
| 4 | 8 s |
| 5 | 16 s |
| 6 | 32 s |
| 7+ | 60 s (cap) |

### Non-Retryable Codes
`400` Bad Request · `401` Unauthorized · `403` Forbidden · `404` Not Found · `422` Unprocessable

**Never retry these** — the request itself is invalid; retrying will not fix it.

### Retryable Codes
`429` Rate Limited · `500` Internal Server Error · `502` Bad Gateway · `503` Service Unavailable · `504` Gateway Timeout

```apex
Integer attempt = 1;
Integer maxAttempts = 5;
while (attempt <= maxAttempts) {
    try {
        HttpResponse resp = http.send(req);
        if (resp.getStatusCode() == 200) return resp;
        String code = String.valueOf(resp.getStatusCode());
        if (!SystemDesignService.shouldRetry(attempt, maxAttempts, code)) break;
    } catch (Exception e) { /* network error → retry */ }
    Integer waitMs = SystemDesignService.calculateBackoffMs(attempt);
    // In Queueable: schedule next execution with delay
    attempt++;
}
```

---

## 5. Event-Driven Multi-Cloud Integration

### Platform Event as Integration Backbone

```apex
// Publisher (Sales Cloud): Lead scored
EventBus.publish(new CrossCloudEvent__e(
    EventType__c      = 'LEAD_SCORED',
    SourceRecordId__c = leadId,
    Payload__c        = JSON.serialize(payload),
    CorrelationId__c  = correlationId
));

// Subscriber (Marketing Cloud connector):
trigger CrossCloudEventTrigger on CrossCloudEvent__e (after insert) {
    for (CrossCloudEvent__e evt : Trigger.new) {
        if ('LEAD_SCORED'.equals(evt.EventType__c)) {
            MarketingCloudService.triggerJourney(evt.SourceRecordId__c, evt.Payload__c);
        }
    }
}
```

### Event Delivery Guarantees
- Platform Events: **at-least-once delivery** — subscribers must be idempotent
- `ReplayId` allows subscribers to replay missed events (72-hour window)
- `EventBus.publish()` is **transactional** — event published only if DML transaction commits

---

## 6. Lead 360 — Full Orchestration Flow

```
Lead Created / Updated
  │
  ▼
Einstein Lead Score (getLeadScores)
  │
  ├── Score ≥ 80 + Category A → AGENTFORCE_HIGH_VALUE
  │     └── Agentforce agent engages autonomously
  │
  ├── Score ≥ 60             → SALES_DIRECT
  │     └── Auto-assign to top rep + create Task
  │
  └── Score < 60 / unknown   → NURTURE_SEQUENCE
        └── Platform Event → Marketing Cloud Journey Builder
```

---

## 7. Dead Letter Queue

### Purpose
Messages that fail all retry attempts must not be silently dropped. Store them for:
1. **Manual reprocessing** by an administrator
2. **Automated retry** by a Scheduled Apex job that runs DLQ queries
3. **Incident investigation** — full payload + error + attempt count

### DLQ Object: `DeadLetterMessage__c`
```
MessageId__c    (Text 255)   — unique message correlation Id
Payload__c      (LTA)        — original message body (up to 131,072 chars)
ErrorMessage__c (Text 1000)  — last failure reason
AttemptCount__c (Number)     — total attempts made before DLQ
Status__c       (Picklist)   — Pending | Reprocessing | Resolved | Abandoned
CreatedDate                  — when the message was dead-lettered
```

---

## 8. Idempotency at Scale

Platform Events deliver **at-least-once**. The same event can be processed twice (network retry, replay). The Idempotency Guard prevents duplicate side effects.

```apex
// Key format: "{source}:{eventType}:{correlationId}"
String key = 'PLATFORM_EVENT:LEAD_SCORED:' + correlationId;

if (SystemDesignService.isAlreadyProcessed(key)) {
    return; // Duplicate — skip processing
}
// ... process the event ...
SystemDesignService.markProcessed(key); // Store the key (TTL: 1 day)
```

---

## Architecture Decision Record (ADR) Template

```markdown
# ADR-{number}: {Title}

## Status: Proposed | Accepted | Deprecated

## Context
What problem are we solving? What forces are at play?

## Decision
What did we decide to do?

## Consequences
### Positive
- ...
### Negative / Trade-offs
- ...

## Alternatives Considered
| Option | Pros | Cons | Why rejected |
|--------|------|------|-------------|
| ...    | ...  | ...  | ...         |
```

---

## Interview Tips

1. **Circuit Breaker state storage** — a static Map resets per transaction. In production, use Platform Cache (session partition) or a Custom Setting for persistence across transactions. The cache key is the service name.

2. **Saga ≠ rollback** — Saga uses *compensation* (undo logic), not DB rollback. Compensation is your own code; it must be idempotent too. If compensation fails, log to DLQ and alert ops.

3. **Platform Events are at-least-once** — always write subscribers to be idempotent using the Idempotency Guard pattern. Check the `CorrelationId` / `ReplayId` before processing.

4. **`hasHeadroom(85%, 85%)`** — the 85% threshold is a conservative heuristic. In triggers, use 75% because trigger re-entry and workflow rules consume additional limits after your code returns.

5. **Queueable chaining limit** — you can chain at most 1 Queueable from another Queueable (`System.enqueueJob` inside `execute()`). Use this for sequential chunk processing; for fan-out use a single Queueable that enqueues multiple others.

6. **Exponential backoff in Apex** — you cannot `Thread.sleep()` in Apex. Implement backoff via a Scheduled Apex job that reads a retry queue (DLQ with `Status = 'Pending'`) and reschedules itself at increasing intervals.

7. **2PC is not available** in Salesforce distributed architecture. The Saga pattern is the recommended alternative. For strictly atomic multi-record operations within a single org, use a savepoint.

8. **Platform Event transaction** — `EventBus.publish()` inside a transaction only publishes if the transaction commits. If the DML rolls back, the event is NOT published. Use this to your advantage: publish events only after all writes succeed.

9. **Correlation Id for distributed tracing** — generate a UUID-style Id at the entry point of each business operation and pass it through all downstream systems (Platform Events, callout headers, log entries). This is essential for debugging multi-cloud flows.

10. **Architecture interview formula** — for any "design X in Salesforce" question: (1) Identify the data model, (2) Define the integration pattern (event-driven vs request-response), (3) Address governor limits, (4) Describe the error/retry strategy, (5) Explain the testing approach.
