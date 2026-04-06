# Day 24 — Performance Tuning & Scalability, Large Data Volumes, Skinny Tables

## Core Interview Questions

### Q: What is a "non-selective" query and why does it matter?

A query is **selective** when the optimizer can use an index to reduce the result set:
- Returns < 10% of total records **OR** < 333,333 records, whichever is smaller
- Uses an indexed field in a leading WHERE clause

A **non-selective** query on an object with > 100K records forces a full table scan:
- Synchronous context: `QueryException` — "System.QueryException: Non-selective query against large object type"
- Async (Batch Apex): allowed but consumes significantly more CPU/heap

**Detection tools:**
- Developer Console → Query Editor → Query Plan button
- `EXPLAIN SELECT ...` equivalent shows index usage vs full scan
- Leading operation `Index` = selective; `TableScan` = non-selective

---

## Index Types

| Index type | How created | Indexed? |
|---|---|---|
| Id, Name | Always | ✅ |
| OwnerId, CreatedDate, SystemModstamp | Always | ✅ |
| RecordTypeId, Master-detail fields | Always | ✅ |
| External ID field | Mark field as External ID | ✅ |
| Unique field | Mark field as Unique | ✅ |
| Custom index | Salesforce Support request | ✅ |
| Formula fields | Never | ❌ |
| Long Text Area / Rich Text | Never | ❌ |
| Most picklists | Default no (Support can add) | ⚠️ |

**Composite index** (multiple fields in order): available for Big Objects (declarative), custom objects (Support request).

---

## Skinny Tables

A **Skinny Table** is a cached, denormalized copy of frequently-queried columns from a standard or custom object table.

### How they work
- Salesforce creates a separate database table containing only the requested columns
- Queries against those columns bypass the JOIN to the main Salesforce object table
- Maintained automatically — no developer action needed after creation
- Transparent to SOQL — same syntax, dramatically faster on 10M+ record objects

### When to request
- Object has > 10M records
- Same small set of fields (< 20) queried repeatedly
- Frequent ORDER BY / GROUP BY on the same columns
- Query Plan shows TableScan on those fields even with standard indexes

### How to get one
Raise a Salesforce Support case with:
1. Object API name
2. Field API names to include
3. Justification (record volume, query pattern, current performance)

### Limitations
- Not available for all objects/fields — Support evaluates eligibility
- Changes to included fields require a new Support request
- Not available in Developer Edition orgs

### Interview answer
> "For objects over 10 million records where the same small set of fields is queried repeatedly, I'd request a Skinny Table from Salesforce Support. It eliminates the JOIN to the main object table, turning what would be a multi-second full-table scan into a millisecond index lookup. The SOQL syntax is unchanged — the optimization is entirely platform-side."

---

## SOQL FOR LOOP — Most Important LDV Pattern

```apex
// ❌ WRONG — loads ALL records into heap at once
List<Account> all = [SELECT Id FROM Account WHERE Sync_Status__c = 'Pending'];
// 50K records × ~400 bytes/record = 20 MB → heap limit exceeded

// ✅ CORRECT — streams 200 records at a time
for (List<Account> chunk : [SELECT Id FROM Account WHERE Sync_Status__c = 'Pending']) {
    // chunk.size() <= 200; heap never accumulates more than 200 records
    for (Account acc : chunk) { /* process */ }
}
```

### DML bulk-safety with FOR LOOP
```apex
List<Account> toUpdate = new List<Account>();  // accumulate OUTSIDE the loop
for (List<Account> chunk : [SELECT Id FROM Account WHERE Sync_Status__c = 'Pending']) {
    for (Account acc : chunk) {
        toUpdate.add(new Account(Id = acc.Id, Sync_Status__c = 'Synced'));
    }
    // ❌ DML inside loop = 1 DML per 200 records; 1M records = 5000 DML = limit violation
}
Database.update(toUpdate, false);  // ✅ single DML for all records
```

---

## Keyset Pagination (beyond OFFSET 2000)

OFFSET is limited to 2000 in SOQL. For deeper pagination, use the seek/keyset method:

```apex
// Page 1 — no cursor
SELECT Id, Name FROM Account ORDER BY Id ASC LIMIT 200

// Page 2 — filter on last-seen Id
SELECT Id, Name FROM Account WHERE Id > '001xx...' ORDER BY Id ASC LIMIT 200

// Page N — same pattern, cursor = last Id from previous page
```

**Requirements:**
- ORDER BY field must be unique (Id is ideal)
- Cursor value stored between requests (stateless API) or in Platform Cache

**OFFSET vs Keyset:**
| | OFFSET | Keyset |
|---|---|---|
| Max depth | 2000 | Unlimited |
| Performance | Degrades at depth (skips rows) | Constant |
| Stable | No (new rows shift positions) | Yes (filters on value) |

---

## Platform Cache — Org vs Session

### Org Cache (`Cache.Org`)
```apex
Cache.OrgPartition partition = Cache.Org.getPartition('local.OrgCache');
partition.put('myKey', myValue, 3600);                      // TTL = 1 hour
Object cached = partition.get('myKey');                      // null if expired/missing
if (partition.contains('myKey')) { partition.remove('myKey'); }
```
- Shared across ALL users and transactions in the org
- Available in triggers, batch, queueable, future
- Key constraints: alphanumeric + `_`, max 50 chars
- Min TTL: 300s; Max TTL: 172800s (48h)

