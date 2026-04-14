# Consumer Goods Cloud — Interview Q&A
## Retail Execution and Field Sales Automation

**Candidate:** Saikiran Pasumarthy
**Project:** Consumer Goods Cloud Retail Execution System
**Stack:** Consumer Goods Cloud · Apex · LWC (Mobile-First) · Platform Events · REST/ERP Integration

---

## Section 1 — Advanced Architect-Level Questions

---

### Q1. How does Consumer Goods Cloud differ from standard Sales Cloud for a field sales use case?

**Answer:**

Standard Sales Cloud gives you the foundational CRM objects — Accounts, Contacts, Activities, Opportunities — but it lacks domain-specific constructs for field execution in FMCG or retail.

**What CG Cloud adds out of the box:**

| Capability | Standard Sales Cloud | Consumer Goods Cloud |
|---|---|---|
| Visit Object | Must build custom with lifecycle trigger | Standard `RetailVisit` with Planned → In Progress → Completed lifecycle, geo-capture fields |
| Activity Plan Templates | Tasks only — no template-driven auto-generation | Native Activity Plan Templates that generate Tasks per visit type |
| Retail Account Hierarchy | Flat Account model | Chain → Region → Individual Store hierarchy with rollups |
| Perfect Store Framework | Not available | Built-in assessment framework with compliance scoring |
| Mobile Visit Execution App | Must fully custom-build | Pre-built CG Cloud mobile experience for Visit execution |
| Territory-based Store Assignment | Manual with ETM | Enterprise Territory Management integrated with Visit and Account |

**What CG Cloud does NOT provide (must be built custom):**
- Inventory tracking (`Store_Inventory__c` — no native inventory object)
- ERP integration (no pre-built connectors)
- Route optimization (Visit scheduling exists, route algorithm must be custom)
- In-visit order capture wizard (standard Order object customized with LWC)
- Promotion compliance scoring (audit framework exists, scoring logic is custom)

**Interview tip:** The key differentiator is the **Visit object + Activity Plans** combination. A standard Sales Cloud Activity doesn't have the store-linked lifecycle, geo-capture, or template-driven task generation that retail field execution requires. CG Cloud also brings Briefcase-aware mobile configuration for offline visit execution — something you'd have to manually configure in Sales Cloud.

> **Maps to code:** Architecture doc Section 1 + 3 (`cgcloud-architecture.md`), `RetailVisitTriggerHandler.cls`, `RetailVisitService.createActivityTasks()`

---

### Q2. How do you design visit execution for offline-first mobile usage in Salesforce?

**Answer:**

Offline-first design in Salesforce Mobile is driven by **Briefcase configuration** + **LWC local state strategy** + **graceful degradation**.

**Briefcase configuration — what to cache:**

| Object | Cache Rule | Why |
|--------|-----------|-----|
| RetailVisit__c | Today's visits for logged-in rep | Core execution context |
| Account (Retail Store) | Stores in today's route | Address, KAM, store format |
| Task | Open tasks for today's visits | Activity checklist |
| Product2 | All active products (<300 items typically) | Stock capture product list |
| Store_Inventory__c | Last known stock for today's stores | Show last-known levels offline |

**LWC strategy for offline:**
- `visitExecutionWizard` uses **imperative Apex** and **local JS state arrays** (`stockEntries`, `auditEntries`, `orderEntries`) — data accumulated across steps is never written to the server per step
- On connectivity loss, the component degrades gracefully: captures continue locally; submission is queued
- Wire adapters are NOT used — cached wire results become stale immediately on connectivity loss; imperative gives explicit control

**Sync flow on reconnect:**
1. Visit check-in (Status → In Progress): queued update syncs; trigger fires server-side
2. Stock capture: Store_Inventory__c upsert via external ID, device timestamp for Last_Updated__c
3. Order creation: Order/OrderItem inserts synced; `Order_Submitted__e` Platform Event fires AFTER connectivity restored — the rep sees "Order saved — pending sync"
4. Visit completion: Status → Completed; `Visit_Completed__e` fires after server receives the sync

