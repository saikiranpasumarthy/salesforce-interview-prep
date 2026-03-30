/**
 * @description Stateful batch that calculates total Closed Won revenue per Account
 *              and writes the result to Account.Total_Closed_Won_Revenue__c.
 *
 *              Why Database.Stateful is required here:
 *                Without it, Salesforce serializes and deserializes the batch instance
 *                between execute() calls. Instance variables are RESET to their
 *                constructor-initialized values on each chunk. The revenueTotals Map
 *                would be empty at the start of every execute() — you'd only ever see
 *                the last chunk's data. Database.Stateful tells the platform to preserve
 *                instance state across chunks.
 *
 *              Performance trade-off:
 *                Stateful batches serialize the entire instance to the database between
 *                chunks. Large Maps or Lists in instance variables inflate this payload,
 *                slow down chunk transitions, and can cause heap limit failures. Store
 *                only IDs and primitives in stateful variables — never full SObjects.
 *
 *              Pattern demonstrated:
 *                start()   → query source records (Opportunity)
 *                execute() → accumulate into stateful Map (no DML here)
 *                finish()  → single bulk DML on parent records (Account)
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class OpportunityRollupBatch
    implements Database.Batchable<SObject>, Database.Stateful {

    public static final Integer DEFAULT_SCOPE = 2000; // Opportunities are read-only here

    // ─── Stateful Variables ───────────────────────────────────────────────────
    // These survive serialization/deserialization between execute() chunks.
    // Store primitives only — Decimal and Id are safe. Full SObjects would bloat heap.

    @TestVisible private Map<Id, Decimal> revenueTotals   = new Map<Id, Decimal>();
    @TestVisible private Integer          totalOppsScanned = 0;
    @TestVisible private Integer          totalErrors      = 0;

    // ─── Batchable Interface ──────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        // Reset accumulators — supports re-running the batch without stale data
        revenueTotals    = new Map<Id, Decimal>();
        totalOppsScanned = 0;
        totalErrors      = 0;

        return Database.getQueryLocator([
            SELECT Id, AccountId, Amount
            FROM   Opportunity
            WHERE  StageName  = 'Closed Won'
              AND  AccountId  != null
              AND  Amount     != null
        ]);
    }

    public void execute(Database.BatchableContext ctx, List<Opportunity> scope) {
        // Accumulate revenue by Account — no SOQL, no DML in execute()
        // This runs inside the stateful serialization boundary
        for (Opportunity opp : scope) {
            Decimal current = revenueTotals.containsKey(opp.AccountId)
                ? revenueTotals.get(opp.AccountId)
                : 0;
            revenueTotals.put(opp.AccountId, current + opp.Amount);
        }
        totalOppsScanned += scope.size();
    }

    public void finish(Database.BatchableContext ctx) {
        if (revenueTotals.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'OpportunityRollupBatch: No Closed Won Opportunities found. '
                + 'Total_Closed_Won_Revenue__c not updated.');
            return;
        }

        // Build Account update list — one record per Account, minimum field set
        List<Account> accountsToUpdate = new List<Account>();
        for (Id accountId : revenueTotals.keySet()) {
            accountsToUpdate.add(new Account(
                Id                         = accountId,
                Total_Closed_Won_Revenue__c = revenueTotals.get(accountId)
            ));
        }

        // Partial DML — one bad Account does not abort the rest
        List<Database.SaveResult> results = Database.update(accountsToUpdate, false);

        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) {
                totalErrors++;
                for (Database.Error err : sr.getErrors()) {
                    System.debug(
                        LoggingLevel.ERROR,
                        'OpportunityRollupBatch.finish | AccountId: ' + sr.getId()
                        + ' | Status: ' + err.getStatusCode()
                        + ' | Message: ' + err.getMessage()
                    );
                }
            }
        }

        System.debug(
            LoggingLevel.INFO,
            'OpportunityRollupBatch complete. '
            + 'Opps scanned: '      + totalOppsScanned
            + ' | Accounts updated: ' + (accountsToUpdate.size() - totalErrors)
            + ' | Errors: '           + totalErrors
        );

        // Day 3 addition: fire Platform Event to trigger email notification on errors.
    }
}
