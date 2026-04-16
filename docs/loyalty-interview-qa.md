# Salesforce Loyalty Cloud — Interview Q&A Reference

**Candidate:** Saikiran Pasumarthy
**Project:** Retail Loyalty Program — E-commerce and In-Store Rewards Platform
**Role Target:** Senior Salesforce Developer / Loyalty Cloud Architect / Industry Cloud Lead

---

## Section 1: Advanced Architect-Level Questions

---

### Q1. Why use Salesforce Loyalty Cloud over building a custom loyalty solution on core Salesforce?

**Answer:**

Salesforce Loyalty Cloud provides a production-grade data model and evaluation engine that would take 30–40 developer-weeks to replicate from scratch. The decision comes down to three dimensions: time-to-market, correctness, and maintenance cost.

**What Loyalty Cloud gives you out of the box:**

| Capability | Loyalty Cloud | Custom Build |
|---|---|---|
| Immutable ledger (LoyaltyLedger) | Standard object | 4–6 weeks to build correctly |
| Multi-currency points | LoyaltyMemberCurrency (standard) | 3 weeks |
| Tier evaluation engine | Built into standard processing | 6–8 weeks |
| Promotion framework | Standard Promotion objects | 8–10 weeks |
| Experience Cloud loyalty templates | Pre-built, configurable | 4–6 weeks |
| Standard reports and dashboards | Out of the box | 3 weeks |

**The deeper reason is correctness.** The LoyaltyLedger immutability pattern — where every earn and burn creates a new ledger entry rather than updating a balance field — is architecturally difficult to enforce on a custom object. A developer can always accidentally update a record. The standard Loyalty Cloud objects have platform-enforced constraints that a custom model cannot easily replicate.

**When would I choose a custom solution?** Only if the client had requirements that cannot be modelled in Loyalty Cloud — for example, a multi-level network rewards program (MLM-style) with complex downline calculations, or a non-Salesforce platform where deploying a full Salesforce org is not justifiable. For a mainstream retail/e-commerce/FMCG loyalty program, Loyalty Cloud is almost always the right choice.

**In this project specifically:** The standard Loyalty Cloud data model covered 70% of requirements. The remaining 30% — the custom promotion engine (`Promotion__c`), e-commerce REST integration, route-based voucher (`Voucher__c`), and batch processing infrastructure — were built as extensions, not replacements. This is the correct pattern: extend standard where needed, do not replace it.

---

### Q2. How do you design a points ledger system that is immutable and auditable?

**Answer:**

The core design principle is: **every change to a member's points balance creates a new record — never updates an existing one.**

**Implementation in this project:**

1. **LoyaltyLedger (standard) is append-only.** Every `accruePointsForPurchase` call creates a new `Loyalty_Transaction__c` record. We never update `Total_Points__c` on an existing transaction. Corrections are made by inserting a compensating transaction (e.g., `-200` points to reverse an incorrect `+200` award).

2. **Stored balance on LoyaltyMemberCurrency.** The running balance is stored denormalized on `LoyaltyMemberCurrency.Points_Balance__c`. This is updated on every earn/burn event. The stored balance must always equal the sum of all transaction `Total_Points__c` for that member. We enforce this by ensuring all balance changes go exclusively through `PointsAccrualService` and `RedemptionService` — no direct field updates from triggers or other services.

3. **Profile-level delete restriction on LoyaltyLedger.** The "Loyalty Program Member" and "Store Associate" profiles have no Delete permission on `Loyalty_Transaction__c`. Only System Administrators can delete, and only after an explicit approval process.

4. **Audit trail for disputes.** When the Operations team investigates a disputed balance, they query `Loyalty_Transaction__c WHERE Loyalty_Program_Member__c = :memberId ORDER BY Transaction_Date__c ASC`. The sum of all `Total_Points__c` values must equal the current `Points_Balance__c`. If it does not, a data integrity issue exists — this discrepancy is itself evidence for investigation.

5. **External ID idempotency guard.** `ECommerce_Order_Id__c` is a unique external ID. If the e-commerce platform retries and creates a duplicate transaction, the database-level unique constraint prevents the insert. The `accruePointsForPurchase` method explicitly checks for existing records with the same external ID and returns the existing result rather than creating a duplicate.

**Interview follow-up: "What if an admin accidentally sets Points_Balance__c to 0 on a member record?"**
This is why the stored balance and the ledger sum must match. After any such incident, the balance can be recalculated by summing `Loyalty_Transaction__c.Total_Points__c` for that member — the ledger is the source of truth, not the denormalized balance field.

