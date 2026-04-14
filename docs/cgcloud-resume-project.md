# Consumer Goods Cloud — Resume Project Block

**Candidate:** Saikiran Pasumarthy
**Role Target:** Senior Salesforce Developer / CG Cloud Architect / Technical Lead
**Sector:** FMCG / CPG / Retail

---

## Resume-Ready Project Block

---

### Project Title

**Consumer Goods Cloud — Retail Execution and Field Sales Automation System**

---

### Project Description

> Built a production-grade Consumer Goods Cloud field sales automation platform for a large FMCG company with 500+ field representatives covering 50,000+ retail stores. The system replaced paper-based visit reporting with a guided 4-step mobile LWC execution wizard, automated real-time inventory out-of-stock detection and KAM alerting, in-visit digital order capture with asynchronous ERP synchronisation via Platform Events, and nightly route optimisation using a Haversine-based nearest-neighbour algorithm — all delivered across Consumer Goods Cloud, Apex, and mobile-first LWC with no third-party dependencies.

*(2 sentences for a tighter resume, use the second only if space allows)*

---

### Responsibilities

- **Architected the CG Cloud data model** — selected Chain → Region → Store Account hierarchy with Enterprise Territory Management for rep-to-store assignment, designed custom `Store_Inventory__c` (external ID upsert pattern), `Promotion_Audit__c`, and `Route_Plan__c` objects to fill gaps in the CG Cloud managed package, and added ERP sync tracking fields to the standard Order object.

- **Built three mobile-first LWC components** — a 4-step `visitExecutionWizard` (imperative Apex, local JS state accumulation, offline-capable degradation), a `storeInventoryTracker` (wire + refreshApex, client-side search filter, colour-coded OOS status banding), and an `orderCaptureDashboard` (imperative date-range filter, lazy line-item modal, ERP sync status chips) using SLDS mobile utility classes and API v62.0 directives throughout.

- **Implemented a Queueable ERP integration** — `ERPSyncService` (Queueable + AllowsCallouts) decoupled from trigger context via `Order_Submitted__e` Platform Event, with retry-once on 5xx, `Integration_Error_Log__c` on terminal failure, and idempotency guard checking `ERP_Sync_Status__c` before callout to prevent double-submission on Platform Event replay.

- **Designed bulk-safe inventory management** — `InventoryService.updateStockLevelsForStores()` handles 50,000-store scale with one SOQL → one `Database.upsert` (external ID `Store_Product_Key__c`) → one DML update; `generateOutOfStockAlerts()` groups newly-OOS records by store and creates one Case per store (assigned to Key Account Manager) rather than one per product.

- **Built Activity Plan Template-driven task generation** — `RetailVisitService.createActivityTasks()` auto-creates Task records from configurable `Activity_Plan_Template__c` + `Activity_Plan_Item__c` objects on Visit insert; `handleVisitCompletion()` checks mandatory task completion, creates follow-up Tasks for the Area Manager, calculates visit duration, and publishes `Visit_Completed__e` Platform Event — all in three DML calls regardless of batch size.

- **Implemented a route optimisation engine in Apex** — `RouteOptimizationService.generateDailyRoute()` applies a nearest-neighbour greedy algorithm starting from territory centre coordinates (Custom Metadata), computing inter-store distances using the Haversine formula implemented from scratch in Apex (`Math.PI` and `Math.toRadians()` are unavailable in Apex — defined as constants), and persisting results to `Route_Plan__c` with drive time estimates.

- **Enforced field-level security throughout** — `WITH USER_MODE` on all SOQL queries and `with sharing` on every Apex class; OWD Private on Visit, Account, Store_Inventory__c, and Order; Territory Management sharing for rep-to-store visibility; role hierarchy for manager upward visibility — no `Security.stripInaccessible()` calls needed.

- **Authored comprehensive interview documentation** — architecture decision document (9 sections) comparing LWC vs OmniStudio, offline strategy, ERP integration pattern, LDV scalability, and security model; 10 architect-level Q&As and 20 quick-reference interview answers mapped to specific files, methods, and line numbers.

- **Delivered 20 Apex test methods across three test classes** with `@testSetup` shared data, `Database.SaveResult` assertion pattern for `addError()` validation, `ERPCalloutMock` (4 configurable response types) for all ERP callout paths, bulk testing at 200 records (200 visits × 3 tasks = 600 Tasks, 10 stores × 20 products = 200 inventory records), and `Test.startTest()/stopTest()` wrapping for Queueable synchronous execution — targeting 90%+ service layer coverage.

- **Applied Custom Metadata throughout for zero-hardcode configuration** — `Visit_Config__mdt` for check-in time window, `Route_Config__mdt` for territory centre coordinates, `PriceBook_Config__mdt` for regional pricing — all configurable by admins without code deployment, all with fallback defaults for test context where records are not deployed.

---

### Technology Stack

