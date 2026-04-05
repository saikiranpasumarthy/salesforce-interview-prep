# Day 15 — Admin Fundamentals: Object Model, Validation Rules, Reports & Audit Trail

## Overview

Day 15 bridges admin configuration and developer implementation. Every senior developer interview includes questions about these fundamentals — interviewers test whether you understand the *why*, not just the *how*.

---

## Object Model

### Standard vs Custom Objects

| | Standard | Custom |
|---|---|---|
| API naming | `Account`, `Contact` | `Project__c`, `Project_Task__c` |
| Key prefix | Fixed (001, 003, 006…) | Assigned at creation |
| Cannot be deleted | ✓ | ✗ |
| Limit | None | 400 custom objects (AE/EE) |
| Sharing model | Fixed per object | Configurable: Private → ControlledByParent |

### Relationship Types

#### Lookup

```
Account  ←────────  Contact
           (AccountId — optional)
```

- Loose coupling: Contact survives if Account deleted (unless "Don't allow deletion" set)
- Child has its own OWD / sharing model
- No roll-up summary fields
- Lookup field is optional by default
- Max 25 lookup fields per object

#### Master-Detail

```
Project__c  ◄════════  Project_Task__c
              (Project__c — required, immutable)
```

- Tight coupling: deleting Project cascades to all Project Tasks
- Child inherits parent's OWD (`sharingModel=ControlledByParent`)
- Roll-up summary fields allowed on parent (COUNT, SUM, MIN, MAX)
- Master-detail field is required and (by default) cannot be reparented
- First master-detail = primary; if two master-details on same object → junction object

#### Many-to-Many (Junction Object)

```
Campaign  ◄══════  CampaignMember  ══════►  Contact
```

Junction object has two Master-Detail fields. Both parents can define roll-ups into the junction.

#### External Lookup / Indirect Lookup

- **External Lookup**: child field references an External Object (cross-system join)
- **Indirect Lookup**: references a custom unique external ID field on a standard/custom object

### Key Prefix & Record ID Structure

```
001 — Account
003 — Contact
006 — Opportunity
00Q — Lead
a0B — Custom object (assigned at creation)
```

Full 18-char Id: `a0B` + `5000` (sequence) + `AAA` (checksum)

---

## Field Types & When to Use Them

| Type | Use case | Notes |
|---|---|---|
| Text | Short string ≤ 255 chars | Case-insensitive in SOQL `=` comparison |
| Long Text Area | Description, notes | Not indexable; no `=` filter in SOQL |
| Rich Text Area | HTML content | Stored as HTML; no direct SOQL filter |
| Number | Integer / decimal | Specify precision + scale |
| Currency | Monetary amounts | Respects org currency settings |
| Percent | Ratio | Stored as 0-100; displayed with `%` |
| Checkbox | Boolean flag | `= true/false` in SOQL; default value required |
| Date / DateTime | Calendar values | `TODAY()`, `NOW()`, date literals in SOQL |
| Picklist | Fixed set of values | Use `ISPICKVAL()` in formulas — **never** `=` |
| Multi-Select Picklist | Multiple choices | `INCLUDES()` in formulas; `;` separator |
| Lookup / MD | Relationship | Stores 18-char Id |
| Formula | Computed read-only | Cannot be written to directly |
| Roll-Up Summary | Aggregate from children | Only on MD parent; COUNT/SUM/MIN/MAX |
| External ID | Integration key | Indexable; use in `upsert` |
| Auto Number | Sequential read-only | Format: `{YY}-{0000}` |

---

## Validation Rules

### Anatomy

```
Error Condition Formula → Boolean
    true  = block save + show error
    false = allow save
```

Configured in: **Object Manager → [Object] → Validation Rules**

### Common Formula Functions

| Function | Purpose |
|---|---|
| `ISBLANK(field)` | True if null or empty string |
| `ISNULL(field)` | True if null (use `ISBLANK` for text fields) |
| `ISNEW()` | True only on record **insert** |
| `ISCHANGED(field)` | True when a field value changes on **update** |
| `PRIORVALUE(field)` | Previous value of a field (update context only) |
| `ISPICKVAL(field, 'val')` | Picklist equality — do NOT use `=` |
| `TODAY()` | Current date (Date type) |
| `NOW()` | Current datetime |
| `AND(a, b)` / `OR(a, b)` | Logical operators |
| `NOT(expr)` | Logical negation |
| `LEN(text)` | String length |
| `REGEX(text, pattern)` | Regex match |
| `$Profile.Name` | Running user's profile name |
| `$UserRole.Name` | Running user's role name |

