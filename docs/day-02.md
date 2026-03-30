# Day 02 — Async Apex: Batch & Queueable · Chaining & Chunking · Stateful Batch
**Phase:** 1 — Code-First Foundation
**Date:** 2026-03-29

---

## 📌 Topics Covered
- Batch Apex: `Database.Batchable`, QueryLocator vs Iterable, scope sizing
- `Database.Stateful` — what it does, when you need it, performance cost
- Queueable Apex: `Queueable`, `Database.AllowsCallouts`, chaining pattern
- Chunking patterns for large datasets (Queueable chain, Batch scope)
- Async testing: `Test.startTest()/stopTest()`, `HttpCalloutMock`
- Connecting Day 1 service layer to Day 2 batch execution path

---

## 🏗 Architecture & Concepts

### How Batch Apex executes internally

When you call `Database.executeBatch(new MyBatch(), 200)`, Salesforce creates an
`AsyncApexJob` record and adds the work to a queue of batch Apex jobs. The platform
spawns a separate transaction for each chunk:

```
Transaction 1:  start()   → returns QueryLocator or Iterable
Transaction 2:  execute() → scope[0..199]      ← fresh governor limits
Transaction 3:  execute() → scope[200..399]    ← fresh governor limits
Transaction N:  finish()                        ← fresh governor limits
```

Each `execute()` is a completely independent Apex transaction with its own 100 SOQL,
150 DML, 10MB heap budget. This is the core governor limit advantage of Batch Apex
— you trade per-transaction scope for the ability to process millions of records.

### QueryLocator vs Iterable

| | QueryLocator | Iterable |
|---|---|---|
| Max records | 50,000,000 | 50,000 |
| Data source | SOQL only | Any Apex (List, Map, external API) |
| SOQL limit counted? | No (special allocation) | Yes (standard SOQL limit) |
| Use when | Large SObject datasets | Non-SOQL sources, complex filtering |

**Default to QueryLocator.** Use Iterable only when you cannot express your filter
in SOQL — e.g., complex multi-field conditions that would exceed SOQL row limits,
or data sourced from a callout.

### Database.Stateful — what actually happens

Without `Database.Stateful`:
- Salesforce serializes the batch class instance to a blob in the database between execute() calls
- On deserialization before the next execute(), all instance variables are **reset to
  their constructor-initialized values** — Maps, Lists, counters, all gone
- The batch class is effectively stateless across chunks

With `Database.Stateful`:
- The serialized blob is flagged to preserve instance variable values
- Deserialization restores the previous state — your Map/counters survive

**The hidden cost:** Serialization of a large stateful Map (e.g., 100K AccountId → Decimal
entries) happens between EVERY chunk. This adds latency and can hit the 12MB async heap
limit if the Map grows large. Rule of thumb: **stateful variables should store primitives
and IDs, never full SObjects or large nested structures.**

### Queueable vs @future vs Batch — decision matrix

| Characteristic | @future | Queueable | Batch |
|----------------|---------|-----------|-------|
| Can chain | No | Yes (5 levels in test; unlimited async) | Via finish() |
| Complex types as params | No (primitives only) | Yes (any type) | N/A (no params) |
| Callouts | Yes | Yes (+ Database.AllowsCallouts) | Not in execute() |
| Job monitoring | No | Yes (JobId) | Yes (AsyncApexJob) |
| Large datasets (>10K) | No | With chaining | Yes (purpose-built) |
| Max concurrent | 50/org | 5 enqueued/transaction | 5 active/org |
| Use when | Simple, fire-and-forget async, no chaining | Ordered processing, callout chain, multi-step workflows | Mass data processing, scheduled nightly jobs |

### Chaining pattern — Queueable

The chaining pattern solves the "I have 50,000 Ids to process but one Queueable
execution can only callout for ~100 before hitting heap or timeout limits":