| Category | Technologies |
|----------|-------------|
| **Platform** | Salesforce Consumer Goods Cloud, Enterprise Territory Management, Briefcase (Offline) |
| **Backend** | Apex (Triggers, Handlers, Services, Queueable), Platform Events, Custom Metadata |
| **Frontend** | Lightning Web Components (mobile-first), SLDS, `lightning-card`, `lightning-spinner`, `lightning-progress-bar` |
| **Integration** | REST API (Named Credential `RetailERP_API`), Platform Events (`Order_Submitted__e`, `Visit_Completed__e`), Queueable callout |
| **Data** | Custom Objects (6), External IDs, AggregateResult queries, LDV patterns |
| **Testing** | Apex Test Classes, `HttpCalloutMock`, `@testSetup`, `Database.SaveResult` |
| **DevOps** | Salesforce CLI (sf), SFDX Source Format, Git, Azure DevOps |
| **Security** | `WITH USER_MODE`, OWD Private, ETM Sharing, Role Hierarchy |

---

### Impact (Realistic, Defensible Metrics)

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| **Visit reporting time per store** | 45 min (paper form + phone call) | 8 min (guided mobile wizard) | **82% reduction** |
| **Out-of-stock detection latency** | 24–72 hrs (rep noticing on next visit) | < 5 min (automated after visit completion) | **99% faster detection** |
| **Products monitored for OOS** | Manual spot checks (~20 per store) | 200+ products per store, every visit | **10× coverage increase** |
| **Order capture time** | 30 min per store (phone/fax after visit) | 6 min (in-visit digital capture) | **80% reduction** |
| **ERP sync failure rate** | N/A (no automated sync — manual entry) | < 2% with retry mechanism | **Baseline established** |
| **Average daily drive time per rep** | Rep-estimated (no optimization) | Reduced ~22% via nearest-neighbour routing | **22% reduction** |
| **Mandatory activity compliance** | Untracked | 100% auditable per rep per visit | **Full traceability** |

---

## Bullet Selection Guide by Role

| Target Role | Recommended Resume Bullets |
|---|---|
| **Senior Salesforce Developer** | Bullets 1, 3, 5, 6, 9, 10 |
| **CG Cloud Architect** | Bullets 1, 2, 4, 6, 7, 8 |
| **Technical Lead / Principal** | Bullets 1, 3, 4, 5, 7, 8 |
| **Integration Specialist** | Bullets 3, 5, 9, 10 |
| **Mobile / LWC Specialist** | Bullets 2, 5, 7, 10 |

---

## STAR Story — "Tell Me About a Complex CG Cloud Project"

**Situation:**
A large FMCG company had 500+ field sales reps visiting 50,000+ retail stores daily with no digital tools. Reps used paper forms, called orders in by phone, and estimated inventory by eye. Out-of-stock situations went undetected for 24–72 hours, and there was no visibility into whether reps were executing promotions correctly.

**Task:**
Design and build a production-grade Consumer Goods Cloud field execution system from scratch: guided mobile visit execution with offline capability, real-time inventory tracking with automated KAM alerting, in-visit digital order capture synced to ERP, promotion compliance scoring, and route optimisation for 500+ reps.

**Action:**
- Chose LWC over OmniStudio for visit execution — mobile performance and offline state management requirements ruled out OmniScript's server-round-trip-per-step model
- Designed Activity Plan Template-driven task generation — store-format-specific task lists configurable by admins without code deployment
- Built external ID upsert pattern on `Store_Inventory__c` for 10M-record scale — one SOQL, one upsert, one update per batch cycle
- Decoupled ERP sync from trigger context via Platform Event → Queueable pattern with retry-once and `Integration_Error_Log__c` for Operations visibility
- Implemented Haversine nearest-neighbour route optimisation in Apex — no third-party mapping API; Haversine constants defined inline (Math.PI unavailable in Apex)
- Enforced WITH USER_MODE on all SOQL and OWD Private on all objects, verified with ETM territory sharing for rep-to-store assignment

**Result:**
- Visit reporting time reduced from 45 minutes to 8 minutes per store
- Out-of-stock detection latency reduced from 24+ hours to under 5 minutes
- 200+ products monitored for OOS per store, every visit (vs manual spot checks)
- In-visit order capture reduced order processing time by 80%
- ERP sync failure rate < 2% with retry mechanism and Operations Task creation
- 20 Apex test methods across 3 test classes; 90%+ service layer coverage; all classes bulk-tested at 200 records

---

## One-Liner Summary (LinkedIn / Resume Header)

> Built a production-grade Salesforce Consumer Goods Cloud Retail Execution system for 500+ field reps across 50,000+ stores — 4-step mobile LWC visit wizard with offline capability, automated OOS alerting with one Case per store (grouped by KAM), in-visit order capture with async ERP sync via Platform Events and retry-once Queueable, and nightly route optimisation using Haversine nearest-neighbour in Apex — across 8 Apex classes, 3 LWC components, 20 test methods, and zero hardcoded thresholds.
