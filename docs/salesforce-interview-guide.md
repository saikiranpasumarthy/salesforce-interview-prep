# Salesforce Interview Preparation Guide
# Saikiran Pasumarthy — Senior Developer / Architect-Track

> Stack: Apex · LWC · Service Cloud · FSL · Experience Cloud · CPQ (Conga) · REST APIs · Azure DevOps · sf CLI · CI/CD
> Certifications: Field Service Consultant · Service Cloud Consultant · Administrator · Platform Developer I
> Target: Senior Developer / Tech Lead / Architect-track

---

## Section 1 — Salesforce Fundamentals

### 1.1 Multi-Tenant Architecture

Salesforce runs all customer orgs on shared infrastructure — the same application servers, the same database clusters, the same metadata engine. What isolates org A from org B is not separate VMs or containers but a **tenant ID** column on virtually every table in the underlying Oracle database. Every query Salesforce generates internally is automatically scoped by that tenant ID at the database layer.

**Why this matters for governor limits:**
Governor limits are not arbitrary restrictions invented to annoy developers. They are the contractual guarantee that one misbehaving org cannot starve the shared database, CPU pool, or memory heap that other orgs depend on. A query that does a full table scan on a 10M-row object in a single-tenant world might be acceptable — in a multi-tenant world, it consumes shared I/O and causes degraded response times for every org on that pod. The 100-SOQL-query limit exists because Salesforce's query optimizer needs to guarantee that any single transaction completes within a bounded time window.

**Pod architecture:**
- Each "pod" hosts thousands of orgs
- Salesforce maintains pod-level isolation for disaster recovery
- Hyperforce (cloud-native infrastructure on AWS/Azure/GCP) moves this to containerized compute while preserving the logical multi-tenancy model
- Your org's data is encrypted at rest; the encryption key is org-specific

**Practical implication for architects:**
When designing for scale, always ask: "Does this operation scale in proportion to org data volume, or does it fan out?" A SOQL query with a selective WHERE clause scales; a trigger that queries all records in a large object on every update does not. The platform will enforce the limit — your job is to design around it proactively.

---

### 1.2 Metadata vs Data

| Layer | What lives here | Deployed via | Examples |
|---|---|---|---|
| **Metadata** | Schema definitions, configuration, code | Deployment (SFDX, change sets, APIs) | Field definitions, Apex classes, page layouts, Flows, permission sets, record types |
| **Data** | Actual records stored by users | Data loader, UI, APIs | Account records, Contact records, custom object rows, field values |

**The key distinction:**
- A **field definition** (`Name__c`, type=Text, length=255) is metadata — it travels in your SFDX package, deploys with `sf project deploy`, and is the same in every sandbox that receives the deployment
- A **field value** ("ACME Corporation" stored in `Name__c` on Account ID 001xxxx) is data — it does not deploy; it is loaded via Data Loader, import wizards, or integration

**Why this matters in interviews:**
Candidates regularly confuse "deploying custom settings" with deploying data. Custom Setting *definitions* are metadata and deploy. Custom Setting *values* are data and do not. Custom Metadata Type *definitions* AND *values* are both metadata — this is the primary reason to choose Custom Metadata over Custom Settings when you need the configuration to travel with deployments.

**Deployment implications:**
- Deploying metadata to production does not touch existing record data
- Deleting a field definition (metadata) cascades to delete all values stored in that field — this is destructive and irreversible without a backup
- Changing a field's type (e.g., Text → Picklist) is a metadata change that may be blocked if existing data is incompatible

---

### 1.3 Order of Execution

When a record is saved (insert or update), Salesforce executes the following sequence. Understanding this sequence is the most reliable way to debug unexpected behavior in complex orgs.

**Complete Sequence (17 steps):**

