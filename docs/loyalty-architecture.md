# Salesforce Loyalty Cloud — Retail Rewards and Member Engagement Platform
# Architecture Decision Document

**Project:** Retail Loyalty Program — E-commerce and In-Store Rewards Platform
**Candidate:** Saikiran Pasumarthy
**Role Target:** Senior Salesforce Developer / Loyalty Cloud Architect / Industry Cloud Lead
**Sector:** Retail / Beauty / FMCG / E-commerce

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Loyalty Cloud Data Model Decisions](#3-loyalty-cloud-data-model-decisions)
4. [Points Calculation Strategy](#4-points-calculation-strategy)
5. [Promotion Engine Design](#5-promotion-engine-design)
6. [Scalability for 2 Million Members](#6-scalability-for-2-million-members)
7. [Integration Strategy](#7-integration-strategy)
8. [Security Model](#8-security-model)
9. [Deployment Notes](#9-deployment-notes)

---

## 1. Project Overview

### What the System Does

This system implements a production-grade retail loyalty program for a mid-to-large beauty brand with 2 million active members, 200+ physical retail locations, and an e-commerce platform. The program unifies points tracking, tier management, and reward redemption across all channels — online, in-store, and mobile app — replacing a fragmented legacy system (spreadsheets + a disconnected legacy database) that required manual intervention for every tier upgrade and had no real-time visibility for members.

**Core capabilities delivered:**

| Capability | Before | After |
|---|---|---|
| Points accrual | Batch job, 48-hour delay | Real-time REST API on purchase |
| Tier management | Manual monthly ops review | Automated on every transaction |
| Redemption | 3-minute manual voucher generation | Under 5 seconds, self-service |
| Member visibility | Call support line to check balance | Real-time Experience Cloud portal |
| Promotion configuration | Hard-coded per campaign | Rule-based engine, admin-configurable |

### Who Uses the System

- **Loyalty Members (2M)** — Experience Cloud portal + mobile app. See balance, redeem rewards, view transaction history, browse active promotions. No direct Salesforce access.
- **Store Associates (200+ locations)** — Salesforce UI. Record in-store purchases, process redemptions at POS, enroll new members.
- **Loyalty Program Manager** — Configures tier thresholds, promotion rules, reward catalog, expiry policies. All via Custom Metadata and Promotion__c records — no deployment required for configuration changes.
- **Marketing Team** — Runs segmented campaigns targeting specific tier groups and member cohorts via Data Cloud integration.
- **Operations Team** — Handles exceptions, manual point adjustments, fraud investigation using the immutable LoyaltyLedger audit trail.

### Why Salesforce Loyalty Cloud Over a Custom Solution

**What Loyalty Cloud provides out of the box that would require months to build from scratch:**

| Feature | Loyalty Cloud Standard | Custom Build Cost |
|---|---|---|
| LoyaltyProgram object | Program definition, currency name, expiry rules | 2–3 weeks to model and build |
| LoyaltyProgramMember | One record per Contact per program, tier, balance, member number | 2 weeks |
| LoyaltyMemberCurrency | Multi-currency points (base points, bonus points, partner points) | 3 weeks |
| LoyaltyLedger | Immutable transaction log with automatic running balance | 4 weeks (immutability alone is complex) |
| LoyaltyTier | Standard tier hierarchy, entry/retention criteria, benefits framework | 3 weeks |
| LoyaltyTransaction | Earn/burn transaction types, linked to ledger | 2 weeks |
| Built-in tier evaluation engine | Real-time tier recalculation on balance change | 6–8 weeks |
| Promotion framework | Standard promotion object with rules engine | 8–10 weeks |
| Experience Cloud templates | Pre-built loyalty portal templates | 4–6 weeks |
| **Total** | | **~30–40 weeks custom build** |

**Decision:** Loyalty Cloud provides the foundational data model and evaluation engine, allowing this project to focus on business-specific logic: the custom promotion engine, e-commerce integration, Experience Cloud portal, and the batch processing infrastructure for 2M-member scale. The standard objects are extended (not replaced) with custom fields and objects where the standard model has gaps.

---

## 2. Architecture Diagram

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                     LOYALTY CLOUD SYSTEM ARCHITECTURE                       ║
╚══════════════════════════════════════════════════════════════════════════════╝

┌─────────────────────────────────────────────────────────────────────────────┐
│  CHANNEL LAYER (Entry Points)                                               │
│                                                                             │
│  ┌──────────────────┐  ┌─────────────────────┐  ┌──────────────────────┐  │
│  │ E-Commerce Site  │  │  Mobile App         │  │  In-Store POS        │  │
│  │ (external)       │  │  (external)         │  │  (Store Associate    │  │
│  │                  │  │                     │  │   Salesforce UI)     │  │
│  └────────┬─────────┘  └──────────┬──────────┘  └──────────┬───────────┘  │
└───────────┼─────────────────────────┼────────────────────────┼─────────────┘
            │ REST POST                │ REST POST              │ UI Action
            │ /loyalty/transaction/    │ /loyalty/transaction/  │
            ▼                         ▼                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  API LAYER                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │  ECommerceIntegrationService (@RestResource)                          │ │
│  │  • Authenticates via Named Credential (RetailEcommerce_API)           │ │
│  │  • Identifies member by email or memberId                             │ │
│  │  • Idempotency check: ECommerce_Order_Id__c external ID               │ │
│  │  • Returns: pointsAwarded, newBalance, tierStatus, promotionApplied   │ │
│  └──────────────────────────────────┬────────────────────────────────────┘ │
└──────────────────────────────────────┼──────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  POINTS ACCRUAL LAYER                                                       │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │  PointsAccrualService                                                 │ │
│  │  • Duplicate check (ECommerce_Order_Id__c)                            │ │
│  │  • Base points = purchaseAmount × pointsPerDollar (CMDT)              │ │
│  │  • Calls PromotionEngineService.getApplicableMultiplier()             │ │
│  │  • Total points = base × multiplier                                   │ │
│  │  • Creates Loyalty_Transaction__c (earn type)                         │ │
│  │  • Updates LoyaltyMemberCurrency balance                              │ │
│  └──────────────────────────────────┬────────────────────────────────────┘ │
│                                     │                                       │
│                  ┌──────────────────┼──────────────────┐                   │
│                  ▼                  ▼                   ▼                   │
│  ┌─────────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ PromotionEngine     │  │ LoyaltyLedger    │  │ TierManagement       │  │
│  │ Service             │  │ (standard)       │  │ Service              │  │
│  │ • Active promos     │  │ • Immutable      │  │ • Eval after balance │  │
│  │ • Tier-eligible     │  │   audit log      │  │   change             │  │
│  │ • Max usage guard   │  │ • Every earn/    │  │ • Silver/Gold/       │  │
│  │ • FOR UPDATE lock   │  │   burn recorded  │  │   Platinum thresholds│  │
│  └─────────────────────┘  └──────────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  DATA LAYER (Salesforce Objects)                                            │
│                                                                             │
│  LoyaltyProgram ──────────── LoyaltyProgramMember ──────── Contact         │
│       │                            │         │                             │
│       │                   LoyaltyMemberCurrency   LoyaltyTier              │
│       │                            │                                       │
│  LoyaltyTier ────────── LoyaltyLedger (immutable)                          │
│                                    │                                       │
│                         Loyalty_Transaction__c                              │
│                         (extends standard with custom fields)               │
│                                    │                                       │
│              ┌─────────────────────┼──────────────────────┐                │
│              ▼                     ▼                       ▼                │
│          Promotion__c          Voucher__c           Tier_Change_Log__c      │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                         Platform Event: Member_Updated__e
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  PRESENTATION LAYER (Experience Cloud + LWC)                                │
│                                                                             │
│  ┌─────────────────────┐  ┌──────────────────────┐  ┌───────────────────┐ │
│  │  memberDashboard    │  │  pointsRedemption    │  │  promotionBanner  │ │
│  │  LWC                │  │  Wizard LWC          │  │  LWC              │ │
│  │  • Hero: tier+      │  │  • 4-step wizard     │  │  • Active promos  │ │
│  │    balance display  │  │  • Reward selection  │  │  • Auto-refresh   │ │
│  │  • Tier progress    │  │  • Points slider     │  │    every 5 min    │ │
│  │  • Recent txns      │  │  • Voucher display   │  │  • Mobile scroll  │ │
│  │  • Vouchers grid    │  │  • Rollback safety   │  │                   │ │
│  └─────────────────────┘  └──────────────────────┘  └───────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
┌─────────────────────────────────────────────────────────────────────────────┐
│  BATCH LAYER (Nightly Processing)                                           │
│                                                                             │
│  LoyaltyTransactionBatch (Scheduled, nightly)                               │
│  • Processes Pending Loyalty_Transaction__c records                         │
│  • Recalculates Annual_Points__c for tier anniversary review                │
│  • Expires points older than expiry months (CMDT-configurable)              │
│  • Chains next batch if more pending records remain                         │
│  • Logs to Batch_Run_Log__c; alerts ops if failure rate > 5%                │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Flow Sequences

**E-Commerce Purchase → Points Awarded:**
```
E-Commerce POST /loyalty/transaction/
  → ECommerceIntegrationService.createTransaction()
    → Idempotency check (ECommerce_Order_Id__c)
    → PointsAccrualService.accruePointsForPurchase()
      → PromotionEngineService.getApplicableMultiplier()
      → Loyalty_Transaction__c INSERT (earn type)
      → LoyaltyMemberCurrency UPDATE (balance++)
      → LoyaltyProgramMember trigger fires
        → TierManagementService.evaluateTierChange()
          → [if tier change] LoyaltyProgramMember UPDATE
          → Tier_Change_Log__c INSERT
          → Tier change email notification
  ← HTTP 200: { pointsAwarded, newBalance, tierStatus }
```

**Member Redemption (Experience Cloud):**
```
Member clicks Redeem in memberDashboard
  → pointsRedemptionWizard launches
    → Step 1: choose reward type
    → Step 2: select points amount (live preview)
    → Step 3: confirm
      → RedemptionService.processRedemption()
        → Savepoint created
        → RedemptionService.validateRedemption() [validates balance]
        → Loyalty_Transaction__c INSERT (redeem type, negative points)
        → LoyaltyMemberCurrency UPDATE (balance--)
        → Voucher__c INSERT (unique code via Crypto.generateAESKey)
        → TierManagementService.evaluateTierChange() [re-evaluate after deduction]
        → Voucher email sent
        → [on any failure] Database.rollback(sp)
    → Step 4: show voucher code + expiry
```

---

## 3. Loyalty Cloud Data Model Decisions

### Standard Loyalty Cloud Objects

#### LoyaltyProgram
**Role:** Master program definition. One record per loyalty scheme.
**Key fields:** `Name`, `CurrencyName` (e.g. "BeautyPoints"), `ExpiryStrategy`, `ExpiryPeriod`, `TierEvaluationFrequency`.
**Decision:** Using the standard object rather than a custom master object means all standard Loyalty Cloud UI, the tier evaluation engine, and the standard report types work without custom development. The program-level expiry rules are configured here once and enforced automatically.

#### LoyaltyProgramMember
**Role:** One record per Contact per program. The primary member record.
**Key fields:** `MembershipNumber`, `MemberStatus` (Active/Inactive), `MembershipStartDate`, `LoyaltyProgramName` (tier), `AssociatedContact`.
**Custom fields added:** `Annual_Points__c` (points earned in current anniversary year for tier requalification), `Tier_Downgrade_Warning__c` (flag set 30 days before downgrade), `Lifetime_Points__c` (never resets — for marketing segmentation), `Enrollment_Source__c` (Online/InStore/Referral).
**Decision:** Using standard LoyaltyProgramMember as the primary record means native Experience Cloud sharing rules (sharing set based on Contact lookup) work without custom Apex sharing. The member can see their own record in Experience Cloud simply by configuring the sharing set — no custom sharing code needed.

#### LoyaltyMemberCurrency
**Role:** Tracks points balance per currency type per member.
**Why separate from LoyaltyProgramMember:** A member may have multiple currency buckets — base points (earned on purchases), bonus points (earned from promotions), and partner points (earned from partner brand purchases). These may have different redemption rules (e.g., base points expire in 12 months; bonus points expire in 6 months). Storing them separately in LoyaltyMemberCurrency allows per-currency expiry rules and redemption restrictions without complex conditional logic on a single balance field.
**Custom fields:** `Currency_Type__c` (Base/Bonus/Partner), `Expiry_Date__c` (per-bucket expiry), `Is_Expired__c`.

#### LoyaltyLedger
**Role:** Immutable transaction log. Every earn and burn event creates a ledger entry. The balance on LoyaltyMemberCurrency is the running total derived from (and kept in sync with) the ledger.
**Why immutability matters:**
- **Audit trail:** The operations team can investigate any disputed balance by replaying ledger entries — there is never a mystery gap.
- **Fraud prevention:** If a member's points are fraudulently manipulated, the ledger entry always exists and cannot be deleted without a compensating transaction.
- **Regulatory compliance:** GDPR and retail financial regulations in most markets require auditable records of loyalty currency transactions.
- **Design rule enforced:** No Apex code ever updates a LoyaltyLedger record after insert. Corrections are made by inserting a compensating transaction (positive or negative), not by modifying the original entry.

#### LoyaltyTier
**Role:** Defines the tier hierarchy — Silver, Gold, Platinum.
**Key fields:** `TierName`, `TierSequence`, `MinimumPoints`, `MaximumPoints`, `RetentionPoints` (minimum annual points to retain the tier).
**Configuration decision:** Three tiers are sufficient for a beauty brand loyalty program. More tiers increase complexity of the tier evaluation logic and create customer confusion. Research (referenced in the architecture decision record) shows diminishing returns above 3–4 tiers for FMCG/beauty brands.
**Entry vs Retention:** A member earns Gold by accumulating 1,000 points (entry threshold). They retain Gold the following year by earning 800 annual points (retention threshold — slightly lower to prevent mass downgrades from loyal-but-slightly-less-active members).

### Custom Objects

#### Loyalty_Transaction__c
**Why custom rather than only using standard LoyaltyTransaction:**
The standard LoyaltyTransaction covers earn and burn events, but lacks fields needed for:
- E-commerce idempotency (`ECommerce_Order_Id__c` — external ID for replay prevention)
- Channel attribution (`Source_Channel__c` — Online/InStore/App — required for channel-specific promotion rules)
- Promotion tracking (`Promotion_Applied__c` lookup, `Bonus_Points_Awarded__c` — to separately report on base vs bonus points awarded)
- Batch processing state (`Status__c` — Pending/Processed/Failed — for the nightly batch)

**Key fields:**
- `LoyaltyProgramMember__c` (lookup)
- `Transaction_Type__c` (Earn/Redeem/Adjustment/Referral/Expiry)
- `Source_Channel__c` (Online/InStore/App)
- `ECommerce_Order_Id__c` (external ID — unique constraint enforces idempotency)
- `Purchase_Amount__c` (decimal — the dollar amount that triggered the transaction)
- `Base_Points__c`, `Bonus_Points_Awarded__c`, `Total_Points__c`
- `Promotion_Applied__c` (lookup to Promotion__c)
- `Status__c` (Pending/Processed/Failed — for batch tracking)
- `Processing_Notes__c` (error details for failed batch records)

#### Promotion__c
**Role:** Stores promotion rules for the campaign engine. Admins create and configure promotions here without code deployment.
**Key fields:**
- `Name` — human-readable campaign name (e.g., "Summer 2025 3x Beauty Points")
- `Start_Date__c`, `End_Date__c` — promotion validity window
- `Bonus_Multiplier__c` — decimal (e.g., 3.0 = triple points on qualifying purchases)
- `Eligible_Tier__c` — picklist: Silver/Gold/Platinum/All Tiers
- `Product_Category__c` — picklist: Foundation/Skincare/Fragrance/All Categories
- `Eligible_Channel__c` — picklist: Online/InStore/App/All Channels
- `Is_Active__c` — admin toggle to activate/deactivate without changing dates
- `Max_Uses__c` — maximum total redemptions of this promotion
- `Current_Uses__c` — atomic counter (maintained with FOR UPDATE lock in PromotionEngineService)
- `Is_Stackable__c` — whether this promotion stacks with other active promotions or is exclusive
- `Description__c`, `CTA_URL__c` — for the promotionBanner LWC display

#### Voucher__c
**Role:** Represents a discount voucher generated on redemption. Separate object from LoyaltyTransaction because:
- A voucher has its own lifecycle (Generated → Active → Redeemed/Expired)
- The POS system queries vouchers by redemption code at checkout — a direct lookup on Voucher__c is simpler and faster than searching through transaction records
- Vouchers may be resent, reprinted, or transferred (future) — managing this on a transaction record would be awkward

**Key fields:**
- `LoyaltyProgramMember__c` (lookup)
- `Reward_Type__c` (Discount/FreeProduct/PartnerReward)
- `Discount_Value__c` (dollar amount of discount)
- `Points_Cost__c` (points deducted to create this voucher)
- `Expiry_Date__c` (default: 90 days from generation, configurable in CMDT)
- `Status__c` (Generated/Active/Redeemed/Expired/Void)
- `Redemption_Code__c` (unique code, generated from Crypto.generateAESKey, masked in list views)
- `Redemption_Date__c`, `Redemption_Channel__c` (populated on use)
- `Redemption_Transaction__c` (lookup to the redemption Loyalty_Transaction__c)

#### Loyalty_Config__mdt (Custom Metadata)
**Why CMDT for all thresholds:** Any threshold stored in Apex code requires a deployment to change. Promotions and tier thresholds change seasonally. CMDT allows Loyalty Program Managers to update rules without a code deployment, without Sandbox → Production cycles, and without a developer involved.

**Records and fields:**
| CMDT Record | Key Fields |
|---|---|
| `Points_Config` | `Points_Per_Dollar__c` (e.g., 1.0), `Referral_Bonus_Points__c` (e.g., 200), `Min_Redemption_Points__c` (e.g., 500) |
| `Tier_Config` | `Silver_Threshold__c` (0), `Gold_Threshold__c` (1000), `Platinum_Threshold__c` (5000), `Gold_Retention__c` (800), `Platinum_Retention__c` (4000) |
| `Expiry_Config` | `Base_Points_Expiry_Months__c` (12), `Bonus_Points_Expiry_Months__c` (6), `Voucher_Expiry_Days__c` (90) |
| `Program_Config` | `Default_Program_Id__c` (Loyalty Program record ID), `Default_Tier__c` ('Silver'), `Ops_Alert_Email__c` (ops team email) |

---

## 4. Points Calculation Strategy

### Real-Time vs Batch Decision

The core design question: should every points accrual event be processed synchronously (while the customer waits) or asynchronously (in a nightly batch)?

**Decision matrix:**

| Transaction Type | Processing Mode | Reason |
|---|---|---|
| In-store purchase accrual | Real-time synchronous | Associate and member expect immediate confirmation |
| E-commerce purchase accrual | Real-time synchronous | E-commerce checkout waits for acknowledgment; points accrual should complete within the same API call to ensure the member sees updated balance immediately |
| Mobile app purchase | Real-time synchronous | Same as e-commerce |
| Tier evaluation | Real-time synchronous (after every transaction) | Tier status affects in-store experience immediately — a member who just hit Gold threshold should be able to show Gold benefits on the same visit |
| Points expiry | Nightly batch only | No customer impact until expiry actually occurs; running expiry checks synchronously on every transaction would add unnecessary query overhead |
| Bulk corrections / migration | Batch processing | High volume, no latency requirement |
| Annual tier review | Nightly batch only | Once-per-year anniversary reset; no real-time requirement |

### Why Not All Real-Time

At 2M members with 6–8 seasonal peak campaigns, concurrent transactions can spike to 5,000+ per minute during Black Friday. If tier evaluation were a complex multi-SOQL operation per transaction:

- **Governor limit risk:** Each synchronous transaction using 3–5 SOQL queries for tier evaluation means the Apex CPU limit (10,000ms) becomes a constraint under complex promotion rules
- **Callout timeout risk:** The e-commerce platform has a 5-second timeout for the REST API call — if tier evaluation adds 2–3 seconds, timeouts occur
- **Queueable offloading:** For transactions above $500 (rare, < 1% of volume), tier recalculation is offloaded to a Queueable to keep the synchronous path under 1 second

**Design boundary:** Tier evaluation is O(1) — a single comparison of `Points_Balance__c` against three CMDT thresholds. No SOQL in tier evaluation itself (thresholds from CMDT are cached). The only SOQL is the member record update. This keeps the synchronous path within governor limits at scale.

### Points Calculation Formula

```
Base Points = FLOOR(purchaseAmount × pointsPerDollar)
Multiplier  = PromotionEngineService.getApplicableMultiplier(memberId, amount, category, channel)
Bonus Points = FLOOR(Base Points × (Multiplier - 1.0))
Total Points = Base Points + Bonus Points

Where:
  pointsPerDollar = Loyalty_Config__mdt.Points_Config.Points_Per_Dollar__c (default: 1.0)
  Multiplier = 1.0 (no promotion) to 5.0 (5x seasonal campaign)
```

**Integer rounding:** `Math.floor()` always applied — members never receive fractional points. This prevents floating-point accumulation errors over millions of transactions that would create balance discrepancies between the stored balance and the sum of ledger entries.

---

## 5. Promotion Engine Design

### Promotion Evaluation Algorithm

On every accrual call, `PromotionEngineService.getApplicableMultiplier()` is called:

```
INPUT: memberId, purchaseAmount, productCategory, channel

1. Query member's current tier (from LoyaltyProgramMember — already loaded by caller)

2. Single SOQL: SELECT all active Promotion__c records where:
   - Is_Active__c = true
   - Start_Date__c <= TODAY <= End_Date__c
   - (Eligible_Tier__c = member's tier OR Eligible_Tier__c = 'All Tiers')
   - (Product_Category__c = productCategory OR Product_Category__c = null)
   - (Eligible_Channel__c = channel OR Eligible_Channel__c = 'All Channels')
   - Current_Uses__c < Max_Uses__c (or Max_Uses__c = 0 for unlimited)

3. Filter results for stacking logic:
   - Collect all stackable promotions
   - Identify if any exclusive (non-stackable) promotion applies
   - If exclusive promotion exists: apply highest exclusive multiplier only
   - If only stackable: apply additive multipliers (2x + 1.5x = 3.5x)
   - Return final multiplier (minimum 1.0)

4. Call incrementPromotionUsage() for each applied promotion
   (using FOR UPDATE SOQL to prevent race conditions)

OUTPUT: finalMultiplier (Decimal), appliedPromotionIds (List<Id>)
```

### Atomic Usage Counter (Race Condition Prevention)

The most common concurrency bug in promotion engines: two transactions both check `Current_Uses__c < Max_Uses__c`, both pass, both increment — resulting in one extra redemption beyond the cap.

**Solution: FOR UPDATE SOQL locking**

```apex
// In PromotionEngineService.incrementPromotionUsage()
List<Promotion__c> promos = [
    SELECT Id, Current_Uses__c, Max_Uses__c
    FROM   Promotion__c
    WHERE  Id IN :promotionIds
    FOR UPDATE  // locks these records for the duration of this transaction
];

for (Promotion__c p : promos) {
    if (p.Max_Uses__c > 0 && p.Current_Uses__c >= p.Max_Uses__c) {
        // Promotion now full — remove from applied list, fall back to next
        results.add(new PromotionResult(p.Id, false));
        continue;
    }
    p.Current_Uses__c++;
    results.add(new PromotionResult(p.Id, true));
}
Database.update(promos, false);
```

The `FOR UPDATE` clause locks the promotion records in the database transaction. Any concurrent Apex transaction trying to lock the same records will wait (up to 10 seconds) and then re-read the updated `Current_Uses__c`. This prevents overselling.

### Seasonal vs Always-On Promotions

| Type | Configuration | Example |
|---|---|---|
| Seasonal campaign | `Start_Date__c` and `End_Date__c` set, `Max_Uses__c = 0` (unlimited within window) | "3x Points on all skincare — December 1–31" |
| Limited run | `Start_Date__c` and `End_Date__c` set, `Max_Uses__c = 10000` | "First 10,000 members to purchase get 5x bonus" |
| Always-on tier benefit | No end date, `Is_Active__c = true` | "Gold members always earn 1.5x on fragrance" |
| Partner promotion | `Eligible_Channel__c = 'Partner'` | "3x points when purchasing via partner brand" |

---

## 6. Scalability for 2 Million Members

### LDV Strategy for Loyalty Transactions

**Volume calculation:**
```
2,000,000 members
× 10 average transactions/month
× 12 months
= 240,000,000 transaction records/year
```

At this volume, naive SOQL like `SELECT * FROM Loyalty_Transaction__c WHERE Member__c = :id` becomes a table scan and exceeds SOQL time limits.

**Mitigations implemented:**

1. **Date-range filtering on all queries:**
   All queries against Loyalty_Transaction__c include a `Transaction_Date__c >= :cutoffDate` filter. The cutoff is configurable in CMDT (default: rolling 12 months). This reduces the query set from 240M records to ~20M at any time.

2. **Indexed fields on Loyalty_Transaction__c:**
   `LoyaltyProgramMember__c` (relationship field — auto-indexed), `Transaction_Date__c` (custom index requested via Salesforce support for LDV orgs), `Status__c` (picklist — covered by SF internal SOQL optimization), `ECommerce_Order_Id__c` (external ID — auto-indexed).

3. **BigObject archiving (future):**
   Transactions older than 2 years are archived to a Loyalty_Transaction_Archive__bobj BigObject. BigObjects support unlimited scale and are append-only, making them appropriate for the immutable ledger pattern.

4. **Stored balance (denormalization):**
   `LoyaltyMemberCurrency.PointsBalance` is stored and maintained on every transaction, not calculated by summing ledger entries on each read. This is intentional denormalization — the cost of a SUM() query across 240M records per page load would be prohibitive. The tradeoff: the stored balance must be kept in sync with every earn/burn event. This is enforced by ensuring all points changes go through `PointsAccrualService` and `RedemptionService` — no direct balance updates from outside the service layer.

### Concurrent Peak Traffic (Black Friday)

During a 4-hour Black Friday window, transaction volume can spike to:
```
200,000 orders × 2M eligible members × 4 hours
= ~50,000 concurrent loyalty transactions/hour peak
```

**Handling strategy:**

1. **Platform Events buffer:** The REST API endpoint publishes a `Transaction_Request__e` Platform Event and returns HTTP 202 immediately. The e-commerce checkout flow is not blocked. A Platform Event trigger subscriber calls `PointsAccrualService` asynchronously.
   - **Trade-off:** Member's balance does not update in real-time during peak events. During the post-purchase experience (receipt page), the balance shown may be stale by 30–60 seconds. This is acceptable per business requirement — the member sees the updated balance on next page load after the event is processed.

2. **Batch fallback:** `LoyaltyTransactionBatch` processes any `Status__c = Pending` records that failed to process synchronously during the peak window.

3. **Governor limit headroom:** Each transaction uses at most 4 SOQL queries and 3 DML operations. At the 100 SOQL / 150 DML governor limits, a single Apex transaction can process up to 25 member transactions in a single execution context — the batch scope of 200 records is split into groups of 25 to stay within limits.

### Tier Evaluation at Scale

Tier evaluation fires on every LoyaltyProgramMember update where `Points_Balance__c` or `Annual_Points__c` changed. At 50,000 concurrent transactions:
- Each tier evaluation is O(1): compare `Points_Balance__c` against three CMDT constants
- No SOQL in the evaluation itself (CMDT accessed via `getInstance()`, which is not a SOQL query)
- One SOQL to fetch the current tier on the member record (already available in trigger context)
- Bulk evaluation: processes List<LoyaltyProgramMember> with one DML at the end — not per-record DML

---

## 7. Integration Strategy

### E-Commerce to Salesforce (Inbound)

**Endpoint:** `@RestResource(urlMapping='/loyalty/transaction/*')`
**Method:** `@HttpPost` `createTransaction()`
**Authentication:** Connected App OAuth 2.0 (client credentials flow) via Named Credential `RetailEcommerce_API`

**Idempotency design:**
The e-commerce platform may retry a failed API call if it receives a timeout or 5xx response. Without idempotency, this would create duplicate points awards for the same order.

**Solution:** `ECommerce_Order_Id__c` is an external ID field (unique constraint at the database level). On every accrual call:
1. Query: does a `Loyalty_Transaction__c` with this `ECommerce_Order_Id__c` already exist?
2. If yes: return the existing transaction result (same response as if it just processed)
3. If no: process normally and insert with the external ID

This guarantees: the e-commerce platform can safely retry up to 5 times — the member never gets double points, and the API always returns a valid response.

**Request / Response format:**
```json
// Request
{
  "memberId": "a0x000000000001",  // or omit and use email
  "memberEmail": "jane@example.com",
  "orderAmount": 125.00,
  "orderId": "ORD-2025-00847361",
  "productCategory": "Skincare",
  "channel": "Online"
}

// Success Response (HTTP 200)
{
  "success": true,
  "pointsAwarded": 375,
  "basePoints": 125,
  "bonusPoints": 250,
  "newBalance": 2875,
  "tierStatus": "Gold",
  "promotionApplied": "Summer 2025 3x Skincare"
}

// Error Response (HTTP 400)
{
  "success": false,
  "errorCode": "MEMBER_NOT_FOUND",
  "message": "No active loyalty member found for email: jane@example.com"
}
```

### Salesforce to External Systems (Outbound)

No outbound callouts in the core transaction flow (to avoid blocking synchronous processing). The `ECommerceCalloutMock.cls` is used only for testing the inbound integration handler's ability to respond correctly to various request scenarios.

Future: outbound callouts to the partner loyalty platform for points exchange would follow the same Queueable + Platform Event pattern used in the Consumer Goods Cloud ERP integration.

---

## 8. Security Model

### Object-Level Security

| Object | OWD | Notes |
|---|---|---|
| LoyaltyProgramMember | Private | Members see only their own record via Experience Cloud sharing set |
| Loyalty_Transaction__c | Private | Members see only their own transactions via sharing rule on Member lookup |
| Voucher__c | Private | Members see only their own vouchers; redemption code masked in list view |
| Promotion__c | Public Read Only | All members can see active promotions; only managers can edit |
| LoyaltyLedger | Private | Operations team only; not exposed to members in Experience Cloud |
| Tier_Change_Log__c | Private | Operations team only; used for audit and dispute resolution |

### Experience Cloud Member Access

Members access only their own data because:
- `LoyaltyProgramMember.AssociatedContact` is a lookup to the member's Contact record
- A **Sharing Set** grants Experience Cloud user access to `LoyaltyProgramMember` records where `AssociatedContact = $User.ContactId`
- Child records (Transactions, Vouchers) inherit access via **Sharing Rules** based on the parent Member relationship
- No guest user access — all Experience Cloud pages require authentication (Enhanced Sites setting)

### Store Associate Access

- Store Associates are internal Salesforce users assigned the "Retail Store Associate" profile
- They can see LoyaltyProgramMember records for members they are actively serving (manual sharing via `Share` button on the member record when a transaction is in progress)
- They cannot see other associates' redemption records (OWD Private enforces this)

### Loyalty Program Manager

- Assigned the "Loyalty Program Manager" permission set
- Modify All on: LoyaltyProgram, LoyaltyTier, Promotion__c, Loyalty_Config__mdt (Admin can edit CMDT records)
- Read All on: LoyaltyProgramMember, Loyalty_Transaction__c (for reporting)
- Delete restricted on: LoyaltyLedger (immutability enforced at profile level — no Delete permission)

### API Security

- The e-commerce REST endpoint is protected by OAuth 2.0 client credentials (Connected App `RetailEcommerce_Connected`)
- The `ECommerceIntegrationService` uses `with sharing` — even if the connected app authenticates as an admin, the sharing rules apply to the data queries
- All Apex uses `WITH USER_MODE` on SOQL queries to enforce FLS
- The `getMemberSummary` AuraEnabled method calls `Security.stripInaccessible(AccessType.READABLE, results)` before returning data to LWC

### Voucher Code Security

- Redemption codes generated using `EncodingUtil.base64Encode(Crypto.generateAESKey(128))` — 128-bit cryptographically random value
- Codes are truncated and formatted as `XXXX-XXXX-XXXX-XXXX` for usability
- The `Redemption_Code__c` field is configured with **Field-Level Security: Visible** only to the owning member (in Experience Cloud) and to Store Associates at POS
- Codes are never logged in debug logs or error messages

---

## 9. Deployment Notes

### Loyalty Management Permission Set License

Salesforce Loyalty Cloud requires the **Loyalty Management** PSL (Permission Set License) assigned to each user who needs to access Loyalty objects. This is not part of standard Sales Cloud or Service Cloud licensing.

**Deployment checklist:**
- [ ] Loyalty Management PSL purchased and assigned to internal user profiles
- [ ] "Loyalty Management" permission set assigned to Store Associates and Loyalty Managers
- [ ] Experience Cloud guest user has no Loyalty PSL — members access via standard Experience Cloud Community license (which inherits Loyalty data access via sharing, not PSL)

### Metadata Deployment via sf CLI

All Apex classes, triggers, LWC components, and Custom Metadata records deploy normally via SFDX source format:
```bash
sf project deploy start --source-dir loyalty-project/force-app --target-org <alias>
```

### Post-Deployment Manual Configuration

The following cannot be deployed via metadata and must be configured manually in the target org's UI:

| Configuration | Location in UI | Notes |
|---|---|---|
| LoyaltyProgram record | Loyalty Management app → Programs | Create the master program record |
| LoyaltyTier records | Loyalty Management app → Tiers | Create Silver, Gold, Platinum tiers |
| Loyalty_Config__mdt records | Setup → Custom Metadata → Loyalty Config | Deploy via metadata or create in UI |
| Experience Cloud site | Digital Experiences → Builder | Import template, configure pages |
| Experience Cloud sharing sets | Setup → Sites → Sharing Settings | Add sharing set for LoyaltyProgramMember |
| Named Credential (RetailEcommerce_API) | Setup → Named Credentials | Configure per target environment |
| Scheduled Apex (LoyaltyTransactionBatch) | Setup → Scheduled Jobs | Schedule for 2 AM nightly |
| Connected App (RetailEcommerce_Connected) | Setup → App Manager | Configure OAuth settings |

### Environment-Specific Notes

- **Scratch org:** Loyalty Cloud features require the `LoyaltyManagement` feature in `project-scratch-def.json`
- **Sandbox:** Request Loyalty Management PSL from Salesforce before testing
- **Production:** Deployment window should avoid peak transaction hours (avoid 6 PM–10 PM on weekdays)

---

*Document version 1.0 — Saikiran Pasumarthy — Consumer Loyalty Cloud Architecture*
