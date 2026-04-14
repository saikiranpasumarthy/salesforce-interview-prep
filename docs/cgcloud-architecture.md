# Consumer Goods Cloud — Retail Execution and Field Sales Automation
## Architecture Decision Document

**Candidate:** Saikiran Pasumarthy
**Project:** Retail Execution and Field Sales Automation System
**Stack:** Consumer Goods Cloud · Apex · LWC (Mobile-First) · Platform Events · REST/ERP Integration

---

## 1. Project Overview

### What the System Does

This system replaces a paper-based, manual field sales process for a large FMCG company with
a fully digital, mobile-first retail execution platform. Five hundred field sales representatives
visit over 50,000 retail stores daily. Before this system, reps completed paper visit forms,
called orders in by phone, and estimated inventory by eye. Out-of-stock situations went
undetected for 24–72 hours. Route planning was handled by each rep individually with no
optimization.

The system delivers:
- **Guided visit execution** — step-by-step mobile wizard driving consistent rep behavior
- **Real-time inventory capture** — stock levels recorded during every visit, out-of-stock alerts
  triggering within 60 minutes of visit completion
- **In-visit order creation** — orders captured on the mobile device, synced to ERP automatically
- **Promotion compliance auditing** — digital audit with compliance scoring per promotion per store
- **Route optimization** — nightly pre-calculated optimal visit sequence per rep

### Who Uses It

| Actor | Role | Salesforce Access |
|-------|------|--------------------|
| Field Sales Rep | Executes store visits, captures inventory, creates orders | Salesforce Mobile App (offline-capable) |
| Area Sales Manager | Reviews visit reports, handles follow-ups, approves orders | Full desktop + mobile |
| Key Account Manager | Manages large retail chains, receives out-of-stock alerts | Full desktop |
| Operations Team | Monitors ERP sync, handles order fulfillment failures | Desktop |
| Retail Store Manager | Receives no Salesforce access — external stakeholder | N/A |

### Why Consumer Goods Cloud Over Standard Sales Cloud

Standard Sales Cloud provides the CRM backbone (Accounts, Contacts, Activities) but lacks
the domain-specific constructs that field sales in FMCG requires. The choice of Consumer
Goods Cloud is justified by the following out-of-the-box capabilities:

| Capability | Standard Sales Cloud | Consumer Goods Cloud |
|---|---|---|
| Visit Object | Custom object must be built | Standard `RetailVisit` object with status lifecycle, time tracking, geo-location |
| Activity Plan Templates | Not available — custom Tasks only | Native Activity Plan + Task templates driven by store type |
| Perfect Store Framework | Not available | Built-in assessment framework with scoring |
| Retail Store Account Hierarchy | Flat Account model | Chain → Region → Individual Store hierarchy |
| Mobile-optimized Visit UI | Must build from scratch | Standard Visit Execution app for mobile |
| Territory-based Store Assignment | Manual setup | Territory Management tightly integrated |

**What CG Cloud does NOT provide out-of-the-box** (requiring custom build in this project):
- Inventory tracking object (`Store_Inventory__c`) — CG Cloud has no native inventory management
- ERP integration — no pre-built ERP connectors, must build REST integration
- Route optimization algorithm — CG Cloud provides visit scheduling but not route optimization
- In-visit order capture wizard — standard order object must be customized with LWC
- Promotion compliance scoring — audit framework exists but scoring logic is custom

---

## 2. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        CONSUMER GOODS CLOUD RETAIL EXECUTION                        │
│                            FIELD SALES AUTOMATION SYSTEM                            │
└─────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────┐
│   FIELD REP MOBILE DEVICE              │
│   Salesforce Mobile App                │
│   (Offline-capable via Briefcase)      │
└──────────┬─────────────────────────────┘
           │ Mobile Actions
           ▼
