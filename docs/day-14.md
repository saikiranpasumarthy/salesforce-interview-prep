# Day 14 — Security Model: CRUD/FLS, Sharing Keywords & Manual Sharing

## Overview

Salesforce security is layered. Each layer is independent — passing one does NOT guarantee access at another.

```
┌─────────────────────────────────────────────────────┐
│  Layer 1: Object-Level (CRUD)                        │
│    Can the user see / create / edit / delete the     │
│    object at all?                                    │
├─────────────────────────────────────────────────────┤
│  Layer 2: Field-Level Security (FLS)                 │
│    Can the user read / edit specific fields?         │
├─────────────────────────────────────────────────────┤
│  Layer 3: Record-Level (Sharing / OWD)               │
│    Can the user see this particular record?          │
│    OWD → Role Hierarchy → Sharing Rules → Manual     │
└─────────────────────────────────────────────────────┘
```

Apex runs in **system context by default** — all three layers are bypassed unless you explicitly enforce them.

---

## Org-Wide Defaults (OWD)

OWD is the **baseline** record-level access for each object. Every record is compared against OWD first.

| Setting | Meaning |
|---|---|
| `Private` | Only the record owner (and users above in role hierarchy) can see it |
| `Public Read Only` | All users can read; only owner + hierarchy can edit |
| `Public Read/Write` | All users can read and edit |
| `Controlled By Parent` | Access follows the parent record's OWD (used on detail objects) |

Configure on **Setup → Sharing Settings**. Changing OWD triggers a sharing recalculation.

**Custom object OWD in metadata:**
```xml
<sharingModel>Private</sharingModel>   <!-- inside .object-meta.xml -->
```

---

## Sharing Keywords

### `with sharing`

```apex
public with sharing class AccountService {
    public List<Account> getAccounts(Set<Id> ids) {
        // SOQL returns ONLY records the running user can see
        return [SELECT Id, Name FROM Account WHERE Id IN :ids];
    }
}
```

- Enforces: OWD + sharing rules + manual shares + role hierarchy
- Does **NOT** enforce CRUD or FLS — those require manual checks
- Best practice: use for **all user-facing code** (controllers, service classes, selectors)

### `without sharing`

```apex
public without sharing class AuditLogService {
    public void write(Id recordId, String action) {
        // Returns ALL records regardless of user's access
        // Typical uses: batch jobs, system integrations, audit writes
    }
}
```

- Bypasses record-level sharing entirely
- If called from a `with sharing` class, the `without sharing` context **still bypasses sharing** — sharing is NOT inherited from the caller

### `inherited sharing`

```apex
public inherited sharing class QueryHelper {
    public List<Account> query(Set<Id> ids) {
        // Adapts to the caller's sharing context:
        // Called from 'with sharing' → enforces sharing
        // Called from 'without sharing' → bypasses sharing
    }
}
```

- Recommended for **utility and helper classes** that must work in both contexts
- Safer than `without sharing` because it won't silently bypass sharing when called from a restricted context

### No keyword (legacy)

- Behaves like `without sharing` in most contexts
- **Avoid** — unpredictable behaviour; always use an explicit keyword

### Inheritance Chain

```
Controller (with sharing)
  └─► Service (with sharing)    → enforces sharing ✅
      └─► Selector (with sharing) → enforces sharing ✅

Controller (with sharing)
  └─► AdminUtil (without sharing) → BYPASSES sharing ⚠️
      └─► Helper (inherited sharing) → BYPASSES (inherits without sharing)
```

---

## CRUD Checks

```apex
// Object-level
Schema.SObjectType acc = Schema.Account.SObjectType;

acc.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()   // can query
acc.getDescribe(SObjectDescribeOptions.DEFERRED).isCreateable()   // can insert
acc.getDescribe(SObjectDescribeOptions.DEFERRED).isUpdateable()   // can update
acc.getDescribe(SObjectDescribeOptions.DEFERRED).isDeletable()    // can delete
```

Throwing a meaningful exception on failure:
```apex
public class CrudException extends Exception {}

public static void assertReadAccess(Schema.SObjectType objType) {
    if (!objType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
        throw new CrudException(
            'Insufficient read access on ' + objType.getDescribe().getLabel()
        );
    }
}
```

---

## FLS (Field-Level Security) Checks

```apex
Schema.DescribeFieldResult dfr =
    Schema.Account.AnnualRevenue.getDescribe();

dfr.isAccessible()   // user can read this field
dfr.isUpdateable()   // user can edit this field
dfr.isCreateable()   // user can set this field on insert
```

Filtering a field list to readable fields:
```apex
public static List<String> getReadableFields(
        Schema.SObjectType objType, List<String> fieldNames) {
    Map<String, Schema.SObjectField> fieldMap =
        objType.getDescribe().fields.getMap();
    List<String> readable = new List<String>();
    for (String f : fieldNames) {
        Schema.SObjectField fld = fieldMap.get(f.toLowerCase());
        if (fld != null && fld.getDescribe().isAccessible()) {
            readable.add(f);
        }
    }
    return readable;
}
```

