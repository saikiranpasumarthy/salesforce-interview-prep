# Day 32 — Data Cloud Architecture, Data Streams & Ingestion, Unified Profiles

## Topics Covered

- Data Cloud architecture: DLO → DMO → Unified Profile pipeline
- Data sources and connectors (CRM, Marketing Cloud, Streaming, Batch)
- Streaming Ingestion API (HTTP POST, 202 Accepted, chunking)
- Batch ingestion patterns
- Data Lake Objects (DLO) vs Data Model Objects (DMO)
- Identity Resolution: matching rules, reconciliation rules
- Unified Individual profile model
- Contact points: email, phone, IsPrimary
- Party Identification (CRM record → unified profile bridge)
- Data Cloud Query API (SQL dialect, DMO tables, pagination)
- Calculated Insights (batch metrics on DMO data)
- Segment membership queries
- Purchase history via SalesOrder__dlm
- GDPR/CCPA right-to-erasure (delete ingestion)

---

## Data Cloud Architecture

```
Data Sources
  ├── Salesforce CRM Connector    — real-time standard objects sync
  ├── Marketing Cloud Connector   — subscriber, journey, campaign data
  ├── Streaming Ingestion API     — real-time events (POST /api/v1/ingest/...)
  ├── Batch / File Ingestion      — CSV/JSON via S3, SFTP, or Bulk API
  └── External Connectors         — MuleSoft, Snowflake, Azure, BigQuery
           ↓
  Data Lake Objects (DLO)         — raw data as-is from source
           ↓
  Data Mapping / Transformation   — field-level mapping to canonical model
           ↓
  Data Model Objects (DMO)        — standardised canonical representation
           ↓
  Identity Resolution              — deduplication + merge
           ↓
  Unified Profile                  — single customer view
```

---

## DLO vs DMO

| Concept | Data Lake Object (DLO) | Data Model Object (DMO) |
|---------|----------------------|------------------------|
| Content | Raw ingested data | Canonically mapped data |
| Schema | Source schema | Salesforce canonical model |
| Naming | `SourceName__dlm` | Standard name (e.g. `Individual__dlm`) |
| Editable | No | Yes (via mapping) |
| Queryable | Yes (Query API) | Yes (Query API) |
| Created by | Ingest / connector | Data mapping configuration |

---

## Standard DMOs (interview vocabulary)

| DMO | Purpose |
|-----|---------|
| `UnifiedIndividual__dlm` | Merged unified profile (post Identity Resolution) |
| `Individual__dlm` | Source individual records (pre-merge) |
| `ContactPointEmail__dlm` | Email addresses linked to individuals |
| `ContactPointPhone__dlm` | Phone numbers linked to individuals |
| `ContactPointAddress__dlm` | Postal addresses |
| `SalesOrder__dlm` | Purchase / order data |
| `UnifiedLinkContactPoint__dlm` | Junction: unified individual ↔ contact points |
| `PartyIdentification__dlm` | Links unified profile → source system record Ids |
| `SegmentMembership__dlm` | Which unified profiles are in which segments |

---

## Streaming Ingestion API

### Endpoint

```
POST callout:DataCloud_Org/api/v1/ingest/sources/{sourceApiName}/{objectApiName}
Content-Type: application/json
Authorization: Bearer {oauth_token}
```

### Request body

```json
{
  "data": [
    {
      "AccountId__c": "001xx0000000001",
      "Name__c": "Acme Corp",
      "AnnualRevenue__c": 5000000,
      "LastModifiedDate__c": "2024-06-15T10:30:00Z"
    }
  ]
}
```

### Response codes

| Code | Meaning |
|------|---------|
| `202 Accepted` | Records queued for async processing **(success)** |
| `400 Bad Request` | Schema validation failed (unknown field, wrong type) |
| `401 Unauthorized` | Invalid / expired OAuth token |
| `429 Too Many Requests` | Rate limit exceeded — retry with exponential backoff |
| `500 Server Error` | Data Cloud internal error — retry |

**Key**: `202` is the success code for ingestion — do **not** expect `200 OK`.

### Chunking rule

```apex
// Max 200 records per request
for (Integer offset = 0; offset < records.size(); offset += 200) {
    Integer end = Math.min(offset + 200, records.size());
    List<Map<String,Object>> chunk = records.subList(offset, end);
    sendIngestionRequest(chunk, sourceApiName, objectApiName);
}
```

### DateTime format

Data Cloud requires **ISO 8601 UTC**: `yyyy-MM-dd'T'HH:mm:ss'Z'`

```apex
String iso = dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
```

### Delete (GDPR Right to Erasure)

```
POST .../sources/{source}/{object}?operation=delete
Body: { "data": [ { "AccountId__c": "001xx..." } ] }  // primary key only
```

---

## Identity Resolution

### Process

```
Source records (multiple systems/sources)
         ↓
  Matching Rules     — which records are the same person?
    ├── Exact Match: EmailAddress__c
    ├── Exact Match: PhoneNumber__c
    └── Fuzzy Match: FirstName + LastName + PostalCode
         ↓
  Reconciliation Rules — which field value "wins" when sources conflict?
    ├── Most Recent Value (last updated source wins)
    ├── Most Frequent Value (most common value across sources)
    └── Source Priority (CRM > MC > Web)
         ↓
  UnifiedIndividual__dlm  — one merged profile per real customer
```

### Party Identification (CRM → Unified Profile bridge)

