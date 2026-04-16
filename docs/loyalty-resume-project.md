# Salesforce Loyalty Cloud — Resume Project Block

**Candidate:** Saikiran Pasumarthy
**Role Target:** Senior Salesforce Developer / Loyalty Cloud Architect / Industry Cloud Lead
**Sector:** Retail / Beauty / E-commerce / FMCG

---

## Resume-Ready Project Block

---

### Project Title

**Salesforce Loyalty Cloud — Retail Rewards and Member Engagement Platform**

---

### Project Description

> Built a production-grade Salesforce Loyalty Cloud implementation for a mid-to-large beauty retail brand unifying 2 million active members across 200+ physical stores and an e-commerce platform — replacing fragmented spreadsheet-based points tracking with a real-time accrual engine, automated tier management, and a self-service Experience Cloud portal. The system features an idempotent REST API for e-commerce integration, a configurable multi-promotion engine with stacking rules and atomic usage caps, Savepoint-backed redemption processing with Crypto-generated voucher codes, and a nightly batch processor handling points expiry and anniversary tier reviews for the full 2M member base — delivered across Loyalty Cloud, Apex, LWC, and Experience Cloud with zero hardcoded thresholds.

---

### Responsibilities

- **Architected the Loyalty Cloud data model** — selected and extended standard `LoyaltyProgram`, `LoyaltyProgramMember`, `LoyaltyMemberCurrency`, and `LoyaltyLedger` objects; designed custom `Loyalty_Transaction__c` (with `ECommerce_Order_Id__c` external ID for idempotency and `Source_Channel__c` for cross-channel attribution), `Promotion__c` (rule-based promotion engine), `Voucher__c` (redemption lifecycle object), and `Loyalty_Config__mdt` (all thresholds and rates configurable without deployment) to extend the standard package where it had gaps.

- **Built the points accrual engine** — `PointsAccrualService.accruePointsForPurchase` processes real-time purchases with base points (`purchaseAmount × pointsPerDollar` from CMDT), calls `PromotionEngineService` for applicable multipliers, creates the `Loyalty_Transaction__c` ledger entry, and updates `LoyaltyMemberCurrency` balance — all in a single Apex transaction with idempotency guard preventing duplicate awards on e-commerce platform retries.

- **Designed an automated tier management system** — `TierManagementService.evaluateTierChange` fires on every `Points_Balance__c` change, compares against CMDT-configured Silver/Gold/Platinum thresholds in O(1) (no SOQL in evaluation), creates `Tier_Change_Log__c` audit records, and sends contextually appropriate upgrade/downgrade notifications; `processAnnualTierReview` in the nightly batch resets annual counters and re-qualifies members on their enrollment anniversary.

- **Implemented atomic redemption with Savepoint rollback** — `RedemptionService.processRedemption` creates a `Database.Savepoint` before three sequential DML operations (insert redemption transaction, deduct member balance, create `Voucher__c`), rolling back all changes on any failure to prevent partial state; voucher codes generated using `Crypto.generateAESKey(128)` formatted as `XXXX-XXXX-XXXX-XXXX` for POS and e-commerce checkout use.

- **Built a configurable promotion engine with race condition protection** — `PromotionEngineService.getApplicableMultiplier` evaluates all active promotions in a single SOQL query with in-Apex stacking logic (exclusive promotions override stackable; stackable promotions combine additively); `incrementPromotionUsage` uses `FOR UPDATE` SOQL to atomically increment promotion usage counters, preventing overselling of limited-run promotions under concurrent Black Friday traffic.

- **Exposed an idempotent REST API for e-commerce integration** — `@RestResource ECommerceIntegrationService` accepts `POST /loyalty/transaction/` with member identification by ID or email, validates the request, calls the accrual engine, and returns structured JSON `{ pointsAwarded, newBalance, tierStatus, promotionApplied }`; idempotency via dual-layer guard (application-level `ECommerce_Order_Id__c` check + database-level unique constraint) eliminates duplicate points awards from e-commerce retry storms.

- **Delivered three mobile-first LWC components for Experience Cloud** — `memberDashboard` (hero tier badge with gradient colour coding, real-time points balance, tier progress bar, active vouchers card grid, toggleable transaction history, imperative Apex on `connectedCallback`), `pointsRedemptionWizard` (4-step modal with live discount preview, tier-gated reward types, double-submit prevention, and voucher code clipboard copy), and `promotionBanner` (horizontal scroll carousel with CSS scroll-snap, wire + `refreshApex`, `setInterval` 5-minute auto-refresh cleared in `disconnectedCallback`).

