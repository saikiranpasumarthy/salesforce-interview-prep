/**
 * @description Service for archiving closed Case records to the Case_Archive__b
 *              Custom Big Object. Demonstrates Big Object patterns: insertImmediate(),
 *              index-constrained queries, and the archival pipeline design.
 *
 *              Big Object fundamentals:
 *                - Custom Big Objects (suffix __b) store massive datasets outside the
 *                  standard object storage limits (e.g., 10B+ records).
 *                - No triggers, workflows, or Flow support — Big Objects are write-once
 *                  data stores with no automation.
 *                - DML: Database.insertImmediate() only. No update, no delete.
 *                  (To "delete", you must drop and recreate the Big Object with new index.)
 *                - SOQL queries MUST include leading index fields in exact order.
 *                  A query on Closed_Date__c alone (without Account_Id__c first) throws
 *                  an error — the composite index requires the leading field.
 *                - No relationship queries — no Account.Name traversal, no sub-queries.
 *                - No SOSL — Big Objects are not full-text indexed.
 *
 *              Index for Case_Archive__b (defined in metadata):
 *                  Account_Id__c (ASC) → Closed_Date__c (DESC) → Case_Id__c (ASC)
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class CaseArchiveService {

    /**
     * @description Archives Closed Cases older than the specified number of days
     *              to Case_Archive__b. Designed to be called from Batch Apex (Day 2)
     *              or a Scheduled Apex job (Day 3) for nightly archival pipelines.
     *
     *              Pipeline pattern:
     *                1. Query Cases meeting archival criteria (IsClosed + age threshold)
     *                2. Map Case fields to Big Object fields
     *                3. insertImmediate() — synchronous, returns SaveResult list
     *                4. Log failures via IntegrationErrorLogger
     *
     *              Note: This method does NOT delete Cases after archival. Deletion
     *              is a separate, audited step once the archive is verified. Combining
     *              archive + delete in one transaction risks data loss if archive fails.
     *
     * @param daysOld     Only archive Cases closed more than this many days ago
     * @param batchSize   Max Cases to archive per call (caller-controlled for governor limits)
     * @return Number of Cases successfully archived
     */
    public static Integer archiveClosedCases(Integer daysOld, Integer batchSize) {
        DateTime thresholdDateTime = DateTime.now().addDays(-daysOld);
        Integer safeLimit = Math.min(batchSize, 200);

        List<Case> casesToArchive = [
            SELECT Id, Subject, Status, Priority, AccountId, OwnerId, ClosedDate
            FROM   Case
            WHERE  IsClosed    = true
              AND  ClosedDate  < :thresholdDateTime
              AND  AccountId  != null    // Big Object requires non-null Account_Id__c index field
            ORDER  BY ClosedDate ASC    // archive oldest first
            LIMIT  :safeLimit
        ];

        if (casesToArchive.isEmpty()) { return 0; }

        List<Case_Archive__b> archives = mapCasesToArchives(casesToArchive);

        // insertImmediate — the ONLY write operation supported on Big Objects.
        // Returns SaveResult like Database.insert. allowPartial behaviour is built-in.
        List<Database.SaveResult> results = Database.insertImmediate(archives);
        IntegrationErrorLogger.logSaveResults(results, 'CaseArchiveService.archiveClosedCases');

        Integer successCount = 0;
        for (Database.SaveResult sr : results) {
            if (sr.isSuccess()) { successCount++; }
        }
        return successCount;
    }

    /**
     * @description Queries archived Cases for a specific Account within a date range.
     *
     *              Big Object query rules enforced here:
     *                1. Leading index field (Account_Id__c) MUST be in WHERE with = operator
     *                2. Second index field (Closed_Date__c) uses >= range filter
     *                3. Third index field (Case_Id__c) is optional but must follow order
     *                4. No non-index fields in WHERE clause
     *                5. No ORDER BY on non-index fields
     *
     * @param accountId  Account whose archived Cases to retrieve (required — leading index)
     * @param fromDate   Start of date range for Closed_Date__c filter
     * @return Archived Case records within the specified window
     */
    public static List<Case_Archive__b> getArchivedCasesForAccount(
        String accountId,
        DateTime fromDate
    ) {
        if (String.isBlank(accountId)) { return new List<Case_Archive__b>(); }

        return [
            SELECT Case_Id__c, Account_Id__c, Subject__c, Status__c,
                   Priority__c, Owner_Id__c, Closed_Date__c
            FROM   Case_Archive__b
            WHERE  Account_Id__c  = :accountId      // leading index field — required
              AND  Closed_Date__c >= :fromDate       // second index field — range filter
            ORDER  BY Closed_Date__c DESC
            LIMIT  200
        ];
    }

    /**
     * @description Count of archived cases for an Account — useful for
     *              dashboard widgets without loading full records.
     *              Uses COUNT() aggregate — supported on Big Objects.
     *
     * @param accountId  Account to count archived cases for
     * @return Total number of archived Case records
     */
    public static Integer countArchivedCasesForAccount(String accountId) {
        if (String.isBlank(accountId)) { return 0; }
        List<AggregateResult> result = [
            SELECT COUNT(Case_Id__c) total
            FROM   Case_Archive__b
            WHERE  Account_Id__c = :accountId
        ];
        return result.isEmpty() ? 0 : (Integer) result[0].get('total');
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    @TestVisible
    private static List<Case_Archive__b> mapCasesToArchives(List<Case> cases) {
        List<Case_Archive__b> archives = new List<Case_Archive__b>();
        for (Case c : cases) {
            archives.add(new Case_Archive__b(
                Case_Id__c     = c.Id,
                Account_Id__c  = c.AccountId,
                Subject__c     = c.Subject?.abbreviate(255),
                Status__c      = c.Status,
                Priority__c    = c.Priority,
                Owner_Id__c    = c.OwnerId,
                Closed_Date__c = c.ClosedDate
            ));
        }
        return archives;
    }
}
