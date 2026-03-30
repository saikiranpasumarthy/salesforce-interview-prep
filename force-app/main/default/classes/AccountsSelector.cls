/**
 * @description Selector for the Account SObject.
 *
 *              All SOQL queries against Account are defined here — nowhere else.
 *              Benefits of this centralisation:
 *                - Field changes (add/remove) propagate everywhere by editing one class
 *                - Sharing enforcement is consistent (`with sharing` declared once)
 *                - Query plans are predictable — no ad-hoc SOQL scattered in triggers
 *                - BatchApex start() calls getQueryLocator() from here, keeping
 *                  AccountRatingBatch's start() a one-liner
 *
 *              Naming convention: method name describes the WHERE clause, not the SObject.
 *              `selectByOwnerId` is clearer than `getAccountsByOwner`.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class AccountsSelector implements ISelector {

    // ─── ISelector contract ───────────────────────────────────────────────────────

    public SObjectType getSObjectType() {
        return Account.SObjectType;
    }

    /**
     * @description Fetches Accounts by Id with the full default field set.
     *              Used as the base query by service and handler classes.
     *
     * @param idSet  Set of Account Ids to fetch.
     * @return       Account records ordered by Name ascending.
     */
    public List<SObject> selectById(Set<Id> idSet) {
        return [
            SELECT Id, Name, OwnerId, Type, Rating,
                   AnnualRevenue, Total_Closed_Won_Revenue__c, CreatedDate
            FROM   Account
            WHERE  Id IN :idSet
            WITH   SECURITY_ENFORCED
            ORDER BY Name ASC
        ];
    }

    /**
     * @description Returns a QueryLocator for use in Batch Apex start().
     *              Replaces the inline SOQL in AccountRatingBatch — the batch class
     *              delegates here for a consistent, testable query definition.
     *
     * @param whereClause  Optional WHERE fragment (e.g. 'AnnualRevenue > 0').
     *                     Pass null or blank to retrieve all Accounts.
     * @return             QueryLocator streaming Account records.
     */
    public Database.QueryLocator getQueryLocator(String whereClause) {
        String soql = 'SELECT Id, Name, OwnerId, Type, Rating, '
                    + 'AnnualRevenue, Total_Closed_Won_Revenue__c, CreatedDate '
                    + 'FROM Account '
                    + (String.isBlank(whereClause) ? '' : 'WHERE ' + whereClause + ' ')
                    + 'WITH SECURITY_ENFORCED ORDER BY Name ASC';
        return Database.getQueryLocator(soql);
    }

    // ─── Domain-specific queries ──────────────────────────────────────────────────

    /**
     * @description Selects Accounts owned by the given User Ids.
     *              Used in territory re-assignment and ownership-audit reports.
     *
     * @param ownerIds  Set of User Ids.
     * @return          Matching Accounts ordered by Name.
     */
    public List<Account> selectByOwnerId(Set<Id> ownerIds) {
        return [
            SELECT Id, Name, OwnerId, Type, Rating, AnnualRevenue
            FROM   Account
            WHERE  OwnerId IN :ownerIds
            WITH   SECURITY_ENFORCED
            ORDER BY Name ASC
        ];
    }

    /**
     * @description Fetches Accounts with their open Opportunities in a
     *              parent-to-child sub-query.
     *
     *              Sub-query cap: Salesforce enforces a 200-record limit per child
     *              sub-query result set. For accounts with > 200 open Opps, use a
     *              separate OpportunitiesSelector.selectByAccountId() call instead.
     *
     * @param accountIds  Set of Account Ids.
     * @return            Accounts with Opportunities relationship populated.
     */
    public List<Account> selectWithOpenOpportunities(Set<Id> accountIds) {
        return [
            SELECT Id, Name, Type,
                (SELECT Id, Name, StageName, Amount, CloseDate
                 FROM   Opportunities
                 WHERE  IsClosed = false
                 ORDER BY CloseDate ASC
                 LIMIT  200)
            FROM   Account
            WHERE  Id IN :accountIds
            WITH   SECURITY_ENFORCED
        ];
    }

    /**
     * @description Finds Accounts whose AnnualRevenue exceeds a threshold.
     *              Demonstrates a parameterised, reusable query.
     *
     * @param revenueThreshold  Minimum AnnualRevenue value.
     * @return                  Matching Accounts ordered by AnnualRevenue descending.
     */
    public List<Account> selectByMinRevenue(Decimal revenueThreshold) {
        return [
            SELECT Id, Name, AnnualRevenue, Rating, Type
            FROM   Account
            WHERE  AnnualRevenue >= :revenueThreshold
            WITH   SECURITY_ENFORCED
            ORDER BY AnnualRevenue DESC
        ];
    }
}