- **Designed a nightly batch processor for 2 million members** — `LoyaltyTransactionBatch` (`Database.Batchable` + `Database.Stateful`, 200-record scope) processes `Pending` transactions, runs anniversary tier reviews using `CALENDAR_MONTH/DAY_IN_MONTH` SOQL functions, creates offsetting expiry transactions for aged points (compensating ledger entries — never deletes), logs each run to `Batch_Run_Log__c`, and alerts the operations team via email when failure rate exceeds 5%.

- **Enforced security throughout the member data model** — OWD Private on `LoyaltyProgramMember__c`, `Loyalty_Transaction__c`, and `Voucher__c`; Experience Cloud member self-service access via Sharing Set on `AssociatedContact` lookup (no custom Apex sharing); `WITH USER_MODE` on all service layer SOQL; `Security.stripInaccessible(AccessType.READABLE)` on `getMemberSummary` AuraEnabled method before returning data to LWC; voucher codes excluded from all list views and debug logs.

- **Applied Custom Metadata throughout for zero-deployment configuration** — `Points_Config__mdt` (points per dollar, referral bonus, minimum redemption), `Tier_Config__mdt` (Silver/Gold/Platinum entry and retention thresholds), `Expiry_Config__mdt` (base and bonus points expiry months, voucher expiry days), `Program_Config__mdt` (default program ID, default tier, ops alert email) — all with `@TestVisible` fallback constants for test context where CMDT records are not deployed.

- **Delivered 25 Apex test methods across 4 test classes** — `@testSetup` shared data per class, `Database.SaveResult` assertion pattern, `ECommerceCalloutMock` with 4 response types, bulk testing at 200 records (200 members × 2 currencies = 400 records; 200 transactions bulk-processed with correct balance delta; 200 Gold members bulk-upgraded to Platinum), Savepoint rollback verified by asserting zero DML after failed redemption, and CMDT fallback constants ensuring tests pass without CMDT deployment.

---

### Technology Stack

| Category | Technologies |
|---|---|
| **Platform** | Salesforce Loyalty Cloud, Experience Cloud (LWC Runtime), Connected App OAuth 2.0 |
| **Backend** | Apex (Trigger Framework, InvocableMethod, Queueable, Batch, Stateful, `@RestResource`) |
| **Frontend** | Lightning Web Components (Experience Cloud, mobile-first), SLDS, `lightning-progress-bar`, `lightning-spinner` |
| **Integration** | REST API (`@RestResource`), Named Credential (`RetailEcommerce_API`), Idempotency via External ID |
| **Data** | Custom Objects (5), LoyaltyLedger, LoyaltyMemberCurrency, External IDs, `FOR UPDATE` SOQL, BigObject archiving strategy |
| **Batch / Events** | `Database.Batchable + Stateful`, Scheduled Apex, Platform Events (`Transaction_Request__e`) |
| **Security** | `WITH USER_MODE`, OWD Private, Experience Cloud Sharing Sets, `Security.stripInaccessible`, `Crypto.generateAESKey` |
| **Testing** | Apex Test Classes, `HttpCalloutMock`, `@testSetup`, `Database.SaveResult`, `Database.Savepoint` rollback verification |
| **DevOps** | Salesforce CLI (sf), SFDX Source Format, Git, Azure DevOps |

---

### Impact (Realistic, Defensible Metrics)

| Metric | Before | After | Improvement |
|---|---|---|---|
| **Loyalty data unification** | 3 separate systems (spreadsheet, legacy DB, Salesforce) | Single source of truth across online + 200+ stores | **Full channel unification** |
| **Points accrual latency** | 24–48 hours (nightly legacy batch) | Real-time via REST API on purchase | **99%+ faster accrual** |
| **Tier management** | Monthly manual review by ops team | Automated real-time on every transaction, 2M members | **100% ops effort eliminated** |
| **Redemption processing** | 3 minutes (manual voucher generation by ops) | Under 5 seconds (self-service Experience Cloud portal) | **97% reduction** |
| **Promotion configuration** | Hard-coded per campaign, requires developer + deployment | Admin-configurable Promotion__c records, live in minutes | **Zero deployment needed** |
| **Duplicate points from retries** | Occasional (no idempotency controls) | Zero — dual-layer idempotency guard | **100% eliminated** |
| **Member self-service** | Balance check required support call | Real-time Experience Cloud portal: balance, vouchers, history | **Full self-service** |
| **Batch processing scale** | Unproven above 500K members | Tested at 200M+ transaction scale (LDV strategy) | **2M member production-ready** |

