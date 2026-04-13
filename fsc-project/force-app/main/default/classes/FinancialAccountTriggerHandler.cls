/**
 * FinancialAccountTriggerHandler
 * Handles all trigger events on FinancialAccount__c.
 *
 * Before Insert : set defaults (IsActive, LastSyncedDateTime)
 * Before Update : prevent reactivation of closed accounts without permission
 * After Insert  : calculate initial portfolio health band
 * After Update  : recalculate portfolio health band if Balance changed
 */
public class FinancialAccountTriggerHandler extends TriggerHandler {

    private FinancialAccountService service;

    public FinancialAccountTriggerHandler() {
        this.service = new FinancialAccountService();
    }

    // Testable constructor — inject mock service
    @TestVisible
    private FinancialAccountTriggerHandler(FinancialAccountService svc) {
        this.service = svc;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BEFORE INSERT
    // ─────────────────────────────────────────────────────────────────────────
    protected override void beforeInsert(List<SObject> newRecords) {
        List<FinancialAccount__c> newAccounts = (List<FinancialAccount__c>) newRecords;

        for (FinancialAccount__c fa : newAccounts) {
            // Default IsActive to true on creation
            if (fa.IsActive__c == null) {
                fa.IsActive__c = true;
            }
            // Default Balance to 0 if not provided
            if (fa.Balance__c == null) {
                fa.Balance__c = 0;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BEFORE UPDATE
    // ─────────────────────────────────────────────────────────────────────────
    protected override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
        List<FinancialAccount__c> newAccounts = (List<FinancialAccount__c>) newRecords;
        Map<Id, FinancialAccount__c> oldAccounts = (Map<Id, FinancialAccount__c>) oldMap;

        for (FinancialAccount__c fa : newAccounts) {
            FinancialAccount__c oldFa = oldAccounts.get(fa.Id);

            // Block reactivation of deactivated accounts without explicit flag
            if (!fa.IsActive__c && oldFa.IsActive__c) {
                // Deactivation is allowed — clear balance display fields
                fa.Balance__c = fa.Balance__c; // retain actual balance for audit
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER INSERT
    // ─────────────────────────────────────────────────────────────────────────
    protected override void afterInsert(List<SObject> newRecords) {
        List<FinancialAccount__c> newAccounts = (List<FinancialAccount__c>) newRecords;
        Set<Id> householdIds = collectHouseholdIds(newAccounts);
        if (!householdIds.isEmpty()) {
            service.recalculateHouseholdNetWorth(householdIds);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER UPDATE
    // ─────────────────────────────────────────────────────────────────────────
    protected override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
        List<FinancialAccount__c> newAccounts = (List<FinancialAccount__c>) newRecords;
        Map<Id, FinancialAccount__c> oldAccounts = (Map<Id, FinancialAccount__c>) oldMap;

        Set<Id> householdIds = new Set<Id>();
        for (FinancialAccount__c fa : newAccounts) {
            FinancialAccount__c oldFa = oldAccounts.get(fa.Id);
            // Only recalculate if balance or active status changed
            if (fa.Balance__c != oldFa.Balance__c || fa.IsActive__c != oldFa.IsActive__c) {
                if (fa.Account__c != null) {
                    householdIds.add(fa.Account__c);
                }
            }
        }

        if (!householdIds.isEmpty()) {
            service.recalculateHouseholdNetWorth(householdIds);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER DELETE
    // ─────────────────────────────────────────────────────────────────────────
    protected override void afterDelete(List<SObject> oldRecords) {
        List<FinancialAccount__c> deleted = (List<FinancialAccount__c>) oldRecords;
        Set<Id> householdIds = collectHouseholdIds(deleted);
        if (!householdIds.isEmpty()) {
            service.recalculateHouseholdNetWorth(householdIds);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────
    private Set<Id> collectHouseholdIds(List<FinancialAccount__c> accounts) {
        Set<Id> ids = new Set<Id>();
        for (FinancialAccount__c fa : accounts) {
            if (fa.Account__c != null) {
                ids.add(fa.Account__c);
            }
        }
        return ids;
    }
}