┌────────────────────────────────────────┐
│   VISIT EXECUTION LAYER                │
│   CG Cloud RetailVisit Object          │
│   + Activity Plan Templates            │
│   Status: Planned → In Progress        │
│          → Completed                   │
└──────────┬─────────────────────────────┘
           │ LWC Components (on Visit record page)
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│   LWC PRESENTATION LAYER (Mobile-First)                             │
│                                                                     │
│  ┌──────────────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │ visitExecutionWizard │  │ storeInventory   │  │ orderCapture │ │
│  │ (4-step guided UI)   │  │ Tracker          │  │ Dashboard    │ │
│  │ Step 1: Check-in     │  │ (Stock levels,   │  │ (Order hist, │ │
│  │ Step 2: Stock capture│  │  OOS flags,      │  │  ERP status, │ │
│  │ Step 3: Promo audit  │  │  refresh)        │  │  line items) │ │
│  │ Step 4: Order capture│  └──────────────────┘  └──────────────┘ │
│  └──────────────────────┘                                           │
└──────────────────────┬──────────────────────────────────────────────┘
                       │ Imperative Apex calls
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│   APEX SERVICE LAYER                                                 │
│                                                                     │
│  RetailVisitTriggerHandler → RetailVisitService                     │
│    validateVisitCheckIn()  — 2hr window validation (Custom Metadata)│
│    createActivityTasks()   — Auto-create tasks from Activity Plan   │
│    handleVisitCompletion() — Duration calc, mandatory task check    │
│                                                                     │
│  InventoryService                                                    │
│    updateStockLevels()          — Bulk upsert via external ID       │
│    generateOutOfStockAlerts()   — Case per store, KAM assigned      │
│    recalculateComplianceScore() — AggregateResult, no row loading   │
│                                                                     │
│  OrderCaptureService                                                 │
│    createOrderFromVisit()  — Order + OrderItems, PriceBook lookup   │
│    submitOrderToERP()      — Publishes Platform Event               │
│    handleERPResponse()     — Updates Order ERP sync fields          │
│                                                                     │
│  RouteOptimizationService                                            │
│    generateDailyRoute()    — Nearest-neighbor algorithm             │
│    calculateRouteMetrics() — Haversine distance + drive time        │
└──────────────────────┬──────────────────────────────────────────────┘
                       │ Platform Events + DML
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│   DATA LAYER — SALESFORCE OBJECTS                                   │
│                                                                     │
│  Account (Retail Store)  Visit (CG Cloud std)  Product2 (catalog)  │
│  Store_Inventory__c      Promotion_Audit__c    Route_Plan__c        │
│  Order + OrderItem       Integration_Error_Log__c                   │
└──────────────────────┬──────────────────────────────────────────────┘
                       │ Platform Event: Order_Submitted__e
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│   ASYNC INTEGRATION LAYER                                           │
│                                                                     │
│  ERPSyncService (Queueable + Database.AllowsCallouts)               │
│    POST /orders → RetailERP_API (Named Credential)                  │
│    Retry once on 5xx failure                                        │
│    Integration_Error_Log__c on terminal failure                     │
│                                                                     │
│  Nightly Batch: InventoryBatchSync                                  │
│    GET /inventory/{storeId} → update Store_Inventory__c bulk       │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│   EXTERNAL SYSTEMS                                                  │
│                                                                     │
│  ┌──────────────────┐    ┌─────────────────┐    ┌───────────────┐  │
│  │  ERP System      │    │  WMS (Warehouse │    │  Mapping API  │  │
│  │  (Order Mgmt)    │    │  Mgmt System)   │    │  (Haversine   │  │
│  │  POST /orders    │    │  GET /inventory │    │   computed    │  │
│  └──────────────────┘    └─────────────────┘    │   in Apex)    │  │
│                                                  └───────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│   MANAGER / OPERATIONS DASHBOARD                                    │
│                                                                     │
│  orderCaptureDashboard LWC — Order history, ERP sync status        │
│  Salesforce Reports + Dashboards — Visit compliance, route KPIs     │
│  Platform Event listeners — Real-time out-of-stock notifications    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Consumer Goods Cloud Data Model Decisions

### Account (Retail Store)

**RecordType:** `Retail_Store`

**Hierarchy:** Chain Account → Region Account → Individual Store Account

```
Walmart (Chain)
  └── Walmart Southeast Region (Region)
        ├── Walmart Store #1042 - Atlanta (Store)
        ├── Walmart Store #1043 - Savannah (Store)
        └── Walmart Store #1044 - Augusta (Store)
```

**Why Account over a custom Store object:**
- Standard Account supports parent-child hierarchy natively via `ParentId` — no custom
  lookup chains needed
- Territory Management (Enterprise Territory Management) is designed to work with Account
  — cannot assign territories to custom objects
