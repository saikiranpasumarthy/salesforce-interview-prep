# Day 01 — Apex Triggers · Trigger Frameworks · Governor Limits
**Phase:** 1 — Code-First Foundation
**Date:** 2026-03-29

---

## 📌 Topics Covered
- Apex Trigger lifecycle and execution order
- Trigger frameworks: Handler / Service / Domain pattern
- Abstract base handler with bypass control
- Governor Limits — per-transaction constraints and bulk-safe patterns
- Custom Metadata-driven configuration (zero hardcoded values)

---

## 🏗 Architecture & Concepts

### Why one trigger per object?

Salesforce does not guarantee execution order when multiple triggers exist on the same object. Two triggers firing in undefined order with interleaved before/after contexts is a debugging nightmare — especially with async callouts, Platform Events, or recursion. The single-trigger rule is non-negotiable at scale.

### The Framework Stack

```
AccountTrigger.trigger
  └── AccountTriggerHandler.cls   (extends TriggerHandler — dispatch only)
        ├── AccountService.cls    (business logic — orchestration across objects)
        └── AccountDomain.cls     (object invariants — rules about what Account IS)
```

**TriggerHandler (abstract base):**
The abstract base class does one job: route Trigger context flags to virtual methods.
It also owns the bypass registry — a static `Set<String>` that persists for the life of
the transaction. This lets data loaders, integration users, and test setup skip specific
handlers without disabling the trigger in Setup.

**Handler layer:**
The handler constructor eagerly captures `Trigger.new`, `Trigger.old`, `Trigger.newMap`,
`Trigger.oldMap` from the static Trigger variable. After the handler method returns,
`Trigger.new` is no longer valid context — capturing upfront prevents null reference
bugs when service methods are unit-tested directly (no Trigger context at all).

**Service vs Domain:**
This is the most common architecture question in senior interviews.

| Layer | Owns | SOQL? | DML? |
|-------|------|-------|------|
| Domain | Rules about what a record IS — field-level invariants | Yes (scoped) | Never (addError only) |
| Service | What a record DOES to other records — cross-object orchestration | Yes | Yes |

If a rule only touches fields on the current SObject, it belongs in Domain.
If it queries or modifies other objects, it belongs in Service.

### Governor Limits — what actually bites you

The 100 SOQL / 150 DML per transaction limits are per *Apex transaction*, not per *trigger
invocation*. A Flow, Process Builder, or a cascade trigger can consume half your limits
before your Apex even runs. The safe design assumption is: *you start every method with
a depleted budget.*

Key limits you need to own in interviews:

| Limit | Value | Mitigation |
|-------|-------|------------|
| SOQL queries | 100 | Bulkify — one query outside the loop, Map by Id |
| SOQL rows returned | 50,000 | Use LIMIT, pagination, or QueryLocator (batch) |
| DML statements | 150 | One `List<SObject>` → one DML outside loop |
| DML rows | 10,000 | Batch Apex for large datasets |
| CPU time | 10,000ms sync / 60,000ms async | Avoid nested loops, cache SOQL results |
| Heap | 6MB sync / 12MB async | Don't build massive Maps of full SObjects — store only what you need |
| Callouts | 100 / 10s per callout | Never call out in triggers — use async (Queueable/Future) |

**Custom Metadata queries do NOT count against the 100 SOQL limit** — but they do count
against heap. Query once, re-use the list.

### Spring '25 (API 62.0) Notes
- **Trigger order control (Beta):** `TriggerOperation` enum and ordering metadata are in
  developer preview. Currently for ISV packaging only — not GA for direct org use.
- **Flow-before-Trigger ordering** is still org-dependent (Run Flow Before Triggers perm).
  Always clarify this in design reviews when combining Flow and Apex on the same object.
- **Agentforce thread:** Agentforce Agent Actions call Apex via `@InvocableMethod`. Your
  service methods are already safe for this — they have no Trigger context dependency.

---

## ⚙️ Scenarios

### Scenario 1 — Revenue-Driven Rating with Config-Driven Thresholds

**Business Problem:**
Sales ops wants to auto-set Account Rating (Hot/Warm/Cold) based on AnnualRevenue.
Thresholds change every quarter. Releasing a new Apex class for a threshold change is
too slow and risky.

