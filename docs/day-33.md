# Day 33 — Data Cloud Segmentation, Real-Time CDP & Data Cloud + Apex

## Topics Covered

- Advanced segmentation: segment types, refresh strategies, publish jobs
- Waterfall segmentation (mutual exclusivity, priority ordering)
- Suppression lists (global unsubscribe, GDPR opt-out)
- Segment activation targets (Marketing Cloud, Google Ads, Webhooks)
- Real-Time CDP: personalisation at point of interaction
- Data Cloud → CRM Data Actions (webhook pattern)
- CRM → Data Cloud (event streaming pattern)
- Streaming Insights vs batch Calculated Insights
- Next-best-action decisioning with unified profile data
- Batch Apex reads from Data Cloud, writes to CRM
- `@InvocableMethod` with Data Cloud callout patterns

---

## Segment Types

| Type | Description | Use Case |
|------|-------------|---------|
| Standard | Filter criteria on DMO data | High LTV, recent purchasers, at-risk |
| Lookalike | Similar profiles to a seed segment | Prospecting, ad targeting |
| Suppression | Profiles to EXCLUDE from activation | Unsubscribed, GDPR opt-out, churned |

---

## Segment Refresh Strategies

| Strategy | Description | Use Case |
|----------|-------------|---------|
| Manual | Triggered on demand | Pre-activation freshening |
| Streaming | Near-real-time (seconds) | Cart abandonment, real-time triggers |
| Scheduled Incremental | Only changed profiles since last run | Daily list refresh |
| Scheduled Full | Reprocess all profiles | Weekly audit, after data model changes |

```apex
// Trigger a full refresh via API
POST /api/v1/segments/{segmentId}/publishjobs
{ "publishType": "Full" }   // or "Incremental"

// Poll job status
GET /api/v1/segments/{segmentId}/publishjobs/{jobId}
→ { "status": "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled" }
```

---

## Waterfall Segmentation

Priority-ordered, mutually exclusive tier assignment:

```
Priority 1: Platinum  (LTV > $50K)         ← checked first
Priority 2: Gold      (LTV > $10K)
Priority 3: Silver    (LTV > $1K)
Priority 4: General   (everyone else)       ← fallback
```

```apex
// Efficient single-query waterfall check
String sql = 'SELECT SegmentId__c FROM SegmentMembership__dlm '
           + 'WHERE UnifiedIndividualId__c = :uid '
           + 'AND SegmentId__c IN (:platId, :goldId, :silverId)';

Set<String> memberSegments = executeAndCollect(sql);

// Walk priority list — return first match
for (String segId : new List<String>{ platId, goldId, silverId }) {
    if (memberSegments.contains(segId)) { return segId; }
}
return null; // → General tier
```

---

## Suppression Lists

```apex
// Check before any activation/communication
Boolean suppressed = DataCloudSegmentService.isOnSuppressionList(
    unifiedIndividualId,
    new List<String>{ globalUnsubscribeSegId, gdprOptOutSegId }
);
if (suppressed) { return; } // do not send
```

Suppression segment types:
- Global unsubscribe list
- GDPR/CCPA opted-out profiles
- Competitor employees (do not contact)
- Recently churned (re-engagement cooling off period)

---

## Activation Targets

| Target Type | Description |
|-------------|-------------|
| `MarketingCloud` | SF Marketing Cloud (Subscriber List or Journey entry) |
| `GoogleAds` | Google Customer Match (email/phone matching) |
| `FacebookAds` | Facebook Custom Audience |
| `S3` / `SFTP` | File export (CSV) to cloud storage |
| `Webhook` | HTTP POST to external endpoint (custom integrations) |

```apex
// Trigger an activation run
POST /api/v1/segments/{segmentId}/activations/{activationId}/runs
→ 202 Accepted = activation queued
```

---

## Real-Time CDP — 4 Integration Patterns

### Pattern 1: CRM → Data Cloud (Event Streaming)

```
CRM Case created (trigger/Flow)
  → @InvocableMethod (callout=true)
  → Streaming Ingestion API POST
  → Data Cloud near-real-time event arrives

Note: Cannot call callout from trigger directly.
Use Queueable: trigger → enqueue → Queueable.execute() → callout
```

### Pattern 2: Data Cloud → CRM (Personalisation)

```
Apex reads Data Cloud profile at point of interaction
  → PartyIdentification lookup (CRM Id → UnifiedIndividualId)
  → Calculated Insight query (LTV, EngagementScore)
  → selectOffer() decisioning
  → Return personalised offer to Salesforce UI/Flow/API
```

```apex
// LTV-based offer selection
if      (ltv >= 50000) { return 'PLATINUM_RENEWAL'; }  // 20% discount
else if (ltv >= 10000) { return 'GOLD_UPSELL'; }       // 10% discount
else if (engScore >= 0.7) { return 'ENGAGED_PROSPECT'; } // 5% discount
else                  { return 'STANDARD'; }            // no discount
```

### Pattern 3: Data Cloud → CRM (Data Actions)

