# Day 25 — Security Architecture, OAuth Flows, Shield & Event Monitoring

## OAuth 2.0 Flow Comparison (complete reference)

| Flow | Grant Type | User interaction | Use case |
|---|---|---|---|
| **Authorization Code** | `code` | Browser redirect | Server-side web apps (secure, refresh token issued) |
| **Auth Code + PKCE** | `code` + `code_challenge` | Browser redirect | SPA, mobile, CLI — no client secret stored |
| **Client Credentials** | `client_credentials` | None | Machine-to-machine, no user context |
| **JWT Bearer** (RFC 7523) | `urn:ietf:params:oauth:grant-type:jwt-bearer` | None | Server-to-server with pre-authorised service user |
| **Device Flow** | `device_code` | Out-of-band code | IoT devices, headless CLI (no browser) |
| **Implicit** | `token` | Browser redirect | DEPRECATED — replaced by Auth Code + PKCE |
| **Refresh Token** | `refresh_token` | None | Long-lived access without re-auth |

### Authorization Code + PKCE (RFC 7636) — the modern default

```
1. App generates:
   code_verifier  = BASE64URL(random 32 bytes)
   code_challenge = BASE64URL(SHA-256(code_verifier))

2. Redirect user to /authorize:
   ?response_type=code
   &client_id=<consumer_key>
   &redirect_uri=<callback>
   &code_challenge=<hash>
   &code_challenge_method=S256
   &state=<random_csrf_token>

3. User authenticates, auth server returns ?code=<auth_code>&state=<same_state>

4. Validate state matches stored value (CSRF check)

5. Exchange code for tokens:
   POST /token
   grant_type=authorization_code
   &code=<auth_code>
   &code_verifier=<original_verifier>   ← never sent to browser
   &redirect_uri=<same_callback>

6. Auth server verifies: SHA-256(code_verifier) == stored code_challenge → issues tokens
```

**Why PKCE prevents auth code interception:**
An attacker intercepts the auth code (e.g. malicious app registered for the redirect URI) but cannot exchange it — they never had the `code_verifier`.

---

## Shield Platform Encryption

### Probabilistic vs Deterministic

| | Probabilistic | Deterministic |
|---|---|---|
| Same plaintext → same ciphertext? | No (random IV) | Yes |
| Searchable in SOQL WHERE? | ❌ No | ✅ Yes |
| Sortable / ORDER BY? | ❌ No | ✅ Yes |
| Security strength | Stronger | Slightly weaker (frequency analysis) |
| Use for | Highly sensitive PII (SSN, card numbers) | Searchable fields (email, ext ID) |

### Key hierarchy
```
Salesforce Key Management Service
  └── Tenant Secret (customer-controlled, rotatable)
        └── Master Encryption Key (Salesforce-managed)
              └── Data Encryption Key (per-record, per-field)
```
Customer controls the Tenant Secret — Salesforce cannot decrypt data if the tenant secret is revoked (HSM-backed option available).

### Fields NOT encryptable with Shield
- Formula fields (computed at read time — no storage to encrypt)
- Lookup filter values
- URL fields used in Salesforce UI navigation
- Certain standard fields (varies by object)

### Impact on Apex
```apex
// Probabilistic encrypted field — cannot filter
SELECT Id FROM Contact WHERE SSN__c = :ssn  // throws exception

// Deterministic encrypted field — can filter
SELECT Id FROM Contact WHERE Email__c = :email  // works — same ciphertext for same value

// Decrypt in Apex — platform decrypts transparently on read
Contact c = [SELECT SSN__c FROM Contact WHERE Id = :id];
String ssn = c.SSN__c;  // value is decrypted automatically for entitled users
```

---

## Apex Crypto Patterns

### AES-256 Encryption (symmetric)
```apex
Blob key        = Crypto.generateAesKey(256);           // 32 bytes; store in Protected CMDT
Blob ciphertext = Crypto.encryptWithManagedIV('AES256', key, Blob.valueOf(plaintext));
Blob decrypted  = Crypto.decryptWithManagedIV('AES256', key, ciphertext);
String result   = decrypted.toString();
```
`ManagedIV` = platform generates random IV and prepends to ciphertext.
Same plaintext → different ciphertext each call (probabilistic).

### SHA-256 Hashing (one-way)
```apex
Blob   hash    = Crypto.generateDigest('SHA-256', Blob.valueOf(input));
String hexHash = EncodingUtil.convertToHex(hash);  // 64-char hex string
```

### HMAC-SHA256 (integrity + authenticity)
```apex
Blob   mac    = Crypto.generateMac('HmacSHA256', Blob.valueOf(message), secretKey);
String macHex = EncodingUtil.convertToHex(mac);
// Verify: recompute and compare with .equals() not ==
```

### RSA-SHA256 Signing
```apex
Blob signature = Crypto.sign('RSA-SHA256', Blob.valueOf(data), privateKeyBlob);
// Verification requires Crypto.verify() — throws SecurityException on failure
```

### Algorithm strings reference
| Operation | Algorithm parameter |
|---|---|
| AES | `'AES128'` / `'AES192'` / `'AES256'` |
| Hash | `'SHA-256'` / `'SHA-512'` / `'SHA1'` / `'MD5'` |
| HMAC | `'HmacSHA256'` / `'HmacSHA512'` / `'HmacSHA1'` |
| Sign | `'RSA-SHA256'` / `'RSA-SHA512'` / `'ECDSA-SHA256'` |