---

### Q3. How do you handle concurrent redemptions to prevent a member from redeeming more points than their balance?

**Answer:**

This is a classic TOCTOU (time-of-check-time-of-use) race condition problem. Two concurrent requests both check the balance, both see sufficient points, and both attempt to redeem.

**Three-layer defence in this implementation:**

**Layer 1 — Validation before DML (`validateRedemption`).**
The `validateRedemption` method runs a `SELECT Points_Balance__c FROM LoyaltyProgramMember__c WHERE Id = :memberId` before any DML. This is the first check, but it does not prevent concurrency issues on its own.

**Layer 2 — Pending redemption guard.**
Before processing, the service queries:
```apex
SELECT COUNT() FROM Loyalty_Transaction__c
WHERE Loyalty_Program_Member__c = :memberId
AND   Transaction_Type__c = 'Redeem'
AND   Status__c = 'Pending'
```
If a redemption is already in progress for this member, the second request is rejected immediately. This prevents the same member from submitting two concurrent redemptions from two browser tabs or devices.

**Layer 3 — Savepoint + atomic DML.**
`RedemptionService.processRedemption` creates a `Database.Savepoint` at the start. All three operations — insert transaction, update member balance, insert voucher — execute within a single Apex transaction. If any step fails (e.g., the member balance update fails because another transaction already deducted the points), the savepoint rolls back all changes. No partial state is committed.

**Layer 4 — FOR UPDATE on promotion records.**
For the promotion usage counter (`Current_Uses__c`), `PromotionEngineService.incrementPromotionUsage` uses `FOR UPDATE` SOQL:
```apex
List<Promotion__c> promos = [SELECT Id, Current_Uses__c FROM Promotion__c
                              WHERE Id IN :promotionIds FOR UPDATE];
```
This locks the promotion records for the duration of the transaction. Any concurrent transaction attempting to claim the same promotion slot waits (up to 10 seconds) and then re-reads the updated counter, preventing overselling.

**What this design does NOT protect against:** If two requests arrive in the exact same millisecond and both pass the `SELECT Points_Balance__c` check before either has committed its deduction, Layer 3 (atomic DML) is the final guard — the second transaction's member update will fail if the first already set the balance to 0, triggering the rollback.

**In a high-scale scenario (Black Friday):** The combination of the pending redemption guard + atomic DML + Experience Cloud's UI debouncing (Confirm button disabled during processing) makes double-redemption practically impossible.

---

### Q4. What is your strategy for managing 20 million loyalty transactions per year without hitting LDV governor limits?

**Answer:**

At 2M members × ~10 transactions/month × 12 months = 240M records/year, this is a genuine Large Data Volume (LDV) scenario. The strategy has four components:

**1. Date-range filtering on all queries.**
Every query against `Loyalty_Transaction__c` includes a `Transaction_Date__c >= :cutoffDate` filter. The cutoff is configurable in `Loyalty_Config__mdt` (default: rolling 12 months). This reduces the effective query set from 240M records to ~20M at any point in time. In Apex:
```apex
Date cutoffDate = Date.today().addMonths(-expiryMonths);
[SELECT ... FROM Loyalty_Transaction__c WHERE Transaction_Date__c >= :cutoffDate ...]
```

**2. Indexed fields.**
- `Loyalty_Program_Member__c` — relationship field, auto-indexed
- `Transaction_Date__c` — custom index requested via Salesforce support for LDV orgs
- `ECommerce_Order_Id__c` — external ID, auto-indexed (critical for idempotency check performance)
- `Status__c` — picklist with low cardinality; the batch query `WHERE Status__c = 'Pending'` is an index scan, not a table scan, because it is used in conjunction with the date filter

**3. Stored balance (deliberate denormalization).**
`LoyaltyMemberCurrency.Points_Balance__c` is maintained on every earn/burn event rather than calculated by `SUM(Total_Points__c)` on demand. A `SUM()` across 20M member transactions per page load would time out. The stored balance is the correct choice here. The trade-off — the balance can become inconsistent if code bypasses the service layer — is managed by restricting all balance updates to `PointsAccrualService` and `RedemptionService`.

**4. BigObject archiving for records older than 2 years.**
Transactions older than 2 years are archived to a `Loyalty_Transaction_Archive__bobj` BigObject. BigObjects are append-only (no updates, no deletes), have no governor limits on storage, and support async SOQL via `database.queryWithBinds`. This keeps the primary `Loyalty_Transaction__c` table bounded. The nightly batch explicitly creates offsetting expiry transactions (negative points) before archiving, ensuring the ledger remains in balance even after archiving.