```
enqueueJob(Ids[0..999])
  └→ execute: process Ids[0..99], enqueueJob(Ids[100..999])
       └→ execute: process Ids[100..199], enqueueJob(Ids[200..999])
            └→ ... continues until empty
```

Key rule: **Queueable chains are unlimited in async production contexts** but are
**capped at 1 level deep in tests** (Salesforce enforces this to prevent infinite
test recursion). Always guard chaining with `Test.isRunningTest()` in test context
or a Custom Metadata feature flag for more granular control.

### Spring '25 (API 62.0) Notes
- **Flex Queue:** Batch jobs now enter a Flex Queue (up to 100 jobs) before the
  Active Queue (5 jobs). `AsyncApexJob.Status = 'Holding'` means it is in Flex Queue.
  Previously jobs just piled up in 'Queued' status. Monitor both queues.
- **Queueable stack depth:** The platform-enforced chain depth (previously undocumented
  soft limits) is now more consistently enforced at the transaction stack level.
  Deep chains (20+) should be refactored to Batch Apex for safety.
- **Agentforce thread:** Agentforce Agent Actions execute synchronously in the request
  context — they cannot call Batch Apex directly. If an Agent Action needs async
  processing (e.g., re-rating 1M Accounts), the pattern is: Agent Action enqueues a
  Queueable, which then calls `Database.executeBatch()`. The Action returns immediately
  with a job ID for status tracking.

---

## ⚙️ Scenarios

### Scenario 1 — Nightly Rating Re-calculation (Batch Reuses Service Layer)

**Business Problem:**
AnnualRevenue is updated overnight by a data sync from Oracle Fusion. The trigger
fires correctly for each update, but some records bypass the trigger via direct API
loads. A nightly batch is needed as a safety net to re-rate all Accounts.

**Approach:**
`AccountRatingBatch` queries all Accounts with non-null AnnualRevenue, applies the
same `AccountService.applyRatingFromRevenue()` method used by the trigger, and bulk
updates. CMDT configs are loaded once in `start()` and reused across all chunks.

**Key architectural insight:**
The service method is called identically from both the trigger path and the batch path.
This is the payoff of the Trigger → Service design from Day 1 — **business logic is
defined once and executed from any entry point without code changes.**

### Scenario 2 — Stateful Revenue Rollup (Anti-Pattern vs Correct)

**Business Problem:**
Finance wants `Account.Total_Closed_Won_Revenue__c` populated from all linked
Closed Won Opportunities. A roll-up summary field won't work — Accounts and
Opportunities are in a lookup (not master-detail) relationship.

**Approach — Anti-Pattern (what NOT to do):**
```apex
// WRONG — queries Opportunities inside execute(), one SOQL per chunk of Accounts
public void execute(BatchableContext ctx, List<Account> scope) {
    Set<Id> accountIds = new Map<Id, Account>(scope).keySet();
    List<Opportunity> opps = [SELECT AccountId, Amount FROM Opportunity
                               WHERE AccountId IN :accountIds AND StageName = 'Closed Won'];
    // DML update inside execute() too — fine, but the SOQL approach is wrong
}
```
This approach has a hidden limit: if you have 1 million Accounts and a scope of 200,
you fire 5,000 execute() calls, each with 1 SOQL = 5,000 SOQL across the job.
Each chunk only sees its own Accounts' opportunities — cross-chunk rollup is impossible.

**Correct Approach:**
Flip the query: iterate over **Opportunities** in `start()`, accumulate per-Account
totals in a stateful `Map<Id, Decimal>`, then bulk-update Accounts in `finish()`.
One query, one DML statement, correct cross-chunk aggregation.

### Scenario 3 — Queueable Callout Chain for Territory Reassignment Sync

**Business Problem:**
When 3,000 Accounts are reassigned to new territory owners overnight, each Account
change must be POSTed to the external CRM. Synchronous callouts from the trigger
would hit the 100-callout limit instantly. A single `@future` method can't accept
a List<Id> larger than what fits in primitive parameters.

