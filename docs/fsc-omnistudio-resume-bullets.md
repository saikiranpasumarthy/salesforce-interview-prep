# FSC + OmniStudio Wealth Management — Resume Bullets

**Candidate:** Saikiran Pasumarthy  
**Project:** Retail Banking and Wealth Management System  
**Stack:** Financial Services Cloud · OmniStudio · Apex · REST Integrations  

---

## How to Use This Document

- **Pick 4–6 bullets** relevant to the role you're applying for (FSC, OmniStudio, Architecture, or general Senior Dev).
- **Tailor the org/company context** — replace "regional bank" with client name if permissible.
- **Every bullet is defensible** — each maps to a specific file and implementation in this repo. Know the code behind the claim.
- **Quantify when asked** — estimates in parentheses below each bullet.

---

## Tier 1 — Architecture / Lead Bullets (FSC + OmniStudio Architect roles)

---

**A1. Designed and delivered a production-grade FSC + OmniStudio Wealth Management system for a regional bank — covering digital client onboarding, Customer 360 household view, and real-time loan eligibility decisioning across 14 Apex classes, 2 OmniScripts, 4 DataRaptors, 2 Integration Procedures, and 2 FlexCards.**

> Use for: FSC Architect, OmniStudio Architect, Senior Developer
> Depth: Covers full stack end-to-end. Expect follow-up on any component.

---

**A2. Architected a zero-coupling Callable interface bridge between OmniStudio Integration Procedures and Salesforce Apex services — enabling 7 IP → Apex action routes (loan eligibility, KYC, credit scoring, portfolio health) without compile-time dependencies, reducing deployment friction across package boundaries.**

> Expect: "Why Callable over @InvocableMethod?" → IP's ApexAction step calls Callable, not InvocableMethod. The IP references a string class name — the Apex class can be renamed/replaced without redeploying the IP. Also easier to mock in tests (inject stub Callable).

---

**A3. Designed a dual-mode Integration Procedure (LoanEligibilityIP) that serves two OmniScript call patterns from a single definition — CALCULATE_DTI (fast path: steps 1–5 only, sub-2s, used on Step 2 load) and FULL_ELIGIBILITY (complete pipeline: 14 steps, credit callout, DR upsert, approval routing, used on Submit) — eliminating duplicate orchestration logic across two IPs.**

> Expect: "How does the early exit work?" → OmniStudio IP stops execution at a Response element. A Conditional at element 5 nests a Response in its trueElements — execution stops there for CALCULATE_DTI mode.

---

**A4. Implemented a 3-level DataRaptor Extract hierarchy (Account → FinancialAccount__c → FinancialHolding__c + AssetsAndLiabilities__c) replacing 4 SOQL queries and 80+ lines of Apex map stitching with a single declarative definition — delivering sub-300ms household data retrieval with 5-minute FlexCard cache.**

> Expect: "How do the levels work?" → Level 0 = root Account, Level 1 = direct children (FA + AAL), Level 2 = grandchildren (Holdings under FA). OmniStudio executes separate SOQL per level and assembles the JSON tree.

---

**A5. Led the FSC data model design — selected Household Account model over Individual Account model to support FSC rollup summaries, co-applicant loan modeling, and advisor-at-household assignment; designed LoanApplication__c (12 custom fields) as the loan origination object absent from FSC managed package.**

> Expect: "Why not use the FSC managed FinancialAccount object?" → Cannot write Apex triggers on FSC managed objects in some org configs; ExternalAccountId__c for core banking sync not present on managed object; full ownership of trigger/handler/service layer.

---

## Tier 2 — OmniStudio Specialist Bullets

---

**B1. Engineered a 4-step ClientOnboarding OmniScript with masked SSN input, conditional employer section, Integration Procedure Action for server-side KYC + credit score orchestration, and a built-in Review element — replacing a 400+ line LWC wizard while making all business rules admin-configurable without deployment.**

> Expect: "What does the IP Action do differently from a callout in LWC?" → IP Action calls the Integration Procedure server-side. No client-side callout — the 2 HTTP requests (KYC + credit bureau) are made within the IP execution, not from the browser. No callout governor limit exposure on the LWC side.