- Standard Reports and Dashboards work against Account hierarchy out of the box
- KAM and ASM relationships map naturally to Account Teams
- CG Cloud Activity Plans reference Account for store context

**Key custom fields on Account (Retail Store):**
- `Region__c` (picklist): maps to PriceBook for regional pricing
- `Territory__c` (lookup to Territory2): rep assignment
- `Key_Account_Manager__c` (lookup to User): for OOS alert routing
- `Last_Visit_Compliance_Score__c` (percent): updated after each visit completion
- `Store_Format__c` (picklist: Hypermarket/Supermarket/Convenience): drives Activity Plan Template selection

---

### Visit (Standard CG Cloud Object — `RetailVisit`)

**Why standard Visit over custom:**
- CG Cloud's `RetailVisit` object has a pre-built status lifecycle with enforcement:
  `Planned → In Progress → Completed / Cancelled`
- Built-in geo-location capture fields: `ActualVisitStartLocation__c`,
  `ActualVisitEndLocation__c` — no custom geolocation solution needed
- Native integration with Activity Plans — cannot link custom objects to
  Activity Plan framework without hacks
- Standard mobile optimization: CG Cloud mobile app has Visit-specific layouts
  already optimized for field rep workflows
- Salesforce Einstein Activity Capture works with standard Visit, not custom objects

**Key fields used:**
| Field | Type | Purpose |
|-------|------|---------|
| `PlannedVisitStartTime` | DateTime | Window validation (±2 hrs) |
| `ActualVisitStartTime` | DateTime | Check-in timestamp |
| `ActualVisitEndTime` | DateTime | Completion timestamp |
| `Status` | Picklist | Lifecycle gate in trigger |
| `AssessmentTaskDefinition` | Lookup | Links to Activity Plan Template |
| `Sequence_Number__c` | Number | Route order from RouteOptimizationService |
| `Visit_Duration_Minutes__c` | Number | Computed on completion |
| `Visit_Score__c` | Percent | Average promotion compliance score |

---

### Activity Plan Templates

Activity Plan Templates define the standardized set of tasks a rep must complete during
each visit type. Templates are configured per Store Format:

| Store Format | Template | Tasks |
|---|---|---|
| Hypermarket | Full_Visit_Hypermarket | Stock Check, Competitor Audit, Order Capture, Promo Check (all mandatory) |
| Supermarket | Full_Visit_Supermarket | Stock Check, Order Capture, Promo Check (mandatory), Competitor Audit (optional) |
| Convenience | Quick_Visit_CVS | Stock Check, Order Capture (mandatory) |

**How templates drive consistency:**
When a new Visit is inserted (status = Planned), `RetailVisitService.createActivityTasks()`
queries the Activity Plan Template linked to the store's Account and creates individual Task
records for each template item. The rep cannot mark the visit Complete until all mandatory
Tasks are checked off — enforced in `handleVisitCompletion()`.

**Why templates over hardcoded task creation:**
Templates are configurable in Salesforce UI without code deployment. Adding a new task type
(e.g., "Digital Shelf Audit") for all Hypermarket visits requires updating the template,
not redeploying Apex.

---

### Product2 (Product Catalog)

**Why standard Product2 works without customization:**
- Standard Price Books per region (stored in Custom Metadata `PriceBook_Config__mdt`)
  handle regional pricing without product object changes
- Product Categories (standard feature) provide the hierarchy needed for compliance reports
- `ProductCode` field used as the external ID for ERP sync matching
- No custom inventory fields needed on Product2 — all inventory data lives on
  `Store_Inventory__c` (store-product junction)

---

### Store_Inventory__c (Custom Object)

**Why custom over standard Salesforce inventory objects:**
- Salesforce has no native inventory management object — `Product2` tracks catalog,
  not store-level stock
- Consumer Goods Cloud does not include inventory management; it is scoped to visit
  execution and order capture
- Full control over trigger logic, batch sync, and out-of-stock detection needed

**Key fields:**
| Field | Type | Notes |
|-------|------|-------|
| `Account__c` | Lookup(Account) | The retail store |
| `Product2__c` | Lookup(Product2) | The product |
| `Store_Product_Key__c` | Text(255), External ID | `{StoreId}_{ProductId}` — upsert key |
| `Current_Stock__c` | Number(18,0) | Live stock level from ERP or rep capture |
| `Minimum_Stock__c` | Number(18,0) | Threshold — sourced from product/store config |
| `Is_Out_Of_Stock__c` | Checkbox | `Current_Stock__c < Minimum_Stock__c` |
| `Last_Updated__c` | DateTime | When stock was last synced or captured |
| `Last_Updated_By_Visit__c` | Lookup(Visit) | Which visit updated the stock |

