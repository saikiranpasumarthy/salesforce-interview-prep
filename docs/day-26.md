# Day 26 — Service Cloud Deep Dive: Case Management, Entitlements & Milestones

## Core Service Cloud Object Model

```
Account / Contact
    └── Entitlement  (what service level is owed)
          └── SlaProcess / EntitlementProcess
                └── MilestoneType  (First Response, Resolution, Follow-up)
                      └── CaseMilestone  (instance on a specific Case)

Case
  ├── EntitlementId  → links to Entitlement
  ├── IsStopped      → SLA stopwatch paused/running
  ├── SlaStartDate   → when SLA clock started
  ├── SlaExitDate    → deadline (breach time)
  ├── IsEscalated    → escalation flag
  ├── CaseComments   → internal/external notes
  ├── CaseTeamMember → users attached in specific roles
  └── CaseMilestones → time-bound targets from SlaProcess
```

---

## How SLA Works End-to-End

```
1. Case created (Web-to-Case, Email-to-Case, manual, API)
2. Assignment Rule assigns case to queue/agent
3. Case.EntitlementId populated (manually, via Flow, or via autoApplyEntitlement)
4. Platform reads Entitlement.SlaProcessId
5. Platform creates CaseMilestone records per process definition
6. Case.SlaStartDate = NOW, SLA clock running (IsStopped = false)
7. Agents work the case
8. Each CaseMilestone reaches TargetDate:
     → Completed before TargetDate: IsCompleted = true, CompletionDate = now
     → Not completed by TargetDate: IsViolated = true
9. All milestones met → SLA satisfied
10. Case closed → Case.SlaExitDate records the deadline
```

---

## Entitlement Key Fields

| Field | Type | Description |
|---|---|---|
| `Status` | Picklist | Active / Inactive / Expired |
| `StartDate` / `EndDate` | Date | Validity window |
| `RemainingCases` | Number | Cases remaining under this entitlement |
| `CasesPerEntitlement` | Number | Total allocation |
| `BusinessHoursId` | Lookup | BH record driving SLA calculations |
| `SlaProcessId` | Lookup | Entitlement Process (drives milestone creation) |

### EntitlementContact junction
A single Entitlement can cover multiple Contacts, and a Contact can have multiple Entitlements. The platform checks both Account-level and Contact-level entitlements when looking up coverage.

---

## CaseMilestone Key Fields

| Field | Description |
|---|---|
| `MilestoneTypeId` | Which milestone template (First Response etc.) |
| `TargetDate` | Platform-calculated deadline based on BH |
| `IsCompleted` | `true` = met before deadline |
| `CompletionDate` | When it was completed |
| `IsViolated` | `true` = TargetDate passed without completion |
| `ElapsedTimeInMins` | Business minutes from start to completion/violation |

### CaseMilestone DML rules
```apex
// ❌ CANNOT insert — platform creates automatically when EntitlementId is set
insert new CaseMilestone(...);  // throws exception

// ✅ CAN complete manually
update new CaseMilestone(Id = milestoneId, IsCompleted = true);

// ✅ CAN query (requires Entitlement Process to be configured)
List<CaseMilestone> violated = [
    SELECT Id, CaseId, TargetDate
    FROM   CaseMilestone
    WHERE  IsViolated = true
];
```

---

## SLA Stopwatch

```apex
// Pause the clock (waiting for customer response)
update new Case(Id = caseId, IsStopped = true);

// Resume (agent picked it back up)
update new Case(Id = caseId, IsStopped = false);
```

**Interview point**: `IsStopped = true` pauses both the Case-level SLA clock AND all CaseMilestone countdowns simultaneously. The elapsed time when the timer was paused is preserved — it does not reset.

---

## Business Hours API

```apex
// Elapsed business minutes between two DateTimes
Long ms = BusinessHours.diff(businessHoursId, startDt, endDt);
Long minutesElapsed = ms / 60000;

// Add business time to a DateTime
DateTime deadline = BusinessHours.add(businessHoursId, startDt, 120 * 60000L); // +2 BH hours

// Is a DateTime within business hours?
Boolean isOpen = BusinessHours.isWithin(businessHoursId, DateTime.now());

// Next business-hours opening after a DateTime
DateTime nextOpen = BusinessHours.nextStartDate(businessHoursId, DateTime.now());
```

**Non-business time is excluded automatically**: nights, weekends, public holidays defined on the BH record. A `BusinessHours.diff()` for a 2-hour window over a weekend returns 0.

---

## Case Team

```apex
// Look up role ID by name (no hardcoded IDs)
List<CaseTeamRole> roles = [SELECT Id FROM CaseTeamRole WHERE Name = 'Technical Lead' LIMIT 1];
Id roleId = roles[0].Id;

// Add a user to the case team
insert new CaseTeamMember(
    ParentId   = caseId,
    MemberId   = userId,
    TeamRoleId = roleId
);
```