---

**B2. Built a DataRaptor Transform with 5 named transformation blocks handling SSN normalization (strip/mask), ISO date conversion, credit bureau response mapping, outbound API request assembly, and composite summary construction — replacing ~80 lines of Apex field-mapping code with admin-modifiable declarative transforms.**

> Expect specific transform: SSN → `Replace` strips hyphens for API, `Mask` hides first 5 chars for display. DateFormat converts MM/DD/YYYY (OmniScript output) to YYYY-MM-DD (API expectation). Lookup transform maps credit band code → human-readable label.

---

**B3. Designed an idempotent OmniScript submission pipeline using SHA-256–generated External IDs on LoanApplication__c and DataRaptor Load upsert operations — ensuring duplicate-free record creation on browser back/resubmit scenarios with zero custom dedup logic.**

> Expect: "How is the External ID generated?" → `LoanApplicationTriggerHandler.generateExternalId()` computes SHA-256 of `applicantId + loanType + timestamp`. The same inputs from the same session produce the same hash — the DR upserts the existing record.

---

**B4. Developed Household 360 and Loan Application Status FlexCards with expression-driven health banding (GREEN/YELLOW/RED), FICO score progress bar (300–850 normalized to 0–100%), context-sensitive action buttons (Submit for Review invokes LoanEligibilityIP directly from the card with confirmation dialog), and LTV calculation inline — with no custom JavaScript.**

> Expect: "How does the health band color work?" → FlexCard `badge.variant` uses an expression: `{balance} >= 10000 ? 'success' : ({balance} >= 1000 ? 'warning' : 'error')`. Same expression drives `backgroundColor`. Pure declarative — no JS.

---

## Tier 3 — Apex / Senior Developer Bullets

---

**C1. Implemented a governor-limit-aware LoanEligibilityService with 30-day credit score caching (checks `CreditScoreFetchedAt__c` before calling credit bureau API), DTI calculation, three-tier approval routing (Branch Manager < $100k, Director $100k–$500k, Executive > $500k), and an async Queueable wrapper for callout execution from trigger context.**

> Expect: "Why cache the credit score?" → Credit bureau APIs charge per inquiry. A 30-day TTL is the industry standard for "still valid for decisioning." Consistency: same score shown to loan officer across multiple views.

---

**C2. Designed a LoanApplication__c status state machine enforced in the trigger handler using a Map<String, Set<String>> valid transitions table — blocking all invalid backward transitions (e.g., FUNDED → DRAFT) with field-level addError() messages, with 100% transition matrix test coverage.**

> Know the table: DRAFT → SUBMITTED, SUBMITTED → IN_REVIEW/DECLINED, IN_REVIEW → APPROVED/DECLINED, APPROVED → FUNDED. All others rejected.

---

**C3. Built a resilient KycValidationService with SSN format regex validation (Pattern.compile), OFAC sanctions check via Named Credential callout, and composite identity verification — with a configurable match score threshold (>85 = blocked) to handle fuzzy OFAC name matches without blocking on low-confidence results.**

> Expect: "Why 85 threshold?" → OFAC match scores are probabilistic. A score of 60 might be a common name coincidence. 85+ indicates high confidence of match. Anything below 85 routes to manual review rather than blocking.

---

**C4. Enforced field-level security across all 8 Apex service classes using `WITH USER_MODE` on every SOQL query and `update as user` on all DML — ensuring FLS/CRUD is enforced at runtime for the running user without a single `Security.stripInaccessible()` call, reducing code complexity while maintaining security-by-default.**

> Expect: "What's the difference from WITH SECURITY_ENFORCED?" → `WITH SECURITY_ENFORCED` throws an exception if any field is inaccessible. `WITH USER_MODE` silently omits inaccessible fields. Safer for FlexCard-facing queries where the advisor may have partial field visibility.

---