**OWD:** Private. Reps see only stores in their territory via Territory Management sharing rules.

---

### Promotion_Audit__c (Custom Object)

Captures promotion compliance data per product per visit. One record per promotion per visit.

**Key fields:**
| Field | Type | Notes |
|-------|------|-------|
| `Visit__c` | Lookup(Visit) | Parent visit |
| `Product2__c` | Lookup(Product2) | The promoted product |
| `Promotion__c` | Lookup(Promotion__c) | Active promotion definition |
| `Expected_Placement__c` | Picklist | Where product should be placed (End Cap, Eye Level, etc.) |
| `Actual_Placement__c` | Picklist | Where rep found it |
| `Compliance_Score__c` | Percent | 0–100: whether placement matches expectation |
| `Photo_Captured__c` | Checkbox | Simulated — indicates photo evidence recorded |
| `Notes__c` | TextArea | Rep notes on compliance issue |

**Compliance Score calculation:**
`Compliance_Score__c` = 100 if `Actual_Placement__c == Expected_Placement__c`, else 0 (binary),
with partial credit (50) if product is on shelf but wrong placement.
`recalculateStoreComplianceScore()` averages across all audits for the visit.

---

### Order + OrderItem (Standard Objects)

**Why standard Order over custom:**
- ERP systems expect Salesforce standard Order schema — custom object would require field
  mapping layer
- Price Books and Products integrate natively with standard Order/OrderItem
- Approval Processes work natively with standard Order
- Standard reporting (Revenue, Order History) works without custom report types
- Order Management Cloud (if adopted later) requires standard Order object

**Custom fields added to Order:**
| Field | Notes |
|-------|-------|
| `Visit__c` | Lookup to Visit — links order to the visit where it was captured |
| `ERP_Order_Id__c` | External ID — ERP's reference number after sync |
| `ERP_Sync_Status__c` | Picklist: Pending / Synced / Failed |
| `ERP_Sync_Message__c` | Text — ERP response message |
| `ERP_Sync_DateTime__c` | DateTime — When ERP sync completed |

---

### Route_Plan__c (Custom Object)

One record per rep per day. Stores the optimized visit sequence.

**Key fields:**
| Field | Type | Notes |
|-------|------|-------|
| `Rep__c` | Lookup(User) | Assigned field rep |
| `Visit_Date__c` | Date | The planned visit day |
| `Ordered_Stores__c` | LongTextArea | JSON array of store IDs in sequence |
| `Estimated_Drive_Time__c` | Number | Total estimated drive time in minutes |
| `Total_Distance_Km__c` | Decimal | Total route distance |
| `Total_Stores__c` | Number | Count of stores in route |
| `Status__c` | Picklist | Draft / Published / In Progress / Completed |

---

## 4. LWC vs OmniStudio Decision

### Decision: LWC for this project

Consumer Goods Cloud field execution is **performance-critical on mobile**. This drove the
decision toward LWC over OmniStudio in every component of this project.

### Decision Matrix

| Factor | LWC | OmniStudio (OmniScript) | Winner |
|--------|-----|------------------------|--------|
| Mobile render performance | Native Aura/LWC stack, lightweight | OmniScript runtime adds JS payload overhead (~200KB+) | LWC |
| Offline behavior | Local JS state survives connectivity loss; Briefcase integration natural | OmniScript sessions not designed for offline-first | LWC |
| Conditional step logic | JS-controlled step navigation with full programmatic control | Conditional elements work but limited to flat branching | LWC |
| Local state management | JS class properties, reactive setters, arrays | JSON data node — works but not designed for stateful multi-step forms | LWC |
| Performance on 4+ step forms | Fast — no server round-trips between steps | IP Actions add latency on every step transition | LWC |
| Admin configurability | Requires deployment for changes | Admin can modify steps/fields without deployment | OmniStudio |
| Time to build (no-code) | Requires developer skill | Faster for configuration-oriented scenarios | OmniStudio |
| Mobile-specific SLDS | Full SLDS mobile utility class access | Limited mobile-specific styling options | LWC |