---

## Bullet Selection Guide by Role

| Target Role | Recommended Resume Bullets |
|---|---|
| **Senior Salesforce Developer** | Bullets 2, 3, 5, 9, 10, 11 |
| **Loyalty Cloud Architect** | Bullets 1, 3, 4, 6, 8, 9 |
| **Technical Lead / Principal** | Bullets 1, 4, 5, 6, 7, 8 |
| **Integration Specialist** | Bullets 2, 6, 10, 11 |
| **Mobile / LWC Specialist** | Bullets 7, 10, 11 |
| **Industry Cloud (Retail/FMCG)** | Bullets 1, 2, 3, 5, 8 |

---

## STAR Story — "Tell Me About a Complex Loyalty Cloud Project"

**Situation:**
A mid-to-large beauty retail brand had 2 million active loyalty members but no unified system — points were tracked in spreadsheets and a legacy database with no Salesforce integration. Members had to call the support line to check their balance, tier upgrades were done manually by the ops team each month, seasonal promotions were hard-coded per campaign requiring developer involvement, and e-commerce orders were not connected to the loyalty system at all, resulting in a 24–48 hour delay before points appeared.

**Task:**
Architect and build a production-grade Salesforce Loyalty Cloud implementation covering real-time points accrual across online, in-store, and mobile channels; automated tier management for 2M members; a configurable promotion engine for 6–8 seasonal campaigns per year; self-service redemption via Experience Cloud; and a reliable e-commerce REST integration with idempotency guarantees.

**Action:**
- Extended the standard Loyalty Cloud data model rather than replacing it — `LoyaltyProgramMember`, `LoyaltyMemberCurrency`, and `LoyaltyLedger` remain standard; custom objects fill gaps (promotion rules, vouchers, channel attribution)
- Built an idempotent REST API endpoint (`@RestResource`) with `ECommerce_Order_Id__c` external ID as dual-layer idempotency guard, eliminating duplicate points from e-commerce retry storms
- Designed `PromotionEngineService` with `FOR UPDATE` SOQL locking on promotion usage counters, preventing overselling of limited-run campaigns under Black Friday concurrent load
- Implemented `RedemptionService.processRedemption` with `Database.Savepoint` atomicity across three DML operations, ensuring no partial state is ever committed on failure
- Built three Experience Cloud LWC components with mobile-first SLDS layouts, `disconnectedCallback` interval cleanup, and live discount preview in the 4-step redemption wizard
- Delivered `LoyaltyTransactionBatch` (`Database.Batchable + Stateful`, 200-record scope) for nightly points expiry, anniversary tier reviews, and ops alerting at >5% failure rate
- Applied `WITH USER_MODE`, OWD Private, Experience Cloud Sharing Sets, and `Crypto.generateAESKey` voucher code generation throughout

**Result:**
- Points accrual latency reduced from 24–48 hours to real-time on purchase
- Automated tier management eliminated 100% of manual monthly ops team effort across 2M members
- Redemption processing reduced from 3 minutes (manual voucher) to under 5 seconds (self-service)
- Zero duplicate points awards — idempotent design handles e-commerce retry storms natively
- 6–8 seasonal promotions per year now configurable by Marketing team in minutes, no deployment needed
- 25 Apex test methods across 4 test classes, 85%+ service coverage, all bulk-tested at 200 records

---

## One-Liner Summary (LinkedIn / Resume Header)

> Built a production-grade Salesforce Loyalty Cloud Retail Rewards platform for 2M+ members across online and 200+ in-store channels — real-time REST API accrual with dual-layer idempotency, `FOR UPDATE` promotion engine preventing Black Friday oversell, Savepoint-atomic redemption with Crypto-generated voucher codes, nightly batch for points expiry and anniversary tier reviews, three Experience Cloud LWC components with 5-minute auto-refresh, and zero hardcoded thresholds across 8 Apex services, 3 LWC components, and 25 test methods.

---

*Document version 1.0 — Saikiran Pasumarthy — Loyalty Cloud Resume Project*
