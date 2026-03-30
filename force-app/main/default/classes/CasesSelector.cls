/**
 * @description Selector for the Case SObject.
 *
 *              Houses all Case SOQL — status filtering, account scoping,
 *              and bulk batch queries. Follows the same `with sharing` + explicit
 *              field list convention as AccountsSelector and OpportunitiesSelector.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class CasesSelector implements ISelector {

    // ─── ISelector contract ───────────────────────────────────────────────────────

    public SObjectType getSObjectType() {
        return Case.SObjectType;
    }

    /**
     * @description Fetches Cases by Id with the default field set.
     *
     * @param idSet  Set of Case Ids.
     * @return       Case records ordered by CreatedDate descending.
     */
    public List<SObject> selectById(Set<Id> idSet) {
        return [
            SELECT Id, CaseNumber, Subject, Status, Priority,
                   OwnerId, AccountId, IsClosed, CreatedDate
            FROM   Case
            WHERE  Id IN :idSet
            WITH   SECURITY_ENFORCED
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * @description Streams Cases for Batch Apex via QueryLocator.
     *
     * @param whereClause  Optional WHERE fragment; null = all records.
     * @return             QueryLocator.
     */
    public Database.QueryLocator getQueryLocator(String whereClause) {
        String soql = 'SELECT Id, CaseNumber, Subject, Status, Priority, '
                    + 'OwnerId, AccountId, IsClosed, CreatedDate '
                    + 'FROM Case '
                    + (String.isBlank(whereClause) ? '' : 'WHERE ' + whereClause + ' ')
                    + 'WITH SECURITY_ENFORCED ORDER BY CreatedDate DESC';
        return Database.getQueryLocator(soql);
    }

    // ─── Domain-specific queries ──────────────────────────────────────────────────

    /**
     * @description Fetches open (non-closed) Cases for the given Account Ids.
     *              Results ordered newest-first so callers can detect recently
     *              escalated cases without additional sorting.
     *
     * @param accountIds  Set of Account Ids.
     * @return            Open Cases.
     */
    public List<Case> selectOpenByAccountId(Set<Id> accountIds) {
        return [
            SELECT Id, CaseNumber, Subject, Status, Priority, OwnerId, AccountId
            FROM   Case
            WHERE  AccountId IN :accountIds
            AND    IsClosed = false
            WITH   SECURITY_ENFORCED
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * @description Fetches Cases by Account and a set of Status values.
     *              Used for SLA monitoring — e.g., retrieve all 'Escalated'
     *              and 'New' cases for a key account in one query.
     *
     * @param accountIds  Set of Account Ids.
     * @param statuses    Set of Status picklist values to filter by.
     * @return            Matching Cases ordered by CreatedDate descending.
     */
    public List<Case> selectByAccountIdAndStatus(
            Set<Id> accountIds, Set<String> statuses) {
        return [
            SELECT Id, CaseNumber, Subject, Status, Priority, AccountId
            FROM   Case
            WHERE  AccountId IN :accountIds
            AND    Status    IN :statuses
            WITH   SECURITY_ENFORCED
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * @description Counts open Cases per Account using GROUP BY.
     *              Returns AggregateResult[] — used in Account page layouts
     *              and SLA dashboard queries without a full record fetch.
     *
     * @param accountIds  Set of Account Ids to count for.
     * @return            AggregateResult[] with AccountId and openCaseCount.
     */
    public List<AggregateResult> countOpenCasesByAccount(Set<Id> accountIds) {
        return [
            SELECT   AccountId,
                     COUNT(Id) openCaseCount
            FROM     Case
            WHERE    AccountId IN :accountIds
            AND      IsClosed = false
            WITH     SECURITY_ENFORCED
            GROUP BY AccountId
        ];
    }
}
