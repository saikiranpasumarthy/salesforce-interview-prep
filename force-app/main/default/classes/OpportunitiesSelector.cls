/**
 * @description Selector for the Opportunity SObject.
 *
 *              Centralises all Opportunity SOQL — including the sub-queries and
 *              aggregate queries that would otherwise be scattered across batch classes,
 *              service methods, and trigger handlers. Selectors are `with sharing`
 *              by default; individual queries can be moved to a separate
 *              `without sharing` selector when elevated access is justified.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class OpportunitiesSelector implements ISelector {

    // ─── ISelector contract ───────────────────────────────────────────────────────

    public SObjectType getSObjectType() {
        return Opportunity.SObjectType;
    }

    /**
     * @description Fetches Opportunities by Id with the default field set.
     *              Includes Day 5 custom pricing fields.
     *
     * @param idSet  Set of Opportunity Ids.
     * @return       Opportunity records ordered by CloseDate descending.
     */
    public List<SObject> selectById(Set<Id> idSet) {
        return [
            SELECT Id, Name, AccountId, StageName, Amount, CloseDate,
                   Type, IsWon, IsClosed,
                   Discount_Percent__c, Final_Price__c
            FROM   Opportunity
            WHERE  Id IN :idSet
            WITH   SECURITY_ENFORCED
            ORDER BY CloseDate DESC
        ];
    }

    /**
     * @description Streams all Opportunities for Batch Apex processing.
     *
     * @param whereClause  Optional WHERE fragment; null = all records.
     * @return             QueryLocator.
     */
    public Database.QueryLocator getQueryLocator(String whereClause) {
        String soql = 'SELECT Id, Name, AccountId, StageName, Amount, CloseDate, '
                    + 'Type, IsWon, IsClosed, Discount_Percent__c, Final_Price__c '
                    + 'FROM Opportunity '
                    + (String.isBlank(whereClause) ? '' : 'WHERE ' + whereClause + ' ')
                    + 'WITH SECURITY_ENFORCED ORDER BY CloseDate DESC';
        return Database.getQueryLocator(soql);
    }

    // ─── Domain-specific queries ──────────────────────────────────────────────────

    /**
     * @description Fetches all Opportunities for given Account Ids.
     *              Results ordered by CloseDate descending — most recent first.
     *
     * @param accountIds  Set of Account Ids.
     * @return            Related Opportunities.
     */
    public List<Opportunity> selectByAccountId(Set<Id> accountIds) {
        return [
            SELECT Id, Name, AccountId, StageName, Amount, CloseDate,
                   Type, IsWon, IsClosed, Discount_Percent__c, Final_Price__c
            FROM   Opportunity
            WHERE  AccountId IN :accountIds
            WITH   SECURITY_ENFORCED
            ORDER BY CloseDate DESC
        ];
    }

    /**
     * @description Fetches Closed Won Opportunities for the given Account Ids.
     *              Used by OpportunityRollupBatch as an alternative to a full scan
     *              when processing a targeted subset of accounts.
     *
     * @param accountIds  Set of Account Ids.
     * @return            Closed Won Opportunities ordered by CloseDate descending.
     */
    public List<Opportunity> selectClosedWonByAccountId(Set<Id> accountIds) {
        return [
            SELECT Id, Name, AccountId, Amount, CloseDate
            FROM   Opportunity
            WHERE  AccountId IN :accountIds
            AND    IsWon = true
            WITH   SECURITY_ENFORCED
            ORDER BY CloseDate DESC
        ];
    }

    /**
     * @description Returns aggregate revenue and count per Account.
     *              Replaces the inline aggregate query in OpportunityRollupBatch —
     *              by housing it here, the batch's execute() method stays focused
     *              on orchestration rather than query construction.
     *
     *              NOTE: Returns AggregateResult[] because SOQL GROUP BY cannot
     *              be typed as List<Opportunity>.
     *
     * @param accountIds  Set of Account Ids to aggregate over.
     * @return            One AggregateResult per Account with:
     *                    AccountId, totalRevenue (SUM), oppCount (COUNT).
     */
    public List<AggregateResult> selectRevenueByAccount(Set<Id> accountIds) {
        return [
            SELECT   AccountId,
                     SUM(Amount) totalRevenue,
                     COUNT(Id)   oppCount
            FROM     Opportunity
            WHERE    AccountId IN :accountIds
            AND      IsWon = true
            WITH     SECURITY_ENFORCED
            GROUP BY AccountId
        ];
    }

    /**
     * @description Fetches open (non-closed) Opportunities for given Account Ids.
     *              Used by AccountsSelector.selectWithOpenOpportunities() and
     *              directly by handlers that need the child list without the parent.
     *
     * @param accountIds  Set of Account Ids.
     * @return            Open Opportunities ordered by CloseDate ascending
     *                    (soonest-closing first).
     */
    public List<Opportunity> selectOpenByAccountId(Set<Id> accountIds) {
        return [
            SELECT Id, Name, AccountId, StageName, Amount, CloseDate
            FROM   Opportunity
            WHERE  AccountId IN :accountIds
            AND    IsClosed = false
            WITH   SECURITY_ENFORCED
            ORDER BY CloseDate ASC
        ];
    }
}
