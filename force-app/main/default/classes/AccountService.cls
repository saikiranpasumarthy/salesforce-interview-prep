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
     * @description Core rating logic — public so batch jobs can inject pre-cached CMDT
     *              configs rather than re-querying on every execute() call. Configs must
     *              arrive pre-sorted descending by Revenue_Threshold__c (highest wins).
     */
    public static void applyRatingFromRevenue(
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

    // ─── Day 22: SoC / DI Service Methods ────────────────────────────────────
    // The methods below use the Application factory for Selector + UoW injection,
    // enabling clean unit testing without database hits.

    /**
     * Marks accounts as Pending sync and publishes a Platform Event for each.
     * Demonstrates: Selector → filter → UoW registerDirty → commitWork → publish.
     */
    public static void markForSync(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) { return; }
        IAccountSelector selector =
            (IAccountSelector) Application.Selector.newInstance(IAccountSelector.class);
        IUnitOfWork uow = Application.UnitOfWork.newInstance();

        List<Account> accounts = selector.selectById(accountIds);
        List<Integration_Event__e> events = new List<Integration_Event__e>();
        for (Account acc : accounts) {
            if (acc.Sync_Status__c != 'Pending') {
                uow.registerDirty(new Account(Id = acc.Id, Sync_Status__c = 'Pending'));
                events.add(PlatformEventService.accountSyncEvent(acc.Id, 'MARK_SYNC'));
            }
        }
        uow.commitWork();
        if (!events.isEmpty()) { PlatformEventService.publishBulk(events); }
    }

    /** Records a sync failure: sets Sync_Status__c=Failed and stores the error message. */
    public static void recordSyncFailure(Id accountId, String errorMessage) {
        if (accountId == null) { return; }
        IUnitOfWork uow = Application.UnitOfWork.newInstance();
        uow.registerDirty(new Account(
            Id             = accountId,
            Sync_Status__c = 'Failed',
            Sync_Error__c  = errorMessage != null ? errorMessage.left(255) : 'Unknown error'
        ));
        uow.commitWork();
    }

    /**
     * Bulk-creates Accounts with related Contacts via UoW relationship resolution.
     * Demonstrates parent-child INSERT without managing parent IDs manually.
     */
    public static List<Id> createAccountsWithContacts(
            List<AccountWithContactsDto> dtos) {
        if (dtos == null || dtos.isEmpty()) { return new List<Id>(); }
        IUnitOfWork uow = Application.UnitOfWork.newInstance();
        List<Account> newAccounts = new List<Account>();
        for (AccountWithContactsDto dto : dtos) {
            Account acc = new Account(
                Name           = dto.accountName,
                Type           = dto.accountType,
                Sync_Status__c = 'Pending'
            );
            uow.registerNew(acc);
            newAccounts.add(acc);
            if (dto.contacts != null) {
                for (ContactDto cDto : dto.contacts) {
                    uow.registerNew(
                        new Contact(FirstName = cDto.firstName,
                                    LastName  = cDto.lastName,
                                    Email     = cDto.email),
                        Contact.AccountId, acc
                    );
                }
            }
        }
        uow.commitWork();
        List<Id> ids = new List<Id>();
        for (Account acc : newAccounts) { ids.add(acc.Id); }
        return ids;
    }

    /** Returns accounts grouped by Type, with their open Opportunities. */
    public static Map<String, List<Account>> getAccountsByTypeWithOpps(Set<Id> accountIds) {
        IAccountSelector selector =
            (IAccountSelector) Application.Selector.newInstance(IAccountSelector.class);
        List<Account> accounts = selector.selectWithOpenOpportunities(accountIds);
        Map<String, List<Account>> grouped = new Map<String, List<Account>>();
        for (Account acc : accounts) {
            String type = String.isBlank(acc.Type) ? 'Unknown' : acc.Type;
            if (!grouped.containsKey(type)) { grouped.put(type, new List<Account>()); }
            grouped.get(type).add(acc);
        }
        return grouped;
    }

    // DTOs for createAccountsWithContacts
    public class AccountWithContactsDto {
        public String accountName;
        public String accountType;
        public List<ContactDto> contacts;
    }
    public class ContactDto {
        public String firstName;
        public String lastName;
        public String email;
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
