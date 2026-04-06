# Day 23 — Multi-Org Architecture, Connected Apps & Org Strategy

## Core Interview Questions

### Q: When should you use multiple Salesforce orgs vs a single org?

| Use multiple orgs | Stay single org |
|---|---|
| Legal / data residency (EU data must stay in EU) | Simple department separation → use profiles/permission sets |
| Distinct business units with independent release cadences | Shared objects needed across units (cross-org adds latency) |
| ISV: each customer gets a managed-package org | Test isolation → use sandboxes, not separate production orgs |
| Blast-radius isolation (one unit's runaway batch can't impact others) | Budget: each org = separate license costs, admin overhead |
| Acquisition: merge two orgs over time with a hub-spoke bridge | |

---

## Multi-Org Topology Patterns

### Hub-and-Spoke (implemented in OrgTopologyService)
```
Hub Org (source of truth)
    ├── Spoke EMEA  ← subset of Account + Contact
    ├── Spoke APAC  ← subset of Account + Contact
    └── Spoke NA    ← subset of Account + Opportunity
```
- Hub owns master records; spokes receive read-optimised subsets
- Named Credential per spoke → CMDT-driven routing, zero code for new spokes
- Conflict resolution: last-write-wins (timestamp field) or hub-wins (reject spoke updates)

### Mesh
- Any org can push/pull from any other
- Higher callout complexity; requires idempotent external IDs on every record
- Use when orgs must operate independently during hub downtime

### Federated Identity
- Shared SSO (Salesforce as IdP or 3rd-party IdP via Auth Provider)
- Separate data stores per org; users log in once, are provisioned across orgs
- Combined with hub-spoke for data, federated for identity

---

## Connected Apps

### What is a Connected App?
A Connected App is the OAuth 2.0 client registration in Salesforce that:
- Identifies the external app (consumer key + secret)
- Defines allowed OAuth flows (grant types)
- Sets IP ranges, refresh token policy, session timeout
- Can require a named permission set for access

### OAuth Flow Comparison

| Flow | Use case | User interaction |
|---|---|---|
| **Web Server** (Auth Code) | Server-side web apps | Browser redirect → login |
| **User-Agent** (Implicit) | Single-page apps | Browser redirect (deprecated in OAuth 2.1) |
| **JWT Bearer** (RFC 7523) | Server-to-server / headless | None — pre-authorised service user |
| **Client Credentials** | Machine-to-machine (non-Salesforce IdP) | None |
| **Device Flow** | CLI tools, IoT | Out-of-band code entry |
| **Refresh Token** | Long-lived sessions | Initial auth only |

### JWT Bearer Token Flow (Day 16 recap — key for Day 23 context)
```
Apex → Auth.JWT (iss=consumerKey, sub=serviceUser, aud=loginURL)
     → Auth.JWS.sign(certName)          // RSA-SHA256 using SF-managed cert
     → POST /services/oauth2/token      // exchange JWT for access_token
     → cache token in Platform Cache    // avoid re-auth per transaction
```
`JwtTokenService.cls` implements this. Salesforce verifies: JWT signature (public key on Connected App), `iss` matches consumer key, `sub` is pre-authorised, `exp` is within 5-min window.

---

## Named Credentials — Modern vs Legacy

### Legacy Named Credentials
- Single credential, org-wide auth
- Auth Protocol: Basic, OAuth 2.0, JWT, Named Principal or Per-User
- Set in Setup → Named Credentials

### External Credentials + Principals (Spring '23+, recommended)
```
External Credential
  └── Principal (Named / Per User / Anonymous)
       └── Named Credential (points to External Credential)
```
- Separation: External Credential = auth config; Named Credential = URL + headers
- Multiple Named Credentials can share one External Credential
- Principal binding: users/permission sets map to specific auth identities
- `callout:<NC_DeveloperName>/path` — unchanged endpoint syntax in Apex

---

## Cross-Org REST Patterns (OrgBridgeService)

### queryRemoteOrg
```apex
// Named Credential handles auth — no token in Apex code
req.setEndpoint('callout:Hub_Org/services/data/v63.0/query?q=' + encodedSoql);
```
- Response includes `nextRecordsUrl` when `totalSize > 2000` — loop `queryMore` for full sets
- `totalSize` ≠ records.size() when server-side pagination is active

### Composite SObject Collections API
```
PATCH /services/data/v63.0/composite/sobjects/{SObjectType}/{externalIdField}
{
  "allOrNone": false,
  "records": [{ "attributes": {"type":"Account"}, "Name":"Acme", "External_Id__c":"E1" }]
}
```
- `allOrNone: false` → partial success, inspect each result's `success` flag
- `allOrNone: true`  → atomic batch, one failure = full rollback
- Max 200 records per call — `OrgBridgeService.compositeUpsert` auto-chunks
- Returns array ordered to match input — index alignment is critical

