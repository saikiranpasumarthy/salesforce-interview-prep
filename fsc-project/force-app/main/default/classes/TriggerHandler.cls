/**
 * TriggerHandler — Abstract base class for all trigger handlers.
 * Pattern: one handler class per object; trigger delegates immediately to handler.
 * Supports bypass via static set for test isolation.
 */
public abstract class TriggerHandler {

    // Bypass registry — add handler class name to skip execution (use in tests or batch)
    @TestVisible
    private static Set<String> bypassedHandlers = new Set<String>();

    public static void bypass(String handlerName) {
        bypassedHandlers.add(handlerName);
    }

    public static void clearBypass(String handlerName) {
        bypassedHandlers.remove(handlerName);
    }

    public static Boolean isBypassed(String handlerName) {
        return bypassedHandlers.contains(handlerName);
    }

    /**
     * Entry point called from trigger body.
     * Routes to the appropriate virtual method based on Trigger context.
     */
    public void run() {
        if (isBypassed(getHandlerName())) {
            return;
        }

        if (Trigger.isBefore) {
            if (Trigger.isInsert)  beforeInsert(Trigger.new);
            if (Trigger.isUpdate)  beforeUpdate(Trigger.new, Trigger.oldMap);
            if (Trigger.isDelete)  beforeDelete(Trigger.old);
        } else {
            if (Trigger.isInsert)  afterInsert(Trigger.new);
            if (Trigger.isUpdate)  afterUpdate(Trigger.new, Trigger.oldMap);
            if (Trigger.isDelete)  afterDelete(Trigger.old);
            if (Trigger.isUndelete) afterUndelete(Trigger.new);
        }
    }

    // Override these in subclasses as needed — all default to no-op
    protected virtual void beforeInsert(List<SObject> newRecords)                          {}
    protected virtual void beforeUpdate(List<SObject> newRecords, Map<Id,SObject> oldMap)  {}
    protected virtual void beforeDelete(List<SObject> oldRecords)                          {}
    protected virtual void afterInsert(List<SObject> newRecords)                           {}
    protected virtual void afterUpdate(List<SObject> newRecords, Map<Id,SObject> oldMap)   {}
    protected virtual void afterDelete(List<SObject> oldRecords)                           {}
    protected virtual void afterUndelete(List<SObject> newRecords)                         {}

    private String getHandlerName() {
        return String.valueOf(this).substring(0, String.valueOf(this).indexOf(':'));
    }
}
