# Day 03 — @future · Scheduled Apex · Platform Events (intro) · Async Error Handling
**Phase:** 1 — Code-First Foundation
**Date:** 2026-03-29

---

## 📌 Topics Covered
- `@future(callout=true)` — trigger-to-callout bridge, parameter constraints, limitations
- Scheduled Apex — `Schedulable` interface, cron syntax, CronTrigger management
- Platform Events (intro) — publish/subscribe architecture, `HighVolume` vs `StandardVolume`
- `PublishAfterCommit` vs `PublishImmediately` — transaction boundary behaviour
- `Test.getEventBus().deliver()` — forcing Platform Event subscriber execution in tests
- Async error handling architecture — completing the error logging thread from Days 1 & 2

---

## 🏗 Architecture & Concepts

### The Async Execution Landscape (Complete Picture After Day 3)

```
Synchronous trigger transaction
  ├── @future(callout=true)          → separate async tx, callout allowed
  │     └── AccountFutureService
  │
  ├── System.enqueueJob()            → Queueable async tx (Day 2)
  │     └── AccountSyncQueueable
  │
  └── (trigger exits)

Salesforce Scheduler (cron)
  └── Schedulable.execute()
        ├── Database.executeBatch() → AccountRatingBatch   (Day 2)
        └── Database.executeBatch() → OpportunityRollupBatch (Day 2)

Error signalling
  └── EventBus.publish(Integration_Error_Log__e)
        └── IntegrationErrorLogTrigger (after insert, separate tx)
              └── Integration_Error_Log__c records
```

### @future — what it is and what it can't do

`@future` predates Queueable by several years. Its role today is narrow: **enabling
callouts from trigger context** in cases where a full Queueable job is overhead you
don't want to justify.

The platform restriction: DML operations open a database transaction. Callouts from
within an open transaction would expose uncommitted data to external systems, breaking
transactional isolation. `@future(callout=true)` defers the callout to after the
triggering transaction commits, in a new async transaction where no DML is pending.

**What @future cannot do:**

| Constraint | Detail |
|-----------|--------|
| Parameter types | Primitives and collections of primitives only — no SObjects, no Maps |
| Chaining | Cannot call another @future from within a @future |
| Job monitoring | No AsyncApexJob record created — no JobId, no cancellation |
| Re-queue | Cannot enqueue a Queueable from inside a @future |
| Mixed callout+DML | DML in @future is allowed (unlike Batch execute+callout); no restriction |

**Rule of thumb:** If you find yourself working around @future's limitations, switch to
Queueable. @future remains valid for simple, single-hop, fire-and-forget callouts that
don't need monitoring or chaining.

### Scheduled Apex — execution model

`System.schedule(name, cron, instance)` registers a `CronTrigger` record. The scheduler
fires the `execute()` method at each trigger time. The job itself runs within its own
Apex transaction with fresh governor limits.