### Session Cache (`Cache.Session`)
```apex
Cache.SessionPartition session = Cache.Session.getPartition('local.SessionCache');
session.put('wizardStep', 3, 1800);  // TTL = 30 min
```
- Scoped to current user's session only
- NOT available in headless contexts (Batch, Queueable, triggers, REST without session)

### Cache-aside pattern
```apex
public static List<Account_Rating_Config__mdt> getRatingConfigs() {
    String cacheKey = 'rating_configs';
    Cache.OrgPartition p = Cache.Org.getPartition('local.OrgCache');
    List<Account_Rating_Config__mdt> cached =
        (List<Account_Rating_Config__mdt>) p.get(cacheKey);
    if (cached != null) { return cached; }

    List<Account_Rating_Config__mdt> fresh = [
        SELECT Revenue_Threshold__c, Rating_Value__c
        FROM   Account_Rating_Config__mdt
        ORDER BY Revenue_Threshold__c DESC
    ];
    p.put(cacheKey, fresh, 3600);
    return fresh;
}
```
**Zero SOQL on subsequent calls in the same cache window.**

---

## FOR UPDATE — Row Locking

```apex
List<Account> locked = [
    SELECT Id, Sync_Status__c
    FROM   Account
    WHERE  Id IN :ids
    FOR    UPDATE
];
```
- Acquires a row-level lock for the duration of the transaction
- Prevents concurrent jobs from reading stale data and overwriting each other
- **Deadlock risk**: two transactions locking same rows in different Id order → one throws
- **Mitigation**: always sort Ids before locking: `ids.sort()` before SELECT

---

## Selective Filter Composition

```apex
// ✅ GOOD — indexed field leads the WHERE
SELECT Id FROM Opportunity
WHERE  CloseDate >= :start        // indexed standard date field
  AND  CloseDate <= :end
  AND  StageName  = :stage         // non-indexed, applied AFTER index scan

// ❌ BAD — non-indexed field leads on large object
SELECT Id FROM Opportunity
WHERE  StageName = 'Closed Won'   // no index → table scan on 10M opps
  AND  CloseDate >= :start
```

---

## AggregateResult vs Loading Records

```apex
// ❌ WRONG — loads all child Opportunity records into heap
List<Account> accs = [SELECT Id, (SELECT Amount FROM Opportunities) FROM Account WHERE ...];
Decimal total = 0;
for (Account acc : accs) { for (Opportunity opp : acc.Opportunities) { total += opp.Amount; } }

// ✅ CORRECT — single query, O(1) heap regardless of child count
AggregateResult[] results = [
    SELECT AccountId, SUM(Amount) total
    FROM   Opportunity
    WHERE  AccountId IN :accountIds
    GROUP BY AccountId
];
```

---

## Apex CPU Optimization Patterns

| Anti-pattern | Fix |
|---|---|
| SOQL inside for loop | Collect IDs → single query outside loop |
| `Map.containsKey()` + `Map.get()` twice | Use single `Map.get()`, null-check result |
| Nested loops (O(n²)) | Use Map for O(n) lookup |
| `JSON.serialize()` inside loop | Serialize outside loop or cache result |
| `String +=` concatenation in loop | Use `List<String>` + `String.join()` |
| `Database.query()` (dynamic SOQL) in loop | Build query once, execute once |

---

## LDV Decision Framework

```
Object record count?
  < 100K    → standard Apex, normal SOQL
  100K–1M   → FOR LOOP, selective filters, Batch if > 50K DML
  1M–10M    → Skinny Tables (Support), keyset pagination, Platform Cache for lookups
  > 10M     → Big Objects for archival, External Objects for federated data,
              Deferred Sharing Recalc for sharing-heavy objects
```

---

## Key Classes (Day 24)

| Class | Responsibility |
|---|---|
| `LdvQueryService` | FOR LOOP streaming, keyset pagination, selective queries, FOR UPDATE, aggregate rollups |
| `PlatformCacheService` | Cache-aside pattern, Org Cache wrapper, mock injection for tests |
| `CaseArchiveService` (Day 4) | Big Object archival via `Database.insertImmediate()` |
| `AccountRatingBatch` (Day 2) | Batch Apex for 50K+ record processing |

---

## Quick-Reference: Interview Answers

**"What is the SOQL FOR LOOP and when do you use it?"**
> The FOR LOOP emits records 200 at a time rather than loading the full result set into heap. Use it whenever a query may return more than a few thousand records — the heap stays at O(200) regardless of total volume. Critical rule: accumulate DML changes in an outer List and commit a single DML after the loop ends, never DML inside the loop.

**"How do you paginate beyond 2000 records in SOQL?"**
> OFFSET is limited to 2000. For deeper pagination I use keyset (seek) pagination: ORDER BY an indexed unique field (Id is ideal), store the last-seen value, and use `WHERE Id > :lastSeenId` on the next request. This is constant-cost regardless of depth and produces stable results even when records are inserted between pages.

**"When would you request a Skinny Table?"**
> For objects with over 10 million records where the same small set of columns is queried in repeated scans — typically a few fields used in ORDER BY or frequently filtered together. I'd raise a Salesforce Support case with the object, field list, and query pattern. The platform creates a denormalized table that eliminates the JOIN to the main object store, turning multi-second scans into millisecond lookups — fully transparent to SOQL.
