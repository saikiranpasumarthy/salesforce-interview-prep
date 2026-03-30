# Day 07 — Apex Testing Deep Dive: Mocking, Stubs & TestDataBuilder

## Overview

Day 7 elevates the portfolio's testing quality from integration-only to a full spectrum:

| Test Type | Infrastructure Used | DML | SOQL |
|---|---|---|---|
| **Unit** | MockUnitOfWork + MockSelector | 0 | 0 |
| **Stub** | ApexMockFramework (StubProvider) | 0 | 0 |
| **Integration** | Real UoW + Real Selectors | ✅ | ✅ |
| **Boundary** | TestDataBuilder | ✅ | ✅ |

---

## New Classes

| Class | Pattern | Purpose |
|---|---|---|
| `MockUnitOfWork` | Hand-rolled mock | Captures UoW registrations without DML; rich assertion helpers |
| `MockSelector` | Hand-rolled mock | Returns pre-built SObjects without SOQL; tracks call count |
| `ApexMockFramework` | System.StubProvider | Generic stub generator for any interface via `Test.createStub()` |
| `TestDataBuilder` | Builder Pattern | Fluent, self-documenting test data construction |
| `AccountHealthService` | Service (injectable) | Minimal service with ISelector + IUnitOfWork injection for mock demos |

---

## Pattern 1 — Hand-Rolled Mocks

### Why Hand-Rolled Over Generated Stubs?

Hand-rolled mocks provide **typed assertion helpers** that generated stubs cannot:

```apex
// Generic stub — what was registered?
provider.getCallCount('registerNew') == 3 // can only count

// Hand-rolled MockUnitOfWork — precise inspection
mock.countNewOf(Account.SObjectType)   // 1 Account
mock.countNewOf(Opportunity.SObjectType) // 1 Opportunity
mock.hasRelationship(opp, Opportunity.AccountId) // relationship verified
mock.getRelationshipParent(opp, Opportunity.AccountId) == acc // parent identity
```

Use hand-rolled mocks for core infrastructure (UoW, Selector) that appears in many tests and warrants first-class assertion methods. Use `StubProvider` for one-off stubs in isolated scenarios.

### MockUnitOfWork — Interaction Verification Without DML

```apex
@IsTest
static void onboard_registersThreeRecordsAndCommits() {
    MockUnitOfWork mock = new MockUnitOfWork();
    AccountOnboardingService svc = new AccountOnboardingService(mock, sel);

    svc.onboard(req);

    // Verify WHAT the service registered — not WHAT the database contains
    System.assertEquals(3, mock.newRecords.size());
    System.assertEquals(1, mock.countNewOf(Account.SObjectType));
    System.assert(mock.hasRelationship(opp, Opportunity.AccountId));
    System.assertEquals(true, mock.wasCommitted());
}
```

**Key insight:** This test runs with 0 DML statements and 0 SOQL queries. It verifies the service's business logic — which records it decided to create and which relationships it registered — completely independent of the database.

### MockUnitOfWork — Simulating Commit Failure

```apex
mock.shouldThrowOnCommit = true;
AccountOnboardingService.OnboardingResult result = svc.onboard(req);
System.assertEquals(false, result.success);
System.assertNotEquals(null, result.errorMessage);
```

Without a mock, testing error-handling paths requires a real DML failure (validation rule, required field, etc.). The mock flag triggers the same code path instantly without any setup.

### MockSelector — Zero SOQL Verification

```apex
@IsTest
static void mockSelector_zeroQueriesInsideStartStopTest() {
    MockSelector mock = new MockSelector(Account.SObjectType, fakeAccounts);
    AccountHealthService svc = new AccountHealthService(mock, mockUow);

    Test.startTest();
    Integer queriesBefore = Limits.getQueries();
    svc.refreshRatings(ids);
    Integer queriesAfter = Limits.getQueries();
    Test.stopTest();

    System.assertEquals(queriesBefore, queriesAfter); // 0 SOQL fired
}
```

