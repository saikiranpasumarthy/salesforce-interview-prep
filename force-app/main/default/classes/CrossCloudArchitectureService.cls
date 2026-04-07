/**
 * Day 40 — Advanced Scenarios & Cross-Cloud Architecture (Part 2)
 *
 * Production patterns for cross-cloud integration design questions:
 *
 *  1. Marketing Cloud connector     — REST API data extension upsert
 *  2. Data Cloud activation handler — inbound segment activation webhook
 *  3. Revenue Cloud (CPQ) helpers   — quote pricing callback + approval routing
 *  4. Agentforce grounding data     — structured context for Einstein LLM actions
 *  5. MuleSoft request/response     — canonical message format + error envelope
 *  6. Tableau / CRM Analytics bridge— push dataset rows via Analytics REST API
 *  7. Offer negotiation Q&A data    — interview-ready system design answers as constants
 */
public with sharing class CrossCloudArchitectureService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. MARKETING CLOUD CONNECTOR — DATA EXTENSION UPSERT
    //
    // Interview Q: "How does Sales Cloud integrate with Marketing Cloud?"
    //
    // Three integration options:
    //
    //  A. Marketing Cloud Connect (native)
    //     - Syncs Leads, Contacts, Campaigns via configured Synchronized Data Sources
    //     - No Apex required; configured in MC Setup
    //     - Limitation: sync is near-real-time, not instant
    //
    //  B. Marketing Cloud REST API (Apex callout)
    //     - Full control: upsert DE rows, trigger journeys, fire transactional sends
    //     - Requires OAuth2 client credentials flow to get access token
    //
    //  C. Distributed Marketing (for Journey Builder from Sales/Service Cloud)
    //     - ConnectApi.MarketingCloud or Flow action to fire a Journey from Apex/Flow
    //
    // This implementation demonstrates Option B (REST API).
    // ═══════════════════════════════════════════════════════════════════════════

    // Step 1: Obtain MC OAuth2 access token (client credentials grant)
    public static String getMarketingCloudToken(String namedCredential) {
        HttpRequest req = new HttpRequest();
        // Named Credential stores client_id, client_secret, and MC auth URL
        req.setEndpoint('callout:' + namedCredential + '/v2/token');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, String>{
            'grant_type' => 'client_credentials'
            // client_id and client_secret come from Named Credential merge fields
        }));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new CalloutException('MC auth failed: ' + res.getStatusCode());
        }
        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) parsed.get('access_token');
    }

    // Step 2: Upsert a row into a Marketing Cloud Data Extension
    public static McUpsertResult upsertDataExtensionRow(
        String accessToken,
        String restBaseUrl,
        String dataExtensionKey,
        Map<String, String> rowValues
    ) {
        McUpsertResult result = new McUpsertResult();
        if (String.isBlank(accessToken) || String.isBlank(dataExtensionKey)) {
            result.success = false;
            result.message = 'accessToken and dataExtensionKey are required';
            return result;
        }

        List<Map<String, String>> keys   = new List<Map<String, String>>();
        List<Map<String, String>> values = new List<Map<String, String>>();

        for (String k : rowValues.keySet()) {
            Map<String, String> kv = new Map<String, String>{
                'Name'  => k,
                'Value' => rowValues.get(k)
            };
            values.add(kv);
        }

        Map<String, Object> body = new Map<String, Object>{
            'keys'   => keys,
            'values' => values
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(restBaseUrl + '/hub/v1/dataevents/key:'
            + EncodingUtil.urlEncode(dataExtensionKey, 'UTF-8') + '/rows');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(body));

        try {
            HttpResponse res = new Http().send(req);
            result.success = (res.getStatusCode() == 200 || res.getStatusCode() == 202);
            result.statusCode = res.getStatusCode();
            result.message = result.success ? 'Upserted' : 'MC DE upsert failed: ' + res.getBody();
        } catch (Exception e) {
            result.success = false;
            result.message = e.getMessage();
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. DATA CLOUD ACTIVATION HANDLER
    //
    // Interview Q: "How does Data Cloud push segment membership into Sales Cloud?"
    //
    // Data Cloud → Sales Cloud activation methods:
    //
    //  A. Related Object activation — writes to a custom object in Sales Cloud
    //     (segment membership → Contact attribute or custom object row)
    //
    //  B. Webhook activation — Data Cloud calls a Salesforce REST endpoint
    //     when segment membership changes
    //
    //  C. Streaming Insights — Data Cloud fires Platform Events into Sales Cloud
    //     for real-time action (e.g., update Contact field, trigger Flow)
    //
    // This implementation demonstrates Option B (webhook receiver).
    // ═══════════════════════════════════════════════════════════════════════════

    public static ActivationResult handleDataCloudActivation(
        String activationPayloadJson
    ) {
        ActivationResult result = new ActivationResult();
        if (String.isBlank(activationPayloadJson)) {
            result.success = false;
            result.message = 'Empty activation payload';
            return result;
        }

        DataCloudActivationPayload payload;
        try {
            payload = (DataCloudActivationPayload)
                JSON.deserialize(activationPayloadJson, DataCloudActivationPayload.class);
        } catch (JSONException e) {
            result.success = false;
            result.message = 'Malformed activation payload: ' + e.getMessage();
            return result;
        }

        if (payload.memberProfiles == null || payload.memberProfiles.isEmpty()) {
            result.success    = true;
            result.updatedCount = 0;
            result.message    = 'No member profiles in activation';
            return result;
        }

        // Collect contact emails from the activation payload
        Set<String> emails = new Set<String>();
        for (DataCloudMemberProfile mp : payload.memberProfiles) {
            if (String.isNotBlank(mp.email)) emails.add(mp.email.toLowerCase());
        }

        // Bulk lookup — single SOQL
        Map<String, Id> emailToContactId = new Map<String, Id>();
        for (Contact c : [
            SELECT Id, Email FROM Contact
            WHERE Email IN :emails WITH USER_MODE
        ]) {
            emailToContactId.put(c.Email.toLowerCase(), c.Id);
        }

        // Apply segment membership to matching Contacts
        List<Contact> toUpdate = new List<Contact>();
        for (DataCloudMemberProfile mp : payload.memberProfiles) {
            if (String.isBlank(mp.email)) continue;
            Id contactId = emailToContactId.get(mp.email.toLowerCase());
            if (contactId == null) continue;

            Contact c = new Contact(Id = contactId);
            // Write segment name to a custom field — e.g. DataCloudSegment__c
            c.put('DataCloudSegment__c',   payload.segmentName);
            c.put('SegmentMemberSince__c', DateTime.now());
            toUpdate.add(c);
        }

        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(toUpdate, false);
            for (Database.SaveResult sr : results) {
                if (sr.isSuccess()) result.updatedCount++;
                else                result.failureCount++;
            }
        }

        result.success = true;
        result.message = 'Activation applied: ' + result.updatedCount + ' contacts updated';
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. REVENUE CLOUD (CPQ) INTEGRATION HELPERS
    //
    // Interview Q: "How do you integrate CPQ quote approval with an external
    //               ERP system?"
    //
    // CPQ Quote lifecycle:
    //   Draft → Needs Approval → Approved → Contracted
    //
    // Common integration points:
    //   A. Quote Calculator Plugin — Apex class that plugs into CPQ pricing engine
    //      Implement SBQQ.QuoteCalculatorPlugin interface
    //   B. Approval callback — After CPQ approval, call ERP to reserve inventory
    //   C. Contract generation — SBQQ__Contract__c created → sync to ERP
    //
    // Quote Calculator Plugin (implement at design time — not runtime):
    //   global class MyCalculator implements SBQQ.QuoteCalculatorPlugin { ... }
    // ═══════════════════════════════════════════════════════════════════════════

    // Approval routing: determines which approval tier a CPQ quote requires
    public static QuoteApprovalResult routeQuoteForApproval(
        Id quoteId, Decimal totalAmount, String discountCategory
    ) {
        QuoteApprovalResult result = new QuoteApprovalResult();
        result.quoteId = quoteId;

        // Tiered approval thresholds (in production: read from Custom Metadata)
        if (totalAmount >= 500000 || 'STRATEGIC'.equalsIgnoreCase(discountCategory)) {
            result.approvalTier   = 'EXECUTIVE';
            result.requiredSigners = new List<String>{ 'VP_Sales', 'CFO' };
            result.slaHours       = 24;
        } else if (totalAmount >= 100000 || 'HIGH'.equalsIgnoreCase(discountCategory)) {
            result.approvalTier   = 'DIRECTOR';
            result.requiredSigners = new List<String>{ 'Director_Sales' };
            result.slaHours       = 8;
        } else if (totalAmount >= 25000) {
            result.approvalTier   = 'MANAGER';
            result.requiredSigners = new List<String>{ 'Sales_Manager' };
            result.slaHours       = 4;
        } else {
            result.approvalTier   = 'AUTO_APPROVE';
            result.requiredSigners = new List<String>();
            result.slaHours       = 0;
        }

        result.expiresAt = DateTime.now().addHours(result.slaHours);
        return result;
    }

    // Post-approval ERP notification — sync approved quote to order management
    public static ErpSyncResult notifyErpOfApprovedQuote(
        Id quoteId, String namedCredential
    ) {
        ErpSyncResult result = new ErpSyncResult();
        // In production: query SBQQ__Quote__c + SBQQ__QuoteLine__c, build payload
        // For this demo: minimal payload structure
        Map<String, Object> payload = new Map<String, Object>{
            'quoteId'    => (String) quoteId,
            'status'     => 'APPROVED',
            'approvedAt' => String.valueOf(DateTime.now()),
            'source'     => 'SalesforceRevCloud'
        };

        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + namedCredential + '/api/v1/quotes/approve');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(payload));
            req.setTimeout(15000);

            HttpResponse res = new Http().send(req);
            result.success    = res.getStatusCode() == 200 || res.getStatusCode() == 201;
            result.statusCode = res.getStatusCode();
            result.erpOrderId = result.success
                ? extractErpOrderId(res.getBody()) : null;
            result.message    = result.success ? 'ERP notified' : res.getBody();
        } catch (Exception e) {
            result.success  = false;
            result.message  = e.getMessage();
        }
        return result;
    }

    private static String extractErpOrderId(String responseBody) {
        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            return (String) parsed.get('orderId');
        } catch (Exception e) { return null; }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. AGENTFORCE GROUNDING DATA
    //
    // Interview Q: "How do you provide Agentforce with context about a specific
    //               record when it runs an action?"
    //
    // Grounding = providing the LLM with relevant record data so it can generate
    // accurate, record-specific responses without hallucinating.
    //
    // Pattern: @InvocableMethod that returns a structured "context string" which
    // Agentforce includes in its prompt as grounding context.
    //
    // Key design rules:
    //   - Keep grounding data concise — LLMs have context window limits
    //   - Structure as key-value pairs or natural language summaries
    //   - Exclude PII unless consent is established
    //   - Never include raw SOQL results — summarize them
    // ═══════════════════════════════════════════════════════════════════════════

    @InvocableMethod(
        label       = 'Get Account Context for Agentforce'
        description = 'Returns a structured context summary for an Account record. '
                    + 'Use this to ground Agentforce responses with current account data '
                    + 'before generating emails, summaries, or recommendations.'
        category    = 'Agentforce Grounding'
    )
    public static List<AgentContextOutput> getAccountContextForAgent(
        List<AgentContextInput> inputs
    ) {
        List<AgentContextOutput> outputs = new List<AgentContextOutput>();
        if (inputs == null) return outputs;

        Set<Id> accountIds = new Set<Id>();
        for (AgentContextInput inp : inputs) {
            if (String.isNotBlank(inp.accountId)) accountIds.add(inp.accountId);
        }

        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Name, Industry, AnnualRevenue, NumberOfEmployees,
                   BillingCity, BillingCountry, Type, OwnerId, Owner.Name,
                   (SELECT Id, StageName, Amount, CloseDate FROM Opportunities
                    WHERE IsClosed = false ORDER BY CloseDate ASC LIMIT 3),
                   (SELECT Id, Subject, Status, CreatedDate FROM Cases
                    WHERE Status NOT IN ('Closed','Resolved')
                    ORDER BY CreatedDate DESC LIMIT 3)
            FROM   Account
            WHERE  Id IN :accountIds
            WITH   USER_MODE
        ]);

        for (AgentContextInput inp : inputs) {
            AgentContextOutput out = new AgentContextOutput();
            out.accountId = inp.accountId;

            Account acc = accounts.get(inp.accountId);
            if (acc == null) {
                out.contextSummary = 'No account data available for Id: ' + inp.accountId;
                outputs.add(out);
                continue;
            }

            List<String> lines = new List<String>{
                'Account: ' + acc.Name,
                'Industry: ' + (acc.Industry ?? 'Unknown'),
                'Type: ' + (acc.Type ?? 'Unknown'),
                'Location: ' + (acc.BillingCity ?? '') + ', ' + (acc.BillingCountry ?? ''),
                'Owner: ' + (acc.Owner?.Name ?? 'Unassigned')
            };

            if (acc.AnnualRevenue != null) {
                lines.add('Annual Revenue: $' + acc.AnnualRevenue.format());
            }

            if (acc.Opportunities != null && !acc.Opportunities.isEmpty()) {
                lines.add('Open Opportunities (' + acc.Opportunities.size() + '):');
                for (Opportunity opp : acc.Opportunities) {
                    lines.add('  - ' + opp.StageName + ': $'
                        + (opp.Amount != null ? opp.Amount.format() : '0')
                        + ' (closes ' + opp.CloseDate?.format() + ')');
                }
            }

            if (acc.Cases != null && !acc.Cases.isEmpty()) {
                lines.add('Open Cases (' + acc.Cases.size() + '):');
                for (Case c : acc.Cases) {
                    lines.add('  - [' + c.Status + '] ' + c.Subject);
                }
            }

            out.contextSummary = String.join(lines, '\n');
            outputs.add(out);
        }
        return outputs;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. MULESOFT CANONICAL MESSAGE FORMAT
    //
    // Interview Q: "How do you structure Apex integration with MuleSoft?"
    //
    // MuleSoft best practices from Salesforce side:
    //   - Define canonical request/response DTOs in Apex
    //   - MuleSoft calls Apex REST or Named Credential endpoint
    //   - Use correlation ID for distributed tracing (same as Day 36)
    //   - Error envelope: standard shape so MuleSoft can parse any failure
    //   - Version the API: /v1/, /v2/ in endpoint path
    //
    // Canonical error envelope (every error response has this shape):
    //   { "success": false, "correlationId": "...", "errorCode": "...",
    //     "errorMessage": "...", "timestamp": "..." }
    // ═══════════════════════════════════════════════════════════════════════════

    public static String buildCanonicalSuccessResponse(
        String correlationId, Object data
    ) {
        return JSON.serialize(new Map<String, Object>{
            'success'       => true,
            'correlationId' => correlationId,
            'timestamp'     => String.valueOf(DateTime.now()),
            'data'          => data
        });
    }

    public static String buildCanonicalErrorResponse(
        String correlationId, String errorCode, String errorMessage
    ) {
        return JSON.serialize(new Map<String, Object>{
            'success'       => false,
            'correlationId' => correlationId,
            'errorCode'     => errorCode,
            'errorMessage'  => errorMessage,
            'timestamp'     => String.valueOf(DateTime.now())
        });
    }

    // Standard error codes (interviewers expect you to have a taxonomy)
    public enum IntegrationErrorCode {
        VALIDATION_ERROR,      // 400 — bad input
        AUTH_ERROR,            // 401/403 — credentials/permissions
        NOT_FOUND,             // 404 — record doesn't exist
        RATE_LIMIT_EXCEEDED,   // 429 — too many calls
        TIMEOUT,               // 408/504 — upstream timeout
        UPSTREAM_ERROR,        // 5xx — MuleSoft / external system error
        INTERNAL_ERROR         // unexpected Apex exception
    }

    public static String errorCodeToHttpStatus(IntegrationErrorCode code) {
        Map<IntegrationErrorCode, String> mapping = new Map<IntegrationErrorCode, String>{
            IntegrationErrorCode.VALIDATION_ERROR    => '400',
            IntegrationErrorCode.AUTH_ERROR          => '401',
            IntegrationErrorCode.NOT_FOUND           => '404',
            IntegrationErrorCode.RATE_LIMIT_EXCEEDED => '429',
            IntegrationErrorCode.TIMEOUT             => '408',
            IntegrationErrorCode.UPSTREAM_ERROR      => '502',
            IntegrationErrorCode.INTERNAL_ERROR      => '500'
        };
        return mapping.get(code);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. CRM ANALYTICS / TABLEAU BRIDGE
    //
    // Interview Q: "How do you push data from Apex into CRM Analytics?"
    //
    // Two paths:
    //
    //  A. External Data API (REST) — POST CSV/JSON rows to a dataset
    //     Used for external data not in Salesforce (financial data, ERP data)
    //
    //  B. Live Dataset — CRM Analytics queries Salesforce objects directly via
    //     dataflow/recipe — no Apex required
    //
    //  C. Analytics REST API from Apex — query lens/dashboard, get results
    //     Used to surface analytics data in Apex logic or Flows
    //
    // This demonstrates Option A (push rows to an Analytics dataset).
    // ═══════════════════════════════════════════════════════════════════════════

    public static AnalyticsUploadResult pushRowsToAnalyticsDataset(
        String datasetApiName,
        List<Map<String, Object>> rows,
        String namedCredential
    ) {
        AnalyticsUploadResult result = new AnalyticsUploadResult();
        if (rows == null || rows.isEmpty()) {
            result.success = false;
            result.message = 'No rows to push';
            return result;
        }

        // Step 1: Create an upload job
        Map<String, Object> jobBody = new Map<String, Object>{
            'edgemartAlias'  => datasetApiName,
            'operation'      => 'Upsert',
            'notificationSent' => 'Never'
        };

        try {
            HttpRequest createReq = new HttpRequest();
            createReq.setEndpoint('callout:' + namedCredential
                + '/services/data/v59.0/wave/dataConnectors');
            createReq.setMethod('POST');
            createReq.setHeader('Content-Type', 'application/json');
            createReq.setBody(JSON.serialize(jobBody));

            HttpResponse createRes = new Http().send(createReq);
            if (createRes.getStatusCode() != 200 && createRes.getStatusCode() != 201) {
                result.success = false;
                result.message = 'Failed to create analytics job: ' + createRes.getStatusCode();
                return result;
            }

            Map<String, Object> jobResp =
                (Map<String, Object>) JSON.deserializeUntyped(createRes.getBody());
            result.jobId  = (String) jobResp.get('id');
            result.success = true;
            result.rowsSubmitted = rows.size();
            result.message = 'Analytics upload job created: ' + result.jobId;

        } catch (Exception e) {
            result.success = false;
            result.message = e.getMessage();
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class McUpsertResult {
        public Boolean success;
        public Integer statusCode;
        public String  message;
    }

    public class DataCloudActivationPayload {
        public String                   segmentName;
        public String                   activationType;
        public List<DataCloudMemberProfile> memberProfiles;
    }

    public class DataCloudMemberProfile {
        public String email;
        public String individualId;
        public Map<String, String> attributes;
    }

    public class ActivationResult {
        public Boolean success;
        public Integer updatedCount = 0;
        public Integer failureCount = 0;
        public String  message;
    }

    public class QuoteApprovalResult {
        public Id          quoteId;
        public String      approvalTier;
        public List<String> requiredSigners;
        public Integer     slaHours;
        public DateTime    expiresAt;
    }

    public class ErpSyncResult {
        public Boolean success;
        public Integer statusCode;
        public String  erpOrderId;
        public String  message;
    }

    public class AgentContextInput {
        @InvocableVariable(label='Account ID' required=true)
        public String accountId;
    }

    public class AgentContextOutput {
        @InvocableVariable(label='Account ID')
        public String accountId;
        @InvocableVariable(label='Context Summary for Einstein')
        public String contextSummary;
    }

    public class AnalyticsUploadResult {
        public Boolean success;
        public String  jobId;
        public Integer rowsSubmitted = 0;
        public String  message;
    }
}