1. Load the original record from the database (or initialize with defaults for new records)
2. Load new field values from the save request (overwrite loaded values)
3. Execute all **before triggers** (including `before insert`, `before update`)
4. Run **system validation**: required fields, field formats, max length enforcement
5. Save the record to the database (but do NOT commit yet — this is a write to the session's unit of work)
6. Execute **after triggers** (`after insert`, `after update`)
7. Execute **assignment rules** (Lead/Case assignment)
8. Execute **auto-response rules** (Case auto-response emails)
9. Execute **workflow rules** (legacy — field updates, email alerts, tasks, outbound messages)
10. If workflow field updates fired, re-execute before and after triggers **once more**, then re-run validation — but NOT workflow rules again (prevents infinite loop)
11. Execute **processes** (Process Builder — deprecated path, still in use in many orgs)
12. Execute **escalation rules**
13. Execute all **record-triggered Flows** (after-save)
14. Execute **entitlement rules**
15. Execute **roll-up summary field** calculations on parent records
16. Execute criteria-based sharing rules evaluation
17. **Commit** the transaction to the database; send any email alerts queued during the transaction

**Real combined scenario — one record update, multiple automations firing:**

> Scenario: A Support Rep updates a Case's `Status` from "In Progress" to "Escalated".

Step 3 — Before trigger fires: `CaseTriggerHandler` (extends `TriggerHandler`) runs, reads Status change, sets `EscalatedDate__c = DateTime.now()` in memory. No DML yet.

Step 4 — Validation rule fires: checks that `EscalatedReason__c` is not blank when Status = 'Escalated'. If blank, save aborts here — nothing else fires.

Step 6 — After trigger fires: `CaseTriggerHandler` detects Status change, enqueues a `CaseEscalationQueueable` via `System.enqueueJob()`. The queueable runs in a **separate transaction** after commit — the callout to PagerDuty happens there.

Step 9 — Workflow rule fires: a legacy workflow sends an email alert to the case owner's manager.

Step 13 — Record-triggered Flow fires (after-save): an after-save Flow creates a Task "Follow up with customer" assigned to the case owner.

**Why the order matters:**
- If the validation rule at step 4 fails, the after trigger (step 6) never fires — no PagerDuty alert
- If the after trigger (step 6) updates the Case record via DML, that DML triggers a new save cycle starting back at step 1 for that update — this is trigger recursion, which `TriggerHandler.cls` prevents with a static depth counter
- The Flow at step 13 fires after the after trigger — any `@future` or `Queueable` enqueued in the trigger runs after the Flow completes and the transaction commits

---

### 1.4 Governor Limits

**Synchronous vs Asynchronous limits (full table):**

| Limit | Synchronous | Async (Future/Queueable) | Batch execute() | Scheduled |
|---|---|---|---|---|
| SOQL queries | 100 | 200 | 200 | 200 |
| SOQL rows returned | 50,000 | 50,000 | 50,000 | 50,000 |
| DML statements | 150 | 150 | 150 | 150 |
| DML rows | 10,000 | 10,000 | 10,000 | 10,000 |
| CPU time | 10,000 ms | 60,000 ms | 60,000 ms | 60,000 ms |
| Heap size | 6 MB | 12 MB | 12 MB | 12 MB |
| Callouts | 100 | 100 | 100 | 100 |
| Future calls (from sync) | 50 | — | 0 (not allowed) | — |
| Queueable jobs (enqueued) | 50 | 1 (chain) | 1 | 1 |
| Email invocations | 10 | 10 | 10 | 10 |

**Real scenario — what breaks at 101 SOQL queries:**

```apex
// ❌ ANTI-PATTERN — SOQL in loop
for (Account acc : accounts) {
    List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
    // This fires one SOQL per Account. At 101 accounts: LimitException
}

// ✅ CORRECT — Map-based bulk query
Map<Id, List<Contact>> contactsByAccount = new Map<Id, List<Contact>>();
Set<Id> accountIds = new Set<Id>();
for (Account acc : accounts) accountIds.add(acc.Id);

for (Contact c : [SELECT Id, AccountId FROM Contact WHERE AccountId IN :accountIds]) {
    if (!contactsByAccount.containsKey(c.AccountId)) {
        contactsByAccount.put(c.AccountId, new List<Contact>());
    }
    contactsByAccount.get(c.AccountId).add(c);
}
```

The `AccountService.cls` in this repo uses this exact pattern in `syncBillingToChildContacts` — one SOQL outside the loop, grouped results consumed inside.

**Monitoring limits in production code:**
```apex
if (Limits.getQueries() >= Limits.getLimitQueries() - 5) {
    // Less than 5 queries remaining — enqueue remainder
    System.enqueueJob(new ContinuationQueueable(remainingIds));
    return;
}
```

---

### 1.5 Data Model Fundamentals

**Lookup vs Master-Detail — deep comparison:**

| Aspect | Lookup | Master-Detail |
|---|---|---|
| Parent required on child | No (nullable) | Yes (always required) |
| Cascade delete | No (configurable reparent) | Yes — deleting parent deletes all children |
| Reparenting allowed | Yes (change the lookup value) | No (locked after insert unless "Allow reparenting" enabled) |
| Rollup Summary fields | ❌ Not supported natively | ✅ COUNT, SUM, MIN, MAX on child |
| OWD/Sharing | Child has independent OWD | Child inherits parent's sharing |
| Impact on org deletion | Relationship field can be deleted; children remain | Cannot delete parent record type / object if children exist |

**When to use lookup over master-detail:**
- The child record must be able to exist without a parent (e.g., a Contact without an Account)
- You need the child to belong to a different owner than the parent
- You want the child to have its own independent sharing model

**Polymorphic relationships:**
Task and Event have two polymorphic fields:
- `WhatId` — can point to Account, Opportunity, Case, Lead, or any custom object with Activity tracking enabled. The SObject type is resolved at runtime
- `WhoId` — can point to Contact or Lead

Querying polymorphic fields requires TYPEOF in SOQL:
```soql
SELECT Id, Subject,
    TYPEOF What WHEN Account THEN Name WHEN Opportunity THEN Amount END
FROM Task
WHERE WhatId != null
```

**Junction objects:**
Used to model many-to-many relationships. A junction object has two master-detail fields pointing to the two parent objects. The junction object inherits the sharing of the parent with the lower access — meaning if either parent is private, the junction record is only visible to users who can see both parents. This is a common source of hidden data access bugs.

---

### 1.6 Schema Design Trade-offs at Scale

**Normalize when:**
- Data integrity is critical (single source of truth)
- Record counts on the normalized entity are manageable (< 1M)
- Rollup queries are infrequent

**Denormalize (flatten) when:**
- Reporting performance is critical — SOQL across deep relationship chains is slow at LDV scale
- The data is read-heavy vs write-heavy
- Rollup Summary fields cannot be used (lookup relationships)
- List views and reports routinely time out due to cross-object formula fields

**LDV (Large Data Volume) schema rules:**
- Index fields used in WHERE clauses — only unique fields and fields declared as `externalId=true` are auto-indexed; custom fields require a manual index request to Salesforce support (or use a selective filter that qualifies for runtime indexing)
- Avoid cross-object formula fields in list view filters — each formula traverses the relationship at query time
- Consider a summary/denormalized field maintained by a trigger for frequently-queried rollup values (the pattern `AccountService.rollupOpportunityMetrics` in this repo uses `AggregateResult` to maintain a flat `TotalOpportunityValue__c` field on Account)


---

## Section 2 — Salesforce Admin (Deep)

### 2.1 Profiles vs Permission Sets vs Permission Set Groups

**Behavioral differences:**

| Feature | Profile | Permission Set | Permission Set Group |
|---|---|---|---|
| Assigned per user | Exactly one | Many | Many |
| Object CRUD | ✅ | ✅ | ✅ (aggregated) |
| Field-level security | ✅ | ✅ | ✅ |
| Tab visibility | ✅ | ✅ | ✅ |
| App assignment | ✅ (default app) | ❌ | ❌ |
| Login hours / IP ranges | ✅ | ❌ | ❌ |
| Page layout assignment | ✅ | ❌ | ❌ |
| Record type assignment | ✅ | ✅ | ✅ |
| Can be muted in a PSG | N/A | ✅ (via Muting PS) | N/A |

**Migration strategy — profile-centric to PSG-centric org:**

Phase 1 — Audit: Export all profile permissions with Metadata API. Map each unique permission combination to a persona (e.g., "Service Agent", "Field Tech", "Finance Reviewer").

Phase 2 — Build Permission Sets: Create one PS per capability cluster (e.g., "Case Management Full Access", "Account Read Only", "Knowledge Edit"). Keep them narrow and reusable.

Phase 3 — Build PSGs: Group PSs into PSGs matching each persona. Test with a user in a sandbox — assign PSG, validate access matches the old profile.

Phase 4 — Minimum Profile: Reduce all profiles to "Minimum Access — Salesforce" (system permissions only, no object access). All object/field access comes exclusively from PSGs.

Phase 5 — Rollout: Assign PSGs to users, validate, remove object permissions from profiles.

**What breaks during migration:**
- Page layout assignments remain on profiles — you must keep at least one profile with page layout assignments or migrate to Dynamic Forms
- Login hours and IP ranges are profile-only — must stay on profiles
- Record type assignments can be on both profiles and permission sets; duplicates are additive (user sees all assigned record types)
- Report and dashboard folder visibility is role-based, not profile-based — no impact

---

### 2.2 Role Hierarchy and Record Visibility

Role hierarchy grants **upward visibility** — a user in a higher role can see records owned by users in lower roles, *if* the OWD is Private or Public Read Only. With OWD = Public Read/Write, role hierarchy is irrelevant for sharing (but still affects report rollups).

**Common mistake:** Elevating a user's role to give them access to a specific set of records. This opens access to ALL records owned by everyone below them in the hierarchy — far broader than intended. The correct fix is a Sharing Rule or manual share.

**Impact on report visibility:** Reports show only records the running user can see (respecting role hierarchy, sharing rules, and OWD). Dashboards run as the "running user" — if the dashboard running user is a System Admin, all viewers see all data regardless of their own access. This is a common data leakage vector.

---

### 2.3 Security Layers — Complete Chain

```
1. OWD (Org-Wide Default)       — sets the floor: what a user sees with NO other access
2. Role Hierarchy               — adds upward visibility for records owned below the user
3. Sharing Rules (criteria/owner) — opens access to groups of records based on criteria
4. Manual Sharing               — individual user grants share on a specific record
5. Apex Managed Sharing         — programmatic share with custom RowCause
6. Field-Level Security (FLS)   — controls read/edit access to specific fields
7. CRUD (Object permissions)    — controls whether the user can read/create/edit/delete at all
```

**Which layer wins when they conflict:**
- CRUD is a gate — if a user lacks Read on Case, no sharing rule can grant access to Case records
- FLS is additive with profile + permission sets — if profile says field is read-only but a PS says editable, editable wins
- OWD is the floor — sharing rules, manual sharing, and role hierarchy can only *expand* access, never restrict below OWD
- Exception: Teams (Account Teams, Opportunity Teams) can grant access *below* the OWD minimum for a specific record

---

### 2.4 Validation Rules

Validation rules fire at step 4 of the Order of Execution (system validation). They are evaluated by the formula engine — meaning they have access to cross-object formulas (e.g., `Account.BillingCountry`), but with limitations:

**Cross-object formula limitations in validation rules:**
- Maximum of 10 hops across relationships
- Cannot reference fields on polymorphic lookup targets (e.g., `Task.What.Name` fails if What can be multiple types)
- No DML, no Apex callouts — pure formula evaluation

**When to push validation to Apex instead:**
- Validation depends on data not reachable by a cross-object formula (e.g., checking aggregate of child records)
- Validation needs to run in an integration/API context where the validation rule fires but the error message must be machine-readable (Apex can return structured errors)
- Validation involves complex multi-field conditions that produce unmaintainable validation rule formulas
- Validation must be skipped in specific integration scenarios (a bypass Custom Metadata + Apex check is cleaner than a formula bypass field)

**Real example:**
```apex
// Validation rule cannot check: "Case cannot be closed if there are open child Tasks"
// → Push to before trigger in CaseTriggerHandler
if (Trigger.isUpdate) {
    Set<Id> closingCaseIds = new Set<Id>();
    for (Case c : (List<Case>) Trigger.new) {
        Case old = (Case) Trigger.oldMap.get(c.Id);
        if (c.Status == 'Closed' && old.Status != 'Closed') closingCaseIds.add(c.Id);
    }
    if (!closingCaseIds.isEmpty()) {
        Map<Id, Integer> openTaskCount = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT WhatId, COUNT(Id) cnt FROM Task
            WHERE WhatId IN :closingCaseIds AND IsClosed = false GROUP BY WhatId
        ]) {
            openTaskCount.put((Id) ar.get('WhatId'), (Integer) ar.get('cnt'));
        }
        for (Case c : (List<Case>) Trigger.new) {
            if (openTaskCount.containsKey(c.Id) && openTaskCount.get(c.Id) > 0) {
                c.addError('Cannot close case with ' + openTaskCount.get(c.Id) + ' open tasks.');
            }
        }
    }
}
```

---

### 2.5 Formula Fields

Formula fields are computed at read time — they are not stored in the database (with the exception of cross-object formula fields which may be cached for performance). This means:

- **No DML, no Apex logic** — formulas are pure expressions
- **Reporting limitation:** Formula fields that reference parent fields can cause slow reports because the relationship must be traversed for every row at report run time
- **Rollup interaction:** Rollup Summary fields on master-detail relationships cannot roll up formula fields — you must persist the value first (use a workflow/flow to copy the formula result to a text field, then roll up the text field — though this introduces a sync dependency)

**Cross-object formula depth limit:** 5 levels of relationship traversal (e.g., `Opportunity.Account.Parent.Owner.Name` traverses 4 levels — approaches the limit).

---

### 2.6 Rollup Summary Fields

Master-detail only. Supports COUNT, SUM, MIN, MAX on a child field.

**Workaround for lookup rollups (the pattern this repo uses):**
The `AccountService.cls` implements `rollupOpportunityMetrics()` using `AggregateResult`:
```apex
for (AggregateResult ar : [
    SELECT AccountId, COUNT(Id) oppCount, SUM(Amount) totalAmt,
           AVG(Amount) avgAmt, MAX(CloseDate) latestClose
    FROM Opportunity
    WHERE AccountId IN :accountIds AND IsWon = true
    GROUP BY AccountId
]) {
    Account acc = new Account(Id = (Id) ar.get('AccountId'));
    acc.WonOpportunityCount__c  = (Integer) ar.get('oppCount');
    acc.TotalWonRevenue__c      = (Decimal) ar.get('totalAmt');
}
```

**Performance implications of large rollup recalculations:**
When a large number of child records are updated in bulk (e.g., a data migration updating 500K Opportunity records), Salesforce queues rollup recalculations. This can lock parent records (Account rows) for extended periods. For LDV orgs, consider deferring rollup updates by using a nightly batch rather than real-time rollup fields.

---

### 2.7 Duplicate Rules and Matching Rules

**Configuration approach:**
1. Matching Rule: defines the algorithm for detecting duplicates (exact, fuzzy, phone normalized). Runs before the Duplicate Rule evaluates
2. Duplicate Rule: determines what to *do* when the Matching Rule finds a duplicate (Block, Allow with Alert, Report)

**Matching Rule limitations:**
- Fuzzy matching only available for Name fields on standard objects
- Cross-object matching (e.g., "is this Lead a duplicate of any Contact?") is supported but slow at scale
- Matching Rules cannot be invoked programmatically — they fire on save via the platform

**When to build custom Apex deduplication:**
- Integration payloads arrive via REST and must be deduplicated before DML (matching rules don't fire on `Database.insert` from unmanaged code in some contexts)
- The deduplication logic involves fields not in the Matching Rule configuration (e.g., custom external ID from a source system)
- Deduplication must happen across objects that Salesforce doesn't support in OOTB matching rules
- See `MockInterviewApexService.blockDuplicateContacts()` in this repo for the Map-based pattern

---

### 2.8 Record Types

Record types affect: picklist values available on a record, page layout assigned, assignment rule handling.

**Common mistake — using record types where a field would suffice:**
If the only behavioral difference between "Customer Account" and "Partner Account" is which picklist values are visible on one field, a record type is overkill. Record types multiply the configuration surface: every permission set must have record type assignments, every page layout must be associated, every validation rule may need record type conditions.

Use record types when: page layout is genuinely different, business process (support routing, approval routing) differs by type, or picklist values differ substantially across multiple fields.

---

### 2.9 Page Layouts vs Dynamic Forms

| Feature | Page Layouts | Dynamic Forms |
|---|---|---|
| Field visibility rules | No (show all or hide via profile) | Yes (conditional visibility per component) |
| Component-level conditional | No | Yes |
| Requires Lightning Experience | No | Yes |
| Supported objects | All | Custom objects + limited standard objects |
| Page Layout Assignment | Via profile | Not applicable (LWC component decides) |

**Dynamic Forms limitation (as of 2025):** Not yet fully supported on all standard objects (Lead, Case, Contact, Account support varies by release). Always check the current release notes — Salesforce expands support each release.

---

### 2.10 Data Management

**Data Loader vs Import Wizard decision matrix:**

| Factor | Use Import Wizard | Use Data Loader |
|---|---|---|
| Record count | < 50,000 | > 50,000 |
| Object type | Leads, Contacts, Accounts, Solutions | Any sObject |
| Automation bypass needed | No | Yes (can use Bulk API to bypass triggers) |
| Upsert by external ID | Limited | Full support |
| Scheduled/automated | No | Yes (via CLI) |
| Error handling | Basic | Full error log |

**External IDs for migration:**
Every migrated object should have a `Legacy_ID__c` external ID field. This enables:
- Upsert (create if not exists, update if exists) during incremental loads
- Relationship resolution in child object loads (reference parent by external ID instead of Salesforce ID)
- Reconciliation post-migration: compare source count to Salesforce count by external ID

**Post-migration reconciliation:**
```sql
-- In source system: COUNT(*) WHERE migrated = true
-- In Salesforce SOQL: SELECT COUNT() FROM Account WHERE LegacyId__c != null
-- Diff by external ID to find missing or duplicated records
```

---

### 2.11 AppExchange Risk Evaluation

Before installing a managed package:

1. **Namespace**: The namespace prefix is permanent — field names like `pkg__CustomField__c` appear in all SOQL, reports, and Apex forever. Evaluate if the namespace is acceptable in your codebase
2. **Governor limit consumption**: Managed package triggers and flows consume the *same* governor limits as your code. A badly written managed package can cause your code to hit limits
3. **Upgrade risk**: Managed packages cannot be removed without deleting all their data. Test upgrades in sandbox before production
4. **Support model**: Is the ISV Salesforce-native (responsive to Salesforce releases) or slow to patch? A package that breaks on every major Salesforce release is a liability
5. **Data access**: Review what objects/fields the package accesses — some packages request broad access for telemetry
6. **Unmanaged package risk**: Unmanaged packages are fully readable source code that becomes yours to maintain — no upgrade path, no support


---

## Section 3 — Flows (Critical — Same Depth as Apex)

### 3.1 Flow Types — Decision Matrix

| Flow Type | Trigger | User Interaction | Can Query/DML | Can Callout | Key Limitation |
|---|---|---|---|---|---|
| Record-Triggered (Before Save) | Record save, before commit | No | Read only (no DML) | No | Cannot create/update other records |
| Record-Triggered (After Save) | Record save, after commit | No | Yes | No (sync context) | Callouts require Apex action |
| Screen Flow | User clicks launch button / tab | Yes | Yes | Via Apex action | Must be launched by a user |
| Auto-launched (No Trigger) | Apex, Process Builder, REST API | No | Yes | Via Apex action | Cannot be directly scheduled |
| Schedule-Triggered | Cron schedule on a batch of records | No | Yes | Via Apex action | Processes records in batches; no single-record context |
| Platform Event-Triggered | Platform Event published | No | Yes | Via Apex action | At-least-once delivery; must be idempotent |

**Decision rule:** Default to Record-Triggered before-save for pure field updates. Use after-save when related records need creating. Use Apex when callouts, complex logic, or performance requirements exceed declarative capabilities.

---

### 3.2 Before-Save vs After-Save

**Before-save advantages:**
- Executes in the same transaction as the save — no additional DML call
- Can set field values on the triggering record without an explicit DML statement (the update is implicit)
- Consumes fewer governor limits — no extra DML count, no extra trigger re-entry
- Faster: Salesforce internal benchmarks show before-save flows are ~10x faster than equivalent after-save flows

**What is ONLY possible in after-save:**
- Creating or updating *other* records (Contacts, Cases, Tasks related to the saved record)
- Calling subflows that perform DML on related records
- Sending emails that reference the newly-created record ID (for insert scenarios — ID doesn't exist in before-save on insert)
- Publishing Platform Events

**Governor limit sharing:**
Before-save flows share limits with the trigger transaction. After-save flows run in a new "system" context but still consume from the same transaction's SOQL and DML allocations. This means a heavy before-save flow + a heavy after-save flow + an Apex trigger on the same object can collectively exhaust the 100-SOQL limit even though each piece looks fine in isolation.

---

### 3.3 Flow vs Apex Decision Matrix

| Scenario | Use Flow | Use Apex | Reason |
|---|---|---|---|
| Field update on same record based on field value | Before-save Flow ✅ | Overkill | Faster, no DML, admin-maintainable |
| Create related record on Case close | After-save Flow ✅ | Overkill | Declarative, admin-adjustable |
| Send HTTP callout to external system | ❌ | Apex Queueable ✅ | Flows cannot make direct HTTP callouts |
| Process 200 records in bulk efficiently | Flow (bulkified internally) ✅ | Only if complex | Flows bulk-process record-triggered batches |
| Complex multi-object rollup calculation | ❌ | Apex + AggregateResult ✅ | Formula limits exceeded |
| User-facing guided process with screens | Screen Flow ✅ | Full-page LWC (expensive) | Flow screens are cheaper to build |
| Nightly data sync of 2M records | ❌ | Batch Apex ✅ | Schedule-triggered flows batch poorly at this scale |
| CPQ pricing logic with branching | ❌ | Apex QuoteCalculatorPlugin ✅ | CPQ plugin interface required |

---

### 3.4 Bulkification in Flows

Salesforce internally batches record-triggered flows: when a bulk DML operation updates 200 records, the flow runs against all 200 in a single "interview" where the triggering record collection is the full batch. The flow engine bulkifies Get Records and DML actions automatically.

**Where bulkification breaks:**

```
❌ Anti-pattern: Get Records INSIDE a loop
Loop (iterating triggering record collection):
  → Get Records: SELECT Id FROM Contact WHERE AccountId = {currentRecord.Id}
  → This fires one SOQL per loop iteration → SOQL limit at 101 records
```

```
✅ Correct: Get Records OUTSIDE the loop
Get Records: SELECT Id, AccountId FROM Contact WHERE AccountId IN {recordIds collection}
Loop (iterating result collection):
  → Process each contact
```

**Collection updates must be placed correctly:**
Updating a collection variable inside a loop and then calling Update Records inside the same loop fires one DML per iteration. Accumulate all updates in the collection inside the loop, then call Update Records once *outside* the loop.

---

### 3.5 Fault Handling

Every Flow path that performs DML or calls an external action must have a fault path. Without a fault path, a flow failure in a record-triggered context rolls back the entire transaction silently — the record is not saved, and the user sees a generic error with no useful context.

**Production fault path pattern:**
```
On Fault → 
  Create Record: Error_Log__c (
      Flow_Name__c = {$Flow.CurrentFlowInterviewGuid},
      Error_Message__c = {$Flow.FaultMessage},
      Record_Id__c = {triggering record Id},
      Occurred_At__c = {$Flow.CurrentDateTime}
  )
  Send Email: Platform Ops alert (error details in body)
  → (terminate gracefully)
```

**What happens with no fault path in production:**
- Record-triggered flow failure → record save rolls back → user sees "An unexpected error has occurred" with no actionable detail
- Platform Event-triggered flow failure → event is retried; if failure is systematic, the subscriber's `LastError` field fills up and the subscriber is suspended
- Scheduled flow failure → batch fails silently; no email unless Flow Error Email setting is configured in Setup

---

### 3.6 Subflows and Modularization

**When to decompose into subflows:**
- A flow grows beyond 30 elements (maintenance becomes difficult)
- The same logic (e.g., "Create Follow-up Task") is needed in multiple parent flows
- Version management — a subflow can be updated independently and parent flows reference the active version

**Passing record collections between flows:**
Parent flow variable type `Record Collection (Account)` → Subflow input variable must be the same SObject type. Primitive collections (Text Collection, Number Collection) pass cleanly. Avoid passing generic SObject collections — type safety prevents runtime errors.

**Version management risk:**
If a subflow is deactivated (e.g., during a release), any parent flow referencing it will fail at runtime with "Subflow not found." Always test subflow version dependencies before deactivating old versions.

---

### 3.7 Invocable Apex in Flows

`@InvocableMethod` is the bridge between Flow's declarative engine and Apex logic. It is also the mechanism for Agentforce Agent Actions (Section 15).

**Design rules for InvocableMethod:**
```apex
@InvocableMethod(label='Calculate Risk Score' description='...' category='Risk Management')
public static List<RiskOutput> calculateRisk(List<RiskInput> inputs) {
    // Must accept List<Input> — this IS the bulk-safe signature
    // Must return List<Output>
    // Do NOT return a single object — Flow expects a list
    // Do NOT do DML inside; let the Flow handle DML with the output
}
```

**Why `List<List<T>>` appears in some implementations:**
When a Flow calls an Apex action in a loop, each invocation passes a `List` of one element. The outer list is the number of concurrent invocations. For bulk-safety in nested loops, `List<List<T>>` lets you receive all loop iterations in one call — but this is rarely needed in practice; standard `List<T>` is bulk-safe for record-triggered contexts.

---

### 3.8 Flow Debugging

- **Debug as another user:** Run → Debug → "Run as" lets you simulate a different user's context — critical for testing FLS in flows
- **Flow interview logs:** Show each element execution, variable values, and the fault message. Access in Setup → Debug Logs, filter by Flow interviews
- **Common failure points:**
  - `NullPointerException` when a Get Records returns no records and the next element tries to access a field on the null variable — add a decision element checking `Is Null`
  - Permission error on Get Records — the running user lacks Read on the queried object — add system context or use "Run in System Context Without Sharing"
  - CPU timeout — a flow with nested loops processing 200 records; profile with Flow debug log to find the expensive element

---

### 3.9 Migration Patterns

**Workflow Rule to Flow:**
1. Document all workflow rules (field updates, email alerts, tasks, outbound messages)
2. Recreate each as a before-save flow (field updates) or after-save flow (emails, tasks)
3. Outbound messages → replace with Platform Event published from flow + external subscriber
4. Test by running the trigger condition in sandbox and verifying all field updates
5. Deactivate workflow rules only after flow is live and validated

**Process Builder to Flow:**
Process Builder is deprecated (Salesforce plans to retire it). Conversion steps:
1. Export Process Builder visual representation via Setup
2. Recreate trigger condition in Flow with equivalent entry criteria
3. Map each "Immediate Action" group to either before-save (field updates) or after-save (create records, email) elements
4. Scheduled actions in PB → use Scheduled Paths in Record-Triggered Flow

---

### 3.10 Flow Anti-Patterns

| Anti-Pattern | Production Consequence | Correct Approach |
|---|---|---|
| Hardcoded Record IDs | Flow breaks when data is refreshed to sandbox; fails on migration | Store IDs in Custom Metadata; reference via Get Records |
| Missing fault paths | Silent record save failures; users see generic error | Every DML/callout path must have an explicit Fault connector |
| Get Records inside loops | SOQL limit at 101 records in bulk context | Move Get Records outside loop; filter by collection |
| DML inside loops | DML limit at 151 operations in bulk context | Accumulate collection, call Update/Create once outside loop |
| After-save flow updating same record | Triggers re-entry of the trigger → recursion → CPU timeout | Use before-save flow for same-record field updates |
| After-save where before-save suffices | Double transaction cost; extra DML count consumed | Evaluate if the field update needs the record ID or related data |
| Screen flow without input validation | Invalid data submitted; downstream failures are opaque | Validate all user inputs before the first DML element |


---

## Section 4 — Apex Deep Dive

### 4.1 Trigger Framework

**The anti-pattern — logic directly in trigger:**
```apex
// ❌ NEVER DO THIS
trigger AccountTrigger on Account (before insert, before update) {
    for (Account acc : Trigger.new) {
        if (acc.Type == 'Customer') {
            // Business logic embedded in trigger
            // Cannot be unit-tested in isolation
            // Cannot be bypassed for data migration
            // Cannot be extended without editing the trigger file
        }
    }
}
```

**The pattern this repo uses — TriggerHandler → AccountTriggerHandler → AccountService:**

```
AccountTrigger (1 line: new AccountTriggerHandler().run())
  ↓
TriggerHandler (abstract base)
  - bypassSet (Set<String>) — static, persists in transaction
  - loopCountMap (Map<String, LoopCount>) — depth guard
  - run() — routes to virtual before/after methods
  - static bypass(String name) — called from test or migration script
  - static isBypassed(String name) — checked at start of run()
  ↓
AccountTriggerHandler (concrete handler, extends TriggerHandler)
  - beforeInsert() — calls AccountService.applyDefaults()
  - afterInsert() — calls AccountService.createFollowUpTasks()
  - beforeUpdate() — calls AccountDomain.validateRatingChange()
  ↓
AccountService (business logic — no Trigger context references)
  - Receives List<Account> / Map<Id, Account> as parameters
  - All SOQL encapsulated here
  - Returns void or a result DTO
  ↓
AccountDomain (domain rules — pure validation, no DML)
  - validateRatingChange(): enforces Customer→Prospect downgrade guard
  - No SOQL, no DML — only field-level rules applied to in-memory objects
```

**CMDT bypass registry (TriggerHandler.cls pattern):**
```apex
// In Custom Metadata Type: TriggerSetting__mdt with fields:
//   Handler_Name__c (text), Bypass__c (checkbox)

// In TriggerHandler.run():
private static Map<String, TriggerSetting__mdt> settings; // static cache
private static Map<String, TriggerSetting__mdt> getSettings() {
    if (settings == null) {
        settings = new Map<String, TriggerSetting__mdt>();
        for (TriggerSetting__mdt s : TriggerSetting__mdt.getAll().values()) {
            settings.put(s.Handler_Name__c, s);
        }
    }
    return settings;
}

public static Boolean isBypassed(String handlerName) {
    TriggerSetting__mdt s = getSettings().get(handlerName);
    return s != null && s.Bypass__c;
}
```

This lets admins toggle bypass in a deployed CMDT record without a code deployment — critical for data migrations and emergency hotfixes.

---

### 4.2 Bulkification

**The anti-pattern:**
```apex
// ❌ Fires one SOQL per Account in the trigger
trigger AccountTrigger on Account (after insert) {
    for (Account acc : Trigger.new) {
        Contact c = [SELECT Id FROM Contact WHERE AccountId = :acc.Id LIMIT 1];
        // System.LimitException: Too many SOQL queries: 101 — at 101 accounts
    }
}
```

**The correct Map-based approach:**
```apex
// ✅ Pattern from AccountService.syncBillingToChildContacts()
public static void syncBillingToChildContacts(List<Account> accounts) {
    Set<Id> accountIds = new Set<Id>();
    for (Account a : accounts) accountIds.add(a.Id);

    // ONE query regardless of list size
    Map<Id, List<Contact>> contactsByAccount = new Map<Id, List<Contact>>();
    for (Contact c : [SELECT Id, AccountId, MailingStreet FROM Contact
                      WHERE AccountId IN :accountIds]) {
        if (!contactsByAccount.containsKey(c.AccountId))
            contactsByAccount.put(c.AccountId, new List<Contact>());
        contactsByAccount.get(c.AccountId).add(c);
    }

    List<Contact> toUpdate = new List<Contact>();
    for (Account a : accounts) {
        List<Contact> contacts = contactsByAccount.get(a.Id);
        if (contacts == null) continue;
        for (Contact c : contacts) {
            c.MailingStreet  = a.BillingStreet;
            c.MailingCity    = a.BillingCity;
            toUpdate.add(c);
        }
    }
    if (!toUpdate.isEmpty()) Database.update(toUpdate, false); // partial DML
}
```

**Why 200 records is the minimum design target:**
Salesforce batches DML in chunks of up to 200 records. A trigger that processes records in a loop without bulkification fails when the first chunk of 200 is processed — not at 1 record. Testing with single records gives false confidence.

---

### 4.3 Exception Handling

**try/catch placement — where it belongs:**
```apex
// ✅ In service layer — catch, log, and surface meaningfully
public static void applyDefaults(List<Account> accounts) {
    try {
        List<Account> toUpdate = buildUpdates(accounts);
        Database.SaveResult[] results = Database.update(toUpdate, false); // allOrNone=false
        logSaveErrors(results, toUpdate); // AccountService.logSaveErrors pattern
    } catch (DmlException e) {
        // Unexpected — allOrNone=true would throw; allOrNone=false should not
        // Log and rethrow so caller knows something failed
        AccountService.logException(e);
        throw new AccountServiceException('Unexpected DML failure: ' + e.getMessage());
    }
}
```

**Database.SaveResult checking (pattern from AccountService.logSaveErrors):**
```apex
private static void logSaveErrors(Database.SaveResult[] results, List<Account> records) {
    for (Integer i = 0; i < results.size(); i++) {
        if (!results[i].isSuccess()) {
            String errors = '';
            for (Database.Error err : results[i].getErrors()) {
                errors += err.getStatusCode() + ': ' + err.getMessage() + '; ';
            }
            // Create Error_Log__c record or publish Platform Event for ops visibility
            insert new Error_Log__c(
                Record_Id__c = records[i].Id,
                Error_Message__c = errors,
                Context__c = 'AccountService.applyDefaults'
            );
        }
    }
}
```

**allOrNone vs partial DML:**
- `Database.insert(list, true)` — allOrNone: one failure rolls back ALL. Use when atomicity is required (financial transactions, multi-object saga)
- `Database.insert(list, false)` — partial: successful records commit, failures return in SaveResult. Use in batch jobs and data migrations where partial success is acceptable

**When to swallow exceptions vs surface them:**
- Swallow: graceful degradation for non-critical functionality (e.g., enrichment callout failed — proceed without enrichment, log the failure)
- Surface: business-critical operations where partial failure must be visible to the user or ops team

---

### 4.4 Transaction Boundaries

**What commits when:**
- All DML in a synchronous transaction (trigger + flow + called Apex) commits atomically at step 17 of the Order of Execution
- If any unhandled exception occurs anywhere in the transaction, ALL DML rolls back — including DML that completed before the exception
- Platform Events published via `EventBus.publish()` are only actually published after the transaction commits — if the transaction rolls back, the event is not published

**Savepoints:**
```apex
Savepoint sp = Database.setSavepoint();
try {
    insert orderHeader;
    insert orderLines; // if this fails
    Database.releaseSavepoint(sp);
} catch (Exception e) {
    Database.rollback(sp); // orderHeader insert is also rolled back
    throw e;
}
```

Savepoints cannot cross async boundaries — you cannot roll back a `@future` method from a synchronous catch block.

---

### 4.5 Static Variable Behavior

Static variables persist for the lifetime of a **transaction** — not the lifetime of the Apex class file, not between requests, not between test methods.

**Practical implications:**
- A static `Set<Id> processedIds` in a trigger handler guards against recursion within the same transaction — once a record ID is in the set, the trigger skips it on re-entry
- `AccountService.getRatingConfigs()` uses a static `Map<String, AccountRating__mdt>` cache — the first call queries CMDT, subsequent calls within the same transaction return the cached map with zero additional SOQL
- Between test methods (`@IsTest` annotated methods in the same class), static variables are reset — each test method starts with a clean static state

**The cache pattern:**
```apex
private static Map<String, AccountRating__mdt> ratingConfigCache;
public static Map<String, AccountRating__mdt> getRatingConfigs() {
    if (ratingConfigCache == null) {
        ratingConfigCache = new Map<String, AccountRating__mdt>();
        for (AccountRating__mdt cfg : AccountRating__mdt.getAll().values()) {
            ratingConfigCache.put(cfg.Tier__c, cfg);
        }
    }
    return ratingConfigCache;
}
```

---

### 4.6 Apex Managed Sharing

Apex managed sharing lets you programmatically grant record access beyond what OWD + role hierarchy + sharing rules provide.

```apex
// Grant 'Edit' access on a Case to a specific user
Case_Share share = new Case_Share();
share.CaseId        = caseId;
share.UserOrGroupId = userId;
share.CaseAccessLevel = 'Edit';
share.RowCause      = Schema.Case_Share.RowCause.Manual; // or a custom row cause
insert share;
```

**Custom RowCause:** Register a custom Apex Sharing Reason in Setup. This lets you create/delete shares with a specific cause without affecting shares with other causes (e.g., delete all "ServiceTeam__c" shares and replace with new ones without touching "Manual" shares).

**When `without sharing` is legitimate:**
- System processes (nightly batch running as a system user that needs to read all records)
- Post-insert operations that must access records the current user cannot see (e.g., after inserting a Case, immediately reading back related Entitlement data)

**When `without sharing` is a security hole:**
- In an Experience Cloud (portal) Apex controller — guest users running `without sharing` can access any record. All portal controllers must be `with sharing` unless a specific reviewed exception is documented.


---

## Section 5 — Async Apex

### 5.1 Decision Table

| Feature | @future | Queueable | Batch | Scheduled |
|---|---|---|---|---|
| HTTP callouts | ✅ (with callout=true) | ✅ | ✅ | ✅ |
| Chaining | ❌ | ✅ (1 child per job) | ❌ | ❌ |
| State across chunks | N/A | ✅ (instance vars) | ✅ (Database.Stateful) | N/A |
| Can be monitored | Via AsyncApexJob | Via AsyncApexJob | Via AsyncApexJob + FlexQueue | Via CronTrigger |
| Start delay | Short (queued) | Short | Configurable (start time) | Cron schedule |
| Max active per org | 50 per transaction | 50 enqueued | 5 concurrent | 100 scheduled |
| CPU time limit | 60,000 ms | 60,000 ms | 60,000 ms (per execute) | 60,000 ms |
| Heap | 12 MB | 12 MB | 12 MB | 12 MB |
| Enqueue from Batch | ❌ | ✅ (1 per execute) | ❌ (from finish only) | ✅ |
| Can pass sObjects | ❌ (primitives only) | ✅ | ✅ | ✅ |
| Best for | Fire-and-forget callouts | Chained processing, stateful callouts | Large data volumes | Recurring jobs |

---

### 5.2 Queueable Chaining

Pattern from `AccountSyncQueueable.cls`:
```apex
public class AccountSyncQueueable implements Queueable, Database.AllowsCallouts {
    private final List<Id> accountIds;
    private final Integer offset;
    private static final Integer CHUNK = 50;

    public AccountSyncQueueable(List<Id> ids, Integer offset) {
        this.accountIds = ids;
        this.offset     = offset;
    }

    public void execute(QueueableContext ctx) {
        Integer end  = Math.min(offset + CHUNK, accountIds.size());
        List<Id> chunk = new List<Id>(accountIds).subList(offset, end);

        // Process chunk — make callout, upsert results
        processChunk(chunk);

        // Chain to next chunk if more remain
        if (end < accountIds.size() && Limits.getQueueableJobs() < 1) {
            System.enqueueJob(new AccountSyncQueueable(accountIds, end));
        }
    }
}
```

**Max chain depth:**
- Synchronous context: can enqueue up to 50 jobs
- From a Queueable execute: can only enqueue **1** child job (chain depth = 1 per step)
- No hard limit on chain length, but Salesforce monitors for infinite chains and may terminate

**Cursor-based pagination alternative (for very large datasets):**
Instead of passing all IDs upfront (heap risk), pass a `lastId` cursor:
```apex
List<Account> page = [SELECT Id FROM Account WHERE Id > :lastId ORDER BY Id ASC LIMIT 50];
if (!page.isEmpty()) {
    System.enqueueJob(new AccountSyncQueueable(page[page.size()-1].Id));
}
```

---

### 5.3 Stateful Batch

Pattern from `OpportunityRollupBatch.cls`:
```apex
public class OpportunityRollupBatch
    implements Database.Batchable<SObject>, Database.Stateful {

    // ⚠️ Stateful: these instance variables persist across ALL execute() calls
    public Integer totalProcessed = 0;
    public Integer totalErrors    = 0;
    public List<String> errorLog  = new List<String>(); // watch heap at scale

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, AccountId, Amount, IsWon FROM Opportunity
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        // Process scope — each execute() gets a fresh transaction
        // but instance vars carry over
        totalProcessed += scope.size();
    }

    public void finish(Database.BatchableContext bc) {
        // Send summary email using totalProcessed and totalErrors
    }
}
```

**What `Database.Stateful` preserves:** instance variables (fields on the class).
**What it costs:** The entire class is serialized between `execute()` calls. Large `List<String> errorLog` or complex object graphs can cause heap overflow. Keep stateful data minimal — store IDs or counts, not full SObject lists.

---

### 5.4 Batch Scope Sizing

| Scope | Transactions | SOQL per transaction | CPU per transaction | Risk |
|---|---|---|---|---|
| 1 | 10M transactions for 10M records | 200 per tx (low per-tx usage) | Very low | Rate throttling |
| 200 | 50K transactions for 10M records | 200 per tx | Moderate | Safe default |
| 2000 | 5K transactions for 10M records | 200 per tx | High — risk CPU timeout | Only if simple logic |

**Rule of thumb:** Default to 200. Only increase scope if the execute() body is simple (pure field updates, no nested SOQL) and you want to reduce number of transactions for performance. Never exceed 2000 — Salesforce caps scope at 2000 even if you specify higher.

**Scope interaction with SOQL in execute():**
```apex
// With scope=200: each execute() gets 200 Opportunities
// This query is fine: 200 AccountIds in a Set query
List<Account> accounts = [SELECT Id FROM Account WHERE Id IN :accountIds];
// 1 SOQL per execute() — well within the 200 limit

// With scope=2000: 2000 Opportunities
// Same query — still 1 SOQL, but CPU for processing 2000 records may breach 60s
```

---

### 5.5 Monitoring Async Jobs

```apex
// Query AsyncApexJob for status
AsyncApexJob job = [
    SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, ExtendedStatus
    FROM AsyncApexJob WHERE Id = :jobId
];
// Status: Queued, Holding, Preparing, Processing, Aborted, Completed, Failed

// Monitor Queueable specifically
AsyncApexJob q = [
    SELECT Status, ExtendedStatus FROM AsyncApexJob
    WHERE JobType = 'Queueable' ORDER BY CreatedDate DESC LIMIT 10
];

// CronTrigger for scheduled jobs
CronTrigger ct = [
    SELECT CronJobDetail.Name, State, NextFireTime, PreviousFireTime
    FROM CronTrigger WHERE Id = :cronJobId
];
```

**FlexQueue:** When more than 5 batch jobs are active, additional batches are "Holding" in the FlexQueue. FlexQueue supports reordering via `System.FlexQueue.moveJobToFront(jobId)` — useful for prioritizing time-sensitive jobs.

---

### 5.6 Error Handling Across the Async Boundary

There is no try/catch that spans an async boundary. If a `@future` method throws an unhandled exception:
- The async transaction rolls back
- The error is logged to `AsyncApexJob.ExtendedStatus`
- The calling synchronous transaction has already committed and cannot be rolled back

**Pattern for surfacing async failures:**
```apex
public void execute(QueueableContext ctx) {
    try {
        doWork();
    } catch (Exception e) {
        // Publish a Platform Event — visible immediately via streaming
        insert new Async_Error_Event__e(
            Message__c = e.getMessage(),
            Stack__c   = e.getStackTraceString(),
            Job_Id__c  = ctx.getJobId()
        );
        // OR: create an Error_Log__c record
        // Do NOT rethrow unless you want the job to retry
    }
}
```


---

## Section 6 — SOQL and Performance

### 6.1 Selectivity Rules

Salesforce's query optimizer uses indexes to avoid full table scans. A query is selective when its WHERE clause filters reduce the result set to a small percentage of total records.

**What is indexed automatically:**
- `Id` (primary key)
- Fields with `unique=true`
- Fields with `externalId=true`
- Standard indexed fields: `Name`, `OwnerId`, `CreatedDate`, `SystemModstamp`, `RecordTypeId`, `IsDeleted`, `IsClosed`

**Selectivity thresholds:**
- Selective: < 10% of total records OR < 333,333 records (whichever is smaller)
- A query on a non-indexed field against a 10M record object is a full table scan — runtime warning or timeout

**Custom indexes:**
Request via Salesforce Support for heavily-queried custom fields. Custom indexes on fields with many null values (e.g., a lookup that is null 60% of the time) are selective for NOT NULL queries but not for null queries.

---

### 6.2 Query Optimization

**Bad query — non-selective, no index:**
```soql
-- ❌ SOQL on non-indexed custom field against 10M records
SELECT Id, Name FROM Case WHERE Custom_Category__c = 'Billing' ORDER BY CreatedDate
```

**Optimized version:**
```soql
-- ✅ Leading with indexed field (Status is indexed on Case), scoped with date range
SELECT Id, Name, Custom_Category__c FROM Case
WHERE Status = 'Open'           -- indexed: dramatically reduces result set
  AND CreatedDate >= LAST_N_DAYS:30  -- indexed: further reduces
  AND Custom_Category__c = 'Billing' -- now filters a small set
ORDER BY CreatedDate DESC
LIMIT 200
```

**WHERE clause ordering:** Salesforce's query optimizer evaluates all predicates but will use the most selective index. Leading with an indexed field is good practice even if the optimizer reorders internally.

**Bind variables in Apex:** Always use bind variables (`:variableName`) not string concatenation. Bind variables are immune to SOQL injection and allow the query engine to reuse execution plans.

```apex
// ❌ String concatenation — injection risk, no plan reuse
String soql = 'SELECT Id FROM Account WHERE Name = \'' + userInput + '\'';

// ✅ Bind variable
String name = userInput;
List<Account> accs = [SELECT Id FROM Account WHERE Name = :name];
```

---

### 6.3 LDV Strategies for 10M+ Records

| Strategy | When to Use | Trade-offs |
|---|---|---|
| Custom indexes | High-traffic WHERE clause fields | Requires Salesforce support ticket; write overhead |
| Skinny tables | Frequently queried small field sets | Must be requested from Salesforce support; cannot include formula fields |
| Archiving | Records older than a threshold rarely accessed | Requires data archiving strategy (Salesforce Archiving or external store) |
| Date-range partitioning | Queries always include a date range filter | Depends on CreatedDate indexing; design schemas to include date in queries |
| External objects | Historical data in external system (e.g., S3 + OData connector) | Callout overhead; no SOQL aggregates; no triggers |

**Skinny tables:** Salesforce can create a "skinny table" — a narrow denormalized table containing only the most queried fields from a large sObject. Queries that only need those fields hit the skinny table instead of the full row, dramatically reducing I/O.

---

### 6.4 Query Plan Tool

Access: Developer Console → Query Editor → Query Plan button (click before running query).

Key outputs to understand:
- **Leading Operation Type: TableScan** — the query will scan every row. This is a performance problem for any object with > 100K records
- **Leading Operation Type: Index** — an index is being used; check the `cost` value (lower is better, 1.0 = estimated full table scan equivalent)
- **Relative Cost:** Values near or above 1.0 mean the optimizer considers the query expensive

---

### 6.5 SOSL

SOSL (Salesforce Object Search Language) searches the full-text search index — a separate index maintained by Salesforce that tokenizes and indexes string field values.

**When to use SOSL over SOQL:**
- You need to search across multiple objects in a single query
- You are implementing a search feature (user types a term, you return matching records)
- The search term is partial (SOSL handles partial matching via wildcards efficiently)

**SOSL syntax:**
```soql
FIND {acme*} IN ALL FIELDS
RETURNING Account(Id, Name), Contact(Id, FirstName, LastName), Case(Id, Subject)
LIMIT 20
```

**SOSL limitations:**
- No aggregate functions (COUNT, SUM)
- No relationship traversal in RETURNING clause
- Results are List<List<SObject>> — one inner list per returned object type
- Minimum 2 characters in search term (1-character searches fail)
- Does not search formula fields or long text area fields by default

---

### 6.6 SOQL Anti-Patterns

| Anti-Pattern | Risk | Fix |
|---|---|---|
| `SELECT * FROM Account` equivalent (all fields) | Heap overflow on large result sets; slow query | Select only needed fields |
| SOQL inside loops | SOQL limit at 101 queries | Move query outside loop; use Map pattern |
| Missing WHERE on large objects | Table scan → timeout | Always filter with selective indexed fields |
| OFFSET > 2000 | Hard platform limit — throws exception | Use cursor-based pagination (`WHERE Id > :lastId`) |
| Not checking `Limits.getQueries()` in recursive patterns | Governor limit breach in complex flows | Check `Limits.getQueries() < Limits.getLimitQueries() - 5` before querying |
| `ORDER BY` on non-indexed field with large result | Full sort of entire result set in memory | Use indexed sort fields or avoid sorting at database level |


---

## Section 7 — Apex Design Patterns

### 7.1 Separation of Concerns

The layered architecture used in this repo makes each layer independently testable, maintainable, and bypassable:

```
Trigger Layer (AccountTrigger)
  — One line: new AccountTriggerHandler().run()
  — NO logic, NO SOQL
  — Purpose: entry point only

Handler Layer (AccountTriggerHandler extends TriggerHandler)
  — Receives Trigger context (Trigger.new, Trigger.oldMap)
  — Routes to service methods with clean Apex collections
  — NO business rules, NO SOQL
  — Purpose: context translation

Service Layer (AccountService)
  — Accepts List<Account>, Map<Id, Account> — no Trigger context
  — Contains ALL SOQL for Account-related operations
  — Performs DML
  — Calls Domain for validation
  — Purpose: orchestration of business logic

Domain Layer (AccountDomain)
  — Pure in-memory validation against Apex collections
  — NO SOQL, NO DML — only field-level business rules
  — Purpose: enforce invariants (e.g., rating downgrade guard)
```

**What belongs where:**

| Layer | Has SOQL | Has DML | Knows about Trigger context | Testable without DML |
|---|---|---|---|---|
| Trigger | ❌ | ❌ | ✅ (reads Trigger.*) | N/A |
| Handler | ❌ | ❌ | ✅ | ✅ |
| Service | ✅ | ✅ | ❌ | Requires DML |
| Domain | ❌ | ❌ | ❌ | ✅ (pure method calls) |

---

### 7.2 Selector Layer

The Selector layer encapsulates all SOQL behind named methods. This provides two concrete benefits:

1. **Test mocking:** Override the selector with a mock implementation using `@TestVisible` static injection — no actual DML needed for query-heavy tests
2. **Query optimization:** All queries for an object live in one place — easy to add `WITH USER_MODE`, add indexes, or change field lists without hunting across the codebase

```apex
public with sharing class AccountSelector {
    // Single source of truth for all Account queries
    public static List<Account> getByIds(Set<Id> ids) {
        return [SELECT Id, Name, Rating, BillingCity, OwnerId
                FROM Account WHERE Id IN :ids WITH USER_MODE];
    }
    public static List<Account> getWithOpenOpportunities(Set<Id> ids) {
        return [SELECT Id, Name, (SELECT Id, Amount, StageName FROM Opportunities
                WHERE IsClosed = false)
                FROM Account WHERE Id IN :ids WITH USER_MODE];
    }
}
```

---

### 7.3 Factory Pattern

Use when you need to create SObjects or handler instances without coupling to a concrete type at compile time:

```apex
public class SObjectFactory {
    public static SObject create(String objectApiName, Map<String, Object> fieldValues) {
        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectApiName);
        if (sobjType == null) throw new IllegalArgumentException('Unknown: ' + objectApiName);
        SObject record = sobjType.newSObject();
        for (String field : fieldValues.keySet()) {
            record.put(field, fieldValues.get(field));
        }
        return record;
    }
}
```

Also used in `TestDataFactory.cls` — builder pattern for test data with sensible defaults and optional overrides.

---

### 7.4 Strategy Pattern

Replace if/else chains with polymorphic behavior:

```apex
// ❌ Growing if/else — adding a new tier requires modifying this method
public static Decimal calculateDiscount(String tier, Decimal amount) {
    if (tier == 'Gold') return amount * 0.2;
    else if (tier == 'Silver') return amount * 0.1;
    else if (tier == 'Bronze') return amount * 0.05;
    return 0;
}

// ✅ Strategy — adding a new tier requires only a new class
public interface DiscountStrategy {
    Decimal calculate(Decimal amount);
}
public class GoldDiscount implements DiscountStrategy {
    public Decimal calculate(Decimal amount) { return amount * 0.2; }
}
// Register strategies in Custom Metadata — select at runtime via Type.forName()
```

---

### 7.5 Unit of Work

Batch all DML into a single commit at the end of the operation — reduces DML statement count and ensures consistency:

```apex
public class UnitOfWork {
    private List<SObject> toInsert = new List<SObject>();
    private List<SObject> toUpdate = new List<SObject>();
    private List<SObject> toDelete = new List<SObject>();

    public void registerNew(SObject record) { toInsert.add(record); }
    public void registerDirty(SObject record) { toUpdate.add(record); }
    public void registerDeleted(SObject record) { toDelete.add(record); }

    public void commitWork() {
        Savepoint sp = Database.setSavepoint();
        try {
            insert toInsert;
            update toUpdate;
            delete toDelete;
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }
}
```

Benefit: one DML statement per object type regardless of how many service methods registered records.

---

### 7.6 Dependency Injection in Apex

Apex has no DI framework, but the principle is achievable via interface injection:

```apex
public interface EmailService { void sendAlert(String subject, String body); }
public class SalesforceEmailService implements EmailService {
    public void sendAlert(String s, String b) { /* real implementation */ }
}
public class MockEmailService implements EmailService {
    public List<String> sentSubjects = new List<String>();
    public void sendAlert(String s, String b) { sentSubjects.add(s); }
}

public class CaseEscalationService {
    @TestVisible static EmailService emailSvc = new SalesforceEmailService();
    public static void escalate(Case c) {
        emailSvc.sendAlert('Case Escalated', c.Id);
    }
}

// In test:
CaseEscalationService.emailSvc = new MockEmailService();
```

---

### 7.7 When NOT to Use Patterns

| Context | Anti-pattern | Why it hurts |
|---|---|---|
| < 500 LOC org, solo developer | Full 4-layer architecture | Overhead without benefit; every change requires 4 files |
| Time-boxed sprint deliverable | Unit of Work + Strategy pattern | Analysis paralysis; ship the feature |
| Simple field update trigger | TriggerHandler + Domain + Service | 20 lines of logic split across 4 files |
| Prototype / MVP phase | Full DI framework | Adds abstraction debt before requirements are stable |

**Rule:** Patterns solve real problems. Introduce a pattern when you feel the pain it solves — not preemptively.


---

## Section 8 — Testing Strategy

### 8.1 Test Class Structure

```apex
@IsTest
private class AccountServiceTest {
    // @TestSetup runs once before all test methods in the class
    // Use for expensive shared data (large record sets, complex hierarchies)
    // Drawback: cannot pass variables from @TestSetup to individual test methods
    //           (data must be re-queried in each test)
    @TestSetup
    static void setup() {
        TestDataFactory.createAccounts(200); // bulk-ready test data
    }

    // Individual test methods: isolated, focused on one behavior
    @IsTest
    static void applyDefaults_setsRatingForNewCustomer() {
        // Arrange
        Account acc = TestDataFactory.buildAccount('Test Corp', 'Customer');
        // Act
        Test.startTest();
        insert acc;
        Test.stopTest();
        // Assert
        Account result = [SELECT Rating FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Hot', result.Rating, 'New Customer should be rated Hot');
    }
}
```

**@TestSetup vs setup per method:**
- Use `@TestSetup` when: many test methods need the same baseline data (reduces total DML)
- Use per-method setup when: each test needs different data configurations (avoids pollution between tests)

---

### 8.2 TestDataFactory Pattern

`TestDataFactory.cls` in this repo uses a builder pattern:

```apex
public class TestDataFactory {
    // Sensible defaults — call build methods for quick setup
    public static Account buildAccount(String name, String type) {
        return new Account(
            Name             = name,
            Type             = type,
            BillingCity      = 'San Francisco',
            BillingCountry   = 'US',
            AnnualRevenue    = 100000
        );
    }

    // CMDT injection: @TestVisible static cache in AccountService
    // allows test to inject fake CMDT records without DML
    public static void injectRatingConfig(String tier, Decimal threshold) {
        AccountService.ratingConfigCache = new Map<String, AccountRating__mdt>{
            tier => new AccountRating__mdt(Tier__c = tier, Threshold__c = threshold)
        };
    }
}
```

**CMDT injection via @TestVisible:**
Because CMDT records cannot be inserted in test context (`AccountRating__mdt.getAll()` returns org records), the `@TestVisible static ratingConfigCache` field lets tests override the cache with controlled test data without any DML.

---

### 8.3 Mocking HTTP Callouts

```apex
// Implement HttpCalloutMock
public class SuccessCalloutMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setHeader('Content-Type', 'application/json');
        res.setBody('{"id":"abc123","status":"created"}');
        return res;
    }
}

// Use in test
@IsTest
static void syncAccount_success() {
    Test.setMock(HttpCalloutMock.class, new SuccessCalloutMock());
    Test.startTest();
    AccountSyncQueueable job = new AccountSyncQueueable(new List<Id>{ accId }, 0);
    System.enqueueJob(job);
    Test.stopTest();
    // Verify the result was persisted
}
```

**StaticResourceCalloutMock:** For complex JSON responses, store the response in a Static Resource and reference it:
```apex
Test.setMock(HttpCalloutMock.class,
    new StaticResourceCalloutMock('MyMockResponse')); // Static Resource name
```

---

### 8.4 Mocking Platform Event Publishing

Platform Events cannot be fully unit-tested (the subscriber trigger runs in a separate transaction). Test publishing separately from consuming:

```apex
// Test the publisher: verify the event was published
@IsTest
static void publishEvent_onEscalation() {
    Test.startTest();
    CaseEscalationService.escalate(caseId);
    Test.stopTest();
    // Platform Events published in Test.startTest/stopTest are committed
    // Query EventBus delivery is not testable in unit context
    // Verify side effects on the publishing side (e.g., no exception thrown)
    // Test the subscriber trigger separately with Test.startTest() around
    // EventBus.publish() simulation
}
```

---

### 8.5 Bulk Testing

**Always test at 200 records. Always.**

```apex
@IsTest
static void applyDefaults_bulk200Records() {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 200; i++) {
        accounts.add(TestDataFactory.buildAccount('Acct ' + i, 'Customer'));
    }
    Test.startTest();
    insert accounts; // fires trigger with full 200-record batch
    Test.stopTest();

    // Verify all 200 received the expected defaults
    List<Account> results = [SELECT Rating FROM Account WHERE Id IN :new Map<Id,Account>(accounts).keySet()];
    for (Account a : results) {
        System.assertEquals('Hot', a.Rating, 'All 200 should be rated Hot');
    }
}
```

Pattern from `AccountServiceTest.cls` — 200-record bulk insert verifies no SOQL-in-loop limit breach.

---

### 8.6 Testing Different User Contexts

```apex
@IsTest
static void restrictedUser_cannotEditBillingCity() {
    User restrictedUser = TestDataFactory.buildUser('Standard User', 'Standard Platform User');
    insert restrictedUser;

    Account acc = TestDataFactory.buildAccount('Locked Corp', 'Customer');
    insert acc;

    System.runAs(restrictedUser) {
        try {
            acc.BillingCity = 'New York';
            update acc;
            System.assert(false, 'Expected DmlException for field access');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('insufficient access'), e.getMessage());
        }
    }
}
```

---

### 8.7 Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| `@IsTest(SeeAllData=true)` | Tests depend on org data — pass in org A, fail in org B | Create all test data in the test |
| Hardcoded Salesforce IDs (001xxxx) | IDs don't exist in all orgs | Query for the record or use TestDataFactory |
| No negative tests | Bugs in error paths not caught | Test invalid input, missing required fields, boundary values |
| Only testing happy path | Validation logic untested | Test the rejection path explicitly |
| No bulk test | SOQL-in-loop not caught | Always test at 200 records minimum |
| Asserting count but not content | Wrong records returned, count matches by coincidence | Assert specific field values, not just list size |
| Missing `Test.startTest()` | Async jobs don't execute; callout mocks don't apply | Wrap async invocations in `Test.startTest()/stopTest()` |


---

## Section 9 — Lightning Web Components

### 9.1 Lifecycle Hooks

| Hook | When it fires | Common use |
|---|---|---|
| `constructor()` | Component created; DOM not yet rendered | Initialize primitive properties; do NOT access DOM or child components here |
| `connectedCallback()` | Component inserted into the DOM | Subscribe to LMS, add event listeners, start imperative data loads |
| `renderedCallback()` | After every render (initial + every reactive property change) | Access DOM elements via `this.template.querySelector()`; guard with a flag to prevent repeated initialization |
| `disconnectedCallback()` | Component removed from DOM | Unsubscribe from LMS, clear timers, remove event listeners |
| `errorCallback(error, stack)` | Unhandled error in a child component | Display error UI, log to Apex; prevents error from propagating up |

**`renderedCallback` loop trap:**
```javascript
renderedCallback() {
    // ❌ This modifies a reactive property → triggers re-render → fires renderedCallback again → infinite loop
    this.isReady = true;
}

// ✅ Guard with a flag
_initialized = false;
renderedCallback() {
    if (this._initialized) return;
    this._initialized = true;
    // One-time DOM access
    this.template.querySelector('.my-chart').initialize();
}
```

---

### 9.2 Component Communication

**Parent → Child: @api property**
```javascript
// child.js
@api accountId; // parent sets this

// parent.html
<c-child account-id={selectedId}></c-child>
```

**Parent → Child: @api method**
```javascript
// child.js
@api refresh() { this._loadData(); }

// parent.js
this.template.querySelector('c-child').refresh();
```

**Child → Parent: CustomEvent**
```javascript
// child.js
handleSelect(event) {
    this.dispatchEvent(new CustomEvent('accountselected', {
        detail: { accountId: event.target.dataset.id },
        bubbles: true,   // propagates up DOM tree
        composed: false  // does NOT cross shadow DOM boundary (keeps it within Lightning page)
    }));
}
// parent.html
<c-child onaccountselected={handleAccountSelected}></c-child>
```

**Unrelated components: Lightning Message Service**
```javascript
import { MessageContext, publish, subscribe, unsubscribe, APPLICATION_SCOPE }
    from 'lightning/messageService';
import RECORD_SELECTED from '@salesforce/messageChannel/RecordSelected__c';

// Subscriber — must unsubscribe in disconnectedCallback
connectedCallback() {
    this._sub = subscribe(this.messageContext, RECORD_SELECTED,
        (msg) => this.handleMessage(msg), { scope: APPLICATION_SCOPE });
}
disconnectedCallback() {
    unsubscribe(this._sub); // Memory leak if omitted
}
```

---

### 9.3 Wire vs Imperative

**Use @wire when:**
- Data is needed on component load
- Data should auto-refresh when a reactive property changes
- The Apex method is `cacheable=true`

```javascript
@wire(getRecentAccounts, { maxRecords: '$maxRecords' }) // $ = reactive
wiredAccounts({ data, error }) {
    if (data) this.accounts = data;
    if (error) this.error = this._extractError(error);
}
```

**Use imperative when:**
- Call is conditional (triggered by a user action)
- You need full control over error handling and loading state
- The method is NOT cacheable (modifies data)
- You need to call refreshApex programmatically

```javascript
async handleSearch() {
    this.isLoading = true;
    try {
        this.accounts = await searchAccounts({ term: this.searchTerm });
    } catch (error) {
        this.errorMessage = this._extractError(error);
    } finally {
        this.isLoading = false;
    }
}
```

---

### 9.4 Base Components

| Component | Use when | Don't use when |
|---|---|---|
| `lightning-record-form` | Simple create/edit/view of a single record | Complex conditional field visibility, custom validation |
| `lightning-record-edit-form` | Need custom layout with some standard fields | Full custom UI with non-standard inputs |
| `lightning-datatable` | Tabular data with inline edit, sorting, row actions | Complex cell rendering requiring custom HTML |

**`lightning-record-form` respects FLS automatically** — fields the user cannot read are not shown. Imperative Apex controllers must enforce FLS manually.

---

### 9.5 Performance

**@track vs reactive properties:**
In LWC, `@track` is only needed for nested object/array mutations. Primitive properties and top-level object assignments are reactive by default. Overusing `@track` on all properties causes unnecessary re-renders.

```javascript
// ✅ No @track needed — top-level assignment is reactive
this.accounts = [...this.accounts, newAccount]; // new array reference → reactive

// ❌ Without @track, mutation of existing array does not trigger re-render
this.accounts.push(newAccount); // no re-render
```

**Avoiding renderedCallback loops:** Always guard with a boolean flag.

**Lazy loading:** Load detailed data only when needed (user expands a section, clicks a record). Don't pre-load data for all rows in a table.

---

### 9.6 Experience Cloud Constraints

- **Wire adapters that fail for guest users:** `getRecord`, `getRelatedListRecords` require authentication. Use custom Apex `@AuraEnabled(cacheable=true)` with `without sharing` *only* if data is intentionally public
- **Apex for guest context must be `with sharing`:** Guest users with `without sharing` Apex can see ALL records in the org — this is a critical security vulnerability
- **CSP restrictions:** External scripts (analytics, chat widgets) must be explicitly allowed in Experience Cloud CSP Trusted Sites and must use `lightning__ExperiencePage` target in component metadata

---

### 9.7 FSL Mobile Considerations

- **Briefcase configuration:** Defines which records and fields are cached on the mobile device for offline access. Only briefcase-configured fields are available in offline mode
- **Offline-capable components:** Must handle `navigator.onLine === false` gracefully — show cached data, queue mutations for sync when online
- **Unavailable APIs offline:** `getRecord` wire adapter does NOT work offline; use briefcase-stored record data instead
- **Streaming API:** Not available in offline mode — use briefcase + background sync patterns

---

### 9.8 Real Component Example — Imperative Apex, Spinner, Error, RefreshApex

```javascript
import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getAccounts from '@salesforce/apex/AccountService.getRecentAccounts';

export default class AccountList extends LightningElement {
    @track accounts = [];
    @track isLoading = false;
    @track errorMessage;
    _wiredResult; // Store wire result for refreshApex

    @wire(getAccounts, { maxRecords: 50 })
    wiredAccounts(result) {
        this._wiredResult = result;
        if (result.data) {
            this.accounts = result.data;
            this.errorMessage = null;
        }
        if (result.error) {
            this.errorMessage = result.error?.body?.message ?? 'Unknown error';
        }
    }

    handleRefresh() {
        this.isLoading = true;
        refreshApex(this._wiredResult)
            .finally(() => { this.isLoading = false; });
    }

    _extractError(error) {
        if (error?.body?.message) return error.body.message;
        if (error?.body?.pageErrors?.[0]?.message) return error.body.pageErrors[0].message;
        return error?.message ?? 'Unknown error';
    }

    get hasAccounts() { return this.accounts.length > 0; }
    get hasError() { return !!this.errorMessage; }
}
```


---

## Section 10 — Integrations

### 10.1 REST Callout Pattern

```apex
// AccountSyncQueueable.cls pattern
public static HttpResponse callExternalSystem(String endpoint, String method, String body) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:My_Named_Credential' + endpoint);
    req.setMethod(method);
    req.setHeader('Content-Type', 'application/json');
    req.setHeader('Accept', 'application/json');
    if (String.isNotBlank(body)) req.setBody(body);
    req.setTimeout(20000); // 20 seconds — always set an explicit timeout

    HttpResponse res = new Http().send(req);

    // Branch on status code — don't treat all non-200 the same
    if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
        return res;
    } else if (res.getStatusCode() == 401 || res.getStatusCode() == 403) {
        throw new CalloutException('Auth failure: ' + res.getStatusCode());
    } else if (res.getStatusCode() == 429) {
        throw new RateLimitException('Rate limited — retry after cooldown');
    } else {
        throw new CalloutException('Unexpected: ' + res.getStatusCode() + ' ' + res.getBody());
    }
}
```

**Named Credentials:**
Named Credentials store the endpoint URL and authentication details (OAuth, Basic, JWT) outside of Apex code. This means:
- Credentials never appear in Apex source code — no risk of committing secrets
- Token refresh is handled transparently by the platform
- Same Apex code works across sandboxes — only the Named Credential needs to be reconfigured per environment

---

### 10.2 OAuth Flows

| Flow | Use Case | Token Storage |
|---|---|---|
| Client Credentials (Server-to-Server) | System-to-system integration where no user context is needed | Named Credential stores client_id + client_secret |
| JWT Bearer (Server-to-Server) | When you need a specific Salesforce user's context without a browser | Named Credential with certificate; Apex generates the assertion |
| Web Server (Authorization Code) | User-facing integrations where the user must authenticate | Per-user credential stored by Salesforce's External Credential system |
| User-Agent (Implicit) | ⚠️ Deprecated — avoid for new integrations | N/A |

**Connected App setup for JWT flow:**
1. Create Connected App with "Enable OAuth" and "Use Digital Signatures"
2. Upload the certificate's public key in the Connected App
3. Pre-authorize the integration user via Setup → Connected App → Manage → Profiles
4. Sign JWT with the private key in Apex using `Auth.JWT`, `Auth.JWTBearerTokenExchange`

---

### 10.3 Platform Events vs CDC

| Feature | Platform Events | Change Data Capture (CDC) |
|---|---|---|
| Publisher | Apex, Flow, API, Process Builder | Salesforce platform automatically |
| What triggers it | Explicit `EventBus.publish()` call | Any record create/update/delete/undelete |
| Payload contents | Custom fields you define | Changed fields + ChangeEventHeader |
| Delivery guarantee | At-least-once | At-least-once |
| Replay window | 72 hours (3 days) | 72 hours (3 days) |
| Subscriber types | Apex trigger, CometD client, Flow | Apex trigger on `__ChangeEvent` object |
| Governor limits | Publishes count against DML limit | Free — platform generates automatically |
| Use case | Custom business events (case escalated, order approved) | Sync Salesforce data changes to external systems |
| changedFields | Custom payload — you control | `ChangeEventHeader.changedFields` — only on UPDATE |

**When to use PE over CDC:**
Use PE when you need to define a custom event schema, control when events fire, or publish from non-DML code paths (callout results, scheduled Apex outcomes).

Use CDC when you need to react to all DML changes on an object without instrumentation — ideal for external system replication.

---

### 10.4 Outbound Messaging

Still relevant when: external systems consume SOAP-based Outbound Messages and rewriting them is not feasible. Outbound Messages have a built-in retry mechanism (up to 24 hours) and do not require Named Credentials.

**Limitations vs Platform Events:**
- SOAP only (no JSON)
- Limited field selection (defined in Setup UI)
- No subscriber can filter by field value
- Cannot be triggered from Apex directly — only from workflow rules

For new integrations, Platform Events are the preferred replacement.

---

### 10.5 Middleware vs Native Decision

| Factor | Use Native Salesforce API | Use Integration Middleware (MuleSoft, Azure IPaaS) |
|---|---|---|
| Number of systems involved | 2 (Salesforce + one other) | 3+ systems with complex routing |
| Transformation complexity | Simple JSON mapping | Complex schema transformation, canonical model |
| Team ownership | Salesforce team owns both sides | Separate integration team owns the middleware layer |
| Volume | < 1M events/day | High volume requiring external queue buffering |
| Protocol translation | Not needed | SOAP→REST, EDI→JSON, legacy protocols |
| Retry/DLQ sophistication | Platform Event replay sufficient | Enterprise-grade DLQ with alerting required |

---

### 10.6 Retry and Error Handling

**Dead letter queue pattern:**
```apex
// When processing a Platform Event fails after retries:
// Create a DeadLetterMessage__c record for ops team visibility
try {
    processEvent(event);
} catch (Exception e) {
    if (shouldRetry(e)) {
        throw new EventBus.RetryableException(e.getMessage()); // Platform retries up to 9 times
    }
    // Non-retryable: send to DLQ
    insert new DeadLetterMessage__c(
        Payload__c       = JSON.serialize(event),
        Error_Message__c = e.getMessage(),
        Channel__c       = 'Case_Escalation_Event__e',
        Occurred_At__c   = DateTime.now()
    );
}
```

**Integration_Error_Log__c approach:**
Every callout in `AccountSyncQueueable.cls` that fails creates an `Integration_Error_Log__c` record with:
- Source system name
- Target system name
- HTTP status code
- Request payload (truncated to 32K)
- Response body (truncated)
- Correlation ID
- Retry count

This gives ops teams visibility without requiring log file access.

---

### 10.7 Integration Anti-Patterns

| Anti-Pattern | What Goes Wrong | Fix |
|---|---|---|
| Callout in synchronous trigger | `System.CalloutException: You have uncommitted work pending` | Move callout to Queueable invoked from after trigger |
| No idempotency key | Retry delivers duplicate records in target system | Generate UUID correlation ID; check for existing record before insert |
| Swallowing HTTP errors (`catch (Exception e) { }`) | Integration fails silently; data gets out of sync | Log every non-2xx with full context; alert ops team |
| No retry mechanism | Transient failures (network glitch, 503) cause data loss | Implement retry with exponential backoff (Day 36 pattern) |
| Hardcoded endpoint in Apex | Breaks when URL changes; requires code deployment | Use Named Credentials |
| Querying in integration callback trigger | SOQL limit hit when bulk events arrive | Bulk-query outside loop; use Map pattern |


---

## Section 11 — Security Model

### 11.1 Full Sharing Model Chain

```
Layer 1: OWD (Org-Wide Default)
  → Sets the baseline: Private, Public Read Only, Public Read/Write, Controlled by Parent
  → Cannot restrict below this floor with any higher layer

Layer 2: Role Hierarchy
  → Grants upward visibility: managers see subordinates' records
  → Only applies when OWD is Private or Public Read Only
  → Configurable per object (Grant Access Using Hierarchies checkbox)

Layer 3: Sharing Rules (Criteria-based or Owner-based)
  → Opens access to sets of records for groups of users
  → Can only expand access beyond OWD + Role Hierarchy
  → Evaluated asynchronously for large data volumes

Layer 4: Manual Sharing
  → User-granted access on a specific record
  → "Share" button on record detail
  → Stored in {Object}Share sObject

Layer 5: Apex Managed Sharing
  → Programmatic share with custom RowCause
  → Survives ownership changes if RowCause is a custom one
  → Standard Manual RowCause shares are deleted when owner changes

Layer 6: Field-Level Security (FLS)
  → Controls which fields a user can read/edit
  → Enforced by the UI automatically; Apex does NOT auto-enforce
  → Profile + Permission Set = most permissive union wins

Layer 7: CRUD (Object-Level Permissions)
  → Gate: if user lacks Read on Case, no sharing layer can reveal Case records
  → Read, Create, Edit, Delete, View All, Modify All
```

---

### 11.2 FLS Enforcement in Apex

**The problem:** Apex runs as the system user by default — it ignores FLS unless you explicitly enforce it.

**Three enforcement approaches:**

```apex
// A — WITH USER_MODE in SOQL (API v56+, preferred)
List<Account> accs = [SELECT Id, Name, AnnualRevenue FROM Account WITH USER_MODE];
// Fields the user can't read are silently omitted; DML respects CRUD

// B — Security.stripInaccessible() before returning to UI
SObjectAccessDecision decision = Security.stripInaccessible(
    AccessType.READABLE, rawRecords
);
return decision.getRecords(); // inaccessible fields removed

// C — Manual describe check for granular control
Schema.DescribeFieldResult fd = Account.AnnualRevenue.getDescribe();
if (!fd.isAccessible()) throw new SecurityException('Cannot read AnnualRevenue');
```

**WITH SECURITY_ENFORCED vs WITH USER_MODE:**
- `WITH SECURITY_ENFORCED` throws a `System.QueryException` if any field is inaccessible — use only when you are certain all fields are accessible
- `WITH USER_MODE` silently omits inaccessible fields — safer for general use, never throws

---

### 11.3 LWC vs Apex Security

| Scenario | FLS Enforced? |
|---|---|
| `lightning-record-form` displays a field | ✅ Automatically — field hidden if user lacks Read |
| `lightning-record-edit-form` with a field | ✅ Automatically |
| Custom LWC calls `@AuraEnabled` Apex method | ❌ Apex must enforce manually |
| Custom LWC calls Apex with `WITH USER_MODE` | ✅ Query enforces FLS |
| Apex REST endpoint called externally | ❌ Must strip inaccessible or use USER_MODE |

---

### 11.4 Guest User Security in Experience Cloud

**What guest users can access by default:**
- Nothing. OWD for guest users starts at the most restrictive setting
- Records can be exposed via Guest User Sharing Rules (criteria-based) or Sharing Sets

**Common misconfiguration:**
Setting OWD for a custom object to "Public Read Only" *for all users* — this exposes records to guest users because guest users are included in "all users". Guest user OWD should always be "Private" unless intentional.

**Sharing Set for guest users:**
Used when guest users should see records related to them (e.g., a portal case belonging to their account). Configure a Sharing Set in Setup → Digital Experiences → Settings → Guest User Sharing Rules.

**Apex controller for portal:**
```apex
// ✅ Correct — with sharing enforces OWD + sharing rules
public with sharing class PortalCaseController {
    @AuraEnabled(cacheable=true)
    public static List<Case> getPortalCases() {
        // Returns only cases the running user can see
        return [SELECT Id, Subject, Status FROM Case WHERE ContactId = :UserInfo.getContactId()
                WITH USER_MODE];
    }
}

// ❌ DANGEROUS in portal context
public without sharing class PortalCaseController {
    // Guest users running this can see ALL cases in the org
}
```

---

### 11.5 Shield

| Shield Feature | What it Does | Performance Impact |
|---|---|---|
| Platform Encryption | Encrypts field values at rest using org-managed key | Fields encrypted with AES-256 cannot be used in SOQL WHERE clauses with standard indexes; SOQL on encrypted fields forces table scans |
| Event Monitoring | Audit trail of user logins, report exports, API calls; available via log files | None on query performance; download logs via API |
| Field Audit Trail | Extended data retention for field history (up to 10 years) | None on query performance |

**Platform Encryption and SOQL:**
If a field is encrypted with Platform Encryption, any query filtering on that field performs a deterministic encryption first and compares ciphertext — this only works if the value is an exact match and the field uses "Deterministic Encryption" mode. "Probabilistic Encryption" mode makes the field completely unqueryable.

**When to use Shield:**
- Healthcare/Financial Services compliance (HIPAA, PCI-DSS)
- Government contracts requiring data residency and encryption at rest
- Industries requiring full audit trails for regulatory compliance


---

## Section 12 — DevOps and Deployment

### 12.1 SFDX Project Structure

```
salesforce-interview-prep/        (this repo)
├── force-app/
│   └── main/
│       └── default/
│           ├── classes/          Apex classes + -meta.xml
│           ├── lwc/              LWC bundles (js, html, js-meta.xml)
│           ├── triggers/         Trigger files + -meta.xml
│           ├── flows/            Flow XML files
│           ├── objects/          sObject definitions + fields
│           ├── permissionsets/   Permission Set metadata
│           ├── messageChannels/  LMS channel definitions
│           └── staticresources/  Static resource files
├── scripts/                      Deploy shell scripts per day
├── docs/                         Day-specific documentation
├── sfdx-project.json             Project config (API version, package directories)
└── .github/workflows/            CI/CD pipeline definitions
```

`sfdx-project.json` critical settings:
```json
{
  "packageDirectories": [{ "path": "force-app", "default": true }],
  "sourceApiVersion": "59.0",
  "plugins": {
    "sf": { "useMostRecentVersion": true }
  }
}
```

---

### 12.2 sf CLI Key Commands

| Command | Purpose | Key Flags |
|---|---|---|
| `sf project deploy start` | Deploy source to org | `--source-dir`, `--target-org`, `--wait 10`, `--test-level RunLocalTests` |
| `sf project retrieve start` | Retrieve metadata from org | `--source-dir`, `--target-org` |
| `sf apex run test` | Run Apex tests | `--class-names`, `--target-org`, `--result-format human`, `--wait 10` |
| `sf org create scratch` | Create scratch org | `--definition-file config/project-scratch-def.json`, `--alias`, `--duration-days 30` |
| `sf package version create` | Create unlocked package version | `--package`, `--installation-key`, `--wait 20` |
| `sf apex run` | Execute anonymous Apex | `--file scripts/anon.apex`, `--target-org` |
| `sf data import tree` | Import test data | `--files data/accounts.json`, `--target-org` |

**Delta deployment with sfdx-git-delta:**
```bash
# Install: npm install -g sfdx-git-delta
# Generate delta between last deployed commit and HEAD
sgd --from HEAD~1 --to HEAD --output ./delta --repo .
sf project deploy start --source-dir delta/force-app --target-org prod
```

---

### 12.3 Unlocked Packages vs Org Development vs Source Tracking

| Model | Version Control | Dependency Management | CI/CD Friendly | Best For |
|---|---|---|---|---|
| Org Development | Via SFDX source tracking | Manual | Partial (full org deploys) | Solo devs, simple orgs |
| Unlocked Package | Per package version | Declared in sfdx-project.json | ✅ Yes | Multi-team, modular large orgs |
| Managed Package (2GP) | Per package version | Full dependency tree | ✅ Yes | ISV / AppExchange products |

**When unlocked packages are worth the overhead:**
- > 3 developers working on different functional areas simultaneously
- Multiple sandboxes that receive different subsets of functionality
- Need to version-pin specific features (rollback a package version without affecting others)

---

### 12.4 CI/CD Pipeline with Azure DevOps

```yaml
# azure-pipelines.yml — typical Salesforce pipeline
stages:
  - stage: Validate
    jobs:
      - job: ValidateDeployment
        steps:
          - script: sf project deploy validate --source-dir force-app
              --target-org CI_Sandbox --test-level RunLocalTests --wait 30
            displayName: Validate against CI sandbox

  - stage: Test
    dependsOn: Validate
    jobs:
      - job: RunTests
        steps:
          - script: sf apex run test --target-org CI_Sandbox
              --test-level RunLocalTests --result-format tap --wait 30
            displayName: Run Apex tests
          - script: check_coverage.sh  # Custom script: fail if < 75%

  - stage: Deploy
    dependsOn: Test
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: DeployToProduction
        environment: production
        strategy:
          runOnce:
            deploy:
              steps:
                - script: sf project deploy start --source-dir force-app
                    --target-org Production --test-level RunLocalTests --wait 60
```

**Approval gate before production:** In Azure DevOps, the `environment: production` with a configured approval check pauses the pipeline and sends approval requests to designated reviewers.

---

### 12.5 Branching Strategy

**Day-based model (this repo as portfolio evidence):**
Each day's work lives in a feature branch (`day-38-mock-interview-clouds-devops`), has a PR with test checklist, and merges to `main`. Demonstrates:
- Git discipline
- PR-based review workflow
- Incremental delivery

**GitFlow for Salesforce teams:**
```
main          ← production-aligned; only releases merge here
develop       ← integration branch; feature branches merge here
feature/xxx   ← developer's working branch
hotfix/xxx    ← emergency production fix; merges to both main and develop
release/vX.Y  ← stabilization branch before production deploy
```

**Trunk-based for large CI/CD teams:**
Short-lived feature branches (< 1 day) merged directly to main with feature flags. Requires strong automated testing and CI gating.

---

### 12.6 Destructive Changes

When you delete a field, object, Apex class, or Flow:
1. Create `destructiveChanges.xml` (pre-deployment: delete before deploying new code)
   or `destructiveChangesPost.xml` (post-deployment: delete after new code is deployed)
2. The XML format:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>OldApexClass</members>
        <name>ApexClass</name>
    </types>
    <version>59.0</version>
</Package>
```
3. Include in the deployment: `sf project deploy start --manifest destructiveChanges.xml`

**Risk:** Deleting a field destroys all its data. Always back up field data before deleting. Verify no reports, dashboards, Flows, or Apex reference the field before deletion.

---

### 12.7 Deployment Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| Change sets with no rollback plan | Production is broken; reverting requires another deployment cycle | Always have a rollback plan (previous version of changed classes ready to redeploy) |
| Deploying without running tests | Coverage check skipped; broken logic in production | Always use `--test-level RunLocalTests` minimum |
| No destructive changes plan | Deleted fields/classes remain as dead code/data in production | Audit dependencies before deletion; plan destructive XML |
| Environment drift from manual changes | Sandbox and production diverge; future deployments fail | Enforce all changes via source control + deployment; no direct production changes |
| Deploying on Friday afternoon | Weekend support unavailable if deployment breaks production | Define deployment windows; no production deployments < 4 hours before a support gap |


---

## Section 13 — Architecture and System Design

### 13.1 Multi-Org Strategy

**When one org is enough:**
- Single business unit, single region, unified data model
- No data residency requirements forcing geographic separation
- All users are part of the same org-wide sharing model

**When to split into multiple orgs:**
- Regulatory/compliance: data for Region A cannot be accessible to Region B users (e.g., EU GDPR data cannot live in a US org)
- Acquired company with a completely different business model — merging is more expensive than maintaining two orgs with a sync layer
- Development sandbox isolation: Scratch orgs per developer are effectively multi-org but merge to one production

**Hub and Spoke model:**
A single "Hub" org holds cross-org analytics, user provisioning, and master data. "Spoke" orgs are regional/business-unit-specific and sync key objects (Account, Contact) to/from the Hub via Platform Events or REST. This repo's `MultiCloudOrchestrator.cls` demonstrates the event-driven version of this pattern.

**Data residency and compliance:**
- Salesforce Hyperforce allows specifying geographic residency for data-at-rest
- This does NOT change the multi-tenant model — it controls which data center hosts the pods

---

### 13.2 Integration Patterns at Scale

| Pattern | When to Use | Scale Limit |
|---|---|---|
| Point-to-Point REST | 2 systems, simple mapping, < 100K events/day | Brittle at scale; each new system requires bilateral agreements |
| Event-Driven (Platform Events) | Decoupled producers and consumers; audit trail via replay | 250K events/day (standard); higher with add-on |
| Middleware (MuleSoft/Azure) | 3+ systems; complex transformation; enterprise DLQ required | Limited by middleware tier; can handle millions/day |
| Bulk API 2.0 | Large ETL batches (100K–100M records) | Up to 150M records per 24h window |
| Streaming API (CometD) | Real-time record changes for external consumers | Depends on Event Monitoring allocation |

---

### 13.3 Data Modeling Decisions

**Lookup vs Master-Detail impact on sharing:**
Master-Detail child inherits the parent's OWD. If the parent has OWD = Private, the child is also effectively private to unauthorized users even without an explicit child OWD setting. This is often surprising when auditing access issues.

**Schema evolution without downtime:**
1. **Adding a field:** Zero downtime — Salesforce adds the column to the underlying table with a null default
2. **Renaming a field:** Change the label (zero impact); changing the API name requires updating all references (Apex, Flows, Reports, integrations) — high risk
3. **Changing field type:** Allowed for some type pairs (Text→TextArea); blocked for others; data may be lost if changing Picklist to Text
4. **Deleting a field:** Soft-delete (field goes to "Deleted Fields" for 15 days); all data is retained but inaccessible; hard-delete destroys data permanently

---

### 13.4 Scalability Design

**What breaks at 10M records:**
- List views with complex filters (especially cross-object formulas in filters)
- Reports with row counts exceeding 2,000 (report row limit)
- Trigger with SOQL not filtered by date range (table scan on Case with 10M rows)
- Rollup Summary recalculation on mass updates

**What breaks at 100M records:**
- SOQL timeout even with indexed fields (query returns too many rows)
- Rollup Summary field recalculation queues can back up for hours
- Any Apex that loads the full data set into memory (heap overflow)
- Reports become unusable — push to CRM Analytics or external BI

**Design upfront:**
- Index strategy: plan which fields need custom indexes before go-live
- Date partitioning: always include a date range filter in any automated query on LDV objects
- Archiving strategy: define retention policy at schema design time, not after data grows
- Flat structure: denormalize frequently-queried aggregate values into parent records

---

### 13.5 End-to-End System Design — Field Service + Portal + Billing

**Business scenario:** A field service company needs: (1) Service Cloud for case management, (2) FSL for work order dispatch, (3) Experience Cloud portal for customer self-service, (4) External billing system sync.

**Data flow:**
```
Customer → Experience Cloud Portal → Creates Case (via PortalCaseController with sharing)
                                           ↓
                              Service Cloud — Case assigned to Service Agent (Omni-Channel)
                                           ↓
                              Agent creates Work Order → linked to Case
                                           ↓
                              FSL Dispatcher Console → Schedule Service Appointment
                                           ↓
                              Field Tech (FSL Mobile) → Updates Service Appointment Status
                                           ↓
                      After-save trigger on WorkOrder → publishes WorkOrderCompleted__e
                                           ↓
                   Platform Event subscriber → creates Invoice__c + sends to billing system
                                           ↓
               Billing system webhook → updates Invoice__c with payment status
                                           ↓
          Portal contact sees updated case/invoice status in Experience Cloud
```

**Error handling:**
- Billing callout fails: `EventBus.RetryableException` in subscriber → retries up to 9 times → DLQ after exhaustion
- FSL offline update: Briefcase sync on reconnect updates ServiceAppointment → trigger fires asynchronously
- Portal data access: All portal Apex is `with sharing`; Sharing Set grants contact access to their cases

**Deployment strategy:**
1. Core objects (Case, WorkOrder, Invoice__c) → metadata deployed first
2. Service Cloud flows and triggers → deployed and tested
3. FSL configuration (Service Territory, Scheduling Policy) → configured in sandbox, exported via metadata
4. Experience Cloud site → published to sandbox, URL configured, deployed to production
5. Billing integration → Named Credential configured per environment; callout Apex deployed


---

## Section 14 — Clouds Overview

### 14.1 Service Cloud

**Case Lifecycle:**
New → Assigned (via Assignment Rules / Omni-Channel) → In Progress → Pending Customer → Resolved → Closed

**Entitlements and Milestones (SLA enforcement):**
- Entitlement: defines what a customer is entitled to (e.g., "8x5 Phone Support", "24x7 Priority Support")
- Entitlement Process: a sequence of Milestones with time-based actions
- Milestone: a step within the process (e.g., "First Response within 4 hours", "Resolution within 24 hours")
- Warning/Violation actions: automatically email agents, reassign, or update fields when a milestone is at risk or breached

**Omni-Channel routing:**
- Queue-based: cases assigned to a queue; Omni-Channel routes to the first available agent subscribed to that queue
- Skills-based: routes to an agent with a matching skill (e.g., "Spanish", "Billing", "Technical") at the required skill level
- `PendingServiceRouting` record: programmatic routing via Apex (`MockInterviewCloudsService.routeWorkItemToOmniChannel` pattern)
- Capacity model: each work item has a `CapacityWeight`; agents have a capacity limit — no new items assigned when agent is at capacity

**Real escalation scenario:**
```
Portal Case created → First Response Milestone starts (4h SLA)
  → Agent assigned via Omni-Channel
  → No response in 3h → Warning email to agent + manager
  → No response in 4h → Milestone violated → Case priority escalated to Critical
  → Critical priority → Assignment Rule reassigns to Escalation Queue
  → Escalation Queue → Omni-Channel routes to Escalation Agent
  → After-save trigger → publishes Platform Event → PagerDuty notification
```

**Knowledge:**
- Articles linked to Cases for deflection (self-service portal shows suggested articles)
- `Knowledge__kav` is the article sObject; use `TYPEOF` in SOQL for article type queries
- Data Category Groups control who can see which articles

---

### 14.2 Field Service Lightning

**Core objects:**
- `WorkOrder` — the service job (created from a Case)
- `WorkOrderLineItem` — individual tasks within the work order
- `ServiceAppointment` — the scheduled visit (date/time, assigned resource)
- `ServiceResource` — a technician or equipment
- `ServiceTerritory` — geographic area; resources are assigned to territories
- `OperatingHours` — business hours for territories and resources
- `SchedulingPolicy` — rules for how the Optimizer assigns appointments (priority, travel time weight, skill matching)

**Dispatcher Console:**
- Gantt-based UI showing resource availability and appointment scheduling
- Drag-and-drop to reassign or reschedule
- Optimization: run "Schedule All" to let the FSL Optimizer assign appointments based on policy

**Apex hooks in FSL lifecycle:**
- `FSL.ScheduleResult` — return from custom scheduling logic
- Global actions (Apex-backed FSL actions) allow custom logic when a technician completes a step in the mobile app
- Platform Events: FSL publishes `FSL_ServiceAppointmentFeed__e` events on status changes — subscribe in Apex or Flow

**Mobile app architecture:**
- Ionic/Angular-based native app (not LWC)
- Briefcase: preloads data for offline access (configure in FSL Settings → Briefcase)
- Offline actions: technician can capture signature, complete checklist, update status offline — synced on reconnect

---

### 14.3 Experience Cloud

**LWR (Lightning Web Runtime) vs Aura sites:**
- LWR: modern, built on LWC primitives, faster initial load, progressive rendering, no Aura components
- Aura: legacy, supports Aura components, slower, being phased out for new implementations
- For new Experience Cloud builds: always use LWR

**Guest user security model:**
- Guest users are unauthenticated visitors to the portal
- They run as the "Guest User" in the site's context — NOT as the logged-in Salesforce user
- Object permissions for Guest User are configured in Setup → Digital Experiences → Guest User Profile
- Record access is via Sharing Rules (Guest User Sharing Rules) or Sharing Sets — not OWD or Role Hierarchy

**CMS for content management:**
- Salesforce CMS: structured content (articles, news) managed in a workspace, published to Experience Cloud pages
- Content can be translated and personalized based on audience segments

**Apex controller design for portal context:**
- Always `with sharing` — never `without sharing` unless the data is intentionally public
- Always `WITH USER_MODE` in SOQL — enforces FLS for the running portal user
- Limit queries to records owned by or shared with the running user: `WHERE ContactId = :UserInfo.getContactId()`

---

### 14.4 CPQ (Conga — formerly Salesforce CPQ)

**Quote-to-cash lifecycle:**
```
Product Catalog → Quote → Approval → Contract → Order → Invoice
```

**Product catalog and bundles:**
- Products have Price Book Entries defining list price
- Bundles: a parent Product with child Product Options (components)
- Configuration rules: constraints that determine which options are available together

**Pricing waterfall:**
```
1. List Price     (from Price Book Entry)
2. – Volume Discount (quantity-based)
3. – Discretionary Discount (manually applied by rep)
4. – Partner Discount (for channel partners)
5. = Customer Price
6. – Special Terms Discount
7. = Net Price
```

Waterfall order matters: a 10% partner discount applied before a 20% volume discount produces a different result than the reverse order. CPQ applies discounts in the configured order — misconfiguration is a common support ticket source.

**Approval workflow:**
- Approval conditions: configured on the Quote record (e.g., Discount > 20% requires manager approval)
- Multi-level: sequential approvers or parallel
- `SBQQ__Quote__c.SBQQ__Status__c`: Draft → Needs Approval → Approved → Contracted

**Order handoff to billing:**
After contract generation (`SBQQ__Contract__c`), an after-save trigger or Flow publishes a Platform Event with contract details. The billing system subscribes and creates an invoice. The ERP Order ID is stored back on the Contract via a webhook callback (see `CrossCloudArchitectureService.notifyErpOfApprovedQuote`).


---

## Section 15 — Modern Salesforce: Agentforce and Data Cloud

### 15.1 Agentforce

**What it is:** Agentforce is Salesforce's AI agent platform. Agents are AI-powered autonomous assistants that can reason, use tools (Actions), and respond to natural language queries within a defined topic scope.

**How Agents differ from Bots:**
| | Bots (Einstein Bots) | Agentforce Agents |
|---|---|---|
| Interaction model | Scripted dialog tree | LLM-based reasoning and natural language |
| Action execution | Pre-configured intents | Dynamic tool use via Apex @InvocableMethod |
| Context understanding | Limited to dialog state | Full conversational context + grounding data |
| Customization | Dialog designer in Setup | Topics, Actions, Prompt Templates in Agentforce Studio |

**Key concepts:**
- **Topics:** Intent classification rules — "When should this agent engage?" (e.g., "This topic handles account health inquiries")
- **Actions:** What the agent can do — Apex `@InvocableMethod`, Flows, or Prompt Templates
- **Reasoning Engine:** The LLM that decides which Action to invoke based on user input and Topic scope
- **Guardrails:** Safety rules — what the agent is prohibited from doing or saying

---

### 15.2 Agent Actions via Apex

The same `@InvocableMethod` that powers Flow actions powers Agentforce Actions. The `label` and `description` fields are read by the LLM to understand when and how to call the action.

```apex
@InvocableMethod(
    label       = 'Get Case Summary'
    description = 'Returns a plain-language summary of a Case including status, '
                + 'open tasks, and recent activity. Use this when the user asks '
                + 'about a specific case or case number.'
    category    = 'Case Management'
)
public static List<CaseSummaryOutput> getCaseSummary(List<CaseSummaryInput> inputs) {
    // Output is returned to the LLM as grounding context
    // The LLM uses it to compose the natural language response
}
```

**Design rules for LLM-friendly actions:**
1. `description` is written for an LLM, not a developer — use natural language trigger phrases ("Use when user asks about...")
2. Outputs must be `@InvocableVariable` with meaningful `label` values — the LLM references outputs by label
3. Actions must be deterministic — same input → same output (no random elements)
4. Keep each action focused on one capability — the LLM routes across actions; monolithic actions produce unpredictable results
5. Return a `contextSummary` string that the LLM can include verbatim in its response (see `CrossCloudArchitectureService.getAccountContextForAgent`)

---

### 15.3 Prompt Templates

**Types:**
- **Completion template:** Single-turn prompt → response (e.g., "Summarize this account record")
- **Chat template:** Multi-turn conversation with system + user + assistant turns

**Grounding with merge fields:**
```
You are a Salesforce Service Agent assistant.

Account: {!$Record.Name}
Industry: {!$Record.Industry}
Open Cases: {!$Record.OpenCaseCount__c}

Based on the above, provide a brief account health summary.
```

Merge fields inject live org data into the prompt at runtime — this is grounding. The LLM generates a response specific to the actual record, not a hallucinated generic answer.

**Security:** Prompt Templates use the running user's context — FLS applies. A user who cannot see `AnnualRevenue` will not have it injected into their prompt even if it's in the template.

---

### 15.4 Data Cloud

**Architecture:**
```
Data Streams (ingest) → Data Lake Objects (raw) → Data Model Objects (mapped) 
  → Unified Individual (identity resolution) → Segments (filter) → Activations (output)
```

**Data streams:** Ingest data from Salesforce CRM, external systems (S3, Snowflake), mobile apps, and web analytics. Data arrives in the Data Lake as raw streaming or batch data.

**Unified Individual / Unified Profile:** Data Cloud's identity resolution engine matches records across sources by email, phone, device ID, etc. and creates a single unified profile per person. This is the "golden record" pattern at platform scale.

**Segments:** Filter unified profiles by attributes (e.g., "High-value customers who haven't purchased in 90 days"). Segments can be evaluated in real-time or batch.

**Activations:** Push segment membership to:
- Salesforce CRM (via Related Object activation → custom object or field update)
- Marketing Cloud (via connector → Journey entry, DE update)
- External systems (via webhook or Streaming Insights Platform Event)

---

### 15.5 Einstein Features

| Feature | Where It Lives | What It Does |
|---|---|---|
| Einstein Next Best Action | Service Cloud, any object | Recommends actions to agents based on strategy and ML scoring |
| Prediction Builder | Setup → Einstein | Predicts a field value (e.g., likelihood to churn) without coding; writes score to a custom field |
| Einstein Copilot | Side panel in Lightning | Conversational AI assistant; powered by Agentforce internally |
| Einstein Language | API (sentiment, intent) | Text classification: sentiment analysis, intent detection (Day 34 patterns) |
| Einstein Vision | API | Image classification, object detection |

**Next Best Action in Service Cloud:**
Configured via a Recommendation Strategy (Flow-like canvas). The strategy evaluates ML scores, business rules, and context to surface 1-3 recommendations in the NBA component on the Case page. Apex can also call `ConnectApi.Recommendations.getRecommendations()` programmatically.

---

### 15.6 Saikiran's Background Mapped to Agentforce/Data Cloud

| Your Experience | Agentforce/Data Cloud Opportunity |
|---|---|
| Service Cloud + Case lifecycle | Agentforce agent that automates case triage, suggests knowledge articles, routes to right queue — natural extension |
| FSL Work Order management | Agentforce action that queries available technicians and recommends appointment slots |
| Experience Cloud portal | Agentforce embedded in portal for self-service ("What is the status of my work order?") |
| REST API integrations | Data Cloud data stream from external system; activation back to Salesforce CRM |
| Apex + @InvocableMethod | Already the mechanism for Agent Actions — direct transfer |

**How to speak confidently without direct project experience:**
"I haven't deployed Agentforce in production yet, but I've built the foundational components it relies on — `@InvocableMethod` actions, grounding context queries, and Named Credential callout patterns. The architecture maps directly to what I've implemented: the same Apex methods I write for Flow actions are the same ones Agentforce calls. I'd be productive from day one with the platform fundamentals already in place."


---

## Section 16 — Scenario-Based Questions

### Scenario 1: Trigger Conflict — 12 Triggers on Opportunity from 4 Teams

**Business problem (as a PM would describe it):**
"Every time we release, something breaks on the Opportunity object. Sales, Finance, Support, and Product all have triggers. Nobody knows which order they run in or why one trigger's update is overwriting another's."

**Weak answer:** "We should combine all the triggers into one."

**Strong answer — architecture thinking:**
The root cause is no trigger framework ownership and no execution ordering. The fix is two-phased:

**Phase 1 — Immediate stabilization:**
1. Audit all 12 triggers: document which event each fires on, what SOQL they do, what DML they commit
2. Identify conflicts: are two triggers updating the same field? Are two doing SOQL on the same object in the same before-insert context?
3. Add a CMDT-based bypass flag to each — this lets us disable individual triggers for testing without deployment

**Phase 2 — Consolidation:**
1. Implement `TriggerHandler` base class (as in this repo) in a shared library unlocked package
2. One trigger file per object: `OpportunityTrigger on Opportunity (before insert, before update, after insert, after update, after delete)` — routes to `OpportunityTriggerHandler`
3. Each team migrates their logic into service class methods called from the handler
4. Execution order is now deterministic within the single trigger
5. Each service method has its own Apex tests and can be bypassed independently via CMDT

**Trade-off:** Migration takes 2-3 sprints per team. During migration, run old triggers in parallel with a CMDT flag to A/B test. Never delete the old trigger until the new service method is fully tested.

---

### Scenario 2: Async Processing — 2M Account Sync with Retry and Alerting

**Business problem:**
"Every night we need to sync 2 million Account records to our ERP. The sync sometimes fails partway through, and we don't know which records failed or how to retry just the failures."

**Weak answer:** "Use a batch job to call the ERP for each record."

**Strong answer:**
Design a multi-layer async architecture:

**Layer 1 — Scheduled Apex fires nightly:**
```apex
// ScheduledAccountSync queries only records modified since last run
// Uses a Last_Sync_Timestamp__c Custom Setting as a watermark
List<Id> modifiedIds = [SELECT Id FROM Account
    WHERE LastModifiedDate >= :lastSyncTimestamp LIMIT 2000000];
Database.executeBatch(new AccountSyncBatch(modifiedIds), 200);
```

**Layer 2 — Batch Apex processes in chunks of 200:**
- `execute()` makes a Composite REST API call (up to 25 accounts per composite request = 8 callouts per chunk of 200)
- On per-record failure: create `Integration_Error_Log__c` with record ID, error, retry count
- `Database.Stateful`: accumulate error count across batches

**Layer 3 — Retry mechanism:**
- After `finish()`: query `Integration_Error_Log__c` where `Retry_Count__c < 3`
- Re-enqueue failed IDs in a separate batch job
- After 3 retries: mark as `Permanent_Failure__c = true`, publish Platform Event for ops alert

**Trade-offs:**
- Composite API vs individual calls: 25:1 callout reduction; if one record in the composite fails and `allOrNone=true`, all 25 fail — use `allOrNone=false` and parse `compositeResponse` per-record
- Stateful batch heap: keep `errorLog` as a list of `Id` strings, not full SObjects, to stay within 12MB heap

---

### Scenario 3: Integration Failure — Mid-Transaction Callout After Partial DML

**Business problem:**
"Our trigger creates an Order record in Salesforce and then calls the warehouse API. Sometimes the warehouse call fails after the Order is already saved. Now we have an orphaned Order with no warehouse reservation."

**Weak answer:** "Use a try/catch around the callout."

**Strong answer — atomicity problem:**
Callouts cannot be made in the same transaction after DML. This is a platform constraint. The correct solution is to separate the concerns:

**Solution A — Queueable (recommended):**
1. Before trigger or after trigger on Order: validate all fields, add error if invalid (no DML yet in before)
2. After insert: enqueue `WarehouseReservationQueueable` (pass the Order ID)
3. The Order is committed to Salesforce (transaction completes)
4. Queueable runs in a new transaction: calls warehouse API
5. If warehouse call fails: update Order with `Warehouse_Status__c = 'Failed'`; create `Integration_Error_Log__c`; retry via a new Queueable with exponential backoff

**Solution B — Saga pattern with compensation:**
If true atomicity is required (Order must not exist if warehouse fails):
1. After warehouse call fails in Queueable: delete the Order record as compensation
2. Log the failure; notify the originating user via Platform Event or email

**Trade-off:** Saga compensation introduces complexity and requires idempotent steps. For most integrations, Solution A (accept eventual consistency) is correct. True 2-phase commit does not exist natively in Salesforce.

---

### Scenario 4: LDV Performance — Dashboards Timing Out on 50M-Row Case Object

**Business problem:**
"Our Service dashboard shows average resolution time and open case count. It's been timing out for the past month. The Case object now has 50 million records."

**Weak answer:** "Add a custom index on the Status field."

**Strong answer:**
Diagnose first, then prescribe:

**Step 1 — Diagnose:**
- Run the report underlying the dashboard with Explain Plan — is it a TableScan?
- Check if dashboard filter fields are indexed
- Check if the report is using a cross-object formula field in its filter

**Step 2 — Short-term fix:**
- Replace non-indexed filters with indexed fields (Status, OwnerId, CreatedDate)
- Remove cross-object formula fields from filter criteria
- Add date range to all report filters: `CreatedDate >= LAST_N_DAYS:365` instead of "all time"

**Step 3 — Medium-term:**
- Skinny table request to Salesforce Support for the 5-6 fields used in all Case reports
- Request custom indexes for `Custom_Category__c`, `Resolution_Time__c` if used in filters

**Step 4 — Long-term (architectural):**
- Introduce a `DailyCaseMetrics__c` custom object: nightly batch aggregates case metrics into one row per day per queue
- Dashboard queries `DailyCaseMetrics__c` (small table, fast queries) instead of Case directly
- Push historical data to CRM Analytics — move trend analysis out of reports, into Einstein Analytics dashboards with pre-aggregated datasets

**Trade-off:** Pre-aggregated metrics are slightly stale (up to 24 hours). For real-time metrics, use a skinny table + selective SOQL; for historical trends, CRM Analytics is the right tool.

---

### Scenario 5: Security Gap — Portal Users Seeing Other Companies' Cases

**Business problem:**
"A customer called us — they can see cases from a competitor company in our portal. We need to fix this immediately."

**Weak answer:** "Set OWD to Private on Case."

**Strong answer — immediate containment + root cause + fix:**

**Immediate (within 1 hour):**
1. Determine scope: query Cases visible to a test portal user — how many can they see?
2. If widespread: temporarily deactivate the Experience Cloud site (Emergency → Settings → Deactivate) to prevent further exposure
3. Notify security/legal team per incident response policy

**Root cause diagnosis:**
The most likely causes:
1. Case OWD is "Public Read Only" — all portal users see all cases
2. A Guest User Sharing Rule opens all cases to all guest users
3. A Sharing Set is too broadly configured (e.g., "All Users" instead of "Contacts of the same Account")
4. An Apex controller uses `without sharing` — returns all cases regardless of sharing

**Fix:**
1. Set Case OWD to "Private" (for external sharing)
2. Configure Sharing Set: only share Cases where `Case.AccountId = User.AccountId` (or `Case.ContactId = User.ContactId` for B2C)
3. Audit all portal Apex controllers — any `without sharing` must be replaced with `with sharing`
4. Test with multiple portal test users from different accounts — verify cross-company isolation

---

### Scenario 6: Multi-Cloud Design — Full Field Service Architecture

*(Full design covered in Section 13.5. For interview context, frame as:)*

**Structure your answer:**
- "Let me start with the data model, then walk through the main flows, then address error handling and deployment."
- Data model: Case → WorkOrder → ServiceAppointment → ServiceResource → ServiceTerritory
- Main flows: portal case creation → agent assignment → FSL dispatch → mobile completion → billing sync
- Error handling: PE retry, DLQ, webhook idempotency
- Deployment: metadata first, then integration config per environment

---

### Scenario 7: CPQ Edge Case — Discount Waterfall Not Applying Correctly

**Business problem:**
"Sales reps are saying their partner discount isn't being applied before the volume discount, so the math is wrong."

**Strong answer:**
CPQ applies discounts in the waterfall order configured in Setup → Products → Pricing. The fix:
1. Open the Pricing Procedure and verify the order of discount blocks
2. Check whether the partner discount and volume discount are in separate blocks or combined
3. If a Quote Calculator Plugin is installed, it may be overriding the standard waterfall — inspect the plugin's `onPricingFinished` method
4. Test with a controlled quote: one product, known quantity, known partner level — trace the math through each waterfall step using CPQ's price log (`SBQQ__PricingLog__c` if enabled)

---

### Scenario 8: Agentforce Action — Live Inventory Query

**Business problem:**
"Service agents need to tell customers if a part is in stock. Can the AI agent handle this?"

**Strong answer:**
Build a grounded Agentforce action:
```apex
@InvocableMethod(
    label = 'Check Part Inventory'
    description = 'Returns real-time inventory availability for a given part number. '
                + 'Use when a customer asks if a part is available or when to expect delivery.'
)
public static List<InventoryOutput> checkInventory(List<InventoryInput> inputs) {
    // Call external inventory system via Named Credential
    // Return: partNumber, quantityAvailable, estimatedDeliveryDays, warehouseLocation
}
```
The LLM receives the structured output and composes a natural language response: "Part P-1234 is available at our Dallas warehouse. Estimated delivery is 2 business days."

---

### Scenario 9: CI/CD Rollback — Production Broke After Deployment

**Business problem:**
"We deployed this morning. Case assignment rules stopped working. Sandboxes all pass. How do we recover?"

**Strong answer:**
1. **Immediate:** Check if the deployment included changes to the assignment rule criteria or the Apex trigger that fires after case insert. Roll back to the previous version of the trigger using a quick deploy from the last known-good commit
2. **Investigate:** Run a debug log on a Case insert in production — trace which step breaks (validation, trigger, flow, assignment rule)
3. **Root cause:** Often a sandbox → production data difference: an Assignment Rule references a Role or Profile that exists in production but not sandbox, causing the rule to fail silently
4. **Fix:** Update the assignment rule criteria to use data-independent conditions (field values, not record IDs or names that differ across envs)
5. **Prevention:** Include assignment rule metadata in the SFDX project and validate in CI; use `@TestSetup` in tests to create the role/profile references the assignment rule expects

---

### Scenario 10: Flow and Trigger Recursion — CPU Timeout in Production

**Business problem:**
"We deployed an after-save flow on Case last week. Now agents get CPU timeout errors when updating cases."

**Strong answer:**
The classic recursion scenario:
1. After-save Flow updates `Resolution_Time__c` on Case
2. That update re-fires the Case trigger
3. The trigger calls `AccountService.rollupCaseMetrics()` — doing a SOQL query
4. The rollup update fires another after-save flow (or the same one if conditions still match)
5. CPU exhausted

**Fix the Flow:**
Add a decision element at the start of the after-save flow:
- Check: `{!$Record.Resolution_Time__c} = {!$Record__Prior.Resolution_Time__c}`
- If true: immediately end (no change — don't proceed)
- This prevents the flow from running when the Case is updated by itself

**Fix the Trigger (defense in depth):**
Use the `RecursionGuard` pattern from `MockInterviewApexService.cls`:
```apex
// In CaseTriggerHandler.afterUpdate()
Set<Id> firstTimeIds = RecursionGuard.filterFirstTime(Trigger.newMap.keySet());
if (firstTimeIds.isEmpty()) return; // already processed these IDs in this transaction
```

**Prevention:**
Before deploying any after-save flow on a high-traffic object: trace the full execution path. Ask: "Does this flow update a field that re-triggers itself or any other automation?"


---

## Section 17 — Interview Q&A

### Basic Questions (10)

**Q1: What is a trigger and when does it fire?**
A trigger is Apex code that executes before or after DML operations (insert, update, delete, undelete) on a Salesforce record. `before` triggers fire before the record is committed — use them to validate or modify the triggering record's fields without an additional DML call. `after` triggers fire after the record is committed — use them when you need the record's `Id` (newly inserted records don't have an ID until after commit) or when you need to create/update related records.

**Q2: What is a governor limit and why does it exist?**
Governor limits are execution constraints Salesforce enforces per transaction: 100 SOQL queries, 150 DML statements, 10,000 DML rows, 10 seconds CPU time. They exist because Salesforce is multi-tenant — shared infrastructure where one org's runaway code would degrade all other orgs on the same pod. They are the contractual guarantee of shared infrastructure stability.

**Q3: What is the difference between a Profile and a Permission Set?**
A user has exactly one Profile. It controls object/field access, login hours, IP restrictions, page layout assignments, and the default app. A user can have many Permission Sets, each granting additive permissions. Profiles set the baseline; Permission Sets extend it. The modern best practice is Minimum Access profile + Permission Set Groups for all functional access.

**Q4: What is the difference between a before trigger and an after trigger?**
Before triggers fire before the record is written to the database — you can modify `Trigger.new` record fields directly, and changes are committed as part of the save. No additional DML statement is needed. After triggers fire after the record is written — the record has an `Id` and can be referenced by related records. Use after triggers when creating/updating related sObjects.

**Q5: What is a future method?**
A method annotated `@future` that executes asynchronously in a separate transaction. Use cases: HTTP callouts from a trigger (callouts are not allowed in synchronous trigger context), operations that need to run outside the calling transaction's governor limit context. Limitation: cannot pass SObjects as parameters (primitives only); cannot be chained; no monitoring.

**Q6: What is the difference between SOQL and SOSL?**
SOQL queries a single object and its related objects — like SQL SELECT. SOSL searches the full-text search index across multiple objects simultaneously. Use SOQL when you know exactly which object to query and have a selective WHERE clause. Use SOSL when implementing a search feature (user types a search term, you want results from Account, Contact, Case simultaneously).

**Q7: What is OWD (Org-Wide Default)?**
OWD sets the baseline access level for every record in an org. With Private OWD, users can only see records they own or that have been explicitly shared with them. With Public Read Only, everyone can read all records but only owners can edit. With Public Read/Write, everyone can read and edit. OWD is the floor — sharing rules and role hierarchy can only expand access above it, never restrict below it.

**Q8: What is the difference between a master-detail and a lookup relationship?**
Master-detail: the child requires a parent (parent field is mandatory); cascade delete (deleting parent deletes all children); child inherits parent's OWD sharing; Rollup Summary fields are supported; reparenting is not allowed by default. Lookup: the parent is optional; no cascade delete by default; the child has an independent sharing model; no native rollup support; reparenting is allowed.

**Q9: What is bulkification and why is it important?**
Bulkification means designing Apex to process a collection of records with a fixed number of SOQL and DML operations regardless of collection size. It is important because Salesforce batches DML in chunks of up to 200 records — a trigger designed for one record at a time will hit the 100-SOQL limit at 101 records. The pattern: query outside loops using `IN` clauses, collect updates in a list, DML once outside the loop.

**Q10: What is the scope of a static variable in Apex?**
A static variable in Apex persists for the lifetime of a single transaction. It is shared across all instances of the class within that transaction but is reset between test methods and between separate HTTP requests. This makes static variables useful for caching SOQL results within a transaction (see `AccountService.getRatingConfigs()`) and for recursion guards in triggers.

---

### Intermediate Questions (15)

**Q11: Describe the trigger framework in this repo and why it's better than logic in the trigger.**
`AccountTrigger` contains one line: `new AccountTriggerHandler().run()`. `TriggerHandler` (abstract base) has a `run()` method that routes to virtual `beforeInsert()`, `beforeUpdate()`, etc. methods. It also maintains a CMDT-driven bypass set — setting `Bypass__c = true` on a `TriggerSetting__mdt` record disables a handler without a deployment. `AccountTriggerHandler` extends `TriggerHandler` and dispatches to `AccountService` with clean Apex collections (no Trigger.new references below the handler layer). Benefits: testable service methods, deployable bypass controls, enforced separation of concerns.

**Q12: How does `Database.Stateful` work in batch Apex and what does it cost?**
Implementing `Database.Stateful` tells the batch framework to serialize the class's instance variables between `execute()` calls. Without it, each `execute()` gets a fresh instance with zeroed fields. Cost: the entire class instance is serialized to the database between chunks. Large instance variables (big lists, nested objects) cause heap overflow. Keep stateful data minimal — store IDs or counters, not full SObject lists. See `OpportunityRollupBatch.cls`.

**Q13: What is the difference between Platform Events and CDC?**
Platform Events: you define a custom schema and explicitly publish events via `EventBus.publish()` or `Database.insert()`. CDC: the platform automatically publishes events on every record create/update/delete/undelete for objects you enable it on. Platform Events are for custom business events; CDC is for replicating all data changes to external systems. Both guarantee at-least-once delivery and provide 3-day replay.

**Q14: When would you use `@wire` vs an imperative Apex call in LWC?**
Use `@wire` when: data is needed at component load, should auto-refresh when reactive properties change, and the method is `cacheable=true`. Use imperative when: the call is conditional (triggered by user action), the method modifies data (cannot be cached), you need explicit loading states, or you need `refreshApex` control. A common pattern: `@wire` for initial load, imperative for user-triggered search.

**Q15: What are Named Credentials and why should you use them?**
Named Credentials store endpoint URL and authentication details (OAuth tokens, JWT, Basic auth) outside of Apex code. They provide: (1) no credentials in source code — no risk of committing secrets to git, (2) token refresh handled transparently by the platform, (3) the same Apex code works across sandboxes — only the Named Credential configuration changes per environment. Access in Apex: `callout:MyNamedCred/path`.

**Q16: When should automation be in a Flow vs Apex?**
Default to Flow for: field updates on the triggering record (before-save), creating related records, sending notifications, simple conditional logic — admin-maintainable without deployments. Use Apex for: HTTP callouts, complex multi-object logic exceeding declarative limits, performance-sensitive bulk processing, patterns requiring Apex data structures (Maps, Sets for deduplication). The key question: "Can an admin maintain this without a developer?" If yes → Flow.

**Q17: Explain the full sharing model chain.**
OWD sets the baseline; role hierarchy grants managers upward visibility; sharing rules open access to criteria-based groups; manual sharing grants record-specific access; Apex managed sharing programs custom access with a RowCause; FLS controls field-level read/write access independent of record access; CRUD (object permissions) is the outermost gate — no sharing layer overrides a missing Read permission. FLS is additive across profile and permission sets — most permissive wins.

**Q18: What is partial DML and when do you use it?**
`Database.insert(list, false)` — `allOrNone=false` — processes each record independently. Records that succeed are committed; records that fail return error details in `Database.SaveResult`. Use it in batch jobs and migrations where processing partial successes is better than all-or-nothing failures. Always check `SaveResult.isSuccess()` and log failures. Use `allOrNone=true` (or the plain `insert` statement) when atomicity is required.

**Q19: What is the difference between Custom Metadata Type and Custom Settings?**
Custom Metadata: definition AND values are metadata — deploy together via SFDX. Packagable. Cannot have per-user/per-profile values. No DML limits for reads. Custom Settings (Hierarchy type): definition is metadata but values are data — values don't deploy, must be loaded separately. Support user/profile/org-level overrides via `getInstance()`. Use CMDT for config that must travel with code deployments; use Custom Settings for per-user or per-profile configuration that admins manage post-deployment.

**Q20: Unlocked Packages vs Change Sets — when to use each?**
Change sets are UI-driven, have no version history, no dependency management, and cannot be rolled back easily — suitable for simple single-org deployments. Unlocked Packages have explicit versioning, dependency graphs, installation keys, and are fully scriptable in CI/CD pipelines. Use change sets for emergency hotfixes in orgs not yet on SFDX. Use Unlocked Packages for any multi-developer, multi-environment project where repeatability and rollback matter.

**Q21: What are the security risks of `without sharing` in an Experience Cloud Apex controller?**
A portal Apex controller with `without sharing` runs as the system user — it can see ALL records in the org regardless of OWD, sharing rules, or the portal user's access level. A guest user calling this controller can read any record. This is a critical data leakage vulnerability. All portal controllers must use `with sharing` unless the data is deliberately public (e.g., a public knowledge article API). Even then, explicitly scope the query (`WHERE ContactId = :UserInfo.getContactId()`).

**Q22: What is a common Order of Execution gotcha?**
After-trigger DML triggers a new save cycle — the updated record goes back through steps 1–17 including before triggers and flows. Without a recursion guard, this creates an infinite loop. Common scenario: an after-update trigger updates a related field on the same record; the update re-fires the after-update trigger; CPU timeout after 2-3 cycles. Fix: `RecursionGuard.filterFirstTime(Trigger.newMap.keySet())` — skip records already processed in this transaction.

**Q23: How many Queueable jobs can you chain?**
From a synchronous context, you can enqueue up to 50 Queueable jobs. From within a Queueable's `execute()` method, you can enqueue exactly 1 child job. There is no hard limit on total chain length — a Queueable can keep chaining indefinitely. However, Salesforce monitors for infinite chains and may terminate a chain that shows no signs of completing.

**Q24: How does a Record Type affect automation?**
Record Types affect: picklist values available (field-level filtering), page layout assignment, and report filtering. For automation: validation rules can reference `RecordType.DeveloperName` to apply different rules per record type. Assignment rules can route records to different queues based on record type. Flow entry criteria can filter on `RecordType.DeveloperName`. A trigger cannot be scoped to a record type — all records of the object hit the trigger; filter by record type in code.

**Q25: How do you test async Apex?**
Wrap the async invocation in `Test.startTest()` / `Test.stopTest()`. The `stopTest()` call forces all async operations queued between `startTest` and `stopTest` to execute synchronously within the test. For Queueable: enqueue the job between `startTest/stopTest`; assert results after `stopTest`. For Batch: call `Database.executeBatch()` between `startTest/stopTest`. For `@future`: call the future method between `startTest/stopTest`.

---

### Advanced Questions (15)

**Q26: When would you design a multi-org architecture instead of a single org?**
When: data residency requirements force geographic separation; an acquisition has a completely different business model making data model consolidation more expensive than integration; regulatory isolation requires that different business units cannot access each other's data even with sharing rules. Single org is always preferred when possible — it eliminates the sync complexity, latency, and consistency challenges of multi-org. The cost of multi-org sync (eventual consistency, conflict resolution, duplicate management) is high.

**Q27: How do you handle 100M records on the Case object without degrading performance?**
Design upfront: (1) Always filter Case queries with a date range on an indexed field — no query should ever scan all 100M rows. (2) Request skinny tables for the 5-6 most-queried fields. (3) Archive records older than a defined retention period to an external data lake (use External Objects via Salesforce Connect or periodic exports to S3). (4) Push reporting to CRM Analytics — pre-aggregate daily metrics. (5) Never run a rollup that spans all 100M records — maintain denormalized summary fields updated incrementally.

**Q28: How do you make a callout from Batch Apex?**
Implement both `Database.Batchable<SObject>` and `Database.AllowsCallouts` on the class. The `execute()` method can then make callouts. However, you cannot use `Database.Stateful` AND `Database.AllowsCallouts` together (Salesforce limitation). Design choice: if you need callouts per record, use a small scope (50-100) to keep `execute()` fast. If you need to track state across execute calls, use a different pattern — batch with stateful tracking of IDs, then process callouts in a Queueable chain.

**Q29: How do you implement a cross-object rollup without a master-detail relationship?**
Pattern from `AccountService.rollupOpportunityMetrics()`: use `AggregateResult` with `GROUP BY` on the parent ID:
```apex
for (AggregateResult ar : [
    SELECT AccountId, COUNT(Id) cnt, SUM(Amount) total
    FROM Opportunity WHERE AccountId IN :accountIds AND IsWon = true
    GROUP BY AccountId
]) {
    // Update Account with cnt and total
}
```
Call from an Apex trigger on Opportunity (after insert/update/delete/undelete). This is the standard pattern for lookup rollups and is used by third-party packages like Declarative Rollup Summary Tool (DLRS).

**Q30: How do you design an Agentforce action for a live inventory query?**
Three design requirements: (1) `label` and `description` are written for the LLM — use natural language trigger phrases that match the types of questions users would ask; (2) Input uses `@InvocableVariable(required=true)` for the part number; (3) Output returns a `contextSummary` string in natural language that the LLM can include verbatim. The action calls the inventory system via a Named Credential. Graceful degradation: if the callout fails, return "Inventory data temporarily unavailable — please check the warehouse portal directly."

**Q31: How does Data Cloud unify customer profiles?**
Data Cloud's identity resolution processes data streams and applies matching rules (email, phone, device fingerprint, first/last name + address) to link records across sources into a single "Unified Individual." The resulting unified profile is the golden record — a single view of the customer across all touchpoints. Segment membership is calculated on unified profiles, so a customer who appears in Marketing Cloud as email "a@b.com" and in Salesforce CRM as Contact "A B" are merged into one profile before segmentation.

**Q32: How would you design a CI/CD pipeline for a 50-developer Salesforce team?**
Branch strategy: trunk-based development with short-lived feature branches (< 2 days). CI pipeline: validate every PR against a CI scratch org (parallel test runs, 15% coverage gate minimum). Merge to main triggers deploy to Developer Integration sandbox. Scheduled weekly release deploys to UAT sandbox; human approval gate before production. Delta deployment using `sfdx-git-delta` — only changed components deployed, not full org. Unlocked Packages for modular teams. Each package has its own pipeline — changes to Package A don't block deployment of Package B.

**Q33: How do you refactor a legacy trigger-heavy org without downtime?**
Phased approach: (1) Add CMDT bypass registry first — no logic changes, just the ability to disable triggers. (2) Extract logic to service classes one method at a time; new service method runs in parallel with old trigger logic until tested. (3) Once service method is validated in production with 100 real records, enable the bypass flag to disable the old trigger logic. (4) Remove old trigger code after 1 release cycle (keep old code around as fallback). Never big-bang refactor a production trigger.

**Q34: What is Platform Encryption's impact on SOQL?**
Fields encrypted with Probabilistic Encryption cannot be used in SOQL WHERE clauses at all — any filter on an encrypted field results in a table scan or query failure. Fields encrypted with Deterministic Encryption can be filtered but only for exact-match comparisons (no LIKE, no partial match). This means any field that needs to be searchable (email, phone, Account name) must use Deterministic Encryption, which is less secure than Probabilistic. Architects must evaluate which fields truly need encryption vs which just need FLS restriction.

**Q35: Design an event-driven integration between Salesforce and a legacy ERP.**
Use Platform Events as the decoupling layer:
- Salesforce → ERP: Salesforce after-save Flow publishes `OrderCreated__e`; a subscriber Lambda (or MuleSoft) receives the event, transforms to ERP format, calls ERP API. Retry: `EventBus.RetryableException` if ERP is temporarily unavailable.
- ERP → Salesforce: ERP calls Salesforce REST endpoint (Apex REST `@RestResource`) on order status change; Apex upserts by External ID.
- Idempotency: both directions include a `CorrelationId` checked against `ProcessedEvent__c` before processing.
- Monitoring: `Integration_Error_Log__c` records for all failures; Platform Event for ops alerting.

**Q36: How do you design FSL scheduling policy for a 200-technician field service operation?**
Key scheduling policy components: (1) Work Rule for skills matching — technician must have the skill required by the work order; (2) Work Rule for time windows — service appointment must fall within customer's requested window; (3) Work Rule for territory — technician must be in the same service territory as the work location; (4) Travel time optimization — minimize total travel time across all appointments in the territory; (5) Priority scoring — urgent work orders (SLA at risk) get higher scheduling priority. Balance: tighter constraints improve SLA compliance but reduce optimization flexibility. Start with skill + territory as hard constraints; make time windows soft (preferred, not required) for non-SLA-critical appointments.

**Q37: How do you debug a CPQ pricing waterfall issue?**
Enable the CPQ Pricing Log in Setup → Installed Packages → CPQ Settings → Pricing. This adds a `SBQQ__PricingLog__c` long text area to each Quote Line with a step-by-step trace of every calculation. Create a test quote with the problematic product and discount combination, save it, then read the pricing log. Each step shows the price before and after applying the discount rule. Compare the order of steps to the expected waterfall sequence. The log will show exactly where the discount was applied and in what order.

**Q38: How do you enforce FLS in a bulk Apex REST endpoint?**
```apex
@RestResource(urlMapping='/api/v1/accounts/*')
global with sharing class AccountRestResource {
    @HttpGet
    global static void getAccounts() {
        List<Account> rawResults = [SELECT Id, Name, AnnualRevenue, Phone
            FROM Account WITH USER_MODE LIMIT 200];
        // Strip any fields the running user can't read
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.READABLE, rawResults
        );
        RestContext.response.responseBody = Blob.valueOf(
            JSON.serialize(decision.getRecords())
        );
    }
}
```
Key points: `with sharing` ensures record-level access; `WITH USER_MODE` in SOQL enforces FLS at query time; `stripInaccessible` removes any fields that shouldn't have been returned.

**Q39: How do you design a full field service company Salesforce architecture?**
See Section 13.5. Key talking points for interview: lead with the data model (objects and relationships), then the main user journeys (customer → portal → case → work order → dispatch → completion → billing), then error handling (PE retry, DLQ), then deployment strategy (metadata first, integration config per environment). Always mention: how OmniChannel routes cases, how FSL Optimizer dispatches appointments, how the portal uses `with sharing` for security.

**Q40: How do you handle a production outage caused by a governor limit breach?**
Immediate response: (1) Identify the transaction that's breaching — check Setup → Apex Jobs, Debug Logs with limit exceptions. (2) If it's a trigger: use the CMDT bypass registry to disable the handler immediately (no deployment needed). (3) If it's a batch job: abort via `System.abortJob()` or in Setup → Apex Jobs. (4) For root cause: the breach is almost always a code path that scales with data volume (SOQL in loop, trigger without bulkification). Fix in a scratch org, validate with 200 records, deploy with fast validation. Post-incident: add a limit-check in the offending code path; add a bulk test at 200 records to prevent regression.


---

## Section 18 — Common Mistakes and Anti-Patterns

### 18.1 Logic in Trigger File (No Handler, No Service)

**What it is:** Business logic, SOQL, and DML written directly inside the trigger file — no abstraction layer.

**Why it fails in production:**
- Cannot be bypassed during data migrations without a deployment
- Cannot be unit-tested in isolation — every test requires a full trigger context
- Multiple developers editing the same trigger file causes constant merge conflicts
- Adding a second trigger on the same object creates unpredictable execution order

**Correct approach:** One trigger file per object (one line: `new AccountTriggerHandler().run()`). All logic in handler → service → domain layers as implemented in this repo.

---

### 18.2 SOQL in Loops

**What it is:** A SOQL query inside a `for` loop, executing once per iteration.

**Why it fails:** `System.LimitException: Too many SOQL queries: 101` at exactly 101 iterations. In a trigger context, this means the operation fails entirely and no records in the batch are saved.

**Correct approach:**
```apex
// ❌ SOQL in loop
for (Account acc : accounts) {
    List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
}

// ✅ Single bulk query + Map pattern
Map<Id, List<Contact>> contactMap = new Map<Id, List<Contact>>();
for (Contact c : [SELECT Id, AccountId FROM Contact WHERE AccountId IN :accountIds]) {
    if (!contactMap.containsKey(c.AccountId)) contactMap.put(c.AccountId, new List<Contact>());
    contactMap.get(c.AccountId).add(c);
}
```

---

### 18.3 DML in Loops

**What it is:** An `insert`, `update`, or `delete` statement inside a `for` loop.

**Why it fails:** `System.LimitException: Too many DML statements: 151` at 151 iterations. Each DML statement in the loop also fires triggers on the affected object — causing compounding governor limit consumption.

**Correct approach:** Collect all records in a list inside the loop; call DML once outside the loop.

---

### 18.4 Hardcoded IDs, Profile Names, Record Type Names

**What it is:** Salesforce IDs, profile names, or record type developer names stored as string literals in Apex or Flows.

**Why it fails in production:**
- Salesforce IDs differ between orgs (sandbox vs production vs scratch org) — hardcoded ID never refers to the same record
- Profile names and record type names are text values — they change when admins rename them

**Correct approach:**
```apex
// ❌ Hardcoded ID
if (acc.OwnerId == '005D000000IqhVIIAZ') { ... }

// ✅ Query by meaningful field
User systemUser = [SELECT Id FROM User WHERE Username = :Label.System_User_Username LIMIT 1];

// ❌ Hardcoded record type name
if (acc.RecordType.DeveloperName == 'CustomerAccount') { ... }

// ✅ Query once, cache in static variable
Id custRTId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
    .get('CustomerAccount').getRecordTypeId();
```

---

### 18.5 Missing Bulk Tests and No Negative Test Coverage

**What it is:** Test classes that only test with one record and only test the happy path.

**Why it fails:** A single-record test passes; the same code breaks at 101 records due to a SOQL-in-loop hidden in a called method. Negative tests not written means error paths are untested — a bug in the validation logic is undetected until production.

**Correct approach:** Every trigger test must include a 200-record bulk test. Every validation/error path must have a test that exercises the rejection. See `AccountServiceTest.cls` pattern.

---

### 18.6 Process Builder Still in Use (Deprecated Path)

**What it is:** Continuing to build new automation in Process Builder when Salesforce has announced its retirement.

**Why it fails:** Process Builder is in maintenance mode — no new features, and Salesforce plans to eventually retire it. New automations built in PB will require migration before retirement. Existing PBs should be converted to Record-Triggered Flows during any automation refactor.

**Correct approach:** All new automation in Record-Triggered Flows. Use Migration Tool for PB → Flow conversion of existing automations.

---

### 18.7 Ignoring Async Governor Limits

**What it is:** Treating a Batch Apex `execute()` method as if it has synchronous limits — writing code that assumes 100 SOQL, 6MB heap, 10s CPU.

**Why it fails:** Async limits are higher (200 SOQL, 12MB heap, 60s CPU) but still finite. A developer who writes a complex `execute()` assuming "batch has no limits" will eventually hit the 60s CPU timeout as data volume grows.

**Correct approach:** Design batch `execute()` with the same discipline as synchronous code. Monitor via `Limits.getCpuTime()`. Keep scope small enough that each `execute()` completes in < 30s under full data load.

---

### 18.8 Callouts in Synchronous Triggers Without Queueable

**What it is:** Calling `new Http().send(req)` directly inside a trigger's `execute()` method.

**Why it fails:** Salesforce throws `System.CalloutException: You have uncommitted work pending` if you attempt a callout after DML has occurred in the same transaction. Triggers fire after the record is written (after-triggers) or are in the middle of a transaction (before-triggers) — both are disallowed for callouts.

**Correct approach:**
```apex
// In after trigger:
System.enqueueJob(new AccountSyncQueueable(new List<Id>{ acc.Id }, 0));
// The Queueable runs in a new transaction with no uncommitted work — callout is allowed
```

---

### 18.9 SeeAllData=true in Test Classes

**What it is:** Using `@IsTest(SeeAllData=true)` to allow test methods to access real org data.

**Why it fails:** Tests that depend on real org data pass in the org where they were written but fail in other orgs (CI scratch org, client's org, new sandbox) where that data doesn't exist. It also creates brittle tests that fail when an admin deletes a record the test depends on.

**Correct approach:** Create all test data in `@TestSetup` or at the start of each test method using `TestDataFactory`. The only acceptable use of `SeeAllData=true` is for standard price book access (historical limitation — now solvable with `Test.getStandardPricebookId()`).

---

### 18.10 Missing Fault Paths in Flows

**What it is:** A Flow that performs DML or calls an Apex action with no fault path connector.

**Why it fails:** When the action fails (network error, validation failure, governor limit), the Flow throws an unhandled exception. The record save rolls back silently. The user sees "An unexpected error has occurred" with no context. The error is not logged anywhere.

**Correct approach:** Every DML element and every Apex action must have a fault path. Minimum fault path: Create `Error_Log__c` record with `{!$Flow.FaultMessage}` and the triggering record ID; send an alert to the ops team.

---

### 18.11 DML Inside Flow Loops

**What it is:** An Update Records or Create Records element placed inside a Loop element in a Flow.

**Why it fails:** Each loop iteration fires one DML statement. At 151 iterations: `DML limit exceeded`. In a bulk record-triggered context (200 records firing the flow), even a single DML inside a loop for each record will breach limits quickly.

**Correct approach:** Inside the Loop, add records to a collection variable. After the Loop ends, call Update/Create Records once with the entire collection.

---

### 18.12 without sharing in Portal Apex Controllers

**What it is:** Using `public without sharing class` in an Apex controller exposed to Experience Cloud.

**Why it fails:** The running user in portal context is the portal user — often with very limited access. `without sharing` bypasses their sharing restrictions entirely and returns ALL records. A guest user running `without sharing` Apex can see every record in the org.

**Correct approach:** All portal controllers: `public with sharing class`. Scope queries explicitly: `WHERE ContactId = :UserInfo.getContactId()`. If system-level access is needed for a specific operation, create a separate `without sharing` inner method with a documented security review, called only from a `with sharing` outer method that validates the input.

---

### 18.13 Not Enforcing FLS in Custom Apex REST Endpoints

**What it is:** An Apex REST endpoint that returns field values without checking whether the calling user can see those fields.

**Why it fails:** A user with a custom permission set that restricts `AnnualRevenue` can still receive `AnnualRevenue` values from the endpoint because Apex doesn't auto-enforce FLS. This is a data leakage vulnerability.

**Correct approach:** Use `WITH USER_MODE` in all queries. Add `Security.stripInaccessible(AccessType.READABLE, results)` before serializing the response.

---

### 18.14 Deploying Without Destructive Changes on Deleted Fields

**What it is:** Deleting a custom field or class in a sandbox and deploying the rest of the package without including the deletion in a `destructiveChanges.xml`.

**Why it fails:** Salesforce does NOT automatically delete components that are missing from a deployment. The deleted field/class remains in production, potentially with stale data or broken references. Worse — if the class was referenced by a Flow that is still active, the Flow fails.

**Correct approach:** Always audit deletions. Generate `destructiveChanges.xml` for any component that needs to be removed from production. Test the destructive deploy in a full-copy sandbox first.

---

### 18.15 Infinite Loop Between After-Save Flow and Trigger

**What it is:** An after-save Flow updates Field A on the triggering record; the trigger fires again on that update; the trigger runs logic that causes the after-save Flow's entry condition to be true again.

**Why it fails:** CPU timeout after 2-3 cycles. The transaction never completes; all DML is rolled back; the original record save fails.

**Correct approach:**
- Flow: add a decision element checking `{!$Record.FieldA} != {!$Record__Prior.FieldA}` — only proceed if the field actually changed
- Trigger: use `RecursionGuard.filterFirstTime()` to skip records already processed in this transaction

---

### 18.16 Hardcoded Record IDs in Flows

**What it is:** Using a literal 18-character Salesforce ID in a Flow variable or assignment element.

**Why it fails:** IDs are org-specific. The ID for the "Default Queue" in sandbox is different from its ID in production. The Flow works in sandbox and fails silently (or assigns to the wrong record) in production.

**Correct approach:** Use a Get Records element to look up the record by a stable, meaningful field (DeveloperName, Name, ExternalId). Store the ID from the lookup result. This works across all orgs.

---

### 18.17 Over-Engineering Small Orgs with Full Enterprise Pattern Stack

**What it is:** Applying a full 4-layer trigger framework, Unit of Work, Strategy patterns, and Selector layer to a 3-object, 1-developer org.

**Why it fails:** Every change requires modifying 4+ files. Context switching overhead dominates delivery. Junior developers on the team can't navigate the abstraction layers. The maintenance burden exceeds the benefit.

**Correct approach:** Match complexity to the problem. For simple orgs: trigger → one service class. Add layers only when the pain they solve is real: second developer → handler layer; multiple triggers on one object → framework; reusable DML → unit of work.

---

### 18.18 Not Using Static Caching for Repeated SOQL

**What it is:** Calling a SOQL query or `Schema.getGlobalDescribe()` multiple times in the same transaction.

**Why it fails:** Each call consumes one of the 100 SOQL slots. `Schema.getGlobalDescribe()` is particularly expensive — it builds a map of all sObject types in the org. Calling it 10 times in a complex trigger + flow transaction can exhaust the SOQL limit before user code runs.

**Correct approach:** Static lazy-init cache pattern from `AccountService.getRatingConfigs()` — first call queries, subsequent calls return the cached map. Same for `Schema.getGlobalDescribe()` as shown in `WeakAreaRevisitService.getGlobalDescribe()`.

---

### 18.19 Not Checking Database.SaveResult on Partial DML

**What it is:** Calling `Database.insert(list, false)` (partial DML) and not inspecting the `SaveResult[]` for failures.

**Why it fails:** Failed records are silently dropped. No error log is created. The operation appears to succeed from the caller's perspective even though a subset of records were not saved.

**Correct approach:** Always iterate `SaveResult[]` after partial DML. For each failed result, create an `Error_Log__c` record or publish a Platform Event. Pattern from `AccountService.logSaveErrors()` in this repo.


---

## Section 19 — Revision Cheat Sheet

### Governor Limits: Sync vs Async

| Limit | Synchronous | Async (Future/Queueable) | Batch execute() | Scheduled |
|---|---|---|---|---|
| SOQL queries | 100 | 200 | 200 | 200 |
| SOQL rows returned | 50,000 | 50,000 | 50,000 | 50,000 |
| DML statements | 150 | 150 | 150 | 150 |
| DML rows | 10,000 | 10,000 | 10,000 | 10,000 |
| CPU time | 10,000 ms | 60,000 ms | 60,000 ms | 60,000 ms |
| Heap size | 6 MB | 12 MB | 12 MB | 12 MB |
| Callouts | 100 | 100 | 100 | 100 |
| Future calls per tx | 50 | — | 0 | — |
| Queueable jobs enqueued | 50 | 1 (chain) | 1 | 1 |
| Email invocations | 10 | 10 | 10 | 10 |

---

### Async Apex Decision Table

| Feature | @future | Queueable | Batch | Scheduled |
|---|---|---|---|---|
| HTTP callouts | ✅ (callout=true) | ✅ | ✅ | ✅ |
| Pass SObjects | ❌ (primitives only) | ✅ | ✅ | ✅ |
| Chain jobs | ❌ | ✅ (1 child) | ❌ | ❌ |
| Stateful | N/A | ✅ (instance vars) | ✅ (Database.Stateful) | N/A |
| Monitoring | AsyncApexJob | AsyncApexJob | AsyncApexJob + FlexQueue | CronTrigger |
| Max active | 50/tx | 50 enqueued | 5 concurrent | 100 scheduled |
| Best use case | Fire-and-forget callout | Chained processing | Large data volumes | Recurring jobs |

---

### Order of Execution (17 Steps)

1. Load original record from database
2. Load new field values from save request
3. **Before triggers** fire
4. System validation (required fields, format, max length)
5. Write to database (not committed)
6. **After triggers** fire
7. Assignment rules
8. Auto-response rules
9. **Workflow rules** (field updates re-run steps 3-6 once)
10. Processes (Process Builder)
11. Escalation rules
12. **Record-triggered Flows** (after-save)
13. Entitlement rules
14. Roll-up summary field calculations
15. Criteria-based sharing evaluation
16. **Commit** to database
17. Send queued email alerts

---

### Security Model Quick Reference

```
OWD          → Sets the floor (Private / PubReadOnly / PubReadWrite / Controlled by Parent)
Role Hierarchy → Managers see records owned by subordinates (upward only)
Sharing Rules  → Opens access to groups of records for groups of users (criteria/owner)
Manual Sharing → Individual user grants access on a specific record
Apex Sharing   → Programmatic share with custom RowCause (survives ownership change)
FLS            → Controls which fields a user can read/edit (profile + PS union = max permissive)
CRUD           → Gate: no sharing layer overrides a missing object-level Read permission
```

---

### Flow Types Reference

| Type | Trigger Event | Use Case | Key Limitation |
|---|---|---|---|
| Record-Triggered (Before Save) | Record save, before commit | Field updates on triggering record | No DML on other records |
| Record-Triggered (After Save) | Record save, after commit | Create/update related records | No callouts (use Apex action) |
| Screen Flow | User action | Guided user process with UI | Must be launched by a user |
| Auto-launched | Apex, API, PB | Background logic with no UI | Cannot be directly scheduled |
| Schedule-Triggered | Cron | Nightly batch on record sets | No single-record context |
| Platform Event-Triggered | PE published | React to business events | At-least-once; must be idempotent |

---

### LWC Lifecycle Hooks Reference

| Hook | When It Fires | Common Use |
|---|---|---|
| `constructor()` | Component created | Initialize primitive properties; no DOM access |
| `connectedCallback()` | Inserted into DOM | Subscribe to LMS, start data loads, add event listeners |
| `renderedCallback()` | After every render | One-time DOM access (guard with boolean flag) |
| `disconnectedCallback()` | Removed from DOM | Unsubscribe LMS, clear timers, remove listeners |
| `errorCallback(error, stack)` | Child component error | Display error UI, log to Apex |

---

### Design Patterns One-Liner Table

| Pattern | What It Solves | Summary |
|---|---|---|
| Trigger Handler | Logic in trigger files | Route to handler → service → domain; CMDT bypass |
| Selector | SOQL scattered across codebase | All queries for an object in one class |
| Service Layer | Business logic mixed with trigger context | Stateless methods accepting List<SObject> |
| Domain Layer | Business rules mixed with DML | Pure in-memory validation, no SOQL/DML |
| Factory | Coupling to concrete SObject types | Create SObjects by API name at runtime |
| Strategy | Growing if/else for behavior variations | Interface + CMDT-registered implementations |
| Unit of Work | DML scattered across service calls | Collect all changes; one commit at end |
| Dependency Injection | Hard to test — real services in production code | `@TestVisible static Interface field` override in test |

---

### sf CLI Commands Reference

| Command | Purpose | Example Flag |
|---|---|---|
| `sf project deploy start` | Deploy metadata to org | `--source-dir force-app --target-org myorg --wait 10` |
| `sf project retrieve start` | Pull metadata from org | `--source-dir force-app --target-org myorg` |
| `sf apex run test` | Run Apex tests | `--class-names MyTest --result-format human --wait 10` |
| `sf org create scratch` | Create scratch org | `--definition-file config/scratch-def.json --alias dev1` |
| `sf package version create` | Create package version | `--package MyPkg --installation-key abc --wait 20` |
| `sf apex run` | Execute anonymous Apex | `--file scripts/anon.apex --target-org myorg` |
| `sf data import tree` | Import test data | `--files data/accounts.json --target-org myorg` |
| `sf project deploy validate` | Validate without deploying | `--source-dir force-app --test-level RunLocalTests` |

---

### Common Interview Red Flags (Junior Thinking Signals)

- "I'll just add another trigger" — no awareness of framework or execution order
- "Let me use SeeAllData=true so I don't have to create test data" — test quality signal
- "I'll hardcode the queue ID" — no understanding of cross-environment differences
- "Batch Apex has no limits" — confusion of async limit values with no limits
- "I'll query in the loop because the list is usually small" — performance at scale not considered
- "Process Builder is fine — it still works" — unaware of deprecation path
- "I'll use without sharing because the portal user doesn't have access" — security vulnerability framed as a solution
- "I'll fix the recursion by catching the exception" — treating the symptom not the cause
- "I tested it with one record and it worked" — no bulk testing awareness

---

### Saikiran's Stack Mapped to Interview Focus Areas

| Your Experience | Likely Deep-Dive Topics | Key Talking Points |
|---|---|---|
| Service Cloud (9 years) | Case lifecycle, Entitlements, Omni-Channel, Assignment Rules | Routing design, SLA enforcement, Knowledge deflection |
| FSL | Work Orders, Service Appointments, Territory Management, Scheduling Policy | Dispatcher Console, mobile offline, Apex hooks in FSL |
| Experience Cloud / Portal | Guest user security, LWR vs Aura, Sharing Sets, Portal Apex design | `with sharing` in portal, Sharing Set config, CSP restrictions |
| CPQ (Conga) | Pricing waterfall, bundles, approval workflow, contract generation | Waterfall order, Quote Calculator Plugin, order handoff to ERP |
| REST APIs / Integrations | Named Credentials, OAuth flows, error handling, idempotency | Webhook receiver, retry pattern, DLQ, correlation IDs |
| Azure DevOps / CI/CD | Pipeline design, delta deployment, test gates, approval gates | sfdx-git-delta, `sf project deploy validate`, SFDX project structure |
| Apex / LWC | All of Section 4 + Section 9 — these are your deepest strengths | TriggerHandler pattern, bulkification, `@wire` vs imperative |


---

## Section 20 — How to Answer Like an Architect

### 20.1 Answer Structure: Problem → Context → Approach → Trade-offs → Decision

Every technical answer from an architect-track candidate should follow this structure:

**Problem:** Restate what you're solving (brief — shows you understood the question)
**Context:** What factors shape your answer (data volume, team size, org complexity, SLA requirements)
**Approach:** Your recommended solution with enough detail to show you've built it before
**Trade-offs:** What you're giving up with this approach — architects always acknowledge trade-offs
**Decision:** Why this approach is correct given the context — not "it's the best," but "for this scenario, it's the right balance"

**Example (Question: "How would you handle a callout from a trigger?"):**
- Problem: "Callouts aren't allowed in synchronous trigger context after DML."
- Context: "For a trigger on Account after insert that needs to call an external CRM."
- Approach: "Enqueue a Queueable from the after trigger. The Queueable runs in a new transaction with no uncommitted work, so the callout is allowed. I'd pass the Account IDs to the Queueable, not the SObjects, to stay within future method parameter limits."
- Trade-offs: "The callout is asynchronous — the external system may not receive the data immediately. For near-real-time requirements, we'd need to handle the case where the Queueable is delayed by the FlexQueue."
- Decision: "Queueable is the right choice here — it supports callouts, allows chaining for retry logic, and is monitorable via AsyncApexJob."

---

### 20.2 Showing Architect Thinking in a Coding Question

When given a coding question, talk through your thinking before writing code:

1. **"Let me clarify the scale"** — how many records, how often does this run, is this synchronous or can it be async?
2. **"My first concern is bulkification"** — acknowledge the batch context before writing a single line
3. **"I'll design for failure"** — mention error handling and partial DML before being asked
4. **"There's a trade-off between X and Y"** — show awareness of architectural alternatives

The interviewer is watching HOW you think, not just WHAT you write. Narrating your decisions signals maturity.

---

### 20.3 Weak vs Strong Answers

**Question: "How do you prevent trigger recursion?"**

Weak answer: "Use a static boolean set to true after the trigger runs."

Strong answer: "The simplest approach is a static `Set<Id> processedIds` — on first entry, add the record's ID; on re-entry, if the ID is already in the set, skip processing. This is more precise than a boolean flag because it handles partial batches correctly: if 200 records come in and 50 are re-triggered, only the 50 that were already processed are skipped, not all 200. In this repo's `RecursionGuard` pattern, I also expose a `@TestVisible reset()` method to clear the static state between test methods, which prevents test pollution."

---

**Question: "What is the difference between a lookup and a master-detail?"**

Weak answer: "Master-detail has cascade delete and rollup fields."

Strong answer: "The behavioral differences split across five areas: parent requirement (lookup is optional; master-detail is mandatory), cascade delete (master-detail deletes children when parent is deleted — this is a dangerous default at scale), reparenting (lookup allows it; master-detail locks it after insert unless explicitly enabled), rollup summary (only master-detail supports native COUNT/SUM/MIN/MAX), and sharing (master-detail child inherits parent's OWD; lookup child has its own independent sharing model). For schema design, I use master-detail when I want the child to be meaningless without the parent and I want rollup fields. I use lookup when the relationship is optional, the child needs independent sharing, or I don't want cascade delete risk."

---

**Question: "How would you architect a multi-org data sync?"**

Weak answer: "Use integration middleware to sync the data."

Strong answer: "The core design is External ID + upsert + change fingerprint. Both orgs get a `LegacyId__c` external ID field. The source org publishes a Platform Event on every relevant change. The target org subscribes and upserts by external ID — this is idempotent by design. The fingerprint (SHA-256 hash of key fields) prevents unnecessary DML when a record arrives unchanged — important for high-volume syncs where most records haven't changed. The subscriber uses `EventBus.RetryableException` for transient failures. After 9 retries, the event goes to a `DeadLetterMessage__c` record for ops visibility. The design is eventually consistent — there's a short window between publish and consume where the orgs are out of sync, which is acceptable for most CRM use cases."

---

### 20.4 Handling a Question You Don't Know

**Do:**
1. Say what you DO know that's related: "I haven't configured Einstein Vision specifically, but I have used Einstein Language API for sentiment analysis — the authentication and callout pattern is the same."
2. Reason aloud from first principles: "I'd expect it to follow the same pattern as other Einstein APIs — a Named Credential, a POST request with the image payload, and a response with probabilities."
3. Offer to explore: "I'd want to check the current documentation since the API evolved significantly with Winter '26."

**Don't:**
- Bluff — interviewers know the answer and will probe deeper
- Go silent — quiet signals knowledge gap more than a structured "I'm not certain, but here's my thinking"
- Say "I've never used that" and stop — always bridge to something you do know

---

### 20.5 Pivoting from Your Experience to a Strong Answer

Saikiran's FSL + Service Cloud + integration background maps to every major Salesforce interview topic:

| Question Topic | Your Pivot |
|---|---|
| "Describe a complex integration" | "In our FSL implementation, we synced ServiceAppointment status changes to an external billing system via Platform Events. The subscriber Queueable made a REST callout to the billing API. I implemented HMAC signature validation and a dedup check against ProcessedWebhook__c to handle retries." |
| "How did you handle governor limit challenges?" | "On a nightly Account sync of 400K records to our CRM, I implemented cursor-based batch pagination instead of OFFSET and pre-aggregated the delta using a LastModifiedDate watermark — this reduced the batch from full-table to incremental, cutting run time from 4 hours to 20 minutes." |
| "Tell me about your DevOps experience" | "I set up our Azure DevOps pipeline with three stages: PR validation against a CI scratch org, test gate requiring 80% coverage, and delta deployment to production using sfdx-git-delta. This replaced manual change sets and reduced deployment errors by eliminating human selection of changed components." |
| "How do you approach portal security?" | "In our Experience Cloud FSL portal, every Apex controller is `with sharing`. I implemented a Sharing Set scoped to ContactId = CurrentUser.ContactId so portal users only see their own work orders. I audited all controllers for `without sharing` usage and found two legacy classes that were exposing unintended data — both were corrected before the site went live." |

---

### 20.6 Communication Style

**When to draw a diagram:** Any question involving data flow, system architecture, or multi-object relationships. Say "Let me sketch this out" and draw boxes + arrows. A physical diagram signals architect-level thinking and gives the interviewer a shared artifact to reference.

**When to write pseudocode:** When describing an algorithm, a pattern, or a solution with multiple steps. Pseudocode shows structure without syntax distractions. Write it on the whiteboard before jumping to full Apex.

**When to ask clarifying questions:** Before answering any system design question. Questions to ask:
- "How many records are we talking about — hundreds, millions?"
- "Does this need to be real-time or can it be eventually consistent?"
- "Are we designing for a new org or retrofitting an existing one?"
- "Is there a compliance or security requirement I should account for?"

Asking these questions signals you're thinking like an architect, not rushing to a solution.

**Phrases that signal senior thinking:**
- "The trade-off here is..."
- "At scale, the concern would be..."
- "I'd design for failure by..."
- "Before I answer, let me understand the data volume..."
- "The right answer depends on whether we need real-time or eventual consistency..."

**Phrases that signal junior thinking:**
- "I would just use a formula field" (no awareness of limitations)
- "Batch Apex handles it" (no specifics on scope, state, retry)
- "I'd test it manually" (no automated testing discipline)
- "It works on my sandbox" (no multi-environment awareness)


---

## Section 21 — Debugging and Failure Scenarios

### 21.1 Trigger Recursion: CPU Timeout in Production, Works in Sandbox

**Symptoms:** Production CPU timeout errors on Case updates during business hours. Sandbox passes all tests. Users report "something's slow" before the actual timeout starts appearing.

**Root cause:** An after-save flow or after-update trigger updates a field on the Case record. This update re-triggers the same trigger and/or flow. Each re-entry processes the same records again, consuming CPU cumulatively. In sandbox, the test data is minimal (1-2 records); in production, a batch update of 50+ cases causes enough re-entries to exhaust the 10-second CPU limit.

**Fix:**
1. In the after-save flow: add a decision element comparing `{!$Record.FieldX} != {!$Record__Prior.FieldX}` — exit immediately if the field hasn't changed
2. In the trigger: use `RecursionGuard.filterFirstTime(Trigger.newMap.keySet())` from `MockInterviewApexService.cls` — skip records already processed in this transaction
3. Deploy the flow fix first (no deployment needed if done in Setup); deploy the trigger fix next

**Prevention:** Before deploying any after-save flow on a high-traffic object, trace every field update the flow makes and ask: "Does updating this field cause this flow's entry condition to be true on the next trigger cycle?"

---

### 21.2 Batch CPU Timeout: execute() Breaching 10 Seconds

**Symptoms:** `System.LimitException: Apex CPU time limit exceeded` in `AsyncApexJob.ExtendedStatus` for a batch job. Job processes the first few batches successfully then fails on a specific chunk.

**Root cause:** The `execute()` method is performing complex processing — nested loops, String manipulation, repeated Schema calls — that scales with the record count per chunk. As data grows or a specific subset of records triggers heavier logic paths, the 60-second async CPU limit is breached.

**Diagnosis:**
```apex
// Add CPU monitoring at chunk boundaries
public void execute(Database.BatchableContext bc, List<Case> scope) {
    System.debug('CPU at start of execute: ' + Limits.getCpuTime() + 'ms');
    // ... processing ...
    System.debug('CPU at end of execute: ' + Limits.getCpuTime() + 'ms');
}
```

**Fix:**
1. Reduce scope size from 200 to 50-100 — each execute() processes fewer records, staying within limits
2. Move expensive operations outside the inner loop (cache Schema describes statically, pre-compute Maps before the loop)
3. If specific records are inherently more expensive to process: identify them in the start() query and filter them to a separate batch run with a smaller scope

**Prevention:** CPU-profile batch jobs in a full-copy sandbox with production-volume data before go-live.

---

### 21.3 REST Callout Returning 200 but Data Not Updated in Target System

**Symptoms:** No errors in Apex logs. HTTP response status = 200. But the target system doesn't reflect the update. No error in `Integration_Error_Log__c`.

**Root cause diagnosis (in order of likelihood):**
1. **Response body parsing error:** The 200 response contained a business-level error in the body (`{"status":"error","message":"duplicate key"}`) but Apex only checked the HTTP status code, not the body content
2. **Async processing in target:** The target system accepted the request and returned 202 Accepted — the actual write is async on their side; check again 30 seconds later
3. **Field mapping error:** The JSON payload has the right structure but a field name mismatch — target silently ignores unknown fields
4. **Authentication token expired mid-batch:** Token was valid when the batch started; expired 2 hours in; all subsequent calls returned 200 with an auth error body

**Fix:**
```apex
HttpResponse res = new Http().send(req);
if (res.getStatusCode() == 200 || res.getStatusCode() == 202) {
    // ✅ Also validate the response body for business-level errors
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    String status = (String) parsed.get('status');
    if ('error'.equalsIgnoreCase(status)) {
        throw new CalloutException('Business error in 200 response: ' + parsed.get('message'));
    }
}
```

---

### 21.4 Flow Bulk Failure: Works in Single-Record Context, Fails in Bulk Data Load

**Symptoms:** Flow works when a single record is updated via the UI. When a Data Loader bulk update runs, the flow throws an error for some records and succeeds for others. Logs show "Get Records returned no rows."

**Root cause:** The flow has a `Get Records` element inside a loop (or the `Get Records` result is used without a null check). In single-record context, the record retrieved always exists. In bulk context, 200 records arrive simultaneously; the first `Get Records` call with all 200 AccountIds finds records for 195 of them; 5 are null — the next element tries to access a field on a null variable and throws.

**Fix:**
1. Add a Decision element after every Get Records: "Was the record found? → if null → skip/log and continue"
2. Move Get Records outside the loop and filter by collection to get all related records in one query
3. Review the flow's fault path — make sure failures create an error log with the specific record ID

**Prevention:** Test every record-triggered flow with a bulk Data Loader update of 200 records in a sandbox before deploying.

---

### 21.5 Deployment Failure: Deployment Succeeds but Flows Deactivated Post-Deploy

**Symptoms:** `sf project deploy` returns success. Users report that record-triggered flows stopped firing. On investigation, the flows are inactive in production.

**Root cause:** The flow metadata files in the deployment package have `<status>Draft</status>` instead of `<status>Active</status>`. When deployed, Salesforce honors the metadata status — Active flows are deployed as Draft.

**Fix:**
1. Check the flow `.flow-meta.xml` files: ensure `<status>Active</status>` is set
2. In the SFDX project, retrieve the flow from an active sandbox to get the correct status
3. Re-deploy with corrected flow metadata

**Prevention:** Add a CI check: after deployment, query the org for any inactive flows that should be active:
```bash
sf data query --query "SELECT DeveloperName, Status FROM Flow WHERE Status = 'Draft'" --target-org prod
```
Fail the pipeline if any expected flows are Draft.

---

### 21.6 Governor Limit Breach in Production: 101 SOQL Error from Overnight Batch

**Symptoms:** The nightly `AccountRatingBatch` succeeds for months. One morning, `AsyncApexJob` shows `Status = Failed`, `ExtendedStatus = "System.LimitException: Too many SOQL queries: 101"`. No code was changed.

**Root cause:** The data volume crossed a threshold. The batch's `execute()` calls `AccountService.getRatingConfigs()` — which was correctly cached with a static variable. But a new after-update trigger was deployed by a different team last week — it fires on every Account update and calls `Schema.getGlobalDescribe()` without caching. For 200 Accounts per execute(): 200 trigger invocations × 1 `getGlobalDescribe()` = 200 SOQL (though it appears as 1 per trigger context, the batch execute() accumulates them). Combined with existing SOQL in the service, total exceeds 100.

**Fix:**
1. Identify the new trigger — add `Schema.getGlobalDescribe()` caching as a static variable (see `WeakAreaRevisitService.getGlobalDescribe()`)
2. Short-term: reduce batch scope to 50 to keep per-execute SOQL within limits
3. Medium-term: audit all SOQL calls in every code path the batch touches; ensure static caching at each potential repeated call

**Prevention:** After any deployment of a new trigger on a high-volume object, run the affected batch with production-volume data in a full-copy sandbox to verify SOQL consumption stays under 80 (leaving headroom).


---

## Section 22 — Behavioral and Leadership Questions

### 22.1 Handling a Conflict Between Your Approach and the Client's Request

**Framework:** Acknowledge → Understand → Inform → Defer Appropriately

The client has context you don't have — business constraints, political relationships, past failures with similar approaches. Start by understanding WHY they want what they want before defending your position.

**Real answer (mapped to Saikiran's background):**
"In our FSL implementation, the client wanted to put all the scheduling logic in a single massive trigger. I knew this would become unmanageable as their field ops team scaled. I started by asking questions to understand their concern — they'd been burned by a consultant who over-engineered a previous solution they couldn't maintain. That context changed my approach. Instead of insisting on the full trigger framework immediately, I proposed a middle path: a single service class extracted from the trigger, with method-level unit tests they could run themselves. Once they saw the testability benefit, they agreed to the handler layer in the next sprint. The key was understanding their risk before proposing my solution."

---

### 22.2 Leading a Production Incident

**Communication order (within first 15 minutes):**
1. **Immediate team lead / manager notification** — "Case updates are failing in production, investigating now"
2. **Impacted team (Service Cloud ops)** — "Advise agents to avoid bulk case updates until resolved"
3. **If data is at risk:** legal/security team notification per incident response policy
4. **Status updates every 15 minutes** until resolved, even if the update is "still investigating"

**Technical steps:**
1. Identify: check Debug Logs filtered by "Error" level, check `AsyncApexJob` for failed jobs, check `Setup → Apex Jobs`
2. Contain: if it's a trigger, activate the CMDT bypass flag to stop the damage without a deployment
3. Diagnose: reproduce in a sandbox with production data volume
4. Fix: code change with test coverage
5. Deploy: validate in sandbox, quick deploy to production
6. Post-mortem: document root cause, fix, and preventive measures within 24 hours

**What NOT to do:** Make untested changes directly in production. Deploy without running tests. Go silent while investigating — silence increases stakeholder anxiety.

---

### 22.3 Mentoring a Junior Developer Not Following the Trigger Framework

**Framework:** Observe → Explain impact → Coach → Follow up

Don't lead with "you're doing it wrong." Lead with curiosity about their reasoning — they may have a legitimate context you're not aware of.

"I noticed the case assignment logic in the trigger file directly. Can you walk me through your thinking? ... I want to share a challenge this creates: when we need to bypass this logic for the data migration next month, there's no way to disable just this piece without a deployment or removing the whole trigger. The CMDT bypass pattern we use elsewhere lets an admin flip a switch without waiting for a release window. Would you be open to refactoring this before we go to production? I'm happy to pair on it — it should take about 2 hours and I can show you the pattern from AccountTriggerHandler."

The goal: they understand the WHY, not just the what. The follow-up: review the refactored version and acknowledge it in the next team standup.

---

### 22.4 Delivering Bad News: Feature Will Miss Deadline by 2 Weeks

**Framework:** Early → Factual → Options → Ask for Input

The cardinal rule: deliver bad news as early as possible, never the day before the deadline.

"I want to flag something with you before it becomes a bigger problem. The FSL work order routing feature is running behind — we have the core logic working but the 200-record bulk test is surfacing a governor limit issue I didn't anticipate. My estimate is 2 more weeks to resolve this correctly. I've identified two options: (1) we delay the feature 2 weeks and deliver it correctly, or (2) we scope it down and deliver the single-record path next week with bulk support in the following release. I'd recommend option 2 because it unblocks the field operations team for their go-live, but I wanted your input on the priority."

Map to your experience: "I've had this conversation on our FSL implementation when the offline briefcase configuration ran 3 weeks over because we discovered edge cases in the sync logic that weren't in the original spec."

---

### 22.5 Stakeholder Pushback: Client Insists on a Design You Know Will Fail at Scale

**Framework:** Document → Propose → Escalate appropriately

"I want to make sure we're aligned on the risks so we can make an informed decision together. The approach you're describing — querying all Cases in a trigger without a date filter — will work correctly for the 50,000 records we have today. When we hit 5 million records in 18 months, this query will start timing out and the trigger will fail for all users. I can implement it the way you've described and document this risk formally, or I can show you an alternative approach that adds about 3 hours of development time but doesn't have this scaling constraint. Which would you prefer? If you'd like to proceed with the first approach, I'll capture the risk and proposed mitigation in the technical design document so the future team has context."

The written risk documentation protects both you and the client. If the problem occurs later, the decision was informed and documented — not a surprise.

---

### 22.6 Code Review Conflict: Senior Peer Disagrees with Your Architectural Decision

**Framework:** Listen → Separate technical from personal → Find common ground → Escalate to data if needed

"I'd like to understand your concern fully — can you walk me through the scenario where you see this causing problems? ... That's a valid point I hadn't fully considered. My thinking was [reason], because [evidence from this repo or past project]. If we add [mitigation], does that address your concern? If we're still not aligned, I'm open to testing both approaches in a spike and letting the performance data decide."

The key behavior: treat it as a technical question to be resolved, not a contest to be won. Your architecture choices in this repo (the trigger framework, the Queueable chaining pattern, the CMDT bypass) were all deliberate decisions with documented trade-offs — you can defend them with specifics.

---

### 22.7 Estimation That Turned Out Wrong

**Framework:** Own it → Explain what changed → Show what you learned → What changes next time

"My estimate was 5 days. It took 10. Here's what I got wrong: I underestimated the complexity of the FSL briefcase sync for offline cases. My estimate was based on the standard briefcase configuration, but the client had a custom mobile app that required a different sync sequence. By day 3 I knew we were off track and flagged it immediately. The actual delay was 5 days, but by surfacing it early, we were able to descope the custom sync for launch and deliver it in the next sprint. What I've changed since: I now add a 30% buffer to any estimate involving mobile or offline features, and I do a 30-minute spike on any area I haven't personally implemented before estimating it."

Map to your experience: this answer fits your FSL + portal work where offline and integration complexity regularly outpaces initial estimates.

---

## Final Note for Saikiran

This guide covers 22 sections of production-depth content across every topic you'll face in a senior developer or architect-track interview. The most important things to internalize before your interview:

1. **Your real projects are your best evidence.** FSL, Service Cloud, Experience Cloud, CI/CD — every section of this guide maps to something you've actually built. Use specific examples: which trigger, which SOQL pattern, which pipeline stage.

2. **Trade-offs signal seniority.** Every answer you give should acknowledge what you're trading off. Interviewers don't expect perfect answers — they expect mature thinking about consequences.

3. **You know this stack deeply.** 9 years of Salesforce experience is not common. The patterns in this repo — trigger framework, Queueable chaining, stateful batch, HMAC webhook receiver, multi-cloud orchestration — these are architect-level implementations. Present them with confidence.

4. **Agentforce and Data Cloud are a growth opportunity, not a gap.** Bridge from your existing `@InvocableMethod` and integration experience to the AI layer confidently. You have the foundation; the surface API is learnable quickly.

Good luck.

