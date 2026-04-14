# FSC + OmniStudio Wealth Management — Interview Q&A

**Project Reference:** Retail Banking and Wealth Management System  
**Stack:** Financial Services Cloud · OmniStudio · Apex · REST Integrations  
**Candidate:** Saikiran Pasumarthy  

---

## How to Use This Document

Each Q&A maps directly to code written in this project. When you answer in an interview:

1. **State the concept** (what it is)
2. **Reference the project** ("In my wealth management project...")
3. **Give the specific implementation** (file name, pattern, decision made)
4. **State the trade-off or alternative** (why this vs. something else)

---

## Section 1: Financial Services Cloud (FSC)

---

**Q1: What is the FSC Household model and when would you use it over the Individual Account model?**

**A:** The Household model represents a family unit as a single Account record (Household Account) with individual clients linked as Person Accounts via the `AccountAccountRelation` junction object. The Household Account becomes the aggregate unit for financial planning.

In my wealth management project, I chose the Household model because:
- **Net worth rollup** — FSC provides built-in rollup summaries that aggregate `FinancialAccount` balances across all household members. With the Individual model you'd build custom rollups.
- **Advisor assignment** — One advisor owns the Household Account, serving the entire family. Individual model assigns per person — creates ownership confusion for joint accounts.
- **Co-applicant support** — The `LoanApplication__c` references both `Applicant__c` (PersonAccount) and `Household__c` (Household Account), allowing joint loan applications.

The Individual model is appropriate when: a bank has no concept of household grouping, all customers are treated as independent entities, and no aggregate financial view is needed.

---

**Q2: How does the FSC FinancialAccount object relate to your custom FinancialAccount__c?**

**A:** FSC ships with a managed `FinancialAccount` object inside the FSC managed package. In orgs with the full FSC package, this is the canonical object. My `FinancialAccount__c` is a **companion custom object** that mirrors key fields and adds project-specific ones.

Why I created a custom object instead of using the managed one:
- **Trigger control** — You cannot write Apex triggers on FSC managed package objects in some org configurations. `FinancialAccount__c` gives full trigger ownership (I built `FinancialAccountTrigger` + `FinancialAccountTriggerHandler`).
- **Custom field freedom** — Added `PortfolioHealthBand__c`, `LastSyncedDateTime__c`, `ExternalAccountId__c` for core banking sync — not present on the managed object.
- **ExternalId for integration** — `ExternalAccountId__c` as an external ID field enables idempotent upsert from the Integration Procedure without complex dedup logic.

In a full FSC org, I'd use the managed `FinancialAccount` for standard FSC features (rollups, relationship maps) and the custom object for integration-specific tracking.

---

**Q3: How does OmniStudio's DataRaptor Extract compare to a SOQL query in Apex? When do you use each?**

**A:** Both retrieve data, but at different layers with different trade-offs:

| Dimension | DataRaptor Extract | Apex SOQL |
|---|---|---|
| Who can modify it | Admin (no deployment) | Developer (requires deployment) |
| Multi-level relationships | Declarative — define level 0/1/2 | Manual — multiple queries + map stitching |
| Output structure | Configured JSON tree | Hand-built Map/List |
| FLS enforcement | OmniStudio runtime enforces automatically | Must use `WITH USER_MODE` explicitly |
| Testability | IP Test tab with mock inputs | Full @isTest framework |
| Volume handling | Use TurboExtract for >2,000 rows | Batch Apex |

In my project, `DR-Extract-HouseholdExtract` retrieves Account → FinancialAccount__c → FinancialHolding__c (3 levels) plus AssetsAndLiabilities__c — all in one declarative definition. The equivalent Apex would be 3 SOQL queries with manual stitching into a nested map.

I use Apex SOQL when: I need complex dynamic filtering, the query logic needs branching unavailable in DR, or the data is consumed by business logic (not just display).

---

**Q4: Walk me through how you implemented the portfolio health banding. Why not use a Salesforce formula field?**

**A:** Portfolio health (GREEN/YELLOW/RED) is computed at two layers:

**Apex layer** (`FinancialAccountService.computeHealthBand`):
```apex
static String computeHealthBand(Decimal balance) {
    if (balance == null || balance < YELLOW_MIN_BALANCE) return 'RED';
    if (balance < GREEN_MIN_BALANCE)                      return 'YELLOW';
    return 'GREEN';
}
```
Called from `portfolioHealthForHousehold()` — returns a `Map<Id, String>` of accountId → band.

**FlexCard layer** — inline expression on the balance field:
```
{item.balance} >= 10000 ? 'GREEN' : ({item.balance} >= 1000 ? 'YELLOW' : 'RED')
```

Why not formula field on the object:
- Thresholds may vary by account type or product tier — business rule belongs in the service layer, not locked into a formula field that requires deployment to change.
- The FlexCard expression covers display only — it doesn't write back to Salesforce.
- For alerts and automated actions (e.g., rebalance notification), the Apex service method is the authoritative source. Both layers use the same threshold constants — single source of truth.

---

**Q5: How do you handle the integration between OmniStudio Integration Procedures and Apex? Why not @InvocableMethod?**

**A:** OmniStudio IPs call Apex via the **Callable interface**, not `@InvocableMethod`. The reason is architectural:

- **`@InvocableMethod`** — designed for Flow invocation. Not the standard IP → Apex bridge.
- **Callable interface** — OmniStudio's native pattern. The IP's `ApexAction` step specifies `className: WealthManagementCallable` and `methodName: call`. The IP passes `action` as a string argument.

My `WealthManagementCallable.call(action, args)` routes 7 actions:
```
calculateLoanEligibility  → LoanEligibilityService.scoreEligibility()
fetchCreditScore          → CreditScoreService.fetchScore()
getHouseholdNetWorth      → FinancialAccountService.householdNetWorth()
getPortfolioHealth        → FinancialAccountService.portfolioHealthForHousehold()
validateKyc               → KycValidationService.verifyIdentity()
interpretCreditBand       → CreditScoreService.interpretBand()
calcDebtToIncomeRatio     → LoanEligibilityService.calcDebtToIncomeRatio()
```

The Callable interface gives **zero compile-time coupling** — the IP references a string class name. If I rename or replace the service class, the IP configuration changes (not recompiled). I can also inject a mock Callable in tests without touching the IP.

---

## Section 2: OmniScript Design

---

**Q6: Why did you use OmniScript for client onboarding instead of a custom LWC wizard?**

**A:** I evaluated both and chose OmniScript for three specific capabilities it handles declaratively that LWC requires custom code for:

1. **Step navigation with conditional branching** — `EmployerSection` shows only when `EmploymentStatus !== UNEMPLOYED`. In LWC: `v-if` + controller state + `@track` variables. In OmniScript: `Conditional` element with a property expression. Admin-modifiable.

2. **Multi-step Review element** — OmniScript's built-in `Review` element auto-generates a summary table from all previous steps' answers. The advisor can review without data re-entry risk. In LWC: custom template, manual data binding, risk of display/save divergence.

3. **Integration Procedure Action step** — Calls the IP server-side without client-side callout. OmniScript Step 3 calls `ClientOnboardingIP` which makes 2 HTTP callouts (KYC + credit bureau) and 2 DML operations — all server-side, no governor limit exposure on the LWC side.

I would choose LWC when: pixel-perfect custom UI is required, the interaction model is too complex for declarative elements, or the component needs custom JavaScript event handling.

---

**Q7: Your LoanApplication OmniScript calls the same Integration Procedure in two different modes. How does that work?**

**A:** `LoanEligibilityIP` supports two action modes controlled by an `action` input parameter:

- **`CALCULATE_DTI`** — called on Step 2 load via `autoTrigger:true`. The IP runs steps 1–5 only: initialize → validate → calculate DTI → classify DTI → return Response immediately. No credit callout, no DML. Fast, cheap, used for real-time feedback while the user fills in income/debt fields.

- **`FULL_ELIGIBILITY`** — called on Step 3 Submit click via `autoTrigger:false`. The IP runs all 14 elements: DTI → credit score fetch → eligibility decision → DR Load (persist record) → approval routing → notification.