**Cron syntax (7 fields):**
```
Seconds  Minutes  Hours  Day-of-Month  Month  Day-of-Week  Year (optional)
   0        0       2        *            *        ?           (any year)
```
The `?` means "no specific value" — required in either Day-of-Month or Day-of-Week
(you can't specify both). `*` means "every."

| Expression | Meaning |
|---|---|
| `0 0 2 * * ?` | 2:00 AM every day |
| `0 0 2 ? * MON-FRI` | 2:00 AM weekdays only |
| `0 0 2 1 * ?` | 2:00 AM on the 1st of every month |
| `0 0/30 * * * ?` | Every 30 minutes |

**Org limit:** Maximum 100 scheduled jobs (CronTriggers) active at one time.
Monitor via `SELECT Id, CronJobDetail.Name, State FROM CronTrigger` and `System.abortJob()`
for cleanup. This limit bites multi-tenant ISV packages hardest.

**Scheduled Apex cannot be deployed active.** The CronTrigger is not metadata — it's
a runtime record created by `System.schedule()`. Every sandbox refresh or org deployment
requires re-scheduling. Script this in your CI/CD pipeline (anonymous Apex post-deploy step).

### Platform Events — architecture deep dive

Platform Events are the Salesforce-native pub/sub message bus. They sit on top of the
same infrastructure as Streaming API (CometD) but add:
- Apex-native publish (`EventBus.publish()`)
- Apex trigger subscribers (after insert — only valid context)
- Declarative subscribers (Flows, Process Builder)
- Replay capability (stream position via ReplayId)

**Event Types:**

| Type | Throughput | Apex Trigger Subscriber | Use When |
|------|-----------|------------------------|----------|
| HighVolume | Higher (varies by edition) | ✅ Yes (API 47+) | Most production use cases |
| StandardVolume | Lower | ✅ Yes | Legacy, low-volume events |

**Publish Behaviour — this is the most important decision:**

`PublishAfterCommit` (default):
- Event fires only if the publishing transaction commits
- Best for business events where the event should only exist if the data exists
- **Risk:** If the publishing transaction rolls back (exception), the error event is lost

`PublishImmediately`:
- Event fires regardless of transaction outcome — even if the publisher rolls back
- Best for error and audit events that must fire even during transaction failure
- **Risk:** Creates events from rolled-back transactions — subscriber may see phantom data

**For IntegrationErrorLogger:** We use `PublishAfterCommit` because our errors come from
partial-success DML scenarios — the transaction commits, some records fail. The event
correctly fires after commit. For a true fault-tolerant error logger (one that captures
exceptions and rollbacks), switch to `PublishImmediately`.

### Subscriber trigger behaviour (commonly misunderstood)

The subscriber trigger (`IntegrationErrorLogTrigger`) runs in a **completely separate
async transaction** from the publisher. This means:
1. Publisher DML (Account updates) and subscriber DML (log record inserts) have
   independent governor limits and independent rollback boundaries.
2. If the subscriber fails (DML exception inserting the log record), **the original
   publishing transaction is not affected** — it already committed.
3. The subscriber has its own 150 DML / 100 SOQL limits per invocation.
4. HighVolume events can batch up to 2,000 events per subscriber trigger invocation.

### Completing the error handling thread (Days 1–3)

| Day | Error Handling |
|-----|---------------|
| Day 1 | `System.debug(LoggingLevel.ERROR, ...)` — debug log only |
| Day 2 | Same System.debug pattern in batch classes |
| Day 3 | `IntegrationErrorLogger` → `Integration_Error_Log__e` → `Integration_Error_Log__c` |

New code from Day 3 onwards uses `IntegrationErrorLogger` directly. Day 1/2 classes
retain System.debug for now — a production-ready "Update Day 1" would swap them.

### Spring '25 (API 62.0) Notes
- **Platform Events + Agentforce:** Agent Actions can subscribe to Platform Events via
  Flows — an Agent can react to `Integration_Error_Log__e` events and automatically
  open a Case or alert a team. This is the Day 30 connection.
- **Scheduled Apex + Flow:** Spring '25 allows Flows to be scheduled directly (without
  Scheduled Apex as the launcher). For simple batch-like processing without Apex,
  evaluate Flow scheduler before building a new Schedulable class.
- **`@future` deprecation trajectory:** Salesforce hasn't deprecated @future, but the
  introduction of Queueable (2014), allotment increases, and documentation shifts all
  point toward Queueable as the preferred pattern. New code should always start with
  Queueable unless the use case is genuinely trivial.

---

## ⚙️ Scenarios

### Scenario 1 — Trigger → Callout Without @future (Anti-Pattern)

**Business Problem:**
An Account insert should look up the SIC code from an external data service to
enrich the record before it hits reporting.

**Approach — Anti-Pattern (what NOT to do):**
```apex
// WRONG — callout from trigger context
trigger AccountTrigger on Account (after insert) {
    for (Account acc : Trigger.new) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.siccodes.com/lookup?industry=' + acc.Industry);
        HttpResponse res = new Http().send(req); // ← System.CalloutException thrown
    }
}
```
This throws `System.CalloutException: You have uncommitted work pending. Please commit
or rollback before calling out.` at runtime. The trigger runs inside an open DML
transaction — callouts from within open transactions are prohibited.

**Correct Approach:**
`@future(callout=true)` defers the callout to after the trigger's DML transaction commits.
`AccountTriggerHandler.afterInsert` collects Account IDs with Industry populated and
calls `AccountFutureService.enrichWithSicCode(accountIds)`. The @future method runs in
a separate async transaction where no DML is pending.

### Scenario 2 — Scheduler Timing Conflict (Batch Resource Contention)

**Business Problem:**
Two nightly batch jobs were scheduled at the same time (2:00 AM). Both process Account
records. Database locks cause both jobs to run significantly slower and occasionally
one fails with lock timeout errors.

