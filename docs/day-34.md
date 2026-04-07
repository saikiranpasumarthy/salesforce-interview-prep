# Day 34 — Einstein Features & AI in Apex, Prediction Builder, AI-Powered Flows

## Topics Covered

- Einstein Prediction Builder — reading scores from SObject fields
- OOTB Einstein Scoring — OpportunityScore and LeadScore objects
- Einstein Language API — sentiment analysis, intent classification
- Einstein Next Best Action — ConnectApi.Recommendations
- `@InvocableMethod` for AI-powered Flow actions
- Routing automation via intent classification
- Graceful degradation patterns (try/catch for org-optional features)
- Test patterns: SimpleMock, ConnectApi mock via static flags

---

## Einstein AI Feature Overview

| Feature | Data Source | API / Object |
|---------|-------------|--------------|
| Prediction Builder | Custom model → custom SObject field | Read field via SOQL |
| Einstein Discovery | Statistical model → Recommendation field | Read field via SOQL |
| Opportunity Scoring | OOTB ML model | `OpportunityScore` sObject |
| Lead Scoring | OOTB ML model | `LeadScore` sObject |
| Einstein Language | Custom/standard model | HTTP → `callout:Einstein_Language` |
| Einstein Vision | Custom image model | HTTP → `callout:Einstein_Vision` |
| Next Best Action | Strategy + recommendations | `ConnectApi.Recommendations` |
| Generative AI / LLM | Prompt Templates | `ConnectApi.EinsteinLLM` (Day 30) |

---

## Prediction Builder — SObject Field Pattern

Prediction Builder **writes its output to a custom field** on the SObject — no API call needed at runtime. The model runs on a schedule and updates the field.

```apex
// Reading a Prediction Builder score — just SOQL
List<Account> accs = [
    SELECT Id, Churn_Risk_Score__c, Churn_Risk_Tier__c
    FROM Account
    WHERE Id IN :accountIds
];

// Score thresholds (customise per model)
String tier(Decimal score) {
    if (score >= 90) return 'High';
    if (score >= 60) return 'Medium';
    return 'Low';
}
```

### Prediction Builder vs Einstein Discovery

| | Prediction Builder | Einstein Discovery |
|--|-------------------|--------------------|
| Model type | Binary / multi-class classification | Regression + classification |
| Output field | Custom Apex-readable field | Recommendation + explanation fields |
| Builder | Point-and-click Setup wizard | Story builder UI |
| Apex access | SOQL on custom field | SOQL on recommendation field |
| Licence | Einstein Platform licence | Einstein Analytics licence |

---

## OOTB Einstein Scoring Objects

When Einstein Opportunity Scoring or Lead Scoring is enabled, Salesforce provisions dedicated sObjects:

```apex
// Opportunity Scoring
SELECT OpportunityId, Score, ScoreCategory, Trend
FROM OpportunityScore
WHERE OpportunityId IN :oppIds
// Score: 1–99 | ScoreCategory: 'A','B','C','D' | Trend: 'up','down','flat'

// Lead Scoring
SELECT LeadId, Score, ScoreCategory, Trend
FROM LeadScore
WHERE LeadId IN :leadIds
```

**Important:** These objects do NOT exist in scratch orgs without the feature licence.
**Pattern:** Always wrap in `try/catch` and return empty list on exception.

```apex
try {
    return Database.query('SELECT ... FROM OpportunityScore WHERE ...');
} catch (Exception e) {
    return new List<OpportunityScore>(); // graceful degradation
}
```

---

## Einstein Language API

### Authentication
Uses OAuth 2.0 JWT Bearer flow. Configure a **Named Credential** (`Einstein_Language`) with the Einstein Platform API endpoint. The API handles PII masking via the Einstein Trust Layer.

### Sentiment Analysis

```apex
POST callout:Einstein_Language/v2/language/sentiment
{
    "document": "I love this product!",
    "modelId": "CommunitySentiment"   // built-in model; or use custom model ID
}

// Response
{
    "probabilities": [
        { "label": "positive", "probability": 0.92 },
        { "label": "negative", "probability": 0.05 },
        { "label": "neutral",  "probability": 0.03 }
    ]
}
// Probabilities sorted descending — first entry = highest confidence prediction
```

### Intent Classification

```apex
POST callout:Einstein_Language/v2/language/intent
{
    "document": "I am unhappy with my bill",
    "modelId": "support-intent-v1"   // your custom trained model
}

// Response
{
    "probabilities": [
        { "label": "Complaint",   "probability": 0.89 },
        { "label": "Inquiry",     "probability": 0.11 }
    ]
}
```

### Intent → Queue Routing Pattern

```apex
static String mapIntentToQueue(String intent) {
    Map<String, String> queueMap = new Map<String, String>{
        'Complaint'       => 'Escalation_Queue',
        'Billing_Issue'   => 'Billing_Queue',
        'Technical_Issue' => 'Technical_Queue',
        'Renewal_Inquiry' => 'Renewal_Queue',
        'Cancellation'    => 'Retention_Queue'
    };
    return queueMap.containsKey(intent) ? queueMap.get(intent) : 'General_Support';
}

// Escalation rule: high-priority intent AND confidence >= 70%
Boolean isHighPriority = hpIntents.contains(intent) && confidence >= 0.7;
```

---

## Einstein Next Best Action (NBA)

NBA uses **Recommendation** records filtered by a **Strategy** (built in Flow or Apex). Strategies apply SOQL filters, branching logic, and ML predictions to rank recommendations.

