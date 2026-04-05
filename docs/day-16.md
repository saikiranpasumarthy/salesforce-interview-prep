# Day 16 — REST API Integrations, Named Credentials & Auth

## Overview

Salesforce is a hub for enterprise integrations. Every senior developer interview includes callout questions — focusing on governor limits, auth patterns, error handling, and testability.

---

## HTTP Callout Basics

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('https://api.example.com/v1/accounts/123');
req.setMethod('GET');
req.setHeader('Authorization', 'Bearer ' + token);
req.setHeader('Content-Type', 'application/json');
req.setHeader('Accept',       'application/json');
req.setTimeout(30000);   // milliseconds; default is 10,000; max is 120,000

HttpResponse resp = new Http().send(req);

Integer code = resp.getStatusCode();   // 200, 201, 404, 500, …
String  body = resp.getBody();
String  ct   = resp.getHeader('Content-Type');
```

### Methods

| Method | Idempotent | Body | Typical use |
|---|---|---|---|
| `GET` | Yes | No | Fetch resource |
| `POST` | No | Yes | Create resource |
| `PUT` | Yes | Yes | Replace resource (full) |
| `PATCH` | No | Yes | Update resource (partial) |
| `DELETE` | Yes | No | Remove resource |

### Governor Limits

| Limit | Value |
|---|---|
| Max callouts per transaction | 100 |
| Max timeout per callout | 120,000 ms |
| Max request body size | 12 MB |
| Max response body size | 12 MB |

**Cannot make callouts after DML in the same transaction.**

Solutions:
- `@future(callout=true)` — fire-and-forget async callout
- `Queueable implements Database.AllowsCallouts` — async with chaining + state
- `Batch` + `Database.AllowsCallouts` — bulk callout in execute()

---

## Named Credentials

### Why Named Credentials?

| Without NC | With NC |
|---|---|
| Hard-code endpoint URLs in code | Endpoint stored in metadata |
| Manage tokens/auth in Apex | Platform injects auth headers automatically |
| Remote Site Settings required | No Remote Site Setting needed |
| Credentials in code or custom settings | Credentials stored encrypted in platform |

### Endpoint Format

```apex
req.setEndpoint('callout:Demo_External_API/accounts/123');
// Platform resolves to: https://api.example.com/v1/accounts/123
// + injects auth headers based on NC protocol
```

### Protocol Options

| Protocol | When to use |
|---|---|
| `NoAuthentication` | Public API or you inject headers manually |
| `Password` | Basic Auth (username + password) |
| `Oauth` | OAuth 2.0 org-wide; platform manages tokens |
| `Jwt` | JWT Bearer; references a Salesforce certificate |
| `JwtExchange` | JWT + token exchange (Salesforce-to-Salesforce) |

### Legacy vs New Model (API 57+)

**Legacy Named Credential** (all-in-one):
```xml
<NamedCredential>
    <protocol>Oauth</protocol>
    <authProvider>My_Auth_Provider</authProvider>
    <url>https://api.example.com</url>
    <label>My API</label>
</NamedCredential>
```

**New model** (separated concerns):
```
ExternalCredential  — auth protocol, client_id/secret, per-user principals
       ↓
NamedCredential     — endpoint URL + reference to ExternalCredential
```

New model supports per-user credentials (each Salesforce user has their own token) vs org-wide. Configure via **Setup → Named Credentials → External Credentials**.

---

## JSON Patterns

### Type-safe deserialization

```apex
// DTOs must match JSON field names (case-insensitive)
public class AccountDto {
    public String id;
    public String name;
    public List<ContactDto> contacts;
}