**5. Batch scope sizing.**
`LoyaltyTransactionBatch` processes 200 records per chunk. Each chunk uses at most 4 SOQL queries and 3 DML operations, well within the 100 SOQL / 150 DML governor limits. The batch is `Database.Stateful` to accumulate counts across chunks for the `finish()` method's reporting without re-querying.

---

### Q5. How do you design a promotion engine that supports complex stacking rules (some promotions stackable, some exclusive)?

**Answer:**

The `PromotionEngineService.getApplicableMultiplier` method implements a two-class stacking model:

**Exclusive promotions:** `Is_Stackable__c = false`. Only one exclusive promotion applies — the one with the highest `Bonus_Multiplier__c`. All other exclusive promotions on the same transaction are ignored.

**Stackable promotions:** `Is_Stackable__c = true`. Multiple stackable promotions combine additively:
```
Final multiplier = 1.0 + Σ(each stackable multiplier - 1.0)
```
For example: 2x stackable + 1.5x stackable = 1.0 + (2.0-1.0) + (1.5-1.0) = 2.5x total.

**Exclusive overrides stackable:** If any exclusive promotion applies, all stackable promotions are ignored and only the best exclusive multiplier is used. This prevents a seasonal 5x campaign from stacking with an always-on 1.5x tier benefit to produce 6.5x, which would be unintended.

**Single SOQL approach:**
```apex
List<Promotion__c> candidates = [
    SELECT Id, Name, Bonus_Multiplier__c, Is_Stackable__c, ...
    FROM   Promotion__c
    WHERE  Is_Active__c = true
      AND  Start_Date__c <= :today
      AND  End_Date__c   >= :today
    WITH   USER_MODE
];
// In-Apex filtering for tier, category, channel, usage cap
```
All filtering except date and active flag is done in Apex (not SOQL) to avoid dynamic SOQL and keep the query predictable. The date-based filter is sufficient to keep the result set manageable — there are rarely more than 20–30 active promotions at any given time.

**Atomic usage counter:**
`incrementPromotionUsage` uses `FOR UPDATE` to lock the promotion records and re-check `Current_Uses__c < Max_Uses__c` after locking, preventing race conditions when multiple concurrent transactions compete for the last available promotion slot.

**Configuration without deployment:**
New promotions are created as `Promotion__c` records by the Marketing team — no Apex deployment needed. The engine automatically discovers them via the SOQL query. Tier eligibility, category restrictions, channel restrictions, and stacking rules are all field values on the promotion record.

---

### Q6. How do you ensure idempotency when an e-commerce platform retries a failed points accrual API call?

**Answer:**

The idempotency design has two layers: application-level and database-level.

**Application-level check (fast path):**
`PointsAccrualService.accruePointsForPurchase` accepts an `externalOrderId` parameter. Before any points calculation or DML, it queries:
```apex
List<Loyalty_Transaction__c> existing = [
    SELECT Id, Total_Points__c, Base_Points__c, Bonus_Points_Awarded__c,
           Loyalty_Program_Member__r.Points_Balance__c
    FROM   Loyalty_Transaction__c
    WHERE  ECommerce_Order_Id__c = :externalOrderId
    WITH   USER_MODE
    LIMIT  1
];
if (!existing.isEmpty()) {
    // Return the existing transaction result — no new DML
    return buildResultFromExisting(existing[0]);
}
```
The first retry check is in Apex. If the record already exists, the method returns the same response as if it just processed — `{ success: true, pointsAwarded: X, newBalance: Y }`. The e-commerce platform receives an identical response and can proceed normally.

**Database-level constraint (safety net):**
`ECommerce_Order_Id__c` is a unique external ID field on `Loyalty_Transaction__c`. Even if two concurrent requests somehow both pass the application-level check simultaneously (before either commits), the database-level unique constraint rejects the second insert with a duplicate value error. The `Database.insert(txn, false)` call returns a `SaveResult` with `isSuccess = false`, which the method handles by returning a failure response. The e-commerce platform retries once more, and this time the application-level check finds the record inserted by the first request.

**Why both layers are needed:**
- The application-level check handles the common case (sequential retries) efficiently — no DML, just a SOQL and a return.
- The database-level constraint handles the race condition case (near-simultaneous retries) correctly — the database enforces uniqueness even when Apex cannot.