### ISNEW vs ISCHANGED

```
ISNEW()          — true only on INSERT (create)
ISCHANGED(field) — true when the field changes on UPDATE
PRIORVALUE(field)— old value of field on UPDATE
```

**Pattern: allow backdating on edits, block on creates**

```
AND(ISNEW(), NOT(ISBLANK(Due_Date__c)), Due_Date__c < TODAY())
```

**Pattern: require field only when picklist changes to a specific value**

```
AND(ISCHANGED(Status__c), ISPICKVAL(Status__c, 'Active'), ISBLANK(Owner_Confirmed__c))
```

### Error Display Options

- `errorDisplayField = <Field API Name>` → inline red border on the field
- Omit `errorDisplayField` → error appears at the top of the page

### Cross-Object Validation (Lookup fields)

```
AND(
    ISPICKVAL(Account__r.Type, 'Prospect'),
    NOT(ISBLANK(Contract_Value__c))
)
```

Traverse lookup with `__r` notation. Up to 10 levels deep in formulas.

### Bypass Strategies (for data migration / integrations)

1. **Custom bypass field**: `Bypass_Validation__c` (checkbox) + `AND(..., NOT(Bypass_Validation__c))`
2. **Profile/Permission Set check**: `$Profile.Name != 'Data Migration Profile'`
3. **Custom Metadata toggle**: reference a CMDT row to enable/disable

---

## Schema.describe (Apex Object Model Inspection)

```apex
// Object describe
Schema.DescribeSObjectResult d =
    Schema.getGlobalDescribe().get('Account').getDescribe(SObjectDescribeOptions.DEFERRED);

d.getLabel()          // 'Account'
d.getName()           // 'Account'
d.getKeyPrefix()      // '001'
d.isCustom()          // false
d.getSharingModel()   // SharingModel.ReadWrite
d.fields.getMap()     // Map<String, SObjectField>

// Field describe
Schema.DescribeFieldResult dfr =
    Schema.Account.Type.getDescribe();

dfr.getType()           // DisplayType.PICKLIST
dfr.isAccessible()      // FLS read access
dfr.isUpdateable()      // FLS edit access
dfr.isNillable()        // opposite of required
dfr.getPicklistValues() // List<Schema.PicklistEntry>
dfr.getReferenceTo()    // List<Schema.SObjectType> for REFERENCE type

// Child relationships
for (Schema.ChildRelationship cr : d.getChildRelationships()) {
    cr.getRelationshipName()   // 'Contacts', 'Project_Tasks__r'
    cr.getChildSObject()       // Schema.SObjectType
    cr.isCascadeDelete()       // true = Master-Detail
}
```

**Performance: use `SObjectDescribeOptions.DEFERRED`** to avoid loading child relationships unless needed.

**Cache `Schema.getGlobalDescribe()`** in a static variable — it's expensive on first call.

---

## Reports & Dashboards

### Report Types

| Type | Structure | Fact Map Key |
|---|---|---|
| Tabular | Flat list of rows | `T!T` |
| Summary | Grouped by one field | `<groupKey>!T` |
| Matrix | Grouped by rows AND columns | `<rowKey>!<colKey>` |
| Joined | Multiple report blocks | Separate fact maps per block |

### Analytics API (Reports namespace)

