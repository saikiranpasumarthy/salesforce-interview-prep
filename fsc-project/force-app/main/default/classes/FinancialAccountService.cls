/**
 * FinancialAccountService
 * Core service for FSC wealth management operations.
 *
 * Responsibilities:
 *   - Household net worth calculation (sum of active FinancialAccount__c balances)
 *   - Portfolio health banding (GREEN / YELLOW / RED)
 *   - Rebalance alert detection (allocation deviation > threshold)
 *   - Balance sync from core banking (HTTP callout via Named Credential)
 *   - Household rollup update (called from trigger handler)
 */
public with sharing class FinancialAccountService {

    // ── Portfolio health thresholds ──────────────────────────────────────────
    @TestVisible static final Decimal GREEN_MIN_BALANCE  = 10000;
    @TestVisible static final Decimal YELLOW_MIN_BALANCE = 1000;
    // < YELLOW_MIN_BALANCE → RED

    // ── Rebalance alert: flag if any single account > this % of total net worth
    @TestVisible static final Decimal CONCENTRATION_THRESHOLD_PCT = 60.0;

    // ─────────────────────────────────────────────────────────────────────────
    // NET WORTH
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns the total net worth for a single household (sum of active FA balances).
     * Uses WITH USER_MODE to enforce FLS.
     */
    public Decimal householdNetWorth(Id householdId) {
        Decimal total = 0;
        for (FinancialAccount__c fa : [
            SELECT Balance__c
            FROM   FinancialAccount__c
            WHERE  Account__c = :householdId
            AND    IsActive__c = true
            WITH   USER_MODE
        ]) {
            total += (fa.Balance__c != null ? fa.Balance__c : 0);
        }
        return total;
    }

    /**
     * Recalculates net worth for multiple households and writes it back
     * to Account.NetWorth__c (custom field on Account — add as needed).
     * Called from trigger handler after insert/update/delete.
     */
    public void recalculateHouseholdNetWorth(Set<Id> householdIds) {
        // Aggregate balance per household
        Map<Id, Decimal> netWorthByHousehold = new Map<Id, Decimal>();
        for (Id hId : householdIds) {
            netWorthByHousehold.put(hId, 0);
        }

        for (AggregateResult ar : [
            SELECT Account__c acctId, SUM(Balance__c) totalBalance
            FROM   FinancialAccount__c
            WHERE  Account__c IN :householdIds
            AND    IsActive__c = true
            WITH   USER_MODE
            GROUP BY Account__c
        ]) {
            Id acctId    = (Id) ar.get('acctId');
            Decimal total = (Decimal) ar.get('totalBalance');
            netWorthByHousehold.put(acctId, total != null ? total : 0);
        }

        // Write back to Account
        List<Account> toUpdate = new List<Account>();
        for (Id hId : netWorthByHousehold.keySet()) {
            toUpdate.add(new Account(
                Id           = hId,
                NetWorth__c  = netWorthByHousehold.get(hId)
            ));
        }

        if (!toUpdate.isEmpty()) {
            update as user toUpdate;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PORTFOLIO HEALTH
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns a map of FinancialAccount__c Id → health band (GREEN/YELLOW/RED).
     * Operates on a pre-fetched list to allow easy testing without DML.
     */
    public Map<Id, String> portfolioHealth(List<FinancialAccount__c> accounts) {
        Map<Id, String> result = new Map<Id, String>();
        for (FinancialAccount__c fa : accounts) {
            result.put(fa.Id, computeHealthBand(fa.Balance__c));
        }
        return result;
    }

    /**
     * Fetches active accounts for a household and returns their health bands.
     */
    public Map<Id, String> portfolioHealthForHousehold(Id householdId) {
        List<FinancialAccount__c> accounts = [
            SELECT Id, Balance__c, AccountType__c
            FROM   FinancialAccount__c
            WHERE  Account__c = :householdId
            AND    IsActive__c = true
            WITH   USER_MODE
        ];
        return portfolioHealth(accounts);
    }

    @TestVisible
    static String computeHealthBand(Decimal balance) {
        if (balance == null || balance < YELLOW_MIN_BALANCE) return 'RED';
        if (balance < GREEN_MIN_BALANCE)                      return 'YELLOW';
        return 'GREEN';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // REBALANCE ALERT
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns a list of account IDs where a single account represents more than
     * CONCENTRATION_THRESHOLD_PCT of the household's total balance.
     * Used to flag concentration risk.
     */
    public List<Id> rebalanceAlerts(Id householdId) {
        List<FinancialAccount__c> accounts = [
            SELECT Id, Balance__c
            FROM   FinancialAccount__c
            WHERE  Account__c = :householdId
            AND    IsActive__c = true
            WITH   USER_MODE
        ];

        Decimal totalBalance = 0;
        for (FinancialAccount__c fa : accounts) {
            totalBalance += (fa.Balance__c != null ? fa.Balance__c : 0);
        }

        List<Id> alerts = new List<Id>();
        if (totalBalance == 0) return alerts;

        for (FinancialAccount__c fa : accounts) {
            Decimal balance = (fa.Balance__c != null ? fa.Balance__c : 0);
            Decimal pct     = (balance / totalBalance) * 100;
            if (pct > CONCENTRATION_THRESHOLD_PCT) {
                alerts.add(fa.Id);
            }
        }
        return alerts;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BALANCE SYNC (Core Banking Callout)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fetches the current balance for a single FinancialAccount__c from the
     * core banking system and updates the record.
     *
     * Named Credential: CoreBankingNC
     * Endpoint pattern: GET /accounts/{ExternalAccountId__c}
     * Response: { "balance": 12500.00, "currency": "USD", "status": "ACTIVE" }
     */
    public FinancialAccount__c syncBalanceFromCoreBanking(Id faId, String namedCredential) {
        FinancialAccount__c fa = [
            SELECT Id, ExternalAccountId__c, Balance__c
            FROM   FinancialAccount__c
            WHERE  Id = :faId
            WITH   USER_MODE
            LIMIT  1
        ];

        if (String.isBlank(fa.ExternalAccountId__c)) {
            throw new FinancialAccountException(
                'FinancialAccount__c ' + faId + ' has no ExternalAccountId__c — cannot sync.'
            );
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCredential + '/accounts/' + fa.ExternalAccountId__c);
        req.setMethod('GET');
        req.setTimeout(10000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new FinancialAccountException(
                'Core banking sync failed for ' + fa.ExternalAccountId__c +
                ' — HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Decimal newBalance = (Decimal) payload.get('balance');

        fa.Balance__c           = newBalance;
        fa.LastSyncedDateTime__c = Datetime.now();

        update as user fa;
        return fa;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INNER EXCEPTION
    // ─────────────────────────────────────────────────────────────────────────
    public class FinancialAccountException extends Exception {}
}
