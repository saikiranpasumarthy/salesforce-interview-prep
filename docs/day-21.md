# Day 21 — Metadata API & Tooling API, SFDX Project Structure, Environment Strategy

## Topics Covered
1. Metadata API vs Tooling API — when to use each
2. Tooling API SOQL — ApexClass, ApexCodeCoverageAggregate, ApexTestResult
3. Metadata API REST — deploy status, deploy/retrieve
4. SFDX project structure — source format conventions
5. Environment strategy — sandbox types, org detection, Custom Metadata config
6. `EnvironmentService` — detecting org type at runtime

---

## 1. Metadata API vs Tooling API

| Aspect | Metadata API | Tooling API |
|--------|-------------|-------------|
| **Endpoint** | `/services/data/vXX.0/metadata/*` | `/services/data/vXX.0/tooling/*` |
| **Primary use** | Deploy/retrieve metadata containers | Developer tooling, code coverage, test results |
| **Format** | SOAP (WSDL) or REST | REST only |
| **SOQL** | No | Yes — `/tooling/query?q=SELECT...` |
| **Body/source** | Not exposed | `ApexClass.Body`, `ApexTrigger.Body` |
| **Coverage data** | No | `ApexCodeCoverageAggregate` |
| **Test results** | No | `ApexTestResult`, `ApexTestRunResult` |
| **Deploy ops** | `deploy()`, `retrieve()`, `checkDeployStatus()` | Not applicable |
| **Custom field metadata** | Yes | `CustomField` sObject |
| **Used by** | sf CLI, Workbench, ANT Migration Tool | VS Code, IDE extensions, CI coverage checks |

### Key Tooling API sObjects

| sObject | What it exposes |
|---------|----------------|
| `ApexClass` | Name, Body (source!), SymbolTable, IsValid, Status, ApiVersion |
| `ApexTrigger` | Name, Body, TableEnumOrId, Status |
| `ApexCodeCoverage` | Per test class → per covered class line counts |
| `ApexCodeCoverageAggregate` | Aggregated coverage across all test runs (preferred) |
| `ApexTestResult` | Individual test method outcomes (Pass/Fail/CompileFail/Skip) |
| `ApexTestRunResult` | Summary of a full test run |
| `FlowDefinition` | Flow metadata, process type, active version |
| `CustomField` | Field metadata including DataType, Description, EntityDefinition |
| `EntityDefinition` | Object metadata (label, keyPrefix, fields count) |

---

## 2. Tooling API — Querying from Apex

```apex
// Authenticate with session ID (requires Remote Site Settings or Named Credential)
HttpRequest req = new HttpRequest();
req.setEndpoint(URL.getOrgDomainUrl().toExternalForm()
    + '/services/data/v62.0/tooling/query'
    + '?q=SELECT+Id,Name,Body+FROM+ApexClass+WHERE+Name+=+\'MyClass\'');
req.setMethod('GET');
req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
req.setHeader('Content-Type', 'application/json');

HttpResponse res = new Http().send(req);
Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
List<Object> records = (List<Object>) result.get('records');
```

### Why use Tooling API over Schema.describe?
- `Schema.getDescribe()` only returns fields the **running user can see** (FLS-filtered)
- Tooling API `CustomField` returns **all fields regardless of FLS** — needed for migration tools
- Tooling API is the only way to read Apex **source code** (`Body` field)
- `ApexCodeCoverageAggregate` is **only available via Tooling API** — not standard SOQL

---

## 3. Metadata API — Deploy Status

```apex
// Check status of an async deploy (0Af... IDs from sf project deploy start)
GET /services/data/v62.0/metadata/deployRequest/<deployId>?includeDetails=true

// Response shape:
{
  "deployResult": {
    "done": true,
    "success": true,
    "status": "Succeeded",   // Pending | InProgress | Succeeded | Failed | Canceled
    "numberComponentsDeployed": 5,
    "numberComponentTotal": 5,
    "numberTestsCompleted": 20,
    "numberTestErrors": 0,
    "details": {
      "componentFailures": []
    }
  }
}
```

