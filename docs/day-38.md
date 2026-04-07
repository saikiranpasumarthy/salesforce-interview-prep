# Day 38 — Mock Interview Day 2: Clouds + DevOps + Design

## Overview

Simulation of a senior Salesforce developer technical interview focused on:
- **Clouds**: OmniChannel, Sharing, CDC, Automation strategy, Config patterns, Pagination
- **DevOps**: Deployment readiness, Coverage analysis, Environment management, CI/CD gating
- **Design**: Packaging models, Sandbox lifecycle, Destructive change detection

---

## Part 1: Clouds & Platform Interview Q&A

### Q1: How does OmniChannel routing work, and how do you programmatically route a work item?

**Answer:**

OmniChannel routes work items (Cases, Leads, custom objects) to agents based on capacity, skills, and availability.

**Flow:**
1. Work Item (e.g. Case) is created
2. A `PendingServiceRouting` record is inserted with `IsReadyForRouting = true`
3. Salesforce evaluates routing rules → assigns to an agent via a `AgentWork` record

```apex
PendingServiceRouting psr = new PendingServiceRouting(
    WorkItemId        = caseId,
    RoutingType       = 'QueueBased',   // or 'SkillsBased'
    CapacityWeight    = 1,
    IsReadyForRouting = true
);
insert psr;
```

**Key interview points:**
- `RoutingType`: `QueueBased` (queue membership) vs `SkillsBased` (agent skill routing)
- `CapacityWeight`: how much agent capacity this item consumes (e.g. 2 = twice normal)
- `IsReadyForRouting = true` triggers the routing engine immediately on insert

---

### Q2: Explain Salesforce's sharing model. How do you create a manual share in Apex?

**Answer:**

**Sharing model layers (evaluated in order):**
1. **OWD (Org-Wide Defaults)** — baseline access: Private, Public Read Only, Public Read/Write
2. **Role Hierarchy** — managers see subordinates' records (configurable)
3. **Sharing Rules** — criteria-based or ownership-based automated sharing
4. **Manual Sharing** — user-granted share on individual records
5. **Apex Managed Sharing** — programmatic share with custom `RowCause`

**Manual share via Apex:**
```apex
// Standard object uses {ObjectName}Share and {ObjectName}Id field
// Custom object uses {ObjectName}__Share and ParentId field
SObject share = Schema.getGlobalDescribe().get('AccountShare').newSObject();
share.put('AccountId',    recordId);
share.put('UserOrGroupId', userId);
share.put('AccessLevel',  'Read');
share.put('RowCause',     'manual');
insert share;
```

