/**
 * @description Advanced SOQL pattern library. Demonstrates relationship queries,
 *              aggregate functions, semi/anti-joins, dynamic SOQL, FOR UPDATE,
 *              date functions, and bulk-safe query design.
 *
 *              This class serves both as a production utility and as an interview
 *              reference for Day 4 SOQL mastery. Every method is an independent,
 *              testable pattern — no cross-method dependencies.
 *
 *              Optimization principles applied throughout:
 *                - All WHERE filters on indexed fields where possible (Id, Name,
 *                  custom indexed, ExternalId)
 *                - Bind variables (:variable) instead of string concatenation in
 *                  dynamic SOQL — prevents injection and preserves query plan caching
 *                - LIMIT on every query that may return unbounded rows
 *                - Static Map cache for repeated same-transaction lookups
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class SoqlQueryService {

    // ─── Transaction-Scoped Static Cache ─────────────────────────────────────
    // Prevents repeated SOQL for the same Account IDs within one Apex transaction.
    // Cache lives for the duration of the transaction, then is garbage-collected.
    @TestVisible private static Map<Id, Account> accountCache = new Map<Id, Account>();

    // ─── Relationship Queries ─────────────────────────────────────────────────

    /**
     * @description Parent-to-child relationship query. Returns Accounts with their
     *              open Cases in a single SOQL — avoids a second query for child records.
     *
     *              Child sub-query limit: 200 records per parent record.
     *              Use LIMIT in sub-query to make this explicit and prevent truncation
     *              surprises. For accounts with >200 open cases, a separate bulk query
     *              by AccountId is required.
     *
     * @param accountIds  Set of Account IDs to query
     * @return List of Accounts with populated Cases child relationship
     */
    public static List<Account> getAccountsWithOpenCases(Set<Id> accountIds) {
        return [
            SELECT Id, Name, Rating, AnnualRevenue,
                (SELECT Id, Subject, Status, Priority, CreatedDate, OwnerId
                 FROM   Cases
                 WHERE  IsClosed = false
                 ORDER  BY Priority DESC, CreatedDate DESC
                 LIMIT  200)
            FROM Account
            WHERE Id IN :accountIds
        ];
    }

    /**
     * @description Child-to-parent dot notation. Traverses up to 5 relationship
     *              levels. Account.Name, Account.Rating are single-level traversals.
     *              Owner.Name crosses to the User object — still one SOQL.
     *
     * @param caseIds  Set of Case IDs to query
     * @return List of Cases with Account and Owner fields populated
     */
    public static List<Case> getCasesWithParentData(Set<Id> caseIds) {
        return [
            SELECT Id, Subject, Status, Priority, CreatedDate, ClosedDate,
                   AccountId, Account.Name, Account.Rating, Account.AnnualRevenue,
                   OwnerId, Owner.Name, Owner.Email
            FROM   Case
            WHERE  Id IN :caseIds
        ];
    }

    /**
     * @description Static cache pattern. Returns accounts from cache if already
     *              queried this transaction; falls back to SOQL for misses only.
     *              Prevents redundant SOQLs when multiple service methods need the
     *              same Account data within one transaction.
     *
     * @param accountIds  Set of Account IDs needed
     * @return Map of Id → Account with full field set
     */
    public static Map<Id, Account> getAccountsCached(Set<Id> accountIds) {
        Set<Id> cacheMisses = new Set<Id>();
        for (Id accId : accountIds) {
            if (!accountCache.containsKey(accId)) {
                cacheMisses.add(accId);
            }
        }

        if (!cacheMisses.isEmpty()) {
            for (Account acc : [
                SELECT Id, Name, Rating, AnnualRevenue, Industry, Type, OwnerId
                FROM   Account
                WHERE  Id IN :cacheMisses
            ]) {
                accountCache.put(acc.Id, acc);
            }
        }

        // Return only the subset requested — never expose full cache to caller
        Map<Id, Account> result = new Map<Id, Account>();
        for (Id accId : accountIds) {
            if (accountCache.containsKey(accId)) {
                result.put(accId, accountCache.get(accId));
            }
        }
        return result;
    }

    // ─── Aggregate Queries ────────────────────────────────────────────────────

    /**
     * @description GROUP BY with HAVING filter. Returns only industries where the
     *              combined Account revenue exceeds the minimum threshold.
     *              HAVING operates on aggregate values post-grouping — cannot use
     *              WHERE for this because individual row values are not the target.
     *
     * @param minimumRevenue  Only include industry groups above this total revenue
     * @return AggregateResult list with Industry, totalRevenue, accountCount, avgRevenue
     */
    public static List<AggregateResult> getRevenueByIndustry(Decimal minimumRevenue) {
        return [
            SELECT Industry,
                   SUM(AnnualRevenue) totalRevenue,
                   COUNT(Id)          accountCount,
                   AVG(AnnualRevenue) avgRevenue,
                   MAX(AnnualRevenue) maxRevenue
            FROM   Account
            WHERE  AnnualRevenue != null
              AND  Industry      != null
            GROUP  BY Industry
            HAVING SUM(AnnualRevenue) >= :minimumRevenue
            ORDER  BY SUM(AnnualRevenue) DESC
        ];
    }

    /**
     * @description Date function aggregate. Groups Cases by calendar year using
     *              CALENDAR_YEAR() date function — useful for year-over-year dashboards.
     *              Other date functions: CALENDAR_MONTH, FISCAL_YEAR, FISCAL_QUARTER,
     *              DAY_IN_WEEK, WEEK_IN_YEAR, HOUR_IN_DAY.
     *
     * @return AggregateResult list with year and case count per year
     */
    public static List<AggregateResult> getCaseVolumeByYear() {
        return [
            SELECT CALENDAR_YEAR(CreatedDate) caseYear,
                   COUNT(Id)                  caseCount,
                   COUNT_DISTINCT(AccountId)  uniqueAccounts
            FROM   Case
            WHERE  CreatedDate != null
            GROUP  BY CALENDAR_YEAR(CreatedDate)
            ORDER  BY CALENDAR_YEAR(CreatedDate) DESC
            LIMIT  10
        ];
    }

    // ─── Semi-Joins and Anti-Joins ─────────────────────────────────────────────

    /**
     * @description Semi-join using IN with a sub-query. Returns open Cases whose
     *              parent Accounts have at least one Closed Won Opportunity.
     *              Salesforce evaluates the inner query first, then filters the outer.
     *              Both queries must be on the same object in the inner query.
     *
     *              Performance note: Semi-joins are evaluated in Salesforce's query
     *              optimizer — not as application-layer joins. They use the index on
     *              AccountId in both queries.
     *
     * @return List of open Cases linked to accounts with Closed Won revenue
     */
    public static List<Case> getOpenCasesForWonAccountsSemiJoin() {
        return [
            SELECT Id, Subject, Status, Priority, AccountId, Account.Name
            FROM   Case
            WHERE  IsClosed = false
              AND  AccountId IN (
                       SELECT AccountId
                       FROM   Opportunity
                       WHERE  StageName  = 'Closed Won'
                         AND  AccountId != null
                   )
            ORDER BY Priority DESC
            LIMIT  500
        ];
    }

    /**
     * @description Anti-join using NOT IN with a sub-query. Returns Accounts that
     *              have no associated Contacts — data quality / orphan detection.
     *
     *              Caution: NOT IN sub-queries are non-selective by nature (they
     *              cannot use an index to confirm absence). Performance degrades
     *              significantly on large Contact datasets. Prefer Batch Apex with
     *              AggregateResult grouping for orgs with millions of Contacts.
     *
     * @param limitCount  Max records to return — always limit anti-join results
     * @return List of Accounts with no Contact records
     */
    public static List<Account> getAccountsWithNoContacts(Integer limitCount) {
        Integer safeLimit = Math.min(limitCount, 2000);
        return [
            SELECT Id, Name, CreatedDate, Industry, Type
            FROM   Account
            WHERE  Id NOT IN (
                       SELECT AccountId
                       FROM   Contact
                       WHERE  AccountId != null
                   )
            ORDER  BY CreatedDate DESC
            LIMIT  :safeLimit
        ];
    }

    // ─── Dynamic SOQL ─────────────────────────────────────────────────────────

    /**
     * @description Allowlisted dynamic SOQL. Field list is caller-supplied but
     *              validated against a hardcoded allowlist — prevents SOQL injection
     *              via field name manipulation.
     *
     *              Security rules for dynamic SOQL:
     *                1. Never concatenate user-supplied strings into WHERE clause values
     *                   — use bind variables or String.escapeSingleQuotes()
     *                2. Validate field names against Schema or an allowlist
     *                3. WITH SECURITY_ENFORCED or stripInaccessible() for FLS enforcement
     *                4. Database.queryWithBinds (API 57.0+) for safe bind variable injection
     *
     * @param requestedFields  Caller-requested field API names
     * @param industryFilter   Industry value to filter on (bind variable — injection-safe)
     * @return List of Accounts with requested fields for given industry
     */
    public static List<Account> queryAccountsByIndustryDynamic(
        List<String> requestedFields,
        String industryFilter
    ) {
        // Allowlist — only these fields are safe to include in dynamic SELECT
        Set<String> allowedFields = new Set<String>{
            'Id', 'Name', 'AnnualRevenue', 'Rating', 'Industry',
            'Type', 'Phone', 'BillingCity', 'BillingState', 'OwnerId'
        };

        // Id is always included — required for record identity
        Set<String> safeFields = new Set<String>{ 'Id' };
        for (String field : requestedFields) {
            if (allowedFields.contains(field)) {
                safeFields.add(field);
            }
        }

        // Bind variable (:industryFilter) prevents injection — Salesforce does NOT
        // execute the bind value as SOQL syntax, only as a literal filter value.
        // This is equivalent to a prepared statement in SQL.
        String query =
            'SELECT ' + String.join(new List<String>(safeFields), ', ') +
            ' FROM Account' +
            ' WHERE Industry = :industryFilter' +
            ' WITH SECURITY_ENFORCED' +     // enforces FLS — throws exception if field inaccessible
            ' ORDER BY Name' +
            ' LIMIT 200';

        return Database.query(query);
    }

    /**
     * @description Database.queryWithBinds — API 57.0+ pattern for dynamic SOQL
     *              with named bind variables. Eliminates the class-level variable
     *              scope requirement of traditional bind variables in dynamic SOQL.
     *
     * @param minRevenue  Minimum AnnualRevenue threshold
     * @param maxRevenue  Maximum AnnualRevenue threshold
     * @return Accounts within the revenue band
     */
    public static List<Account> queryAccountsByRevenueBand(
        Decimal minRevenue,
        Decimal maxRevenue
    ) {
        String query =
            'SELECT Id, Name, AnnualRevenue, Rating, Industry ' +
            'FROM Account ' +
            'WHERE AnnualRevenue >= :minRev ' +
            '  AND AnnualRevenue <= :maxRev ' +
            'ORDER BY AnnualRevenue DESC ' +
            'LIMIT 500';

        // Named bind map — variables resolved from this Map, not from method scope.
        // Safe to pass this query string and bind map around without scope pollution.
        Map<String, Object> bindVars = new Map<String, Object>{
            'minRev' => minRevenue,
            'maxRev' => maxRevenue
        };

        return Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
    }

    // ─── FOR UPDATE (Pessimistic Locking) ────────────────────────────────────

    /**
     * @description FOR UPDATE acquires a row-level lock on queried records.
     *              No other transaction can update these records until this
     *              transaction commits or rolls back.
     *
     *              Use when:
     *                - Multiple Queueable/Batch jobs may update the same records
     *                - You need read-then-update atomicity (prevent lost updates)
     *                - Implementing an optimistic-lock equivalent without versioning
     *
     *              Never use in high-concurrency trigger paths — a FOR UPDATE in a
     *              trigger on a heavily-written object will cause widespread lock
     *              contention and transaction timeouts at scale.
     *
     * @param accountIds  Records to lock for the current transaction
     * @return Locked Account records (safe to read and update)
     */
    public static List<Account> lockAccountsForUpdate(Set<Id> accountIds) {
        return [
            SELECT Id, Name, Rating, AnnualRevenue, OwnerId
            FROM   Account
            WHERE  Id IN :accountIds
            FOR    UPDATE
        ];
    }

    // ─── Pagination ───────────────────────────────────────────────────────────

    /**
     * @description OFFSET-based pagination for UI-driven result pages.
     *              OFFSET limit: 2,000 records maximum — not suitable for deep
     *              pagination on large datasets (use QueryLocator + cursor instead).
     *
     *              For datasets > 2,000 or > 10 pages: use the "keyset pagination"
     *              pattern — filter by WHERE Id > :lastSeenId ORDER BY Id LIMIT :pageSize.
     *
     * @param pageNumber  1-based page number
     * @param pageSize    Records per page (max 2,000 to stay within OFFSET limit)
     * @return One page of open Cases ordered by newest first
     */
    public static List<Case> getOpenCasesPaginated(Integer pageNumber, Integer pageSize) {
        Integer safePageSize = Math.min(pageSize, 200);
        Integer offset       = Math.min((pageNumber - 1) * safePageSize, 2000);
        return [
            SELECT Id, Subject, Status, Priority, CreatedDate, AccountId, Account.Name
            FROM   Case
            WHERE  IsClosed = false
            ORDER  BY CreatedDate DESC
            LIMIT  :safePageSize
            OFFSET :offset
        ];
    }

    /**
     * @description Keyset pagination — scalable alternative to OFFSET for large datasets.
     *              Filters WHERE Id > :lastSeenId to avoid full-scan on offset rows.
     *              Requires consistent ORDER BY Id and a stable cursor (last Id seen).
     *
     * @param lastSeenId  Last Case Id from previous page (null for first page)
     * @param pageSize    Records per page
     * @return Next page of Cases relative to cursor position
     */
    public static List<Case> getOpenCasesKeysetPage(Id lastSeenId, Integer pageSize) {
        Integer safePageSize = Math.min(pageSize, 200);
        if (lastSeenId == null) {
            return [
                SELECT Id, Subject, Status, Priority, CreatedDate
                FROM   Case
                WHERE  IsClosed = false
                ORDER  BY Id ASC
                LIMIT  :safePageSize
            ];
        }
        return [
            SELECT Id, Subject, Status, Priority, CreatedDate
            FROM   Case
            WHERE  IsClosed = false
              AND  Id > :lastSeenId
            ORDER  BY Id ASC
            LIMIT  :safePageSize
        ];
    }

    // ─── Date Literals ────────────────────────────────────────────────────────

    /**
     * @description Demonstrates dynamic date literals — no hardcoded date values.
     *              LAST_N_DAYS:30 is evaluated by the Salesforce query engine at
     *              runtime and uses the UTC timezone of the org.
     *
     *              Key date literals for interviews:
     *                LAST_N_DAYS:N, NEXT_N_DAYS:N
     *                THIS_WEEK, LAST_WEEK, NEXT_WEEK
     *                THIS_MONTH, LAST_MONTH, LAST_N_MONTHS:N
     *                THIS_QUARTER, LAST_QUARTER, THIS_FISCAL_QUARTER
     *                TODAY, YESTERDAY, TOMORROW
     *
     * @param daysWindow  Number of days lookback for escalated cases
     * @return Escalated Cases created within the specified window
     */
    public static List<Case> getRecentHighPriorityCases(Integer daysWindow) {
        // Date literals require literal token values — cannot be bound dynamically.
        // For dynamic date ranges, use Date arithmetic with bind variables instead.
        DateTime threshold = DateTime.now().addDays(-daysWindow);
        return [
            SELECT Id, Subject, Status, Priority, AccountId, Account.Name, CreatedDate
            FROM   Case
            WHERE  Priority     = 'High'
              AND  IsClosed     = false
              AND  CreatedDate >= :threshold
            ORDER  BY CreatedDate DESC
            LIMIT  200
        ];
    }
}