**Approach:**
Custom Metadata Type `Account_Rating_Config__mdt` with `Revenue_Threshold__c` (Number)
and `Rating_Value__c` (Text). Three records: Hot (≥ $10M), Warm (≥ $1M), Cold (≥ $0).
Service queries CMDT once per transaction, sorted descending. First match wins.

**Solution & Trade-offs:**
- `@TestVisible private static applyRatingFromRevenue()` separates CMDT query from rating
  logic, enabling full unit test isolation without SOQL.
- Trade-off: CMDT records are org-wide. If multiple business units need different thresholds
  per record type, add a `Record_Type_Name__c` field as a secondary key.
- CMDT vs Custom Settings: CMDT is deployable (source-controlled), readable without sharing
  context, and works in managed packages. Custom Settings require separate deploy and can
  create sharing complications. Default to CMDT.

### Scenario 2 — Preventing Account Delete with Open Opportunities (Anti-Pattern)

**Business Problem:**
Reps accidentally delete Accounts that still have active pipeline. The deletion cascades
and orphans or deletes related Opportunities, losing revenue history.

**Approach — Anti-Pattern (what NOT to do):**
```apex
// WRONG — SOQL inside a loop. At 200 records this fires 200 SOQL queries.
for (Account acc : Trigger.old) {
    List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE AccountId = :acc.Id];
    if (!opps.isEmpty()) {
        acc.addError('Cannot delete...');
    }
}
```
This hits the 100-query limit at exactly 100 records. It will pass your 1-record manual test
and fail your first real bulk load.

**Correct Approach:**
Aggregate query with `GROUP BY AccountId` outside the loop. One SOQL regardless of batch
size. Map the results by AccountId. Then iterate the accounts list and check the Map.
See `AccountService.preventDeleteWithOpenOpportunities()`.

### Scenario 3 — Case Owner Sync on Account Reassignment

**Business Problem:**
When an Account is reassigned to a new owner (territory change, rep turnover), open Cases
remain with the previous owner. Support queue routing breaks.

**Approach:**
After-update trigger context. Detect only accounts where `OwnerId` actually changed
(compare newMap vs oldMap — avoid processing every update). Query open Cases for those
accounts in one SOQL. Batch update. Use `Database.update(list, false)` for partial success.

**Key subtlety — recursion guard:**
If the Case trigger also has after-update logic that touches Account, you can get a loop.
A `static Boolean processed = false` guard blocks ALL subsequent executions — including
legitimate ones from other code paths. `static Set<Id> processedCaseSyncIds` is precise:
only the specific Account Ids that already ran are skipped.

---

## ❓ Interview Questions

### 🟢 Foundational

**Q:** Why should a trigger contain zero business logic?
**A:** Triggers are not testable in isolation — you can only invoke them through DML.
If logic lives in the trigger, every test requires full DML setup, making tests slow,
brittle, and hard to debug. Moving logic to a Service class lets you unit test that logic
directly, mock inputs, and test edge cases without any DML overhead. It also enables
reuse: the same service method can be called from Batch Apex, Queueable jobs, REST
endpoints, or InvocableMethod for Flows — all without duplicating code.
**What makes this 9/10:** The reusability angle. Most candidates say "testability."
Senior candidates add "any code path that needs this logic — batch, REST, Flow — calls
the same service." That's the architectural insight.

**Q:** What is the difference between `with sharing` and `without sharing` in Apex?
**A:** `with sharing` enforces the running user's record-level sharing rules (OWD +
sharing rules + manual shares + role hierarchy). `without sharing` runs in system context
and ignores sharing — the code sees all records. If neither keyword is declared, the class
inherits the sharing mode of its caller, which is unpredictable. Best practice: declare
explicitly on every class. Use `with sharing` by default. Switch to `without sharing`
only for specific, justified operations (e.g., a sharing-calculation class that must see
all records to build share records correctly).
**What makes this 9/10:** "If neither is declared, the class inherits the calling context."
Most candidates don't know this and assume it defaults to `with sharing`.

### 🟡 Intermediate