**Limitations to state explicitly in interviews:**
- No real-time inventory check offline — component shows "Using last-known stock as of [timestamp]"
- PriceBook validation requires connectivity — unpriced products noted as "price pending"
- Activity Plan Template changes made during the day don't reach offline reps until cache refresh

> **Maps to code:** Architecture doc Section 5 (`cgcloud-architecture.md`), `visitExecutionWizard.js` connectedCallback + local state arrays

---

### Q3. What is the Activity Plan framework in CG Cloud and how does it drive rep behavior consistency?

**Answer:**

The Activity Plan framework in CG Cloud is the mechanism that converts a generic Visit into a standardized, repeatable execution workflow for every rep across every store type.

**How it works:**
1. **Activity Plan Templates** are defined per store format (Hypermarket, Supermarket, Convenience)
2. Each template contains **Activity Plan Items** — the tasks a rep must complete (Stock Check, Order Capture, Promotion Audit, Competitor Audit)
3. Items are categorized as **mandatory** or **optional**
4. When a Visit is inserted (Status = Planned), `RetailVisitService.createActivityTasks()` queries the template linked to the store's Account and bulk-creates Task records — one per item
5. On Visit completion, `handleVisitCompletion()` checks whether all mandatory Tasks are Completed
6. If any mandatory task is still open → a follow-up Task is created for the Area Manager

**Why this drives consistency:**
- 500 reps cannot be individually trained on every new product SKU audit — the template ensures they're all prompted for the same activities
- Adding a new mandatory step (e.g., "Digital Shelf Audit" for all Hypermarkets) requires updating the template in UI, not redeploying Apex
- Completion rate of mandatory tasks becomes a measurable KPI in reporting

**Configuration vs code boundary:**
- Templates are configured in Salesforce UI (Activity Plan Template setup) — not deployable via Metadata API in all org configurations
- The Task creation logic is Apex, but the task list content is admin-configurable
- Custom Metadata (`Visit_Config__mdt`) governs the check-in window — thresholds are admin-changeable without code changes

> **Maps to code:** `Activity_Plan_Template__c`, `Activity_Plan_Item__c`, `RetailVisitService.createActivityTasks()`, `RetailVisitTriggerHandlerTest.testCreateActivityTasks_createsCorrectNumberOfTasks()`

---

### Q4. How do you handle inventory data at 50,000 store scale without hitting governor limits?

**Answer:**

At 50,000 stores × 200 products per store = **10 million Store_Inventory__c records**, naive approaches break immediately.

**Five decisions that make this scale:**

**1. External ID upsert, not query-then-insert:**
```apex
// Store_Product_Key__c = storeId + '_' + productId
Database.upsert(records, Store_Inventory__c.Store_Product_Key__c, false);
```
One `Database.upsert` call matches against the external ID server-side. No SOQL per record. No map lookups in loops.

**2. Batch Apex for nightly sync, not trigger-based recalculation:**
Trigger on every `Store_Inventory__c` update at this scale would exhaust CPU limits. Nightly `InventoryBatchSync` processes stores in 2,000-record chunks. `Is_Out_Of_Stock__c` recalculated in the batch, not per-record in a trigger.

**3. AggregateResult for compliance scores — no row loading:**
```apex
// One SOQL: AVG(Compliance_Score__c) grouped by store
// Does NOT load 500 Promotion_Audit__c records into heap
```

**4. Platform Events for OOS alert fan-out:**
Instead of creating Cases synchronously inside the upsert DML chain (which hits row limits), `Out_Of_Stock_Alert__e` is published. The subscriber creates Cases asynchronously, spreading the load across the event bus.

**5. One Case per store, not per product:**
`generateOutOfStockAlerts()` groups by `Account__c` before inserting Cases. 50 OOS products at one store = 1 Case, not 50. At 50,000 stores with any OOS items, this prevents Case volume explosion.

**LDV strategies for the Visit object:**
- Date-based filter on all queries (`PlannedVisitStartTime__c >= :cutoffDate`)
- Custom composite index on `OwnerId + PlannedVisitStartTime__c`
- Archive visits > 1 year old to BigObject (`Visit_Archive__b`)
- Skinny table on Visit for the most-queried field set