**Response contract with e-commerce:**
The REST endpoint always returns HTTP 200 for idempotent duplicates (not 409 Conflict). The response body includes `{ "message": "Duplicate order — returning existing transaction." }` which the e-commerce platform can log. The member never sees this message; it's for the integration team's operational visibility.

---

### Q7. How do you handle tier downgrade communication sensitively without damaging customer loyalty?

**Answer:**

This is a CX (customer experience) problem as much as a technical one. The design addresses it at three levels:

**1. 30-day advance warning (Tier_Downgrade_Warning__c flag).**
During the nightly `LoyaltyTransactionBatch`, members approaching their anniversary date with annual points below the retention threshold have a `Tier_Downgrade_Warning__c` flag set on their `LoyaltyProgramMember__c` record 30 days before the anniversary. This flag triggers:
- A "We miss you!" email campaign (configured in Marketing Cloud) offering a double-points promotion for the next 30 days
- A banner in the Experience Cloud portal: "You need X more points by [date] to retain your Gold status"

**2. Tone in tier change notifications.**
The `sendTierChangeNotifications` method in `TierManagementService` uses different subject lines for upgrades vs downgrades:
- Upgrade: *"Congratulations! You've been upgraded to Gold!"*
- Downgrade: *"Your loyalty tier has been updated to Silver"* (neutral, not apologetic, not shaming)

The downgrade email body acknowledges the member's loyalty ("Thank you for being a valued member"), explains that their annual activity determines tier status, and highlights what they can do to re-qualify — rather than framing it as a loss.

**3. Grandfathering period for edge cases.**
For members who are just below threshold (e.g., 795 annual points against an 800 Gold retention), the `Loyalty_Config__mdt.Gold_Retention__c` field allows the Program Manager to temporarily lower the threshold during difficult periods (e.g., a pandemic year where shopping volumes dropped) without a code deployment. This is a business continuity provision, not a technical override.

**Trade-off acknowledged:**
Some loyalty programs choose never to downgrade tiers — instead letting members "age down" gradually. This design opts for active annual re-evaluation because the business requirement was that tier status accurately reflects current-year engagement, not historical. The 30-day warning mechanism mitigates the customer experience impact.

---

### Q8. What is the difference between LoyaltyLedger and LoyaltyTransaction in the standard Loyalty Cloud data model?

**Answer:**

This is a commonly confused pair and a strong indicator of genuine Loyalty Cloud experience.

| | LoyaltyLedger | LoyaltyTransaction |
|---|---|---|
| **Purpose** | Immutable, low-level audit record — one record per points movement | Business-level event — one record per customer interaction (purchase, redemption, referral) |
| **Created by** | Loyalty Cloud engine automatically on every earn/burn | Your Apex code (or the standard engine) |
| **Mutability** | Never updated after creation — true ledger semantics | Can be updated (e.g., Status__c from Pending → Processed) |
| **Relationship** | One LoyaltyTransaction can result in multiple LoyaltyLedger entries (e.g., base points + bonus points as separate ledger rows) | One LoyaltyTransaction per customer event |
| **Audience** | Internal audit / finance / operations | Member-facing (what appears on "your points history") |
| **Queryable by member** | No (OWD Private, ops team only) | Yes (via Experience Cloud sharing) |

**In this project's implementation:**
Because the org is a standard Salesforce org without the Loyalty Management package deployed in the scratch org setup, `Loyalty_Transaction__c` serves as the combined transaction+ledger object. In a production Loyalty Cloud org, the standard `LoyaltyLedger` would be the append-only record created by the Salesforce engine, and `LoyaltyTransaction` would be the higher-level event. The custom `Loyalty_Transaction__c` models the business transaction layer, with the `LoyaltyLedger` standard object implicitly created by the platform on every balance change.

**Why the distinction matters for architecture:**
If you write code that updates `LoyaltyLedger` records (which you should never do), you break the audit trail. The correct correction pattern is always: insert a new compensating transaction, never edit the ledger.

---

### Q9. How do you integrate Loyalty Cloud with Data Cloud for real-time member segmentation?

**Answer:**

The integration serves two use cases: **inbound** (Data Cloud enriching Loyalty member profiles) and **outbound** (Loyalty data feeding Data Cloud for segmentation).

**Outbound — Loyalty to Data Cloud:**
`LoyaltyProgramMember__c`, `Loyalty_Transaction__c`, and `Voucher__c` records stream to Data Cloud via the **Salesforce CRM connector** (zero-ETL). This gives Data Cloud access to:
- Member tier, lifetime points, annual points
- Transaction history by channel (Online/InStore/App)
- Voucher redemption patterns