The early exit at element 5 (`EarlyExitForDTIOnlyMode`) uses a `Conditional` with a nested `Response` element. OmniStudio stops IP execution at a `Response` element — so elements 6–14 never execute in DTI-only mode. This pattern avoids duplicating orchestration logic across two separate IPs, reduces maintenance surface, and shares the validation and DTI logic between both modes.

---

**Q8: How do you handle idempotency in your OmniScript submissions?**

**A:** Three layers:

1. **ExternalId on `LoanApplication__c`** — The OmniScript generates `ExternalId__c` as `SHA-256(applicantId + loanType + timestamp)` at wizard start (LoanApplicationTriggerHandler.generateExternalId()). If the user hits back and resubmits, the same ID is generated and `DR-Load-LoanDecisionLoad` upserts the existing record instead of creating a duplicate.

2. **DataRaptor Load operation:Upsert** — `externalIdField: ExternalId__c` means the DR uses Salesforce's native upsert — if the record exists (matched by ExternalId__c), it updates; otherwise creates. No manual dedup logic.

3. **ClientOnboarding IP duplicate check** — Element 3 (`CheckExistingHousehold`) queries Account by PersonEmail before creating. If an Account exists, element 4 (`DuplicateAccountGuard`) routes to use the existing Id and skips Account creation entirely.

This makes the entire onboarding flow safe to retry on network failure, browser crash, or user resubmission.

---

## Section 3: Integration Architecture

---

**Q9: How do you secure external API credentials in this project? What would you do differently in production?**

**A:** All external callouts use **Named Credentials** — no API keys appear anywhere in code, DataRaptor configurations, or Integration Procedure steps:

- `CreditBureauNC` — HTTP callout in `CreditScoreService.fetchScore()` and `ClientOnboardingIP` element 9b
- `CoreBankingNC` — `FinancialAccountService.syncBalanceFromCoreBanking()`
- `KycProviderNC` — `ClientOnboardingIP` element 7

The `endpoint` in each HTTP call is `callout:CreditBureauNC/v1/scores` — Salesforce resolves the Named Credential at runtime, injecting the auth header automatically.

**Production hardening I'd add:**
- **Certificate pinning** — configure a client certificate on the Named Credential for mutual TLS to the credit bureau (PCI requirement for financial data).
- **Per-environment Named Credentials** — each sandbox and production org gets its own Named Credential pointing to the sandbox/prod endpoint. Same code runs everywhere.
- **Secret rotation** — Named Credential auth parameters (API keys, OAuth tokens) are stored in Salesforce's encrypted credential store, separate from org config. Rotation doesn't require code changes.
- **IP allowlisting** — coordinate with the external vendor to allowlist Salesforce's outbound IP ranges.

---

**Q10: Walk me through what happens end-to-end when a client submits a loan application through the OmniScript.**

**A:** Full execution path:

1. **OmniScript Step 3 (autoTrigger)** — On Step 2 load, OS calls `LoanEligibilityIP` with `action:CALCULATE_DTI`. IP elements 1–5 run: validate inputs → `WealthManagementCallable.call('calcDebtToIncomeRatio')` → classify DTI → return DTI% to OmniScript. User sees real-time DTI feedback.

2. **OmniScript Step 3 Submit** — User clicks Submit. OS calls `LoanEligibilityIP` with `action:FULL_ELIGIBILITY`.

3. **IP Element 6** — `ApexAction:FetchCreditScore` → `WealthManagementCallable.call('fetchCreditScore')` → `CreditScoreService.fetchScore()` → `HTTP POST callout:CreditBureauNC/v1/scores` → response parsed → score + band returned.

4. **IP Element 8** — `ApexAction:RunEligibilityDecision` → `WealthManagementCallable.call('calculateLoanEligibility')` → `LoanEligibilityService.determineDecision(score, dti)` → `AUTO_APPROVED / MANUAL_REVIEW / DECLINED`.

5. **IP Element 9** — Compute estimated interest rate inline (EXCELLENT:4.5%, VERY_GOOD:5.25%, GOOD:6.0%).

6. **IP Element 10** — `DataRaptorLoadAction:DR-Load-LoanDecisionLoad` → upsert `LoanApplication__c` via `ExternalId__c` with all 22 fields including decision, credit score, DTI, approval tier, estimated rate.