**Correct Approach:**
`AccountSyncQueueable` chunks the 3,000 IDs into 100-record batches. Each job
processes one chunk and chains itself for the remainder. 30 Queueable jobs, each
with one callout, process all 3,000 records across ~30 async transactions — each
with a fresh 100-callout budget.

**Gotcha: Why not a single callout with all 3,000 IDs?**
HTTP body size limits at the gateway level (often 5MB), downstream API rate limiting,
and the risk of a single timeout failing 3,000 records make chunked callouts the
production-safe choice.

---

## ❓ Interview Questions

### 🟢 Foundational

**Q:** What is the difference between a QueryLocator and an Iterable in Batch Apex?
**A:** A `Database.QueryLocator` is returned from a SOQL query and can handle up to
50 million records. The query itself does not consume your transaction's 100-SOQL budget —
it uses a separate allocation. An `Iterable<SObject>` processes a collection of objects
that you build in Apex code and is capped at 50,000 records. Use Iterable when your data
source isn't a SOQL query — for example, records from an HTTP callout result set, or a
complex filter that can't be expressed purely in SOQL. Default to QueryLocator for
standard SObject processing.
**What makes this 9/10:** Knowing the 50M vs 50K limit AND the fact that QueryLocator
SOQL does not count against your 100-query budget. Most candidates know one fact, not both.

**Q:** What is `Database.Stateful` and when would you NOT use it?
**A:** `Database.Stateful` preserves instance variable values across execute() chunk
boundaries. Without it, the batch class is re-instantiated from its serialized form
between chunks and all instance variables reset to constructor values. You need it when
you accumulate data across chunks — running totals, error logs, aggregated Maps. You
should NOT use it when the accumulated state is large (hundreds of thousands of Map
entries) because the entire stateful payload is serialized to the database between every
chunk. Large stateful batches are slower and prone to heap limit failures. Prefer a batch
that writes interim results to a custom object and reads them in `finish()` over an
unbounded stateful Map.
**What makes this 9/10:** The serialization cost and heap limit callout. "Just use
@TestVisible" is a mid-level answer. Knowing the performance penalty is architect-level.

### 🟡 Intermediate