### Deploy Status Values
| Status | Meaning |
|--------|---------|
| `Pending` | Queued — waiting for platform capacity |
| `InProgress` | Running — deploying components |
| `Succeeded` | All components deployed, all tests passed |
| `Failed` | One or more component errors or test failures |
| `Canceled` | Deployment was cancelled via API or UI |
| `Canceling` | Cancel in progress |

---

## 4. SFDX Project Structure

```
salesforce-interview-prep/
├── sfdx-project.json           ← Package config, API version, source paths
├── .forceignore                ← Files excluded from deploy/retrieve (like .gitignore)
├── config/
│   ├── project-scratch-def.json     ← Standard scratch org definition
│   └── scratch-def-full.json        ← Full-feature scratch definition
├── manifest/
│   └── package.xml                  ← Full deployment manifest
├── force-app/
│   └── main/
│       └── default/
│           ├── classes/             ← ApexClass: .cls + .cls-meta.xml pairs
│           ├── triggers/            ← ApexTrigger: .trigger + -meta.xml pairs
│           ├── objects/             ← CustomObject: folder per object
│           │   └── Account/
│           │       └── fields/      ← One file per custom field
│           ├── lwc/                 ← LWC: folder per component
│           ├── flows/               ← Flow: one .flow-meta.xml per flow
│           ├── permissionsets/      ← PermissionSet: .permissionset-meta.xml
│           └── customMetadata/      ← Custom Metadata records: .md-meta.xml
├── .azure-pipelines/            ← CI/CD pipeline YAML
├── scripts/                     ← Shell scripts and Anonymous Apex
└── docs/                        ← Study notes per day
```

### Source Format Key Conventions
- Each metadata component has **two files**: the component file + `-meta.xml` sidecar
- Custom Objects are **exploded** — one folder per object, one file per field/validation/etc.
- Custom Metadata **type** = `objects/MyType__mdt/`; **records** = `customMetadata/MyType.RecordName.md-meta.xml`
- Flows live in `flows/` as a single `.flow-meta.xml` file
- Named Credentials: `namedCredentials/` folder

### `.forceignore`
```
# Ignore Jest test output
**/.jest-cache
**/node_modules
**/__tests__/coverage

# Ignore scratch org state files
.sfdx/
.sf/

# Ignore local override files
*.local.json
```

---

## 5. Environment Strategy

### Sandbox Types

| Type | Storage | Refresh | Data Copy | Best for |
|------|---------|---------|-----------|---------|
| Developer | ~200MB | On-demand | None | Feature dev, unit testing |
| Developer Pro | ~1GB | On-demand | None | Performance testing |
| Partial Copy | 5GB | 5 days | Sampling rules | QA, integration testing |
| Full Copy | Same as prod | 29 days | Full (anonymized) | UAT, staging, load testing |

### Recommended Org Strategy (Enterprise)

```
Dev Scratch Orgs  →  Integration Dev Sandbox  →  QA/UAT (Partial)
                                                         ↓
Hotfix branch   →  Staging (Full Copy Sandbox)  →  Production
```

- **Scratch orgs**: feature development, one per developer/feature branch
- **Integration sandbox**: continuous integration, always matches main branch
- **QA sandbox**: UAT testing, refreshed per sprint
- **Staging (Full Copy)**: production rehearsal, load testing, final sign-off
- **Production**: single source of truth

### Detecting Org Type in Apex

```apex
Organization org = [
    SELECT IsSandbox, OrganizationType, TrialExpirationDate
    FROM Organization LIMIT 1
];

Boolean isScratch    = !org.IsSandbox && org.TrialExpirationDate != null;
Boolean isSandbox    = org.IsSandbox;
Boolean isProduction = !org.IsSandbox && org.TrialExpirationDate == null;
```

---

## 6. Custom Metadata — Environment-Aware Config

Use Custom Metadata Types (not Custom Settings) for environment-specific configuration:

```
Environment_Config__mdt
├── Environment_Type__c   — 'SCRATCH' | 'DEVELOPER_SANDBOX' | 'FULL_SANDBOX' | 'PRODUCTION'
├── Api_Endpoint__c       — https://api.sandbox.example.com/v1
├── Config_Key__c         — e.g. 'MAX_BATCH_SIZE'
├── Config_Value__c       — e.g. '200'
└── Is_Active__c          — true/false toggle
```

