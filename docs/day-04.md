# Day 04 — SOQL & SOSL Mastery · Query Optimization · Big Objects & External Objects
**Phase:** 1 — Code-First Foundation
**Date:** 2026-03-29

---

## 📌 Topics Covered
- SOQL: relationship queries, aggregate functions, semi/anti-joins, dynamic SOQL with injection prevention
- SOQL: FOR UPDATE, keyset pagination, date functions, static cache pattern
- `Database.queryWithBinds()` — API 57.0+ named bind variable pattern
- SOSL: search groups, RETURNING with WHERE, dynamic `Search.query()`, `Test.setFixedSearchResults()`
- Query optimization: selective filters, index types, non-selective patterns, SOQL injection
- Custom Big Objects: `Database.insertImmediate()`, composite index rules, query constraints
- External Objects & Salesforce Connect: architecture overview, when to use vs ETL

---

## 🏗 Architecture & Concepts

### How Salesforce executes SOQL

Every SOQL query goes through the Salesforce Query Optimizer before hitting the database. The optimizer:
1. Evaluates the WHERE clause filters for selectivity
2. Chooses the best available index (or full table scan)
3. Generates an execution plan

**Selectivity rule:** A filter is selective if it returns ≤10% of the total records in the object (or ≤333K records, whichever is smaller). Non-selective filters cause full table scans — performance degrades linearly with record count.

**Index types in Salesforce:**

| Index Type | Fields | Notes |
|---|---|---|
| Standard (auto) | Id, Name, OwnerId, CreatedDate, SystemModstamp, RecordTypeId, Division, master-detail fields | Always indexed |
| Custom index | Any field except LongTextArea, MultiPicklist, compound address | Admin/Support request via case |
| Unique index | Fields marked Unique in UI | Automatically indexed |
| External Id | Fields marked External Id | Automatically indexed |
| Custom Metadata | Not indexed — don't use in WHERE | Query returns full table |

**Checking a query plan:** Use the Developer Console → Query Editor → Query Plan. Look for `TABLE_SCAN` — that's the red flag. A good plan shows `INDEX` or `SHARING_FILTER` as the leading operation.

### SOQL Relationship Query Mechanics

**Parent-to-child (child sub-query):**
```soql
SELECT Id, Name, (SELECT Id, Subject FROM Cases WHERE IsClosed = false) FROM Account
```
- Sub-query returns up to **200 child records per parent row**. Beyond 200: `QueryException`.
- Always add `LIMIT 200` explicitly so you know the cap is enforced — never silently truncated.
- Each parent-child pair is one SOQL query slot — not two.

**Child-to-parent (dot notation):**
```soql
SELECT Id, Subject, Account.Name, Account.Rating, Owner.Email FROM Case
```
- Up to 5 relationship levels: `Case.Account.Owner.Manager.Department__r.Name`
- Standard relationships use the related field name (`Account.Name`)
- Custom relationships use `__r` suffix (`SupportTier__r.Name`)

### SOQL Injection Prevention — the complete picture

```apex
// ❌ WRONG — string concatenation: attacker sends "' OR '1'='1"
String query = 'SELECT Id FROM Account WHERE Name = \'' + userInput + '\'';

// ❌ STILL WRONG — escapeSingleQuotes doesn't prevent SOQL function injection
String safeish = 'SELECT Id FROM Account WHERE Name = \'' +
                 String.escapeSingleQuotes(userInput) + '\'';
// Attack: userInput = "test' LIMIT 0 OR Name LIKE '%"  ← works around escaping

// ✅ CORRECT — bind variable: value is never parsed as SOQL syntax
String query = 'SELECT Id FROM Account WHERE Name = :nameVar';
return Database.query(query); // nameVar resolved from Apex scope, not query string

// ✅ ALSO CORRECT — Database.queryWithBinds (API 57.0+): named binds in a Map
Map<String, Object> binds = new Map<String, Object>{'nameVar' => userInput};
return Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);
```

