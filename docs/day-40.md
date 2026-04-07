# Day 40 — Advanced Scenarios, Cross-Cloud Architecture & Offer Negotiation

## Overview

Final technical deep-dive before Day 41 (Jitterbit). Covers architect-level patterns
for the final interview round, plus offer negotiation strategy.

**Part 1 — Advanced Apex Scenarios:**
1. Composite REST API — atomic multi-object creation in one callout
2. Agentforce Custom Action — `@InvocableMethod` for Einstein Copilot
3. Token-bucket rate limiter — throttle outbound API calls
4. Multi-org record sync — External ID + fingerprint change detection
5. Bulk API 2.0 job lifecycle — when to use vs Batch Apex
6. Idempotent webhook receiver — HMAC-256 + dedup

**Part 2 — Cross-Cloud Architecture:**
1. Marketing Cloud connector — REST API data extension upsert
2. Data Cloud activation handler — segment membership to Contacts
3. Revenue Cloud (CPQ) — quote approval routing + ERP notification
4. Agentforce grounding — structured account context for Einstein LLM
5. MuleSoft canonical message format — error envelopes + error code taxonomy
6. CRM Analytics / Tableau — External Data API push

---

## Part 1: Advanced Apex Q&A

### Q1: How do you create an Account, Contact, and Opportunity atomically in a single REST call?

**Answer:** Salesforce Composite REST API.

```
POST /services/data/v59.0/composite
{
  "allOrNone": true,
  "compositeRequest": [
    { "method": "POST", "url": "/services/data/v59.0/sobjects/Account",
      "referenceId": "newAccount", "body": { "Name": "ACME Corp" } },
    { "method": "POST", "url": "/services/data/v59.0/sobjects/Contact",
      "referenceId": "newContact",
      "body": { "LastName": "Doe", "AccountId": "@{newAccount.id}" } },
    { "method": "POST", "url": "/services/data/v59.0/sobjects/Opportunity",
      "referenceId": "newOpp",
      "body": { "Name": "Deal", "AccountId": "@{newAccount.id}", ... } }
  ]
}
```

- **Reference IDs** (`@{newAccount.id}`) resolve at runtime — child records reference parent IDs
- **`allOrNone: true`** — all succeed or all roll back
- **One callout** consumed (not three)
- **Up to 25 subrequests** per composite call

**When to use:** When an external system (mobile app, integration middleware) needs to create related records atomically via REST.

---

### Q2: How do you build an Agentforce custom action?

**Answer:**

```apex
@InvocableMethod(
    label       = 'Get Account Health Score'
    description = 'Returns a health score 0-100 for an account. Use when user asks '
                + 'about account health, risk, or status.'  // LLM reads this description
    category    = 'Account Management'
)
public static List<AccountHealthOutput> getAccountHealthScore(
    List<AccountHealthInput> inputs
) { ... }

public class AccountHealthInput {
    @InvocableVariable(label='Account ID' required=true)
    public String accountId;
}

public class AccountHealthOutput {
    @InvocableVariable(label='Health Score (0-100)')
    public Integer healthScore;
    @InvocableVariable(label='Recommendation')
    public String recommendation;
}
```

**Key interview points:**
- `label` and `description` are surfaced to Einstein as "tool metadata" — write them for an LLM, not a developer
- `@InvocableVariable` (not `Map<String,Object>`) — structured data the LLM can reference by field name
- Actions must be **deterministic**: same input → same output
- Actions must be **focused**: one action = one clear capability

---

### Q3: What is a token-bucket rate limiter and how do you implement one in Apex?

**Answer:**

Token bucket: a bucket holds N tokens. Each API call consumes one token. Tokens refill at a fixed rate (e.g., 10/minute). If the bucket is empty, the call is deferred or rejected.

```apex
// Static per-transaction bucket (resets each transaction)
static Map<String, Integer> tokenBuckets = new Map<String, Integer>();

public static Boolean consumeToken(String serviceKey, Integer capacity) {
    if (!tokenBuckets.containsKey(serviceKey)) {
        tokenBuckets.put(serviceKey, capacity);
    }
    Integer remaining = tokenBuckets.get(serviceKey);
    if (remaining <= 0) return false; // rate limit hit
    tokenBuckets.put(serviceKey, remaining - 1);
    return true;
}
```

**For cross-transaction rate limiting:** use Platform Cache (Org partition) to persist the token count between transactions. Cache the `{serviceKey}:{windowStartTime}:{count}` value with a TTL matching the rate window.

---

