# Day 29 — Sales Cloud & CPQ

## Topics Covered

- Quote-to-Cash object model (standard Salesforce)
- Pricebook, Product2, and PricebookEntry relationships
- Quote lifecycle: Draft → Submitted → Approved → Converted to Order
- Quote sync (`IsSyncing`) and its constraints
- Approval Process API (programmatic submission & decision)
- Salesforce CPQ (SBQQ) object model and pricing waterfall
- Discount schedules, tiers, and volume pricing
- Product bundles and configuration options
- Contracted prices and subscription renewals

---

## Quote-to-Cash Object Model

```
Opportunity
  └── Quote                   Price proposal sent to customer
        └── QuoteLineItem     One line per product + negotiated price
              └── PricebookEntry  Product2 in a Pricebook2 with its price

Product2          Master product catalogue
Pricebook2        Price list (Standard, Partner, Regional, etc.)
PricebookEntry    Unit price of a Product2 in a specific Pricebook2

Order             Confirmed sale (converted from accepted Quote or Opportunity)
  └── OrderItem   One line per product on the order

Contract          Executed legal agreement, linked to Account
```

---

## Key Rules

| Rule | Detail |
|------|--------|
| Pricebook assignment | `Opportunity.Pricebook2Id` must be set before adding `OpportunityLineItem` records |
| Quote sync | `IsSyncing = true` — QuoteLineItem changes sync back to `Opportunity.Amount` |
| One syncing quote | Only **one** Quote per Opportunity may have `IsSyncing = true` at a time |
| Pre-conversion | Quote must have `Status = 'Accepted'` (or pass approval) before Order conversion |
| Test pricebook | `Test.getStandardPricebookId()` required in test context — direct SOQL on `Pricebook2` in tests needs extra setup |

---

## Quote Lifecycle

```
Draft
  → (edit lines, submit for approval)
Needs Review / In Review
  → (approver decision)
Approved / Accepted
  → convertQuoteToOrder()
Denied / Rejected
```

### IsSyncing Management

```apex
// Deactivate any existing syncing quote first
List<Quote> syncing = [SELECT Id FROM Quote
                       WHERE OpportunityId = :oppId AND IsSyncing = true];
if (!syncing.isEmpty()) {
    for (Quote q : syncing) { q.IsSyncing = false; }
    update syncing;
}
// Then create the new syncing quote
Quote q = new Quote(OpportunityId = oppId, IsSyncing = true, ...);
insert q;
```

---

## Approval Process API

### Submit for Approval

```apex
Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
req.setObjectId(quoteId);
req.setComments('Requesting approval');
req.setSubmitterId(UserInfo.getUserId());         // defaults to running user
req.setProcessDefinitionNameOrId('QuoteApproval'); // target specific process
Approval.ProcessResult result = Approval.process(req);

if (result.isSuccess()) {
    List<Id> workItemIds = result.getNewWorkitemIds(); // pending approvals
}
```

### Approve / Reject

```apex
Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
req.setWorkitemId(workItemId);   // from getNewWorkitemIds()
req.setAction('Approve');        // 'Approve' | 'Reject' | 'Removed'
req.setComments('LGTM');
Approval.ProcessResult result = Approval.process(req);
```

### Key Fields on ProcessResult

| Field | Type | Description |
|-------|------|-------------|
| `isSuccess()` | Boolean | True if submitted/processed without errors |
| `getNewWorkitemIds()` | List\<Id\> | WorkItem Ids created (pending approvers) |
| `getErrors()` | List\<ProcessResultError\> | Errors if `isSuccess()` = false |
| `getInstanceId()` | Id | ProcessInstance Id for tracking |
| `getInstanceStatus()` | String | 'Pending', 'Approved', 'Rejected', 'Removed' |

---

## Salesforce CPQ Object Model (SBQQ Namespace)

```
SBQQ__Quote__c
  └── SBQQ__QuoteLine__c            One line per product/bundle
        └── SBQQ__Product__c        CPQ-enriched product record

SBQQ__Product__c
  └── SBQQ__ProductOption__c        Bundle component (parent→child)

SBQQ__DiscountSchedule__c
  └── SBQQ__DiscountTier__c         Volume discount tiers (qty ranges)

SBQQ__PriceRule__c                  Automated field updates on recalc
  └── SBQQ__PriceCondition__c       When the rule fires
  └── SBQQ__PriceAction__c          What gets updated and to what value

SBQQ__ContractedPrice__c            Negotiated price overrides per account
SBQQ__Subscription__c               Active subscription lines from contracts
```

---

## CPQ Pricing Waterfall

The waterfall is the sequence CPQ evaluates to arrive at the final customer price:

```
1. List Price            PricebookEntry.UnitPrice (base)
2. Partner Discount      SBQQ__PartnerDiscount__c %
3. Customer Discount     SBQQ__CustomerDiscount__c %
4. Additional Discount   Manual line-level override
5. Distributor Discount  Channel-specific discount
6. Net Price             After steps 1–5
7. Markup                Cost-plus calculation
8. Regular Price         Before volume/subscription adjustments
9. Contracted Price      SBQQ__ContractedPrice__c (account-specific override)
10. Customer Price       Final price charged to customer
```