In Data Cloud, these are unified into a **Customer 360 Profile** alongside e-commerce browsing data, email engagement data from Marketing Cloud, and in-store POS data. A Data Cloud **Calculated Insight** computes:
```sql
SELECT member_id,
       SUM(total_points) as ltv_points,
       COUNT(DISTINCT transaction_date) as purchase_frequency,
       AVG(purchase_amount) as avg_basket_size
FROM loyalty_transactions
GROUP BY member_id
```

**Inbound — Data Cloud to Loyalty:**
Segments defined in Data Cloud ("Gold members who haven't transacted in 60 days", "High-LTV Platinum members about to expire") are activated back into Salesforce as `LoyaltyProgramMember__c` field updates or Campaign membership records. The Marketing team then configures targeted promotions in `Promotion__c` that only activate for the segment.

**Real-time path (future state):**
For real-time "next best offer" at checkout (e.g., the POS system asking "what promotion should I show this member?"), a Data Cloud **Streaming Insight** scores the member on purchase probability and passes the score back via the `getActiveMemberPromotions` endpoint. The `promotionBanner` LWC then surfaces the most relevant promotion for that specific member at that moment.

**What's different with Loyalty Cloud specifically:**
The `LoyaltyProgramMember` standard object maps directly to the Data Cloud `Individual` and `Loyalty Profile` data model entities. Standard Loyalty Cloud orgs with Data Cloud can use the pre-built Loyalty Cloud data stream templates rather than building a custom connector.

---

### Q10. How do you test a points accrual engine for correctness when promotion rules change frequently?

**Answer:**

Frequently-changing rules are the enemy of brittle tests. The testing strategy has three layers:

**Layer 1 — Isolated unit tests with explicit promotion setup.**
Each test that involves a promotion creates its own `Promotion__c` record with known values, rather than relying on any pre-deployed promotion data. This makes tests hermetic — they pass or fail based on the code logic, not on what promotions happen to be active in the org.

Example from `PointsAccrualServiceTest`:
```apex
Promotion__c promo = new Promotion__c(
    Bonus_Multiplier__c  = 3.0,
    Eligible_Tier__c     = 'All Tiers',
    Is_Active__c         = true,
    Start_Date__c        = Date.today().addDays(-1),
    End_Date__c          = Date.today().addDays(30)
    ...
);
insert promo;
// Now call accruePointsForPurchase — the engine will find this promotion
```

**Layer 2 — Boundary tests at tier thresholds.**
The `TierManagementServiceTest` tests at exactly the threshold values: `999 → 1000` for Gold upgrade, `4999 → 5000` for Platinum upgrade. These catch off-by-one errors that are common when thresholds change.

**Layer 3 — Bulk correctness test.**
`testAccruePoints_bulk200Transactions` verifies that the final member balance equals the expected accumulated total across 200 transactions. This catches accumulation bugs — where individual calculations are correct but floating-point drift or integer truncation errors compound over many transactions.

**Layer 4 — CMDT fallback testing.**
Since `Loyalty_Config__mdt` records are not deployed in test context, all service classes have `@TestVisible static final` fallback constants. Tests assert against these constants, and the constants are also what `getInstance()` returns when CMDT is absent. This ensures tests accurately model production behavior.

**For promotion rule changes specifically:**
Because promotions are `Promotion__c` data records (not code), a rule change doesn't require a test suite update — it requires a new test record in the existing test. The promotion engine code doesn't change; only the data changes. Tests for the engine's logic remain valid; tests for specific promotion outcomes would be updated in the test class by changing the `Bonus_Multiplier__c` value. This is the correct trade-off between test maintainability and correctness confidence.

---

## Section 2: Scenario Questions

---

### Scenario 1: A beauty brand wants to launch a loyalty program that works across their website, mobile app, and 200 physical stores simultaneously — design the complete system architecture.

**Approach:**

**Phase 1 — Data model (Week 1–2):**
- `LoyaltyProgram` — one record, "BeautyRewards"
- `LoyaltyProgramMember` — one per Contact, all channels share the same member record
- `LoyaltyMemberCurrency` — separate Base and Bonus currency buckets
- `Loyalty_Transaction__c` — with `Source_Channel__c` (Online/InStore/App) for attribution
- `ECommerce_Order_Id__c` external ID on transactions for idempotency