**Q:** How do you prevent trigger recursion, and what's wrong with a static Boolean flag?
**A:** The canonical approach is a `static Boolean hasRun = false` guard — set it to true
on entry, return early if true. The problem: it's a blunt instrument. Once set, it blocks
ALL subsequent trigger invocations in the transaction, including legitimate ones from
different code paths (e.g., a workflow update, a separate Batch Apex job, or an
InvocableMethod call later in the transaction). A `static Set<Id> processedIds` is
precise: you only skip the specific records already processed, not the entire trigger.
This matters in complex transactions where the same trigger fires multiple times on
different record sets.
**What makes this 9/10:** Explaining the failure mode of the Boolean flag with a concrete
example. The Set<Id> approach is not just "better practice" — it's necessary when you
have multi-context transactions.

**Q:** A trigger on Account does an update on related Cases. The Case trigger then fires.
Can the Case trigger cause the Account trigger to fire again? How do you control this?
**A:** Yes — if the Case trigger updates the Account (or if a workflow/process on Case
updates Account), the Account trigger fires again. The recursion depth is capped by
Salesforce at 16 trigger re-entries per transaction, after which a `System.LimitException`
is thrown. Control it by: (1) designing triggers so they don't create circular update
chains; (2) using the `Set<Id>` recursion guard in the Account service to skip accounts
already processed; (3) using `TriggerHandler.bypass()` at strategic points during
data migration scripts where you need to suppress secondary processing.
**What makes this 9/10:** Citing the 16-level re-entry limit. Most candidates know "you
can get a loop" but don't know the exact limit or how Salesforce terminates it.

### 🔴 Advanced / Architect

