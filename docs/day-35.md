# Day 35 — Industry Clouds Overview, OmniStudio Basics, FlexCards

## Topics Covered

- Industry Clouds overview (FSC, Health Cloud, Manufacturing Cloud, Consumer Goods Cloud)
- OmniStudio components: Integration Procedures, DataRaptors, OmniScript
- FlexCards — data sources, actions, child cards
- FSC Household model, FinancialAccount, RecordAlert, ActionPlan
- Health Cloud — CareProgram, CareProgramEnrollee
- Calling Integration Procedures from Apex via Callable interface
- Graceful degradation patterns for managed packages

---

## Industry Clouds — Overview

| Cloud | Key Use Case | Key Objects / Features |
|-------|-------------|------------------------|
| **Financial Services Cloud (FSC)** | Wealth management, banking, insurance | Household model, FinancialAccount, RecordAlert, ActionPlan, RollupByLookup |
| **Health Cloud** | Patient / member management | CareProgram, CareProgramEnrollee, CarePlanActivity, HealthCondition |
| **Manufacturing Cloud** | Account forecasting, partner management | AccountForecast, SalesAgreement, BusinessBrand |
| **Consumer Goods Cloud** | Route planning, store execution | RetailStore, AssessmentTask, RetailVisit |
| **Education Cloud** | Student lifecycle management | Application, ProgramEnrollment, CourseOffering |
| **Nonprofit Cloud** | Fundraising, programme management | GAU, Opportunity (Donation), Program, ProgramEngagement |

All Industry Clouds sit on top of the core Salesforce platform — all standard Apex, SOQL, Flow, and LWC patterns apply. They add managed packages with domain-specific objects and UX components.

---

## OmniStudio Components

### Component Map

```
OmniScript (guided UI process)
  └─ Steps: FormStep, DataRaptorStep, IntegrationProcedureStep, NavigationStep, etc.
  └─ Actions: callout to IP or DR

Integration Procedure (serverside orchestration)
  └─ Calls: DataRaptors, HTTP Actions, Apex, Set Values, Loops, Conditions

DataRaptor (data I/O)
  ├─ Extract       — SOQL → JSON
  ├─ TurboExtract  — optimised read-only Extract (with caching)
  ├─ Load          — JSON → DML (insert/update/upsert/delete)
  └─ Transform     — reshape/filter JSON

FlexCard (contextual display)
  └─ Data Sources: DataRaptor, Integration Procedure, SOQL, Apex Remote, REST
  └─ Actions: OmniScript launch, Flow launch, Navigation
  └─ Child cards, conditional visibility, flyout panels
```

### Integration Procedure vs DataRaptor

| | Integration Procedure | DataRaptor |
|--|----------------------|------------|
| Purpose | Orchestration — combine multiple data sources | Single data operation (read or write) |
| Can call | Other IPs, DataRaptors, HTTP, Apex, Set Values | N/A (no sub-calls) |
| Key format | `{Type}_{Name}` — e.g. `Account_GetSummary` | Named by interface API name |
| Called from | OmniScript, FlexCard, Apex, REST | OmniScript, FlexCard, IP |
| Equivalent to | A mini-Flow (serverside) | SOQL query or DML (declarative) |

---

## Calling Integration Procedures from Apex

### Callable Interface Pattern (recommended)

Uses `Type.forName` + `Callable` — compiles and deploys to orgs **without** the OmniStudio package installed (no compile-time dependency):

```apex
Type ipType = Type.forName('omnistudio', 'IntegrationProcedureService');
if (ipType == null) {
    return new Map<String, Object>{ 'error' => 'OmniStudio not installed' };
}

Map<String, Object> args = new Map<String, Object>{
    'input'   => inputMap,
    'options' => new Map<String, Object>{ 'useContinuation' => false },
    'output'  => new Map<String, Object>()
};
// call(procedureKey, args) — key format: "TypeName_ProcedureName"
Object result = ((Callable) ipType.newInstance()).call('Account_GetSummary', args);
Map<String, Object> output = (Map<String, Object>) result;
```

### IP Key Format

```
{TypeName}_{ProcedureName}
e.g.:
  Account_GetFinancialSummary
  Opportunity_CalculateDiscount
  Case_RouteToQueue
  Patient_GetCarePlan
```