7. **IP Element 12** — If `MANUAL_REVIEW`: `ApexAction:SubmitForApproval` → `LoanEligibilityService.routeToApproval()` → `Approval.ProcessSubmitRequest` → routes to `BRANCH_MANAGER / DIRECTOR / EXECUTIVE` based on requested amount.

8. **IP Element 13** — HTTP callout to notification service → confirmation email to applicant.

9. **IP Element 14 Response** — Returns `{decision, creditScore, dti, loanAppId, approvalTier, estimatedRate}` to OmniScript context.

10. **OmniScript Step 3** — Three `Conditional` elements evaluate `EligibilityResult:decision` and display the appropriate outcome banner (green/orange/red).

11. **`LoanApplicationTrigger`** — DR Load fires after-update trigger. `LoanApplicationTriggerHandler.afterUpdate()` detects status change to SUBMITTED. Since `EligibilityDecision__c` is already set (not PENDING), `LoanEligibilityQueueable` skips re-evaluation (double-scoring guard).

---

## Section 4: Security

---

**Q11: How do you enforce field-level security in your Apex service classes?**

**A:** Three mechanisms, applied at different layers:

**1. `WITH USER_MODE` on all SOQL** (primary pattern, used in every service class):
```apex
List<FinancialAccount__c> accounts = [
    SELECT Balance__c, AccountType__c
    FROM FinancialAccount__c
    WHERE Account__c = :householdId
    WITH USER_MODE
];
```
`USER_MODE` enforces both FLS (field-level) and CRUD (object-level) for the running user. Fields the user cannot read are omitted from results — no exception, silent omission.

**2. `update as user` on DML** (used in FinancialAccountService, LoanEligibilityService):
```apex
update as user toUpdate;
```
Enforces CRUD and FLS on DML operations. If the user cannot write a field, that field is excluded from the update.

**3. `Security.stripInaccessible()` pattern** — Not used in this project directly, but mentioned in tests: for collections where you need to know which fields were stripped (rather than silent omission), `stripInaccessible(AccessType.READABLE, records)` returns a `SObjectAccessDecision` with the stripped list and a set of removed fields.

**Why not `WITH SECURITY_ENFORCED`?** It throws an exception if any field is inaccessible — aggressive behavior that can break the UI for partially-permissioned users. `WITH USER_MODE` silently omits — safer for record-page FlexCards where the advisor may have read on some fields but not others.

---

**Q12: How do you prevent duplicate Account creation during concurrent onboarding submissions?**

**A:** Two layers:

**Optimistic check** (ClientOnboardingIP element 3) — DataRaptor Extract queries Account by PersonEmail before creating. If found, element 4 short-circuits to use the existing record Id.

**Deterministic upsert** — The DR Load uses `operation:Upsert` with `upsertKey:Id` on Account. If `applicantId` is already set (existing account found), the upsert updates the record. If null (new account), it inserts. No DML race condition at this layer.

**What I'd add for production**: A unique index (Unique constraint) on `PersonEmail` to prevent duplicates at the database layer, with a before-insert trigger that normalizes email to lowercase before the unique check fires. This handles the edge case where two OmniScript submissions arrive simultaneously before either has persisted — the database constraint becomes the last line of defense.

---

## Section 5: Performance and Scalability

---

**Q13: How do you handle the scenario where a household has 200+ financial accounts? Where could your solution break?**

**A:** Current limits in `DR-Extract-HouseholdExtract`:
- `FinancialAccount__c` limit: 50 records (ordered by Balance DESC)
- `FinancialHolding__c` limit: 200 records per FA

For 200+ accounts, the Extract only returns the top 50 by balance. This is intentional for the FlexCard display — showing 200 tiles on a record page would be unusable.

**Where it could break:**

1. **`recalculateHouseholdNetWorth()`** in `FinancialAccountService` — AggregateResult query has no limit. For 10,000+ accounts per household (unlikely but possible for institutional clients), this could hit heap limits in the trigger context. Fix: move to async (Platform Event fan-out or batch).

2. **`DR-Load-ClientProfileLoad` `iterateOver`** — Creates one FinancialAccount__c per account type. Currently 5 max account types, safe. If the picklist grows and users select all, the DR creates 5 records in a single transaction — within limits.

