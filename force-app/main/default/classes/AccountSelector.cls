/**
 * AccountSelector
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 22 — Selector Layer: concrete SOQL implementation for Account.
 *
 * SELECTOR DESIGN RULES:
 * ═══════════════════════
 * 1. Every method returns List<Account> — no raw query leaking
 * 2. WITH SECURITY_ENFORCED on every query (FLS enforcement)
 * 3. No business logic — pure data retrieval
 * 4. Field lists are additive — base fields + method-specific extras
 * 5. ORDER BY for deterministic results in tests
 * 6. No hardcoded IDs — all IDs/values come from parameters
 */
public with sharing class AccountSelector implements IAccountSelector {

    // Base field set returned on every query
    private static final String BASE_FIELDS =
        'Id, Name, Type, Rating, AnnualRevenue, OwnerId, '
        + 'Sync_Status__c, Sync_Error__c, '
        + 'BillingCity, BillingCountry, Phone, Website, '
        + 'CreatedDate, LastModifiedDate';

    // ─────────────────────────────────────────────────────────────────────────
    // IAccountSelector implementation
    // ─────────────────────────────────────────────────────────────────────────

    public List<Account> selectById(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) { return new List<Account>(); }
        return [
            SELECT Id, Name, Type, Rating, AnnualRevenue, OwnerId,
                   Sync_Status__c, Sync_Error__c,
                   BillingCity, BillingCountry, Phone, Website,
                   CreatedDate, LastModifiedDate
            FROM   Account
            WHERE  Id IN :ids
            WITH   SECURITY_ENFORCED
            ORDER BY Name
        ];
    }

    public List<Account> selectByType(String type) {
        if (String.isBlank(type)) { return new List<Account>(); }
        return [
            SELECT Id, Name, Type, Rating, AnnualRevenue, OwnerId,
                   Sync_Status__c, BillingCity, BillingCountry
            FROM   Account
            WHERE  Type = :type
            WITH   SECURITY_ENFORCED
            ORDER BY Name
        ];
    }

    /**
     * Returns Accounts with at least one open Opportunity.
     * Uses a semi-join subquery to avoid N+1 pattern.
     */
    public List<Account> selectWithOpenOpportunities(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) { return new List<Account>(); }
        return [
            SELECT Id, Name, Type, AnnualRevenue,
                   (SELECT Id, Name, StageName, Amount, CloseDate
                    FROM   Opportunities
                    WHERE  IsClosed = false
                    ORDER BY CloseDate ASC)
            FROM   Account
            WHERE  Id IN :ids
            AND    Id IN (
                SELECT AccountId FROM Opportunity WHERE IsClosed = false
            )
            WITH   SECURITY_ENFORCED
            ORDER BY Name
        ];
    }

    /**
     * Returns Accounts that need to be synced to the external system.
     * Used by the SyncAccountBatch (Day 17) to find work to do.
     */
    public List<Account> selectPendingSync() {
        return [
            SELECT Id, Name, Type, AnnualRevenue, Rating,
                   Sync_Status__c, Sync_Error__c
            FROM   Account
            WHERE  Sync_Status__c IN ('Pending', 'Error')
            WITH   SECURITY_ENFORCED
            ORDER BY LastModifiedDate ASC
        ];
    }

    public Integer countByType(String type) {
        if (String.isBlank(type)) { return 0; }
        return [
            SELECT COUNT() FROM Account
            WHERE  Type = :type
            WITH   SECURITY_ENFORCED
        ];
    }
}
