/**
 * @description Domain layer for Account — enforces object-level business invariants
 *              that are intrinsic to the Account record itself (as opposed to
 *              cross-object orchestration which belongs in AccountService).
 *
 *              Domain vs Service distinction:
 *                - Domain: rules about what an Account IS or CAN BE (invariants)
 *                - Service: rules about what an Account DOES to other records (orchestration)
 *
 *              Called from AccountTriggerHandler before update context so that
 *              addError() prevents the DML from committing.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class AccountDomain {

    /**
     * @description Prevents an Account from being downgraded from Type = 'Customer'
     *              back to Type = 'Prospect' if it has Closed Won opportunities.
     *              A customer with revenue history cannot be reclassified as a prospect —
     *              this would corrupt pipeline and forecasting reports.
     *
     *              Uses a single aggregate SOQL scoped to only the accounts attempting
     *              the downgrade, not the full trigger batch.
     *
     * @param newAccounts  Trigger.new — records being updated
     * @param oldMap       Trigger.oldMap — records before update
     */
    public static void validateTypeDowngrade(
        List<Account> newAccounts,
        Map<Id, Account> oldMap
    ) {
        // Collect only the accounts attempting Customer → Prospect type change
        Map<Id, Account> downgradeCandidates = new Map<Id, Account>();
        for (Account acc : newAccounts) {
            Account oldAcc = oldMap.get(acc.Id);
            if (oldAcc != null
                    && oldAcc.Type == 'Customer'
                    && acc.Type    == 'Prospect') {
                downgradeCandidates.put(acc.Id, acc);
            }
        }
        if (downgradeCandidates.isEmpty()) { return; }

        // Single aggregate SOQL — count Closed Won per candidate account
        Map<Id, Integer> closedWonCountByAccountId = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT AccountId, COUNT(Id) wonCount
            FROM   Opportunity
            WHERE  AccountId IN :downgradeCandidates.keySet()
              AND  StageName = 'Closed Won'
            GROUP  BY AccountId
        ]) {
            closedWonCountByAccountId.put(
                (Id)      ar.get('AccountId'),
                (Integer) ar.get('wonCount')
            );
        }

        for (Id accId : downgradeCandidates.keySet()) {
            if (closedWonCountByAccountId.containsKey(accId)) {
                downgradeCandidates.get(accId).addError(
                    'Cannot revert to Prospect: this account has '
                    + closedWonCountByAccountId.get(accId)
                    + ' Closed Won opportunity(ies). Update the account type manually'
                    + ' via your administrator if reclassification is required.'
                );
            }
        }
    }
}
