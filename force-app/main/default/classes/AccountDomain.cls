/**
 * @description Domain layer for Account — enforces object-level business invariants.
 *
 *              Day 22 update: now implements IAccountDomain for the SoC / fflib
 *              Dependency Injection pattern. Instance methods enable constructor-
 *              injection of records and clean unit testing without DML.
 *
 *              Domain vs Service distinction:
 *                - Domain: rules about what an Account IS or CAN BE (invariants)
 *                - Service: rules about what an Account DOES to other records (orchestration)
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class AccountDomain implements IAccountDomain {

    private final List<Account> records;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor — called by Application.Domain.newInstance(records)
    // ─────────────────────────────────────────────────────────────────────────

    public AccountDomain(List<Account> records) {
        this.records = records != null ? records : new List<Account>();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAccountDomain — trigger lifecycle hooks
    // ─────────────────────────────────────────────────────────────────────────

    public void onBeforeInsert() {
        applyDefaults();
        validateRequiredFields();
    }

    public void onBeforeUpdate(Map<Id, Account> existingRecords) {
        validateRequiredFields();
        preventDowngrade(existingRecords);
    }

    public void onAfterInsert() {}

    public void onAfterUpdate(Map<Id, Account> existingRecords) {}

    // ─────────────────────────────────────────────────────────────────────────
    // Validation
    // ─────────────────────────────────────────────────────────────────────────

    public void validateRequiredFields() {
        for (Account acc : records) {
            if (String.isBlank(acc.Name)) {
                acc.Name.addError('Account Name is required.');
            }
            if (acc.AnnualRevenue != null && acc.AnnualRevenue < 0) {
                acc.AnnualRevenue.addError('Annual Revenue cannot be negative.');
            }
        }
    }

    /** Prevents downgrading a Strategic account to Prospect. */
    @TestVisible
    private void preventDowngrade(Map<Id, Account> existingRecords) {
        for (Account acc : records) {
            Account old = existingRecords.get(acc.Id);
            if (old == null) { continue; }
            if (old.Type == 'Strategic' && acc.Type == 'Prospect') {
                acc.Type.addError(
                    'A Strategic account cannot be downgraded to Prospect.');
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Defaulting
    // ─────────────────────────────────────────────────────────────────────────

    public void applyDefaults() {
        for (Account acc : records) {
            if (String.isBlank(acc.Rating))         { acc.Rating         = 'Cold'; }
            if (String.isBlank(acc.Sync_Status__c)) { acc.Sync_Status__c = 'Pending'; }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Accessors and filters
    // ─────────────────────────────────────────────────────────────────────────

    public List<Account> getRecords() { return records; }

    /**
     * Returns only records where any of the specified fields changed.
     * @param existingRecords  Trigger.oldMap
     * @param fields           Set of field API names to watch
     */
    public List<Account> getChangedRecords(
            Map<Id, Account> existingRecords, Set<String> fields) {
        List<Account> changed = new List<Account>();
        for (Account acc : records) {
            Account old = existingRecords.get(acc.Id);
            if (old == null) { changed.add(acc); continue; }
            for (String field : fields) {
                if (acc.get(field) != old.get(field)) { changed.add(acc); break; }
            }
        }
        return changed;
    }

    /** Returns accounts that just transitioned TO Pending sync status. */
    @TestVisible
    List<Account> getNewlySyncPending(Map<Id, Account> existingRecords) {
        List<Account> result = new List<Account>();
        for (Account acc : records) {
            Account old = existingRecords.get(acc.Id);
            if (old != null
                    && acc.Sync_Status__c == 'Pending'
                    && old.Sync_Status__c != 'Pending') {
                result.add(acc);
            }
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Legacy static method — preserved from Day 1 for backward compatibility
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Prevents an Account from being downgraded from Type = 'Customer'
     *              to Type = 'Prospect' if it has Closed Won opportunities.
     *              Called from AccountTriggerHandler (static entry point, Day 1).
     */
    public static void validateTypeDowngrade(
            List<Account> newAccounts, Map<Id, Account> oldMap) {
        Map<Id, Account> downgradeCandidates = new Map<Id, Account>();
        for (Account acc : newAccounts) {
            Account oldAcc = oldMap.get(acc.Id);
            if (oldAcc != null && oldAcc.Type == 'Customer' && acc.Type == 'Prospect') {
                downgradeCandidates.put(acc.Id, acc);
            }
        }
        if (downgradeCandidates.isEmpty()) { return; }

        Map<Id, Integer> closedWonCount = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT AccountId, COUNT(Id) wonCount
            FROM   Opportunity
            WHERE  AccountId IN :downgradeCandidates.keySet()
              AND  StageName = 'Closed Won'
            GROUP  BY AccountId
        ]) {
            closedWonCount.put((Id) ar.get('AccountId'), (Integer) ar.get('wonCount'));
        }
        for (Id accId : downgradeCandidates.keySet()) {
            if (closedWonCount.containsKey(accId)) {
                downgradeCandidates.get(accId).addError(
                    'Cannot revert to Prospect: this account has '
                    + closedWonCount.get(accId) + ' Closed Won opportunity(ies).');
            }
        }
    }
}
