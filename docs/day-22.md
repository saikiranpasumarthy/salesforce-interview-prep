# Day 22 — Separation of Concerns (Architecture), fflib Enterprise Patterns, DI

## Topics Covered
1. SoC layered architecture — Selector, Domain, Service, Unit of Work
2. Interface-based design and Dependency Injection
3. Application factory — central DI container
4. fflib equivalence — hand-rolled pattern without managed package
5. Testing each layer independently
6. Unit of Work — batched DML and relationship resolution

---

## 1. Layered Architecture Overview

```
Trigger
  └── TriggerHandler
        └── Domain  (business rules, no SOQL, no DML)
              └── Service  (orchestration, transaction boundary)
                    ├── Selector  (all SOQL)
                    └── UnitOfWork  (all DML)
```

### Layer Responsibilities

| Layer | Does | Does NOT |
|-------|------|---------|
| **Selector** | SOQL queries | Business logic, DML |
| **Domain** | Validation, defaulting, field derivation | SOQL, DML, callouts |
| **Service** | Orchestrate layers, transaction boundary | SOQL, direct DML |
| **Unit of Work** | Batch and commit DML | Business logic, SOQL |
| **Trigger / Handler** | Route to Domain/Service | Logic of any kind |

---

## 2. Selector Layer

```apex
public interface IAccountSelector {
    List<Account> selectById(Set<Id> ids);
    List<Account> selectByType(String type);
    List<Account> selectPendingSync();
    Integer countByType(String type);
}

public with sharing class AccountSelector implements IAccountSelector {
    public List<Account> selectById(Set<Id> ids) {
        return [
            SELECT Id, Name, Type, Sync_Status__c
            FROM   Account
            WHERE  Id IN :ids
            WITH   SECURITY_ENFORCED
            ORDER BY Name
        ];
    }
    // ...
}
```

### Key rules
- Every SOQL query for Account goes here — no SOQL in Service, Domain, or Trigger
- `WITH SECURITY_ENFORCED` on every query (FLS)
- Returns `List<Account>` — never raw `SObject[]`
- Injected via the Application factory → swappable with a mock in tests

---

## 3. Domain Layer

```apex
public class AccountDomain implements IAccountDomain {
    private final List<Account> records;

    public AccountDomain(List<Account> records) { this.records = records; }

    public void onBeforeInsert() {
        applyDefaults();
        validateRequiredFields();
    }

    public void applyDefaults() {
        for (Account acc : records) {
            if (String.isBlank(acc.Rating)) { acc.Rating = 'Cold'; }
            if (String.isBlank(acc.Sync_Status__c)) { acc.Sync_Status__c = 'Pending'; }
        }
    }

    public List<Account> getChangedRecords(
            Map<Id, Account> existingRecords, Set<String> fields) {
        // Returns only records where any field in 'fields' changed
    }
}
```

### Key rules
- Constructed with the record list — stateless between trigger invocations
- `addError()` for validation — surfaces as DML exception
- `getChangedRecords()` — avoids downstream work for irrelevant field changes
- No SOQL, no DML, no callouts

---

## 4. Unit of Work

```apex
// Setup
IUnitOfWork uow = Application.UnitOfWork.newInstance();

// Register
Account parent = new Account(Name = 'Parent');
Contact child  = new Contact(LastName = 'Child');

uow.registerNew(parent);
uow.registerNew(child, Contact.AccountId, parent);  // relationship resolved after insert
uow.registerDirty(existingAccount);
uow.registerDeleted(staleRecord);

// Single DML pass — all registered in order
uow.commitWork();
// → INSERT Account (parent gets ID)
// → INSERT Contact (parent.Id written to child.AccountId)
// → UPDATE existingAccount
// → DELETE staleRecord
```

### Why UoW matters
- Without UoW: `for (acc : accounts) { insert acc; }` → N DML statements → hits limit
- With UoW: all inserts batched → 1 DML statement per sObject type
- Relationship resolution — new parent IDs written into children before child INSERT
- Single transaction — all commits or rolls back together