**Approach:**
Stagger the schedulers. `AccountRatingScheduler` runs at 2:00 AM; `OpportunityRollupScheduler`
runs at 3:00 AM. Estimate the earlier job's runtime from `AsyncApexJob.CompletedDate`
vs `CreatedDate` in the job history, and set the gap accordingly.

For unpredictable runtimes, use the `finish()` method as a chaining mechanism:
`AccountRatingBatch.finish()` calls `Database.executeBatch(new OpportunityRollupBatch())`
directly, guaranteeing OpportunityRollupBatch only starts after AccountRatingBatch
completes — regardless of how long the first job takes.

**Trade-off:** Chaining batches in `finish()` creates a hard dependency. If AccountRatingBatch
fails, OpportunityRollupBatch never runs. Use this only when the sequence dependency is
genuinely required.

### Scenario 3 — Platform Event Subscriber Failure (Error Handling Anti-Pattern)

**Business Problem:**
The `IntegrationErrorLogTrigger` subscriber has a bug that causes it to throw an
unhandled exception. The ops team worries this will start losing error events.

**What actually happens (important to know for interviews):**
When a Platform Event subscriber trigger fails:
1. Salesforce retries the subscriber trigger automatically — up to 3 times for `HighVolume`.
2. If all retries fail, the **event is NOT lost** — it remains in the event bus and can
   be replayed using the ReplayId stored from a prior successful delivery.
3. The publishing transaction is NOT affected — it committed successfully before the
   subscriber ever ran.
4. A `Platform Event Usage` metric records the failed delivery for monitoring.

This is the key advantage over synchronous DML for error logging: publisher isolation.
Fix the subscriber bug, redeploy, and replay events from the last known good ReplayId.

---

## ❓ Interview Questions

### 🟢 Foundational

**Q:** Why can't you make an HTTP callout directly from an Apex trigger?
**A:** Apex triggers run within an active database transaction. The platform prohibits
HTTP callouts from within open DML transactions to prevent uncommitted data from being
exposed to external systems — a transactional isolation violation. If the callout
succeeded but the transaction later rolled back, the external system would have received
data that Salesforce never committed. The solution is `@future(callout=true)`, which
defers the callout to after the triggering transaction commits, in a fresh async
transaction with no pending DML.
**What makes this 9/10:** Explaining the *why* — the transactional isolation concern,
not just "the platform doesn't allow it." This is the architect-level framing.

**Q:** What is the maximum number of Scheduled Apex jobs an org can have active?
**A:** 100 CronTrigger records maximum per org. This counts all active scheduled jobs —
custom code, standard Salesforce features (Report Subscriptions), and managed package
schedulers all share this limit. In practice, large orgs with many installed packages
can hit this limit. Monitor via `SELECT Id, CronJobDetail.Name, State FROM CronTrigger`.
Clean up stale jobs with `System.abortJob(cronTriggerId)`. A common ISV anti-pattern
is scheduling on package install without checking if a job already exists — this
creates duplicate jobs and burns through the org limit.
**What makes this 9/10:** The managed package angle. Most candidates say "100 jobs" and
stop. Knowing that packages share the same limit and cause real production problems
signals enterprise-scale experience.

### 🟡 Intermediate

**Q:** What is the difference between `PublishAfterCommit` and `PublishImmediately` on a Platform Event, and when would you choose each?
**A:** `PublishAfterCommit` fires the event only after the publishing Apex transaction
successfully commits. If the transaction rolls back, the event is silently discarded.
This is the correct choice for business events — you only want to notify downstream
systems about data that actually exists in Salesforce. `PublishImmediately` fires the
event regardless of the transaction outcome, even if the publisher rolls back. This is
the correct choice for audit and error logging events where you need a record of what
was attempted, not just what succeeded. For `IntegrationErrorLogger`, `PublishAfterCommit`
works for partial-success DML errors (transaction commits, some records fail). For
capturing unhandled exceptions and transaction rollbacks, you'd need `PublishImmediately`
— at the cost of potentially logging events from transactions that were rolled back.
**What makes this 9/10:** Naming the specific failure case for `PublishAfterCommit`:
unhandled exception rollbacks lose the event. Most candidates describe the happy path only.

