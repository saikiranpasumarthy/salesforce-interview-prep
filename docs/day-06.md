# Day 06 — Apex Design Patterns II: Selector Layer & Unit of Work

## Overview

Day 6 introduces the two enterprise-grade Apex patterns that underpin the **fflib** framework (Salesforce's standard enterprise pattern library) and that appear in virtually every Senior / Architect interview:

| Pattern | What It Solves |
|---|---|
| **Selector** | Scattered, inconsistent, untestable SOQL across triggers and classes |
| **Unit of Work** | Uncoordinated DML across SObject types, manual FK management, partial-failure risk |

These two patterns are almost always used together — Selectors feed data in, UoW sends changes out, and the Service layer orchestrates in the middle.

---

## Architecture

```
AccountOnboardingService
  ├── AccountsSelector          (read — 1 SOQL)
  │     implements ISelector
  └── UnitOfWork                (write — 3 DML statements)
        implements IUnitOfWork
        ├── Account INSERT
        ├── Opportunity INSERT  ← AccountId resolved from Account.Id
        └── Task INSERT         ← WhatId resolved from Opportunity.Id
```

---

## Selector Pattern Deep Dive

### What Is a Selector?

A Selector is a class with a single responsibility: **own all SOQL for one SObject type**.

```apex
// Before Selector — SOQL scattered across the codebase
// In AccountTriggerHandler:
List<Account> accs = [SELECT Id, Name FROM Account WHERE Id IN :ids];
// In AccountRatingBatch:
List<Account> accs = [SELECT Id, AnnualRevenue FROM Account WHERE ...];
// In AccountService:
List<Account> accs = [SELECT Id, Name, OwnerId, Rating FROM Account WHERE Id IN :ids];
// — three inconsistent field sets, three places to update if a new field is needed

// After Selector — one place, one field set
List<SObject> accs = new AccountsSelector().selectById(ids);
```

### ISelector Interface

```apex
public interface ISelector {
    SObjectType getSObjectType();
    List<SObject> selectById(Set<Id> idSet);
    Database.QueryLocator getQueryLocator(String whereClause);
}
```

Every selector implements this contract. `getQueryLocator()` is the hook for Batch Apex — `AccountRatingBatch.start()` calls `new AccountsSelector().getQueryLocator(condition)` rather than containing its own SOQL string.

### Selectors in This Portfolio

| Selector | Domain-specific methods |
|---|---|
| `AccountsSelector` | `selectByOwnerId`, `selectWithOpenOpportunities`, `selectByMinRevenue` |
| `OpportunitiesSelector` | `selectByAccountId`, `selectClosedWonByAccountId`, `selectRevenueByAccount`, `selectOpenByAccountId` |
| `CasesSelector` | `selectOpenByAccountId`, `selectByAccountIdAndStatus`, `countOpenCasesByAccount` |

### Key Conventions

- **`with sharing` on every selector** — queries respect the running user's visibility. Switch to a separate `without sharing` selector when elevated access is justified and documented.
- **`WITH SECURITY_ENFORCED`** on every static SOQL — field-level security enforced at the database level, not just in Apex code.
- **Explicit field lists** — never `SELECT *`. The field set is the selector's contract; it must be intentional.
- **Named methods over generic SOQL builders** — `selectOpenByAccountId()` is self-documenting; a generic `query(String whereClause)` is not.

---

## Unit of Work Pattern Deep Dive

### What Is a Unit of Work?

Unit of Work (UoW) is a **transaction coordinator**. It accumulates INSERT, UPDATE, and DELETE operations across multiple SObject types in memory, then commits them all in a single ordered, atomic transaction with Savepoint rollback.

### The Relationship Registration Problem

Without UoW, creating parent+child records requires explicit FK management:

```apex
// Without UoW — manual FK management
Account acc = new Account(Name = 'Acme');
insert acc;
// Must wait for acc.Id to be populated before building child

Opportunity opp = new Opportunity(
    Name      = 'Deal 1',
    AccountId = acc.Id,  // caller must set this explicitly
    ...
);
insert opp;

Task t = new Task(WhatId = opp.Id, ...);  // caller sets this too
insert t;
// 3 separate DML statements — 3 separate savepoints, no atomicity
```

With UoW, the caller registers the relationship and never sets FK fields:

```apex
// With UoW — relationship registration handles FK
Account acc = new Account(Name = 'Acme');
uow.registerNew(acc);

Opportunity opp = new Opportunity(Name = 'Deal 1', ...);
uow.registerNew(opp, Opportunity.AccountId, acc); // "set AccountId = acc.Id after acc is inserted"

Task t = new Task(...);
uow.registerNew(t, Task.WhatId, opp); // "set WhatId = opp.Id after opp is inserted"

uow.commitWork(); // 3 DML statements in one transaction — atomic
```

### How `commitWork()` Resolves Relationships

```
1. Process Account type:
   resolveRelationships([acc]) → acc has no parent, nothing to resolve
   INSERT [acc]                → acc.Id = '001...' (populated in-place by DML)

2. Process Opportunity type:
   resolveRelationships([opp]) → opp.AccountId = acc.Id  ← acc.Id now populated!
   INSERT [opp]                → opp.Id = '006...'

3. Process Task type:
   resolveRelationships([t])   → t.WhatId = opp.Id  ← opp.Id now populated!
   INSERT [t]
```

The key insight: **Apex DML populates the Id field on the SObject instance in-place after INSERT**. Since `relationships` stores a reference to the same SObject instance, `parent.Id` is available immediately after the parent type's INSERT block.

### Savepoint Rollback

```apex
public void commitWork() {
    Savepoint sp = Database.setSavepoint();
    try {
        doInserts();
        doUpdates();
        doDeletes();
    } catch (Exception e) {
        Database.rollback(sp);
        throw e; // re-throw — caller decides whether to log/retry
    }
}
```

If Task INSERT fails (e.g., validation rule), **all three DML operations are rolled back** — no partial Account or Opportunity is left behind. This is atomicity that three separate `insert` statements cannot provide.

### Dependency Order

UoW requires the caller to declare the dependency order at construction time:

```apex
IUnitOfWork uow = new UnitOfWork(new List<SObjectType>{
    Account.SObjectType,       // 1st — parent
    Opportunity.SObjectType,   // 2nd — child of Account
    Task.SObjectType           // 3rd — child of Opportunity
});
```

- **INSERT** fires in this order (parent first)
- **DELETE** fires in reverse order (child first — prevents master-detail constraint errors)
- **UPDATE** fires in this order (order matters less, kept consistent)

### Unregistered Type Guard

```apex
private void assertRegistered(SObject record) {
    if (!newRecords.containsKey(recordKey(record))) {
        throw new UnitOfWork.UnitOfWorkException(
            'SObjectType "' + key + '" was not included in the UnitOfWork constructor...'
        );
    }
}
```

Forgetting to add a type to the constructor list is a common mistake. The guard throws a descriptive exception immediately rather than failing silently with a null pointer later.

---

## Dependency Injection in AccountOnboardingService

```apex
public AccountOnboardingService(IUnitOfWork uow, AccountsSelector sel) {
    this.uow             = uow;
    this.accountsSelector = sel;
}
```

Constructor injection makes the service independently testable:
- Tests pass `new UnitOfWork(...)` — verifying the full stack
- Future mock tests can pass a stub `IUnitOfWork` to test the service in isolation
- No `new UnitOfWork(...)` buried inside a service method — the service has no knowledge of which UoW implementation it receives

---

## Test Coverage

| Test Class | Methods | Key Patterns |
|---|---|---|
| `SelectorUoWTest` | 18 | Selector field assertions, sub-query verification, UoW relationship resolution, rollback on failure, service E2E |

**Key test scenarios:**

| Test | What It Proves |
|---|---|
| `accountsSelector_selectWithOpenOpportunities_populatesSubquery` | Sub-query in selector returns child records |
| `accountsSelector_selectByMinRevenue_filtersLowRevenueAccounts` | Parameterised query filters correctly |
| `opportunitiesSelector_selectRevenueByAccount_aggregatesCorrectly` | Aggregate query through selector |
| `uow_registerNew_withRelationship_resolvesParentId` | Core UoW relationship resolution |
| `uow_commitWork_rollsBackOnException` | Savepoint rollback on DML failure |
| `onboardingService_onboard_createsAllThreeRecordsAtomically` | Full Account → Opportunity → Task E2E |
| `onboardingService_enrichHighRevenueAccounts_updatesRating` | Selector read + UoW write integration |

---

## Interview Talking Points

### "What is the Selector Pattern and why use it?"
Centralise all SOQL for an SObject in one class with consistent field sets and sharing enforcement. Benefits: (1) one place to add new fields, (2) `WITH SECURITY_ENFORCED` applied consistently, (3) Batch Apex `start()` calls `getQueryLocator()` here rather than containing its own SOQL string, (4) mockable surface for true unit tests.

### "What is the Unit of Work pattern?"
A transaction coordinator that accumulates DML across multiple SObject types in memory and commits them atomically with Savepoint rollback. Key benefits: (1) relationship registration eliminates manual FK management, (2) one Savepoint wraps all DML — partial commits are impossible, (3) deduplication of dirty records (Map<Id, SObject>) prevents double-update bugs.

### "How does UoW resolve parent-child relationships?"
The caller registers a relationship: `uow.registerNew(child, Child.ParentId__c, parentRecord)`. At commit time, UoW inserts parent records first — Salesforce populates `parent.Id` in-place on the SObject instance. Before inserting child records, `resolveRelationships()` reads `parent.Id` (now populated) and sets `child.ParentId__c = parent.Id`. The caller never sets the FK field.

### "Why does DELETE fire in reverse SObjectType order?"
Master-detail constraints prevent parent deletion while child records exist. By deleting in reverse dependency order (child → parent), the UoW removes all child records first, then safely deletes the parent without constraint violations.

### "What is `inherited sharing` and when do you use it on UoW?"
`inherited sharing` delegates the sharing decision to the calling context. If the calling Service is `with sharing`, UoW runs with sharing. If called from a `without sharing` context (e.g., a batch class that legitimately needs elevated access), UoW inherits that. This is appropriate for utility classes like UoW that should not impose their own sharing level — the Service owns that decision.

### "How does Selector integrate with Batch Apex?"
`AccountsSelector.getQueryLocator(whereClause)` returns a `Database.QueryLocator` that Batch Apex's `start()` returns directly. The batch class becomes a thin orchestrator; the SOQL logic lives in the Selector where it's testable and reusable independently of the batch.