AccountDto dto = (AccountDto) JSON.deserialize(body, AccountDto.class);
// Fields not in JSON remain null — no exception
// Extra JSON fields are silently ignored
```

### Untyped parsing

```apex
// Returns Map<String,Object> for objects, List<Object> for arrays
Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
String id   = (String) root.get('id');
List<Object> items = (List<Object>) root.get('items');
Map<String, Object> first = (Map<String, Object>) items[0];
```

Use untyped when:
- Schema is dynamic / unknown at compile time
- Deeply nested with varying types
- You only need a few specific values from a large payload

### Serialization

```apex
String json = JSON.serialize(myObject);
// suppressApexObjectNulls=true omits null fields → smaller payload
String json = JSON.serialize(myObject, true);
```

### Snake_case → camelCase translation

JSON APIs often use `snake_case`; Apex uses camelCase. Workarounds:

1. Match field names in DTO to JSON exactly (not always possible)
2. Use `JSON.createParser(body)` for manual token-by-token parsing
3. Pre-process: `body.replace('"first_name":', '"firstName":')` (fragile)
4. Use a custom `JSONDeserializer` utility class

---

## Retry Pattern

```apex
private static HttpResponse sendWithRetry(HttpRequest req) {
    Http http = new Http();
    for (Integer attempt = 0; attempt <= MAX_RETRIES; attempt++) {
        HttpResponse resp = http.send(req);
        Integer code = resp.getStatusCode();
        Boolean retryable = (code == 429 || (code >= 500 && code < 600));
        if (!retryable || attempt == MAX_RETRIES) { return resp; }
        // In production: use Queueable chaining for real exponential back-off
    }
    return null; // unreachable
}
```

**Retryable status codes:**
- `429` — Rate Limit exceeded
- `500` — Internal Server Error
- `502` — Bad Gateway (upstream error)
- `503` — Service Unavailable
- `504` — Gateway Timeout

**Do NOT retry:**
- `400` — Bad Request (fix the payload first)
- `401` / `403` — Auth failure (refresh token instead)
- `404` — Not Found (resource doesn't exist)

**Real back-off in Apex:**
Apex has no `Thread.sleep()`. True exponential back-off requires Queueable chaining:
```apex
public class RetryJob implements Queueable, Database.AllowsCallouts {
    private HttpRequest req;
    private Integer attempt;
    public void execute(QueueableContext ctx) {
        HttpResponse resp = new Http().send(req);
        if (shouldRetry(resp) && attempt < MAX) {
            System.enqueueJob(new RetryJob(req, attempt + 1));
        }
    }
}
```

---

## Auth Patterns

### 1. Named Credential (platform-managed OAuth) — simplest

```
Salesforce → Named Credential (OAuth) → External API
            Platform fetches + refreshes token automatically
```

### 2. JWT Bearer Token (RFC 7523)

```
1. Build JWT:  iss=consumer_key, sub=username, aud=token_endpoint
2. Sign JWT:   Auth.JWS(jwt, certName)  ← RSA-SHA256 with Salesforce-managed key
3. Exchange:   POST grant_type=jwt-bearer&assertion=<signed_jwt>
4. Use token:  Authorization: Bearer <access_token>
```

```apex
Auth.JWT jwt = new Auth.JWT();
jwt.setIss(consumerKey);
jwt.setSub(username);
jwt.setAud('https://login.salesforce.com');

Auth.JWS jws = new Auth.JWS(jwt, 'MyCertificate');
String signedJwt = jws.getCompactSerialization();  // header.payload.signature
```

### 3. OAuth 2.0 Client Credentials (RFC 6749 §4.4)

```
POST /oauth/token
  grant_type=client_credentials
  &client_id=abc
  &client_secret=xyz
  → { "access_token": "...", "expires_in": 3600 }
```

Use for service-to-service (no user context). Cache the token; refresh when `isTokenExpiring()` returns true.

### 4. Token caching strategies

| Strategy | Scope | Notes |
|---|---|---|
| Platform Cache (`Cache.Org`) | Org-wide | Requires Platform Cache add-on; TTL auto-expiry |
| Custom Setting / CMDT | Org-wide | No add-on; manual expiry check; DML in same tx |
| Static variable | Transaction | Free; lost after tx ends; useful for burst dedup |

```apex
// Platform Cache pattern
private static String getCachedToken(String key) {
    String token = (String) Cache.Org.get('local.TokenCache.' + key);
    if (token == null) {
        JwtTokenService.TokenResponse resp = fetchNewToken();
        Cache.Org.put('local.TokenCache.' + key, resp.access_token, resp.expires_in - 60);
        token = resp.access_token;
    }
    return token;
}
```

---

## Testing Callouts

### Test.setMock pattern

```apex
@IsTest
static void myCalloutTest() {
    // 1. Register mock BEFORE startTest
    Test.setMock(HttpCalloutMock.class, new CalloutMocks.SingleResponse(200, body));

    Test.startTest();
    // 2. Call the method under test (callout is intercepted by mock)
    String result = ExternalApiClient.get('/path');
    Test.stopTest();

    // 3. Assert on the result
    System.assertNotEquals(null, result);
}
```

### HttpCalloutMock interface

```apex
public class MyMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
        HttpResponse resp = new HttpResponse();
        resp.setStatusCode(200);
        resp.setBody('{"id":"123"}');
        resp.setHeader('Content-Type', 'application/json');
        return resp;
    }
}
```

### Multi-response mock (routing by URL)

```apex
CalloutMocks.MultiEndpoint mock = new CalloutMocks.MultiEndpoint()
    .addResponse('/accounts', 200, accountJson)
    .addResponse('/token',    200, tokenJson)
    .setDefault(404, errorJson);
