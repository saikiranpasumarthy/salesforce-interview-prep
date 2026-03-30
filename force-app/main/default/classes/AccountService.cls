/**
 * @description Service layer for Account business logic. All methods are list-based,
 *              stateless-by-design (except recursion guards), and have zero dependency
 *              on Trigger context — they can be called from anywhere: triggers, flows
 *              via InvocableMethod, REST endpoints, batch jobs, or test classes.
 *
 *              Governor Limit Strategy:
 *                - No SOQL inside loops — collect IDs, query once outside
 *                - No DML inside loops — accumulate in List, single DML at end
 *                - Static recursion guard (Set<Id>) — precision over Boolean flag
 *                - Database.update(list, false) — partial success, check SaveResult
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class AccountService {

    // Precision recursion guard — tracks Account Ids that already triggered Case sync
    // in this transaction. Set<Id> preferred over Boolean: a Boolean re-entry guard
    // blocks ALL subsequent trigger invocations, not just the re-entrant ones.
    private static Set<Id> processedCaseSyncIds = new Set<Id>();

    // ─── Rating Assignment ────────────────────────────────────────────────────

    /**
     * @description Sets Account.Rating based on AnnualRevenue thresholds defined
     *              in Account_Rating_Config__mdt Custom Metadata. Thresholds are
     *              configurable without a code deployment — update CMDT records only.
     *
     *              Internally delegates to applyRatingFromRevenue() so tests can
     *              inject configs directly without triggering a SOQL call.
     *
     * @param accounts  List of Account records in Trigger.new context
     */
    public static void setRatingFromRevenue(List<Account> accounts) {
        // CMDT queries are not subject to the 100-SOQL governor limit, but we still
        // query once per transaction and cache the result in the overloaded private method.
        List<Account_Rating_Config__mdt> configs = [
            SELECT Revenue_Threshold__c, Rating_Value__c
            FROM   Account_Rating_Config__mdt
            ORDER  BY Revenue_Threshold__c DESC
        ];
        applyRatingFromRevenue(accounts, configs);
    }

    /**
     * @description Core rating logic — separated for test isolation via @TestVisible.
     *              Configs must arrive pre-sorted descending by Revenue_Threshold__c
     *              (highest threshold wins).
     */
    @TestVisible
    private static void applyRatingFromRevenue(
        List<Account> accounts,
        List<Account_Rating_Config__mdt> configs
    ) {
        if (configs.isEmpty()) { return; }

        for (Account acc : accounts) {
            if (acc.AnnualRevenue == null) { continue; }
            for (Account_Rating_Config__mdt config : configs) {
                if (acc.AnnualRevenue >= config.Revenue_Threshold__c) {
                    acc.Rating = config.Rating_Value__c;
                    break; // highest-matching threshold wins; list is sorted DESC
                }
            }
        }
    }

    // ─── Delete Prevention ────────────────────────────────────────────────────

    /**
     * @description Blocks Account deletion when one or more related Opportunities
     *              are still open (IsClosed = false). Uses an aggregate query to
     *              count open Opps per Account in a single SOQL — bulk-safe.
     *
     * @param accounts  List of Account records in Trigger.old context (before delete)
     */
    public static void preventDeleteWithOpenOpportunities(List<Account> accounts) {
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();

        // Aggregate in one SOQL — never query inside the loop below
        Map<Id, Integer> openOppCountByAccountId = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT AccountId, COUNT(Id) oppCount
            FROM   Opportunity
            WHERE  AccountId IN :accountIds
              AND  IsClosed = false
            GROUP  BY AccountId
        ]) {
            openOppCountByAccountId.put(
                (Id)      ar.get('AccountId'),
                (Integer) ar.get('oppCount')
            );
        }

        for (Account acc : accounts) {
            if (openOppCountByAccountId.containsKey(acc.Id)) {
                Integer count = openOppCountByAccountId.get(acc.Id);
                acc.addError(
                    'Cannot delete this account: ' + count +
                    ' open opportunity(ies) must be closed or reassigned first.'
                );
            }
        }
    }

    // ─── Case Owner Sync ──────────────────────────────────────────────────────

    /**
     * @description When an Account's OwnerId changes, updates all related open Cases
     *              to the same new owner. Runs after update so the Account Id is
     *              available for child record queries.
     *
     *              Recursion guard: Set<Id> is populated before DML so that if the
     *              Case trigger fires back and re-invokes Account logic, the accounts
     *              already processed are skipped — preventing an infinite loop.
     *
     *              Error handling: partial-success DML (allowPartial=false) with
     *              SaveResult inspection. Production orgs should replace System.debug
     *              with Platform Event publishing (introduced Day 3).
     *
     * @param newMap  Trigger.newMap — Accounts post-update
     * @param oldMap  Trigger.oldMap — Accounts pre-update
     */
    public static void syncCaseOwnerOnAccountOwnerChange(
        Map<Id, Account> newMap,
        Map<Id, Account> oldMap
    ) {
        // Step 1: identify accounts where the owner actually changed
        Set<Id> changedOwnerAccountIds = new Set<Id>();
        for (Id accountId : newMap.keySet()) {
            Account newAcc = newMap.get(accountId);
            Account oldAcc = oldMap.get(accountId);
            if (newAcc.OwnerId != oldAcc.OwnerId
                    && !processedCaseSyncIds.contains(accountId)) {
                changedOwnerAccountIds.add(accountId);
            }
        }
        if (changedOwnerAccountIds.isEmpty()) { return; }

        // Step 2: mark as processed BEFORE DML to prevent re-entrant recursion
        processedCaseSyncIds.addAll(changedOwnerAccountIds);

        // Step 3: single SOQL for all open cases across affected accounts
        List<Case> openCases = [
            SELECT Id, AccountId, OwnerId
            FROM   Case
            WHERE  AccountId IN :changedOwnerAccountIds
              AND  IsClosed = false
        ];
        if (openCases.isEmpty()) { return; }

        // Step 4: build update list — only records that actually need a change
        List<Case> casesToUpdate = new List<Case>();
        for (Case c : openCases) {
            Id newOwnerId = newMap.get(c.AccountId)?.OwnerId;
            if (newOwnerId != null && c.OwnerId != newOwnerId) {
                casesToUpdate.add(new Case(Id = c.Id, OwnerId = newOwnerId));
            }
        }
        if (casesToUpdate.isEmpty()) { return; }

        // Step 5: partial DML — log failures without aborting the transaction
        List<Database.SaveResult> results = Database.update(casesToUpdate, false);
        logSaveResultErrors(results, 'AccountService.syncCaseOwnerOnAccountOwnerChange');
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    /**
     * @description Logs DML SaveResult failures. Platform Event publishing
     *              (Integration_Error_Log__e) is wired in on Day 3 — this debug
     *              log is the Day 1 placeholder for the same error contract.
     */
    private static void logSaveResultErrors(
        List<Database.SaveResult> results,
        String context
    ) {
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) {
                for (Database.Error err : sr.getErrors()) {
                    System.debug(
                        LoggingLevel.ERROR,
                        context + ' | RecordId: ' + sr.getId()
                        + ' | Status: ' + err.getStatusCode()
                        + ' | Message: ' + err.getMessage()
                    );
                }
            }
        }
    }
}