**C5. Engineered a `CreditScoreMock` implementing `HttpCalloutMock` with 8 configurable response types (CREDIT_SCORE_SUCCESS, HIGH, LOW, HTTP_ERROR, OFAC_NO_MATCH, OFAC_MATCH, OFAC_HTTP_ERROR, CORE_BANKING_BALANCE) — enabling 44 unit tests across 3 test classes with 90%+ service layer coverage without live external API dependencies.**

> Expect: "How do you test the credit cache path?" → Pre-populate `CreditScore__c` and `CreditScoreFetchedAt__c = Datetime.now()` on the test LoanApplication__c record. Call `scoreEligibility()` without setting a mock. If the test passes without `Test.setMock()`, the cache path was taken — any callout attempt would throw a `CalloutException` in test context.

---

## Tier 4 — Integration / Cross-Cloud Bullets

---

**D1. Implemented secure external API integration for Credit Bureau and KYC provider callouts using Salesforce Named Credentials — eliminating hardcoded API keys from all code, DataRaptor configurations, and Integration Procedure definitions, with endpoint-per-environment separation across Dev/Sandbox/Production.**

---

**D2. Designed a core banking balance sync using `FinancialAccountService.syncBalanceFromCoreBanking()` with Named Credential callout, `ExternalAccountId__c` validation, and `LastSyncedDateTime__c` timestamp — callable from both Apex (batch sync) and FlexCard action button (single-record on-demand sync) via the same service method.**

---

**D3. Built an error-resilient Integration Procedure pipeline with three distinct `onError` strategies per step: `SetValueAndContinue` for external API failures (credit bureau outage → MANUAL_REVIEW, not false DECLINED), `ThrowException` for DML persistence failures, and `SetValueAndContinue` for notification failures — satisfying the bank's regulatory requirement that no loan application can be silently dropped.**

---

## Bullet Selection Guide by Role

| Role | Recommended Bullets |
|---|---|
| **FSC Architect** | A1, A2, A3, A5, B1, C1 |
| **OmniStudio Architect / Developer** | A1, A3, A4, B1, B2, B3, B4 |
| **Senior Salesforce Developer** | A2, C1, C2, C3, C4, C5 |
| **Integration Architect** | A2, D1, D2, D3, C1 |
| **Technical Lead / Principal** | A1, A2, A3, A5, D3, C2 |

---

## STAR Story — "Tell Me About a Complex Project"

**Situation:** A regional bank needed to modernize their wealth management operations — manual onboarding, no Customer 360, no automated loan decisioning.

**Task:** Design and build a production-grade system on FSC + OmniStudio from scratch: digital onboarding, household portfolio view, real-time loan eligibility.

**Action:**
- Chose FSC Household model over Individual Account for aggregate financial planning and co-applicant support
- Designed OmniStudio-first for the client-facing layer (OmniScript, DataRaptor, IP, FlexCard) to minimize deployment friction and enable admin configurability
- Built Callable interface bridge between IPs and Apex services for zero compile-time coupling
- Implemented dual-mode IP to serve two OmniScript call patterns from a single definition
- Enforced FLS via `WITH USER_MODE` across all service classes; all callouts via Named Credentials
- Engineered 30-day credit score cache and idempotent External ID upsert for production resilience

**Result:**
- 14 Apex classes, 2 OmniScripts, 4 DataRaptors, 2 Integration Procedures, 2 FlexCards — all version-controlled in SFDX source format
- 44 unit tests, 90%+ service layer coverage
- Full onboarding (KYC + credit score + Account + FinancialAccount__c creation) in a single OmniScript submission, sub-5 second end-to-end
- No hardcoded credentials anywhere in the codebase
- Zero duplicate records on retry due to ExternalId upsert strategy

---

## One-Liner Summary (LinkedIn / Resume Header)

> Built a production-grade Salesforce FSC + OmniStudio Wealth Management system — digital onboarding with live KYC and credit scoring, Household 360 FlexCard with portfolio health visualization, and real-time loan eligibility pipeline with automated approval routing — across 14 Apex classes, 2 OmniScripts, 4 DataRaptors, 2 Integration Procedures, and 2 FlexCards.