3. **FlexCard holdings flattening** — `HouseholdData.financialAccounts[*].holdings` JSONPath flattens all holdings across all FAs into one list. With 50 FAs × 200 holdings = 10,000 rows — too large for a FlexCard table. Fix: paginate, or show top-N by market value with a "View All" link.

**Production fix for large households**: Dedicated `TurboExtract` DataRaptor (optimized for large result sets with cursor-based pagination) for the holdings table, and async recalculation via `Platform Event` → Batch Apex for net worth.

---

**Q14: Why does your LoanEligibilityService cache the credit score for 30 days instead of fetching fresh every time?**

**A:** Two reasons:

**Cost** — Credit bureau APIs typically charge per inquiry. A loan officer reviewing an in-progress application multiple times would trigger unnecessary API charges if we re-fetch on every access. The 30-day TTL is a common industry standard for "still valid for decisioning purposes."

**Consistency** — If a loan officer pulls the application twice in one day, they should see the same credit score both times. A fresh pull might return a different score (scores fluctuate day-to-day) and create confusing audit trails.

Implementation in `LoanEligibilityService.resolveCreditScore()`:
```apex
Integer daysSinceFetch = app.CreditScoreFetchedAt__c.date().daysBetween(Date.today());
if (daysSinceFetch <= SCORE_CACHE_DAYS) {
    return app.CreditScore__c.intValue();
}
// fetch fresh
```

The cache TTL (`SCORE_CACHE_DAYS = 30`) is a `@TestVisible static final` constant — overridable in tests without CMDT changes. In production I'd store this in `LoanEligibilityThreshold__mdt` so a compliance officer can change it without code deployment.

**When to force a fresh pull**: The `LoanApplication__c` record has a `ConsentHardPull__c` checkbox. When checked (i.e., the applicant accepts a loan offer), a fresh hard inquiry is always made regardless of cache age.

---

## Section 6: OmniStudio Architecture

---

**Q15: How does DataRaptor Transform differ from an Apex transformation class? Give a concrete example from your project.**

**A:** Both transform data between representations. The difference is deployment, ownership, and capability:

| | DataRaptor Transform | Apex Transform |
|---|---|---|
| Deployable by | Admin (no code) | Developer (SFDX deploy) |
| Testable via | IP Test tab, mock inputs | @isTest, full framework |
| Complex logic | Limited (no loops, recursion) | Unlimited |
| Performance | Server-side, no DML limit | Same |

**Concrete example — SSN handling in `DR-Transform-KycTransform`:**

```
Input:  "123-45-6789" (OmniScript DatePicker output)
Transform 1 (Replace): strip hyphens → "123456789" (for KYC API)
Transform 2 (Mask): mask chars 0–5 → "***-**-6789" (for display)
Transform 3 (RegexReplace): phone digits only → "5555555555"
Transform 4 (DateFormat): "03/15/1990" → "1990-03-15" (ISO for API)
```

Without the Transform DR, I'd write:
```apex
String ssnDigits = ssn.replaceAll('-', '');
String ssnMasked = '***-**-' + ssn.substring(7);
String phoneDigits = phone.replaceAll('[^0-9]', '');
String dobIso = Date.parse(dob).format(); // or manual parsing
```

The DR version is admin-configurable — if the KYC vendor changes their SSN format requirement, the admin updates the Transform definition without touching Apex. The Apex version requires a code change and deployment.

I use Transform DR when the transformations are field-by-field mappings, type conversions, or string operations. I use Apex when the logic involves loops, branching on values, or complex computation (like `computeFingerprint()` with SHA-256).

---

**Q16: When would you use a FlexCard's action button to call an IP directly vs. navigating to an OmniScript?**

**A:** The decision comes down to whether the action requires **user input** or not.

**Invoke IP directly from FlexCard** (no user input needed):
- `Sync Balance` button on the Household360 FlexCard — passes `faId` from the current list item, calls `SyncBalanceIP`. No form, no wizard. One click, one API call.
- `Submit for Review` on the LoanApplicationStatus FlexCard — all required data is already on the `LoanApplication__c` record. The FlexCard passes it directly to `LoanEligibilityIP`. The loan officer doesn't need to fill in a form.