### Q4: How do you sync records between two Salesforce orgs?

**Pattern: External ID + Fingerprint**

```apex
// Source org publishes: { externalId, name, industry, ... }
// Target org upserts by External ID

// Fingerprint = SHA-256 hash of key fields (truncated)
String fingerprint = computeFingerprint(new List<String>{name, industry, phone});

// Skip upsert if fingerprint matches — record hasn't changed
if (existing.SyncFingerprint__c == fingerprint) return; // no-op

Database.upsert(account, Account.ExternalAccountId__c);
```

**Interview checklist for multi-org sync:**
1. Deploy `ExternalAccountId__c` (unique, `externalId=true`) to both orgs
2. Source Id stored as External ID in target
3. Fingerprint prevents unnecessary DML when data hasn't changed
4. Change publisher: Platform Event or Outbound Message or REST webhook
5. Change receiver: Platform Event trigger or REST `@RestResource` endpoint
6. Idempotency: upsert by External ID is naturally idempotent

---

### Q5: When do you use Bulk API 2.0 vs Batch Apex?

| Aspect | Bulk API 2.0 | Batch Apex |
|---|---|---|
| Triggers / Flows / Workflows | ❌ Skipped | ✅ Execute |
| Governor limits per chunk | No per-chunk limit | 10k DML rows |
| Max records | 150M+ | Unlimited (chunked) |
| Use case | Pure data load / ETL | Business logic required |
| Monitoring | Job state via REST poll | `AsyncApexJob` query |
| Error records | `failedResults` endpoint | `Database.SaveResult[]` |

**Use Bulk API when:** sandbox refresh data scrub, org migration, no business logic needed.
**Use Batch Apex when:** triggers/flows must fire, complex logic per record, rollups.

---

### Q6: How do you build an idempotent webhook receiver?

**Two concerns:**

**A. Authenticity (is it really from the partner?)**
```apex
// HMAC-SHA256 signature verification
Blob mac = Crypto.generateMac('HmacSHA256',
    Blob.valueOf(payload), Blob.valueOf(sharedSecret));
String expected = EncodingUtil.convertToHex(mac);
return expected.equals(receivedSignature); // constant-time compare
```

