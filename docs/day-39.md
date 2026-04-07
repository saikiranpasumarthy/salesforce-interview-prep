# Day 39 — Weak Area Revisit

## Overview

Targeted deep-dives on patterns most commonly missed in senior Salesforce developer
interviews, identified from mock interview gaps (Days 37–38):

1. FLS / CRUD enforcement — `stripInaccessible`, `WITH USER_MODE`, describe checks
2. Describe cache — avoid repeated `Schema.getGlobalDescribe()` calls
3. Custom Iterable / Iterator — memory-efficient large-dataset traversal
4. Platform Event error handling — `RetryableException`, idempotency
5. Callable interface — cross-class/cross-package loose coupling
6. CPU-aware chunking — `Limits.getCpuTime()` guard
7. String security — SOQL injection, XSS, JSON deserialization, open redirect
8. Lightning Message Service (LWC) — cross-component comms without parent-child

---

## Pattern 1: FLS / CRUD Enforcement

### The Three Approaches

**A. `WITH USER_MODE` (API v56+) — recommended for new code**
```apex
List<Account> results = [
    SELECT Id, Name FROM Account WHERE Industry = :ind
    WITH USER_MODE   // silently omits inaccessible fields, throws on CRUD violation
];
Database.insert(records, AccessLevel.USER_MODE); // DML with FLS
```

**B. `Security.stripInaccessible()` — use before returning data to UI**
```apex
SObjectAccessDecision decision = Security.stripInaccessible(
    AccessType.READABLE, rawRecords
);
return decision.getRecords(); // fields the user can't read are removed
```

**C. Manual describe check — granular, pre-v56 compatible**
```apex
Schema.DescribeFieldResult fd = fieldMap.get('Email__c').getDescribe();
if (!fd.isCreateable()) throw new SecurityException('Cannot write Email__c');
```