> **Maps to code:** `InventoryService.updateStockLevelsForStores()`, `InventoryService.generateOutOfStockAlerts()`, `InventoryService.recalculateStoreComplianceScore()`, Architecture doc Section 7

---

### Q5. When would you choose LWC over OmniStudio for a Consumer Goods Cloud implementation?

**Answer:**

The choice is driven by three factors: **mobile performance**, **offline capability**, and **change frequency**.

**Decision matrix:**

| Factor | LWC | OmniStudio | Winner |
|--------|-----|------------|--------|
| Mobile render performance | Native, lightweight | +200KB OmniScript runtime overhead | LWC |
| Offline state management | Local JS arrays survive disconnection | Session-based, not offline-designed | LWC |
| Conditional step logic | Full JS programmatic control | Flat Conditional elements | LWC |
| Real-time calculated values | Reactive getters (order total, OOS flags) | IP Action per calculation = server round-trip | LWC |
| Admin configurability | Requires deployment to change | Admin modifies in UI without deployment | OmniStudio |
| Time to build (simple forms) | Developer required | Low-code, faster for simple scenarios | OmniStudio |
| Multi-step data collection | Local state, no server per step | JSON data node | LWC |

**Choose LWC when:**
- Component runs on mobile devices carried by field reps (performance-critical)
- Step data must survive connectivity loss (offline-first)
- Real-time calculations update as the user types (order total, OOS detection)
- Complex conditional branching that changes infrequently

**Choose OmniStudio when:**
- Desktop-first workflow (KAM account planning, store onboarding)
- Business users need to modify steps/fields without development cycles
- Low-frequency, configuration-heavy workflow (joint business plan setup, promotion creation)
- Org already has OmniStudio licensed (FSC co-deployed, for example) and dev team is fluent
- No offline requirement

**In this project:** The visit execution wizard runs 500× per day per rep, on mobile, often in areas with poor connectivity. LWC was the only sensible choice. The `visitExecutionWizard` accumulates all 4 steps of data in local JS arrays and submits in one call — impossible with OmniScript's per-step IP Action pattern without significant latency.

> **Maps to code:** Architecture doc Section 4, `visitExecutionWizard.js` (local state), `storeInventoryTracker.js` (wire + refreshApex — appropriate for read-only desktop)

---

### Q6. How do you sync orders to an ERP system reliably without losing data on callout failure?

**Answer:**

The pattern is: **Platform Event → Queueable callout → idempotent ERP endpoint** with a retry-once strategy and Integration_Error_Log__c for terminal failures.

**Why this specific pattern:**

*Problem 1: Trigger context prohibits callouts.*
When Order.Status → Submitted fires a trigger, Salesforce blocks direct HTTP callouts from synchronous trigger context. Any attempt throws `System.CalloutException: Callout from triggers not allowed`.

*Solution: Platform Event decoupling.*
`OrderCaptureService.submitOrderToERP()` publishes `Order_Submitted__e` synchronously (within the trigger transaction). The ERP callout happens in a separate, async execution context via `ERPSyncService` (Queueable + AllowsCallouts).

**Full flow:**
```
Order.Status → Submitted
  └── Trigger → OrderCaptureService.submitOrderToERP()
        └── EventBus.publish(Order_Submitted__e)
              └── ERPSyncService.execute() [Queueable]
                    ├── POST callout:RetailERP_API/orders
                    ├── 200 → OrderCaptureService.handleERPResponse(Success)
                    ├── 5xx + retry < 1 → System.enqueueJob(new ERPSyncService(id, retryCount+1))
                    └── 4xx / 5xx after retry → handleERPResponse(Failed)
                                              + Integration_Error_Log__c
                                              + Task for Operations Team
```

**Idempotency — preventing double orders:**
- `ERP_Order_Id__c` is marked as External ID on Order
- Before calling out, `ERPSyncService.execute()` checks `ERP_Sync_Status__c == 'Synced'` — skips if already processed
- ERP endpoint checks `salesforceOrderId` in the payload — returns existing ERP order if duplicate
- Platform Event replay (Operations team can replay failed events) is safe because of both guards

