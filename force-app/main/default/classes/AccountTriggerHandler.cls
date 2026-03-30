/**
 * @description Trigger handler for the Account object. Dispatches trigger events to
 *              AccountService (business logic) and AccountDomain (object invariants).
 *              This class contains zero business logic — it is a routing table only.
 *
 *              Extending TriggerHandler provides: bypass control, consistent event
 *              dispatch, and a single entry point per object.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class AccountTriggerHandler extends TriggerHandler {

    private List<Account>      newList;
    private List<Account>      oldList;
    private Map<Id, Account>   newMap;
    private Map<Id, Account>   oldMap;

    public AccountTriggerHandler() {
        newList = Trigger.new    != null ? (List<Account>)    Trigger.new    : new List<Account>();
        oldList = Trigger.old    != null ? (List<Account>)    Trigger.old    : new List<Account>();
        newMap  = Trigger.newMap != null ? (Map<Id, Account>) Trigger.newMap : new Map<Id, Account>();
        oldMap  = Trigger.oldMap != null ? (Map<Id, Account>) Trigger.oldMap : new Map<Id, Account>();
    }

    protected override void beforeInsert() {
        AccountService.setRatingFromRevenue(newList);
    }

    protected override void beforeUpdate() {
        AccountService.setRatingFromRevenue(newList);
        AccountDomain.validateTypeDowngrade(newList, oldMap);
    }

    protected override void beforeDelete() {
        AccountService.preventDeleteWithOpenOpportunities(oldList);
    }

    protected override void afterUpdate() {
        AccountService.syncCaseOwnerOnAccountOwnerChange(newMap, oldMap);
    }
}