---

## SOQL FLS Enforcement Options

### Option 1: `WITH SECURITY_ENFORCED` (all-or-nothing)

```apex
List<Account> accounts = [
    SELECT Id, Name, AnnualRevenue
    FROM   Account
    WHERE  Id IN :ids
    WITH   SECURITY_ENFORCED   // throws QueryException if ANY field is inaccessible
];
```

- **Pros**: zero boilerplate
- **Cons**: all-or-nothing — if one field is inaccessible the entire query fails; no partial result
- Best for: queries where you need all fields or nothing

### Option 2: `Security.stripInaccessible` (graceful degradation)

```apex
List<Account> raw = [SELECT Id, Name, AnnualRevenue FROM Account WHERE Id IN :ids];
SObjectAccessDecision decision = Security.stripInaccessible(AccessType.READABLE, raw);

List<Account> safe    = (List<Account>) decision.getRecords();      // fields stripped
Map<String, Set<String>> removed = decision.getRemovedFields();      // what was stripped
```

- **Pros**: returns partial data; caller can log removed fields
- **Cons**: slightly more code
- `AccessType` values: `READABLE`, `CREATABLE`, `UPDATABLE`, `UPSERTABLE`
- Best for: UI components where degraded display is better than an error page

### Comparison

| | `WITH SECURITY_ENFORCED` | `Security.stripInaccessible` |
|---|---|---|
| Behaviour on inaccessible field | Throws `QueryException` | Strips field silently |
| Partial results | No | Yes |
| DML (insert/update) | N/A | Yes (CREATABLE/UPDATABLE) |
| Boilerplate | Minimal | Moderate |

---

## AccountShare — Manual Sharing

`AccountShare` is the **sharing object** for `Account`. Every manual share row grants one principal access to one record.

### Fields

| Field | Purpose |
|---|---|
| `AccountId` | The account being shared |
| `UserOrGroupId` | The user or public group receiving access |
| `AccountAccessLevel` | `Read` or `Edit` |
| `OpportunityAccessLevel` | `None`, `Read`, or `Edit` (required) |
| `CaseAccessLevel` | `None`, `Read`, or `Edit` (required) |
| `RowCause` | Why the share exists (see below) |

### RowCause Values

| Value | Meaning |
|---|---|
| `Manual` | Created explicitly via Apex or sharing button; **can be deleted** |
| `Rule` | Created by a sharing rule; system-managed; **cannot be deleted via Apex** |
| `Owner` | Implicit owner row; always present; **cannot be deleted** |
| `ImplicitParent` | Inherited from parent via `Controlled By Parent` |

### Grant Access

```apex
AccountShare share = new AccountShare(
    AccountId            = accountId,
    UserOrGroupId        = principalId,
    AccountAccessLevel   = 'Read',       // 'Read' or 'Edit'
    OpportunityAccessLevel = 'None',     // required
    CaseAccessLevel      = 'None',       // required
    RowCause             = Schema.AccountShare.RowCause.Manual
);
insert share;
```

### Revoke Access (Manual only)

```apex
List<AccountShare> toDelete = [
    SELECT Id FROM AccountShare
    WHERE  AccountId     = :accountId
    AND    UserOrGroupId = :principalId
    AND    RowCause      = :Schema.AccountShare.RowCause.Manual
];
delete toDelete;
```

### Deduplicate before inserting

```apex
Integer existing = [
    SELECT COUNT() FROM AccountShare
    WHERE AccountId = :accountId
    AND   UserOrGroupId = :principalId
    AND   RowCause = :Schema.AccountShare.RowCause.Manual
];
if (existing == 0) { insert share; }
```

---

## Custom Object Sharing — `Project__Share`

For custom objects with `sharingModel=Private`, Salesforce auto-generates a `<ObjectName>__Share` object.

```apex
Project__Share ps = new Project__Share(
    ParentId           = projectId,      // note: ParentId, not ProjectId
    UserOrGroupId      = principalId,
    AccessLevel        = 'Read',         // 'Read' or 'Edit'
    RowCause           = Schema.Project__Share.RowCause.Manual
);
insert ps;
```

Set `sharingModel` in the object metadata:
```xml
<sharingModel>Private</sharingModel>
```

---

## Inner Class Pattern for Privilege Escalation

```apex
public with sharing class AccountService {

    // Runs 'with sharing' — user sees only their data
    public static List<Account> getUserAccounts(Set<Id> ids) {
        return [SELECT Id, Name FROM Account WHERE Id IN :ids];
    }

    // Deliberate, narrow escalation to system context
    public static List<Account> getAdminAccounts(Set<Id> ids) {
        return new AdminEscalation().getAllAccounts(ids);
    }

    // Inner class overrides sharing for specific operations only
    private without sharing class AdminEscalation {
        public List<Account> getAllAccounts(Set<Id> ids) {
            return [SELECT Id, Name, OwnerId FROM Account WHERE Id IN :ids];
        }
    }
}
```