**No silent drops (regulatory requirement):**
Every failure path creates a visible artifact:
- `Integration_Error_Log__c` — technical details for Operations
- `Task` (High priority) — human action item for investigation
- `ERP_Sync_Status__c = Failed` — visible in orderCaptureDashboard LWC (red chip)

> **Maps to code:** `OrderCaptureService.submitOrderToERP()`, `ERPSyncService.execute()`, `OrderCaptureServiceTest.testERPSync_calloutSuccess()`, `testERPSync_calloutFailure_logsError()`

---

### Q7. What is the Perfect Store framework and how is it implemented in Salesforce CG Cloud?

**Answer:**

**Perfect Store** is the brand's definition of the ideal shelf state at a retail location — the exact placement, facing count, pricing, and promotional display that maximizes product visibility and sales velocity.

**Four components of Perfect Store:**
1. **Shelf placement** — Is the product at eye level? On the end cap? In the correct aisle?
2. **Facing count** — Are there sufficient facings to meet the planogram specification?
3. **Pricing compliance** — Is the price tag correct and visible?
4. **Promotion execution** — Is the promotional display present, correctly placed, and compliant with the brand brief?

**How it's implemented in this project:**

At the visit level, `Promotion_Audit__c` records capture each dimension:
```
Promotion_Audit__c
├── Visit__c          → parent visit
├── Product2__c       → the product being audited
├── Expected_Placement__c → e.g., "End Cap"
├── Actual_Placement__c   → what the rep found
├── Compliance_Score__c   → 100 = compliant, 50 = wrong location, 0 = missing
└── Photo_Captured__c     → simulated photo evidence flag
```

`InventoryService.recalculateStoreComplianceScore()` computes `AVG(Compliance_Score__c)` for all audit records linked to a completed visit using a single AggregateResult query, then writes the result to `Account.Last_Visit_Compliance_Score__c`.

**Reporting layer:**
- Store-level compliance score trending over time → rep performance dashboards
- Territory rollup → ASM can compare which reps drive highest Perfect Store scores
- Product-level compliance → brand managers see which SKUs have lowest compliance

**In production at scale:**
Perfect Store thresholds (what score = "pass") are stored in Custom Metadata, not hardcoded. The brand team can raise the bar from 70% to 80% compliance without code changes.

> **Maps to code:** `Promotion_Audit__c` object, `InventoryService.recalculateStoreComplianceScore()`, `InventoryServiceTest.testRecalculateComplianceScore_calculatesCorrectAverage()`

---

### Q8. How do you secure store data so reps only see their assigned territory?

**Answer:**

Three layered mechanisms work together: **OWD Private**, **Enterprise Territory Management**, and **Apex USER_MODE**.

**Layer 1 — OWD Private:**
```
Visit          → OWD: Private (rep sees only their own visits)
Account        → OWD: Private (stores visible only via territory sharing)
Store_Inventory__c → OWD: Private (inherits Account sharing via lookup)
Order          → OWD: Private (linked to Account, territory-inherited)
```
Private OWD means zero implicit sharing — every visible record must come from an explicit sharing rule, role hierarchy, or territory assignment.

**Layer 2 — Enterprise Territory Management:**
- Stores (Accounts) are assigned to Territories via Account-Territory assignment rules (region, postal code range, etc.)
- Each Territory has a **Territory Manager** (the Area Sales Manager)
- Field Reps are assigned as Territory Members → they get Read access to all stores in the territory
- ASM (Territory Manager) gets Read/Edit access to all stores and their child objects (Visits, Inventory) in the territory
- Rep cannot see stores in an adjacent territory — even if those stores are 10 feet away

**Layer 3 — Apex USER_MODE on every SOQL:**
```apex
SELECT Id FROM Store_Inventory__c
WHERE Account__c IN :storeIds
WITH USER_MODE  // ← enforces FLS/CRUD at runtime
```
Even if a rep somehow passes a store ID they shouldn't have access to, `WITH USER_MODE` prevents Apex from returning records they don't have field-level access to. It silently omits inaccessible fields (vs `WITH SECURITY_ENFORCED` which throws).

