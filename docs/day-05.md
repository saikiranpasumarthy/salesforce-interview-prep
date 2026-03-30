# Day 05 — Apex Design Patterns I: Strategy, Factory & Separation of Concerns

## Overview

Day 5 introduces three foundational design patterns to the portfolio:

| Pattern | Implementation |
|---|---|
| **Strategy** | `IDiscountStrategy` + three concrete implementations |
| **Factory** | `DiscountStrategyFactory` — CMDT-driven, `Type.forName()` resolution |
| **Separation of Concerns** | Trigger → Handler → Service → Domain → Strategy layering |

The domain is Opportunity discount pricing — a universally understood, interview-friendly problem that lets patterns shine without domain-specific noise.

---

## Architecture

```
OpportunityTrigger
  └── OpportunityTriggerHandler extends TriggerHandler
        ├── beforeInsert()  ─┐
        └── beforeUpdate()  ─┴─► handlePricing()
                                   ├── OpportunityPricingDomain.validateAmount()
                                   └── OpportunityPricingService.applyDiscounts()
                                         ├── fetchAccounts()           [1 SOQL]
                                         ├── DiscountStrategyFactory.getStrategy(opp.Type)
                                         │     ├── loadConfigs()        [1 SOQL, cached]
                                         │     └── instantiate()        [Type.forName()]
                                         └── IDiscountStrategy.calculate(opp, acc)
                                               ├── TieredDiscountStrategy
                                               ├── LoyaltyDiscountStrategy
                                               └── FlatRateDiscountStrategy
                                         └── OpportunityPricingDomain.applyPricing()
```

---

## Design Patterns Deep Dive

### 1 — Strategy Pattern

**Problem:** Discount calculation varies by Opportunity.Type. Without Strategy, this produces cascading if/else or switch statements that violate Open/Closed Principle.

**Solution:** Extract the varying algorithm behind an interface contract.

```apex
public interface IDiscountStrategy {
    Decimal calculate(Opportunity opp, Account acc);
}
```

Every algorithm is independently testable, independently deployable, and independently swappable. The service layer calls `calculate()` — it never inspects the concrete type.

**Concrete strategies:**

| Class | Algorithm |
|---|---|
| `TieredDiscountStrategy` | Amount-based: 5% / 10% / 15% |
| `LoyaltyDiscountStrategy` | Account age: 5% / 10% / 15% |
| `FlatRateDiscountStrategy` | Constructor-injected flat rate (e.g. 20% for partners) |

**Adding a new strategy:** Create a class implementing `IDiscountStrategy`, add a `Discount_Strategy_Config__mdt` record — zero other changes required.

---

### 2 — Factory Pattern

**Problem:** Something must instantiate the correct strategy at runtime. If that decision lives in the service, the service must change every time a new strategy is added.

**Solution:** Centralise instantiation in a Factory that reads configuration from CMDT.

```apex
public static IDiscountStrategy getStrategy(String oppType) {
    loadConfigs(); // cached — SOQL at most once per transaction
    if (!configsByType.containsKey(oppType)) return new TieredDiscountStrategy();
    return instantiate(configsByType.get(oppType));
}
```

**`Type.forName()` dynamic instantiation:**
```apex
Type t = Type.forName(config.Strategy_Class_Name__c); // e.g. 'LoyaltyDiscountStrategy'
return (IDiscountStrategy) t.newInstance();
```

- Returns `null` for unknown class names — Factory handles this defensively by returning the default.
- `FlatRateDiscountStrategy` requires constructor injection (flat rate value from CMDT) so it is special-cased before the generic `forName()` path.

**CMDT records (source-controlled, deploy without code change):**

| Record | Opportunity Type | Strategy Class |
|---|---|---|
| Existing_Business | Existing Business | LoyaltyDiscountStrategy |
| New_Business | New Business | TieredDiscountStrategy |
| Partner | Partner | FlatRateDiscountStrategy (0.20) |

---

### 3 — Separation of Concerns

Each layer has one job. No layer reaches into another layer's domain.

| Layer | Single Responsibility | Must NOT |
|---|---|---|
| `OpportunityTrigger` | Call handler | Contain any logic |
| `OpportunityTriggerHandler` | Route events, filter changed fields | Query database |
| `OpportunityPricingService` | Orchestrate: fetch accounts, call factory, call domain | Contain business rules |
| `OpportunityPricingDomain` | Validate fields, compute pricing, enforce caps | Query database |
| `IDiscountStrategy` implementations | Single discount algorithm | Know about other strategies |
| `DiscountStrategyFactory` | Resolve strategy from config | Contain discount logic |

**Governor limit profile (200-record batch):**
- 1 SOQL for Account bulk fetch (in Service)
- 1 SOQL for CMDT load (in Factory — cached after first call)
- 0 DML (before-trigger context; fields written to Trigger.new in memory)

---

## Opportunity Custom Fields

| Field | Type | Purpose |
|---|---|---|
| `Discount_Percent__c` | Number(5,2) | Discount percentage applied (0–50) |
| `Final_Price__c` | Currency(18,2) | Amount after discount |

Both fields are stamped by `OpportunityPricingDomain.applyPricing()` in the before-trigger context — no extra DML, no extra SOQL.