```apex
// Synchronous — summary only (faster, less heap)
Reports.ReportResults results =
    Reports.ReportManager.runReport(reportId, false);

// Synchronous — with row detail (higher heap use; max ~2000 rows)
Reports.ReportResults results =
    Reports.ReportManager.runReport(reportId, true);

// Read grand total (summary or matrix)
Reports.ReportFactWithSummaries grandTotal =
    (Reports.ReportFactWithSummaries) results.getFactMap().get('T!T');
List<Reports.SummaryValue> aggregates = grandTotal.getAggregates();

// Read row detail (tabular)
Reports.ReportFactWithDetails fact =
    (Reports.ReportFactWithDetails) results.getFactMap().get('T!T');
for (Reports.ReportDetailRow row : fact.getRows()) {
    List<Reports.ReportDataCell> cells = row.getDataCells();
    Object value = cells[0].getValue();  // String, Decimal, Date, etc.
}

// Column order
List<String> columns = results.getReportMetadata().getDetailColumns();

// Runtime filter override
Reports.ReportMetadata metadata = results.getReportMetadata();
Reports.ReportFilter rf = new Reports.ReportFilter();
rf.setColumn('ACCOUNT_TYPE');
rf.setOperator('equals');
rf.setValue('Customer - Direct');
metadata.getReportFilters().add(rf);
Reports.ReportResults filtered =
    Reports.ReportManager.runReport(reportId, metadata, false);

// Async run (no row limit; no DML restriction)
Reports.ReportInstance instance =
    Reports.ReportManager.runAsyncReport(reportId, false);
String instanceId = instance.getId();

// Poll async status
Reports.ReportInstance polled =
    Reports.ReportManager.getReportInstance(reportId, instanceId);
polled.getStatus()          // 'New' | 'Running' | 'Success' | 'Error'
polled.getCompletionDate()
polled.getReportResults()   // populated when status='Success'
```

### Governor Limits

- `runReport` counts toward CPU time and heap
- No DML can occur in the same transaction as `runReport`
- Async reports bypass heap limits but require polling

### Dashboard Refresh

Dashboards show data from the last **scheduled refresh** or manual refresh — they do not query live data on view. Use the **Dashboard Refresh API** or schedule nightly refreshes for critical dashboards.

---

## Audit Trail

### 1. Setup Audit Trail (`SetupAuditTrail`)

- Tracks all **admin setup changes**: field creation, profile edits, workflow activation, etc.
- Retains last **6 months**
- Queryable via SOQL (read-only)

```apex
List<SetupAuditTrail> trail = [
    SELECT Action, Section, Display, CreatedDate, CreatedBy.Name
    FROM   SetupAuditTrail
    ORDER  BY CreatedDate DESC
    LIMIT  20
];
```

Common `Section` values: `'CustomField'`, `'ValidationRule'`, `'ApexClass'`, `'UserManagement'`, `'ProfilesAndPermsets'`, `'SecurityAndSharing'`

### 2. Field History Tracking

- Enable per field in **Object Manager → [Object] → Fields → Edit → Track History**
- Up to **20 fields** per object (standard + custom)
- Retain **18 months** standard; longer with Field Audit Trail add-on
- History object naming:
  - Standard: `AccountHistory`, `ContactHistory`, `OpportunityHistory`
  - Custom: `Project__History`, `Project_Task__History` (`__c` → `__History`)

```apex
List<AccountHistory> history = [
    SELECT Field, OldValue, NewValue, CreatedDate, CreatedBy.Name
    FROM   AccountHistory
    WHERE  AccountId = :accountId
    AND    Field     != 'created'   -- exclude synthetic insert entry
    ORDER  BY CreatedDate DESC
];
```

`OldValue` / `NewValue` are polymorphic (`Object`). Cast or stringify as needed.

### 3. Event Monitoring (`EventLogFile`)

- Requires **Event Monitoring add-on** (not included in standard licences)
- Captures every API call, login, report run, page view, Apex execution
- Log files are CSV; stored in `EventLogFile.LogFile` (Blob)
- Default retention: **1 day**; 30 days with add-on

```apex
List<EventLogFile> logs = [
    SELECT EventType, LogDate, LogFileLength, LogFileName
    FROM   EventLogFile
    WHERE  EventType = 'ApexExecution'
    AND    LogDate   = :Date.today()
];
// Download log body separately via REST API or Blob.toString()
```

Common `EventType` values: `'Login'`, `'API'`, `'ApexExecution'`, `'ReportExport'`, `'LightningPageView'`, `'BulkApi'`

### 4. Shield Platform Encryption

- Encrypts field data **at rest** (standard encryption only protects backup media)
- Tenant secret managed by customer; Salesforce cannot decrypt without it
- Not the same as field masking or FLS — encrypted fields can still be read by users with FLS access
- Performance impact: encrypted fields cannot be used in certain SOQL filters

---

## Interview Q&A