**Role Hierarchy:**
```
VP Sales
 └── Area Sales Manager (Territory Manager)
      ├── Field Rep 1  ← sees only own visits
      ├── Field Rep 2  ← sees only own visits
      └── Field Rep 3  ← sees only own visits
```
Upward role hierarchy visibility: ASM sees all rep visits without requiring individual sharing rules.

**Testing as different user profiles:**
In `RetailVisitTriggerHandlerTest`, the KAM assignment test implicitly verifies that `Key_Account_Manager__c = UserInfo.getUserId()` — the follow-up task is assigned to the correct user. In production tests, `System.runAs(repUser)` would verify reps cannot see other territories' stores.

> **Maps to code:** Architecture doc Section 8, `with sharing` on every class, `WITH USER_MODE` in all SOQL across all 5 service classes

---

### Q9. How do you optimize daily route planning for 500+ reps without a third-party mapping service?

**Answer:**

The approach is: **pre-calculated nightly** using a **nearest-neighbour greedy algorithm** with **Haversine distance** — no external API call required.

**Why nearest-neighbour over exact TSP:**
The Travelling Salesman Problem is NP-hard. At 15 stores per rep, a brute-force solution requires evaluating 15! ≈ 1.3 trillion route permutations. Nearest-neighbour gives a good-enough approximation (typically within 20% of optimal) in O(n²) — 225 comparisons for 15 stores. Acceptable for nightly batch.

**Haversine formula in Apex (no Math.PI, no Math.toRadians):**
```apex
private static final Double PI = 3.14159265358979323846;
private static final Double EARTH_RADIUS_KM = 6371.0;

private static Double haversineKm(Double lat1, Double lng1, Double lat2, Double lng2) {
    Double dLat = (lat2 - lat1) * PI / 180.0;
    Double dLng = (lng2 - lng1) * PI / 180.0;
    Double a = Math.sin(dLat/2) * Math.sin(dLat/2)
        + Math.cos(lat1 * PI/180.0) * Math.cos(lat2 * PI/180.0)
        * Math.sin(dLng/2) * Math.sin(dLng/2);
    return EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
```
`Math.PI` and `Math.toRadians()` do not exist in Apex — both must be provided inline.

**Full flow:**
1. Nightly scheduled Batch Apex (2 AM) iterates over all active reps
2. `RouteOptimizationService.generateDailyRoute(repId, date)` queries tomorrow's visits
3. Starting point: territory centre coordinates from `Route_Config__mdt`
4. Nearest-neighbour sort updates `Visit.Sequence_Number__c` on each visit
5. `calculateRouteMetrics()` computes total distance and estimated drive time
6. `Route_Plan__c` record created with JSON-ordered store sequence, published to rep

**Limitations to state openly:**
- Haversine = great-circle (straight-line) distance; real road distance is ~20–30% longer
- Algorithm doesn't account for traffic, store opening hours, or visit duration
- When to escalate: if drive-time accuracy becomes a contractual SLA metric, integrate Google Maps Distance Matrix API via Named Credential

> **Maps to code:** `RouteOptimizationService.generateDailyRoute()`, `RouteOptimizationService.haversineKm()` (private, `@TestVisible`), Architecture doc Section 7

---

### Q10. How would you integrate Data Cloud with CG Cloud for unified retail performance analytics?

**Answer:**

Data Cloud integration with CG Cloud creates a **unified retail intelligence layer** where visit execution data, order history, inventory trends, and external data sources (ERP, competitor intelligence) are combined for deeper analytics than Salesforce reports can deliver alone.

**Architecture:**

```
CG Cloud Events (Source)          Data Cloud                   Activation (Target)
───────────────────────          ───────────                   ──────────────────────
Visit_Completed__e   ──────────► Ingestion Connector          Calculated Insights
Order_Submitted__e   ──────────► (Real-time streaming)    ──► Store Compliance Trend
Store_Inventory__c   ──────────► Batch ingestion               OOS Risk Score
Promotion_Audit__c   ──────────► (nightly snapshot)       ──► Predicted Replenishment
ERP Stock Levels     ──────────► S3 or direct API         ──► Segment: Low-compliance
                                                               stores → KAM action
```

**Five integration decisions:**