### When OmniStudio Would Be the Right Choice

OmniStudio (OmniScript + DataRaptor + Integration Procedure) would be preferred over LWC for
Consumer Goods Cloud in these scenarios:

1. **Non-mobile, configuration-heavy onboarding** — New store onboarding wizard where business
   users need to modify steps without development cycles. The performance difference is
   acceptable on desktop.

2. **KAM account planning workflows** — Key Account Managers creating annual joint business
   plans on desktop. Multi-step with server-side validation per step; IP Actions appropriate.

3. **Promotion setup and approval** — Creating promotion definitions across product catalogs
   and regions. Complex conditional logic that changes frequently — admin configurability
   outweighs performance cost.

4. **When FSC is co-deployed** — In orgs where Financial Services Cloud and CG Cloud are
   both present (bank-owned retail chains), OmniStudio is already licensed and the
   developer pool is familiar with it.

**Summary:** The visit execution wizard is real-time, mobile, offline-aware, and used 500+ times
per day by reps under time pressure — LWC is the only sensible choice. OmniStudio is powerful
for configuration-heavy, desktop-first, low-frequency admin workflows.

---

## 5. Offline Capability Strategy

### Briefcase Configuration for CG Cloud

Salesforce Mobile's Briefcase feature caches records for offline access. For this implementation:

**Objects configured for offline caching:**

| Object | Cache Rule | Rationale |
|--------|-----------|-----------|
| `RetailVisit` | Today's visits for logged-in rep | Rep must access visit details without connectivity |
| `Account` (Retail Store) | Stores in today's route | Store address, KAM, contact details needed offline |
| `Task` (Activity) | Open tasks for today's visits | Checklist items must be accessible offline |
| `Product2` | All active products (< 500 items typically) | Stock capture requires product list |
| `Store_Inventory__c` | Last known stock per store in today's route | Display last-known levels when offline |
| `Promotion_Audit__c` | Existing audits for today's visits | Pre-populate compliance data captured previously |

**Objects NOT cached offline:**

- `Order` history — too large, not needed for field capture
- `Route_Plan__c` — only the visit sequence matters, embedded in Visit records
- `Integration_Error_Log__c` — ops team only, not field-relevant

### What Happens When Rep Submits Data Offline

1. **Visit check-in** (Step 1): Recorded in local Briefcase cache. Syncs when connectivity
   restored. Status change to `In Progress` is a local update queued for sync.

2. **Stock capture** (Step 2): Stock quantities stored in local `Store_Inventory__c` records.
   Sync queue commits the upsert when online. `Last_Updated__c` uses device timestamp.

3. **Promotion audit** (Step 3): `Promotion_Audit__c` records created locally, synced on
   reconnect. No server validation during offline capture — validation runs post-sync trigger.

4. **Order capture** (Step 4): `Order` and `OrderItem` records created locally with status
   `Draft`. ERP sync (`Order_Submitted__e` Platform Event) does NOT fire until online.
   The rep sees an "Order saved — pending sync" state.

5. **Visit completion**: `Visit.Status = Completed` queued for sync. Platform Event
   `Visit_Completed__e` fires after Salesforce receives the synced completion — not
   from the device directly.

### Offline Limitations and Fallbacks

- **No real-time inventory check offline**: The `Is_Out_Of_Stock__c` comparison against
  `Minimum_Stock__c` cannot be recalculated against server data offline. The component
  falls back to: "Using last-known stock levels (as of [Last_Updated__c])."

- **No PriceBook lookup offline**: If a store is in a new region without cached PriceBook data,
  the order capture step shows a warning: "Price data unavailable offline — quantities saved,
  pricing will be applied on sync."

- **No Activity Plan Template query offline**: Templates must be cached at app startup (daily).
  If the template changes during the day, the rep gets the old version until next cache refresh.

- **Conflict resolution**: Salesforce Briefcase uses last-write-wins for field conflicts.
  `Current_Stock__c` is the only field with concurrent update risk — mitigated by including
  the Visit ID in the update so managers know which visit's data was the source.

---

## 6. Integration Strategy

### Order Sync to ERP — Event-Driven Async Pattern