```apex
// Fetch recommendations via ConnectApi
ConnectApi.RecommendationPage page = ConnectApi.Recommendations.getRecommendations(
    null,            // communityId (null = internal)
    contextRecordId, // Account Id, Contact Id, etc.
    strategyName,    // NBA Strategy API name
    null, null, null, null
);

for (ConnectApi.AbstractRecommendation abs : page.recommendations) {
    if (abs instanceof ConnectApi.Recommendation) {
        ConnectApi.Recommendation r = (ConnectApi.Recommendation) abs;
        // r.name, r.description, r.targetId, r.acceptanceLabel, r.rejectionLabel
    }
}
```

### NBA Setup (Declarative)
```
Setup → Next Best Action → Strategies → New
  - Name: Account_NBA_Strategy
  - Object: Account
  - Branches: Load → Filter (eligibility) → Boost/Bury (score) → Limit (max 5)
  - Recommendation records: Setup → Recommendations → New
    - Name, Description, Acceptance/Rejection Label, Target URL/Flow
```

### Testing NBA in Apex

```apex
// Cannot mock ConnectApi in unit tests directly.
// Pattern: @TestVisible static flag + mock data

@TestVisible static Boolean useMock = false;
@TestVisible static List<RecommendationItem> mockRecommendations;

public static List<RecommendationItem> getNextBestActions(...) {
    if (useMock && mockRecommendations != null) return mockRecommendations;
    try {
        // real ConnectApi call
    } catch (Exception e) {
        return new List<RecommendationItem>(); // graceful degradation
    }
}
```

---

## @InvocableMethod for AI-Powered Flows

```apex
@InvocableMethod(
    label='Classify Email Intent'
    description='Uses Einstein Language API to classify intent of email text. Returns intent, confidence, routing queue, and high-priority flag.'
    category='Einstein AI'
    callout=true          // REQUIRED for any HTTP callout
)
public static List<EmailIntentOutput> classifyEmailIntent(List<EmailIntentInput> inputs) {
    // bulk-safe: inputs always has exactly 1 element when called from Flow,
    // but service layer handles any size for Apex-direct or Batch use
}
```

### AI Flow Action — Design Rules

1. **Always `callout=true`** when making HTTP calls (Language API, Vision API, external AI)
2. **Bulk-safe**: accept `List<Input>` / return `List<Output>` even if Flow sends 1 element
3. **Graceful error path**: set `error` field on output instead of throwing exception — Flow can branch on it
4. **Separate input validation** from service logic (null checks before delegating to service)
5. **Category label** appears in Flow builder palette — use `'Einstein AI'` for discoverability

---

## Escalation Automation Pattern (AI + Flow + Omni-Channel)

```
Email / Case Created
  → Flow: Get Case.Description
  → Flow Action: Classify Email Intent (EinsteinFlowService)
  → If intent = 'Complaint' AND isHighPriority = true:
      → Flow Action: Analyse Sentiment
      → If requiresEscalation = true:
          → Flow: Create PendingServiceRouting (route to Escalation_Queue)
          → Flow: Post Chatter message to Case

// Apex-side (Day 31 PendingServiceRouting pattern applies here)
PendingServiceRouting psr = new PendingServiceRouting(
    WorkItemId = caseId, RoutingType = 'QueueBased',
    CapacityWeight = 1, IsReadyForRouting = true
);
insert psr;
```

---

## Sentiment → Escalation Thresholds

| Probability | Label | Action |
|-------------|-------|--------|
| ≥ 0.80 | negative | `requiresEscalation = true` → route to Escalation Queue |
| 0.60–0.79 | negative | Flag for supervisor review |
| any | neutral | Standard queue |
| any | positive | No escalation |

---

## Graceful Degradation Summary

| Feature | Guard | Fallback |
|---------|-------|---------|
| `OpportunityScore` | `try/catch` around `Database.query` | Return empty list |
| `LeadScore` | `try/catch` around `Database.query` | Return empty list |
| `ConnectApi.Recommendations` | `try/catch` | Return empty list |
| Einstein Language API | HTTP status check + `try/catch` | Return error in DTO |
| Prediction Builder field | `try/catch` around dynamic SOQL | Return `error` in DTO |

---

## Interview Tips

1. **Prediction Builder writes to a field** — no API call at read time. The ML model runs on a schedule (or triggered refresh) and writes the score to a custom field. Apex just queries it.

2. **`OpportunityScore` / `LeadScore` are separate sObjects** — not fields on Opportunity/Lead. Query them with a separate SOQL joining on `OpportunityId` / `LeadId`.

3. **`callout=true` on `@InvocableMethod`** — required whenever the action makes an HTTP callout (Language API, Vision API, external endpoint). Missing this = `System.CalloutException` at runtime.

4. **NBA strategy vs recommendation** — a *Recommendation* is the content (name, description, button labels). A *Strategy* is the logic that filters and ranks recommendations. They are separate setup objects.

5. **Einstein Language model types** — Sentiment uses `CommunitySentiment` (built-in, no training needed). Intent/NER require a custom model trained in Einstein Platform. Specify model via `modelId` in the request body.

6. **ConnectApi cannot be called in unit tests** — use `@TestVisible static Boolean useMock` pattern to bypass. Alternatively test the surrounding logic and let the ConnectApi call gracefully degrade.

7. **Bulk-safe @InvocableMethod** — always `List<Input>` / `List<Output>`. Flow sends exactly 1 element per invocation but declare bulk-safe so the action can also be called from Batch Apex.

8. **Einstein Trust Layer applies** — Einstein Language API passes through the Trust Layer (PII masking, toxicity filter, audit log). No additional configuration needed.

9. **Prediction Builder vs Discovery** — Prediction Builder = classification (binary or multi-class). Discovery = regression + predictions with explanations. Both write output to fields — accessed identically from Apex.

10. **Score → tier mapping** — standardise tier thresholds (e.g. High ≥ 90, Medium ≥ 60, Low < 60) in a single method and reuse across actions. This makes threshold changes a one-line edit.
