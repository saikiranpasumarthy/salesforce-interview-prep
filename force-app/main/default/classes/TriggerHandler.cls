/**
 * @description Abstract base class for all trigger handlers. Enforces single-trigger,
 *              single-handler architecture across the entire org. Provides per-handler
 *              bypass control for data migrations, integrations, and unit test isolation.
 *
 *              Pattern: One trigger → one handler → delegates to Service/Domain layers.
 *              No business logic lives here — this class is pure dispatch infrastructure.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public abstract with sharing class TriggerHandler {

    // Tracks bypassed handler names for the current transaction
    private static Set<String> bypassedHandlers = new Set<String>();

    /**
     * @description Executes the appropriate virtual methods based on the current
     *              trigger context. Skips execution if this handler is bypassed.
     */
    public void run() {
        if (isBypassed(getHandlerName())) {
            return;
        }

        if (Trigger.isBefore) {
            if (Trigger.isInsert)   beforeInsert();
            if (Trigger.isUpdate)   beforeUpdate();
            if (Trigger.isDelete)   beforeDelete();
            if (Trigger.isUndelete) beforeUndelete();
        } else {
            if (Trigger.isInsert)   afterInsert();
            if (Trigger.isUpdate)   afterUpdate();
            if (Trigger.isDelete)   afterDelete();
            if (Trigger.isUndelete) afterUndelete();
        }
    }

    // ─── Bypass Controls ─────────────────────────────────────────────────────
    // Use these in data migration scripts, integration flows, and test setup
    // where specific trigger logic should be skipped without disabling the trigger.

    public static void bypass(String handlerName) {
        bypassedHandlers.add(handlerName);
    }

    public static void clearBypass(String handlerName) {
        bypassedHandlers.remove(handlerName);
    }

    public static Boolean isBypassed(String handlerName) {
        return bypassedHandlers.contains(handlerName);
    }

    public static void clearAllBypasses() {
        bypassedHandlers.clear();
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    private String getHandlerName() {
        // e.g. "AccountTriggerHandler:..." → "AccountTriggerHandler"
        return String.valueOf(this).substringBefore(':');
    }

    // ─── Virtual Event Hooks ──────────────────────────────────────────────────
    // Subclasses override only the events they need. Default is no-op.

    protected virtual void beforeInsert()   {}
    protected virtual void beforeUpdate()   {}
    protected virtual void beforeDelete()   {}
    protected virtual void beforeUndelete() {}
    protected virtual void afterInsert()    {}
    protected virtual void afterUpdate()    {}
    protected virtual void afterDelete()    {}
    protected virtual void afterUndelete()  {}
}