`Limits.getQueries()` inside `startTest()/stopTest()` counts queries against the reset governor limit. If the service issues an unexpected query, this assertion fails — making inadvertent SOQL visible in CI.

### MockSelector.fakeId() — In-Memory SObjects with Valid Ids

```apex
Id fakeId = MockSelector.fakeId(Account.SObjectType, 1);
// Returns: '001000000000001AAA' (prefix + 15-char padded index)

Account acc = new Account(Id = fakeId, Name = 'Mock Corp', AnnualRevenue = 2000000);
// Valid SObject instance with a well-formed Id — no DML required
```

This is the standard technique for building in-memory SObjects in unit tests. The Id format must match the SObjectType prefix or field-type validations fail.

---

## Pattern 2 — System.StubProvider

### The StubProvider Contract

Any class implementing `System.StubProvider` intercepts all method calls on the generated stub:

```apex
public Object handleMethodCall(
    Object       stubbedObject,    // the stub instance
    String       stubbedMethodName, // method being called
    Type         returnType,        // declared return type
    List<Type>   listOfParamTypes,  // parameter types in order
    List<String> listOfParamNames,  // parameter names in order
    List<Object> listOfArgs         // actual argument values
) {
    // Return whatever value the method should produce
    return returnValues.get(stubbedMethodName);
}
```

### Generating a Stub

```apex
ApexMockFramework.GenericStubProvider provider =
    new ApexMockFramework.GenericStubProvider();
provider.whenCalled('selectById').thenReturn(stubbedList);

// Test.createStub() MUST be called from @IsTest context
ISelector stub = (ISelector) Test.createStub(ISelector.class, provider);

List<SObject> result = stub.selectById(ids);
// result == stubbedList (intercepted by handleMethodCall)
// provider.getCallCount('selectById') == 1
```

### StubProvider Limitations

1. **`Test.createStub()` is `@IsTest`-only** — cannot be called from production code
2. **No compile-time type safety** — the return value is `Object`, cast failures surface at runtime
3. **Interface/virtual class only** — cannot stub concrete classes
4. **Partial stubbing** — unconfigured methods return `null`; callers must handle this

---

## Pattern 3 — TestDataBuilder (Builder Pattern for Tests)

### The Readability Problem

```apex
// Which of these fields matters for the assertion?
Account acc = new Account(Name='X', Type='Partner', Rating='Hot',
    AnnualRevenue=2000000, BillingCity='NYC', Industry='Tech');
```

### Builder Solution

```apex
// The test specification is self-evident
Account acc = new TestDataBuilder.AccountBuilder()
    .asPartner()            // Type = 'Partner' — this is what triggers the flat-rate strategy
    .withRevenue(2000000)   // Revenue qualifies as Hot — the boundary being tested
    .build();               // No DML — unit test context
```

**Key conventions:**
- `build()` → returns the SObject without DML (unit test friendly)
- `buildAndInsert()` → inserts and returns record with Id (integration test)
- Semantic methods (`asPartner()`, `asClosedWon()`, `asHighPriority()`) express intent
- `buildStringOfLength(n, ch)` generates exact-boundary strings for Text field tests

### Bulk Helpers

```apex
// Creates 200 Accounts with sequential names and scaling revenue
List<Account> accs = TestDataBuilder.buildAccounts(200, true);

// Creates 200 Opportunities linked to one Account
List<Opportunity> opps = TestDataBuilder.buildOpportunities(acc.Id, 200, true);
```

---

## Pattern 4 — Test Isolation

### @TestSetup — Run Once, Isolate Per Test

```apex
@TestSetup
static void makeData() {
    Account acc = new TestDataBuilder.AccountBuilder()
        .withName('Setup Account')
        .withRevenue(500000)
        .buildAndInsert();
    // committed once; each test method sees a fresh copy
}
```