**Why Custom Metadata over Custom Settings?**
- Deployable via `package.xml` — can ship config with code
- Available in Formula Fields, Validation Rules, Flows
- Supports dependency injection at deploy time
- Cannot be edited by end users (vs Custom Settings which can)

**Usage pattern:**
```apex
// Different endpoint per environment — no if/else in code
EnvironmentService.getExternalApiEndpoint()
// → reads Environment_Config__mdt WHERE Environment_Type__c = 'PRODUCTION'
//   and returns Api_Endpoint__c value
```

---

## Interview Q&A

**Q: What is the difference between the Metadata API and the Tooling API?**
A: The Metadata API is for deploying and retrieving metadata containers (CustomObject, ApexClass, Flow) — it's what `sf project deploy start` uses under the hood. The Tooling API is a developer-focused REST API that exposes richer sObjects like `ApexClass` (with source Body), `ApexCodeCoverageAggregate`, `ApexTestResult`, and `CustomField`. Use Metadata API for deployment automation; use Tooling API for IDE integrations, code coverage reporting, and metadata introspection tools.

**Q: Why can't you read Apex class source via standard SOQL?**
A: The standard `ApexClass` sObject exposes Name, Status, ApiVersion, and IsValid, but not `Body`. The Body field (source code) is only exposed via the Tooling API. This is by design — source code access is restricted to developer tools, not business logic. The Tooling API requires `API Enabled` permission and a valid session token.

**Q: What is `ApexCodeCoverageAggregate` and why is it preferred over `ApexCodeCoverage`?**
A: `ApexCodeCoverage` records individual test class → covered class relationships — one row per test class per covered class. `ApexCodeCoverageAggregate` aggregates coverage across ALL test runs for a given class/trigger, giving you the overall coverage percentage. For reporting and threshold enforcement, use `ApexCodeCoverageAggregate` — it's a single row per class and avoids double-counting.

**Q: How do you detect whether Apex is running in a sandbox vs production?**
A: Query the `Organization` sObject: `SELECT IsSandbox, OrganizationType, TrialExpirationDate FROM Organization LIMIT 1`. `IsSandbox = true` means sandbox. Scratch orgs have `IsSandbox = false` but `TrialExpirationDate != null`. Production has `IsSandbox = false` and no trial date. For distinguishing Full vs Developer sandbox, use `OrganizationType` (Enterprise/Unlimited Edition = Full Copy; Developer Edition = Developer sandbox).

**Q: What is the difference between Custom Metadata and Custom Settings for environment config?**
A: Custom Metadata records are deployable via `package.xml` and can be included in packages — they ship with code. Custom Settings are org data — not deployable, must be set up manually per org. Custom Metadata is also available in Formula Fields, Validation Rules, and Flows without Apex. The trade-off: Custom Metadata records require a deployment to change; Custom Settings can be edited in Setup. Use Custom Metadata for environment configuration that changes with deployments; use Custom Settings for end-user-editable preferences.

**Q: What is a Full Copy sandbox and when would you use it?**
A: A Full Copy sandbox is a complete clone of production — same data volume, same configuration, same users (with anonymized credentials). It has a 29-day minimum refresh interval and is the most expensive sandbox type. Use it for: UAT/final sign-off before production releases, load and performance testing with realistic data volumes, and disaster recovery rehearsals. Because of the refresh window, a Full Copy sandbox is typically the staging environment closest to production in an enterprise release pipeline.

**Q: How does `sfdx-project.json` relate to package management?**
A: `sfdx-project.json` is the project manifest. For source-only projects, it defines `packageDirectories` with paths and API versions. For unlocked packages, it adds `package`, `versionNumber`, `versionName`, `definitionFile`, and `ancestorId` to each directory, plus a `packageAliases` map translating human-readable names to `0Ho` IDs. The `sf package version create` command reads this file to know which package to associate the version with. Multiple `packageDirectories` entries support multi-package repositories where different directories correspond to different packages.
