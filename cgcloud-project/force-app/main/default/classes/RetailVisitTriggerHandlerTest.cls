/**
 * @description Tests for RetailVisitTriggerHandler → RetailVisitService.
 *
 *              Coverage targets (85%+):
 *                RetailVisitTriggerHandler  — 100% (all three overrides exercised)
 *                RetailVisitService         —  90%+ (all three public methods)
 *
 *              Test strategy:
 *                • @testSetup creates shared store, Activity Plan Template, and
 *                  template items once per class run — avoids repeat DML overhead.
 *                • Trigger fires naturally on insert/update — no direct service
 *                  calls. This tests the full stack: Trigger → Handler → Service.
 *                • Bulk test at 200 records verifies no governor-limit violations.
 *                • Platform Event publish verified indirectly: duration calculation
 *                  proves handleVisitCompletion reached the EventBus.publish() call.
 *                  (Direct event delivery is not verifiable in test context without
 *                   a trigger subscriber.)
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
@isTest
private class RetailVisitTriggerHandlerTest {

    // Number of Activity Plan Items per template —
    // 3 items: 2 mandatory (Stock Check, Order Capture), 1 optional (Competitor Audit)
    static final Integer ITEMS_PER_TEMPLATE = 3;
    static final Integer MANDATORY_ITEMS    = 2;
    static final String  TEMPLATE_NAME      = 'Test_Full_Visit';

    // ── Shared Test Data ─────────────────────────────────────────────────────
    @testSetup
    static void setup() {
        // Store Account
        Account store = new Account(
            Name                     = 'Test Hypermarket #001',
            ActivityPlanTemplate__c  = TEMPLATE_NAME,
            Key_Account_Manager__c   = UserInfo.getUserId()
        );
        insert store;

        // Activity Plan Template
        Activity_Plan_Template__c template = new Activity_Plan_Template__c(
            Name        = TEMPLATE_NAME,
            IsActive__c = true
        );
        insert template;

        // Template Items — 2 mandatory, 1 optional
        List<Activity_Plan_Item__c> items = new List<Activity_Plan_Item__c>{
            new Activity_Plan_Item__c(
                Activity_Plan_Template__c = template.Id,
                Task_Subject__c           = 'Stock Check',
                Is_Mandatory__c           = true,
                Visit_Activity_Type__c    = 'Stock Check',
                Sequence_Order__c         = 1
            ),
            new Activity_Plan_Item__c(
                Activity_Plan_Template__c = template.Id,
                Task_Subject__c           = 'Order Capture',
                Is_Mandatory__c           = true,
                Visit_Activity_Type__c    = 'Order Capture',
                Sequence_Order__c         = 2
            ),
            new Activity_Plan_Item__c(
                Activity_Plan_Template__c = template.Id,
                Task_Subject__c           = 'Competitor Audit',
                Is_Mandatory__c           = false,
                Visit_Activity_Type__c    = 'Competitor Audit',
                Sequence_Order__c         = 3
            )
        };
        insert items;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — validateVisitCheckIn: within window → update succeeds
    //
    // Visit_Config__mdt not deployed in test context → fallback 2-hour window.
    // PlannedVisitStartTime = now → within 2 hours → status update allowed.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testValidateCheckIn_withinWindow_allowed() {
        Account store = [SELECT Id FROM Account LIMIT 1];

        RetailVisit__c visit = new RetailVisit__c(
            Store__c                 = store.Id,
            Status__c                = 'Planned',
            PlannedVisitStartTime__c = Datetime.now()
        );
        insert visit;

        Test.startTest();
        visit.Status__c = 'In Progress';
        Database.SaveResult sr = Database.update(visit, false);
        Test.stopTest();

        System.assert(sr.isSuccess(),
            'Check-in within the 2-hour window should succeed. Errors: ' +
            (sr.isSuccess() ? '' : sr.getErrors().toString()));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — validateVisitCheckIn: outside window → addError blocks DML
    //
    // PlannedVisitStartTime = 5 hours ago → outside 2-hour window.
    // Database.update(allOrNone=false) returns SaveResult with errors.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testValidateCheckIn_outsideWindow_blocked() {
        Account store = [SELECT Id FROM Account LIMIT 1];

        RetailVisit__c visit = new RetailVisit__c(
            Store__c                 = store.Id,
            Status__c                = 'Planned',
            PlannedVisitStartTime__c = Datetime.now().addHours(-5)
        );
        insert visit;

        Test.startTest();
        visit.Status__c = 'In Progress';
        Database.SaveResult sr = Database.update(visit, false);
        Test.stopTest();

        System.assert(!sr.isSuccess(),
            'Check-in 5 hours outside the window should be blocked.');
        System.assert(
            !sr.getErrors().isEmpty(),
            'SaveResult should contain at least one error.');
        System.assert(
            sr.getErrors()[0].getMessage().containsIgnoreCase('Check-in'),
            'Error message should reference the check-in window. Got: ' +
            sr.getErrors()[0].getMessage());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — createActivityTasks: correct number of Tasks per template
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testCreateActivityTasks_createsCorrectNumberOfTasks() {
        Account store = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        RetailVisit__c visit = new RetailVisit__c(
            Store__c                 = store.Id,
            Status__c                = 'Planned',
            PlannedVisitStartTime__c = Datetime.now()
        );
        insert visit;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, Subject, Is_Mandatory__c
                            FROM Task
                            WHERE WhatId = :visit.Id];

        System.assertEquals(ITEMS_PER_TEMPLATE, tasks.size(),
            'Expected ' + ITEMS_PER_TEMPLATE + ' tasks from template. Got: ' + tasks.size());

        Integer mandatoryCount = 0;
        for (Task t : tasks) {
            if (t.Is_Mandatory__c) mandatoryCount++;
        }
        System.assertEquals(MANDATORY_ITEMS, mandatoryCount,
            'Expected ' + MANDATORY_ITEMS + ' mandatory tasks.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — createActivityTasks: bulk 200 visits — no governor limit breach
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testCreateActivityTasks_bulk200Visits() {
        Account store = [SELECT Id FROM Account LIMIT 1];

        List<RetailVisit__c> visits = new List<RetailVisit__c>();
        for (Integer i = 0; i < 200; i++) {
            visits.add(new RetailVisit__c(
                Store__c                 = store.Id,
                Status__c                = 'Planned',
                PlannedVisitStartTime__c = Datetime.now().addHours(i)
            ));
        }

        Test.startTest();
        insert visits;
        Test.stopTest();

        Integer expected = 200 * ITEMS_PER_TEMPLATE;
        Integer actual   = [SELECT COUNT() FROM Task WHERE WhatId IN :visits];

        System.assertEquals(expected, actual,
            'Bulk 200 visits should create ' + expected + ' total tasks. Got: ' + actual);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5 — handleVisitCompletion: all mandatory tasks done → no follow-up
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testHandleVisitCompletion_allTasksComplete_noFollowUp() {
        Account store = [SELECT Id FROM Account LIMIT 1];

        // Insert visit — trigger creates activity tasks
        RetailVisit__c visit = new RetailVisit__c(
            Store__c                 = store.Id,
            Status__c                = 'Planned',
            PlannedVisitStartTime__c = Datetime.now()
        );
        insert visit;

        // Mark all tasks as Completed
        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :visit.Id];
        for (Task t : tasks) t.Status = 'Completed';
        if (!tasks.isEmpty()) update tasks;

        Test.startTest();
        visit.Status__c             = 'Completed';
        visit.ActualVisitStartTime__c = Datetime.now().addMinutes(-45);
        visit.ActualVisitEndTime__c   = Datetime.now();
        update visit;
        Test.stopTest();

        // Follow-up tasks are created on the store Account (WhatId = store.Id)
        Integer followUpCount = [
            SELECT COUNT() FROM Task
            WHERE WhatId     = :store.Id
              AND Subject    LIKE 'Follow-up:%'
        ];
        System.assertEquals(0, followUpCount,
            'No follow-up task should be created when all mandatory tasks are complete.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 6 — handleVisitCompletion: incomplete mandatory tasks → follow-up
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testHandleVisitCompletion_incompleteTasks_createsFollowUp() {
        Account store = [SELECT Id FROM Account LIMIT 1];

        RetailVisit__c visit = new RetailVisit__c(
            Store__c                 = store.Id,
            Status__c                = 'Planned',
            PlannedVisitStartTime__c = Datetime.now()
        );
        insert visit;

        // Do NOT complete the tasks — leave them as 'Not Started'

        Test.startTest();
        visit.Status__c               = 'Completed';
        visit.ActualVisitStartTime__c = Datetime.now().addMinutes(-30);
        visit.ActualVisitEndTime__c   = Datetime.now();
        update visit;
        Test.stopTest();

        List<Task> followUps = [
            SELECT Id, Subject, Priority, OwnerId
            FROM Task
            WHERE WhatId    = :store.Id
              AND Subject   LIKE 'Follow-up:%'
        ];
        System.assertEquals(1, followUps.size(),
            'Exactly one follow-up task should be created for incomplete mandatory tasks.');
        System.assertEquals('High', followUps[0].Priority,
            'Follow-up task should have High priority.');
        System.assertEquals(UserInfo.getUserId(), followUps[0].OwnerId,
            'Follow-up task should be assigned to KAM (which is current user in testSetup).');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 7 — handleVisitCompletion: Platform Event publish
    //
    // We cannot directly assert EventBus delivery in test context without a
    // trigger subscriber. Instead we verify that:
    //   (a) The handler ran to completion — Visit_Duration_Minutes__c is set
    //   (b) The duration is mathematically correct (30 min visit)
    //   (c) No DmlException was thrown (would indicate EventBus.publish failed)
    //
    // This gives us 100% line coverage of the EventBus.publish() call path.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testHandleVisitCompletion_publishesPlatformEvent() {
        Account store = [SELECT Id FROM Account LIMIT 1];

        RetailVisit__c visit = new RetailVisit__c(
            Store__c                 = store.Id,
            Status__c                = 'Planned',
            PlannedVisitStartTime__c = Datetime.now()
        );
        insert visit;

        // Complete all tasks to isolate the event publish path
        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :visit.Id];
        for (Task t : tasks) t.Status = 'Completed';
        if (!tasks.isEmpty()) update tasks;

        Datetime startTime = Datetime.now().addMinutes(-30);
        Datetime endTime   = Datetime.now();

        Test.startTest();
        visit.Status__c               = 'Completed';
        visit.ActualVisitStartTime__c = startTime;
        visit.ActualVisitEndTime__c   = endTime;
        update visit;
        Test.stopTest();

        RetailVisit__c result = [
            SELECT Visit_Duration_Minutes__c
            FROM   RetailVisit__c
            WHERE  Id = :visit.Id
        ];

        System.assertNotEquals(null, result.Visit_Duration_Minutes__c,
            'Duration must be populated — proves handleVisitCompletion ran to the Platform Event call.');
        System.assert(result.Visit_Duration_Minutes__c >= 28,
            'Duration should be approximately 30 minutes. Got: ' + result.Visit_Duration_Minutes__c);
    }
}