**Phase 2 — Channel integrations:**
- **Online (REST API):** `@RestResource` endpoint at `/loyalty/transaction/`. E-commerce platform POSTs order details; response within 2 seconds. Idempotency via external ID. Named Credential `RetailEcommerce_API` for auth.
- **Mobile app:** Same REST endpoint. Channel = 'App'. Mobile client uses the same Connected App OAuth credentials as the web platform.
- **In-store (200 locations):** Store Associates use Salesforce app UI. Quick Action on `LoyaltyProgramMember__c` launches an Apex action that calls `PointsAccrualService.accruePointsForPurchase`. POS integration (future) would use the same REST endpoint with channel = 'InStore'.

**Phase 3 — Member experience:**
- Experience Cloud portal for online members: `memberDashboard` LWC, `pointsRedemptionWizard`, `promotionBanner`
- Mobile app uses the same Apex REST endpoints as the portal (headless mode)
- In-store: Store Associates can look up member by phone number or member number; balance visible on the member record page

**Phase 4 — Batch infrastructure:**
- `LoyaltyTransactionBatch` scheduled nightly at 2 AM: process any Pending transactions, expire aged points, run anniversary tier reviews
- Points expiry emails sent via batch (not real-time) — no customer impact until expiry

**Key architectural decision — unified member identity:**
The member's `LoyaltyProgramMember__c` is a single record regardless of channel. An in-store purchase and an online purchase both update the same `Points_Balance__c`. The channel is recorded on the transaction (`Source_Channel__c`) for analytics, but the member's identity is channel-agnostic. This prevents the most common loyalty program failure: members having separate point pools for online vs in-store.

**Trade-off disclosed:**
Real-time in-store sync depends on the POS system having reliable internet connectivity. For stores with intermittent connectivity, a local queue (POS-side) with retry on reconnect would be needed. This project assumes reliable connectivity; the idempotency design handles the retry scenario correctly even if a transaction is submitted multiple times due to connectivity issues.

---

### Scenario 2: During a Black Friday promotion, 50,000 members try to redeem points simultaneously — how does your design handle this without data corruption or overselling vouchers?

**Approach:**

**The problem has three distinct failure modes:**

1. **Double-redemption:** Same member redeems twice, getting more points deducted than they have, or receiving two vouchers for one set of points.
2. **Promotion overselling:** A limited-run promotion (e.g., "First 1,000 members get 5x bonus") is claimed by 1,100 members.
3. **Performance degradation:** 50,000 concurrent API calls overwhelm the Apex processing tier.

**How each is handled:**

**Double-redemption (per member):**
- Pending redemption guard: only one in-progress redemption per member at a time
- UI: Confirm button disabled immediately on click, re-enabled only on result
- Savepoint: atomic DML means no partial state if the second step fails
- Even if two requests somehow race: the second member balance update will fail (balance already deducted), triggering the Savepoint rollback

**Promotion overselling (global cap):**
- `FOR UPDATE` SOQL on `Promotion__c` locks the record for the duration of the transaction
- After locking, `Current_Uses__c` is re-read — if now at cap, the promotion is not applied
- The platform enforces this at the database row level, not in application code
- Result: exactly `Max_Uses__c` members benefit from a limited promotion, never more

**Performance at 50,000 concurrent:**
- **Platform Events buffer:** The REST endpoint publishes a `Transaction_Request__e` event and returns HTTP 202 immediately. Points processing happens asynchronously in a Platform Event trigger. This decouples the e-commerce checkout response time from points processing time.
- **`LoyaltyTransactionBatch` fallback:** Any transactions that fail the async path are picked up as `Status__c = 'Pending'` by the nightly batch.
- **Experience Cloud self-service redemptions:** These go through the Apex redemption path directly (not buffered). Salesforce Experience Cloud's session-based rate limiting (default: 50 API calls per minute per session) naturally throttles individual members.
- **Trade-off communicated:** Members may see a 30–60 second delay in their balance updating during the peak window. This is communicated via the Experience Cloud UI ("Your points are being processed") rather than showing an error.

**What I would NOT do:** Implement a pessimistic global lock on the member table during Black Friday. This would serialize all transactions and create a single point of failure. The per-member Pending guard + per-promotion FOR UPDATE lock is surgical rather than global.

---

### Scenario 3: A member calls support claiming their points were incorrectly deducted — walk through how you would investigate and correct the issue using the immutable ledger design.

**Investigation workflow:**