**B. Idempotency (don't process the same webhook twice)**
```apex
// Check ProcessedWebhook__c for existing webhookId before processing
// On success: insert ProcessedWebhook__c with WebhookId__c = webhookId
```

**Flow:**
1. Validate HMAC → reject if invalid (return 401)
2. Check `ProcessedWebhook__c` by `webhookId` → return 200 (already processed)
3. Process payload → insert `ProcessedWebhook__c` → return 200

---

## Part 2: Cross-Cloud Architecture Q&A

### Q7: How does Sales Cloud integrate with Marketing Cloud?

**Three options:**

| Option | When to Use |
|---|---|
| MC Connect (native sync) | Standard Contact/Lead sync, near-real-time is acceptable |
| MC REST API (Apex callout) | Custom DE upsert, Journey entry, transactional sends |
| Distributed Marketing | Fire a Journey from a Flow or Apex action in Sales/Service Cloud |

**MC REST API flow:**
1. POST to `/v2/token` with `client_credentials` → get `access_token`
2. POST to `/hub/v1/dataevents/key:{DE_Key}/rows` with row payload
3. Bearer token in `Authorization` header

**Named Credential stores:** `client_id`, `client_secret`, MC REST base URL — never in Apex code.

---

### Q8: How does Data Cloud push segment membership to Sales Cloud?

**Three activation methods:**

1. **Related Object activation** — Data Cloud writes to a custom object in Sales Cloud (e.g., `SegmentMembership__c`) when segment membership changes
2. **Webhook activation** — Data Cloud calls a Salesforce REST endpoint with member profiles; Apex upserts the data
3. **Streaming Insights** — Data Cloud fires Platform Events into Sales Cloud; subscriber trigger updates Contact fields in real-time

**For real-time reactions:** Streaming Insights (Platform Events) is lowest latency.
**For bulk updates:** Related Object activation with a batch Apex processor.

---

### Q9: How does CPQ integrate with an ERP for order management?

**Integration points:**

```
Quote → Approved → SBQQ__Quote__c.SBQQ__Status__c = 'Approved'
  ↓
Platform Event or Process Builder / Flow fires
  ↓
Apex callout to ERP: POST /api/v1/quotes/approve
  ↓
ERP returns orderId
  ↓
Store orderId on SBQQ__Quote__c.ErpOrderId__c
```

**Approval routing tiers (typical):**
- `< $25k` → Auto-approve
- `$25k–$100k` → Manager
- `$100k–$500k` → Director
- `> $500k` or Strategic discount → Executive (VP + CFO)

---

### Q10: How do you ground Agentforce with record-specific context?

```apex
@InvocableMethod(
    label       = 'Get Account Context for Agentforce'
    description = 'Returns structured account summary including open cases, '
                + 'pipeline, and owner. Use before generating any account-related response.'
)
public static List<AgentContextOutput> getAccountContextForAgent(
    List<AgentContextInput> inputs
) { ... }
```

**Output (contextSummary passed to Einstein):**
```
Account: ACME Corp
Industry: Technology
Owner: Jane Smith
Open Opportunities (2):
  - Negotiation: $250,000 (closes 2026-06-30)
  - Prospecting: $80,000 (closes 2026-09-15)
Open Cases (1):
  - [New] Integration failing after Winter '26 release
```

**Why structure matters:** Einstein performs better with structured summaries than raw SOQL result JSON. Label fields descriptively — the LLM reads the labels.

---

## Part 3: Offer Negotiation Prep

### Framing your value as a Senior Salesforce Developer

**Your differentiators (based on this 40-day prep):**
- **Architect-level depth**: Cross-cloud orchestration, Saga pattern, multi-org sync, Composite API
- **Security awareness**: FLS enforcement, HMAC validation, injection prevention at every layer
- **Performance engineering**: Circuit breakers, rate limiters, CPU guards, cursor pagination
- **DevOps maturity**: CI/CD gating, coverage analysis, destructive change detection, env config factory
- **AI/Cloud breadth**: Agentforce custom actions, Data Cloud activation, MC REST API, Einstein sentiment

### The STAR framework for technical interviews

**"Tell me about a complex integration you built."**

- **Situation**: "We had Sales Cloud, Service Cloud, and a legacy ERP, with no real-time sync."
- **Task**: "I was asked to architect a bi-directional sync that handled failures gracefully."
- **Action**: "I designed a Saga-based orchestration with Platform Events, external ID upsert, HMAC-verified webhooks, and a dead-letter queue for failed events."
- **Result**: "Reduced data lag from 4 hours to < 30 seconds, zero data loss incidents in 6 months."

### Negotiation anchors

| Situation | Response |
|---|---|
| "What are your salary expectations?" | Give a range based on market data. Lead with architect-level scope: "Given the cross-cloud architecture experience I bring, I'm targeting $X–$Y." |
| "That's above our band." | "I understand. Can you share what's in the band? I want to understand the full package — equity, bonus, and certification budget also matter to me." |
| "We need a decision by Friday." | "I appreciate the timeline. I want to make a thoughtful decision — can I have until [2 days later]?" |
| Competing offer | Use it as leverage only if real: "I have another offer at $X. I prefer this role — is there flexibility to match?" |

### Certification value at senior level

- **Architect certs** (System Architect, Application Architect, CTA) add $20–40k to base in most markets
- **AI Specialist** (Einstein, Agentforce) is commanding a premium in 2025–2026
- Request **certification budget** ($5–10k/year) as part of the offer — it's usually available

---

## Files Created

| File | Purpose |
|---|---|
| `AdvancedScenariosService.cls` | Composite API, Agentforce action, rate limiter, multi-org sync, Bulk API, idempotent webhook |
| `CrossCloudArchitectureService.cls` | MC connector, Data Cloud activation, CPQ routing, Agentforce grounding, MuleSoft canonical format, CRM Analytics |
| `AdvancedScenariosTest.cls` | 35 tests covering all patterns with callout mocks |

---

## Interview Tips — Day 40

1. **Composite API**: Most candidates say "three DML statements" — saying "Composite REST API with reference IDs" signals architect-level REST knowledge.
2. **Agentforce**: Write `description` fields as instructions to an LLM, not a developer. "Use when the user asks about X" is the right pattern.
3. **Rate limiter**: Mention Platform Cache for cross-transaction state — shows you understand the stateless nature of Apex transactions.
4. **Multi-org sync**: Always lead with External ID + upsert. Adding the fingerprint optimization distinguishes senior from mid-level.
5. **Bulk API**: Interviewers often want to hear you volunteer "but triggers don't fire" — proactively mention this trade-off.
6. **HMAC webhook**: The constant-time comparison (`expected.equals(received)`) prevents timing attacks — mentioning this shows security depth.
7. **Data Cloud**: Know the three activation methods and when each is appropriate — most candidates only know one.