**Key interview distinction:**
- `WITH SECURITY_ENFORCED` → **throws** if any field is inaccessible (use only when you're sure all fields are accessible)
- `WITH USER_MODE` → **silently omits** inaccessible fields (safer for general use)

---

## Pattern 2: Describe Cache

### Why It Matters
`Schema.getGlobalDescribe()` builds a map of **all sObject types** in the org — it's one of the most expensive Apex calls. Calling it per-record or in a loop is a performance anti-pattern.

```apex
// ❌ Anti-pattern — called once per record
for (String field : fieldNames) {
    Schema.getGlobalDescribe().get('Account').getDescribe().fields.getMap();
}

// ✅ Pattern — static cache, paid once per transaction
private static Map<String, Schema.SObjectType> globalDescribeCache;
private static Map<String, Schema.SObjectType> getGlobalDescribe() {
    if (globalDescribeCache == null) {
        globalDescribeCache = Schema.getGlobalDescribe();
    }
    return globalDescribeCache;
}
```

**Interview tip:** Also cache `fieldDescribeCache` per object — avoids repeated `getDescribe().fields.getMap()` calls across methods in the same transaction.

---

## Pattern 3: Custom Iterable / Iterator

### When to Use
- Batch Apex `start()` returning a non-SOQL data source (CSV, API response, static resource)
- Processing a string blob line-by-line without loading all lines into memory at once

```apex
// Implement Iterable<T> for Batch Apex start()
public class CsvIterable implements Iterable<List<String>> {
    public Iterator<List<String>> iterator() {
        return new CsvIterator(rawData, 200);
    }
}

// Batch class uses it
public Iterable<List<String>> start(Database.BatchableContext bc) {
    return new CsvIterable(csvData);
}
```

**Key point:** `Iterator.next()` returns the **next chunk** — Batch Apex calls `execute()` once per chunk. This is memory-efficient vs loading everything into `List<String>`.

---

## Pattern 4: Platform Event Error Handling

### The Three Outcomes

| Outcome | How | Result |
|---|---|---|
| Success | Normal completion | Event consumed, not retried |
| Retryable failure | `throw new EventBus.RetryableException(msg)` | Retried up to 9 times with backoff |
| Non-retryable failure | Any other exception | Event skipped, logged to `EventBusSubscriber.LastError` |

### Idempotency Pattern (required because of at-least-once delivery)
```apex
trigger AccountCDC on AccountChangeEvent (after insert) {
    for (AccountChangeEvent e : Trigger.new) {
        String corrId = e.ChangeEventHeader.commitNumber + '_'
                      + String.join(e.ChangeEventHeader.recordIds, ',');
        if (isAlreadyProcessed(corrId)) continue; // skip duplicate
        try {
            processEvent(e);
            markAsProcessed(corrId);
        } catch (TransientException te) {
            throw new EventBus.RetryableException(te.getMessage());
        }
    }
}
```

**Interview tip:** Mention that replay is available for **3 days** and controlled via `replayId`. `-1` = latest, `-2` = earliest retained.

---

## Pattern 5: Callable Interface

### Use Case: Zero Compile-Time Dependency
```apex
// In Package A (callee):
public class TaxService implements Callable {
    public Object call(String action, Map<String, Object> args) {
        if (action == 'calculateTax') { ... }
        throw new IllegalArgumentException('Unknown: ' + action);
    }
}

// In Package B (caller) — no compile-time reference to TaxService:
Type t = Type.forName('packageA', 'TaxService');
if (t == null) return 0; // package not installed — graceful degrade
Callable svc = (Callable) t.newInstance();
Decimal tax = (Decimal) svc.call('calculateTax', new Map<String,Object>{...});
```

**When to use Callable:**
- OmniStudio `IntegrationProcedureService` (Day 35 pattern)
- ISV package providing extension points to subscriber orgs
- Optional add-on packages called from a core package
- Cross-namespace communication in unlocked package architectures

---

## Pattern 6: CPU-Aware Chunking

```apex
// Limits class — always available, no SOQL cost
Long usedPct = Limits.getCpuTime() * 100 / Limits.getLimitCpuTime();
if (usedPct >= 80) {
    // Enqueue remainder — continue in fresh transaction
    System.enqueueJob(new ContinuationQueueable(remainingIds));
    return;
}
```

**Limit reference table (memorise for interviews):**

| Limit | Sync | Async/Batch execute |
|---|---|---|
| CPU time | 10,000ms | 60,000ms |
| Heap | 6MB | 12MB |
| SOQL queries | 100 | 200 |
| DML statements | 150 | 150 |
| DML rows | 10,000 | 10,000 |
| Callouts | 100 | 100 |
| Queueable jobs | 50 | 1 (chain) |

---

## Pattern 7: String Security

### SOQL Injection — Three Safe Approaches
```apex
// 1. Bind variable (best)
String term = '%' + searchInput + '%';
[SELECT Id FROM Account WHERE Name LIKE :term];

// 2. escapeSingleQuotes (legacy — use with caution)
String safe = String.escapeSingleQuotes(userInput);

// 3. Database.queryWithBinds (dynamic SOQL)
Database.queryWithBinds(soql, bindMap, AccessLevel.USER_MODE);
```

### XSS Prevention
```apex
// In Apex REST / string building
String safe = String.escapeHtml4(userContent);
// In Visualforce: {!HTMLENCODE(myVar)} or <apex:outputText escape="true">
```

### Safe JSON Deserialization
```apex
// ✅ Typed class — fields are validated by the type system
MyDTO dto = (MyDTO) JSON.deserialize(jsonBody, MyDTO.class);

// ❌ Untyped — no validation, easy to get ClassCastException or miss fields
Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(jsonBody);
```

---

## Pattern 8: Lightning Message Service (LWC)

### When to Use LMS vs Other Options

| Scenario | Solution |
|---|---|
| Child → Parent | `CustomEvent` (bubbles up DOM) |
| Parent → Child | `@api` property or method call |
| Sibling / unrelated components | **Lightning Message Service** |
| Legacy Aura ↔ LWC | **Lightning Message Service** |

### Key LMS APIs
```javascript
import { MessageContext, publish, subscribe, unsubscribe, APPLICATION_SCOPE }
    from 'lightning/messageService';
import MY_CHANNEL from '@salesforce/messageChannel/MyChannel__c';

@wire(MessageContext) messageContext;  // framework-provided context

// Subscribe (in connectedCallback)
this._sub = subscribe(this.messageContext, MY_CHANNEL,
    (msg) => this.handleMessage(msg), { scope: APPLICATION_SCOPE });

// Unsubscribe (in disconnectedCallback — ALWAYS do this)
unsubscribe(this._sub);

// Publish (from any event handler)
publish(this.messageContext, MY_CHANNEL, { recordId: id, recordName: name });
```

**`APPLICATION_SCOPE`:** receive messages from ALL LWC/Aura components on the page.
Default (no scope): receive only from the same Lightning tab.

### MessageChannel metadata
```xml
<!-- force-app/main/default/messageChannels/MyChannel__c.messageChannel-meta.xml -->
<LightningMessageChannel>
    <masterLabel>My Channel</masterLabel>
    <isExposed>true</isExposed>
    <lightningMessageFields>
        <fieldName>recordId</fieldName>
    </lightningMessageFields>
</LightningMessageChannel>
```
Deploy with `sf project deploy start` — it's a metadata type, not data.

---

## Files Created

| File | Purpose |
|---|---|
| `WeakAreaRevisitService.cls` | 7 patterns: FLS, describe cache, Iterable, PE errors, Callable, CPU guard, string security |
| `WeakAreaRevisitTest.cls` | 40 tests covering all 7 service patterns |
| `lwc/notificationPanel/` | LMS publisher + subscriber demo with pagination |
| `messageChannels/RecordSelected__c.messageChannel-meta.xml` | LMS channel metadata |

---

## Interview Tips — Day 39

1. **FLS**: Lead with `WITH USER_MODE` for queries, `AccessLevel.USER_MODE` for DML, then mention `stripInaccessible` for endpoint responses. Avoid `WITH SECURITY_ENFORCED` unless you explain the throw-on-any-inaccessible behaviour.
2. **Describe cache**: Interviewers love asking "what's wrong with this code?" — calling `Schema.getGlobalDescribe()` in a loop is a classic trap.
3. **Platform Events**: Always say "at-least-once delivery" and "idempotency" in the same sentence. Mention `RetryableException` vs non-retryable exception distinction.
4. **Callable**: Frame it as "the Salesforce equivalent of a service locator pattern" — architects love this explanation.
5. **CPU limits**: Know the numbers cold — 10s sync, 60s async. The `hasCpuHeadroom()` + enqueue-remainder pattern shows production maturity.
6. **LMS**: The `disconnectedCallback` unsubscribe is the detail that separates candidates who've shipped LWC from those who've only read docs.
7. **SOQL injection**: Never say `escapeSingleQuotes` as your first answer — say bind variables. `escapeSingleQuotes` is a code smell that signals the developer is building the SOQL string wrong.