---

## Event Monitoring

### EventLogFile sObject
```apex
// Query available event types for today
List<EventLogFile> files = [
    SELECT Id, EventType, LogDate, LogFileLength
    FROM   EventLogFile
    WHERE  LogDate = TODAY
    ORDER BY EventType
];

// Parse CSV content
String csv = elf.LogFile.toString();
// First row: column headers; subsequent rows: one event per row
```

### Key event types for security monitoring
| EventType | What it tracks |
|---|---|
| `Login` | All login attempts; fields: USERNAME, LOGIN_STATUS, SOURCE_IP |
| `Logout` | Session ends |
| `API` | All REST/SOAP calls; fields: URI, HTTP_METHOD, USER_AGENT |
| `ApexCallout` | Outbound HTTP from Apex; fields: URL, STATUS_CODE |
| `Report` | Report runs / exports; high volume = exfiltration indicator |
| `ListViewExport` | List view data exports |
| `BulkApi` | Bulk API jobs — large data movements |

### Shield Threat Detection sObjects
```apex
// Credential stuffing — high login failure rate from same IP
List<CredentialStuffingEventStore> threats = [
    SELECT Username, SourceIp, Score, EventDate
    FROM   CredentialStuffingEventStore
    WHERE  Score >= 70
    ORDER BY Score DESC
];
// Score range: 0-100. >= 70 typically warrants investigation.
```

### Permission required
```
Profile: API Enabled + View Event Log Files
→ Standard: 1-day retention
→ Event Monitoring add-on: 30-day retention + real-time streaming
```

---

## Transaction Security Policies

Apex-based real-time security conditions evaluated as events occur.

```apex
// Implement the interface in a global Apex class
global class BlockLargeDataExport implements TxnSecurity.PolicyCondition {
    public Boolean evaluate(TxnSecurity.Event event) {
        // Access TxnSecurity.Event fields: userId, entityName, data
        String userId = event.userId;
        Map<String, String> data = event.data;
        Integer rowCount = Integer.valueOf(data.get('RowCount') ?? '0');
        // Return true to BLOCK the action
        return rowCount > 50000;
    }
}
```

**Actions available:** Block, Notify admin (email), End session, Log to EventLogFile.

**Use cases:**
- Block logins from non-corporate IP ranges
- Block report exports > N rows for non-admin users
- Block API calls outside business hours from service accounts
- Notify on login from new country

**Setup:** Setup → Security → Transaction Security → New Policy → select event type → link to Apex class.

---

## Org Security Health Check

Setup → Security → Health Check — scores org configuration against Salesforce Baseline Standard:

| Category | What is checked |
|---|---|
| Password policies | Minimum length, complexity, expiry |
| Session settings | Timeout duration, clickjack protection, HTTPS |
| Network access | Trusted IP ranges, login IP restrictions |
| Login flows | Multi-Factor Authentication enforcement |
| Certificate settings | Valid certificates for outbound TLS |

```apex
// Health Check score is not queryable via Apex — UI only
// HealthCheck sObject does exist but only via Tooling API
// Tooling: GET /services/data/v63.0/tooling/query?q=SELECT Score FROM HealthCheck
```

---

## Key Classes (Day 25)

| Class | Responsibility |
|---|---|
| `ShieldEncryptionService` | AES-256 encrypt/decrypt, SHA-256, HMAC-SHA256, RSA sign, PKCE generation, OAuth state |
| `EventMonitoringService` | EventLogFile queries, CSV parsing, high-frequency login detection, large export detection, Shield threat events |
| `SecurityArchitectureTest` | 30 tests — crypto round-trips, HMAC verification, PKCE RFC 7636 compliance, CSV parsing edge cases |
| `SecurityService` (Day 14) | CRUD/FLS enforcement, Security.stripInaccessible(), Apex sharing |
| `JwtTokenService` (Day 16) | JWT Bearer + Client Credentials OAuth flows |

---

## Quick-Reference: Interview Answers

**"When do you use PKCE vs Client Credentials?"**
> PKCE is for public clients — mobile apps, SPAs, CLI tools — where a client secret cannot be stored securely (any user can decompile the app and extract it). PKCE uses a one-time verifier/challenge pair so even if the auth code is intercepted, it cannot be exchanged. Client Credentials is for server-side machine-to-machine flows where there IS a secure server environment to store the secret.

**"What is the difference between Shield Platform Encryption and Apex Crypto?"**
> Shield encrypts field values at rest in the Salesforce database — it's platform-managed, transparent to SOQL (for deterministic mode), and uses a customer-controlled key hierarchy. Apex Crypto is developer-managed encryption in code — used for encrypting data in transit, signing payloads, webhook verification. They solve different problems: Shield = storage security, Crypto = application-level security.

**"How do you detect credential stuffing in Salesforce?"**
> Two approaches: (1) Event Monitoring — query the Login EventLogFile, count LOGIN_STATUS failures by SOURCE_IP and USERNAME; flag IPs/users above a threshold. (2) Shield Threat Detection — CredentialStuffingEventStore is an ML-scored sObject updated in near real-time by Shield; query Score >= 70 for high-confidence detections. Combine with a Transaction Security Policy to block logins from flagged IPs automatically.