### `registerDirty` with field list
```apex
// Only update the fields you changed — avoid overwriting concurrent edits
uow.registerDirty(
    new Account(Id = accId, Sync_Status__c = 'Pending'),
    new List<Schema.SObjectField>{ Account.Sync_Status__c }
);
```

---

## 5. Service Layer

```apex
public with sharing class AccountService {

    public static void markForSync(Set<Id> accountIds) {
        IAccountSelector selector = getSelector();   // injected
        IUnitOfWork uow = Application.UnitOfWork.newInstance();  // injected

        List<Account> accounts = selector.selectById(accountIds);
        for (Account acc : accounts) {
            if (acc.Sync_Status__c != 'Pending') {
                uow.registerDirty(new Account(Id = acc.Id, Sync_Status__c = 'Pending'),
                    new List<Schema.SObjectField>{ Account.Sync_Status__c });
            }
        }
        uow.commitWork();  // single DML
        // Publish Platform Events AFTER DML (PublishAfterCommit)
    }
}
```

### Key rules
- One method = one business operation = one transaction boundary
- All dependencies (Selector, UoW) come from Application factory — injectable
- No `new AccountSelector()` directly in service code

---

## 6. Application Factory — Dependency Injection

```apex
public class Application {

    // Selector factory — maps Interface → ConcreteClass
    public static final SelectorFactory Selector = new SelectorFactory(
        new Map<Type, Type>{
            IAccountSelector.class => AccountSelector.class
        }
    );

    // Unit of Work factory — ordered sObject types for INSERT
    public static final UnitOfWorkFactory UnitOfWork = new UnitOfWorkFactory(
        new List<Schema.SObjectType>{
            Account.SObjectType,
            Contact.SObjectType,
            Opportunity.SObjectType
        }
    );
}
```

### Usage in production
```apex
IAccountSelector sel = (IAccountSelector)
    Application.Selector.newInstance(IAccountSelector.class);
IUnitOfWork uow = Application.UnitOfWork.newInstance();
```

### Usage in tests
```apex
Application.Selector.setMock(IAccountSelector.class, new MockAccountSelector(testData));
Application.UnitOfWork.setMock(new MockUnitOfWork());
// Now call the service — it uses mocks, no DB hit
AccountService.markForSync(ids);
```

---

## 7. Testing Each Layer

### Domain test (no DB, no mocks)
```apex
List<Account> records = new List<Account>{ new Account(Name = 'Test') };
AccountDomain domain = new AccountDomain(records);
domain.applyDefaults();
System.assertEquals('Cold', records[0].Rating);
```

### Selector test (real DB — integration)
```apex
Account acc = new Account(Name = 'Test', Type = 'Customer');
insert acc;
List<Account> result = new AccountSelector().selectByType('Customer');
System.assert(!result.isEmpty());
```

### UoW test (real DB — batch DML)
```apex
UnitOfWork uow = new UnitOfWork(new List<Schema.SObjectType>{ Account.SObjectType, Contact.SObjectType });
Account parent = new Account(Name = 'Parent');
Contact child  = new Contact(LastName = 'Child');
uow.registerNew(parent);
uow.registerNew(child, Contact.AccountId, parent);
uow.commitWork();
System.assertNotEquals(null, parent.Id);
System.assertEquals(parent.Id, [SELECT AccountId FROM Contact WHERE Id = :child.Id].AccountId);
```

### Service test (mocks — no DB)
```apex
Application.Selector.setMock(IAccountSelector.class, new MockSelector(testAccounts));
Application.UnitOfWork.setMock(mockUow);
AccountService.markForSync(ids);
System.assert(mockUow.commitCalled);
System.assertEquals(1, mockUow.dirtyRecords.size());
```

---

## 8. fflib Equivalence