1. **Identity Resolution:** Store Account matched across ERP and Salesforce via `ExternalAccountId__c` — same store ID used in both systems. No fuzzy matching needed; deterministic join.

2. **Unified Store Profile (Data Model Object):** One record per store aggregating: visit frequency, average compliance score, OOS rate, order value per visit, time since last visit. Replaces manual report cross-referencing.

3. **Calculated Insights:** Apex-free analytics in Data Cloud's SQL-like layer:
   - `OOS_Rate = COUNT(OOS events last 30 days) / total visits`
   - `Compliance_Trend = SLOPE(Compliance_Score__c over last 6 months)`
   - `Revenue_Per_Visit = SUM(Order.TotalAmount) / COUNT(Visits)`

4. **Activation back to CG Cloud:** Low-compliance stores (score < 50%) published as a Segment, activated to Salesforce as a Campaign Member list — KAMs get a curated list of stores needing focus visits without running reports.

5. **Predictive OOS:** Historical visit + ERP stock data → identify products that go OOS within 48 hours of a visit → trigger proactive replenishment order before the next visit.

**Why this requires Data Cloud and not just Salesforce Reports:**
- Salesforce Reports aggregate within Salesforce schema — cannot join ERP stock data
- At 10M inventory records, report query times exceed limits
- Trend analysis over 2+ years of visit history requires Data Cloud's columnar storage

> **Maps to code:** Architecture doc Section 3 (ExternalAccountId__c), Integration Strategy Section 6, `ERPSyncService` (the integration layer feeding Data Cloud)

---

## Section 2 — Scenario Questions

---

### Scenario 1: Field rep visits 15 stores per day — design the complete mobile visit execution system including offline capability and ERP sync

**Approach:**

**Pre-visit (nightly, server-side):**
- `RouteOptimizationService.generateDailyRoute()` runs for every rep at 2 AM
- 15 visits sorted by proximity using nearest-neighbour, Sequence_Number__c updated
- `Route_Plan__c` record created with ordered JSON array and estimated drive time
- Briefcase sync pushes today's 15 visits + store accounts + product catalog to rep's device

**During visit (mobile, visit execution wizard):**
- Rep opens Visit record page → `visitExecutionWizard` LWC renders (4 steps)
- Step 1: Check-in — validates ±2hr window vs PlannedVisitStartTime, updates status
- Step 2: Stock capture — quantities entered into local JS array (no server call per product)
- Step 3: Promotion audit — compliance checkboxes stored locally
- Step 4: Order capture — quantities and running total calculated client-side
- On Complete: single `completeVisitAndCreateOrder` Apex call with all data

**If offline during visit:**
- Steps 1–4 capture and store data in Briefcase cache
- Order created as Draft locally; `Order_Submitted__e` fires after reconnect
- Trigger runs server-side after sync, not from device

**Post-visit (after Visit Status → Completed):**
- `handleVisitCompletion`: duration calculated, mandatory task check, follow-up Task if needed
- `Visit_Completed__e` published → downstream ERP notification subscriber
- Order Platform Event → `ERPSyncService` Queueable → ERP POST (retry once on 5xx)
- `InventoryService.updateStockLevels()` → OOS detection → Case for KAM if needed