**Key rule:** `@TestSetup` data is committed before each test method starts. Any mutations in a test method (updates, deletes) are rolled back after the test. The next test method sees the original `@TestSetup` state. This is faster than per-method `insert` but requires that the setup data is valid for all test methods in the class.

### Static Variable Reset Between Tests

```apex
@IsTest
static void staticCache_resetBetweenTests_factoryCacheIsNull() {
    System.assertEquals(null, DiscountStrategyFactory.configsByType);
}
```

Static variables in Apex reset to their initial values at the start of each test transaction. This test verifies that assumption — critical when your production code uses static caches (as `DiscountStrategyFactory` does). If a test modifies a static variable, the next test sees the reset value, preventing cross-test pollution.

### Test.startTest() / stopTest() — Dual Purpose

```apex
Test.startTest();
Integer dmlAfterReset = Limits.getDmlStatements(); // resets to 0
// ... code under test ...
Test.stopTest(); // forces async Apex to execute synchronously
```

1. **Governor limit reset:** DML, SOQL, CPU, heap all reset to 0 inside `startTest()`. This separates setup consumption from production code consumption.
2. **Async forcing:** `Test.stopTest()` blocks until all queued async work (Queueable, future methods, Platform Events) completes. Without this, `@future` and `Queueable` tests cannot assert on results.

---

## Test Coverage Summary

| Class Tested | Test Method Count | Type |
|---|---|---|
| `AccountOnboardingService` (via MockUoW) | 4 | Unit |
| `AccountHealthService` (via MockSelector + MockUoW) | 4 | Unit |
| `ApexMockFramework.GenericStubProvider` | 3 | Unit |
| `TestDataBuilder` | 5 | Unit + Integration |
| Test isolation patterns | 4 | Meta / Infrastructure |
| **Total** | **20** | |

---

## Interview Talking Points

### "What is the difference between a unit test and an integration test in Apex?"
A unit test verifies one class's logic in isolation — all dependencies (database, external services, other classes) are replaced with mocks. An integration test exercises multiple layers together with real infrastructure. In Apex, most tests are integration tests by default because the framework encourages DML setup. The mocking patterns in Day 7 enable true unit tests.

### "How do you mock dependencies in Apex? There is no Mockito."
Two approaches: (1) Hand-rolled mocks — a plain Apex class implementing the interface being mocked, capturing interactions for assertion. (2) `System.StubProvider` + `Test.createStub()` — Apex's native stub API generates a proxy that intercepts all method calls via `handleMethodCall()`. Both require the production code to accept the dependency via an interface (Dependency Injection) — you cannot mock concrete classes.

### "What is `Test.createStub()` and what are its limitations?"
`Test.createStub(InterfaceType.class, StubProvider)` generates a proxy object for any interface or virtual class. Limitations: (1) can only be called from `@IsTest` context, (2) only interfaces and virtual/abstract classes can be stubbed — concrete classes cannot, (3) return values are typed as `Object` — runtime cast failures are possible, (4) does not enforce method signatures at compile time.

### "When should you use @TestSetup vs per-method data setup?"
Use `@TestSetup` when the same data shape is needed across all (or most) methods in the class — it runs once and each test sees a fresh copy, saving DML statements per test. Use per-method setup when a test requires a significantly different data shape that would be wasteful to create for every test. Avoid `@TestSetup` when tests need to mutate the base data — partial mutations can interact unexpectedly.

### "How does Test.startTest()/stopTest() help with governor limits?"
`Test.startTest()` resets the governor limit counters (SOQL, DML, CPU) to zero, so the code under test gets a fresh allocation independent of setup code. `Test.stopTest()` flushes and executes all queued asynchronous work (future, queueable, batch, platform events) synchronously, allowing tests to assert on async results.

### "What is Limits.getQueries() and how do you use it in tests?"
`Limits.getQueries()` returns the number of SOQL queries consumed so far in the current transaction. Inside `startTest()/stopTest()`, the counter resets to 0. Call it before and after the code under test and assert the delta equals the expected query count. This catches N+1 query bugs and unintended selector calls.