| This project | Full fflib |
|-------------|-----------|
| `IAccountSelector` | `fflib_ISObjectSelector` |
| `AccountSelector` | extends `fflib_SObjectSelector` |
| `IAccountDomain` | `fflib_ISObjectDomain` |
| `AccountDomain` | extends `fflib_SObjectDomain` |
| `IUnitOfWork` | `fflib_ISObjectUnitOfWork` |
| `UnitOfWork` | extends `fflib_SObjectUnitOfWork` |
| `Application` | `fflib_Application` |

**Why hand-rolled instead of full fflib?**
- No managed package dependency → deployable to any org
- No namespace conflicts
- Full control over UoW INSERT ordering and error handling
- Same SoC benefits — Selector/Domain/Service/UoW separation, DI via Application factory

---

## Interview Q&A

**Q: What is the Selector layer and why should all SOQL go through it?**
A: The Selector encapsulates all SOQL queries for a given sObject. Every method returns a typed list — no raw SOQL leaks to callers. Centralizing SOQL in one class means: (1) all FLS enforcement (`WITH SECURITY_ENFORCED`) is in one place; (2) tests can replace the Selector with a mock that returns controlled data, eliminating database dependencies from unit tests; (3) SOQL changes only require editing one class. Without a Selector, SOQL is scattered across Service, Domain, and Trigger code — hard to find, hard to mock, easy to duplicate.

**Q: What does the Unit of Work pattern solve?**
A: Without UoW, code issues one DML statement per record (N inserts = N DML hits), quickly consuming the 150 DML statement limit. UoW buffers all registrations and issues one `insert`, one `update`, and one `delete` per sObject type regardless of record count. It also resolves parent-child relationships: you register a child with a reference to its parent, and after the parent is inserted, the parent's real ID is written into the child's foreign key before the child is inserted. All operations run in a single transaction — atomically commit or roll back.

**Q: How does Dependency Injection work in Apex without a DI framework?**
A: The Application class acts as the DI container. It holds a map of Interface → ConcreteClass. When production code asks `Application.Selector.newInstance(IAccountSelector.class)`, the factory instantiates `AccountSelector`. In tests, `Application.Selector.setMock(IAccountSelector.class, mockInstance)` replaces the binding for the duration of the test. This makes every layer independently testable: the Service is tested with a mock Selector (no DB) and a mock UoW (no DML), while the Selector is tested with a real DB in a separate integration test.

**Q: What is the Domain layer responsible for in the fflib pattern?**
A: The Domain is a wrapper around a list of sObject records that encapsulates all record-level business rules: validation (field constraints, business rule enforcement via `addError()`), defaulting (setting field values on insert/update), field derivation (computed values), and change detection (`getChangedRecords()` for filtering records where relevant fields changed). The Domain is constructed fresh per trigger invocation with `Trigger.new`. It never issues SOQL (delegates to Selector) and never issues DML (delegates to UoW via the Service).

**Q: Why is the Service layer the transaction boundary?**
A: Each public method on the Service represents one complete business operation that must succeed or fail atomically. The Service instantiates a UoW, orchestrates Selectors and Domains to determine what needs to happen, registers all DML with the UoW, and calls `commitWork()` at the end. If anything fails — a validation error, a query exception, a DML limit — the entire transaction rolls back. This is the "unit of work" concept: one service method = one transaction. Code outside the service (trigger handlers, REST endpoints, batch jobs) calls the service and gets an all-or-nothing guarantee.

**Q: How does `getChangedRecords()` improve performance?**
A: In an update trigger, `Trigger.new` contains every record that was updated, even if the relevant fields did not change. Without change detection, every update fires all downstream processing even for unrelated field changes. `getChangedRecords(Trigger.oldMap, fieldsOfInterest)` filters to only records where at least one field in `fieldsOfInterest` changed. This reduces Platform Event publishing, Queueable enqueuing, and external sync triggers to only records that actually need downstream action — critical for high-volume orgs where any account update would otherwise flood the integration queue.