**Key interview points:**
- Can only share at access level ≤ your own (can't grant higher than you have)
- `RowCause = 'manual'` for manual shares; custom causes require Apex Sharing Reason setup
- OWD of "Private" is required for manual sharing to be meaningful

---

### Q3: What is Change Data Capture (CDC), and how do you process CDC events in Apex?

**Answer:**

CDC publishes a Platform Event whenever a record is created, updated, deleted, or undeleted. Subscribers process changes asynchronously via Apex triggers on the `__ChangeEvent` object.

**Event structure:**
```apex
trigger AccountCDC on AccountChangeEvent (after insert) {
    for (AccountChangeEvent event : Trigger.new) {
        EventBus.ChangeEventHeader header = event.ChangeEventHeader;
        // header.changeType: CREATE | UPDATE | DELETE | UNDELETE
        // header.entityName: 'Account'
        // header.recordIds: List<String> of affected record IDs
        // header.changedFields: List<String> — only set on UPDATE
    }
}
```

**Key interview points:**
- CDC events are delivered **at-least-once** → subscribers must be idempotent
- `changedFields` is only populated for `UPDATE` events — check before accessing
- Replayable for up to **3 days** via `replayId` (like Platform Events)
- Use `EventBus.RetryableException` to force a retry on transient failure

---

### Q4: When do you use Flow vs Apex Trigger vs Batch Apex?

**Answer:**

**Decision matrix:**

| Scenario | Tool | Reason |
|---|---|---|
| Admin-maintainable business rule | **Flow** | No deployment needed for changes |
| Record validation with complex logic | **Flow** (Record-Triggered) | Declarative, auditable |
| HTTP callout needed | **Apex Trigger + Queueable** | Flow callout actions exist but limited |
| Complex multi-step logic | **Apex Trigger** | Full language capability |
| > 2,000 records to process | **Batch Apex** | Governored chunk processing |
| Scheduled nightly job | **Scheduled Apex** | Cron-style, retry-able |

**Rule of thumb:** Flow-first. Only move to Apex when you hit declarative limits.

---

### Q5: Custom Metadata Type vs Custom Settings — when to use each?

**Answer:**

| Feature | Custom Metadata Type | Custom Setting (Hierarchy) |
|---|---|---|
| Deployable via SFDX | ✅ Yes | ❌ No (data, not metadata) |
| Packageable | ✅ Yes | ❌ No |
| User/Profile override | ❌ No | ✅ Yes |
| DML limits count | ❌ No (no DML for reads) | ❌ No |
| Use case | Config that travels with code | Per-user/profile overrides |

**Use Custom Metadata when:** configuration is part of the feature (feature flags, API endpoints, routing rules).
**Use Custom Settings when:** different users/profiles need different values (e.g. "is email enabled for this user?").

---

### Q6: Why is OFFSET-based pagination a problem, and what's the alternative?

**Answer:**

**Problem with OFFSET:**
- Salesforce limits OFFSET to **2,000** — you cannot page beyond record 2,000
- Performance degrades as OFFSET increases (scans all prior rows)

**Cursor-based pagination (Id-ordered):**
```apex
// Page 1
SELECT Id, Name FROM Account ORDER BY Id ASC LIMIT 50

// Page N+1 — pass lastId from previous page
SELECT Id, Name FROM Account
WHERE Id > :lastId
ORDER BY Id ASC LIMIT 50
```

**Benefits:** No 2,000 limit, consistent performance, immune to inserts between pages.

---

## Part 2: DevOps Interview Q&A

### Q7: What is your deployment process from scratch org to production?

**Answer:**

```
Developer Scratch Org
  ↓  sfdx force:source:push
Feature Branch (Git)
  ↓  PR → code review → merge
CI Pipeline (GitHub Actions / Bitbucket Pipelines)
  ↓  sfdx force:source:convert + deploy to CI scratch org
  ↓  Run all Apex tests (--test-level RunLocalTests)
  ↓  Coverage gate ≥ 75% (target 85%)
  ↓  Static analysis (PMD / Scanner)
Integration Sandbox (Delta deploy)
  ↓  User Acceptance Testing
UAT Sandbox
  ↓  Change set or sfdx deploy --target-org
Production (Quick Deploy if tests passed in CI)
```

**Key interview points:**
- **Quick Deploy**: after running tests in sandbox, Salesforce allows re-use of the test run for up to 10 days — skips re-running tests in production
- **Delta deployment**: only deploy changed components (use `sfdx-git-delta`)
- **Destructive changes**: must be in `destructiveChanges.xml` — Salesforce will NOT auto-delete components

---

### Q8: How do you query Apex code coverage programmatically?

```apex
// ApexCodeCoverageAggregate — summary (one row per Apex class)
List<SObject> rows = Database.query(
    'SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered ' +
    'FROM ApexCodeCoverageAggregate'
);

// Calculate coverage %
Integer covered   = (Integer) row.get('NumLinesCovered');
Integer uncovered = (Integer) row.get('NumLinesUncovered');
Decimal pct = (covered + uncovered > 0)
    ? (Decimal) covered / (covered + uncovered) * 100
    : 0;
```

**Note:** `ApexCodeCoverageAggregate` is a **Tooling API** object. It may not be queryable in all execution contexts — always wrap in try/catch.

---

### Q9: What do you do immediately after a full sandbox refresh?

**Answer (ordered checklist):**

1. **Disable email deliverability** — Setup → Email → Deliverability → "No Access"
2. **Scrub PII** — mask email addresses, phone numbers, SSNs via post-copy Apex script
3. **Reset integration credentials** — update Named Credentials to sandbox endpoints
4. **Deactivate scheduled jobs** — Apex post-copy script calls `System.abortJob()`
5. **Update Custom Settings/Metadata** — switch to sandbox-safe endpoint values
6. **Disable connected apps** if prod OAuth tokens refreshed

**Apex post-copy script:**
```apex
global class SandboxPostCopy implements SandboxPostCopy {
    global void runApexClass(SandboxContext ctx) {
        // mask PII, abort jobs, update config
    }
}
```
Configured in **Setup → Sandboxes → Post Copy Apex Class**.

---

### Q10: Unlocked Package vs Managed Package vs Org Dev Model?

| | Unlocked | Managed 2GP | Org Dev |
|---|---|---|---|
| Namespace | Optional | Required | None |
| Versioning | ✅ | ✅ | ❌ |
| Subscriber upgrades | ❌ | ✅ | ❌ |
| AppExchange | ❌ | ✅ | ❌ |
| CI/CD friendly | ✅ | ✅ | Partial |
| Best for | Modular internal dev | ISV products | Simple single-org |

---

## Part 3: System Design — CI/CD Gate

### Design a deployment readiness check that can block/warn a CI pipeline

**Components:**
1. **Coverage check** — query `ApexCodeCoverageAggregate`, compute average, compare to 75% / 85% thresholds
2. **Destructive change detector** — diff source components vs target; flag deletions
3. **CI gate decision** — PASS / WARN / FAIL based on blockers and warnings
4. **Summary report** — machine-readable + human-readable output for CI logs

**Decision logic:**
```
FAIL  → blockers exist OR coverage < 75%
WARN  → no blockers but warnings exist OR coverage < 85%
PASS  → no blockers, no warnings, coverage ≥ 85%
```

**Key design decisions:**
- Graceful degradation when Tooling API objects are unavailable (return empty, not exception)
- Threshold constants (`MINIMUM_COVERAGE_PCT`, `TARGET_COVERAGE_PCT`) — not magic numbers
- Destructive count > 5 is a blocker, ≤ 5 is a warning — configurable threshold

---

## Files Created

| File | Purpose |
|---|---|
| `MockInterviewCloudsService.cls` | OmniChannel, sharing, CDC, automation/config classifiers, cursor pagination |
| `MockInterviewDevOpsService.cls` | Deployment readiness, coverage query, env config, destructive detector, CI gate |
| `MockInterviewDay2Test.cls` | 40 test methods covering all patterns |

---

## Interview Tips — Day 38

1. **OmniChannel**: Always mention `CapacityWeight` and the difference between `QueueBased` vs `SkillsBased` routing — interviewers test this distinction.
2. **Sharing**: Know the 5-layer model cold. The order matters for how access is resolved.
3. **CDC idempotency**: Every answer about CDC should include "at-least-once delivery → subscribers must be idempotent."
4. **Flow-first**: Lead with Flow in any automation question. Enumerate when Apex is necessary (callouts, governor limits, complex branching).
5. **Coverage query**: Mention Tooling API limitation and try/catch — shows production awareness.
6. **Destructive changes**: Many candidates forget this exists. Knowing `destructiveChanges.xml` and Quick Deploy signals senior-level deployment experience.
7. **Cursor pagination**: The OFFSET 2,000 limit is a known gotcha — knowing the cursor-based alternative immediately differentiates you.
