/**
 * AsyncCalloutService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 17 — Callouts from async Apex: @future, Queueable, Batch.
 *
 * THE CORE PROBLEM:
 * ═════════════════
 * Apex callouts CANNOT be made after DML in the same transaction:
 *   insert account;              // ← DML
 *   ExternalApiClient.post(...); // ← CalloutException: uncommitted work pending
 *
 * SOLUTIONS — in order of preference:
 * ════════════════════════════════════
 * 1. @future(callout=true)       — simplest; fire-and-forget; no state passing beyond primitives
 * 2. Queueable + AllowsCallouts  — supports complex state, chaining, return value via Platform Events
 * 3. Batch + AllowsCallouts      — bulk processing; one callout per execute() recommended
 * 4. Platform Event → Flow/Apex  — decoupled; survives partial failures; scalable
 *
 * COMPARISON TABLE:
 * ═════════════════
 *                    @future    Queueable   Batch       Platform Event
 * ─────────────────────────────────────────────────────────────────────
 * Allow callouts     Yes        Yes*        Yes*        Yes (via handler)
 * Pass complex types No         Yes         Via SOQL    Via JSON body
 * Chain / recurse    No         Yes (50)    No          Infinite (careful)
 * DML after callout  No         No          No          Separate tx
 * Bulk per enqueue   1 tx       1 job       Batched     Per event
 * Monitor in UI      No         Yes         Yes         No
 * * requires Database.AllowsCallouts
 */