**Q: What is the difference between a Lookup and a Master-Detail relationship?**
> Master-Detail creates a tight parent-child bond: the child's sharing model is `ControlledByParent`, deleting the parent cascades to children, and roll-up summary fields are available on the parent. Lookup is loose: the child has its own sharing model, the parent can be deleted independently (unless "Restrict Delete" is set), and no roll-up summaries. The master-detail field is required and cannot be changed after insert by default.

**Q: Can you have two Master-Detail fields on the same object?**
> Yes — that creates a junction object for a many-to-many relationship. Both parent objects cascade-delete into the junction. The junction object's sharing model is `ControlledByParent` relative to its primary (first) master. You cannot have more than two master-detail fields per object.

**Q: Why use `ISPICKVAL` instead of `=` for picklist fields in validation formulas?**
> Picklist fields are not text fields — comparing with `=` can give unreliable results because inactive values or multi-currency picklists behave differently. `ISPICKVAL(field, 'value')` is the correct, platform-safe comparison operator for picklist fields.

**Q: What does `ISNEW()` do in a validation rule and when would you use it?**
> `ISNEW()` returns true only during record insert. It's used when a rule should only fire at creation time — for example, preventing a past due date on new tasks, without locking existing records that already have past dates. Without `ISNEW()`, users couldn't edit any other field on an old record without also fixing the date.

**Q: What are the governor limits for the Analytics API `runReport`?**
> Synchronous `runReport` returns a maximum of approximately 2,000 rows and counts against the transaction's CPU time and heap. You cannot perform DML in the same transaction. For large reports, use `runAsyncReport`, which runs in a background thread without row limits. Poll the returned `ReportInstance` for status.

**Q: How does `SObjectDescribeOptions.DEFERRED` improve performance?**
> By default, `getDescribe()` eagerly loads all child relationship metadata, which can be expensive. `DEFERRED` defers loading child relationships until they are explicitly accessed (`getChildRelationships()`). For CRUD/FLS checks in bulk-processing code where child relationships are irrelevant, `DEFERRED` avoids unnecessary heap and CPU usage.

**Q: What is the difference between Setup Audit Trail and Field History Tracking?**
> Setup Audit Trail (`SetupAuditTrail`) records **administrative setup changes** (field creation, profile edits, workflow activation). Field History Tracking records **data changes to specific record fields** by end users (`AccountHistory`, `Project__History`). They are completely separate mechanisms with different retention periods and query objects.

**Q: How do you query field history for a custom object in Apex?**
> The history object for a custom object follows the pattern `<ObjectApiName without __c>__History`. So `Project__c` → `Project__History`, `Project_Task__c` → `Project_Task__History`. The parent Id field is `ParentId` (not the custom object's field name). Enable field tracking per field in Object Manager.

---

## Files Created

| File | Purpose |
|---|---|
| `objects/Project_Task__c/Project_Task__c.object-meta.xml` | Custom object, Master-Detail to Project__c, sharingModel=ControlledByParent |
| `objects/Project_Task__c/fields/Project__c.field-meta.xml` | Master-Detail relationship field |
| `objects/Project_Task__c/fields/Priority__c.field-meta.xml` | Picklist: High/Medium/Low |
| `objects/Project_Task__c/fields/Due_Date__c.field-meta.xml` | Date field (history-tracked) |
| `objects/Project_Task__c/fields/Effort_Days__c.field-meta.xml` | Number 3,0 |
| `objects/Project_Task__c/fields/Is_Blocked__c.field-meta.xml` | Checkbox (history-tracked) |
| `objects/Project_Task__c/fields/Completion_Pct__c.field-meta.xml` | Percent 3,0 |
| `objects/Project_Task__c/validationRules/High_Priority_Requires_Due_Date.validationRule-meta.xml` | ISPICKVAL + ISBLANK pattern |
| `objects/Project_Task__c/validationRules/Effort_Days_Valid_Range.validationRule-meta.xml` | Range validation (1–365) |
| `objects/Project_Task__c/validationRules/Due_Date_Cannot_Be_Past.validationRule-meta.xml` | ISNEW() insert-only guard |
| `classes/MetadataInspector.cls` | Schema.describe: object/field/relationship/picklist inspection |
| `classes/ReportService.cls` | Analytics API: sync + async report runs, filter override |
| `classes/AuditService.cls` | SetupAuditTrail, AccountHistory, generic __History, EventLogFile |
| `classes/AdminFundamentalsTest.cls` | 22 tests: validation rules, Schema.describe, AuditService |