### Triggering Recalculation

```apex
// CPQ managed package API (requires SBQQ package installed)
SBQQ.QuoteAPI.calculate(quote);

// SBQQ__Quote__c.SBQQ__CalculationStatus__c tracks state:
// 'Pending' → 'In Progress' → 'Completed' | 'Failed'
```

---

## Product Bundles

A bundle is a parent product with required/optional component products (ProductOptions).

```
SBQQ__ProductOption__c fields:
  SBQQ__ConfiguredSKU__c  — parent bundle product
  SBQQ__OptionalSKU__c    — child component product
  SBQQ__Required__c       — cannot be removed from bundle
  SBQQ__Optional__c       — user may add/remove
  SBQQ__Selected__c       — pre-selected by default
  SBQQ__MinQuantity__c    — minimum quantity of this option
  SBQQ__MaxQuantity__c    — maximum quantity of this option
  SBQQ__Feature__c        — groups options into sections
  SBQQ__FeatureSort__c    — display order within feature group
```

### Configuration Rules
- `SBQQ__ConfigurationRule__c` — hides, shows, requires, or disables options
- Triggered during product configuration based on selected options
- Can auto-add or auto-remove dependent options

---

## Discount Schedules

```apex
// Tier matching example (LowerBound inclusive, UpperBound exclusive)
// Qty 1–9: 0% | Qty 10–49: 5% | Qty 50+: 10%

SBQQ__DiscountSchedule__c
  SBQQ__DiscountUnit__c = 'Percent'  // 'Percent' | 'Amount'
  SBQQ__Type__c         = 'Range'    // 'Range' | 'Slab'

SBQQ__DiscountTier__c
  SBQQ__LowerBound__c = 10
  SBQQ__UpperBound__c = 50           // null = unbounded top tier
  SBQQ__Discount__c   = 5            // 5%
```

---

## Contracted Prices

```apex
// Created automatically when CPQ Contract is activated
// Overrides list price + discounts during next quote recalculation

SBQQ__ContractedPrice__c
  SBQQ__Account__c   = accountId     // account the price applies to
  SBQQ__Product__c   = productId     // specific product
  SBQQ__Price__c     = 850.00        // negotiated price
  SBQQ__StartDate__c = startDate
  SBQQ__EndDate__c   = endDate       // null = never expires
```

---

## Subscription Renewals (CPQ)

```
Quote → Approved Order → Activated → Contract
                                         └── SBQQ__Subscription__c (one per renewable line)

At renewal:
SBQQ.ContractManipulationAPI.renewContracts(contracts)
→ Creates new SBQQ__Quote__c pre-populated with subscription lines at contracted prices
```

**Co-termination**: Mid-term subscriptions are prorated and end dates aligned to the existing contract (`SBQQ__CoTermedContractsCombined__c = true`).

**Subscription Types** (`SBQQ__SubscriptionType__c`):
- `'Renewable'` — tracked in Contract, eligible for renewal
- `'One-time'` — not tracked, not renewable
- `'Evergreen'` — never expires, no renewal quote needed

---

## Standard Quote vs CPQ — Key Differences

| Capability | Standard Quote | Salesforce CPQ |
|------------|---------------|----------------|
| Product catalog | Product2 + PricebookEntry | SBQQ__Product__c (enriched) |
| Discount logic | Manual on QuoteLineItem | Automated via waterfall + rules |
| Bundles | Not supported | SBQQ__ProductOption__c |
| Configuration rules | Not supported | SBQQ__ConfigurationRule__c |
| Subscriptions | Not supported | SBQQ__Subscription__c + renewal |
| Contracted prices | Manual | SBQQ__ContractedPrice__c |
| Order generation | Manual Apex | CPQ → Order API |
| Approval routing | Standard Approval Process | CPQ Approval + standard |

---

## Interview Tips

1. **IsSyncing** — only one quote can sync per opportunity; always deactivate existing syncing quotes before enabling on a new one.

2. **Test.getStandardPricebookId()** — required in test context; direct SOQL for `IsStandard = true` in tests requires Test.isRunningTest() guard.

3. **Approval.ProcessSubmitRequest vs ProcessWorkitemRequest** — submit = start a new process; workitem = respond to an existing pending item.

4. **CPQ pricing waterfall** — interviewers often ask for the order. Key: Partner → Customer → Additional → Contracted → Customer Price.

5. **Bundle Required vs Optional** — Required options auto-added and cannot be removed; Optional options are user-selectable.

6. **Contracted Price priority** — overrides all standard discounts. Critical for renewal quotes.

7. **SBQQ namespace** — all CPQ objects/fields use `SBQQ__` prefix. Use `Database.query()` with try/catch for CPQ queries to degrade gracefully in non-CPQ orgs.

8. **Order activation** — `Order.Status = 'Activated'` triggers CPQ to create Contract + Subscriptions. Cannot be undone.