```
Order Status → Submitted
      │
      ▼
OrderCaptureService.submitOrderToERP()
      │ publishes
      ▼
Platform Event: Order_Submitted__e
      │ {OrderId, StoreId, TotalAmount, LineItemCount}
      │
      ▼ (async — decoupled from UI)
ERPSyncService (Queueable + Database.AllowsCallouts)
      │
      ├── Build JSON payload from Order + OrderItems
      │
      ├── POST callout:RetailERP_API/orders
      │
      ├── Success (200): OrderCaptureService.handleERPResponse(Success)
      │      └── Update Order: ERP_Order_Id__c, ERP_Sync_Status__c=Synced
      │
      └── Failure (4xx/5xx/timeout):
             ├── Retry once (enqueue new Queueable)
             └── On second failure: log to Integration_Error_Log__c
                    + Task for Operations Team
```

**Why Platform Events instead of direct callout from trigger:**
- Trigger callouts are impossible — `RetailVisitTrigger` runs in trigger context where
  callouts are prohibited
- Platform Events decouple the UI interaction from ERP latency — rep sees "Order Submitted"
  immediately; ERP sync happens asynchronously
- Platform Event delivery is guaranteed (at-least-once) — no silent drops
- Event replay enables debugging: Operations team can replay failed events

**Idempotency:**
- `ERP_Order_Id__c` is marked as External ID on Order
- ERP API checks for duplicate `ERP_Order_Id__c` and returns existing order ID if
  already processed — prevents double-order on retry
- `ERPSyncService` checks `ERP_Sync_Status__c = Synced` before making callout to
  prevent double-submit from event replay

### Inventory Sync — Nightly Batch

```
Nightly Scheduled Batch (2:00 AM local timezone)
      │
      ├── GET callout:RetailERP_API/inventory?region={region}
      │
      ├── Parse response: [{storeId, productId, stockLevel}]
      │
      ├── InventoryService.updateStockLevels(Map<Product2Id, quantity>)
      │
      ├── Upsert Store_Inventory__c via Store_Product_Key__c external ID
      │
      └── InventoryService.generateOutOfStockAlerts() for changed OOS records
```

**Why nightly batch over real-time push:**
- ERP systems in large FMCG companies typically run inventory reconciliation nightly —
  real-time stock APIs are not universally available
- 50,000 stores × 200 products per store = 10M potential `Store_Inventory__c` records —
  real-time updates would exceed Platform Event limits at this scale
- Nightly batch with bulk upsert (2,000-record chunks) stays well within governor limits

---

## 7. Scalability for Large Retail Networks

### Large Data Volume Strategy — Visit Object

At 500 reps × 15 visits/day = 7,500 visits/day × 250 working days = **1.875M visits/year.**
After 3 years: ~5.6M visit records.

- **Date-based filtering**: All SOQL queries on Visit include `Visit_Date__c >= :cutoffDate` filter.
  Cutoff: rolling 1-year window for operational data.
- **Archival**: Visits older than 1 year archived to Salesforce Big Objects or exported to
  Data Lake. Archived via nightly Batch Apex that moves to `Visit_Archive__b` big object.
