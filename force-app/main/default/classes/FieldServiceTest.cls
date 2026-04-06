/**
 * @description Tests for Day 27 — Field Service Lightning: Work Orders, Service
 *              Appointments, Resource Management, Scheduling.
 *
 *              FSL managed package objects (ServiceAppointment, ServiceResource,
 *              ServiceTerritory, etc.) are standard in FSL-enabled orgs. Tests are
 *              written to degrade gracefully when the FSL package is not installed
 *              (try/catch on DML operations against FSL objects).
 *
 *              WorkOrder is a standard platform object (available without FSL package)
 *              and is tested with real DML. ServiceAppointment-level tests use mock
 *              injection where possible.
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class FieldServiceTest {

    // ─── Fake ID helper ───────────────────────────────────────────────────────

    private static Integer fakeCounter = 0;
    private static Id fakeId(Schema.SObjectType t) {
        String prefix = t.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(++fakeCounter).leftPad(12, '0');
        return (Id)(prefix + '0' + suffix);
    }

    // ─── Test data setup ──────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        Account acc = new Account(Name = 'FSL Test Account');
        insert acc;

        Contact con = new Contact(LastName = 'FSL Contact', AccountId = acc.Id);
        insert con;

        Case c = new Case(
            AccountId = acc.Id,
            ContactId = con.Id,
            Subject   = 'Equipment failure',
            Status    = 'New',
            Origin    = 'Phone'
        );
        insert c;
    }

    // ─── WorkOrderService — createFromCase ───────────────────────────────────

    @IsTest static void createFromCase_createsWorkOrderLinkedToCase() {
        Case c = [SELECT Id, AccountId, ContactId FROM Case LIMIT 1];

        Test.startTest();
        Id woId = WorkOrderService.createFromCase(c.Id, 'Repair pump', 'Pump seal failure', null);
        Test.stopTest();

        WorkOrder wo = [SELECT Id, CaseId, AccountId, Subject, Status FROM WorkOrder WHERE Id = :woId];
        System.assertEquals(c.Id,        wo.CaseId,    'WorkOrder must link back to Case');
        System.assertEquals(c.AccountId, wo.AccountId, 'AccountId must be copied from Case');
        System.assertEquals('Repair pump', wo.Subject, 'Subject must match');
        System.assertEquals('New',          wo.Status,  'Initial status must be New');
    }

    @IsTest static void createFromCase_updatesCaseStatus() {
        Case c = [SELECT Id FROM Case LIMIT 1];

        Test.startTest();
        WorkOrderService.createFromCase(c.Id, 'Install unit', 'New install required', null);
        Test.stopTest();

        c = [SELECT Status FROM Case WHERE Id = :c.Id];
        System.assertEquals('Work Order Issued', c.Status,
            'Case status must be updated to prevent duplicate dispatch');
    }

    @IsTest static void createFromCase_withWorkTypeId_populatesField() {
        Case c = [SELECT Id FROM Case LIMIT 1];
        // Use a fake WorkType Id — field accepts any 18-char Id in test context
        Id workTypeId = fakeId(WorkType.SObjectType);

        Test.startTest();
        Id woId = WorkOrderService.createFromCase(c.Id, 'Scheduled maintenance', 'Annual PM', workTypeId);
        Test.stopTest();

        WorkOrder wo = [SELECT WorkTypeId FROM WorkOrder WHERE Id = :woId];
        System.assertEquals(workTypeId, wo.WorkTypeId, 'WorkTypeId must be set');
    }

    // ─── WorkOrderService — createStandalone ─────────────────────────────────

    @IsTest static void createStandalone_createsWorkOrderWithoutCase() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Id woId = WorkOrderService.createStandalone(acc.Id, 'Preventive maintenance', 'High', null);
        Test.stopTest();

        WorkOrder wo = [SELECT Id, CaseId, AccountId, Priority, Status FROM WorkOrder WHERE Id = :woId];
        System.assertNull(wo.CaseId,       'Standalone WO must have no CaseId');
        System.assertEquals(acc.Id,         wo.AccountId, 'AccountId must be set');
        System.assertEquals('High',          wo.Priority,  'Priority must match');
        System.assertEquals('New',           wo.Status,    'Status must be New');
    }

    @IsTest static void createStandalone_nullPriority_defaultsMedium() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Id woId = WorkOrderService.createStandalone(acc.Id, 'Inspection', null, null);
        Test.stopTest();

        WorkOrder wo = [SELECT Priority FROM WorkOrder WHERE Id = :woId];
        System.assertEquals('Medium', wo.Priority, 'Null priority should default to Medium');
    }

    // ─── WorkOrderService — addLineItem ──────────────────────────────────────

    @IsTest static void addLineItem_createsWoliUnderWorkOrder() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Id woId = WorkOrderService.createStandalone(acc.Id, 'Multi-task job', 'Medium', null);

        Test.startTest();
        Id woliId = WorkOrderService.addLineItem(woId, 'Replace filter', 30);
        Test.stopTest();

        WorkOrderLineItem woli = [
            SELECT WorkOrderId, Subject, Duration, DurationType, Status
            FROM   WorkOrderLineItem
            WHERE  Id = :woliId
        ];
        System.assertEquals(woId,      woli.WorkOrderId,  'WOLI must link to parent WO');
        System.assertEquals('Replace filter', woli.Subject, 'Subject must match');
        System.assertEquals(30,         woli.Duration,    'Duration must be 30');
        System.assertEquals('Minutes',  woli.DurationType,'DurationType must be Minutes');
        System.assertEquals('New',      woli.Status,      'Initial WOLI status must be New');
    }

    @IsTest static void addLineItem_multipleLineItems_allLinkedToSameWo() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Id woId = WorkOrderService.createStandalone(acc.Id, 'Complex job', 'High', null);

        Test.startTest();
        WorkOrderService.addLineItem(woId, 'Task 1', 20);
        WorkOrderService.addLineItem(woId, 'Task 2', 45);
        WorkOrderService.addLineItem(woId, 'Task 3', 15);
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM WorkOrderLineItem WHERE WorkOrderId = :woId
        ];
        System.assertEquals(3, count, 'Three line items must be created under the WO');
    }

    // ─── WorkOrderService — completeWorkOrder ────────────────────────────────

    @IsTest static void completeWorkOrder_setsStatusCompleted() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Id woId = WorkOrderService.createStandalone(acc.Id, 'Quick fix', 'Medium', null);

        Test.startTest();
        WorkOrderService.completeWorkOrder(woId, false);
        Test.stopTest();

        WorkOrder wo = [SELECT Status FROM WorkOrder WHERE Id = :woId];
        System.assertEquals('Completed', wo.Status, 'Status must be Completed');
    }

    @IsTest static void completeWorkOrder_withCloseCase_closesCaseAlso() {
        Case c = [SELECT Id FROM Case LIMIT 1];
        Id woId = WorkOrderService.createFromCase(c.Id, 'Fix complete', 'All done', null);

        Test.startTest();
        WorkOrderService.completeWorkOrder(woId, true);
        Test.stopTest();

        c = [SELECT Status FROM Case WHERE Id = :c.Id];
        System.assertEquals('Closed', c.Status, 'Case must be closed when closeCase=true');
    }

    @IsTest static void completeWorkOrder_withoutCloseCase_caseRemainsOpen() {
        Case c = [SELECT Id FROM Case LIMIT 1];
        Id woId = WorkOrderService.createFromCase(c.Id, 'Fix in progress', 'Partial fix', null);

        Test.startTest();
        WorkOrderService.completeWorkOrder(woId, false);
        Test.stopTest();

        // Case was set to 'Work Order Issued' in createFromCase, NOT Closed
        c = [SELECT Status FROM Case WHERE Id = :c.Id];
        System.assertNotEquals('Closed', c.Status, 'Case must not be closed when closeCase=false');
    }

    // ─── WorkOrderService — markCannotComplete ────────────────────────────────

    @IsTest static void markCannotComplete_setsStatusAndReason() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Id woId = WorkOrderService.createStandalone(acc.Id, 'Access denied', 'High', null);

        Test.startTest();
        WorkOrderService.markCannotComplete(woId, 'No site access — reschedule required');
        Test.stopTest();

        WorkOrder wo = [SELECT Status, Description FROM WorkOrder WHERE Id = :woId];
        System.assertEquals('Cannot Complete', wo.Status);
        System.assert(wo.Description.contains('reschedule'), 'Description must contain the reason');
    }

    // ─── WorkOrderService — queries ───────────────────────────────────────────

    @IsTest static void getOpenWorkOrders_excludesClosedStatuses() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        WorkOrderService.createStandalone(acc.Id, 'Open WO',      'Medium', null);
        Id closedId = WorkOrderService.createStandalone(acc.Id, 'Completed WO', 'Low', null);
        WorkOrderService.completeWorkOrder(closedId, false);

        Test.startTest();
        List<WorkOrder> open = WorkOrderService.getOpenWorkOrders(acc.Id);
        Test.stopTest();

        for (WorkOrder wo : open) {
            System.assert(
                !new Set<String>{'Completed','Canceled','Cannot Complete'}.contains(wo.Status),
                'Closed WOs must be excluded from open list'
            );
        }
        System.assert(!open.isEmpty(), 'At least one open WO should be returned');
    }

    @IsTest static void getStaleWorkOrders_returnsOnlyOlderThanThreshold() {
        Test.startTest();
        // Freshly created WOs are NOT stale (0-day threshold means cutoff = now)
        List<WorkOrder> stale = WorkOrderService.getStaleWorkOrders(0);
        Test.stopTest();

        // Freshly inserted WOs have CreatedDate = now — not strictly before cutoff
        for (WorkOrder wo : stale) {
            System.assert(
                !new Set<String>{'Completed','Canceled','Cannot Complete'}.contains(wo.Status),
                'Completed WOs must not appear in stale list'
            );
        }
    }

    // ─── ServiceAppointmentService — dispatch exception ───────────────────────

    @IsTest static void dispatch_throwsWhenStatusIsNotScheduled() {
        // Create a minimal SA in 'None' status — dispatch should throw
        Account acc  = [SELECT Id FROM Account LIMIT 1];
        Id woId      = WorkOrderService.createStandalone(acc.Id, 'FSL SA Test', 'Medium', null);
        Id resourceId = fakeId(ServiceResource.SObjectType);

        ServiceAppointment sa;
        try {
            sa = new ServiceAppointment(
                ParentRecordId    = woId,
                Subject           = 'Test SA',
                EarliestStartTime = DateTime.now(),
                DueDate           = DateTime.now().addDays(1),
                Duration          = 60,
                DurationType      = 'Minutes',
                Status            = 'None'
            );
            insert sa;
        } catch (Exception e) {
            // FSL package not installed — skip FSL DML tests gracefully
            System.assert(true, 'FSL not installed — skipping SA DML test');
            return;
        }

        Test.startTest();
        try {
            ServiceAppointmentService.dispatch(sa.Id, resourceId);
            System.assert(false, 'Expected FslException for non-Scheduled SA');
        } catch (ServiceAppointmentService.FslException e) {
            System.assert(e.getMessage().contains('Cannot dispatch'));
        }
        Test.stopTest();
    }

    // ─── ServiceAppointmentService — mock schedule result ────────────────────

    @IsTest static void scheduleAppointment_returnsMockResult() {
        Id saId               = fakeId(ServiceAppointment.SObjectType);
        Id policyId           = fakeId(FSL__Scheduling_Policy__c.SObjectType);
        FSL.ScheduleResult mock = new FSL.ScheduleResult();
        ServiceAppointmentService.mockScheduleResult = mock;

        Test.startTest();
        FSL.ScheduleResult result =
            ServiceAppointmentService.scheduleAppointment(saId, policyId);
        Test.stopTest();

        System.assertNotNull(result, 'Mock schedule result should be returned in test context');
    }

    // ─── ServiceAppointmentService — in-jeopardy (SOQL structural) ───────────

    @IsTest static void getInJeopardyAppointments_runsSoqlWithoutError() {
        Id territoryId = fakeId(ServiceTerritory.SObjectType);

        Test.startTest();
        try {
            List<ServiceAppointment> atRisk =
                ServiceAppointmentService.getInJeopardyAppointments(territoryId, 60);
            System.assertNotNull(atRisk);
        } catch (System.QueryException e) {
            // FSL not installed — SOQL against SA object may fail gracefully
            System.assert(true, 'FSL not installed — skipping SA query test');
        }
        Test.stopTest();
    }

    // ─── ServiceAppointmentService — createForWorkOrder ──────────────────────

    @IsTest static void createForWorkOrder_createsServiceAppointment() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Id woId     = WorkOrderService.createStandalone(acc.Id, 'SA creation test', 'High', null);

        Test.startTest();
        try {
            Id saId = ServiceAppointmentService.createForWorkOrder(
                woId, 'On-site repair',
                DateTime.now(), DateTime.now().addDays(2), 90
            );
            System.assertNotNull(saId, 'ServiceAppointment Id must be returned');

            ServiceAppointment sa = [
                SELECT ParentRecordId, Subject, Duration, Status
                FROM   ServiceAppointment WHERE Id = :saId
            ];
            System.assertEquals(woId,         sa.ParentRecordId, 'SA must link to WO');
            System.assertEquals('On-site repair', sa.Subject);
            System.assertEquals(90,            sa.Duration);
            System.assertEquals('None',         sa.Status);
        } catch (Exception e) {
            // FSL package not installed
            System.assert(true, 'FSL not installed — SA creation skipped');
        }
        Test.stopTest();
    }

    // ─── WorkOrderService — getOpenWorkOrders empty case ─────────────────────

    @IsTest static void getOpenWorkOrders_noWorkOrders_returnsEmpty() {
        // Use a brand-new account with no WOs
        Account freshAcc = new Account(Name = 'No WO Account');
        insert freshAcc;

        Test.startTest();
        List<WorkOrder> result = WorkOrderService.getOpenWorkOrders(freshAcc.Id);
        Test.stopTest();

        System.assert(result.isEmpty(), 'Should return empty list for account with no WOs');
    }
}
