/**
 * @description Service layer for RetailVisit__c business logic.
 *
 *              Three core responsibilities:
 *
 *              1. validateVisitCheckIn — before-update guard that prevents
 *                 check-in outside a configurable time window. Window hours
 *                 sourced from Visit_Config__mdt, never hardcoded.
 *
 *              2. createActivityTasks — after-insert handler that reads the
 *                 Activity Plan Template assigned to the store and auto-creates
 *                 Task records for each activity item. One DML call for all
 *                 tasks across all visits in the batch.
 *
 *              3. handleVisitCompletion — after-update handler that calculates
 *                 visit duration, checks mandatory task completion, creates
 *                 follow-up Tasks for the area manager when tasks are missed,
 *                 and publishes a Visit_Completed__e Platform Event for
 *                 downstream ERP and notification subscribers.
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
public with sharing class RetailVisitService {

    // Custom Metadata developer name for the visit configuration record
    @TestVisible static final String VISIT_CONFIG_DEV_NAME = 'Default';

    // Fallback if Custom Metadata record is not deployed
    @TestVisible static final Integer DEFAULT_WINDOW_HOURS = 2;

    // ─── Status constants ─────────────────────────────────────────────────────
    private static final String STATUS_PLANNED     = 'Planned';
    private static final String STATUS_IN_PROGRESS = 'In Progress';
    private static final String STATUS_COMPLETED   = 'Completed';

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 1 — validateVisitCheckIn
    // Called from: RetailVisitTriggerHandler.beforeUpdate
    //
    // Adds a field-level error on Status__c if the rep attempts to check in
    // (Status → In Progress) outside the configured time window around
    // PlannedVisitStartTime__c.
    //
    // Time window: ±N hours, N read from Visit_Config__mdt.Check_In_Window_Hours__c
    // ─────────────────────────────────────────────────────────────────────────
    public static void validateVisitCheckIn(
        List<RetailVisit__c>    newVisits,
        Map<Id, RetailVisit__c> oldMap
    ) {
        // Read threshold from Custom Metadata
        Visit_Config__mdt config = Visit_Config__mdt.getInstance(VISIT_CONFIG_DEV_NAME);
        Integer windowHours = (config != null && config.Check_In_Window_Hours__c != null)
            ? (Integer) config.Check_In_Window_Hours__c
            : DEFAULT_WINDOW_HOURS;

        Long windowMillis = (Long) windowHours * 60 * 60 * 1000L;
        Long nowMillis    = Datetime.now().getTime();

        for (RetailVisit__c visit : newVisits) {
            RetailVisit__c oldVisit = oldMap.get(visit.Id);

            // Only validate the transition into In Progress
            if (visit.Status__c != STATUS_IN_PROGRESS
                || oldVisit.Status__c == STATUS_IN_PROGRESS) {
                continue;
            }

            if (visit.PlannedVisitStartTime__c == null) {
                visit.Status__c.addError(
                    'Cannot check in: this visit has no planned start time.'
                );
                continue;
            }

            Long plannedMillis = visit.PlannedVisitStartTime__c.getTime();
            Long diffMillis    = Math.abs(nowMillis - plannedMillis);

            if (diffMillis > windowMillis) {
                String planned = visit.PlannedVisitStartTime__c.format('MM/dd/yyyy HH:mm');
                visit.Status__c.addError(
                    'Check-in is only allowed within ' + windowHours +
                    ' hour(s) of the planned visit time (' + planned + '). ' +
                    'Contact your Area Manager if you need an override.'
                );
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 2 — createActivityTasks
    // Called from: RetailVisitTriggerHandler.afterInsert
    //
    // For every newly inserted Visit with Status = Planned:
    //   1. Query the store's Activity Plan Template assignment
    //   2. Query all Activity_Plan_Item__c records for those templates
    //   3. Bulk-insert one Task per item per visit
    //
    // No DML inside any loop. One Database.insert call for all tasks.
    // ─────────────────────────────────────────────────────────────────────────
    public static void createActivityTasks(List<RetailVisit__c> newVisits) {
        // Filter to planned visits with a store assignment
        List<RetailVisit__c> plannedVisits = new List<RetailVisit__c>();
        Set<Id> storeIds = new Set<Id>();

        for (RetailVisit__c v : newVisits) {
            if (v.Status__c == STATUS_PLANNED && v.Store__c != null) {
                plannedVisits.add(v);
                storeIds.add(v.Store__c);
            }
        }
        if (plannedVisits.isEmpty()) return;

        // Query stores for their Activity Plan Template name
        Map<Id, Account> storeMap = new Map<Id, Account>([
            SELECT Id, ActivityPlanTemplate__c
            FROM   Account
            WHERE  Id IN :storeIds
            WITH   USER_MODE
        ]);

        // Collect unique template names
        Set<String> templateNames = new Set<String>();
        for (Account store : storeMap.values()) {
            if (String.isNotBlank(store.ActivityPlanTemplate__c)) {
                templateNames.add(store.ActivityPlanTemplate__c);
            }
        }
        if (templateNames.isEmpty()) return;

        // Query Activity Plan Items grouped by template name
        Map<String, List<Activity_Plan_Item__c>> itemsByTemplate =
            new Map<String, List<Activity_Plan_Item__c>>();

        for (Activity_Plan_Item__c item : [
            SELECT Id,
                   Task_Subject__c,
                   Is_Mandatory__c,
                   Visit_Activity_Type__c,
                   Sequence_Order__c,
                   Activity_Plan_Template__r.Name
            FROM   Activity_Plan_Item__c
            WHERE  Activity_Plan_Template__r.Name           IN :templateNames
              AND  Activity_Plan_Template__r.IsActive__c     = true
            WITH   USER_MODE
            ORDER BY Sequence_Order__c ASC NULLS LAST
        ]) {
            String tName = item.Activity_Plan_Template__r.Name;
            if (!itemsByTemplate.containsKey(tName)) {
                itemsByTemplate.put(tName, new List<Activity_Plan_Item__c>());
            }
            itemsByTemplate.get(tName).add(item);
        }

        // Build Task records — no DML inside loops
        List<Task> tasksToInsert = new List<Task>();
        Date today = Date.today();

        for (RetailVisit__c visit : plannedVisits) {
            Account store = storeMap.get(visit.Store__c);
            if (store == null || String.isBlank(store.ActivityPlanTemplate__c)) continue;

            List<Activity_Plan_Item__c> items = itemsByTemplate.get(store.ActivityPlanTemplate__c);
            if (items == null || items.isEmpty()) continue;

            for (Activity_Plan_Item__c item : items) {
                Task t = new Task();
                t.WhatId                 = visit.Id;
                t.OwnerId                = visit.OwnerId;
                t.Subject                = item.Task_Subject__c;
                t.Status                 = 'Not Started';
                t.Priority               = item.Is_Mandatory__c ? 'High' : 'Normal';
                t.Is_Mandatory__c        = item.Is_Mandatory__c;
                t.Visit_Activity_Type__c = item.Visit_Activity_Type__c;
                t.ActivityDate           = today;
                tasksToInsert.add(t);
            }
        }

        if (tasksToInsert.isEmpty()) return;

        List<Database.SaveResult> results = Database.insert(tasksToInsert, false);
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'RetailVisitService.createActivityTasks — Task insert failed: ' + sr.getErrors()
                );
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 3 — handleVisitCompletion
    // Called from: RetailVisitTriggerHandler.afterUpdate
    //
    // For every visit that transitions to Completed:
    //   a) Calculate Visit_Duration_Minutes__c
    //   b) Check if any mandatory Tasks are still open
    //   c) Create a follow-up Task for the Area Manager per visit with gaps
    //   d) Publish Visit_Completed__e Platform Event
    //
    // Three DML calls maximum regardless of batch size:
    //   Database.update (visit durations)
    //   Database.insert (follow-up tasks)
    //   EventBus.publish (platform events)
    // ─────────────────────────────────────────────────────────────────────────
    public static void handleVisitCompletion(
        List<RetailVisit__c>    newVisits,
        Map<Id, RetailVisit__c> oldMap
    ) {
        // Collect visits that just transitioned to Completed
        List<RetailVisit__c> completedVisits = new List<RetailVisit__c>();
        Set<Id> completedIds  = new Set<Id>();
        Set<Id> storeIds      = new Set<Id>();

        for (RetailVisit__c visit : newVisits) {
            if (visit.Status__c == STATUS_COMPLETED
                && oldMap.get(visit.Id).Status__c != STATUS_COMPLETED) {
                completedVisits.add(visit);
                completedIds.add(visit.Id);
                if (visit.Store__c != null) storeIds.add(visit.Store__c);
            }
        }
        if (completedVisits.isEmpty()) return;

        // Query all mandatory Tasks for completed visits in one SOQL
        Map<Id, List<Task>> mandatoryByVisit = new Map<Id, List<Task>>();
        for (Id vId : completedIds) {
            mandatoryByVisit.put(vId, new List<Task>());
        }

        for (Task t : [
            SELECT Id, WhatId, Subject, Status, Is_Mandatory__c
            FROM   Task
            WHERE  WhatId          IN :completedIds
              AND  Is_Mandatory__c = true
            WITH   USER_MODE
        ]) {
            mandatoryByVisit.get(t.WhatId).add(t);
        }

        // Query stores for Key Account Manager assignment
        Map<Id, Account> storeMap = new Map<Id, Account>([
            SELECT Id, Name, Key_Account_Manager__c, OwnerId
            FROM   Account
            WHERE  Id IN :storeIds
            WITH   USER_MODE
        ]);

        // Build output collections
        List<RetailVisit__c>   visitsToUpdate = new List<RetailVisit__c>();
        List<Task>             followUpTasks  = new List<Task>();
        List<Visit_Completed__e> events       = new List<Visit_Completed__e>();

        for (RetailVisit__c visit : completedVisits) {
            // ── a) Duration calculation ──────────────────────────────────────
            Integer durationMinutes = 0;
            if (visit.ActualVisitStartTime__c != null && visit.ActualVisitEndTime__c != null) {
                durationMinutes = (Integer)(
                    (visit.ActualVisitEndTime__c.getTime() -
                     visit.ActualVisitStartTime__c.getTime()) / 60000L
                );
            }
            visitsToUpdate.add(new RetailVisit__c(
                Id                       = visit.Id,
                Visit_Duration_Minutes__c = durationMinutes
            ));

            // ── b) Mandatory task completion check ───────────────────────────
            List<Task> mandatory      = mandatoryByVisit.get(visit.Id);
            List<String> incompleteSubs = new List<String>();
            for (Task t : mandatory) {
                if (t.Status != 'Completed') {
                    incompleteSubs.add(t.Subject);
                }
            }

            // ── c) Follow-up task for manager ────────────────────────────────
            if (!incompleteSubs.isEmpty()) {
                Account store   = storeMap.get(visit.Store__c);
                Id managerId    = (store != null && store.Key_Account_Manager__c != null)
                    ? store.Key_Account_Manager__c
                    : UserInfo.getUserId();

                String storeName = (store != null) ? store.Name : 'Unknown Store';

                Task followUp = new Task();
                followUp.Subject      = 'Follow-up: ' + incompleteSubs.size()
                    + ' incomplete mandatory task(s) — ' + storeName;
                followUp.WhatId       = visit.Store__c;
                followUp.OwnerId      = managerId;
                followUp.Status       = 'Not Started';
                followUp.Priority     = 'High';
                followUp.ActivityDate = Date.today().addDays(1);
                followUp.Description  =
                    'Visit ' + visit.Name + ' was marked Completed with the following mandatory ' +
                    'tasks still open:\n\n• ' + String.join(incompleteSubs, '\n• ') +
                    '\n\nPlease follow up with the field rep or reschedule the visit.';
                followUpTasks.add(followUp);
            }

            // ── d) Platform Event ────────────────────────────────────────────
            events.add(new Visit_Completed__e(
                Visit_Id__c         = visit.Id,
                Store_Id__c         = visit.Store__c,
                Rep_Id__c           = visit.OwnerId,
                Completion_Time__c  = visit.ActualVisitEndTime__c,
                Duration_Minutes__c = durationMinutes
            ));
        }

        // ── DML — three calls, outside all loops ─────────────────────────────
        if (!visitsToUpdate.isEmpty()) {
            for (Database.SaveResult sr : Database.update(visitsToUpdate, false)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'RetailVisitService — visit duration update failed: ' + sr.getErrors());
                }
            }
        }

        if (!followUpTasks.isEmpty()) {
            for (Database.SaveResult sr : Database.insert(followUpTasks, false)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'RetailVisitService — follow-up task insert failed: ' + sr.getErrors());
                }
            }
        }

        if (!events.isEmpty()) {
            for (Database.SaveResult sr : EventBus.publish(events)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'RetailVisitService — Visit_Completed__e publish failed: ' + sr.getErrors());
                }
            }
        }
    }
}