### Direct Reference Pattern (when package is installed)

```apex
// Only use if omnistudio package is always deployed in this org
omnistudio.IntegrationProcedureService ipService =
    new omnistudio.IntegrationProcedureService();
Map<String, Object> result = (Map<String, Object>)
    ipService.runIntegrationService('Account_GetSummary', inputMap, optionsMap);
```

---

## Calling DataRaptors from Apex

```apex
Type drType = Type.forName('omnistudio', 'DRProcessService');
Map<String, Object> args = new Map<String, Object>{
    'input'   => inputMap,
    'options' => new Map<String, Object>{
        'drName' => 'AccountExtract',
        'drType' => 'TurboExtract'   // 'Extract', 'TurboExtract', 'Load', 'Transform'
    }
};
Object result = ((Callable) drType.newInstance()).call('AccountExtract', args);
```

---

## FlexCard Data Sources

```
1. DataRaptor Extract   — declarative SOQL → JSON binding
2. Integration Procedure — multi-source orchestrated data
3. SOQL                  — inline query on FlexCard designer
4. Apex Remote           — @AuraEnabled method; must be cacheable=true for read-only
5. REST / Apex REST      — external API via Named Credential
```

### Apex Remote data source method signature

```apex
@AuraEnabled(cacheable=true)
public static FlexCardData getFlexCardData(Id recordId, Map<String, Object> params) {
    // recordId is passed automatically by the FlexCard context
    // params are additional configuration defined in FlexCard designer
}
```

---

## FSC — Household Model

```
Standard CRM model:          FSC Household model:
Account ← Contact            Account (Household RecordType)
  one-to-many                  └─ AccountContactRelation (ACR)
                                     └─ Contact (Individual RecordType)
                                     └─ Contact (Financial Advisor)
                                     └─ Contact (Secondary owner)
```

```apex
// Create Household + primary Contact
Account household = new Account(
    Name         = 'Smith Household',
    RecordTypeId = getHouseholdRecordTypeId()  // 'IndustriesHousehold'
);
insert household;

Contact primary = new Contact(
    FirstName  = 'Jane', LastName = 'Smith',
    AccountId  = household.Id
);
insert primary;

// Query household members via ACR
SELECT ContactId, Contact.FirstName, Roles, IsActive
FROM AccountContactRelation
WHERE AccountId = :household.Id AND IsActive = true
```

---

## FSC — FinancialAccount

`FinancialAccount__c` is the core FSC object for all financial products:

```
Types: SavingsDeposit, CheckingDeposit, CertificateOfDeposit,
       Investment, RetirementAccount, InsurancePolicy, TrustAccount,
       CreditCard, PersonalLoan, Mortgage, AutoLoan, StudentLoan
```

```apex
// Net worth: Assets − Liabilities
Set<String> assetTypes = new Set<String>{
    'SavingsDeposit', 'CheckingDeposit', 'Investment', 'RetirementAccount'
};
Set<String> liabilityTypes = new Set<String>{
    'CreditCard', 'PersonalLoan', 'Mortgage'
};

for (FinancialAccount__c fa : [
    SELECT Balance__c, FinancialAccountType__c
    FROM FinancialAccount__c
    WHERE PrimaryOwner__c = :contactId AND Status__c = 'Active'
]) {
    if (assetTypes.contains(fa.FinancialAccountType__c))     assets      += fa.Balance__c;
    if (liabilityTypes.contains(fa.FinancialAccountType__c)) liabilities += fa.Balance__c;
}
Decimal netWorth = assets - liabilities;
```

---

## FSC — RecordAlert

Surfaces compliance reminders, KYC due dates, and advisory alerts on client records.

```apex
RecordAlert__c alert = new RecordAlert__c(
    WhatId               = contactId,
    Subject__c           = 'Annual Review Due',
    Severity__c          = 'Warning',          // 'Info', 'Warning', 'Error'
    EffectiveDateTime__c = DateTime.now(),
    ExpirationDateTime__c = DateTime.now().addDays(30),
    Status__c            = 'Active'
);
insert alert;

// Always set ExpirationDateTime — FSC compliance requirement
```

---

## FSC — ActionPlan

Standardised checklists for repeatable client processes (onboarding, annual reviews, loan processing):