- **Index strategy**: Custom index on `Visit_Date__c + OwnerId` composite — covers the
  most frequent query pattern (rep's visits for today).
- **Selective queries**: All SOQL on Visit uses skinny table fields only — avoid querying
  all fields on 50K+ result sets.

### Inventory Recalculation Strategy

At 50,000 stores × 200 products = **10M Store_Inventory__c records.**

- **Batch over trigger**: `Is_Out_Of_Stock__c` recalculation is NOT done in a
  `Store_Inventory__c` trigger — at this scale, trigger overhead per record update would
  exhaust CPU limits. Batch Apex recalculates OOS flags in bulk.
- **AggregateResult for compliance**: `recalculateStoreComplianceScore()` uses a single
  `AggregateResult` query (AVG of `Compliance_Score__c`) — does not load individual
  `Promotion_Audit__c` records into Apex heap.
- **External ID upsert**: `InventoryService.updateStockLevels()` uses `Database.upsert()`
  with external ID — Salesforce handles matching server-side, no SOQL-per-record needed.

### Platform Events for Out-of-Stock Alerts at Scale

Instead of creating Cases synchronously in a trigger, out-of-stock detection publishes
a Platform Event (`Out_Of_Stock_Alert__e`). A Process Builder / Flow subscriber creates
Cases asynchronously, spreading the load across the event bus rather than in a single
synchronous execution context.

---

## 8. Security Model

### Object-Level Security

| Object | Field Rep | Area Manager | KAM | Operations |
|--------|-----------|-------------|-----|------------|
| Visit | Read/Edit own | Read all in region | Read all in territory | Read all |
| Store_Inventory__c | Read own territory | Read all in region | Read/Edit own territory | Read/Edit all |
| Order | Read/Edit own | Read/Approve in region | Read own territory | Read/Edit all |
| Promotion_Audit__c | Read/Edit own | Read all in region | Read own territory | Read all |
| Route_Plan__c | Read own | Read/Edit in region | None | None |

### OWD and Sharing

- **Visit OWD:** Private — reps see only their own visits
- **Account OWD:** Private — store visibility controlled by Territory Management
- **Store_Inventory__c OWD:** Private — inherits Account sharing via lookup
- **Order OWD:** Private — linked to Account, inherits territory sharing

**Territory Management (Enterprise Territory Management):**
- Territories defined by geographic region
- Each territory has an assigned Territory Manager (Area Sales Manager)
- Stores assigned to territories via Account-Territory assignment rules
- When a store is added to a territory, all reps in that territory get Read access
- ASM (Territory Manager) gets Read/Edit access to all stores and visits in territory

**Role Hierarchy:**
```
CEO
 └── VP Sales
      ├── Area Sales Manager — North
      │    ├── Field Rep 1 (North)
      │    ├── Field Rep 2 (North)
      │    └── Field Rep 3 (North)
      └── Area Sales Manager — South
           ├── Field Rep 4 (South)
           └── Field Rep 5 (South)
```

Role hierarchy grants upward visibility: ASM can see all their reps' visits and orders.
VP Sales can see everything.

---

## 9. Deployment Notes

### Pre-Deployment Requirements

1. **Enable Consumer Goods Cloud** in the target org via Setup > Consumer Goods Cloud Settings
2. **Enable Enterprise Territory Management** (ETM) — required for store assignment
3. **Assign Permission Set: Consumer_Goods_Cloud_User** to all field reps and managers
4. **Assign Permission Set: Consumer_Goods_Cloud_Admin** to system admins

### What Deploys via sf CLI (sfdx source push)

```
cgcloud-project/force-app/main/default/
  classes/         ← All Apex classes and triggers
  triggers/        ← RetailVisitTrigger
  lwc/             ← All LWC components
  customMetadata/  ← Visit_Config__mdt, Route_Config__mdt, PriceBook_Config__mdt
  objects/         ← Custom object field definitions
  permissionsets/  ← Consumer_Goods_Cloud_User.permissionset-meta.xml
```

### What Must Be Configured Manually in Salesforce UI

- **Activity Plan Templates** — Not deployable via Metadata API in all org configurations.
  Must be created via CG Cloud > Activity Plan Templates setup UI.
- **Named Credential: RetailERP_API** — Credentials (username/password/auth token)
  are org-specific and must be configured post-deployment.
- **Territory structure** — Territory hierarchy and store assignments are configured
  via Territory Management setup UI.
- **Mobile Navigation (Salesforce Mobile App)** — LWC components added to Visit
  and Account mobile layouts via Lightning App Builder (deployable) but navigation
  tab config requires App Manager UI.
- **PriceBook assignments** — Standard PriceBook records created in UI, then IDs
  stored in `PriceBook_Config__mdt` Custom Metadata records.

### Post-Deployment Validation Checklist

- [ ] Field rep can open a Visit on mobile and see `visitExecutionWizard` LWC
- [ ] Check-in time validation fires correctly (test with backdated PlannedVisitStartTime)
- [ ] Activity tasks auto-created on Visit insert (insert a test Visit, verify Tasks exist)
- [ ] `Store_Inventory__c` upsert via external ID works (duplicate insert = update, not new record)
- [ ] Out-of-stock Case created and assigned to KAM on OOS flag change
- [ ] Order creation from visit links correctly to Account and Visit
- [ ] `Order_Submitted__e` event fires on Order status change to Submitted
- [ ] ERP callout mock returns success (test with `ERPCalloutMock`)
- [ ] Route_Plan__c generated for a test rep with 5+ stores