**Navigate to OmniScript** (user input required):
- `Open New Account` and `Apply for Loan` — both require multi-step form input from the client/advisor. The OmniScript provides the guided wizard, validation, and review experience.
- `Request Documents` — requires the loan officer to specify which documents to request.

The `action.type:'invoke'` pattern in FlexCard is powerful for advisor efficiency — they can act on data visible in the card without leaving the record page. I use `confirmationRequired:true` on the Submit for Review button because it triggers a credit inquiry and creates records — a confirmation dialog prevents accidental clicks.

---

**Q17: How do Integration Procedures handle errors differently from Apex? What did you implement for error resilience?**

**A:** IP error handling is step-level, not transaction-level:

**Apex** — `try/catch` wraps a DML transaction. If a callout fails, you can roll back the entire transaction.

**IP** — Each step has its own `onError` behavior:
- `SetValueAndContinue` — set a default/error value and proceed to the next step
- `ThrowException` — stop IP execution, return error to OmniScript
- `ReturnError` — global error handler, return structured error response

In `LoanEligibilityIP`, I used three distinct strategies:

1. **Credit score failure → SetValueAndContinue** (element 6 onError): If the credit bureau API is down, set `score:null, band:'UNKNOWN'` and continue. Downstream, `LoanEligibilityService.determineDecision(null, dti)` returns `DECLINED` — but the IP's element 8 `onError` catches this and overrides to `MANUAL_REVIEW`. An applicant is never falsely declined due to an API outage.

2. **DR Load failure → ThrowException** (element 10 onError): If `LoanApplication__c` cannot be persisted, there's no point continuing — stop immediately and surface the error to the OmniScript. The global error handler returns `{decision:'MANUAL_REVIEW', ipStatus:'ERROR'}` so the application goes to a human reviewer.

3. **Notification failure → SetValueAndContinue** (element 13 onError): Email failure should never block a loan application. Continue and log.

The global `errorHandling` block defaults `decision:MANUAL_REVIEW` — no application can be silently dropped by an unhandled exception. This satisfies the bank's regulatory requirement.

---

## Section 7: Behavioral / Design Questions

---

**Q18: Describe a complex design decision you made in this project and what you would change if you rebuilt it.**

**A:** The most impactful design decision was the **dual-mode Integration Procedure** for `LoanEligibilityIP` (`CALCULATE_DTI` vs `FULL_ELIGIBILITY`). It reduces maintenance surface but creates a more complex IP that's harder for a junior admin to trace.

If I rebuilt it, I'd consider splitting into two IPs:
- `LoanDTI_IP` — pure calculation, 5 elements, used by OmniScript Step 2 autoTrigger
- `LoanEligibilityFull_IP` — full pipeline, 14 elements, used on Submit

**What I'd keep the same:**
- Callable interface bridge — the clean Apex-OmniStudio separation is worth the abstraction
- `SetValueAndContinue` on credit API failure — regulatory resilience requires this
- ExternalId upsert pattern — idempotency is non-negotiable for financial data

**What I'd add:**
- **Platform Event on eligibility completion** — after `DR-Load-LoanDecisionLoad`, publish a `LoanEligibilityCompleted__e` event so downstream systems (CRM Analytics, Marketing Cloud) can react without tight coupling to the IP
- **CMDT-driven thresholds** — move `MAX_DTI_AUTO_APPROVE`, `MIN_SCORE_AUTO_APPROVE`, and `SCORE_CACHE_DAYS` out of Apex `@TestVisible static final` constants into `LoanEligibilityThreshold__mdt` so compliance officers can adjust without code deployment

---

**Q19: How did you approach testing for a system where OmniStudio components call Apex via the Callable interface?**

**A:** Testing the Callable bridge has two angles:

**Unit testing the Callable itself** (`WealthManagementCallableTest`):
- Each action tested independently — 16 test methods covering all 7 actions, missing args, unknown actions, case insensitivity
- Mock HTTP callouts via `CreditScoreMock` (8 configurable response types — success, high score, low score, HTTP error, OFAC match/no-match)
- Cached credit score path tested by pre-populating `CreditScore__c` and `CreditScoreFetchedAt__c` before calling `calculateLoanEligibility` — no mock needed, proves cache avoidance