Test.setMock(HttpCalloutMock.class, mock);
```

### Sequential mock (for retry testing)

```apex
List<HttpResponse> seq = new List<HttpResponse>{
    CalloutMocks.buildResponse(500, errorJson),  // first call fails
    CalloutMocks.buildResponse(200, successJson) // retry succeeds
};
Test.setMock(HttpCalloutMock.class, new CalloutMocks.SequentialResponse(seq));
```

---

## External Services (Declarative)

External Services is a no-code/low-code feature for calling REST APIs from Flows and Process Builder.

**How it works:**
1. Upload an OpenAPI 2.0 or 3.0 spec in Setup → External Services
2. Salesforce generates invocable Apex and Flow actions automatically
3. Use the generated actions in Flows — no Apex coding required
4. Underlying implementation uses Named Credentials for auth

**When to use:**
- Simple CRUD integrations for business users via Flow
- Rapid prototyping without custom Apex
- When the external API has a complete OpenAPI spec

**When to use Apex callouts instead:**
- Custom error handling / retry logic
- Response transformation
- Bulk operations
- The API doesn't have an OpenAPI spec

---

## Interview Q&A

**Q: What are the governor limits for Apex callouts?**
> Max 100 callouts per transaction. Max timeout 120,000ms (2 minutes) per callout. Max body size 12MB. You cannot make a callout after a DML statement in the same transaction — use `@future(callout=true)` or Queueable with `Database.AllowsCallouts` to separate DML and callout contexts.

**Q: What is a Named Credential and why use one?**
> A Named Credential stores an endpoint URL and authentication details (credentials, OAuth tokens) encrypted in the platform. Benefits: (1) no Remote Site Setting needed, (2) auth headers injected automatically by the platform, (3) credentials never appear in code, (4) environment-specific endpoints managed via metadata deployment rather than code changes.

**Q: What is the difference between `callout:NC_Name` and specifying an endpoint directly?**
> `callout:NC_Name/path` resolves to the Named Credential's base URL + the path, with auth headers automatically injected. Direct endpoints (full URL) require a Remote Site Setting entry and you must manage auth headers manually. Named Credentials are the preferred approach for any integration with consistent auth.

**Q: How do you test Apex callouts?**
> Implement `HttpCalloutMock` and register it with `Test.setMock(HttpCalloutMock.class, mock)` before `Test.startTest()`. The mock intercepts the `Http.send()` call and returns the predefined response. Without `setMock`, Apex throws an exception in test context. Use multi-response mocks for endpoint routing and sequential mocks for retry testing.

**Q: How do you implement exponential back-off for retried callouts?**
> Apex has no `Thread.sleep()`, so true back-off requires Queueable job chaining. Each Queueable implements `Database.AllowsCallouts`, makes one callout, and if a retryable status is returned enqueues a new job instance with `attempt + 1`. For simple cases (short bursts), immediate retry is acceptable. The key distinction is between retryable errors (429, 5xx) and non-retryable ones (4xx except 429).

**Q: How does the JWT Bearer Token flow work?**
> You build a JWT with claims (iss=consumer key, sub=username, aud=token endpoint), sign it with a Salesforce-managed RSA private key using `Auth.JWS`, then POST the signed JWT to the token endpoint with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`. The server validates the signature using your app's registered public key and returns an access token. This allows Salesforce to authenticate as a specific user without storing their password.

**Q: Where should you store OAuth client secrets in Salesforce?**
> Never hard-code secrets in Apex. Options in order of preference: (1) Named Credential — platform stores and uses the secret automatically, never exposed to Apex; (2) Protected Custom Metadata (`Visibility=Protected`) — encrypted at rest, accessible to Apex but not directly visible in Setup; (3) Named Credential parameter — similar to option 1 but for manual scenarios. Avoid Custom Settings for secrets as they are not encrypted.

---

## Files Created

| File | Purpose |
|---|---|
| `namedCredentials/Demo_External_API.namedCredential-meta.xml` | NoAuthentication NC — callout demo target |
| `namedCredentials/Demo_OAuth_API.namedCredential-meta.xml` | OAuth NC structure reference |
| `classes/ExternalApiClient.cls` | GET/POST/PATCH/DELETE, Named Credential endpoint, retry on 429/5xx |
| `classes/JwtTokenService.cls` | JWT Bearer (`Auth.JWT`/`Auth.JWS`), OAuth Client Credentials, token expiry check |
| `classes/CalloutMocks.cls` | `HttpCalloutMock` implementations: Single, MultiEndpoint, Sequential |
| `classes/RestIntegrationTest.cls` | 20 tests — all HTTP methods, retry recovery, JSON parsing, auth |