**Why inner class?** The outer class keeps `with sharing` for all other operations. Only the specific method that needs elevation delegates to the inner class. This limits the blast radius of the escalation.

---

## `System.runAs` in Tests

```apex
@IsTest
static void withSharing_standardUser_seesOwnRecords() {
    User user2 = createStandardUser('ws01');
    insert user2;

    Set<Id> ids = new Map<Id, Account>(
        [SELECT Id FROM Account WHERE Name LIKE 'Test%']
    ).keySet();

    List<Account> results;
    System.runAs(user2) {
        results = SharingContextDemo.getMyAccounts(ids);
    }
    // In Private OWD: user2 sees 0 records (owns none)
    // In Public OWD:  user2 sees all records (OWD overrides sharing)
    System.assertNotEquals(null, results); // OWD-agnostic assertion
}
```

> **Note**: `System.runAs` does NOT change CRUD/FLS in tests — the test runner always has full object/field access. It only affects record-level sharing.

---

## Interview Q&A

**Q: What is the difference between `with sharing` and `WITH SECURITY_ENFORCED`?**
> `with sharing` enforces **record-level** access (which rows SOQL returns). `WITH SECURITY_ENFORCED` enforces **field-level** security (which columns are readable). They are completely independent. A class can have `with sharing` and query fields the user cannot read — you need both.

**Q: Does `with sharing` enforce CRUD or FLS?**
> No. `with sharing` only enforces record-level sharing (OWD + sharing rules). CRUD checks require `SObjectType.isAccessible()` etc. FLS checks require `DescribeFieldResult.isAccessible()` or `WITH SECURITY_ENFORCED` / `Security.stripInaccessible`.

**Q: What happens when a `with sharing` class calls a `without sharing` class?**
> The called class runs in system context, bypassing sharing regardless of the caller. Sharing is NOT inherited from the caller when `without sharing` is explicit.

**Q: When would you use `inherited sharing` over `with sharing`?**
> For utility/helper classes (formatters, calculators, query selectors) that are designed to be called from multiple contexts. Using `inherited sharing` lets the same class enforce sharing when called from a restricted controller and bypass it when called from a background batch job — without duplicating the class.

**Q: Can you delete a share with `RowCause = Rule`?**
> No. Sharing rule rows (`RowCause = Rule`) are managed by the platform and cannot be deleted via Apex. Only `RowCause = Manual` shares can be explicitly deleted.

**Q: What fields are required when inserting an `AccountShare`?**
> `AccountId`, `UserOrGroupId`, `AccountAccessLevel`, `OpportunityAccessLevel`, `CaseAccessLevel`, and `RowCause`. Omitting `OpportunityAccessLevel` or `CaseAccessLevel` causes a `DMLException`.

**Q: What is `Security.stripInaccessible` and when would you prefer it over `WITH SECURITY_ENFORCED`?**
> `Security.stripInaccessible` removes inaccessible fields from SOQL results (or DML records) and returns the remaining data. Prefer it when partial data is acceptable (e.g., a dashboard that shows available fields). Use `WITH SECURITY_ENFORCED` when you must have all fields or fail fast (e.g., a transformation that requires every field to be present).

**Q: What is `SObjectDescribeOptions.DEFERRED` and why use it?**
> It's a performance optimisation. The default describe call loads all child relationship metadata eagerly. `DEFERRED` defers loading child relationships until they are explicitly accessed, reducing heap and CPU usage — important when checking CRUD in bulk-processing code.

**Q: How do you share a custom object record programmatically?**
> Insert a row into `<ObjectApiName>__Share` with `ParentId = recordId`, `UserOrGroupId`, `AccessLevel`, and `RowCause = Schema.<ObjectApiName>__Share.RowCause.Manual`. The `__Share` object is only available if the object's `sharingModel` is `Private` or `Read`.

---

## Files Created

| File | Purpose |
|---|---|
| `classes/SecurityService.cls` | CRUD/FLS assertion helpers + `WITH SECURITY_ENFORCED` + `Security.stripInaccessible` |
| `classes/AccountSharingService.cls` | `grantAccess`, `revokeAccess`, `getShares`, `grantProjectAccess` |
| `classes/SharingContextDemo.cls` | `with sharing` / `without sharing` (inner class) / `inherited sharing` patterns |
| `classes/SecurityModelTest.cls` | 19 tests covering CRUD/FLS, sharing keywords, AccountShare lifecycle |
| `objects/Project__c/Project__c.object-meta.xml` | Custom object with `sharingModel=Private` |
| `objects/Project__c/fields/Status__c.field-meta.xml` | Picklist field (Draft/Active/On Hold/Completed) |