**Q:** How do you chain Queueable jobs, and what is the depth limit?
**A:** From within a Queueable's `execute()` method, call `System.enqueueJob(new
NextQueueable(...))` to chain. In production asynchronous contexts, chaining depth is
effectively unlimited — each chained job runs as an independent asynchronous transaction.
In synchronous contexts (e.g., invoked from a trigger), the chain depth is limited to
avoid consuming the synchronous transaction's governor limits. In test context, Salesforce
enforces exactly one level of chaining — the chained job is enqueued but not executed
during `Test.stopTest()`. Always guard with `Test.isRunningTest()` or a feature flag to
prevent infinite chaining in test runs. Monitoring: each chained job creates a new
`AsyncApexJob` record with its own `ParentJobId` linking back to the triggering job.
**What makes this 9/10:** Citing the test context 1-level limit and the `ParentJobId`
monitoring field. These are things you only know from building real Queueable chains.

**Q:** Can you make a callout from within a Batch Apex `execute()` method?
**A:** By default, no — Batch Apex `execute()` does not allow callouts because Batch jobs
can run in the same transaction context as DML operations, and mixed DML/callout is
prohibited. However, if you add `Database.AllowsCallouts` to the batch class signature,
Salesforce permits callouts in `execute()`. The caveat: you must not mix DML and callouts
in the same execute() method. If you need both (update records based on callout response),
the pattern is: execute() does callouts only, accumulates results in a stateful structure,
and finish() does the DML update. Alternatively, use a Queueable with
`Database.AllowsCallouts` which has no such restriction.
**What makes this 9/10:** The "no DML + callout in same method" constraint is rarely
documented. Most people find it by hitting the runtime exception in production. Knowing
the finish()-for-DML pattern signals real production experience.

### 🔴 Advanced / Architect

**Q:** A nightly batch processes 5 million Accounts in chunks of 200. The batch has been
running for 8 hours and you notice the last 20% of chunks are processing much slower
than the first 80%. What are you looking at?
**A:** Multiple suspects, in order of likelihood: (1) **Stateful heap inflation** — if the
batch is `Database.Stateful` with a growing Map, serialization cost increases with every
chunk as the Map grows. 20% of the way through the Map is small; 80% in, it's massive.
Solution: write interim results to a staging object and clear the Map periodically.
(2) **Database contention** — the Account table is hot after 4 million updates. Other
transactions, reports, and triggers compete for the same rows. Solution: run in an
off-peak window, or use `FOR UPDATE` hints to reduce lock wait time.
(3) **SOQL performance degradation** — queries inside execute() may be hitting unindexed
fields at scale. Full table scans on 5M rows become progressively slower as Salesforce
must scan more rows to satisfy the WHERE clause.
(4) **Flex Queue exhaustion** — if other batch jobs were submitted during the run, chunks
may be queued behind them.
**What makes this 9/10:** The stateful heap inflation hypothesis first. Most candidates
jump straight to "it's a lock" or "add an index." The stateful growth arc is the
Salesforce-specific pattern that proves deep batch experience.

**Q:** How do you restart a failed Batch Apex job from the point of failure rather than
re-processing all records from the beginning?
**A:** Salesforce does not provide native checkpoint/resume for Batch Apex. The pattern
is: (1) At the end of each `execute()`, write the last-processed record ID or cursor
position to a Custom Setting or Named Credential-like boundary object. (2) In `start()`,
check for a stored cursor and add a `WHERE Id > :lastProcessedId` clause (requires an
indexed field — Id works well). (3) On resume, the batch starts from the cursor.
For truly large datasets, consider partitioning by a deterministic field (e.g.,
`CreatedDate` or a modulo on the record Id) and tracking completion per partition.
Spring '25 also added improved `AsyncApexJob` status granularity — you can now track
`JobItemsProcessed` vs `TotalJobItems` more reliably for resume logic.
**What makes this 9/10:** The cursor pattern. Most candidates say "you can't resume" and
stop there. The cursor-in-Custom-Setting pattern is production-proven and signals that
you've actually had to deal with a partially failed batch job on live data.

---

## 💻 Code Reference

| File | Layer | Purpose |
|------|-------|---------|
| `AccountRatingBatch.cls` | Batch | Nightly Account re-rating, reuses AccountService |
| `OpportunityRollupBatch.cls` | Batch (Stateful) | Closed Won revenue accumulation per Account |
| `AccountSyncQueueable.cls` | Queueable | Chunked REST callout chain to external CRM |
| `AsyncApexTest.cls` | Test | 11 test methods across all 3 async classes |
| `Account.Total_Closed_Won_Revenue__c` | Custom Field | Rollup target populated by OpportunityRollupBatch |
| `AccountService.cls` (updated) | Service | `applyRatingFromRevenue` promoted to public |

---

## 🔗 Cross-Topic Connections

- **Day 1 (Trigger Framework):** `AccountRatingBatch` calls the same
  `AccountService.applyRatingFromRevenue()` as the trigger. This is the core payoff of
  the Service layer — batch and trigger share one implementation, not two.
- **Day 3 (Future & Scheduled):** `AccountRatingBatch` should be launched by a Scheduled
  Apex class. Day 3 adds `AccountRatingScheduler.cls` that calls `Database.executeBatch()`
  nightly. `finish()` can fire a Platform Event to trigger email on errors.
- **Day 16 (REST Integrations):** `AccountSyncQueueable` uses a Named Credential
  (`callout:ExternalCRM`). Day 16 creates the Named Credential definition and adds
  JWT/OAuth handling to the callout auth flow.
- **Day 24 (Large Data Volumes):** OpportunityRollupBatch will struggle at 100M+ Opp
  records. Day 24 covers SOQL query plans, skinny tables, and batch partitioning strategies
  to keep chunk processing under 10 seconds.
- **Agentforce (Day 30):** An Agentforce Agent Action cannot directly invoke a Batch job.
  The standard pattern: Action calls a Queueable, Queueable calls `Database.executeBatch()`
  in its `execute()` method. Returns the AsyncApexJob ID to the Agent for status reporting.

---

## 📋 Best Practices

| Practice | Why | Consequence of Ignoring |
|----------|-----|------------------------|
| Load CMDT in start(), reuse in execute() | Avoids one SOQL per chunk | 1 SOQL × 25,000 chunks = 25K SOQLs on a 5M record batch |
| Store only primitives in stateful vars | Keeps serialization payload small | Heap limit exceptions at high record counts |
| Partial DML in execute() (allowPartial=true) | One bad record doesn't abort the chunk | AllOrNone=false is false by default in Batch — verify your DML call |
| Guard Queueable chaining with Test.isRunningTest() | Tests only support 1 chain level | Test throws LimitException: Too many queueable jobs added to the queue |
| Separate callout and DML transactions in Batch | Mixed callout+DML is prohibited | Runtime exception: Callout not allowed after DML |
| Query AsyncApexJob in finish() | Provides completion telemetry | You won't know how many chunks had errors without querying |

---

## ⚠️ Gotchas & Anti-Patterns

- **Calling `Database.executeBatch()` from a trigger:** You CAN do this — once per trigger
  transaction. But it's dangerous: a bulk trigger update of 200 records is 1 transaction
  and fires 1 batch. A data load of 200,000 records is 1,000 transactions, each firing 1
  batch = 1,000 batch jobs queued simultaneously, causing severe Flex Queue congestion.
  Instead, trigger the batch from a Scheduled Apex or use Platform Events as the bridge.

- **`@future` from a `@future`:** You cannot call a `@future` method from within another
  `@future` method. This is a hard platform restriction. If you need chained async
  processing, the answer is always Queueable.

- **Batch scope > 2,000 with callouts:** If your batch uses `Database.AllowsCallouts`,
  each execute() can make up to 100 callouts. With scope=2,000, you'd need one callout
  per 20 records to stay under the limit. Design scope size around your callout volume,
  not just DML row limits.

- **`Test.stopTest()` timeout:** In test context, `Test.stopTest()` executes async jobs
  synchronously. If your batch processes thousands of records, the test transaction CPU
  timer starts counting. Complex batch tests with large data sets can hit the 10-second
  CPU limit in tests even if the production batch runs fine.

- **`Database.Stateful` + recursion:** If your stateful batch calls code that fires a
  trigger, and that trigger calls the same batch via `executeBatch()`, you get a cascade.
  Always add a `TriggerHandler.bypass()` call around DML in batch execute() methods to
  prevent trigger re-entry.

---

## 🧠 Retention — 3 Things to Remember

1. **Each execute() is a fresh transaction — fresh governor limits.** This is the whole
   reason Batch Apex exists. 200 records × N chunks = N fresh limit budgets. The total
   records processed is unlimited; the per-chunk limits are the same as any Apex transaction.

2. **`Database.Stateful` = serialization cost per chunk.** Use it only when accumulation
   across chunks is genuinely necessary. Keep stateful variables small — Ids and primitives
   only. Large stateful Maps cause performance degradation that compounds with every chunk.

3. **Queueable > @future for anything non-trivial.** @future can't chain, can't accept
   complex types, and gives you no Job ID. The only reason to use @future in 2025 is
   compatibility with extremely old code — all new async requirements use Queueable.

---

## Updates
<!-- Appended automatically on "Update Day N" commands -->
