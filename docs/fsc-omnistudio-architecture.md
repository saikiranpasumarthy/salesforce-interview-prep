# FSC + OmniStudio Wealth Management System — Architecture Document

**Project:** Retail Banking and Wealth Management — Digital Onboarding, Customer 360, Loan Eligibility  
**Cloud Stack:** Financial Services Cloud (FSC) · OmniStudio · Salesforce Platform  
**Author:** Saikiran Pasumarthy  
**API Version:** 62.0  
**Branch:** `project-fsc-omnistudio-wealth-management`

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Diagram](#2-architecture-diagram)
3. [FSC Data Model Decisions](#3-fsc-data-model-decisions)
4. [Why OmniStudio Over LWC](#4-why-omnistudio-over-lwc)
5. [Integration Strategy](#5-integration-strategy)
6. [Security Model](#6-security-model)
7. [Scalability Considerations](#7-scalability-considerations)
8. [Deployment Notes](#8-deployment-notes)

---

## 1. Project Overview

### Business Context

A mid-size regional bank is modernizing its retail banking and wealth management operations on Salesforce FSC. The system serves three primary personas:

| Persona | Primary Use Case |
|---|---|
| **Wealth Advisor** | 360-degree household view, portfolio health, proactive next-best-action |
| **Loan Officer** | Digital loan origination, eligibility scoring, document collection |
| **Client (Self-Service)** | Experience Cloud portal — onboarding, account summary, loan status |

### Functional Scope

1. **Digital Client Onboarding** — guided OmniScript wizard capturing KYC, employment, and financial profile data; DataRaptor Load into FSC objects; real-time credit score callout
2. **Customer 360 (Household View)** — FlexCard on Account record showing all financial accounts, holdings, assets/liabilities, and household member relationships
3. **Loan Eligibility Engine** — Integration Procedure orchestrating credit score fetch, debt-to-income calculation, regulatory compliance checks, and approval routing
4. **Portfolio Health Dashboard** — FlexCard aggregating FinancialHolding__c data with performance bands (GREEN/YELLOW/RED)

### Non-Functional Requirements

- **Governor Limits**: All Apex is bulkified; OmniStudio Integration Procedures replace callout-heavy LWC
- **Security**: FLS/CRUD enforced via `WITH USER_MODE`; Named Credentials for all external callouts
- **Testability**: 85%+ Apex coverage; OmniStudio components testable via Integration Procedure mock inputs
- **Deployability**: Full SFDX source-tracked; OmniStudio components exported as JSON for version control

---

## 2. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                     PRESENTATION LAYER                              │
│                                                                     │
│  ┌─────────────────────┐    ┌──────────────────────────────────┐   │
│  │  FlexCard: Household │    │  OmniScript: ClientOnboarding    │   │
│  │  360 View            │    │  (Guided Wizard — 4 steps)       │   │
│  │  - FinancialAccounts │    │  - Personal Info                 │   │
│  │  - Holdings          │    │  - Employment & Income           │   │
│  │  - Assets/Liab       │    │  - Financial Profile             │   │
│  │  - Net Worth         │    │  - Review & Submit               │   │
│  └──────────┬──────────┘    └────────────────┬─────────────────┘   │
│             │                                │                     │
│  ┌──────────▼──────────┐    ┌────────────────▼─────────────────┐   │
│  │  FlexCard: Loan      │    │  OmniScript: LoanApplication     │   │
│  │  Application Status  │    │  (Loan Origination — 3 steps)    │   │
│  └──────────┬──────────┘    └────────────────┬─────────────────┘   │
└─────────────┼───────────────────────────────┼─────────────────────┘
              │                               │
┌─────────────▼───────────────────────────────▼─────────────────────┐
│                   ORCHESTRATION LAYER (OmniStudio)                  │
│                                                                     │
│  ┌────────────────────────────┐  ┌──────────────────────────────┐  │
│  │ Integration Procedure:      │  │ Integration Procedure:        │  │
│  │ ClientOnboardingIP          │  │ LoanEligibilityIP             │  │
│  │ - DR: ExtractHousehold      │  │ - Callout: CreditScoreAPI     │  │
│  │ - Callout: CreditScoreAPI   │  │ - Apex: LoanEligibilityService│  │
│  │ - DR: LoadClientProfile     │  │ - DR: LoanDecisionDR          │  │
│  │ - DR: TransformForKyc       │  │ - Routing: ApprovalMatrix     │  │
│  └────────────────────────────┘  └──────────────────────────────┘  │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  DataRaptors                                                │    │
│  │  - DR-Extract: HouseholdExtract  (Account + FA + FH + AAL) │    │
│  │  - DR-Load: ClientProfileLoad    (Account + FA upsert)     │    │
│  │  - DR-Transform: KycTransform    (normalize field mapping) │    │
│  │  - DR-Load: LoanDecisionLoad     (LoanApplication__c)      │    │
│  └────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
              │                               │
┌─────────────▼───────────────────────────────▼─────────────────────┐
│                      APEX SERVICE LAYER                             │
│                                                                     │
│  FinancialAccountTrigger → FinancialAccountTriggerHandler           │
│  LoanApplicationTrigger  → LoanApplicationTriggerHandler           │
│                                                                     │
│  ┌──────────────────────┐  ┌──────────────────────┐               │
│  │ FinancialAccountSvc  │  │ LoanEligibilitySvc    │               │
│  │ - householdNetWorth()│  │ - scoreEligibility()  │               │
│  │ - portfolioHealth()  │  │ - calcDebtToIncome()  │               │
│  │ - rebalanceAlert()   │  │ - routeToApproval()   │               │
│  └──────────────────────┘  └──────────────────────┘               │
│                                                                     │
│  ┌──────────────────────┐  ┌──────────────────────┐               │
│  │ CreditScoreService   │  │ KycValidationService  │               │
│  │ (Named Credential)   │  │ - validateSsn()       │               │
│  │ - fetchScore()       │  │ - checkOfac()         │               │
│  │ - interpretBand()    │  │ - verifyIdentity()    │               │
│  └──────────────────────┘  └──────────────────────┘               │
│                                                                     │
│  WealthManagementCallable implements Callable                       │
│  (OmniStudio → Apex integration via zero-compile coupling)          │
└─────────────────────────────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────────────────────────┐
│                      FSC DATA MODEL LAYER                            │
│                                                                     │
│  Account (PersonAccount / Household)                                │
│    └─ FinancialAccount__c  (Bank Account, Investment, Retirement)   │
│         └─ FinancialHolding__c  (individual securities/positions)   │
│    └─ AssetsAndLiabilities__c   (real estate, vehicles, mortgages)  │
│    └─ LoanApplication__c        (custom — origination tracking)     │
│    └─ AccountAccountRelation    (FSC Household membership)          │
└─────────────────────────────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────────────────────────┐
│                    EXTERNAL SYSTEMS                                  │
│                                                                     │
│  CreditBureauAPI (Named Credential: CreditBureauNC)                 │
│    POST /v1/scores  →  { score: 742, band: "GOOD", ... }           │
│                                                                     │
│  CoreBankingSystem (Named Credential: CoreBankingNC)                │
│    GET /accounts/{extId}  →  balance, transactions, status          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. FSC Data Model Decisions

### 3.1 Core FSC Objects Used

| FSC Object | Standard or Custom | Purpose in This Project |
|---|---|---|
| `FinancialAccount` (FSC managed) | Standard (FSC package) | Bank accounts, investment accounts, retirement accounts |
| `FinancialHolding` (FSC managed) | Standard (FSC package) | Individual security positions within a FinancialAccount |
| `AssetsAndLiabilities` (FSC managed) | Standard (FSC package) | Real estate, vehicles, mortgages, other assets/debts |
| `AccountAccountRelation` | Standard (FSC package) | Household membership — linking persons to a household Account |
| `LoanApplication__c` | Custom | Loan origination tracking; not in FSC managed package |

> **Note:** FSC managed package objects (`FinancialAccount`, `FinancialHolding`, `AssetsAndLiabilities`) cannot be modified with custom triggers in orgs where FSC is installed via managed package. The `LoanApplication__c` custom object is fully controllable.

### 3.2 Why PersonAccount + Household

FSC uses the **Household Account model**: a Household is a regular Account record, and individual clients are Person Accounts linked via `AccountAccountRelation`. This enables:

- Aggregate net worth calculations across all household members
- Advisor assignment at the household level
- FSC's built-in Rollup Summary for household-level financial totals

**Alternative considered**: Individual Account model — rejected because it cannot aggregate financials across spouses/dependents and lacks household rollup support.

### 3.3 LoanApplication__c Custom Object

The FSC managed package does not include a loan origination object. Design decisions:

| Field | Type | Rationale |
|---|---|---|
| `Applicant__c` | Lookup(Account) | Links to PersonAccount (the borrower) |
| `Household__c` | Lookup(Account) | Links to Household for co-applicant support |
| `LoanType__c` | Picklist | MORTGAGE / AUTO / PERSONAL / HELOC |
| `RequestedAmount__c` | Currency | Requested principal |
| `AnnualIncome__c` | Currency | Self-reported income |
| `CreditScore__c` | Number | Fetched from Credit Bureau API at submission |
| `DebtToIncomeRatio__c` | Percent | Calculated by LoanEligibilityService |
| `EligibilityDecision__c` | Picklist | AUTO_APPROVED / MANUAL_REVIEW / DECLINED |
| `ExternalId__c` | Text(36), External ID | For idempotent upsert from OmniScript |
| `Status__c` | Picklist | DRAFT / SUBMITTED / IN_REVIEW / APPROVED / DECLINED / FUNDED |

### 3.4 FinancialAccount__c — Custom Extension Object

Because the FSC managed `FinancialAccount` object may have field-add restrictions in some org configurations, this project uses a companion custom object `FinancialAccount__c` that mirrors key fields and adds project-specific ones:

| Field | Type | Purpose |
|---|---|---|
| `Account__c` | Lookup(Account) | Parent household or person account |
| `AccountType__c` | Picklist | CHECKING / SAVINGS / INVESTMENT / RETIREMENT / CREDIT |
| `Balance__c` | Currency | Current balance |
| `ExternalAccountId__c` | Text(50), External ID | Core banking system ID |
| `PortfolioHealthBand__c` | Formula(Text) | GREEN / YELLOW / RED based on balance thresholds |
| `LastSyncedDateTime__c` | DateTime | When balance was last synced from core banking |
| `IsActive__c` | Checkbox | Soft-delete flag |

---

## 4. Why OmniStudio Over LWC

### 4.1 Decision Matrix

| Capability | LWC | OmniStudio | Winner |
|---|---|---|---|
| Guided multi-step wizard with conditional branching | Requires custom state management, significant JS | OmniScript — declarative step/element configuration | **OmniStudio** |
| Data extraction + transformation without Apex | Not possible | DataRaptor Extract + Transform | **OmniStudio** |
| Orchestrating multiple callouts + DML in sequence | Requires Apex service class | Integration Procedure — no Apex needed | **OmniStudio** |
| Pixel-perfect custom UI with complex interactions | Full control | FlexCard has limits | **LWC** |
| Apex unit testability | Full framework | IP testable via mock inputs; OmniScript less testable | **LWC** |
| Admin configurability without deployment | None — code change required | Fully declarative, admin-modifiable | **OmniStudio** |
| FSC record page summaries (read-mostly) | Works; verbose | FlexCard — purpose-built for summary cards | **OmniStudio** |

### 4.2 OmniStudio Component Selection

**OmniScript** — used when:
- User interaction requires 2+ steps with conditional navigation
- Data needs to be collected and validated before submission
- The flow should be configurable by admins without code changes

**DataRaptor** — used when:
- Data needs to be read from or written to Salesforce without writing Apex
- Field-to-field mapping/transformation is needed (e.g., normalize external API response to Salesforce fields)

**Integration Procedure** — used when:
- Multiple steps need to be orchestrated (fetch data → call API → transform → write)
- Replaces what would otherwise be an Apex class with callouts
- The orchestration should be admin-modifiable

**FlexCard** — used when:
- Record page needs a summary card with child data (financial accounts, holdings)
- The card is primarily read-only with action buttons

### 4.3 Callable Interface Bridge

OmniStudio Integration Procedures can invoke Apex via the **Callable interface** — this is the integration pattern used throughout this project:

```
Integration Procedure
    └─ Apex Action step → WealthManagementCallable.call('calculateLoanEligibility', args)
                                └─ LoanEligibilityService.scoreEligibility(input)
```

**Why Callable over direct `@InvocableMethod`?**

- Integration Procedures invoke Apex through a registered Callable class, not InvocableMethods
- Callable provides zero compile-time coupling — the IP references a string class name
- Single Callable class can route to multiple service methods via the `action` parameter
- Easier to mock in tests (inject a stub Callable)

---

## 5. Integration Strategy

### 5.1 External Systems

| System | Auth | Protocol | Pattern |
|---|---|---|---|
| Credit Bureau API | API Key (Named Credential: `CreditBureauNC`) | REST/JSON | Request-Response; called synchronously from Integration Procedure |
| Core Banking System | OAuth2 Client Credentials (Named Credential: `CoreBankingNC`) | REST/JSON | Pull-on-demand; triggered by FlexCard load via DataRaptor HTTP Action |

### 5.2 Credit Score API Flow

```
OmniScript: ClientOnboarding
    └─ Step 3 (Financial Profile) onNext
         └─ Integration Procedure: ClientOnboardingIP
              └─ HTTP Action: POST CreditBureauNC/v1/scores
                   └─ Response: { score, band, factors[] }
              └─ DataRaptor Transform: CreditScoreTransform
                   └─ Maps score → CreditScore__c, band → EligibilityBand__c
              └─ DataRaptor Load: ClientProfileLoad
                   └─ Upserts LoanApplication__c via ExternalId__c
```

### 5.3 Idempotency

All Integration Procedure loads use External ID upsert to prevent duplicate record creation on retry. The `ExternalId__c` field on `LoanApplication__c` is set by the OmniScript at wizard start (UUID generated client-side or via Apex).

### 5.4 Error Handling Pattern

```
Integration Procedure step:
    errorHandling: true
    └─ On error → set error flag in IP context
         └─ OmniScript conditionally shows error step
              └─ Advisor/user can retry or escalate

Apex (WealthManagementCallable):
    try { ... }
    catch (CalloutException e) { throw new AuraHandledException(e.getMessage()); }
```

---

## 6. Security Model

### 6.1 Permission Set Architecture

| Permission Set | Assigned To | Key Permissions |
|---|---|---|
| `WealthAdvisor_PS` | Wealth Advisors | Read/Edit FinancialAccount__c, FinancialHolding__c, AssetsAndLiabilities__c; Invoke OmniScripts |
| `LoanOfficer_PS` | Loan Officers | Read/Edit LoanApplication__c; Create/Edit FinancialAccount__c |
| `WealthAdmin_PS` | System Admins | All objects; Configure OmniStudio components |

### 6.2 OWD and Sharing

| Object | OWD | Reason |
|---|---|---|
| `FinancialAccount__c` | Private | Financial data — only owner/advisor should see |
| `LoanApplication__c` | Private | Loan data is sensitive; sharing via role hierarchy |
| `AssetsAndLiabilities__c` | Private | PII-adjacent financial data |

Sharing is controlled via role hierarchy: Loan Officers are below Branch Managers who are below Regional Managers — each level can view subordinates' records.

### 6.3 Apex Security

All SOQL in service classes uses `WITH USER_MODE` to enforce FLS and CRUD at runtime:

```apex
List<FinancialAccount__c> accounts = [
    SELECT Id, Balance__c, AccountType__c
    FROM FinancialAccount__c
    WHERE Account__c = :householdId
    WITH USER_MODE
    ORDER BY Balance__c DESC
];
```

All upserts via Integration Procedure DataRaptor Load respect FLS through the OmniStudio runtime's built-in FLS checking.

### 6.4 Named Credentials

All external callouts use Named Credentials — no API keys in code or Custom Settings. Named Credential stores:
- Endpoint URL
- Auth header (API Key or OAuth2 token)
- Certificate pinning (for production)

---

## 7. Scalability Considerations

### 7.1 Bulk Operations

| Scenario | Volume | Solution |
|---|---|---|
| Nightly balance sync from core banking | 50,000+ FinancialAccount__c records | Batch Apex (`FinancialAccountSyncBatch`) in chunks of 200 |
| Mass loan application import | 10,000+ LoanApplication__c | Bulk API 2.0 ingest job + DataRaptor Load in IP |
| Portfolio health recalculation | All active accounts | Scheduled Apex trigger + Platform Event fan-out |

### 7.2 Governor Limit Protections

- **SOQL queries**: Selector pattern with `WITH USER_MODE`; no SOQL in loops
- **DML**: Unit of Work pattern — collect all records, single DML per object type per transaction
- **Callouts**: One callout per Integration Procedure step; IP steps are not subject to Apex callout limits when run in OmniStudio context (they use their own HTTP execution context)
- **Heap**: DataRaptor Extract uses server-side cursor for large datasets

### 7.3 Caching

- `Schema.getGlobalDescribe()` called once per request via static lazy-init map
- Credit score results cached in `LoanApplication__c.CreditScore__c` — re-fetch only if score is older than 30 days (checked in `LoanEligibilityService`)
- FlexCard data cached via OmniStudio DataRaptor cache settings (TTL configurable per card)

### 7.4 OmniStudio Performance

- DataRaptor Extracts use `Filter` conditions to limit returned records
- Integration Procedures use `Conditional` steps to short-circuit paths that aren't needed
- OmniScripts use `Remote Action` only where declarative options are insufficient

---

## 8. Deployment Notes

### 8.1 Prerequisites

| Prerequisite | Notes |
|---|---|
| FSC managed package installed | Version 238.x or later; includes FinancialAccount, FinancialHolding, AccountAccountRelation objects |
| OmniStudio installed | Vlocity/Salesforce OmniStudio package; or Industries license with embedded OmniStudio |
| Named Credentials created | `CreditBureauNC`, `CoreBankingNC` — must be created in target org; not deployable via SFDX |
| Person Accounts enabled | Required for FSC Household model |
| Financial Services Cloud settings | Enable Household model in FSC settings |

### 8.2 Deployment Order

```
1. Custom Objects + Fields
   └─ FinancialAccount__c, FinancialHolding__c, AssetsAndLiabilities__c, LoanApplication__c

2. Permission Sets
   └─ WealthAdvisor_PS, LoanOfficer_PS, WealthAdmin_PS

3. Custom Metadata
   └─ LoanEligibilityThreshold__mdt (approval thresholds by loan type)

4. Apex Classes (TriggerHandler framework first, then Services, then Callable)
   └─ TriggerHandler → FinancialAccountTriggerHandler → FinancialAccountService
   └─ TriggerHandler → LoanApplicationTriggerHandler → LoanEligibilityService
   └─ CreditScoreService, KycValidationService, WealthManagementCallable

5. Apex Triggers
   └─ FinancialAccountTrigger, LoanApplicationTrigger

6. OmniStudio Components (imported via OmniStudio Designer or Data Pack)
   └─ DataRaptors (Extract → Transform → Load order)
   └─ Integration Procedures
   └─ OmniScripts
   └─ FlexCards

7. Run Apex Tests
   └─ sf apex run test --class-names FinancialAccountServiceTest,LoanEligibilityServiceTest,...
```

### 8.3 OmniStudio Version Control Strategy

OmniStudio components (OmniScript, DataRaptor, Integration Procedure, FlexCard) are version-controlled as JSON in the `omnistudio/` directory. Deployment options:

| Method | When to Use |
|---|---|
| OmniStudio Data Pack (JSON import/export) | Dev → Sandbox promotion; stored as JSON files in this repo |
| OmniStudio Metadata API (SFDX) | Available in newer OmniStudio versions; preferred for CI/CD |
| Manual recreation | Last resort for small config changes |

**Recommendation**: Export all OmniStudio components as Data Packs to `omnistudio/` directory after every meaningful change. Commit to Git. Import via OmniStudio Data Pack Import tool in target org.

### 8.4 Testing Strategy

| Layer | Test Approach |
|---|---|
| Apex Services | Unit tests with `@isTest`; mock callouts via `HttpCalloutMock` |
| Apex Triggers | Bulk test (200 records), SOQL limit assertion |
| WealthManagementCallable | Test each action via `Callable.call()` |
| Integration Procedures | Test via OmniStudio IP Test tab with mock HTTP responses |
| OmniScripts | Manual test via Preview mode; E2E via test scripts |
| FlexCards | Manual test on record pages in sandbox |

### 8.5 Scratch Org Setup

```bash
# Create scratch org with FSC + OmniStudio features
sf org create scratch \
  --definition-file fsc-project/config/project-scratch-def.json \
  --alias wealth-mgmt-dev \
  --duration-days 30

# Deploy all metadata
sf project deploy start \
  --source-dir fsc-project/force-app \
  --target-org wealth-mgmt-dev

# Run tests
sf apex run test \
  --target-org wealth-mgmt-dev \
  --result-format human \
  --wait 15
```

---

## Summary: Architecture Decisions at a Glance

| Decision | Choice | Alternative Rejected | Reason |
|---|---|---|---|
| UI layer for onboarding | OmniScript | LWC wizard | Declarative, admin-configurable, no JS state management |
| UI layer for record summary | FlexCard | LWC component | Purpose-built for FSC record page summaries |
| Orchestration | Integration Procedure | Apex + callouts | Admin-modifiable, no DML limits, reusable across OmniScripts |
| Data mapping | DataRaptor | Apex mapper class | Zero-code field mapping; version controlled as JSON |
| Apex-OmniStudio bridge | Callable interface | @InvocableMethod | IP invokes Callable; zero compile-time coupling |
| Credit score callout | Named Credential | Custom Setting + hardcoded | Secure, deployable, supports multiple environments |
| Loan origination object | LoanApplication__c (custom) | FSC managed object | FSC package doesn't include loan origination; custom gives full control |
| Data access | WITH USER_MODE | SYSTEM_MODE | Enforces FLS/CRUD; security-by-default |
| Household model | PersonAccount + AccountAccountRelation | Individual Account | FSC rollup support, co-applicant modeling, advisor assignment |