**Testing the IP orchestration** (OmniStudio IP Test tab):
- Each IP step testable in isolation via mock inputs in the OmniStudio Designer
- Mock HTTP responses configured per HTTPAction step — simulate KYC pass/fail, credit bureau 200/503
- The `interviewNotes` in each IP JSON document the expected input/output for each test scenario

**What I can't unit test in @isTest**:
- DataRaptor Load DML (no @isTest equivalent for DR) — validated manually in sandbox
- OmniScript step navigation (no programmatic trigger of OmniScript steps) — manual E2E test via Preview mode

This is an accepted limitation of OmniStudio's testing model — the boundary between declarative and code is real. The compensating control is the Apex test coverage (44 tests, 90%+ coverage on all service classes) and the IP Test tab for orchestration validation.

---

**Q20: A new regulation requires storing a compliance timestamp every time a credit score is fetched. How would you implement this without changing the LoanApplication__c schema?**

**A:** I'd add an `AuditLog__c` custom object with:
- `RecordId__c` (Text, External ID — the LoanApplication__c Id)
- `EventType__c` (Picklist — CREDIT_FETCH, KYC_CHECK, APPROVAL_SUBMITTED)
- `EventTimestamp__c` (DateTime)
- `ActorId__c` (Lookup to User)
- `CorrelationId__c` (Text — the IP correlation ID)
- `Details__c` (Long Text Area — JSON metadata)

Implementation:
1. Add a `DataRaptorLoadAction` step in `LoanEligibilityIP` after element 6 (FetchCreditScore) that writes to `AuditLog__c` with `eventType:CREDIT_FETCH`, `recordId:{loanAppId}`, `correlationId:{ipCorrelationId}`, and `details:{score, band, applicantId}`.
2. The `CreditScoreService.fetchScore()` already returns the timestamp — capture it in the IP as `creditFetchedAt` and pass to the audit DR Load.

Why not change `LoanApplication__c`: A single loan application may have multiple credit score fetches over its lifecycle (initial check, re-check after 30 days, hard pull on offer acceptance). A single `CreditScoreFetchedAt__c` field can only store the latest. An `AuditLog__c` records every fetch with full metadata — immutable audit trail that satisfies regulatory requirements.

This could also be implemented as a **Platform Event** (`CreditScoreFetched__e`) published from `CreditScoreService` — a subscriber trigger writes to `AuditLog__c` asynchronously. This decouples the audit write from the credit check transaction and makes the audit log extensible to other systems (e.g., SIEM).

---

## Quick-Reference Cheat Sheet

| Concept | Implementation File | Key Method / Property |
|---|---|---|
| Household net worth | `FinancialAccountService.cls:41` | `householdNetWorth(householdId)` |
| Portfolio health band | `FinancialAccountService.cls:78` | `computeHealthBand(balance)` |
| Status state machine | `LoanApplicationTriggerHandler.cls:18` | `VALID_TRANSITIONS` map |
| DTI calculation | `LoanEligibilityService.cls:95` | `calcDebtToIncomeRatio()` |
| Decision logic | `LoanEligibilityService.cls:112` | `determineDecision(score, dti)` |
| Callable routing | `WealthManagementCallable.cls:55` | `call(action, args)` switch |
| Credit score cache | `LoanEligibilityService.cls:149` | `resolveCreditScore()` 30-day TTL |
| KYC SSN normalize | `DR-Transform-KycTransform.json` | `NormalizePersonalInfo` block |
| IP dual-mode | `LoanEligibilityIP.json:element5` | `EarlyExitForDTIOnlyMode` |
| Idempotent upsert | `DR-Load-LoanDecisionLoad.json` | `externalIdField: ExternalId__c` |
| FlexCard expression | `FlexCard-Household360.json` | `healthBadge.variant` expression |
| Error resilience | `LoanEligibilityIP.json:element6` | `SetValueAndContinue` on credit fail |
| FLS enforcement | All service classes | `WITH USER_MODE`, `update as user` |
| Trigger bypass | `TriggerHandler.cls:12` | `bypassedHandlers` static set |