```apex
// 1. Define template in Setup: Setup > Action Plans > Templates
// Template contains TaskTemplate records (one per task)

// 2. Instantiate from Apex
ActionPlan plan = new ActionPlan(
    ActionPlanTemplateId = templateId,
    TargetId             = contactId,    // or Account, Opportunity, etc.
    Name                 = 'Q4 Annual Review — Smith',
    StartDate            = Date.today()
);
insert plan;
// Tasks are auto-created from the template's TaskTemplate records
```

---

## Health Cloud — Care Program Enrolment

```apex
// 1. Confirm CareProgram exists
CareProgram program = [
    SELECT Id FROM CareProgram
    WHERE Name = 'Diabetes Management' AND Status = 'Active' LIMIT 1
];

// 2. Check idempotency (avoid duplicate enrolment)
List<CareProgramEnrollee> existing = [
    SELECT Id FROM CareProgramEnrollee
    WHERE AccountId = :patientId AND CareProgramId = :program.Id
    AND Status = 'Active' LIMIT 1
];
if (!existing.isEmpty()) return existing[0].Id; // already enrolled

// 3. Create enrolment
CareProgramEnrollee enrollee = new CareProgramEnrollee(
    AccountId     = patientId,
    CareProgramId = program.Id,
    Status        = 'Active',
    EnrollmentDate__c = Date.today()
);
insert enrollee;
```

---

## OmniScript Payload Flattening

OmniScript wraps each step's output in the step name:

```json
{
  "PersonalInfoStep": { "firstName": "Jane", "lastName": "Smith" },
  "AccountStep":      { "accountId": "001xxx", "accountType": "Checking" }
}
```

Flatten for easy access in Apex (e.g. when an IP receives an OmniScript payload):

```apex
Map<String, Object> flat = OmniStudioService.flattenOmniScriptPayload(payload);
String firstName = (String) flat.get('firstName');   // 'Jane'
String accountId = (String) flat.get('accountId');   // '001xxx'
```

---

## Graceful Degradation — Managed Package Pattern

```apex
// Pattern: Type.forName returns null when package not installed
// → never throw an exception, always return structured error

Type ipType = Type.forName('omnistudio', 'IntegrationProcedureService');
if (ipType == null) {
    return new Map<String, Object>{ 'error' => 'OmniStudio not installed' };
}

// Same pattern for FSC / Health Cloud objects
try {
    return Database.query('SELECT Id FROM FinancialAccount__c WHERE ...');
} catch (Exception e) {
    return new List<SObject>(); // package not installed
}
```

---

## Interview Tips

1. **IP key format** is `{Type}_{Name}` — e.g. `Account_GetFinancialSummary`. This is the string passed to `Callable.call()`. Type and Name are set in the IP's Setup properties.

2. **DataRaptor is NOT a callout** — it executes SOQL or DML inside Salesforce. No HTTP involved. Integration Procedure can make HTTP callouts (via HTTP Action element).

3. **Callable interface = no package dependency** — `Type.forName('omnistudio', 'IntegrationProcedureService')` compiles without the package. Always check for null before calling `.newInstance()`.

4. **Household model uses AccountContactRelation** — not the standard `Contact.AccountId` one-to-many. A Contact can belong to multiple Households via ACR, with different Roles on each.

5. **`FinancialAccount__c` is NOT a standard Salesforce object** — it's an FSC custom object. Do NOT confuse with a standard `Account`. It represents a financial product (savings, loan, etc.).

6. **RecordAlert expiration is mandatory in FSC** — always set `ExpirationDateTime__c`. Alerts without expiration can cause compliance issues and clutter the record timeline.

7. **`ActionPlanTemplate` must be Active** — query `Status = 'Active'` before instantiating. Templates in Draft status cannot generate tasks.

8. **Health Cloud enrolment is idempotent by design** — check for an existing active `CareProgramEnrollee` before inserting. Duplicate enrolment causes reporting errors in care management dashboards.

9. **FlexCard `Apex Remote` requires `@AuraEnabled(cacheable=true)`** — for read-only data. If the data changes frequently, use `cacheable=false` (but this increases server calls).

10. **OmniScript steps are JSON-keyed** — the output map from each step is wrapped under the step API name. Use `flattenOmniScriptPayload()` to merge step outputs before passing to downstream Apex.