```
Data Cloud detects profile enters/exits segment
  → Fires webhook to Salesforce Connected App
  → Salesforce receives payload:
    {
      "actionType": "SegmentEntry",
      "segmentId": "seg-high-value",
      "segmentName": "High Value Customers",
      "unifiedIndividualId": "uid-abc",
      "eventTime": "2024-06-15T10:30:00Z",
      "attributes": { "ContactId__c": "003xx..." }
    }
  → Apex processes: update CRM record + create Task
```

```apex
// Data Action handler (called from REST Resource or Platform Event trigger)
DataActionResult result = DataCloudPersonalisationService.processDataAction(payload);
// → SegmentEntry: update Contact.Description + create Task
// → SegmentExit:  update Contact.Description (clear segment flag)
```

### Pattern 4: Batch Apex → Data Cloud → CRM

```
Scheduled Batch Apex
  → Query Data Cloud (high LTV profiles via Query API, paginated)
  → For each profile: resolve PartyIdentificationNumber__c (CRM Id)
  → Create/update CRM records (Tasks, Opportunities, Campaign members)
```

```apex
// In Batch Apex execute():
// Note: callouts allowed in Batch if Database.AllowsCallouts is implemented
String sql = 'SELECT pid.PartyIdentificationNumber__c, lv.TotalLifetimeValue__c '
           + 'FROM   LifetimeValue__dlm lv '
           + 'JOIN   PartyIdentification__dlm pid '
           + '         ON lv.UnifiedIndividualId__c = pid.UnifiedIndividualId__c '
           + 'WHERE  lv.TotalLifetimeValue__c >= 10000 '
           + 'ORDER BY lv.TotalLifetimeValue__c DESC LIMIT 200';
```

---

## Streaming Insights vs Batch Calculated Insights

| | Batch Calculated Insight | Streaming Insight |
|-|--------------------------|-------------------|
| Compute trigger | Schedule (hourly/daily) | As events arrive |
| Latency | Minutes to hours | Seconds to minutes |
| Use case | LTV, purchase frequency | Real-time engagement, cart abandonment |
| Licence | Included | Requires Streaming Insights add-on |
| Query | Same Query API | Same Query API |
| Configuration | Standard CI builder | Streaming mode in CI builder |

---

## Segment Analytics from Apex

```apex
// Count membership per segment (Apex-side aggregation)
Map<String, Integer> counts = DataCloudSegmentService.getSegmentMemberCounts(
    new List<String>{ 'seg-platinum', 'seg-gold', 'seg-silver' }
);
// Note: Data Cloud Query API does not support GROUP BY at base tier.
// Aggregate in Apex by counting rows per SegmentId__c.
```

---

## Segment API Reference

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/segments` | GET | List all segments |
| `/api/v1/segments/{id}` | GET | Get segment detail |
| `/api/v1/segments/{id}/publishjobs` | POST | Trigger refresh |
| `/api/v1/segments/{id}/publishjobs/{jobId}` | GET | Poll job status |
| `/api/v1/segments/{id}/activations` | GET | List activation targets |
| `/api/v1/segments/{id}/activations/{actId}/runs` | POST | Trigger activation run |

---

## Testing Patterns

```apex
// Single response
DataCloudSegmentService.calloutMock = new SimpleMock(200, responseJson);

// Sequenced responses (different per call)
DataCloudPersonalisationService.calloutMock = new SequencedMock(
    new List<Integer>{ 200, 200 },
    new List<String>{ partyIdentificationResponse, ltvInsightResponse }
);

// Ingestion mock from Day 32 (reusable)
DataCloudIngestionService.calloutMock = new IngestionMock(202, '{}');
```

---

## Interview Tips

1. **Waterfall = mutually exclusive** — a profile can be in only one tier. Checked top-down; stop at first match.

2. **Suppression check before activation** — always check suppression before communicating. Suppression happens automatically during segment activation (configured in activation setup), but add Apex-side check for real-time decisioning paths.

3. **Data Actions** — Data Cloud fires the webhook; Salesforce receives it. Common interview question: "How does Data Cloud trigger a CRM update?" Answer: Data Action → webhook → Apex REST resource or Platform Event.

4. **Streaming vs batch Calculated Insights** — same Query API, different latency. Streaming requires an add-on licence.

5. **Callout from trigger** — cannot call Data Cloud directly from a trigger. Pattern: trigger → `System.enqueueJob(new MyQueueable())` → Queueable `execute()` → callout.

6. **`callout=true` on `@InvocableMethod`** — required for any action that streams to Data Cloud. Missing this causes `System.CalloutException` at runtime.

7. **Segment refresh vs activation** — refresh = re-evaluate who's in the segment (updates `SegmentMembership__dlm`). Activation = push the current member list to downstream system (MC, Ads, etc.). Refresh must complete before activation reflects latest membership.

8. **No GROUP BY in base Query API** — use Apex-side aggregation or pre-compute in Calculated Insights. This is a common gotcha.

9. **PartyIdentification** — always the bridge between CRM record Id and Data Cloud UnifiedIndividualId. `IdentityType__c` + `PartyIdentificationNumber__c`.

10. **Personalisation pattern** — Party Identification lookup → Calculated Insight query → decisioning logic → offer/next-best-action. Know all 3 steps.
