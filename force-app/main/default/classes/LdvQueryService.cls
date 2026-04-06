/**
 * @description Large Data Volume (LDV) query patterns for Salesforce orgs with
 *              millions of records. Every pattern here maps to a specific governor
 *              limit or query performance concern raised in senior-level interviews.
 *
 *              LDV thresholds (Salesforce guidance):
 *                > 100K records  → start thinking about batch processing
 *                > 1M records    → skinny tables, index hygiene, FOR LOOP mandatory
 *                > 10M records   → Big Objects for archival, External Objects for federation
 *
 *              Index selectivity rule:
 *                A filter on an indexed field is "selective" when it returns:
 *                  < 10% of total records  OR  < 333,333 records  (whichever is smaller)
 *                Non-selective query on an object > 1M rows → full table scan →
 *                potential SOQL timeout or heap overflow.
 *
 *              Skinny Tables (Support request, not configurable in Apex/metadata):
 *                - Denormalized copy of frequently-queried columns on a single table
 *                - Eliminates the JOIN to the main Salesforce object table
 *                - Dramatically speeds up range scans on 10M+ record objects
 *                - Requested via Salesforce Support ticket with field list + object
 *                - Automatically maintained; transparent to SOQL syntax
 *                - Best candidates: objects with > 10M rows, < 20 queried columns,
 *                  frequent ORDER BY / GROUP BY on the same fields
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class LdvQueryService {

    // ─── SOQL FOR LOOP — critical LDV pattern ─────────────────────────────────

    /**
     * Streams records 200 at a time — heap never exceeds O(200) regardless of
     * total record count. The Apex runtime re-uses the same List<Account> reference
     * on each iteration, keeping heap pressure constant.
     *
     * Compare:
     *   List<Account> all = [SELECT ...];   // O(N) heap — blows up at 50K+ records
     *   for (List<Account> chunk : [SELECT ...]) { }  // O(200) heap — safe for millions
     *
     * Interview point: the outer FOR LOOP emits internal chunks of 200; you are
     * responsible for DML-bulkifying across chunks if needed (accumulate in outer List,
     * DML after the loop — see processLargeAccountSet example).
     *
     * @param processor  Strategy interface — called with each 200-record chunk
     */
    public static void streamPendingAccounts(ChunkProcessor processor) {
        for (List<Account> chunk : [
            SELECT Id, Name, AnnualRevenue, Sync_Status__c, Rating
            FROM   Account
            WHERE  Sync_Status__c = 'Pending'
            ORDER BY Id ASC
        ]) {
            processor.process(chunk);
        }
    }

    /**
     * Collects DML updates across FOR LOOP chunks in a single outer list,
     * then issues one DML after the loop — bulk-safe and heap-safe.
     *
     * Anti-pattern: DML inside the FOR LOOP body = 1 DML per 200 records.
     * For 1M records = 5000 DML statements → governor limit violation.
     */
    public static Integer bulkUpdateSyncStatus(String fromStatus, String toStatus) {
        List<Account> toUpdate = new List<Account>();
        for (List<Account> chunk : [
            SELECT Id, Sync_Status__c
            FROM   Account
            WHERE  Sync_Status__c = :fromStatus
        ]) {
            for (Account acc : chunk) {
                toUpdate.add(new Account(Id = acc.Id, Sync_Status__c = toStatus));
            }
        }
        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
        return toUpdate.size();
    }

    // ─── Keyset Pagination — beyond OFFSET 2000 ───────────────────────────────

    /**
     * Keyset (seek-method) pagination — supports unlimited depth.
     *
     * Problem with OFFSET: Salesforce limits OFFSET to 2000.
     *   SELECT Id FROM Account LIMIT 200 OFFSET 2200  → throws QueryException
     *
     * Solution: filter on the last-seen indexed field value instead of skipping rows.
     *   Page 1: WHERE Id > null ORDER BY Id ASC LIMIT 200
     *   Page 2: WHERE Id > <lastIdFromPage1> ORDER BY Id ASC LIMIT 200
     *
     * Requirements:
     *   - ORDER BY field must be unique (Id is ideal; external IDs work too)
     *   - Cursor value (lastSeenId) must be stored by the caller between pages
     *
     * @param lastSeenId  Last Id from previous page, or null for first page
     * @param pageSize    Records per page (max 2000 per SOQL call)
     * @return            Next page of Accounts ordered by Id ASC
     */
    public static List<Account> keysetPage(Id lastSeenId, Integer pageSize) {
        Integer size = Math.min(pageSize != null ? pageSize : 200, 2000);
        if (lastSeenId == null) {
            return [SELECT Id, Name, AnnualRevenue, Sync_Status__c
                    FROM   Account
                    ORDER  BY Id ASC
                    LIMIT  :size];
        }
        return [SELECT Id, Name, AnnualRevenue, Sync_Status__c
                FROM   Account
                WHERE  Id > :lastSeenId
                ORDER  BY Id ASC
                LIMIT  :size];
    }

    // ─── Selective filter composition ─────────────────────────────────────────

    /**
     * Demonstrates correct filter ordering for LDV query performance.
     *
     * Rule: always lead with the most selective indexed filter.
     * Standard indexed fields: Id, Name, OwnerId, CreatedDate, SystemModstamp,
     *   RecordTypeId, master-detail lookup fields, External ID fields, Unique fields.
     * NOT indexed: formula fields, long text areas, most picklists (unless custom-indexed).
     *
     * Interview Q: "What is a non-selective query?"
     *   A query where the optimizer cannot use an index — forces a full table scan.
     *   Salesforce throws a runtime error for non-selective queries on objects > 100K records
     *   when running synchronously. Async (Batch) allows full scans but with higher limits.
     *
     * @param startDate  Start of CloseDate range (indexed field — leads the filter)
     * @param endDate    End of CloseDate range
     * @param stage      StageName filter applied AFTER index scan (non-indexed, narrows set)
     */
    public static List<Opportunity> selectiveOpportunityQuery(
            Date startDate, Date endDate, String stage) {
        return [
            SELECT Id, Name, StageName, CloseDate, Amount, AccountId
            FROM   Opportunity
            WHERE  CloseDate >= :startDate   // indexed standard date field — selective
              AND  CloseDate <= :endDate      // tightens the indexed range
              AND  StageName  = :stage        // non-indexed — applied after index lookup
            ORDER BY CloseDate ASC
        ];
    }

    // ─── COUNT without loading records ────────────────────────────────────────

    /**
     * Returns a count without transferring record data — zero heap cost.
     * Use to gate batch Apex invocation: if count > threshold, enqueue batch.
     *
     * SELECT COUNT() (no field) → returns Integer directly.
     * SELECT COUNT(Id) → returns AggregateResult — less efficient for this purpose.
     */
    public static Integer countPendingAccounts() {
        return [SELECT COUNT() FROM Account WHERE Sync_Status__c = 'Pending'];
    }

    /**
     * Decides whether to process inline (small set) or via Batch Apex (large set).
     * LDV gate pattern — prevents heap overflow in synchronous context.
     *
     * @param batchThreshold  Enqueue batch when pending count exceeds this
     * @return                JobId if batch enqueued, null if processed inline
     */
    public static Id processOrEnqueue(Integer batchThreshold) {
        Integer pending = countPendingAccounts();
        if (pending > batchThreshold) {
            return Database.executeBatch(new AccountRatingBatch(), 200);
        }
        // Inline processing for small sets
        bulkUpdateSyncStatus('Pending', 'Synced');
        return null;
    }

    // ─── FOR UPDATE row locking ───────────────────────────────────────────────

    /**
     * Locks records for the duration of the current transaction.
     * Prevents concurrent Queueable/Batch jobs from processing the same records.
     *
     * Interview points:
     *   - FOR UPDATE acquires a row-level lock immediately on SELECT
     *   - Lock is held until transaction commits or rolls back
     *   - Deadlock risk: if two transactions lock the same rows in different orders,
     *     Salesforce detects the deadlock and throws a runtime exception on one of them
     *   - Best practice: always lock in Id-ascending order to enforce consistent ordering
     *   - Cannot be used in Batch Apex execute() — use pessimistic locking sparingly
     *
     * @param ids  Record IDs to lock — should be sorted ascending before calling
     */
    public static List<Account> lockForProcessing(Set<Id> ids) {
        return [
            SELECT Id, Sync_Status__c, Name
            FROM   Account
            WHERE  Id IN :ids
              AND  Sync_Status__c = 'Pending'
            FOR    UPDATE
        ];
    }

    // ─── Heap-safe aggregate rollup ───────────────────────────────────────────

    /**
     * Uses AggregateResult instead of loading parent + children to compute totals.
     * O(groups) heap instead of O(all child records) — essential for LDV children.
     *
     * Interview pattern: "How do you sum child records without loading them?"
     *   → AggregateResult GROUP BY with SUM/COUNT — single query, minimal heap.
     *
     * @param accountIds  Parent Account IDs
     * @return            Map of AccountId → total Opportunity Amount
     */
    public static Map<Id, Decimal> getOpportunityTotals(Set<Id> accountIds) {
        Map<Id, Decimal> totals = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT AccountId, SUM(Amount) total
            FROM   Opportunity
            WHERE  AccountId IN :accountIds
              AND  IsWon      = true
            GROUP BY AccountId
        ]) {
            totals.put((Id) ar.get('AccountId'), (Decimal) ar.get('total'));
        }
        return totals;
    }

    // ─── Strategy interface ───────────────────────────────────────────────────

    /**
     * Strategy for processing chunked records from the FOR LOOP pattern.
     * Implementations receive exactly 200 records per call (last chunk may be fewer).
     */
    public interface ChunkProcessor {
        void process(List<Account> chunk);
    }
}
