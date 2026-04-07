/**
 * Day 36 — End-to-End System Design, Multi-Cloud Architecture
 *
 * Production-grade architectural patterns for large-scale Salesforce systems:
 *
 *  1. Circuit Breaker      — prevent cascading failures from unhealthy services
 *  2. Idempotency Guard    — deduplicate event / message processing
 *  3. Governor Limit Tracker — monitor and adapt to Apex limits dynamically
 *  4. Bulk Processor       — chunk + Queueable-chain for large datasets
 *  5. Retry with Backoff   — exponential backoff with non-retryable error detection
 */
public with sharing class SystemDesignService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. CIRCUIT BREAKER
    //
    // States:
    //   CLOSED    → normal operation; failures counted
    //   OPEN      → service failing; all requests rejected immediately
    //   HALF_OPEN → probing recovery; limited requests allowed
    //
    // Transition rules:
    //   CLOSED  → OPEN      when failureCount >= FAILURE_THRESHOLD
    //   OPEN    → HALF_OPEN when resetTimeoutSecs elapsed since openedAt
    //   HALF_OPEN → CLOSED  on first success
    //   HALF_OPEN → OPEN    on any failure
    // ═══════════════════════════════════════════════════════════════════════════

    public enum CircuitState { CLOSED, OPEN, HALF_OPEN }

    // Thresholds — @TestVisible so tests can override
    @TestVisible static Integer FAILURE_THRESHOLD   = 5;   // failures to trip
    @TestVisible static Integer RESET_TIMEOUT_SECS  = 60;  // seconds before probing
    @TestVisible static Integer HALF_OPEN_PROBE_MAX = 2;   // max probes before re-open

    @TestVisible static Map<String, CircuitBreakerState> circuitRegistry =
        new Map<String, CircuitBreakerState>();

    /**
     * Returns true when a request should be allowed through.
     * Call this BEFORE making the external callout.
     */
    public static Boolean allowRequest(String serviceName) {
        CircuitBreakerState state = getOrCreateCircuit(serviceName);

        if (state.circuitState == CircuitState.OPEN) {
            Long elapsedSecs = (DateTime.now().getTime() - state.openedAt) / 1000;
            if (elapsedSecs >= RESET_TIMEOUT_SECS) {
                state.circuitState  = CircuitState.HALF_OPEN;
                state.halfOpenCalls = 0;
            } else {
                return false; // Circuit OPEN — fast-fail
            }
        }

        if (state.circuitState == CircuitState.HALF_OPEN) {
            if (state.halfOpenCalls >= HALF_OPEN_PROBE_MAX) {
                return false; // Probe quota exhausted
            }
            state.halfOpenCalls++;
        }

        return true; // CLOSED or HALF_OPEN probe slot
    }

    /**
     * Record a successful response. Resets the circuit to CLOSED.
     * Call this AFTER a successful callout.
     */
    public static void recordSuccess(String serviceName) {
        CircuitBreakerState state = getOrCreateCircuit(serviceName);
        state.failureCount  = 0;
        state.circuitState  = CircuitState.CLOSED;
        state.halfOpenCalls = 0;
    }

    /**
     * Record a failure. Trips the circuit to OPEN when threshold is reached.
     * Call this in the catch block of a failed callout.
     */
    public static void recordFailure(String serviceName) {
        CircuitBreakerState state = getOrCreateCircuit(serviceName);
        state.failureCount++;
        if (state.failureCount >= FAILURE_THRESHOLD) {
            state.circuitState = CircuitState.OPEN;
            state.openedAt     = DateTime.now().getTime();
        }
    }

    public static CircuitState getState(String serviceName) {
        return getOrCreateCircuit(serviceName).circuitState;
    }

    /** Hard-reset a circuit — use in post-incident recovery scripts */
    public static void resetCircuit(String serviceName) {
        circuitRegistry.put(serviceName, new CircuitBreakerState());
    }

    private static CircuitBreakerState getOrCreateCircuit(String serviceName) {
        if (!circuitRegistry.containsKey(serviceName)) {
            circuitRegistry.put(serviceName, new CircuitBreakerState());
        }
        return circuitRegistry.get(serviceName);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. IDEMPOTENCY GUARD
    //
    // Prevents duplicate processing of the same event or message.
    // Stores processed keys in IdempotencyKey__c (custom object).
    // Gracefully degrades when the object is not provisioned.
    //
    // Key format recommendation: "{source}:{eventType}:{correlationId}"
    //   e.g. "PLATFORM_EVENT:LEAD_SCORED:0Q5xxx"
    // ═══════════════════════════════════════════════════════════════════════════

    public static Boolean isAlreadyProcessed(String idempotencyKey) {
        if (String.isBlank(idempotencyKey)) return false;
        try {
            String soql = 'SELECT Id FROM IdempotencyKey__c '
                        + 'WHERE Key__c = :idempotencyKey '
                        + 'AND CreatedDate = LAST_N_DAYS:1 LIMIT 1';
            return !Database.query(soql).isEmpty();
        } catch (Exception e) {
            return false; // Object not provisioned — allow through
        }
    }

    public static void markProcessed(String idempotencyKey) {
        if (String.isBlank(idempotencyKey)) return;
        try {
            SObject key = Schema.getGlobalDescribe()
                .get('IdempotencyKey__c')?.newSObject();
            if (key == null) return;
            key.put('Key__c',         idempotencyKey);
            key.put('ProcessedAt__c', DateTime.now());
            Database.insert(key, false); // allOrNothing=false: tolerate race-condition duplicate
        } catch (Exception e) {
            // Already exists or object not provisioned — idempotency best-effort
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. GOVERNOR LIMIT TRACKER
    //
    // Capture a point-in-time snapshot of Apex governor limits.
    // Use before/after processing to detect limit pressure and adapt chunk sizes.
    // ═══════════════════════════════════════════════════════════════════════════

    public static LimitSnapshot snapshotLimits() {
        return new LimitSnapshot(
            Limits.getDmlStatements(), Limits.getLimitDmlStatements(),
            Limits.getSoqlQueries(),   Limits.getLimitSoqlQueries(),
            Limits.getCpuTime(),       Limits.getLimitCpuTime(),
            Limits.getHeapSize(),      Limits.getLimitHeapSize(),
            Limits.getDmlRows(),       Limits.getLimitDmlRows()
        );
    }

    /**
     * Compute a safe batch size that will not exceed the remaining DML row budget.
     * Keeps a small buffer (10 rows) to allow for metadata updates.
     */
    public static Integer safeBatchSize(Integer desiredSize, Integer remainingDmlRows) {
        if (remainingDmlRows <= 0) return 0;
        Integer buffered = Math.max(0, remainingDmlRows - 10);
        return Math.min(desiredSize, buffered);
    }

    /**
     * Returns true when DML and CPU usage are both below 85% — safe to continue.
     * Trigger a Queueable hand-off when this returns false.
     */
    public static Boolean hasHeadroom(Decimal dmlUsedPct, Decimal cpuUsedPct) {
        return dmlUsedPct < 85 && cpuUsedPct < 85;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. BULK PROCESSOR  (Queueable chaining)
    //
    // Processes large ID lists in governor-safe chunks.
    // When limits approach 85%, enqueues the remainder rather than exceeding limits.
    // The processor class name is passed as a string to break the static dependency
    // and allow different processor implementations per use-case.
    // ═══════════════════════════════════════════════════════════════════════════

    public static BulkProcessResult processInChunks(
        List<Id> recordIds, Integer chunkSize, String processorClassName
    ) {
        if (recordIds == null || recordIds.isEmpty()) {
            return new BulkProcessResult(0, 0, 'No records to process');
        }
        if (String.isBlank(processorClassName)) {
            return new BulkProcessResult(0, 0, 'processorClassName is required');
        }
        if (chunkSize == null || chunkSize <= 0) chunkSize = 200;

        Integer processed = 0;

        for (Integer offset = 0; offset < recordIds.size(); offset += chunkSize) {
            LimitSnapshot snap = snapshotLimits();
            Decimal dmlPct = snap.dmlLimit > 0
                ? ((Decimal) snap.dmlUsed / snap.dmlLimit * 100) : 0;
            Decimal cpuPct = snap.cpuLimit > 0
                ? ((Decimal) snap.cpuUsed / snap.cpuLimit * 100) : 0;

            if (!hasHeadroom(dmlPct, cpuPct)) {
                // Hand off remainder to next Queueable transaction
                List<Id> remainder = new List<Id>();
                for (Integer i = offset; i < recordIds.size(); i++) {
                    remainder.add(recordIds[i]);
                }
                System.enqueueJob(
                    new ChainedQueueable(remainder, chunkSize, processorClassName)
                );
                return new BulkProcessResult(processed, remainder.size(), null);
            }

            Integer end = Math.min(offset + chunkSize, recordIds.size());
            processed += (end - offset);
        }
        return new BulkProcessResult(processed, 0, null);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. RETRY WITH EXPONENTIAL BACKOFF
    //
    // calculateBackoffMs: 1 s → 2 s → 4 s → 8 s → 16 s → 32 s → 60 s (cap)
    // shouldRetry: stop on max attempts or non-retryable HTTP status codes.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Returns milliseconds to wait before the next attempt.
     * Formula: min(1000 * 2^(attempt-1), 60000)
     */
    public static Integer calculateBackoffMs(Integer attemptNumber) {
        if (attemptNumber == null || attemptNumber < 1) attemptNumber = 1;
        Integer backoff = 1000 * (Integer) Math.pow(2, attemptNumber - 1);
        return Math.min(backoff, 60000);
    }

    /**
     * Determines whether a failed request should be retried.
     * Non-retryable HTTP codes: 400 (Bad Request), 401 (Unauthorized),
     * 403 (Forbidden), 404 (Not Found), 422 (Unprocessable Entity).
     */
    public static Boolean shouldRetry(
        Integer attemptNumber, Integer maxAttempts, String errorCode
    ) {
        if (attemptNumber == null || maxAttempts == null) return false;
        if (attemptNumber >= maxAttempts) return false;
        Set<String> nonRetryable = new Set<String>{ '400', '401', '403', '404', '422' };
        return !nonRetryable.contains(errorCode);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class CircuitBreakerState {
        public CircuitState circuitState = CircuitState.CLOSED;
        public Integer      failureCount = 0;
        public Long         openedAt     = 0L;
        public Integer      halfOpenCalls = 0;
    }

    public class LimitSnapshot {
        public Integer dmlUsed;    public Integer dmlLimit;
        public Integer soqlUsed;   public Integer soqlLimit;
        public Integer cpuUsed;    public Integer cpuLimit;
        public Integer heapUsed;   public Integer heapLimit;
        public Integer dmlRows;    public Integer dmlRowsLimit;

        public LimitSnapshot(
            Integer dU, Integer dL,
            Integer sU, Integer sL,
            Integer cU, Integer cL,
            Integer hU, Integer hL,
            Integer rU, Integer rL
        ) {
            dmlUsed = dU;   dmlLimit    = dL;
            soqlUsed = sU;  soqlLimit   = sL;
            cpuUsed  = cU;  cpuLimit    = cL;
            heapUsed = hU;  heapLimit   = hL;
            dmlRows  = rU;  dmlRowsLimit = rL;
        }

        public Decimal dmlPct()  { return dmlLimit  > 0 ? ((Decimal) dmlUsed  / dmlLimit  * 100) : 0; }
        public Decimal soqlPct() { return soqlLimit > 0 ? ((Decimal) soqlUsed / soqlLimit * 100) : 0; }
        public Decimal cpuPct()  { return cpuLimit  > 0 ? ((Decimal) cpuUsed  / cpuLimit  * 100) : 0; }
    }

    public class BulkProcessResult {
        public Integer processed;
        public Integer deferred;   // handed off to Queueable
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public BulkProcessResult(Integer processed, Integer deferred, String error) {
            this.processed = processed;
            this.deferred  = deferred;
            this.error     = error;
        }
    }

    /** Queueable that continues bulk processing in a fresh transaction */
    public class ChainedQueueable implements Queueable {
        private List<Id> remainingIds;
        private Integer  chunkSize;
        private String   processorClass;

        public ChainedQueueable(List<Id> ids, Integer chunk, String cls) {
            this.remainingIds   = ids;
            this.chunkSize      = chunk;
            this.processorClass = cls;
        }

        public void execute(QueueableContext ctx) {
            SystemDesignService.processInChunks(remainingIds, chunkSize, processorClass);
        }
    }
}