**Trade-offs:**
- Briefcase: adds 3–5 minutes daily for cache push; acceptable vs 45 min offline wait
- Last-write-wins on reconnect: acceptable for stock quantities (rep's capture is authoritative); timestamp stored for audit
- Haversine route vs Google Maps: 20% distance estimation error acceptable at this stage; Maps API adds ~$0.01/request × 500 reps = $5/day — viable when scaling

---

### Scenario 2: Real-time out-of-stock alerts to Key Account Managers within 1 hour of visit completion

**Architecture:**

```
Visit Completed (rep submits at 2:47 PM)
  └── Visit_Completed__e Platform Event (T+0: seconds)
        └── Subscriber (Flow or Trigger)
              └── InventoryService.updateStockLevels()
                    └── New OOS detected
                          └── InventoryService.generateOutOfStockAlerts()
                                └── Case created (1 per store, KAM assigned)
                                      └── Case assignment notification email → KAM inbox
                                            (T+3: minutes total, well within 1-hour SLA)
```

**Key decisions that ensure the 1-hour SLA:**

1. **Platform Event delivery is typically < 30 seconds** — the event subscriber triggers the inventory assessment almost immediately after visit completion.

2. **One Case per store** (not one per product) prevents KAM inbox flooding. A Case with 15 OOS products listed in the description is actionable; 15 separate Cases is noise.

3. **Case assignment triggers standard Salesforce notification email** — no custom notification required. KAM receives an email alert the moment the Case is created.

4. **Alternative for sub-minute alerting:** Replace Case creation with a Platform Event → Custom Notification (Bell icon in Salesforce Mobile) for push notification to KAM's device. This adds in-app awareness without waiting for email.

5. **Failure handling:** If `generateOutOfStockAlerts` fails (e.g., Case RecordType not found), `Database.SaveResult` captures the error with `allOrNone=false` — visit completion is not rolled back. OOS alerts are best-effort; visit data is authoritative.

**What NOT to do:**
- Do NOT create Cases synchronously in a Visit trigger — trigger context doesn't know which inventory items changed
- Do NOT use a scheduled job (5-minute poll) — adds unnecessary latency
- Do NOT create one Case per OOS product — KAM receives 200 alerts per day and ignores all of them

---

### Scenario 3: Operations dashboard showing order fulfillment status across 50,000 stores with drill-down by region, rep, and product category

**Approach:**

**Tier 1 — Regional Summary (Salesforce Reports + Dashboard):**
- Standard Report Type: Orders with Account hierarchy
- Groupings: Region → Store Chain → Individual Store
- Filters: Rolling 30-day date range (prevents full-table scan on 50K stores × 365 days)
- KPIs: Total order value, Order count, ERP Sync Failed %, Average days to sync
- Dynamic Dashboard: parameterised by Territory — each ASM sees only their region

**Tier 2 — Store-Level Detail (orderCaptureDashboard LWC on Account page):**
- Date range filter (7/30/90 days) triggers imperative Apex call
- Summary tiles: Total Orders, Value, Pending Sync, Failed
- ERP Sync Status color-coded: Synced (green), Pending (amber), Failed (red)
- Line-item modal: lazy-loaded on row click — order details without leaving the record page

**Tier 3 — Drill-Down by Product Category:**
- Report built on OrderItem with Product Category grouping
- Links OrderItem → Product2 → Product Category hierarchy
- Filterable by rep, region, date range, and ERP sync status

**Scalability decisions:**
- Date-based partitioning on all queries — never full table scan
- `ERP_Sync_Status__c` index enables fast filter on Failed orders (selective field)
- `getOrderHistory` Apex method accepts `storeId` + `days` — bounded query, never unbounded
- For true real-time at 50K+ stores: CRM Analytics (Tableau CRM) handles async aggregation over large datasets that hit Salesforce report limits

**For the "Failed Orders" recovery workflow:**
- Failed orders dashboard view + bulk "Retry ERP Sync" action button
- Action triggers `System.enqueueJob(new ERPSyncService(orderId))` per selected order
- Operations team clears the failure queue without developer intervention

---

## Section 3 — Quick Reference (First-Round Interview Cheat Sheet)

| # | Question | Answer (1–2 lines) |
|---|----------|---------------------|
| 1 | What object does a field rep's store visit use? | `RetailVisit__c` in a custom implementation; standard `RetailVisit` in full CG Cloud org. Lifecycle: Planned → In Progress → Completed. |
| 2 | What are Activity Plans? | Templates defining mandatory and optional tasks per visit type. New visit insert → trigger creates Tasks from template. Drives rep consistency across 500+ reps. |
| 3 | What is Perfect Store? | Brand's ideal shelf state: product placement, facing count, price compliance, promotion execution. Scored per visit, averaged to store level. |
| 4 | How are stores assigned to reps? | Enterprise Territory Management. Stores assigned to territories; reps assigned as territory members; sharing granted automatically. |
| 5 | What is Briefcase in Salesforce Mobile? | Offline record cache configuration. Defined in App Manager — specifies which objects and records sync to rep's device for offline access. |
| 6 | How do you sync orders to ERP? | Platform Event (`Order_Submitted__e`) → Queueable callout (`ERPSyncService`). Async decoupling. Idempotency via `salesforceOrderId` in ERP payload. |
| 7 | What happens when a rep goes offline? | Briefcase cache serves reads. Edits queued locally. Triggers fire server-side when connectivity restored. Platform Events fire after reconnect, not from device. |
| 8 | How do you prevent double-ERP orders on retry? | Guard: `ERP_Sync_Status__c == 'Synced'` checked before callout. ERP checks `salesforceOrderId` as idempotency key. |
| 9 | What is the Visit lifecycle? | Planned → In Progress → Completed / Cancelled. Status transitions validated in `beforeUpdate` trigger against ±N hour window from Custom Metadata. |
| 10 | Why use External ID on Store_Inventory__c? | Enables `Database.upsert(records, ExternalIdField, false)` — no SOQL per record to match existing. Required for 10M-record scale. |
| 11 | How do you scale inventory for 50,000 stores? | Nightly Batch Apex + bulk external ID upsert. Not trigger-based. AggregateResult for calculations. Platform Events for OOS fan-out. |
| 12 | What does Route_Plan__c store? | Rep, date, JSON-ordered store ID array, total distance (km), estimated drive time (mins), Total_Stores__c. Pre-calculated nightly. |
| 13 | How is compliance scored? | `AVG(Promotion_Audit__c.Compliance_Score__c)` per visit via AggregateResult. Written to `Account.Last_Visit_Compliance_Score__c`. |
| 14 | When is OmniStudio better than LWC in CG Cloud? | Desktop-first, config-heavy, admin-maintained workflows. KAM account planning, store onboarding, promotion setup. Not for mobile field execution. |
| 15 | What is the check-in window validation? | `±N hours` from `PlannedVisitStartTime__c`. N from `Visit_Config__mdt.Check_In_Window_Hours__c`. `addError()` on Status field blocks DML. |
| 16 | How are follow-up tasks routed? | Assigned to `Account.Key_Account_Manager__c`. Falls back to store `OwnerId` if KAM not set. Created when any mandatory activity task is not Completed. |
| 17 | What prevents OOS Cases flooding the KAM? | `generateOutOfStockAlerts()` groups newly-OOS records by `Account__c`. One Case per store lists all affected products in description. |
| 18 | Why is Haversine used for route optimization? | Computable in Apex without external API. `Math.PI` and `Math.toRadians()` don't exist in Apex — constant and conversion defined inline. |
| 19 | How does `WITH USER_MODE` differ from `WITH SECURITY_ENFORCED`? | `WITH SECURITY_ENFORCED` throws exception on inaccessible field. `WITH USER_MODE` silently omits it. Safer for partial-visibility scenarios. |
| 20 | What triggers ERP sync? | `Order_Submitted__e` Platform Event, published by `OrderCaptureService.submitOrderToERP()`. Subscribed by `ERPSyncService` (Queueable + AllowsCallouts). |

---

## Appendix — Architecture Decision Cross-Reference

| Decision | Where to find it |
|----------|-----------------|
| LWC vs OmniStudio for visit wizard | Architecture doc §4; `visitExecutionWizard.js` comments |
| External ID upsert pattern | `InventoryService.updateStockLevelsForStores()` lines 55–90 |
| Platform Event for ERP decoupling | `OrderCaptureService.submitOrderToERP()` + Architecture doc §6 |
| Nearest-neighbour algorithm | `RouteOptimizationService.nearestNeighbourSort()` |
| Haversine formula (no Math.PI) | `RouteOptimizationService.haversineKm()` |
| WITH USER_MODE on all SOQL | Every service class (5 classes, ~12 queries total) |
| One Case per store (OOS grouping) | `InventoryService.generateOutOfStockAlerts()` lines 80–120 |
| Custom Metadata for all thresholds | `Visit_Config__mdt` in `RetailVisitService.validateVisitCheckIn()` |
| Mandatory task completion check | `RetailVisitService.handleVisitCompletion()` lines 140–165 |
| ERP retry logic (once on 5xx) | `ERPSyncService.execute()` — statusCode >= 500 branch |
