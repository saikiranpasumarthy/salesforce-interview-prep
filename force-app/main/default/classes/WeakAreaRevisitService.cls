/**
 * Day 39 — Weak Area Revisit
 *
 * Targeted deep-dives on patterns most commonly missed in senior Salesforce
 * developer interviews, identified from mock interview gaps (Days 37–38):
 *
 *  1. FLS / CRUD enforcement    — stripInaccessible, WITH USER_MODE, describe checks
 *  2. Describe cache            — avoid repeated Schema.getGlobalDescribe() calls
 *  3. Custom Iterable / Iterator — memory-efficient large-dataset traversal
 *  4. Platform Event error handling — RetryableException, idempotency, DLQ pattern
 *  5. Callable interface        — cross-class / cross-package loose coupling
 *  6. CPU-aware chunking        — Limits.getCpuTime() + Limits.getLimitCpuTime()
 *  7. String security patterns  — SOQL injection, XSS, JSON deserialization safety
 */
public with sharing class WeakAreaRevisitService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. FLS / CRUD ENFORCEMENT
    //
    // Interview Q: "How do you enforce field-level security in Apex?"
    //
    // Three approaches (pick based on context):
    //
    //  A. WITH USER_MODE (SOQL keyword) — inline FLS + CRUD in queries/DML
    //     → Available in API v56+ for queries; DML: Database.insert(..., AccessLevel.USER_MODE)
    //
    //  B. Schema.stripInaccessible() — strip fields the running user can't read/edit
    //     → Use before returning data from @AuraEnabled / REST endpoints
    //
    //  C. Manual describe check — granular control, pre-API-56 compatibility
    //     → Schema.SObjectField.getDescribe().isAccessible() / isCreateable() / isUpdateable()
    //
    // Common interview mistake: forgetting that WITH SECURITY_ENFORCED throws an
    // exception if any field is inaccessible — prefer WITH USER_MODE (silently omits).
    // ═══════════════════════════════════════════════════════════════════════════

    // A — WITH USER_MODE: query respects running user's FLS automatically
    public static List<Account> getAccountsUserMode(String industry) {
        return [
            SELECT Id, Name, Industry, AnnualRevenue
            FROM   Account
            WHERE  Industry = :industry
            WITH   USER_MODE
            ORDER BY Name
            LIMIT 200
        ];
    }

    // B — stripInaccessible: remove fields the user can't see before returning to UI
    public static List<SObject> getContactsStripped(Set<Id> accountIds) {
        List<Contact> rawContacts = [
            SELECT Id, FirstName, LastName, Email, Phone, Title, Department
            FROM   Contact
            WHERE  AccountId IN :accountIds
            WITH   USER_MODE
        ];
        // Strip fields the running user cannot read — prevents data leakage
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.READABLE,
            rawContacts
        );
        return decision.getRecords();
    }

    // C — manual describe: granular field-level check before DML
    public static void upsertWithFlsCheck(SObject record, List<String> fieldNames) {
        Schema.SObjectType sobjType = record.getSObjectType();
        Schema.DescribeSObjectResult objDescribe = sobjType.getDescribe();

        if (!objDescribe.isCreateable()) {
            throw new SecurityException(
                'Insufficient privileges to create ' + sobjType.getDescribe().getName()
            );
        }
        Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();
        for (String fieldName : fieldNames) {
            String lower = fieldName.toLowerCase();
            if (!fieldMap.containsKey(lower)) continue;
            Schema.DescribeFieldResult fd = fieldMap.get(lower).getDescribe();
            if (!fd.isCreateable()) {
                throw new SecurityException(
                    'Insufficient privileges to write field: ' + fd.getName()
                );
            }
        }
        Database.upsert(record, AccessLevel.USER_MODE);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. DESCRIBE CACHE
    //
    // Interview Q: "What's wrong with calling Schema.getGlobalDescribe() in a loop?"
    //
    // Schema.getGlobalDescribe() is expensive — it builds a map of ALL sObject types.
    // Calling it per-record or per-field in a loop wastes CPU and heap.
    //
    // Pattern: static cache initialized once per transaction.
    // ═══════════════════════════════════════════════════════════════════════════

    // Initialized lazily — first call pays the cost; subsequent calls are O(1)
    private static Map<String, Schema.SObjectType> globalDescribeCache;
    private static Map<String, Map<String, Schema.SObjectField>> fieldDescribeCache
        = new Map<String, Map<String, Schema.SObjectField>>();

    @TestVisible
    private static Map<String, Schema.SObjectType> getGlobalDescribe() {
        if (globalDescribeCache == null) {
            globalDescribeCache = Schema.getGlobalDescribe();
        }
        return globalDescribeCache;
    }

    public static Map<String, Schema.SObjectField> getFieldMap(String objectApiName) {
        String key = objectApiName.toLowerCase();
        if (!fieldDescribeCache.containsKey(key)) {
            Schema.SObjectType sobjType = getGlobalDescribe().get(key);
            if (sobjType == null) return new Map<String, Schema.SObjectField>();
            fieldDescribeCache.put(key, sobjType.getDescribe().fields.getMap());
        }
        return fieldDescribeCache.get(key);
    }

    public static Boolean isFieldAccessible(String objectName, String fieldName) {
        Map<String, Schema.SObjectField> fields = getFieldMap(objectName);
        String lower = fieldName.toLowerCase();
        if (!fields.containsKey(lower)) return false;
        return fields.get(lower).getDescribe().isAccessible();
    }

    public static Schema.DisplayType getFieldType(String objectName, String fieldName) {
        Map<String, Schema.SObjectField> fields = getFieldMap(objectName);
        String lower = fieldName.toLowerCase();
        if (!fields.containsKey(lower)) return null;
        return fields.get(lower).getDescribe().getType();
    }

    // Validate that all field names exist on an object (safe dynamic SOQL construction)
    public static List<String> filterValidFields(String objectName, List<String> fieldNames) {
        Map<String, Schema.SObjectField> fieldMap = getFieldMap(objectName);
        List<String> valid = new List<String>();
        for (String f : fieldNames) {
            if (fieldMap.containsKey(f.toLowerCase())) valid.add(f);
        }
        return valid;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. CUSTOM ITERABLE / ITERATOR
    //
    // Interview Q: "How do you process a very large in-memory collection without
    //               hitting heap limits?"
    //
    // Custom Iterable lets Batch Apex (or any caller) consume records lazily —
    // one chunk at a time — without loading everything into memory at once.
    //
    // Use case: reading a large CSV from a Static Resource or ContentVersion,
    // processing line-by-line without building a List<String> of 100k lines.
    // ═══════════════════════════════════════════════════════════════════════════

    // Iterable wrapper for chunked processing of a delimited string
    public class ChunkedStringIterable implements Iterable<List<String>> {
        private final String rawData;
        private final String rowDelimiter;
        private final String colDelimiter;
        private final Integer chunkSize;

        public ChunkedStringIterable(
            String data, String rowDelim, String colDelim, Integer chunk
        ) {
            this.rawData      = data;
            this.rowDelimiter = rowDelim;
            this.colDelimiter = colDelim;
            this.chunkSize    = chunk != null ? chunk : 200;
        }

        public Iterator<List<String>> iterator() {
            return new ChunkedStringIterator(rawData, rowDelimiter, colDelimiter, chunkSize);
        }
    }

    public class ChunkedStringIterator implements Iterator<List<String>> {
        private final List<String> rows;
        private final String colDelimiter;
        private final Integer chunkSize;
        private Integer position = 0;

        public ChunkedStringIterator(
            String data, String rowDelim, String colDelim, Integer chunk
        ) {
            this.rows         = data != null ? data.split(rowDelim) : new List<String>();
            this.colDelimiter = colDelim;
            this.chunkSize    = chunk;
        }

        public Boolean hasNext() { return position < rows.size(); }

        public List<String> next() {
            if (!hasNext()) throw new NoSuchElementException('No more rows');
            Integer end = Math.min(position + chunkSize, rows.size());
            List<String> chunk = new List<String>();
            for (Integer i = position; i < end; i++) {
                if (String.isNotBlank(rows[i])) chunk.add(rows[i]);
            }
            position = end;
            return chunk;
        }
    }

    // Batch class using the custom Iterable (interview pattern)
    public class CsvImportBatch implements Database.Batchable<List<String>>, Database.Stateful {
        private final String csvData;
        public Integer processedRows = 0;
        public Integer errorRows     = 0;

        public CsvImportBatch(String data) { this.csvData = data; }

        public Iterable<List<String>> start(Database.BatchableContext bc) {
            return new ChunkedStringIterable(csvData, '\n', ',', 200);
        }

        public void execute(Database.BatchableContext bc, List<List<String>> chunks) {
            for (List<String> chunk : chunks) {
                for (String row : chunk) {
                    try {
                        processRow(row);
                        processedRows++;
                    } catch (Exception e) {
                        errorRows++;
                    }
                }
            }
        }

        public void finish(Database.BatchableContext bc) {
            System.debug('CSV import complete. Processed: ' + processedRows
                + ', Errors: ' + errorRows);
        }

        private void processRow(String row) {
            // parse row.split(',') → fields → build SObject → upsert
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. PLATFORM EVENT ERROR HANDLING
    //
    // Interview Q: "How do you handle errors in a Platform Event subscriber trigger?"
    //
    // Three outcomes in a Platform Event trigger:
    //
    //   A. Success           — trigger completes; event consumed
    //   B. Retryable error   — throw EventBus.RetryableException; Salesforce retries
    //                          (up to 9 retries with exponential backoff)
    //   C. Non-retryable     — any other exception; event is skipped (logged to
    //                          EventBusSubscriber.LastError)
    //
    // Idempotency is REQUIRED because at-least-once delivery means the same event
    // can arrive more than once (e.g., after a retry).
    //
    // Pattern: use a ProcessedEvent__c custom object (or ExternalId field) as an
    // idempotency key — skip re-processing if already handled.
    // ═══════════════════════════════════════════════════════════════════════════

    // Called from a Platform Event trigger — demonstrates the three outcomes
    public static void handlePlatformEvent(
        String correlationId,
        String payload,
        Boolean simulateTransientError,
        Boolean simulatePermanentError
    ) {
        if (simulatePermanentError) {
            // Non-retryable: data is malformed; retrying won't help
            throw new IllegalArgumentException('Malformed payload — will not retry: ' + payload);
        }

        // Idempotency check — have we already processed this event?
        if (isAlreadyProcessed(correlationId)) {
            System.debug('Skipping duplicate event: ' + correlationId);
            return;
        }

        if (simulateTransientError) {
            // Retryable: transient issue (callout timeout, lock contention)
            // Salesforce will retry this event up to 9 times
            throw new EventBus.RetryableException(
                'Transient error processing event ' + correlationId + '. Will retry.'
            );
        }

        // Process the event
        markAsProcessed(correlationId);
        System.debug('Platform event processed: ' + correlationId);
    }

    @TestVisible
    static Boolean isAlreadyProcessed(String correlationId) {
        if (String.isBlank(correlationId)) return false;
        // In production: query a ProcessedEvent__c record by CorrelationId__c ExternalId
        // For testability, this method is overridable via @TestVisible
        return false;
    }

    private static void markAsProcessed(String correlationId) {
        // In production: insert ProcessedEvent__c with CorrelationId__c = correlationId
        // Using upsert + external ID for idempotency
    }

    // Replay ID tracking — for resuming from a checkpoint
    public static Long getLastReplayId(String channelName) {
        // Query EventBusSubscriber for the LastReplayId
        List<SObject> rows;
        try {
            rows = Database.query(
                'SELECT ExternalId FROM EventBusSubscriber '
                + 'WHERE Topic = :channelName LIMIT 1'
            );
            if (!rows.isEmpty()) {
                String externalId = (String) rows[0].get('ExternalId');
                return Long.valueOf(externalId);
            }
        } catch (Exception e) { /* EventBusSubscriber not queryable in all contexts */ }
        return -2L; // -2 = replay from earliest retained event (up to 3 days)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. CALLABLE INTERFACE
    //
    // Interview Q: "How do you call code in another package without a compile-time
    //               dependency?"
    //
    // The Callable interface (System.Callable) enables loose coupling between:
    //   - Your managed package and a subscriber org's custom code
    //   - A core package and optional add-on packages
    //   - An ISV app and customer-specific extensions
    //
    // Pattern: implement Callable in the target class; caller uses Type.forName()
    // to get an instance at runtime. Zero compile-time coupling.
    // ═══════════════════════════════════════════════════════════════════════════

    // Example implementation — what the "callee" package provides
    public class TaxCalculatorCallable implements Callable {
        public Object call(String action, Map<String, Object> args) {
            switch on action {
                when 'calculateTax' {
                    Decimal amount    = (Decimal) args.get('amount');
                    String  taxCode   = (String)  args.get('taxCode');
                    return calculateTax(amount, taxCode);
                }
                when 'getRate' {
                    String taxCode = (String) args.get('taxCode');
                    return getTaxRate(taxCode);
                }
                when else {
                    throw new IllegalArgumentException('Unknown action: ' + action);
                }
            }
        }

        private Decimal calculateTax(Decimal amount, String taxCode) {
            Decimal rate = getTaxRate(taxCode);
            return (amount * rate / 100).setScale(2);
        }

        private Decimal getTaxRate(String taxCode) {
            Map<String, Decimal> rates = new Map<String, Decimal>{
                'VAT_20'  => 20.0,
                'VAT_5'   => 5.0,
                'EXEMPT'  => 0.0
            };
            return rates.containsKey(taxCode) ? rates.get(taxCode) : 0.0;
        }
    }

    // Caller pattern — no compile-time dependency on TaxCalculatorCallable
    public static Decimal callExternalTaxService(
        String namespace, String className, Decimal amount, String taxCode
    ) {
        Type serviceType = String.isBlank(namespace)
            ? Type.forName(className)
            : Type.forName(namespace, className);

        if (serviceType == null) {
            System.debug('Tax service not installed: ' + namespace + '.' + className);
            return 0;
        }

        Callable service = (Callable) serviceType.newInstance();
        Map<String, Object> args = new Map<String, Object>{
            'amount'  => amount,
            'taxCode' => taxCode
        };
        return (Decimal) service.call('calculateTax', args);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. CPU-AWARE CHUNKING
    //
    // Interview Q: "How do you avoid CPU limit exceptions in complex Apex logic?"
    //
    // Apex CPU limit: 10,000ms (sync) / 60,000ms (async/batch execute).
    // Strategy: check remaining CPU at chunk boundaries; enqueue remainder if close.
    //
    // Rule of thumb: stop at 80% CPU (8,000ms sync / 48,000ms async) to leave
    // headroom for DML, callout overhead, and framework code.
    // ═══════════════════════════════════════════════════════════════════════════

    public static final Integer CPU_HEADROOM_PCT = 80;

    public static Boolean hasCpuHeadroom() {
        Long used  = Limits.getCpuTime();
        Long total = Limits.getLimitCpuTime();
        return (used * 100 / total) < CPU_HEADROOM_PCT;
    }

    public static ProcessingResult processRecordsWithCpuGuard(
        List<Id> recordIds,
        String continuationQueueableClass
    ) {
        ProcessingResult result = new ProcessingResult();
        List<Id> remaining = new List<Id>(recordIds);

        for (Integer i = 0; i < remaining.size(); i++) {
            if (!hasCpuHeadroom()) {
                // Enqueue the remainder in a new transaction
                result.processedCount = i;
                result.remainingIds   = new List<Id>(remaining).subList(i, remaining.size());
                result.enqueuedContinuation = true;

                if (String.isNotBlank(continuationQueueableClass)
                    && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                    Type qType = Type.forName(continuationQueueableClass);
                    if (qType != null) {
                        // In production: pass remainingIds to the queueable constructor
                        System.enqueueJob((Queueable) qType.newInstance());
                    }
                }
                return result;
            }
            // Do the actual work per record
            processOneRecord(remaining[i]);
            result.processedCount++;
        }
        result.enqueuedContinuation = false;
        return result;
    }

    private static void processOneRecord(Id recordId) {
        // Placeholder — real implementation would query + transform + DML
    }

    // Heap-aware bulk collect — stop building a list before hitting 6MB heap limit
    public static List<String> buildLargeListWithHeapGuard(
        List<String> sourceData, Integer maxHeapPct
    ) {
        Long heapLimit = Limits.getLimitHeapSize();
        List<String> result = new List<String>();

        for (String item : sourceData) {
            Long usedPct = Limits.getHeapSize() * 100 / heapLimit;
            if (usedPct >= (maxHeapPct != null ? maxHeapPct : 80)) break;
            result.add(item);
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. STRING SECURITY PATTERNS
    //
    // Interview Q: "Name three string-related security vulnerabilities in Apex
    //               and how you prevent them."
    //
    // A. SOQL Injection    → use bind variables or Database.queryWithBinds()
    // B. XSS in Visualforce/Aura → use {!HTMLENCODE()} / String.escapeHtml4()
    // C. JSON deserialization → never deserialize to untyped Map<String,Object>
    //    and then cast without validation; use typed DTOs or schema validation
    // D. Open redirect     → validate URL is within your domain before redirect
    // ═══════════════════════════════════════════════════════════════════════════

    // A — SOQL injection safe: bind variable (never string concatenation in WHERE)
    public static List<Account> safeSearch(String searchTerm) {
        // SAFE: bind variable — searchTerm is never interpolated into SOQL
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [SELECT Id, Name FROM Account WHERE Name LIKE :term WITH USER_MODE];
    }

    // A — Dynamic SOQL with multiple conditions: Database.queryWithBinds
    public static List<SObject> safeDynamicQuery(
        String objectName,
        Map<String, Object> filters
    ) {
        Schema.SObjectType sobjType = getGlobalDescribe().get(objectName.toLowerCase());
        if (sobjType == null) throw new IllegalArgumentException('Unknown object: ' + objectName);

        Map<String, Schema.SObjectField> fieldMap =
            sobjType.getDescribe().fields.getMap();

        List<String> conditions = new List<String>();
        Map<String, Object> bindMap = new Map<String, Object>();

        for (String fieldName : filters.keySet()) {
            if (!fieldMap.containsKey(fieldName.toLowerCase())) continue; // skip invalid fields
            String bindKey = 'v_' + fieldName.replaceAll('[^a-zA-Z0-9]', '_');
            conditions.add(fieldName + ' = :' + bindKey);
            bindMap.put(bindKey, filters.get(fieldName));
        }

        String soql = 'SELECT Id FROM ' + String.escapeSingleQuotes(objectName);
        if (!conditions.isEmpty()) {
            soql += ' WHERE ' + String.join(conditions, ' AND ');
        }
        soql += ' WITH USER_MODE LIMIT 200';

        return Database.queryWithBinds(soql, bindMap, AccessLevel.USER_MODE);
    }

    // B — XSS safe: escape before rendering in string-based output
    public static String safeHtmlOutput(String userContent) {
        return String.escapeHtml4(userContent);
    }

    // C — Safe JSON deserialization: use a typed inner class
    public static ImportPayload safeDeserializeJson(String jsonBody) {
        try {
            ImportPayload payload = (ImportPayload) JSON.deserialize(
                jsonBody, ImportPayload.class
            );
            // Validate required fields after deserialization
            if (String.isBlank(payload?.recordId)) {
                throw new IllegalArgumentException('recordId is required');
            }
            return payload;
        } catch (JSONException e) {
            throw new IllegalArgumentException('Invalid JSON payload: ' + e.getMessage());
        }
    }

    // D — Open redirect guard: validate URL is within an allowlist of safe domains
    public static String safeRedirectUrl(String url, Set<String> allowedDomains) {
        if (String.isBlank(url)) return '/';
        try {
            // Ensure the URL is relative or matches an allowed domain
            if (url.startsWith('/') && !url.startsWith('//')) return url;
            for (String domain : allowedDomains) {
                if (url.startsWith('https://' + domain) || url.startsWith('http://' + domain)) {
                    return url;
                }
            }
        } catch (Exception e) { /* fall through to safe default */ }
        return '/'; // default safe redirect
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class ProcessingResult {
        public Integer      processedCount         = 0;
        public List<Id>     remainingIds           = new List<Id>();
        public Boolean      enqueuedContinuation   = false;
    }

    public class ImportPayload {
        public String  recordId;
        public String  action;
        public Map<String, String> attributes;
    }
}