---

## Discount_Strategy_Config__mdt Fields

| Field | Type | Purpose |
|---|---|---|
| `Opportunity_Type__c` | Text(255) | Maps to Opportunity.Type picklist value |
| `Strategy_Class_Name__c` | Text(255) | Fully-qualified Apex class name |
| `Flat_Rate__c` | Number(5,4) | Used by FlatRateDiscountStrategy only |
| `IsActive__c` | Checkbox | Soft-disable a strategy without deleting the CMDT record |

---

## Open/Closed Principle in Practice

> Software entities should be open for extension, closed for modification.

**Before Strategy + Factory:**
```apex
// Every new discount type → modify this method
if (opp.Type == 'Existing Business') {
    discount = calcLoyalty(acc);
} else if (opp.Type == 'New Business') {
    discount = calcTiered(opp);
} else if (opp.Type == 'Partner') {
    discount = 0.20;
}
```

**After Strategy + Factory:**
```apex
// This never changes — regardless of how many strategies are added
IDiscountStrategy strategy = DiscountStrategyFactory.getStrategy(opp.Type);
Decimal discount = strategy.calculate(opp, acc);
```

---

## Dependency Injection in Tests

`DiscountStrategyFactory.setConfigsForTest()` injects a pre-built CMDT map without SOQL:

```apex
DiscountStrategyFactory.setConfigsForTest(
    new Map<String, Discount_Strategy_Config__mdt>{
        'Existing Business' => new Discount_Strategy_Config__mdt(
            Strategy_Class_Name__c = LoyaltyDiscountStrategy.class.getName(),
            IsActive__c            = true
        )
    });
```

This mirrors the `TestDataFactory.getDefaultRatingConfigs()` approach from Day 1 — a consistent pattern across the portfolio for CMDT-dependent classes.

---

## Test Coverage

| Test Class | Methods | Scope |
|---|---|---|
| `DesignPatternTest` | 19 | Strategy units, Factory injection, Domain clamp logic, E2E trigger pipeline |

**Key test scenarios:**

| Test | Pattern Validated |
|---|---|
| `tieredStrategy_largeAmount_returnsFifteenPercent` | Strategy correct output |
| `loyaltyStrategy_seniorAccount_returnsFifteenPercent` | monthsBetween helper via @TestVisible |
| `flatRateStrategy_nonPartnerAccount_returnsZero` | Guard condition in strategy |
| `factory_unknownType_defaultsToTieredStrategy` | Factory fallback |
| `factory_loyaltyTypeMapped_returnsLoyaltyStrategy` | CMDT injection via setConfigsForTest |
| `pricingDomain_discountExceedsCap_clampedAt50Percent` | Domain bounds enforcement |
| `endToEnd_insertOpportunity_tieredDiscountStamped` | Full trigger pipeline |
| `endToEnd_updateOpportunityAmount_discountRecalculated` | Selective reprice on update |
| `endToEnd_updateWithNoAmountChange_noPricingRecalculation` | Optimized beforeUpdate filter |
| `endToEnd_bulkInsert200Opps_allPricedWithinLimits` | Bulk 200-record governor profile |
| `triggerHandler_bypass_skipsDiscountLogic` | Bypass framework from Day 1 |

---

## Interview Talking Points

### "What is the Strategy Pattern and when would you use it in Salesforce?"
Encapsulate a family of algorithms behind a common interface so the calling code never changes when a new algorithm is added. Use it whenever you have multiple variations of the same operation — discount calculation, approval routing logic, notification channel selection (email vs SMS vs Chatter).

### "How does the Factory Pattern complement Strategy?"
Factory decouples the caller from knowing which strategy to use. Combined with CMDT, the factory resolves the correct implementation at runtime from source-controlled configuration — no code changes, no deployments for new variations.

### "What is `Type.forName()` and what are its risks?"
`Type.forName(className)` returns the Apex `Type` for a given class name string. It returns `null` (not an exception) if the class doesn't exist — always null-check before calling `newInstance()`. The class must have a no-arg constructor for generic instantiation; constructor-injected types need special handling (as shown in `FlatRateDiscountStrategy`).

### "How do you enforce Separation of Concerns in a Salesforce trigger?"
Use a layered architecture: Trigger (invocation only) → Handler (event routing, bulk prep) → Service (orchestration, queries) → Domain (validation, field computation) → Strategy (single algorithm). Each layer has one reason to change and one job. The key signal that SoC is broken: a Service performing field validation, or a Domain issuing SOQL.

### "How do you test CMDT-dependent code without deploying records?"
Expose a `@TestVisible private static void setConfigsForTest(Map<String, CMDT__mdt> configs)` method on the Factory. Tests inject in-memory records before calling any production code. The production `loadConfigs()` guards with `if (configsByType != null) return` — the injected map satisfies this check, skipping the SOQL entirely.

### "Why filter `changed` Opportunities in `beforeUpdate` instead of repricing all?"
Repricing on every field change causes unnecessary SOQL (Account fetch) and field updates on records that haven't changed. The filter `opp.Amount != old.Amount || opp.Type != old.Type` ensures the service only runs when the inputs to the pricing algorithm actually changed — reducing query count and audit trail noise.