### Callout budget planning
```
Callouts per transaction = S spokes × ceil(N records / 200)
Example: 3 spokes × 500 records = 3 × 3 = 9 callouts (well within 100 limit)
Example: 10 spokes × 2000 records = 10 × 10 = 100 callouts (at the limit — use Queueable)
```

---

## Hub-Spoke Routing (OrgTopologyService)

### CMDT-driven routing
```
Org_Routing_Config__mdt
  ├── Object_API_Name__c = 'Account'
  ├── Named_Credential__c = 'Spoke_EMEA'
  ├── External_Id_Field__c = 'External_Id__c'
  ├── Is_Hub__c = false
  ├── Is_Active__c = true
  └── Routing_Priority__c = 1
```
Adding a new spoke = add a CMDT record → zero code deployment.
Decommissioning a spoke = set `Is_Active__c = false`.

### Health check before bulk sync
```apex
if (!OrgBridgeService.healthCheck(route.Named_Credential__c)) {
    throw new TopologyException('Health check failed for: ' + route.Named_Credential__c);
}
```
GET /limits returns 200 for a healthy org. Fail fast before consuming callout budget on an unreachable org.

---

## Salesforce-to-Salesforce (S2S) — Legacy Pattern

S2S is the Salesforce native point-and-click cross-org sync feature:
- Setup → Salesforce to Salesforce → enable
- Create a Connection, subscribe to objects/fields
- Publishes records via email-based async mechanism (not REST)

**Interview point**: S2S is legacy — Salesforce has de-emphasised it.
Modern replacement: Named Credentials + Composite API (OrgBridgeService pattern),
or Salesforce Data Pipelines (Data Cloud).

When asked about S2S:
- "S2S uses an async email-relay mechanism — high latency, limited field mapping"
- "Modern pattern: REST with Named Credentials, Composite API for bulk, Platform Events for real-time"

---

## Org Strategy — Environment Types

| Type | Use | Refresh |
|---|---|---|
| Developer Sandbox | Individual dev | On demand |
| Developer Pro Sandbox | Individual dev (larger data) | On demand |
| Partial Copy Sandbox | QA / UAT | 5 days min |
| Full Sandbox | Performance / load testing | 29 days min |
| Scratch Org | CI/CD, package dev | Max 30 days |
| Production | Live | N/A |

### Hyperforce
- Salesforce infrastructure on public cloud (AWS, Azure, GCP)
- Data residency at the pod level (e.g. all EU data on EU pods)
- No feature difference for Apex/LWC — same APIs
- Key for GDPR / data sovereignty discussions

---

## Key Classes (Day 23)

| Class | Responsibility |
|---|---|
| `OrgBridgeService` | Low-level cross-org REST: query, composite upsert, identity, health |
| `OrgTopologyService` | Hub-spoke routing via CMDT; syncToTargetOrg; broadcastToAllSpokes |
| `Org_Routing_Config__mdt` | Routing table — maps SObject → Named Credential + external ID field |
| `JwtTokenService` (Day 16) | JWT Bearer token flow for Connected App auth |

---

## Quick-Reference: Interview Answers

**"How do you authenticate a Salesforce-to-Salesforce integration?"**
> JWT Bearer Token flow via Connected App. Apex uses `Auth.JWT` + `Auth.JWS` to build and sign the JWT with a Salesforce-managed certificate; exchanges it for an access token via `/services/oauth2/token`. Cache in Platform Cache (OrgPartition) to avoid re-auth per transaction.

**"What is the Composite API and why do you use it?"**
> The Composite SObject Collections API allows upserting up to 200 records in a single HTTP call. It reduces N callouts to `ceil(N/200)`, critical for governor limits (100 callouts/transaction). `allOrNone=false` gives partial success — inspect each record's result individually.

**"How does your hub-spoke routing handle new spokes?"**
> A new Org_Routing_Config__mdt record is added via a metadata deployment — no Apex change, no PR, no scratch org required. `OrgTopologyService.getAllSpokeRoutes()` picks it up automatically on the next execution.

**"What is the difference between a Named Credential and an External Credential?"**
> Named Credential = URL + protocol. External Credential = auth config (OAuth scopes, token endpoint, client ID). The new model separates them so multiple Named Credentials (different paths/services on the same host) can share one External Credential, and per-user vs org-wide auth can be controlled via Principal bindings.