CaseTeamRole controls:
- What access the member has to the Case (Read / Read-Write)
- What access they have to related records (Account, Contact)
- Configured in Setup → Service → Case Team Roles

---

## Escalation Patterns

### Standard platform approach
- **Escalation Rules**: Setup → Service → Escalation Rules
  - Criteria-based: escalate cases with Priority=High open > 2 hours
  - Actions: reassign, send email, set IsEscalated = true
  - Limitation: runs on a schedule (not real-time)

### Apex approach (CaseManagementService.escalateCase)
```apex
// Real-time, conditional escalation from trigger or Flow invocable
Case c = [SELECT Id, IsEscalated FROM Case WHERE Id = :caseId];
if (!c.IsEscalated) {
    c.IsEscalated = true;
    update c;
    insert new CaseComment(ParentId = caseId, CommentBody = 'Escalated: ' + reason,
                           IsPublished = false);
    // Optionally: publish Platform Event for downstream notifications
}
```

### At-risk detection (proactive SLA monitoring)
```apex
// Cases within 60 minutes of SLA breach
DateTime warningWindow = DateTime.now().addMinutes(60);
List<Case> atRisk = [
    SELECT Id, CaseNumber, SlaExitDate, OwnerId
    FROM   Case
    WHERE  IsClosed    = false
      AND  SlaExitDate != null
      AND  SlaExitDate <= :warningWindow
    ORDER BY SlaExitDate ASC
];
// → notify owners via Platform Event or Custom Notification
```

---

## Email-to-Case vs Web-to-Case

| | Email-to-Case | Web-to-Case |
|---|---|---|
| Source | Inbound email to support address | HTML form submission |
| Creates | Case + CaseComment (email body) | Case only |
| Attachment handling | Email attachments → Case Files | Form file upload → Case Files |
| Routing | Email Service → Case Assignment Rule | Web form → Case Assignment Rule |
| On-Demand vs Simple | On-Demand (secure, no open port) vs Simple | Always secure (HTTPS POST) |
| Thread key | Email thread ID in subject | N/A |

---

## Knowledge Integration

```
Case → CaseArticle → Knowledge__kav (Article version)
```

- `Case.IsClosed = true` → platform prompts agent to attach resolved KB article
- `KbManagement.PublishingService` — Apex class to search Knowledge articles
- `KbManagement.PublishingService.searchKnowledge(query, filters, sortOrder, offset, pageSize)`
- Email threading and KB article attachment is the standard deflection strategy

---

## Key Classes (Day 26)

| Class | Responsibility |
|---|---|
| `CaseManagementService` | Escalation (idempotent), bulk close, SLA pause/resume, at-risk detection, BusinessHours API, CaseTeam management |
| `EntitlementService` | Active entitlement lookup (Account + Contact), auto-apply to Case, violated milestone query, `MilestoneStats` aggregation |
| `ServiceCloudTest` | 30 tests — BusinessHours queries against live org, mock injection for CaseMilestone + Entitlement, MilestoneStats derived-field edge cases |
| `CasesSelector` (Day 6) | CasesSelector base — bulk query, QueryLocator |
| `CaseArchiveService` (Day 4) | Big Object archival for closed Cases |

---

## Quick-Reference: Interview Answers

**"Walk me through how Entitlements and Milestones work together."**
> When a Case is linked to an Entitlement, the platform reads the attached Entitlement Process (SlaProcess), then generates CaseMilestone records for each stage — e.g. First Response in 2 business hours, Resolution in 8. The SLA stopwatch starts (SlaStartDate). If an agent responds before the TargetDate the milestone is completed; if the deadline passes without completion, IsViolated is set to true. The IsStopped flag pauses all milestone clocks — used when waiting for customer response so agent idle time doesn't count against the SLA.

**"How do you detect at-risk cases before they breach SLA?"**
> I query Cases where IsClosed = false, SlaExitDate is not null, and SlaExitDate ≤ DateTime.now().addMinutes(warningWindow). A Scheduled Apex job runs every 15 minutes, finds at-risk cases, and fires a Custom Notification or Platform Event to the case owner's device. The warning window is configurable — typically 30 to 60 minutes for P1 cases.

**"Can you insert a CaseMilestone from Apex?"**
> No — CaseMilestones are platform-managed. They are created automatically when a Case is linked to an Entitlement that has an Entitlement Process. You can complete a milestone by updating IsCompleted = true, and you can query milestones, but you cannot insert or delete them directly. This is by design: the SLA process definition drives the milestone lifecycle, not developer code.
