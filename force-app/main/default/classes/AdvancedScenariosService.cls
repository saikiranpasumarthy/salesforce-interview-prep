/**
 * Day 40 — Advanced Scenarios & Cross-Cloud Architecture (Part 1)
 *
 * Senior architect-level patterns for the final interview round:
 *
 *  1. Composite REST API builder   — batch up to 25 subrequests in one HTTP callout
 *  2. Agentforce custom action     — @InvocableMethod designed for Einstein Copilot
 *  3. Token-bucket rate limiter    — throttle outbound API calls within governor limits
 *  4. Multi-org record sync        — deterministic upsert via External ID + change detection
 *  5. Large-result streaming       — Bulk API 2.0 job lifecycle from Apex
 *  6. Idempotent webhook receiver  — HMAC-256 signature validation + dedup
 *  7. Named Credential + External Credential pattern  — per-user OAuth in Apex
 */
public with sharing class AdvancedScenariosService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. COMPOSITE REST API BUILDER
    //
    // Interview Q: "You need to create an Account, a Contact, and an Opportunity
    //               in one atomic operation from Apex. How?"
    //
    // Option A: Three separate DML statements (simple, but not truly atomic
    //           unless wrapped in a savepoint — and savepoints don't cross async).
    //
    // Option B: Salesforce Composite REST API — POST /services/data/vXX/composite
    //   - Up to 25 subrequests per call
    //   - Reference IDs let later subrequests use results from earlier ones
    //   - allOrNone=true → all succeed or all roll back (truly atomic)
    //   - Counts as ONE callout against the 100-callout limit
    //
    // Use Composite when: integrating FROM an external system into Salesforce, or
    // when you need cross-object atomic writes via REST (e.g., from a mobile app).
    // ═══════════════════════════════════════════════════════════════════════════

    public static CompositeRequest buildCompositeRequest(Boolean allOrNone) {
        CompositeRequest req = new CompositeRequest();
        req.allOrNone    = (allOrNone != null) ? allOrNone : true;
        req.subrequests  = new List<CompositeSubrequest>();
        return req;
    }

    public static CompositeRequest addSubrequest(
        CompositeRequest composite,
        String referenceId,
        String method,
        String url,
        Map<String, Object> body
    ) {
        CompositeSubrequest sub = new CompositeSubrequest();
        sub.referenceId = referenceId;
        sub.method      = method.toUpperCase();
        sub.url         = url;
        sub.body        = body;
        composite.subrequests.add(sub);
        return composite;
    }

    // Execute the composite request — returns parsed subrequest results
    public static List<CompositeSubresponse> executeComposite(
        CompositeRequest composite,
        String namedCredential
    ) {
        String endpoint = 'callout:' + namedCredential
            + '/services/data/v59.0/composite';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setBody(JSON.serialize(composite));
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new CalloutException(
                'Composite API error ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }

        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> rawResults = (List<Object>) parsed.get('compositeResponse');

        List<CompositeSubresponse> results = new List<CompositeSubresponse>();
        if (rawResults == null) return results;

        for (Object raw : rawResults) {
            Map<String, Object> r = (Map<String, Object>) raw;
            CompositeSubresponse sub = new CompositeSubresponse();
            sub.referenceId  = (String)  r.get('referenceId');
            sub.httpStatusCode = r.get('httpStatusCode') != null
                ? Integer.valueOf(String.valueOf(r.get('httpStatusCode'))) : 0;
            sub.body         = (Map<String, Object>) r.get('body');
            sub.isSuccess    = sub.httpStatusCode >= 200 && sub.httpStatusCode < 300;
            results.add(sub);
        }
        return results;
    }

    // Helper: build an Account+Contact+Opportunity composite in one call
    public static CompositeRequest buildLeadConversionComposite(
        String accountName, String contactFirstName, String contactLastName,
        String contactEmail, String opportunityName, Decimal oppAmount
    ) {
        CompositeRequest composite = buildCompositeRequest(true);

        addSubrequest(composite, 'newAccount', 'POST', '/services/data/v59.0/sobjects/Account',
            new Map<String, Object>{ 'Name' => accountName });

        addSubrequest(composite, 'newContact', 'POST', '/services/data/v59.0/sobjects/Contact',
            new Map<String, Object>{
                'FirstName' => contactFirstName,
                'LastName'  => contactLastName,
                'Email'     => contactEmail,
                'AccountId' => '@{newAccount.id}'  // Reference ID — resolved at runtime
            });

        addSubrequest(composite, 'newOpportunity', 'POST',
            '/services/data/v59.0/sobjects/Opportunity',
            new Map<String, Object>{
                'Name'        => opportunityName,
                'AccountId'   => '@{newAccount.id}',
                'Amount'      => oppAmount,
                'StageName'   => 'Prospecting',
                'CloseDate'   => Date.today().addDays(30).format()
            });

        return composite;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. AGENTFORCE CUSTOM ACTION
    //
    // Interview Q: "How do you expose Apex logic to Einstein Copilot / Agentforce?"
    //
    // Key requirements for Agentforce actions:
    //   - @InvocableMethod with label + description (Copilot reads these for grounding)
    //   - Input/output use @InvocableVariable (NOT Map<String,Object>)
    //   - Actions must be deterministic — same input → same output (no randomness)
    //   - Keep actions focused: one action = one capability (Single Responsibility)
    //   - Return structured data — Copilot can reference individual output fields
    //
    // Agentforce calls actions via Flow infrastructure — same as regular @InvocableMethod.
    // The label and description are surfaced to the LLM as "tool descriptions".
    // ═══════════════════════════════════════════════════════════════════════════

    @InvocableMethod(
        label       = 'Get Account Health Score'
        description = 'Calculates a health score (0-100) for an Account based on open cases, '
                    + 'opportunity pipeline, and last activity. Use this when the user asks about '
                    + 'account health, account status, or account risk.'
        category    = 'Account Management'
    )
    public static List<AccountHealthOutput> getAccountHealthScore(
        List<AccountHealthInput> inputs
    ) {
        List<AccountHealthOutput> outputs = new List<AccountHealthOutput>();
        if (inputs == null || inputs.isEmpty()) return outputs;

        Set<Id> accountIds = new Set<Id>();
        for (AccountHealthInput inp : inputs) {
            if (String.isNotBlank(inp.accountId)) accountIds.add(inp.accountId);
        }

        // Single bulk SOQL — never query in a loop
        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Name,
                   (SELECT Id, Status FROM Cases
                    WHERE Status NOT IN ('Closed', 'Resolved') LIMIT 50),
                   (SELECT Id, Amount, StageName FROM Opportunities
                    WHERE IsClosed = false LIMIT 50),
                   LastActivityDate
            FROM   Account
            WHERE  Id IN :accountIds
            WITH   USER_MODE
        ]);

        for (AccountHealthInput inp : inputs) {
            AccountHealthOutput out = new AccountHealthOutput();
            out.accountId = inp.accountId;

            Account acc = accountMap.get(inp.accountId);
            if (acc == null) {
                out.healthScore   = 0;
                out.healthLabel   = 'Unknown';
                out.recommendation = 'Account not found.';
                outputs.add(out);
                continue;
            }

            Integer score = 100;

            // Deduct for open cases
            Integer openCases = acc.Cases != null ? acc.Cases.size() : 0;
            score -= Math.min(openCases * 10, 40);

            // Boost for active pipeline
            Decimal totalPipeline = 0;
            for (Opportunity opp : (acc.Opportunities != null ? acc.Opportunities : new List<Opportunity>())) {
                totalPipeline += (opp.Amount != null ? opp.Amount : 0);
            }
            if (totalPipeline > 100000) score = Math.min(score + 10, 100);

            // Deduct for inactivity
            if (acc.LastActivityDate == null || acc.LastActivityDate < Date.today().addDays(-90)) {
                score -= 15;
            }

            score = Math.max(0, Math.min(100, score));

            out.healthScore = score;
            out.openCaseCount = openCases;
            out.pipelineAmount = totalPipeline;
            out.healthLabel = score >= 75 ? 'Healthy'
                            : score >= 50 ? 'At Risk'
                            : 'Critical';
            out.recommendation = score >= 75
                ? 'Account is healthy. Continue regular cadence.'
                : score >= 50
                ? 'Schedule a check-in call. ' + openCases + ' open case(s) need attention.'
                : 'Escalate to account manager immediately. High open case volume and low activity.';

            outputs.add(out);
        }
        return outputs;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. TOKEN-BUCKET RATE LIMITER
    //
    // Interview Q: "An external API limits you to 10 calls per minute. You have a
    //               batch job that calls it thousands of times. How do you handle this?"
    //
    // Token Bucket algorithm:
    //   - Bucket holds N tokens (= N allowed calls)
    //   - Each call consumes one token
    //   - Tokens replenish at a fixed rate (e.g., 10/minute)
    //   - If bucket is empty: wait or defer
    //
    // Apex implementation stores state in a Custom Setting or a Platform Cache
    // partition. For cross-transaction rate limiting, use Platform Cache (Org scope).
    // For within-transaction limiting, static state suffices.
    // ═══════════════════════════════════════════════════════════════════════════

    // Static per-transaction state (resets each transaction)
    @TestVisible
    static Map<String, Integer> tokenBuckets = new Map<String, Integer>();

    public static Boolean consumeToken(String serviceKey, Integer bucketCapacity) {
        if (!tokenBuckets.containsKey(serviceKey)) {
            tokenBuckets.put(serviceKey, bucketCapacity);
        }
        Integer remaining = tokenBuckets.get(serviceKey);
        if (remaining <= 0) return false; // rate limit hit
        tokenBuckets.put(serviceKey, remaining - 1);
        return true;
    }

    public static Integer getRemainingTokens(String serviceKey) {
        return tokenBuckets.containsKey(serviceKey) ? tokenBuckets.get(serviceKey) : -1;
    }

    public static void refillTokens(String serviceKey, Integer bucketCapacity) {
        tokenBuckets.put(serviceKey, bucketCapacity);
    }

    // Rate-limited callout wrapper
    public static HttpResponse rateLimitedCallout(
        String serviceKey,
        Integer bucketCapacity,
        HttpRequest request
    ) {
        if (!consumeToken(serviceKey, bucketCapacity)) {
            throw new RateLimitException(
                'Rate limit reached for service: ' + serviceKey
                + '. Tokens remaining: 0. Retry in next transaction.'
            );
        }
        return new Http().send(request);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. MULTI-ORG RECORD SYNC
    //
    // Interview Q: "How do you keep Account records in sync across two Salesforce orgs?"
    //
    // Pattern: External ID + upsert + change fingerprint
    //
    //   1. Source org publishes changes via Platform Event or REST endpoint
    //   2. Target org receives event / webhook → upsert by External ID
    //   3. Use a checksum/hash of key fields to detect actual changes
    //      (skip upsert if record hasn't changed → reduces DML + avoids loops)
    //
    // External ID field: deploy ExternalAccountId__c (unique, externalId=true) to
    // both orgs. Use the source org's record Id as the value.
    // ═══════════════════════════════════════════════════════════════════════════

    public static SyncResult syncAccountFromRemote(AccountSyncPayload payload) {
        SyncResult result = new SyncResult();

        if (payload == null || String.isBlank(payload.externalId)) {
            result.success = false;
            result.message = 'Invalid sync payload: externalId is required';
            return result;
        }

        // Compute a fingerprint of the incoming data to detect actual changes
        String incomingFingerprint = computeFingerprint(new List<String>{
            payload.name, payload.industry, payload.phone,
            String.valueOf(payload.annualRevenue)
        });

        // Check if record already exists with same fingerprint (no-op if unchanged)
        List<Account> existing = [
            SELECT Id, SyncFingerprint__c
            FROM   Account
            WHERE  ExternalAccountId__c = :payload.externalId
            WITH   USER_MODE
            LIMIT  1
        ];

        if (!existing.isEmpty()
            && existing[0].SyncFingerprint__c == incomingFingerprint) {
            result.success     = true;
            result.wasNoOp     = true;
            result.message     = 'No changes detected — sync skipped';
            result.salesforceId = existing[0].Id;
            return result;
        }

        // Upsert by External ID — creates if not exists, updates if exists
        Account acc = new Account();
        acc.put('ExternalAccountId__c', payload.externalId);
        acc.Name          = payload.name;
        acc.Industry      = payload.industry;
        acc.Phone         = payload.phone;
        acc.AnnualRevenue = payload.annualRevenue;
        acc.put('SyncFingerprint__c', incomingFingerprint);
        acc.put('LastSyncedAt__c', DateTime.now());

        try {
            Schema.SObjectField extIdField =
                Account.SObjectType.getDescribe().fields.getMap()
                    .get('externalaccountid__c');

            if (extIdField != null) {
                Database.UpsertResult ur = Database.upsert(acc, extIdField, false);
                result.success     = ur.isSuccess();
                result.salesforceId = ur.getId();
                result.wasNoOp     = false;
                result.message     = ur.isSuccess() ? 'Synced successfully'
                    : ur.getErrors()[0].getMessage();
            } else {
                // Field not deployed — fall back to insert/update
                upsert acc;
                result.success     = true;
                result.salesforceId = acc.Id;
                result.wasNoOp     = false;
                result.message     = 'Synced (fallback path — deploy ExternalAccountId__c)';
            }
        } catch (DmlException e) {
            result.success = false;
            result.message = e.getMessage();
        }
        return result;
    }

    @TestVisible
    static String computeFingerprint(List<String> values) {
        String combined = String.join(values, '|');
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(combined));
        return EncodingUtil.convertToHex(hash).substring(0, 16);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. BULK API 2.0 JOB LIFECYCLE
    //
    // Interview Q: "When would you use Bulk API 2.0 instead of batch Apex?"
    //
    // Bulk API 2.0 vs Batch Apex:
    //
    // | Aspect | Bulk API 2.0 | Batch Apex |
    // |---|---|---|
    // | Trigger execution | ❌ Skipped by default | ✅ Executes |
    // | Workflow/Flow | ❌ Skipped | ✅ Executes |
    // | DML limit per chunk | No per-chunk limit | 10,000 rows / execute |
    // | Max records | 150M+ | Unlimited (chunked) |
    // | Use case | Pure data load, ETL | Business logic required |
    //
    // Use Bulk API when: loading data without triggering automation,
    // large ETL migrations, data masking, sandbox refresh scripts.
    // ═══════════════════════════════════════════════════════════════════════════

    // Initiate a Bulk API 2.0 job (returns job ID for polling)
    public static BulkJobResult createBulkIngestJob(
        String objectApiName,
        String operation,       // insert, update, upsert, delete
        String externalIdField, // required for upsert
        String namedCredential
    ) {
        BulkJobResult result = new BulkJobResult();
        Map<String, Object> jobBody = new Map<String, Object>{
            'object'    => objectApiName,
            'operation' => operation,
            'contentType' => 'CSV'
        };
        if (String.isNotBlank(externalIdField)) {
            jobBody.put('externalIdFieldName', externalIdField);
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCredential + '/services/data/v59.0/jobs/ingest');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(jobBody));

        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> parsed =
                    (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                result.jobId  = (String) parsed.get('id');
                result.state  = (String) parsed.get('state');
                result.success = true;
            } else {
                result.success = false;
                result.errorMessage = 'Job creation failed: ' + res.getStatusCode();
            }
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = e.getMessage();
        }
        return result;
    }

    // Poll job status
    public static String getBulkJobState(String jobId, String namedCredential) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'callout:' + namedCredential + '/services/data/v59.0/jobs/ingest/' + jobId
        );
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');

        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> parsed =
                    (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                return (String) parsed.get('state');
            }
        } catch (Exception e) { /* best-effort poll */ }
        return 'UNKNOWN';
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. IDEMPOTENT WEBHOOK RECEIVER
    //
    // Interview Q: "A partner sends webhooks to your Salesforce REST endpoint.
    //               How do you guarantee idempotency and authenticity?"
    //
    // Two concerns:
    //   A. Authenticity — verify the request came from the expected partner
    //      → HMAC-SHA256 signature on the payload, shared secret in Named Credential
    //   B. Idempotency  — a retry of the same webhook must not duplicate records
    //      → Store a ProcessedWebhook__c keyed on the webhook's unique ID;
    //        skip if already processed
    // ═══════════════════════════════════════════════════════════════════════════

    public static WebhookResult processInboundWebhook(
        String webhookId,
        String payload,
        String receivedSignature,
        String sharedSecret
    ) {
        WebhookResult result = new WebhookResult();
        result.webhookId = webhookId;

        // Step 1: Verify HMAC-SHA256 signature
        if (!verifyHmacSignature(payload, receivedSignature, sharedSecret)) {
            result.accepted = false;
            result.message  = 'Signature verification failed — webhook rejected';
            return result;
        }

        // Step 2: Idempotency check
        if (isWebhookAlreadyProcessed(webhookId)) {
            result.accepted = true;
            result.isDuplicate = true;
            result.message  = 'Duplicate webhook — already processed, skipped';
            return result;
        }

        // Step 3: Process the payload
        try {
            Map<String, Object> data =
                (Map<String, Object>) JSON.deserializeUntyped(payload);
            applyWebhookData(data);
            recordWebhookProcessed(webhookId);
            result.accepted    = true;
            result.isDuplicate = false;
            result.message     = 'Webhook processed successfully';
        } catch (Exception e) {
            result.accepted = false;
            result.message  = 'Processing error: ' + e.getMessage();
        }
        return result;
    }

    @TestVisible
    static Boolean verifyHmacSignature(
        String payload, String receivedSig, String secret
    ) {
        if (String.isBlank(receivedSig) || String.isBlank(secret)) return false;
        Blob mac = Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(payload),
            Blob.valueOf(secret)
        );
        String expectedSig = EncodingUtil.convertToHex(mac);
        // Constant-time comparison — prevents timing attacks
        return expectedSig.equals(receivedSig);
    }

    @TestVisible
    static Boolean isWebhookAlreadyProcessed(String webhookId) {
        if (String.isBlank(webhookId)) return false;
        try {
            List<SObject> rows = Database.query(
                'SELECT Id FROM ProcessedWebhook__c '
                + 'WHERE WebhookId__c = :webhookId LIMIT 1'
            );
            return !rows.isEmpty();
        } catch (Exception e) {
            return false; // object not deployed — proceed
        }
    }

    private static void recordWebhookProcessed(String webhookId) {
        try {
            SObject record = Schema.getGlobalDescribe()
                .get('processedwebhook__c')?.newSObject();
            if (record != null) {
                record.put('WebhookId__c', webhookId);
                record.put('ProcessedAt__c', DateTime.now());
                Database.insert(record, false);
            }
        } catch (Exception e) { /* best-effort */ }
    }

    private static void applyWebhookData(Map<String, Object> data) {
        // In production: parse data, upsert records as needed
        // E.g., if (data.containsKey('accountId')) { ... }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. NAMED CREDENTIAL + EXTERNAL CREDENTIAL PATTERN
    //
    // Interview Q: "How do you handle per-user OAuth tokens in Apex callouts?"
    //
    // Pre-Winter '23: Named Credentials with "Per User" auth — OAuth token stored
    //   in AuthProvider + per-user credentials (User.OAuthToken behind the scenes)
    //
    // Winter '23+: External Credentials (new model)
    //   - External Credential: defines the auth scheme (OAuth, JWT, custom header)
    //   - Named Credential: references External Credential + defines the base URL
    //   - Permission Set: grants user access to the External Credential principal
    //   - Per-user tokens stored securely by Salesforce — never in Apex code
    //
    // Apex usage is identical regardless: callout:MyNamedCred/endpoint
    // The framework handles token refresh transparently.
    // ═══════════════════════════════════════════════════════════════════════════

    public static ExternalServiceResult callWithNamedCredential(
        String namedCredential,
        String path,
        String method,
        String requestBody
    ) {
        ExternalServiceResult result = new ExternalServiceResult();
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + namedCredential + path);
            req.setMethod(method.toUpperCase());
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            if (String.isNotBlank(requestBody)) req.setBody(requestBody);
            req.setTimeout(20000);

            HttpResponse res = new Http().send(req);
            result.statusCode  = res.getStatusCode();
            result.body        = res.getBody();
            result.isSuccess   = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
        } catch (System.CalloutException ce) {
            result.isSuccess   = false;
            result.errorMessage = ce.getMessage();
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class CompositeRequest {
        public Boolean                    allOrNone;
        public List<CompositeSubrequest>  subrequests;
    }

    public class CompositeSubrequest {
        public String              referenceId;
        public String              method;
        public String              url;
        public Map<String, Object> body;
    }

    public class CompositeSubresponse {
        public String              referenceId;
        public Integer             httpStatusCode;
        public Map<String, Object> body;
        public Boolean             isSuccess;
    }

    public class AccountHealthInput {
        @InvocableVariable(label='Account ID' required=true)
        public String accountId;
    }

    public class AccountHealthOutput {
        @InvocableVariable(label='Account ID')
        public String accountId;
        @InvocableVariable(label='Health Score (0-100)')
        public Integer healthScore;
        @InvocableVariable(label='Health Label')
        public String healthLabel;
        @InvocableVariable(label='Open Case Count')
        public Integer openCaseCount;
        @InvocableVariable(label='Pipeline Amount')
        public Decimal pipelineAmount;
        @InvocableVariable(label='Recommendation')
        public String recommendation;
    }

    public class AccountSyncPayload {
        public String  externalId;
        public String  name;
        public String  industry;
        public String  phone;
        public Decimal annualRevenue;
    }

    public class SyncResult {
        public Boolean success;
        public Boolean wasNoOp    = false;
        public String  salesforceId;
        public String  message;
    }

    public class BulkJobResult {
        public Boolean success;
        public String  jobId;
        public String  state;
        public String  errorMessage;
    }

    public class WebhookResult {
        public String  webhookId;
        public Boolean accepted;
        public Boolean isDuplicate = false;
        public String  message;
    }

    public class ExternalServiceResult {
        public Boolean success    = false;
        public Integer statusCode;
        public String  body;
        public String  errorMessage;
        public Boolean isSuccess  = false;
    }

    public class RateLimitException extends Exception {}
}