`WITH SECURITY_ENFORCED` enforces FLS and object-level access in SOQL. If any queried field is inaccessible to the running user, it throws a `System.QueryException` instead of silently stripping the field. Alternative: `AccessLevel.USER_MODE` in `Database.queryWithBinds()` — same effect, more explicit.

### SOQL vs SOSL — decision framework

| Scenario | Use |
|---|---|
| You know the object and the exact field | SOQL |
| You're searching across multiple objects | SOSL |
| You need aggregate functions (SUM, COUNT, GROUP BY) | SOQL (SOSL has none) |
| The filter has an OR condition across different fields | SOSL (SOQL OR is non-selective) |
| You need FOR UPDATE, relationship traversal, OFFSET | SOQL (SOSL supports none) |
| User typing into a search box (free text) | SOSL |
| Field is Long Text Area | SOSL (SOQL can't filter LTA) |
| You need exact record by known Id | SOQL |

**SOSL limits:**
- Max 2,000 results per query total
- Max 200 results per object (configurable with LIMIT in RETURNING)
- Max 25 objects in RETURNING clause (Spring '25)
- Not available in Batch Apex execute() — use SOQL or QueryLocator

### Custom Big Objects — constraints that kill interviews

Big Objects (`__b` suffix) store 10 billion+ records outside standard storage. They come with hard rules interviewers love to probe:

| Capability | Standard Object | Big Object |
|---|---|---|
| DML | insert, update, delete, upsert | `insertImmediate()` only |
| Triggers | ✅ | ❌ |
| Flows / Process Builder | ✅ | ❌ |
| SOSL | ✅ | ❌ |
| Relationship queries | ✅ | ❌ |
| Non-index field in WHERE | ✅ | ❌ (exception thrown) |
| Partial WHERE clause (skip index fields) | N/A | ❌ (must use leading index fields in order) |
| Roll-up summary fields from Big Object | N/A | ❌ |

**Composite index query rule:** If your index is `Account_Id__c → Closed_Date__c → Case_Id__c`, valid queries are:
- `WHERE Account_Id__c = :x` ✅ (leading field only)
- `WHERE Account_Id__c = :x AND Closed_Date__c >= :y` ✅ (leading + second)
- `WHERE Account_Id__c = :x AND Closed_Date__c >= :y AND Case_Id__c = :z` ✅ (all three)
- `WHERE Closed_Date__c >= :y` ❌ (skipped leading field — exception)
- `WHERE Account_Id__c = :x AND Case_Id__c = :z` ❌ (skipped second field — exception)

### External Objects & Salesforce Connect

External Objects (`__x` suffix) make external data appear as Salesforce objects — queryable via SOQL and visible in record pages — without ETL.

**Adapters:**
- **OData 2.0/4.0:** REST-based protocol; most ERP/CRM systems support it
- **Salesforce Connect cross-org:** Query another Salesforce org's data live
- **Custom adapter:** Apex-based; implement `DataSource.Provider` for any source

**When External Objects over ETL:**
- Data is too large or too volatile to replicate into Salesforce
- Regulatory constraint: data must remain in source system
- Read-heavy, write-rare access pattern
- Real-time accuracy is required (ETL lag is unacceptable)

**When ETL over External Objects:**
- You need aggregate queries, Flows, or triggers on the data
- SOSL search across external data is needed
- Relationship queries from external data to Salesforce records (External Object lookups are limited)
- Performance: External Object queries call the source system live — latency applies

**Callout limits apply:** Each External Object query is a callout. In Apex contexts with 100-callout limits, bulk External Object queries can exhaust the budget quickly.

### Spring '25 (API 62.0) Notes
- **`Database.queryWithBinds()` with `AccessLevel.USER_MODE`:** Now the preferred pattern over `WITH SECURITY_ENFORCED` for dynamic SOQL — more granular control and explicit about FLS enforcement intent.
- **SOSL max objects in RETURNING:** Increased to 25 (up from 20 in prior releases).
- **Big Object Async SOQL:** Still in limited availability. `AsyncSoqlQuery` allows Big Object queries to be offloaded asynchronously, results written to a standard object. Not GA — plan for Batch Apex as the alternative.
- **Agentforce thread:** Agentforce Agents use `@InvocableMethod` for data retrieval. `SoqlQueryService` methods can be wrapped in `@InvocableMethod` actions to give Agents structured query capability — e.g., "find open high-priority cases for Account X" becomes an Agent Action backed by `getRecentHighPriorityCases()`.

---

## ⚙️ Scenarios

### Scenario 1 — SOQL in a Loop (The Most Common Interview Trap)

**Business Problem:**
A service method processes a List of Cases and needs the related Account name for each.

**Anti-Pattern:**
```apex
// WRONG — fires 1 SOQL per Case record. At 200 Cases = 200 SOQLs.
// Fails at Case #101 with "Too many SOQL queries: 101"
for (Case c : cases) {
    Account acc = [SELECT Id, Name FROM Account WHERE Id = :c.AccountId];
    System.debug(acc.Name);
}
```

**Correct Approach — two patterns:**
```apex
// Pattern 1: Collect + batch query (use when you need specific fields)
Set<Id> accountIds = new Set<Id>();
for (Case c : cases) { if (c.AccountId != null) accountIds.add(c.AccountId); }
Map<Id, Account> accounts = new Map<Id, Account>(
    [SELECT Id, Name, Rating FROM Account WHERE Id IN :accountIds]
);
for (Case c : cases) {
    Account acc = accounts.get(c.AccountId);
}

// Pattern 2: Parent-to-child subquery (use when you're already querying Cases)
List<Account> accounts = [
    SELECT Id, Name, (SELECT Id, Subject FROM Cases) FROM Account WHERE Id IN :accountIds
];
// Accounts have Cases pre-populated — zero additional SOQL
```

**Solution & Trade-offs:**
Pattern 1 is more flexible — any SOQL filter on the Account query. Pattern 2 is cleaner when you're already querying from Account, but the 200-child-record sub-query cap limits it to accounts with ≤200 cases.

### Scenario 2 — Dynamic SOSL for a Configurable Search Component

**Business Problem:**
A Lightning component lets admins configure which Salesforce objects appear in a search. The object list is stored in Custom Metadata. Different user profiles see different object sets.

**Approach:**
`SoslSearchService.dynamicMultiObjectSearch()` with an allowlist-validated object name list from Custom Metadata. The `Search.query()` call builds the RETURNING clause dynamically. Importantly, the object names are validated against a hardcoded allowlist before being included — a fabricated object name in the CMT record would be rejected, not blindly concatenated into the SOSL query.

**Trade-off:** Dynamic SOSL via `Search.query()` is slightly less performant than static SOSL because the query plan cannot be cached by the platform. For high-frequency searches, prefer static SOSL with specific object combinations.

### Scenario 3 — Big Object Archival Pipeline (Anti-Pattern)

**Business Problem:**
The compliance team needs 7 years of Case history. Standard Case records older than 2 years should be moved to a Big Object to reduce storage costs.

**Anti-Pattern:**
```apex
// WRONG — delete Cases before confirming archive succeeded
List<Case> cases = [SELECT Id FROM Case WHERE ClosedDate < :twoYearsAgo];
delete cases;  // Data gone. Archive step fails. Audit nightmare.
insert archives;
```

**Correct Approach:**
Archive first, verify, then delete as a separate audited transaction:
1. `CaseArchiveService.archiveClosedCases()` — inserts to Big Object, logs failures
2. Verify archive count via `countArchivedCasesForAccount()` matches source
3. Only after verification: delete source Cases via a separate Batch Apex job with a feature flag that must be explicitly enabled

This separation means an archive failure never causes data loss. Cases remain in both places until the delete job is explicitly triggered.

---

## ❓ Interview Questions

### 🟢 Foundational

**Q:** What is the difference between SOQL and SOSL, and when do you use each?
**A:** SOQL (Salesforce Object Query Language) is the SQL-equivalent for querying one object at a time with precise filters, aggregates, and relationship traversal. SOSL (Salesforce Object Search Language) is a text search language that runs across multiple objects simultaneously using Salesforce's full-text search index. Use SOQL when you know the object and exact field values — especially on indexed fields. Use SOSL when searching free text across multiple objects (like a global search bar), when filtering on LongTextArea fields (which SOQL cannot filter), or when OR conditions across multiple fields would make a SOQL query non-selective. The clearest rule: if you know exactly where to look, SOQL; if you're searching, SOSL.
**What makes this 9/10:** Citing the LongTextArea SOQL limitation and OR-condition selectivity degradation as specific SOSL trigger conditions. Most candidates give the generic "one object vs multiple objects" answer.

**Q:** What makes a SOQL query non-selective, and what happens when it is?
**A:** A query is non-selective when the WHERE clause filters return more than 10% of the total records in that object, or more than 333,000 records — whichever is smaller. Non-selective queries cause the Salesforce Query Optimizer to abandon index lookups and fall back to a full table scan. On a table with 1 million records, that means evaluating every row against your filter, which becomes progressively slower as data grows. Common causes: filtering on non-indexed fields, leading wildcard patterns (`LIKE '%value'`), OR conditions across multiple columns, and NULL checks (`WHERE Field = null`). Detection: Developer Console Query Plan shows `TABLE_SCAN`. Fix: add a filter on an indexed field (Id, Name, External Id, or a field with a custom index).
**What makes this 9/10:** Giving the 10% / 333K threshold numbers. Most candidates say "it does a full table scan" without knowing the selectivity threshold that triggers it.

### 🟡 Intermediate

**Q:** How does `FOR UPDATE` work in SOQL, and when is it dangerous?
**A:** `SELECT ... FOR UPDATE` acquires a row-level pessimistic lock on the queried records. No other transaction can write to those records until the locking transaction commits or rolls back. It's valuable when multiple async processes (Queueable jobs, Batch Apex chunks) might update the same records simultaneously — `FOR UPDATE` ensures read-then-update atomicity without lost updates. It's dangerous in high-concurrency trigger paths: if 50 concurrent Account updates all try to `FOR UPDATE` the same records, each waits for the previous lock to release, creating a queue that leads to UNABLE_TO_LOCK_ROW exceptions and transaction rollbacks. Use `FOR UPDATE` in async-only contexts (Batch, Queueable) where concurrency is controlled, never in synchronous trigger paths on heavily written objects.
**What makes this 9/10:** The `UNABLE_TO_LOCK_ROW` exception scenario. Understanding the failure mode at scale, not just the feature's intended use.

**Q:** What are the Big Object query constraints, and why do they exist?
**A:** Big Object queries must include the leading fields of the composite index in exact order, using equality (`=`) for all but the last index field specified (which can use comparison operators). You cannot skip index fields, cannot filter on non-indexed fields, and cannot use SOSL. These constraints exist because Big Objects are stored in a distributed column store optimised for write throughput and range scans on known index paths — not random-access queries. There's no traditional query optimizer because the B-tree indexes used for standard objects don't scale to tens of billions of rows. The composite index enforces a sorted physical layout: all records with the same leading field value are co-located, and within that, sorted by the second field, and so on. Any query that violates this ordering requires a full scan of the entire dataset, which is computationally infeasible at Big Object scale.
**What makes this 9/10:** Explaining the physical storage model (co-located by index fields) as the reason for the constraint. Most candidates say "Big Objects have special requirements" without explaining why.

### 🔴 Advanced / Architect

**Q:** A SOQL query on Account runs in milliseconds with 10,000 records but takes 45 seconds with 2 million records. The WHERE clause hasn't changed. Walk me through your diagnosis.
**A:** First hypothesis: the query became non-selective as data grew. What was 10% of 10K (1,000 records) may now be 20%+ of 2M — same percentage of records but the threshold crossed. Check via Developer Console Query Plan: is it showing `INDEX` or `TABLE_SCAN`? If `TABLE_SCAN`, the filter is no longer selective enough for the optimizer to use the index. Solutions: add a more selective leading filter (a field that narrows to ≤10%), request a custom index on the filtering field, or consider a skinny table (Day 24). Second hypothesis: the result set is large and returning 200K+ rows takes time independent of the query plan — paginate with LIMIT/OFFSET or switch to QueryLocator. Third hypothesis: a sharing evaluation is occurring — if the org uses complex sharing rules (criteria-based, Apex sharing), the sharing filter is re-evaluated for every candidate row. Adding `WITHOUT SHARING` to the query class context bypasses this at a security trade-off. Fourth: lock contention — `AsyncApexJob` or another process holds a row lock on high-cardinality Account records, causing the query to wait. Check Setup → Apex Jobs for competing transactions.
**What makes this 9/10:** Walking through four distinct hypotheses — selectivity, result set size, sharing evaluation cost, and lock contention — and giving a diagnostic step for each. Most candidates jump to "add an index" and stop. The sharing evaluation overhead is rarely mentioned but is a real production issue in orgs with complex sharing rules.

**Q:** How do you implement pagination for a Lightning component displaying 100,000 Case records without hitting SOQL OFFSET limits?
**A:** SOQL OFFSET is capped at 2,000, so page 11+ at 200 records/page is impossible with OFFSET. The solution is **keyset pagination**: instead of page numbers, use a cursor — the Id of the last record seen. Each page query uses `WHERE Id > :lastSeenId ORDER BY Id ASC LIMIT :pageSize`. This works because Id is always indexed, always ordered (within the same object), and the filter is always selective. The client stores the cursor (last seen Id) and sends it with each "next page" request. Trade-offs: (1) keyset pagination only moves forward — there's no true "go to page 47" without traversing all prior pages; (2) inserts between pages can cause records to appear or skip under certain conditions; (3) deletions between pages are handled naturally since the cursor is an Id, not a position. For backward navigation, store a stack of cursors (one per page visited). For Lightning, implement this as a Wire adapter or Imperative Apex call with cursor management in the component's JS state.
**What makes this 9/10:** Naming the pattern as "keyset pagination," explaining WHY it works (Id is indexed and ordered), and calling out the forward-only trade-off with the stack-of-cursors workaround for backward navigation. The stack pattern is what separates a complete answer from a partial one.

---

## 💻 Code Reference

| File | Layer | Purpose |
|------|-------|---------|
| `SoqlQueryService.cls` | Service | 11 SOQL patterns: relationship, aggregate, semi/anti-join, dynamic, FOR UPDATE, pagination, date |
| `SoslSearchService.cls` | Service | 5 SOSL patterns: global, name, email, scoped WHERE, dynamic Search.query() |
| `CaseArchiveService.cls` | Service | Big Object archival pipeline + composite index query patterns |
| `Case_Archive__b` | Big Object | Composite index: Account_Id__c → Closed_Date__c → Case_Id__c |
| `SoqlSoslTest.cls` | Test | 15 methods — SOQL pattern tests + SOSL via Test.setFixedSearchResults() |
| `CaseArchiveServiceTest.cls` | Test | 7 methods — Big Object insertImmediate + query testing |

---

## 🔗 Cross-Topic Connections

- **Day 2 (Batch Apex):** `CaseArchiveService.archiveClosedCases()` should be wrapped in a `Database.Batchable` class for production-scale archival. The current method handles 200 records per call — a batch job wraps it in chunks for millions of Cases.
- **Day 6 (Selector Layer):** `SoqlQueryService` is the informal Selector pattern. On Day 6, this evolves into a formal `fflib`-style `CaseSelector.cls` with a queryable interface, reducing SOQL duplication across the entire codebase.
- **Day 22 (Architecture / fflib):** `Database.queryWithBinds(..., AccessLevel.USER_MODE)` is the foundation for user-context query enforcement in enterprise patterns. fflib's Selector layer builds on this for consistent FLS application.
- **Day 24 (Large Data Volumes):** Query optimization is revisited with skinny tables, custom indexes, and SOQL query plans for orgs with 10M+ records. The patterns here scale naturally — the keyset pagination and selectivity rules apply at any volume.
- **Agentforce (Day 30):** SOQL service methods become Agent Actions via `@InvocableMethod`. An Agent can call `getRecentHighPriorityCases(7)` to find this week's critical cases as part of an automated triage workflow.

---

## 📋 Best Practices

| Practice | Why | Consequence of Ignoring |
|----------|-----|------------------------|
| Bind variables in dynamic SOQL | Prevents injection, enables query plan caching | SOQL injection vulnerability; unique query strings bypass optimizer cache |
| `WITH SECURITY_ENFORCED` or `USER_MODE` | Enforces FLS without manual checks | Users see fields they shouldn't; security audit failures |
| LIMIT on every open-ended query | Prevents governor limit breach on growing datasets | Query works in dev (10K records), fails in prod (500K records) |
| Static Map cache for repeated same-tx queries | Avoids duplicate SOQL within one transaction | Exceeds 100-SOQL limit on complex trigger chains |
| `Test.setFixedSearchResults()` for SOSL tests | SOSL index not populated in test context | All SOSL queries return empty in tests; coverage gap |
| `Database.insertImmediate()` for Big Objects | Only supported DML operation | Using `Database.insert()` throws exception at runtime |
| Leading index field in Big Object queries | Composite index requires ordered field use | QueryException at runtime; non-obvious in development |

---

## ⚠️ Gotchas & Anti-Patterns

- **`COUNT()` vs `COUNT(fieldName)` in aggregate SOQL:** `COUNT()` counts all rows (including null field values). `COUNT(fieldName)` counts rows where `fieldName` is non-null. `COUNT_DISTINCT(fieldName)` counts unique non-null values. In Apex, `COUNT()` returns an Integer directly from `AggregateResult.get('expr0')`. `COUNT(Id)` returns the same value but with a named alias: `ar.get('cnt')` if aliased.

- **Parent-to-child sub-query silent truncation:** The 200-child-per-parent limit is NOT an exception — it's a silent truncation if you don't add `LIMIT 200`. Accounts with 250 open cases will show 200 in the sub-query result with no warning. Always add `LIMIT 200` to make the cap explicit.

- **SOSL in Batch Apex execute():** SOSL is not allowed in Batch Apex's `execute()` method (same restriction as callouts). Use SOQL queries in batch. If SOSL is needed, pre-run it in `start()` and pass the result set to execute() via instance variables (with `Database.Stateful`).

- **FOR UPDATE in a trigger:** Every trigger invocation that uses `FOR UPDATE` on the same records as the triggering DML will immediately deadlock with itself — the trigger's transaction already holds the row lock from the DML that fired it. FOR UPDATE in triggers throws `UNABLE_TO_LOCK_ROW` consistently.

- **`OFFSET` and total record count for pagination:** There's no standard SOQL way to get the total record count for pagination (to know how many pages exist) without a separate `SELECT COUNT()` query. This costs an additional SOQL. Cache the count on first page load and invalidate on refresh.

---

## 🧠 Retention — 3 Things to Remember

1. **Selectivity = 10% / 333K threshold.** A query that was fast at 50K records can table-scan at 1M with the same WHERE clause because the same filter now returns >10% of the data. Knowing this threshold and the Developer Console Query Plan check separates you from mid-level.

2. **Big Object composite index must be used in order.** You cannot skip index fields. You cannot filter on non-index fields. `insertImmediate()` is the only write. No triggers, no flows, no SOSL. These five constraints come up in every Big Object interview question.

3. **`Test.setFixedSearchResults()` for SOSL — use it or your SOSL tests always return empty.** The search index is not populated in test context. This is a known gotcha that prevents coverage of all SOSL-based code paths without the mock.

---

## Updates
<!-- Appended automatically on "Update Day N" commands -->