```apex
// Find unified profile by CRM Contact Id
String sql =
    'SELECT ui.UnifiedIndividualId__c '
    + 'FROM   UnifiedIndividual__dlm ui '
    + 'JOIN   PartyIdentification__dlm pid '
    + '  ON   ui.UnifiedIndividualId__c = pid.UnifiedIndividualId__c '
    + 'WHERE  pid.IdentityType__c = \'ContactId\' '
    + '  AND  pid.PartyIdentificationNumber__c = \'003xx...\' ';
```

`PartyIdentification__dlm` fields:
- `IdentityType__c` — `'ContactId'`, `'LeadId'`, `'MarketoId'`, `'ExternalId'`
- `PartyIdentificationNumber__c` — the actual Id from the source system
- `SourceSystem__c` — `'Salesforce'`, `'MarketingCloud'`, etc.

---

## Data Cloud Query API

### Endpoint

```
POST callout:DataCloud_Org/api/v1/query
Content-Type: application/json

{ "sql": "SELECT UnifiedIndividualId__c, FirstName__c FROM UnifiedIndividual__dlm LIMIT 10" }
```

### Response

```json
{
  "data":        [ { "UnifiedIndividualId__c": "uid-abc", "FirstName__c": "Jane" } ],
  "totalSize":   1,
  "nextBatchId": null
}
```

### SQL Dialect Notes

| Feature | Supported |
|---------|----------|
| `SELECT *` | ✅ |
| `JOIN` between DMOs | ✅ |
| `WHERE` with comparison operators | ✅ |
| `ORDER BY` | ✅ |
| `LIMIT` / `OFFSET` | ✅ |
| `GROUP BY` (base tier) | ❌ Use Calculated Insights |
| Subqueries in `FROM` | ❌ |
| `LIKE` pattern matching | ✅ |
| `DATE_ADD(TODAY(), -N)` | ✅ |

### Pagination

```apex
// First request returns nextBatchId if more rows exist
// GET /api/v1/query/{nextBatchId} fetches the next page
// nextBatchId = null means last page
// Max rows per page: 10,000
```

---

## Calculated Insights

Batch-computed aggregations stored as metrics on DMOs.

```
Examples:
  LifetimeValue__dlm    — TotalLifetimeValue__c, PurchaseCount__c
  EngagementScore__dlm  — Score30Day__c, Score90Day__c
  ChurnRisk__dlm        — ChurnProbability__c, RiskTier__c

Refresh schedule: hourly / daily (configured per insight)
```

```apex
// Query a Calculated Insight DMO
String sql = 'SELECT TotalLifetimeValue__c, PurchaseCount__c '
           + 'FROM   LifetimeValue__dlm '
           + 'WHERE  UnifiedIndividualId__c = \'' + unifiedId + '\'';
```

---

## Segments

```
Segment = filter criteria applied to DMO data
  → Criteria: "TotalLifetimeValue__c > 10000 AND Country__c = 'US'"
  → Members: all UnifiedIndividuals matching the filter
  → Refresh: manual or scheduled (hourly / daily)
  → Activation: publish member list to MC, Advertising Studio, etc.
```

```apex
// Check segment membership (post-refresh)
'SELECT UnifiedIndividualId__c '
+ 'FROM   SegmentMembership__dlm '
+ 'WHERE  UnifiedIndividualId__c = :uid '
+ '  AND  SegmentId__c = :segId '
+ 'LIMIT  1'
```

---

## Named Credential Pattern for Data Cloud

```
Named Credential: DataCloud_Org
  Label:           Data Cloud Org
  URL:             https://{tenant}.c360a.salesforce.com
  Authentication:  OAuth 2.0 (Connected App in Data Cloud org)
  Identity Type:   Named Principal

Usage in Apex:
  req.setEndpoint('callout:DataCloud_Org/api/v1/query');
```

---

## Testing Strategy

```apex
// Inject mock via static field
DataCloudIngestionService.calloutMock = new MyMock(202, '{"accepted":true}');
DataCloudProfileService.calloutMock   = new QueryMock(200, '{"data":[...],"totalSize":1}');

// Sequenced mock for multi-call methods
DataCloudProfileService.calloutMock = new SequencedQueryMock(
    new List<String>{ emailResponseJson, phoneResponseJson }
);
```

---

## Interview Tips

1. **202 Accepted = success** for Streaming Ingestion API. `200 OK` is not the expected code.

2. **DLO vs DMO** — DLO is raw ingested data; DMO is the mapped canonical representation. Identity Resolution runs on DMO data, not DLO.

3. **Identity Resolution** — two phases: matching (which records are the same person?) and reconciliation (which field value wins when they conflict?). Know the three reconciliation strategies.

4. **PartyIdentification** — the bridge between CRM record Ids and Data Cloud unified profile Ids. `IdentityType__c` + `PartyIdentificationNumber__c` + `SourceSystem__c`.

5. **Calculated Insights cannot GROUP BY in Query API** — aggregations must be pre-computed as Calculated Insights, not done ad hoc in the Query API SQL.

6. **Segment vs Calculated Insight** — Segment = membership filter (who qualifies?); Calculated Insight = computed metric (what is the value for each profile?). Both are used for personalisation.

7. **Max 200 records per Streaming Ingestion request** — always chunk before sending.

8. **GDPR delete** — same ingestion endpoint, `?operation=delete` query param, primary key fields only in payload.

9. **`nextBatchId` pagination** — Query API returns max 10,000 rows; use `nextBatchId` for subsequent pages via GET endpoint.

10. **Named Credential** — never hardcode Data Cloud instance URL or OAuth token. Use Named Credential for URL + authentication management.
