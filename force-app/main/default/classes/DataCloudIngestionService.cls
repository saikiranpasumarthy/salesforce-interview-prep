/**
 * @description Salesforce Data Cloud (CDP) — Streaming Ingestion API, batch ingestion
 *              patterns, data stream management, and payload construction.
 *
 *              DATA CLOUD ARCHITECTURE (interview framework):
 *
 *              Data Sources
 *                ├── Salesforce CRM Connector  — real-time sync (Contact, Lead, Account...)
 *                ├── Marketing Cloud Connector — MC subscriber/journey data
 *                ├── Streaming Ingestion API   — real-time events via HTTP POST
 *                ├── Batch / File Ingestion    — CSV/JSON via S3, SFTP, or Bulk API
 *                └── External Connectors       — MuleSoft, S3, Azure, Snowflake
 *                         ↓
 *              Data Lake Objects (DLO)        — raw ingested data (as-is from source)
 *                         ↓
 *              Data Mapping / Transformation  — field-level mapping to canonical model
 *                         ↓
 *              Data Model Objects (DMO)       — standardised canonical objects
 *                ├── Individual               — people/customers
 *                ├── ContactPointEmail        — email addresses
 *                ├── ContactPointPhone        — phone numbers
 *                ├── SalesOrder               — purchase data
 *                └── UnifiedIndividual        — merged profile (after Identity Resolution)
 *                         ↓
 *              Identity Resolution            — matching rules + reconciliation rules
 *                         ↓
 *              Unified Profile                — single customer view
 *
 *              STREAMING INGESTION API:
 *                Endpoint: POST /api/v1/ingest/sources/{sourceApiName}/{objectApiName}
 *                Auth:     OAuth 2.0 Bearer (Data Cloud Connected App)
 *                Body:     { "data": [ {...}, {...} ] }  — max 200 records / request
 *                Headers:  Content-Type: application/json
 *
 *              NAMED CREDENTIAL PATTERN:
 *                Named Credential: DataCloud_Org
 *                  → stores Data Cloud instance URL + OAuth token handling
 *                  → endpoint: callout:DataCloud_Org/api/v1/ingest/sources/...
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class DataCloudIngestionService {

    // Max records per Streaming Ingestion API request
    @TestVisible static final Integer MAX_RECORDS_PER_REQUEST = 200;

    // Named Credential developer name for Data Cloud connection
    @TestVisible static String DATA_CLOUD_NC = 'DataCloud_Org';

    // Test injection: mock HTTP responses
    @TestVisible static HttpCalloutMock calloutMock;

    // ─── Streaming Ingestion ──────────────────────────────────────────────────

    /**
     * Sends CRM Account updates to Data Cloud via the Streaming Ingestion API.
     * Auto-chunks into 200-record batches to respect API limits.
     *
     * Interview: Streaming Ingestion API is the recommended pattern for
     * near-real-time CRM → Data Cloud sync. It is event-driven and does not
     * require a batch schedule. Records are processed within seconds.
     *
     * Payload structure:
     * {
     *   "data": [
     *     { "AccountId__c": "001xx...", "Name__c": "Acme", "AnnualRevenue__c": 500000 }
     *   ]
     * }
     *
     * Source API Name: the Data Stream's source configuration name in Data Cloud
     * Object API Name: the DLO (Data Lake Object) API name for this data stream
     *
     * @param accounts       Accounts to stream to Data Cloud
     * @param sourceApiName  Data Stream source API name
     * @param objectApiName  Data Lake Object API name
     * @return               List of IngestionResult per batch chunk
     */
    public static List<IngestionResult> streamAccounts(
            List<Account> accounts, String sourceApiName, String objectApiName) {

        List<IngestionResult> results = new List<IngestionResult>();
        if (accounts == null || accounts.isEmpty()) { return results; }

        // Build record payloads
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Account acc : accounts) {
            Map<String, Object> record = new Map<String, Object>{
                'AccountId__c'       => String.valueOf(acc.Id),
                'Name__c'            => acc.Name,
                'Industry__c'        => acc.Industry,
                'AnnualRevenue__c'   => acc.AnnualRevenue,
                'NumberOfEmployees__c'=> acc.NumberOfEmployees,
                'BillingCity__c'     => acc.BillingCity,
                'BillingCountry__c'  => acc.BillingCountry,
                'Type__c'            => acc.Type,
                'LastModifiedDate__c'=> acc.LastModifiedDate != null
                    ? acc.LastModifiedDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : null
            };
            records.add(record);
        }

        // Chunk and send
        for (Integer offset = 0; offset < records.size(); offset += MAX_RECORDS_PER_REQUEST) {
            Integer end = Math.min(offset + MAX_RECORDS_PER_REQUEST, records.size());
            List<Map<String, Object>> chunk = new List<Map<String, Object>>();
            for (Integer i = offset; i < end; i++) { chunk.add(records[i]); }
            results.add(sendIngestionRequest(chunk, sourceApiName, objectApiName));
        }
        return results;
    }

    /**
     * Streams Contact interaction events (e.g. email open, web visit) to Data Cloud.
     * Used to build behavioural profiles for personalisation.
     *
     * Interview: Behavioural events are the primary use case for Streaming Ingestion.
     * Unlike CRM sync (which uses the Salesforce Connector), behavioural events
     * are typically streamed in real-time as they occur.
     *
     * Event schema maps to a custom DLO in Data Cloud (e.g. Engagement__dlm).
     *
     * @param events         List of interaction event DTOs
     * @param sourceApiName  Data Stream source API name
     * @return               Ingestion result
     */
    public static IngestionResult streamInteractionEvents(
            List<InteractionEvent> events, String sourceApiName) {

        if (events == null || events.isEmpty()) {
            return new IngestionResult(false, 0, 'No events to stream.');
        }

        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (InteractionEvent evt : events) {
            records.add(new Map<String, Object>{
                'EventId__c'          => evt.eventId,
                'IndividualId__c'     => evt.individualId,
                'EventType__c'        => evt.eventType,
                'EventDateTime__c'    => evt.eventDateTime != null
                    ? evt.eventDateTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : null,
                'ChannelType__c'      => evt.channelType,
                'EngagementScore__c'  => evt.engagementScore,
                'SourceSystem__c'     => 'Salesforce'
            });
        }

        // Single batch (caller responsible for chunking if > 200)
        List<Map<String, Object>> batch = records.size() > MAX_RECORDS_PER_REQUEST
            ? records.subList(0, MAX_RECORDS_PER_REQUEST) : records;

        return sendIngestionRequest(batch, sourceApiName, 'Engagement__dlm');
    }

    /**
     * Sends a delete request to Data Cloud — removes records from a DLO by primary key.
     *
     * Interview: Data Cloud Ingestion API supports upsert (default) and delete.
     * To delete: POST with the same endpoint but include only primary key fields.
     * Used for GDPR/CCPA right-to-erasure compliance (Right to be Forgotten).
     *
     * @param primaryKeys    Map of {primaryKeyField → value} for records to delete
     * @param sourceApiName  Data Stream source name
     * @param objectApiName  DLO API name
     * @return               Ingestion result
     */
    public static IngestionResult deleteRecords(
            List<Map<String, String>> primaryKeys,
            String sourceApiName, String objectApiName) {

        if (primaryKeys == null || primaryKeys.isEmpty()) {
            return new IngestionResult(false, 0, 'No records to delete.');
        }

        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Map<String, String> pk : primaryKeys) {
            Map<String, Object> record = new Map<String, Object>(pk);
            records.add(record);
        }

        // Deletion uses same endpoint but records contain only primary keys
        return sendIngestionRequest(records, sourceApiName, objectApiName + '?operation=delete');
    }

    // ─── HTTP request builder ─────────────────────────────────────────────────

    /**
     * Constructs and sends the Streaming Ingestion API HTTP request.
     *
     * Interview: Data Cloud Ingestion API endpoint pattern:
     *   POST callout:DataCloud_Org/api/v1/ingest/sources/{sourceApiName}/{objectApiName}
     *
     * Response codes:
     *   202 Accepted  — records queued for processing (async)
     *   400 Bad Request — schema validation failed
     *   401 Unauthorized — invalid/expired OAuth token
     *   429 Too Many Requests — rate limit exceeded (retry with backoff)
     *
     * Note: 202 is a SUCCESS response for ingestion — records are processed async.
     * Do not expect 200 OK.
     *
     * @param records       Serialised record payloads
     * @param sourceApiName Data Stream source API name
     * @param objectApiName DLO API name (may include query params for delete)
     * @return              IngestionResult with status and record count
     */
    @TestVisible
    static IngestionResult sendIngestionRequest(
            List<Map<String, Object>> records,
            String sourceApiName, String objectApiName) {

        try {
            Map<String, Object> body = new Map<String, Object>{ 'data' => records };
            String jsonBody = JSON.serialize(body);

            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + DATA_CLOUD_NC
                + '/api/v1/ingest/sources/' + sourceApiName + '/' + objectApiName);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setBody(jsonBody);
            req.setTimeout(30000); // 30s

            Http http = new Http();
            HttpResponse resp = (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req)
                : http.send(req);

            Integer statusCode = resp.getStatusCode();

            // 202 = accepted for async processing (success for ingestion API)
            if (statusCode == 202 || statusCode == 200) {
                return new IngestionResult(true, records.size(), null);
            }

            // Parse error detail from response
            String errorDetail = extractErrorMessage(resp.getBody());
            return new IngestionResult(false, 0,
                'HTTP ' + statusCode + ': ' + errorDetail);

        } catch (Exception e) {
            return new IngestionResult(false, 0, 'Ingestion request failed: ' + e.getMessage());
        }
    }

    // ─── Payload validation ────────────────────────────────────────────────────

    /**
     * Validates that a record payload contains all required fields for a DLO.
     * Called before streaming to catch schema errors before the API call.
     *
     * Interview: Data Cloud will reject (400) any record missing required fields
     * or containing fields not in the DLO schema. Validate first to avoid
     * partial-batch failures.
     *
     * @param record         Record payload to validate
     * @param requiredFields Set of field API names that must be present + non-null
     * @return               List of missing/null field names; empty = valid
     */
    @TestVisible
    static List<String> validateRecordPayload(
            Map<String, Object> record, Set<String> requiredFields) {

        List<String> errors = new List<String>();
        if (record == null) { errors.add('Record payload is null'); return errors; }

        for (String field : requiredFields) {
            if (!record.containsKey(field) || record.get(field) == null) {
                errors.add('Missing required field: ' + field);
            }
        }
        return errors;
    }

    /**
     * Builds a batch of validated record payloads, filtering out invalid records
     * and collecting validation errors without failing the entire batch.
     *
     * @param rawRecords     Raw payload maps
     * @param requiredFields Required field set
     * @return               BatchValidationResult with valid records + error details
     */
    public static BatchValidationResult validateBatch(
            List<Map<String, Object>> rawRecords, Set<String> requiredFields) {

        BatchValidationResult result = new BatchValidationResult();
        if (rawRecords == null) { return result; }

        for (Integer i = 0; i < rawRecords.size(); i++) {
            List<String> errors = validateRecordPayload(rawRecords[i], requiredFields);
            if (errors.isEmpty()) {
                result.validRecords.add(rawRecords[i]);
            } else {
                result.errorDetails.add('Record[' + i + ']: ' + String.join(errors, '; '));
            }
        }
        return result;
    }

    // ─── ISO 8601 datetime helper ──────────────────────────────────────────────

    /**
     * Formats a DateTime as ISO 8601 UTC string for Data Cloud API payloads.
     * Data Cloud requires timestamps in 'yyyy-MM-ddTHH:mm:ssZ' format.
     *
     * @param dt  DateTime to format
     * @return    ISO 8601 UTC string, or null if dt is null
     */
    @TestVisible
    static String toIso8601Utc(DateTime dt) {
        if (dt == null) { return null; }
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }

    // ─── Error parsing ─────────────────────────────────────────────────────────

    @TestVisible
    static String extractErrorMessage(String responseBody) {
        if (String.isBlank(responseBody)) { return 'No response body'; }
        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            if (parsed.containsKey('message')) { return (String) parsed.get('message'); }
            if (parsed.containsKey('error'))   { return (String) parsed.get('error'); }
        } catch (Exception e) { /* not JSON */ }
        return responseBody.left(200);
    }

    // ─── Result / DTO types ───────────────────────────────────────────────────

    public class IngestionResult {
        public Boolean isSuccess;
        public Integer recordsAccepted;
        public String  errorMessage;

        public IngestionResult(Boolean success, Integer count, String error) {
            this.isSuccess       = success;
            this.recordsAccepted = count;
            this.errorMessage    = error;
        }
    }

    public class BatchValidationResult {
        public List<Map<String, Object>> validRecords  = new List<Map<String, Object>>();
        public List<String>              errorDetails  = new List<String>();

        public Integer validCount()   { return validRecords.size(); }
        public Integer invalidCount() { return errorDetails.size(); }
        public Boolean allValid()     { return errorDetails.isEmpty(); }
    }

    public class InteractionEvent {
        public String   eventId;
        public String   individualId;
        public String   eventType;         // 'EmailOpen' | 'WebVisit' | 'AppSession' | 'Purchase'
        public DateTime eventDateTime;
        public String   channelType;       // 'Email' | 'Web' | 'Mobile' | 'InStore'
        public Decimal  engagementScore;

        public InteractionEvent(String id, String indId, String type,
                                DateTime dt, String channel, Decimal score) {
            this.eventId         = id;
            this.individualId    = indId;
            this.eventType       = type;
            this.eventDateTime   = dt;
            this.channelType     = channel;
            this.engagementScore = score;
        }
    }
}