**Q:** How would you design a trigger framework that supports multiple business units
sharing one Salesforce org, each with their own logic on the same object, without
creating deployment conflicts?
**A:** The core problem is that two teams writing `AccountTriggerHandler.beforeInsert()`
creates a merge conflict on every sprint. The solution is a metadata-driven dispatch
pattern: instead of hardcoding service calls in the handler, define a Custom Metadata
Type `Trigger_Action__mdt` with fields `Object__c`, `Event__c`, `Class_Name__c`,
`Order__c`, `Active__c`. The handler queries this metadata and dynamically instantiates
and invokes each action class (implementing a common `ITriggerAction` interface). Each
business unit deploys their own CMDT record pointing to their own class — no shared
handler edits, no conflicts. This is the basis of frameworks like `Apex Trigger Actions`
(Kevin O'Hara) and is the pattern behind fflib's trigger dispatcher.
**What makes this 9/10:** Describing the metadata-driven dispatch and naming the
ITriggerAction interface pattern. This immediately signals enterprise-level architecture
experience. Most candidates stop at "use a framework like fflib" without knowing why.

**Q:** A managed package installs a trigger on Account in a customer org that already has
a trigger. Both triggers fire. The package trigger performs a SOQL. How do you ensure
your org's trigger stays within governor limits?
**A:** You can't control the package's resource consumption, but you can make your code
as efficient as possible. Key strategies: (1) lazy SOQL evaluation — only query if
records actually match your criteria; (2) static caching — store query results in a
`static Map<Id, SObject>` so repeated calls in the same transaction don't re-query;
(3) reduce DML statements by accumulating all records in a single List before a single
DML operation; (4) move heavy processing to async (Queueable) so the synchronous
transaction limit doesn't apply. In extreme cases, request the package vendor expose a
bypass mechanism, or use `TriggerHandler.bypass('YourHandler')` during batch operations
where you control the transaction entry point.
**What makes this 9/10:** Static caching pattern and the async escape valve. The answer
"just be efficient" is mid-level. Knowing you can move to async specifically to get a
fresh limit budget is architect-level.

---

## 💻 Code Reference

| File | Layer | Purpose |
|------|-------|---------|
| `AccountTrigger.trigger` | Trigger | Entry point — routes to handler, zero logic |
| `TriggerHandler.cls` | Framework | Abstract base — dispatch + bypass control |
| `AccountTriggerHandler.cls` | Handler | Event routing to Service and Domain |
| `AccountService.cls` | Service | Rating assignment, delete prevention, case sync |
| `AccountDomain.cls` | Domain | Customer→Prospect type downgrade validation |
| `TestDataFactory.cls` | Test Support | Shared record creation + CMDT config injection |
| `AccountServiceTest.cls` | Test | 15 test methods, 200-record bulk coverage |
| `Account_Rating_Config__mdt` | Custom Metadata | Deployable revenue thresholds — Hot/Warm/Cold |

---

## 🔗 Cross-Topic Connections

- **Day 2 (Async Apex):** The Case owner sync in `AccountService` does inline DML.
  If you need to sync 50,000 Cases per Account, move this to a Queueable chain — the
  synchronous 10,000 DML row limit would breach. The service method signature stays the
  same; you swap the execution model.
- **Day 7 (Testing):** The `@TestVisible applyRatingFromRevenue()` pattern introduced
  here is a precursor to full dependency injection and mocking. On Day 7, this evolves
  into `Stub API` usage and interface-based mocking.
- **Day 22 (fflib Architecture):** The Trigger → Handler → Service → Domain stack you've
  built here is a simplified fflib. Day 22 adds the Selector layer, Unit of Work pattern,
  and Dependency Injection container on top of this same foundation.
- **Agentforce (Day 30):** Agentforce invokes Apex via `@InvocableMethod`. Service methods
  that have no Trigger context dependency (like the ones here) are directly wrappable in
  an InvocableMethod — no rewrite needed.
- **200 records → 200 million:** The same bulk pattern that handles 200 records handles
  200 million *if* you layer Batch Apex on top. The service method doesn't change —
  you just feed it one chunk at a time from a `Database.QueryLocator`.

---

## 📋 Best Practices

| Practice | Why | Consequence of Ignoring |
|----------|-----|------------------------|
| One trigger per object | Guaranteed execution order | Unpredictable behavior in multi-trigger orgs; near-impossible debugging |
| Declare sharing explicitly | Predictable data access | Inherited context causes data leaks or unexpected sharing failures |
| Static Set<Id> recursion guard | Precision control over re-entry | Boolean flag blocks legitimate later invocations in the same transaction |
| Database.update(list, false) | Partial success — don't abort clean records because one failed | AllOrNone=true aborts valid updates when one bad record exists in the batch |
| Custom Metadata for thresholds | Configurable without deployment | Threshold changes require Apex deployment → release cycle delays |
| @TestVisible for CMDT-dependent logic | Test isolation without mocking framework | Tests depend on org CMDT records → fail in scratch orgs without data setup |

---

## ⚠️ Gotchas & Anti-Patterns

- **`Trigger.new` is read-only in after contexts:** You cannot assign field values to
  `Trigger.new` records in after-insert or after-update. Only before-context allows
  in-memory field modification. Attempting this throws a runtime error, not a compile error.

- **`addError()` in after-delete:** `addError()` works in before-delete (prevents the
  delete). In after-delete the record is already gone — `addError()` here does nothing
  useful. Delete validation must go in before-delete.

- **SOQL in `@future` from a trigger:** Calling a `@future` method from a trigger is
  valid, but if that future method performs SOQL and DML, it runs with a fresh governor
  limit budget but shares the same overall transaction heap for objects passed as
  parameters. You cannot pass SObjects to `@future` methods — only primitive types or
  collections of primitives.

- **NULL check on `Trigger.newMap` in handler constructor:** In before-delete context,
  `Trigger.new` and `Trigger.newMap` are null (there are no "new" versions of deleted
  records). Casting null to `List<Account>` throws a NullPointerException. Always null-
  check before casting — or initialize to an empty collection as shown in the handler.

- **Static variables survive across test methods in the same test run:** The `processedCaseSyncIds` Set persists between test methods if tests share a transaction context. Always call `TriggerHandler.clearAllBypasses()` in test teardown or use separate test transactions.

---

## 🧠 Retention — 3 Things to Remember

1. **Trigger → Handler → Service → Domain is the architecture.** If logic is in the trigger file, it is wrong. If cross-object logic is in Domain, it is wrong. The layers are non-negotiable and each one has a single responsibility.

2. **Set<Id> recursion guard, not Boolean.** A Boolean blocks everything after the first run. A Set<Id> blocks only the records already processed. You will be asked this in every senior interview — know the failure mode of the Boolean approach.

3. **Custom Metadata is source-controlled, queryable without sharing, and deployable with sf CLI.** Custom Settings are not. Default to CMDT for any configuration. When asked "how do you avoid hardcoding?" — CMDT is the first-line answer.

---

## Updates
<!-- Appended automatically on "Update Day N" commands -->