**Q:** How do you test Platform Event subscriber triggers? What does `Test.getEventBus().deliver()` do?
**A:** Platform Event publisher and subscriber run in separate async transactions. In test
context, `EventBus.publish()` enqueues events but does not automatically fire the subscriber
trigger — the async delivery is suppressed. `Test.getEventBus().deliver()` (API 48.0+)
forces immediate synchronous delivery of all pending Platform Events to their subscriber
triggers within the test transaction. It must be called inside `Test.startTest() /
Test.stopTest()`. Without it, you can only assert that `EventBus.publish()` returned a
successful `Database.SaveResult` — you cannot assert on the subscriber's output (the
`Integration_Error_Log__c` records won't exist yet). The pattern: publish → deliver()
→ assert on subscriber-created records.
**What makes this 9/10:** Knowing the method name and that it must be inside startTest/stopTest.
The majority of candidates either don't know Platform Event subscriber testing at all,
or just use `Test.stopTest()` (which doesn't deliver events).

### 🔴 Advanced / Architect

**Q:** A Platform Event is published from an Apex trigger on Account. The subscriber trigger that processes this event also updates Account records. Could this cause a recursion loop?
**A:** Not directly — the subscriber runs in a separate async transaction, so it cannot
re-enter the publishing transaction's trigger context. However, the subscriber's Account
update WILL fire the Account trigger in its own transaction. If the Account trigger then
publishes the same Platform Event again, you have an indirect loop: Account trigger
→ Platform Event → subscriber trigger → Account update → Account trigger → Platform Event
→ ... This is an event-driven recursion pattern that Salesforce does not protect against
automatically. Solutions: (1) Add a field to the event that indicates it originated from
a subscriber-driven update, and check this flag in the Account trigger before publishing.
(2) Use `TriggerHandler.bypass('AccountTriggerHandler')` at the start of the subscriber
trigger and clear it after the Account DML. (3) Redesign so the subscriber never updates
the same object that triggered the original publish.
**What makes this 9/10:** Describing the indirect loop pattern. The immediate answer
"subscriber is separate async, so no recursion" is only half correct. The architectural
answer covers the two-hop recursion pattern.

**Q:** Your org has 95 scheduled jobs and a new ISV package is trying to schedule 8 more on install. How do you architect around this limit in a multi-package org?
**A:** The core problem is the 100 CronTrigger ceiling shared across all packages. Solutions:
(1) **Job consolidation:** Replace multiple single-purpose schedulers with one "Master
Scheduler" that runs frequently (e.g., every 15 minutes) and uses Custom Metadata to
determine which batch jobs to launch at which times. This uses 1 CronTrigger for N batch
jobs. (2) **Package-install hook:** In the package install handler (`InstallHandler`),
check for existing scheduled jobs by name before registering new ones to prevent
duplicates. (3) **On-demand scheduling:** Instead of always-on scheduled jobs, trigger
scheduling from a Custom Metadata change event — jobs are only active when needed.
(4) **Platform Cache for lightweight scheduling:** For frequent light operations, use
Platform Cache with expiry-based triggers instead of Scheduled Apex.
**What makes this 9/10:** The Master Scheduler pattern. It's a real production pattern
used by orgs with many installed packages and directly demonstrates you've architected
multi-package Salesforce environments.

---

## 💻 Code Reference

| File | Layer | Purpose |
|------|-------|---------|
| `AccountFutureService.cls` | Service (@future) | Async SIC code enrichment via callout on Account insert |
| `AccountRatingScheduler.cls` | Scheduler | Nightly launcher for AccountRatingBatch at 02:00 AM |
| `OpportunityRollupScheduler.cls` | Scheduler | Nightly launcher for OpportunityRollupBatch at 03:00 AM |
| `IntegrationErrorLogger.cls` | Utility | Platform Event publisher — centralised error logging |
| `IntegrationErrorLogTrigger.trigger` | PE Subscriber | Writes Integration_Error_Log__e → Integration_Error_Log__c |
| `Integration_Error_Log__e` | Platform Event | HighVolume event, PublishAfterCommit |
| `Integration_Error_Log__c` | Custom Object | Persistent error log — AutoNumber name, 6 fields |
| `ScheduledApexTest.cls` | Test | 7 methods: schedulers + @future + end-to-end trigger chain |
| `IntegrationErrorLoggerTest.cls` | Test | 7 methods: publish API, subscriber, bulk, ReplayId |
| `AccountTriggerHandler.cls` (updated) | Handler | afterInsert added → AccountFutureService |

---

## 🔗 Cross-Topic Connections

- **Day 1 (Trigger Framework):** `AccountTriggerHandler.afterInsert` now calls
  `AccountFutureService`. The handler is the only file that changed — zero changes to
  the service layer. This is exactly the layering payoff: adding a new async behaviour
  to Account insert required touching one method in one class.
- **Day 2 (Batch Apex):** `AccountRatingScheduler` and `OpportunityRollupScheduler`
  complete the production lifecycle for Day 2 batch jobs — they are now fully scheduled
  without manual intervention.
- **Day 16 (REST Integrations):** `AccountFutureService` uses a Named Credential
  `SicCodeService`. Day 16 creates this credential with OAuth2 configuration.
- **Day 18 (Platform Events Deep Dive):** Today is the intro — basic publish/subscribe.
  Day 18 covers Change Data Capture, Pub/Sub API, replay strategies, and monitoring
  event delivery latency in production.
- **Day 30 (Agentforce):** An Agentforce Flow can subscribe to `Integration_Error_Log__e`
  and automatically create a Case or notify an on-call engineer when error rate spikes.
  The Platform Event bus is the integration point between Apex error detection and
  Agentforce reactive automation.

---

## 📋 Best Practices

| Practice | Why | Consequence of Ignoring |
|----------|-----|------------------------|
| Use `@future` only for simple one-hop callouts | Queueable is strictly more capable | No monitoring, no chaining, can't debug failures |
| Store the CronTrigger Id after `System.schedule()` | Required to abort the job later | Job runs forever; burns org job quota |
| Call `System.abortJob()` in test teardown | Prevents orphaned CronTrigger records in test | 100-job limit can be reached in sandbox with dirty test runs |
| `PublishAfterCommit` for business events, `PublishImmediately` for fault events | Correct transactional semantics | Business events fire on rollbacks; fault events lost during exceptions |
| Never use IntegrationErrorLogger inside IntegrationErrorLogTrigger | Infinite recursion: publisher → event → subscriber → publisher → ... | StackOverflow / System.LimitException at event bus limit |
| Test Platform Events with `Test.getEventBus().deliver()` | Subscriber trigger won't fire without explicit delivery | Tests pass but subscriber logic is untested |

---

## ⚠️ Gotchas & Anti-Patterns

- **`@future` from a batch execute():** You CANNOT call a `@future` method from within
  Batch Apex's `execute()`. The `@future` context restriction exists there too.
  Use Queueable from `finish()` if you need post-batch async work.

- **Checking `isFuture()` context:** `System.isFuture()` returns true inside an
  `@future` method. Use this guard if a service method needs to conditionally avoid
  calling another `@future` (which would throw a `System.LimitException`).

- **`Test.getEventBus().deliver()` outside startTest/stopTest:** If called outside
  the test boundaries, it doesn't work as expected — events already delivered in a
  previous transaction won't re-fire. Always call inside `Test.startTest()`.

- **Platform Event subscriber and 'without sharing':** Subscriber triggers run as the
  Automated Process user. If the subscriber tries to insert `Integration_Error_Log__c`
  and the Automated Process user doesn't have Create permission on that object, DML will
  fail silently (debug log only). Always test subscriber DML permissions explicitly, or
  add `without sharing` to the subscriber's logic class.

- **Scheduling in scratch orgs:** Scheduled jobs created in a scratch org are deleted
  when the org expires. Always include `scheduleMe()` calls in your CI/CD post-deploy
  anonymous Apex scripts so jobs are re-created after every scratch org creation.

---

## 🧠 Retention — 3 Things to Remember

1. **@future = callout bridge from trigger context.** Its only surviving use case in
   2025 is `@future(callout=true)` for simple trigger-initiated callouts. Every other
   async requirement should use Queueable. The limitations (no complex types, no chaining,
   no JobId) make Queueable the default choice.

2. **Platform Events decouple publisher and subscriber transactions.** The subscriber
   runs in a separate async context — its failures cannot roll back your original data.
   This is the core architectural value: reliable fire-and-forget across transaction
   boundaries. `PublishAfterCommit` vs `PublishImmediately` is the key decision, and
   the answer depends on whether you need events from failed transactions.

3. **Scheduled jobs are runtime records, not metadata.** `System.schedule()` creates a
   CronTrigger record that is NOT deployed by `sf project deploy`. Every org (scratch,
   sandbox, production) needs its own scheduling setup. Script it as a post-deploy step.
   The 100-job org limit is shared across all packages and Salesforce features.

---

## Updates
<!-- Appended automatically on "Update Day N" commands -->