**Step 1 — Pull the member's full ledger (2 minutes).**
```sql
SELECT Transaction_Date__c, Transaction_Type__c, Total_Points__c,
       Description__c, Source_Channel__c, ECommerce_Order_Id__c,
       Status__c
FROM   Loyalty_Transaction__c
WHERE  Loyalty_Program_Member__c = '[member ID]'
ORDER BY Transaction_Date__c DESC
```
This gives the Operations team every earn, burn, referral, and expiry event in reverse chronological order. The total sum of `Total_Points__c` should equal the current `Points_Balance__c`. If it does not, a data integrity issue exists independently of the member's complaint.

**Step 2 — Identify the disputed transaction.**
The member says "I had 2,000 points on Monday, now I have 500." Find all redemption (`Transaction_Type__c = 'Redeem'`) and expiry (`Transaction_Type__c = 'Expiry'`) transactions between Monday and today. If a 1,500-point redemption exists that the member did not initiate, that is the disputed event.

**Step 3 — Verify the evidence.**
Check the `Voucher__c` record linked to the redemption transaction:
- Is `Status__c = 'Redeemed'`? If yes, was it redeemed at a store or online?
- Check `Redemption_Channel__c` and `Redemption_Date__c`
- If the voucher was redeemed in-store, check CCTV or POS receipt for that store on that date
- If the voucher was redeemed online, check the e-commerce platform's order records for that voucher code

**Step 4 — Correction via compensating transaction.**
If the deduction is confirmed to be fraudulent or erroneous, the Operations Manager:
1. Voids the voucher: `Voucher__c.Status__c = 'Void'`
2. Creates a compensating `Loyalty_Transaction__c` (Transaction_Type__c = 'Adjustment', Total_Points__c = +1500, Description__c = 'Manual correction — fraudulent redemption ref: [case number]')
3. Updates `LoyaltyMemberCurrency.Points_Balance__c` by +1500
4. Creates a `Tier_Change_Log__c` if the correction changes the member's tier

**What is never done:** The original redemption transaction is never deleted or modified. The ledger is immutable. The correction is always additive — a new positive transaction that reverses the effect. This preserves the full audit trail for any future investigation or regulatory review.

**Fraud pattern detection (future):**
If this scenario occurs for multiple members, the `ECommerce_Order_Id__c` and `Redemption_Code__c` patterns can be analysed across transactions to identify a compromised redemption code or a fraudulent Store Associate account.

---

## Section 3: Quick Answer Reference

*(20 crisp 1–2 line answers for first-round interviews)*

---

**1. LoyaltyLedger vs LoyaltyTransaction?**
LoyaltyLedger is the immutable, low-level platform audit record — never updated after creation. LoyaltyTransaction is the business-level event record that may be updated (e.g., Status changes) and is visible to members.

**2. How often should tier evaluation run?**
Real-time on every `Points_Balance__c` change — tier status affects the in-store experience immediately. Points expiry and annual tier requalification run nightly in batch (no real-time requirement).

**3. How do you design points expiry?**
Nightly batch queries `Loyalty_Member_Currency__c` records where `Expiry_Date__c <= today`. Creates offsetting negative `Loyalty_Transaction__c` records (not deletes), sets `Points_Balance__c = 0`, marks `Is_Expired__c = true`. Always compensating transactions, never deletes.

**4. How do you prevent two stackable promotions from being applied when the business wants exclusivity?**
Set `Is_Stackable__c = false` on the campaign. `PromotionEngineService` checks this flag and applies only the best exclusive promotion when `Is_Stackable__c = false` promotions exist, ignoring all stackable promotions for that transaction.

**5. Why real-time accrual for purchases but batch for expiry?**
Purchases affect the member's current-session experience (they expect to see points immediately). Expiry only affects balance at a future date — running it synchronously on every transaction would add unnecessary SOQL overhead and risk CPU limit violations at peak volume.

**6. How does Experience Cloud member access work without custom Apex sharing?**
A Sharing Set on `LoyaltyProgramMember__c` grants Experience Cloud user access to the record where `AssociatedContact = $User.ContactId`. Child records (Transactions, Vouchers) inherit access via Sharing Rules. No custom Apex sharing code needed.

**7. How do you ensure idempotency in the REST integration?**
Two layers: application-level check for existing `ECommerce_Order_Id__c` before any DML (returns existing result); database-level unique constraint on `ECommerce_Order_Id__c` as safety net for race conditions.

**8. How do you test Loyalty Cloud components?**
`@testSetup` creates the full member/currency/tier data once; tests use `Database.SaveResult` for DML validation; CMDT fallback constants (`@TestVisible static final`) used when CMDT records are not deployed; bulk tested at 200 records; `Database.Savepoint` tested by verifying no records created after failed redemption.