public with sharing class AsyncCalloutService {

    // ─────────────────────────────────────────────────────────────────────────
    // Pattern 1 — @future(callout=true)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Asynchronously syncs a single Account to an external system.
     *
     * RULES FOR @future:
     *  • Method must be static and void
     *  • Parameters: only primitives or primitive collections (no SObjects, no custom types)
     *  • Max 50 @future calls per transaction
     *  • Enqueues immediately; runs in a separate future transaction
     *  • Cannot chain @future from @future (throws System.AsyncException)
     *  • Order of execution is not guaranteed
     */
    @future(callout=true)
    public static void syncAccountFuture(Id accountId) {
        try {
            Account acc = [
                SELECT Id, Name, Type, AnnualRevenue, Phone, Website
                FROM   Account
                WHERE  Id = :accountId
                WITH   SECURITY_ENFORCED
                LIMIT  1
            ];
            ExternalApiClient.post('/accounts', acc);
            updateSyncStatus(accountId, 'Synced', null);
        } catch (ExternalApiClient.ApiErrorException e) {
            updateSyncStatus(accountId, 'Failed', e.getMessage());
        } catch (Exception e) {
            updateSyncStatus(accountId, 'Error', e.getMessage());
        }
    }

    /**
     * Bulk version: accepts a set of Ids (primitives) and syncs each.
     * Note: still limited to 100 callouts per transaction — batch for larger sets.
     */
    @future(callout=true)
    public static void syncAccountsBulkFuture(List<Id> accountIds) {
        List<Account> accounts = [
            SELECT Id, Name, Type, AnnualRevenue
            FROM   Account
            WHERE  Id IN :accountIds
            WITH   SECURITY_ENFORCED
        ];
        for (Account acc : accounts) {
            try {
                ExternalApiClient.post('/accounts', acc);
            } catch (ExternalApiClient.ApiErrorException e) {
                updateSyncStatus(acc.Id, 'Failed', e.getMessage());
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pattern 2 — Queueable + Database.AllowsCallouts
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Enqueues a job to sync a list of accounts.
     * Accepts complex types (unlike @future) — pass full Account objects or any state.
     */
    public static Id enqueueSyncJob(List<Id> accountIds) {
        return System.enqueueJob(new SyncAccountsJob(accountIds));
    }

    /**
     * SyncAccountsJob — Queueable callout job.
     *
     * KEY POINTS:
     *  • Implements Database.AllowsCallouts to enable callouts from execute()
     *  • Can accept any serialisable types in the constructor
     *  • Can chain another job from execute() for continuation (max depth: 50)
     *  • Each job is a separate transaction — DML before/after callout is fine
     *    within the SAME execute() as long as callouts come BEFORE DML
     *  • Use System.isFuture() / System.isQueueable() guards if needed
     */
    public class SyncAccountsJob implements Queueable, Database.AllowsCallouts {
        private List<Id>  accountIds;
        private Integer   batchIndex;   // which slice to process in this job
        private static final Integer SLICE = 10;  // callouts per job invocation

        public SyncAccountsJob(List<Id> accountIds) {
            this(accountIds, 0);
        }

        public SyncAccountsJob(List<Id> accountIds, Integer batchIndex) {
            this.accountIds = accountIds;
            this.batchIndex = batchIndex;
        }

        public void execute(QueueableContext ctx) {
            Integer start = batchIndex * SLICE;
            Integer end   = Math.min(start + SLICE, accountIds.size());
            if (start >= accountIds.size()) { return; }

            List<Id> slice = new List<Id>();
            for (Integer i = start; i < end; i++) {
                slice.add(accountIds[i]);
            }

            List<Account> accounts = [
                SELECT Id, Name, Type, AnnualRevenue
                FROM   Account
                WHERE  Id IN :slice
                WITH   SECURITY_ENFORCED
            ];

            List<Id> failedIds = new List<Id>();
            for (Account acc : accounts) {
                try {
                    ExternalApiClient.post('/accounts', acc);
                } catch (ExternalApiClient.ApiErrorException e) {
                    failedIds.add(acc.Id);
                }
            }

            // DML AFTER callouts — this is fine (callouts first, then DML)
            if (!failedIds.isEmpty()) {
                markSyncFailed(failedIds);
            }

            // Chain to next slice if more records remain
            if (end < accountIds.size() && !System.isFuture() && !System.isBatch()) {
                System.enqueueJob(new SyncAccountsJob(accountIds, batchIndex + 1));
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pattern 3 — Batch + Database.AllowsCallouts
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Starts the batch job to sync all pending accounts.
     * Use for large volumes (thousands of records).
     *
     * @param batchSize  Scope size per execute() call; keep small (1-5) for callout-heavy batches
     */
    public static Id startSyncBatch(Integer batchSize) {
        return Database.executeBatch(new SyncAccountBatch(), batchSize);
    }

    /**
     * SyncAccountBatch — Batch callout job.
     *
     * KEY POINTS:
     *  • Database.AllowsCallouts enables callouts in execute()
     *  • Each execute() call is a separate transaction (new callout limit = 100)
     *  • Best practice: keep batch size 1–10 when making per-record callouts
     *    to avoid hitting the 100 callout limit within one execute() call
     *  • Cannot make callouts in start() or finish() — only execute()
     *  • For finish()-time callouts: enqueue a Queueable from finish()
     */
    public class SyncAccountBatch
            implements Database.Batchable<SObject>, Database.AllowsCallouts {

        public Database.QueryLocator start(Database.BatchableContext ctx) {
            return Database.getQueryLocator([
                SELECT Id, Name, Type, AnnualRevenue, Phone
                FROM   Account
                WHERE  Sync_Status__c = 'Pending'
                OR     Sync_Status__c = 'Failed'
            ]);
        }

        public void execute(Database.BatchableContext ctx, List<Account> scope) {
            // Callouts FIRST in execute() before any DML
            Map<Id, String> results = new Map<Id, String>();
            for (Account acc : scope) {
                try {
                    ExternalApiClient.post('/accounts', acc);
                    results.put(acc.Id, 'Synced');
                } catch (ExternalApiClient.ApiErrorException e) {
                    results.put(acc.Id, 'Failed:' + e.statusCode);
                } catch (Exception e) {
                    results.put(acc.Id, 'Error');
                }
            }

            // DML AFTER callouts
            List<Account> toUpdate = new List<Account>();
            for (Id accId : results.keySet()) {
                toUpdate.add(new Account(
                    Id            = accId,
                    Sync_Status__c = results.get(accId).startsWith('Failed')
                                        ? 'Failed' : 'Synced'
                ));
            }
            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }
        }

        public void finish(Database.BatchableContext ctx) {
            // Enqueue a Queueable for post-batch callouts (e.g. notify a webhook)
            AsyncApexJob job = [
                SELECT Id, Status, NumberOfErrors, JobItemsProcessed, TotalJobItems
                FROM   AsyncApexJob
                WHERE  Id = :ctx.getJobId()
            ];
            if (job.NumberOfErrors == 0) {
                System.enqueueJob(new NotifyWebhookJob(job.TotalJobItems));
            }
        }
    }

    /**
     * NotifyWebhookJob — called from batch finish() to make a post-completion callout.
     * Demonstrates the Queueable-from-finish() pattern for finish()-time callouts.
     */
    public class NotifyWebhookJob implements Queueable, Database.AllowsCallouts {
        private Integer processedCount;

        public NotifyWebhookJob(Integer processedCount) {
            this.processedCount = processedCount;
        }

        public void execute(QueueableContext ctx) {
            Map<String, Object> payload = new Map<String, Object>{
                'event'     => 'sync_complete',
                'processed' => processedCount,
                'timestamp' => String.valueOf(Datetime.now())
            };
            try {
                ExternalApiClient.post('/webhooks/sync', payload);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Webhook notification failed: ' + e.getMessage());
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers — update Sync_Status__c on Account
    // ─────────────────────────────────────────────────────────────────────────

    private static void updateSyncStatus(Id accountId, String status, String errorMsg) {
        // Intentionally no with sharing — updating audit fields should not be
        // blocked by record-level access of the calling user
        new SyncStatusUpdater().updateStatus(accountId, status, errorMsg);
    }

    private static void markSyncFailed(List<Id> ids) {
        List<Account> accs = new List<Account>();
        for (Id id : ids) {
            accs.add(new Account(Id = id, Sync_Status__c = 'Failed'));
        }
        update accs;
    }

    private without sharing class SyncStatusUpdater {
        public void updateStatus(Id accountId, String status, String errorMsg) {
            update new Account(
                Id             = accountId,
                Sync_Status__c = status,
                Sync_Error__c  = errorMsg != null ? errorMsg.abbreviate(255) : null
            );
        }
    }
}
