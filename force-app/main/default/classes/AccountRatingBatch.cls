/**
 * @description Batch job that re-rates every Account based on AnnualRevenue against
 *              Account_Rating_Config__mdt thresholds. Designed for nightly scheduled
 *              execution or on-demand re-calculation after threshold changes.
 *
 *              Design decisions:
 *                - Reuses AccountService.applyRatingFromRevenue() — business logic is
 *                  never duplicated between trigger path and batch path.
 *                - CMDT configs are loaded once in start() and stored as an instance
 *                  variable. Each execute() call reuses the same list instead of
 *                  re-querying — avoids one SOQL per chunk.
 *                - DEFAULT_SCOPE = 200 — matches the trigger batch size so the same
 *                  logic is exercised at the same scale in both execution paths.
 *                - QueryLocator (vs Iterable) — supports up to 50M records. Use
 *                  Iterable<SObject> only when you need complex in-memory pre-filtering
 *                  that SOQL WHERE clauses cannot express.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class AccountRatingBatch implements Database.Batchable<SObject> {

    /** Recommended scope for DML and heap safety. Pass to Database.executeBatch(). */
    public static final Integer DEFAULT_SCOPE = 200;

    // Instance variable — survives across execute() calls (no Database.Stateful needed
    // here because we only READ this; we don't accumulate into it across chunks).
    private List<Account_Rating_Config__mdt> ratingConfigs;

    // Optional: scope a run to a specific record type or industry segment
    private String additionalFilter;

    public AccountRatingBatch() {
        this(null);
    }

    public AccountRatingBatch(String additionalFilter) {
        this.additionalFilter = additionalFilter;
    }

    // ─── Batchable Interface ──────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        // Load CMDT once — stored in instance variable, reused by every execute() chunk
        ratingConfigs = [
            SELECT Revenue_Threshold__c, Rating_Value__c
            FROM   Account_Rating_Config__mdt
            ORDER  BY Revenue_Threshold__c DESC
        ];

        // Dynamic SOQL allows optional additional filtering (e.g., by record type)
        String baseQuery =
            'SELECT Id, AnnualRevenue, Rating ' +
            'FROM Account ' +
            'WHERE AnnualRevenue != null';

        if (String.isNotBlank(additionalFilter)) {
            baseQuery += ' AND ' + additionalFilter;
        }

        return Database.getQueryLocator(baseQuery);
    }

    public void execute(Database.BatchableContext ctx, List<Account> scope) {
        // Delegate to AccountService — same logic as the trigger path
        // scope is already bulk-safe (≤ DEFAULT_SCOPE records)
        AccountService.applyRatingFromRevenue(scope, ratingConfigs);

        // Partial DML — one failed record does not abort the rest of the chunk
        List<Database.SaveResult> results = Database.update(scope, false);
        logErrors(ctx, results);
    }

    public void finish(Database.BatchableContext ctx) {
        AsyncApexJob job = [
            SELECT Id, Status, NumberOfErrors, TotalJobItems, JobItemsProcessed,
                   CreatedDate, CompletedDate
            FROM   AsyncApexJob
            WHERE  Id = :ctx.getJobId()
        ];

        System.debug(
            LoggingLevel.INFO,
            'AccountRatingBatch finished. '
            + 'Status: '     + job.Status
            + ' | Chunks: '  + job.JobItemsProcessed + '/' + job.TotalJobItems
            + ' | Errors: '  + job.NumberOfErrors
        );

        // Day 3 addition: publish a Platform Event here to notify downstream systems
        // and trigger email alerts on batch failure (NumberOfErrors > 0).
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    private void logErrors(Database.BatchableContext ctx, List<Database.SaveResult> results) {
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) {
                for (Database.Error err : sr.getErrors()) {
                    System.debug(
                        LoggingLevel.ERROR,
                        'AccountRatingBatch | JobId: ' + ctx.getJobId()
                        + ' | RecordId: ' + sr.getId()
                        + ' | Status: '   + err.getStatusCode()
                        + ' | Message: '  + err.getMessage()
                    );
                }
            }
        }
    }
}