**9. How does Data Cloud integration work with Loyalty?**
Salesforce CRM connector streams `LoyaltyProgramMember__c` and `Loyalty_Transaction__c` to Data Cloud zero-ETL. Data Cloud computes Calculated Insights (LTV, frequency). Segments activate back to Salesforce as campaign membership or field updates, driving targeted `Promotion__c` records.

**10. Why Custom Metadata for loyalty configuration?**
Tier thresholds, points-per-dollar, expiry periods, and minimum redemption values change seasonally. CMDT allows Loyalty Program Managers to update these without code deployment or Sandbox → Production cycles. Fallback constants in Apex handle test context where CMDT records are not deployed.

**11. How do you detect loyalty fraud?**
Query for: multiple redemptions from different members using the same `Redemption_Code__c` in a short window; `Loyalty_Transaction__c` records created outside business hours; member balance that does not equal the sum of their ledger entries; excessive referral bonus claims from a single referrer. Flag these as cases for the Operations team.

**12. How do you design a referral program without abuse?**
Three guards: self-referral check (`referrerMemberId == referredMemberId` → rejected); duplicate check (existing `Transaction_Type__c = 'Referral' AND Referral_Member__c = referredMemberId` → rejected); condition that the referred member must complete a first purchase before the referrer is awarded (not just enrollment).

**13. How are voucher codes generated securely?**
`EncodingUtil.base64Encode(Crypto.generateAESKey(128))` — 128-bit cryptographically random value. Formatted as `XXXX-XXXX-XXXX-XXXX` by stripping non-alphanumeric characters and inserting hyphens. Never derived from member ID or timestamp (prevents prediction).

**14. What is the minimum redemption threshold and why?**
Configurable in `Loyalty_Config__mdt.Min_Redemption_Points__c` (default: 500 pts = $5). Prevents micro-redemptions that create disproportionate processing overhead and reduce the perceived value of the voucher. Communicated clearly to members in the redemption wizard.

**15. How do you support multi-currency (base points vs bonus points)?**
`LoyaltyMemberCurrency` records have `Currency_Type__c` (Base/Bonus/Partner). Redemption deducts from Base first. Bonus points may have shorter expiry (6 months vs 12 months for Base), configured via `Loyalty_Config__mdt.Bonus_Points_Expiry_Months__c`. Total balance shown to member is the sum of all non-expired currency buckets.

**16. How does a partner loyalty ecosystem work?**
Partner brands have a separate `Loyalty_Transaction__c` `Source_Channel__c = 'Partner'`. Points are awarded at a different rate (`Partner_Points_Per_Dollar__c` in CMDT). Partner rewards (`PartnerReward` voucher type) are redeemable only at partner stores. The `ECommerce_Order_Id__c` idempotency pattern applies for partner API integrations the same way it does for the primary e-commerce channel.

**17. How do you configure a seasonal promotion?**
Create a `Promotion__c` record with `Start_Date__c`, `End_Date__c`, `Bonus_Multiplier__c`, `Eligible_Tier__c`, `Is_Active__c = true`. The `PromotionEngineService` automatically discovers it via the date-range SOQL query. No code change needed. The `promotionBanner` LWC surfaces it to members in real-time.

**18. How does anniversary tier review work?**
`LoyaltyTransactionBatch` checks each member's `Enrollment_Date__c` against today's month and day using `CALENDAR_MONTH()` and `DAY_IN_MONTH()` SOQL functions. Members whose anniversary is today have `Annual_Points__c` compared against retention thresholds. If below threshold, tier is downgraded and `Annual_Points__c` is reset to zero.

**19. Why store points balance on LoyaltyMemberCurrency rather than calculating from ledger?**
At 2M members × 10 transactions/month, a `SUM(Total_Points__c)` query per page load would time out and consume all SOQL time limits. Stored balance is the correct denormalization — O(1) read vs O(n) aggregation. The consistency guarantee is maintained by ensuring all balance changes flow exclusively through the service layer.

**20. How do you test rollback on failed redemption?**
Insert a `Voucher__c` count before the call, call `processRedemption` with points exceeding balance (guaranteed to fail validation), assert that voucher count, transaction count, and member `Points_Balance__c` are all unchanged after the call. This verifies the `Database.Savepoint` rollback worked correctly — no partial DML was committed.

---

*Document version 1.0 — Saikiran Pasumarthy — Loyalty Cloud Interview Reference*
