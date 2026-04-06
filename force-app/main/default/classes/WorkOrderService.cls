/**
 * @description Field Service Lightning — Work Order and Work Order Line Item management.
 *
 *              FSL OBJECT MODEL (interview framework):
 *
 *              WorkOrder
 *                └── WorkOrderLineItem  (individual tasks within the work order)
 *                └── ServiceAppointment (scheduled visit; linked to WorkOrder or WOLI)
 *                      └── AssignedResource (junction: SA → ServiceResource)
 *
 *              ServiceResource    — a technician or piece of equipment that can be scheduled
 *              ServiceTerritory   — geographic/logical zone; resources belong to territories
 *              ServiceTerritoryMember — junction: ServiceResource ↔ ServiceTerritory
 *              OperatingHours     — working schedule for a territory or resource
 *              ResourceAbsence    — planned unavailability (holiday, sick leave)
 *              Skill              — competency definition (e.g. "HVAC Certified")
 *              ServiceResourceSkill — junction: resource ↔ skill (with expiry date)
 *
 *              WorkType           — reusable template defining:
 *                                    EstimatedDuration, SkillRequirements, BlockTimeAfter
 *
 *              ServiceAppointment.Status values:
 *                None / Scheduled / Dispatched / In Progress / Completed / Cannot Complete /
 *                Canceled / In Jeopardy
 *
 *              Scheduling Engine:
 *                - Optimization: global — runs in background, optimises entire schedule
 *                - Scheduling: per-appointment — finds best slot for one SA
 *                - In-Day: real-time — adjusts schedule for same-day changes
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class WorkOrderService {

    // ─── Work Order creation ──────────────────────────────────────────────────

    /**
     * Creates a Work Order from a Case — standard FSL escalation pattern.
     *
     * Interview point: Work Orders are typically created when a Case requires an
     * on-site visit. The Case remains open until the Work Order is completed.
     * Case.Status is updated to 'Work Order Issued' to prevent duplicate dispatches.
     *
     * @param caseId      Source Case — AccountId + ContactId copied to Work Order
     * @param subject     Work Order subject
     * @param description Detailed description of work required
     * @param workTypeId  Optional WorkType Id (drives duration and skill requirements)
     * @return            Newly created Work Order Id
     */
    public static Id createFromCase(
            Id caseId, String subject, String description, Id workTypeId) {
        Case c = [SELECT Id, AccountId, ContactId FROM Case WHERE Id = :caseId];

        WorkOrder wo = new WorkOrder(
            CaseId      = caseId,
            AccountId   = c.AccountId,
            ContactId   = c.ContactId,
            Subject     = subject,
            Description = description,
            Status      = 'New',
            Priority    = 'Medium'
        );
        if (workTypeId != null) { wo.WorkTypeId = workTypeId; }
        insert wo;

        // Mark the case to prevent a second Work Order being dispatched
        update new Case(Id = caseId, Status = 'Work Order Issued');
        return wo.Id;
    }

    /**
     * Creates a standalone Work Order not linked to a Case.
     * Used for preventive maintenance, installations, or proactive site visits.
     *
     * @param accountId    Account the work is performed for
     * @param subject      Work Order subject
     * @param priority     'Low' | 'Medium' | 'High' | 'Critical'
     * @param workTypeId   WorkType Id (may be null)
     * @return             Newly created Work Order Id
     */
    public static Id createStandalone(
            Id accountId, String subject, String priority, Id workTypeId) {
        WorkOrder wo = new WorkOrder(
            AccountId   = accountId,
            Subject     = subject,
            Priority    = String.isBlank(priority) ? 'Medium' : priority,
            Status      = 'New'
        );
        if (workTypeId != null) { wo.WorkTypeId = workTypeId; }
        insert wo;
        return wo.Id;
    }

    // ─── Work Order Line Items ────────────────────────────────────────────────

    /**
     * Adds a line item to an existing Work Order.
     *
     * Work Order Line Items represent discrete tasks. Each WOLI can have its own
     * ServiceAppointment — useful when different technicians handle different tasks.
     *
     * @param workOrderId  Parent Work Order
     * @param subject      Line item description
     * @param duration     Estimated duration in minutes
     * @return             Newly created WorkOrderLineItem Id
     */
    public static Id addLineItem(Id workOrderId, String subject, Integer duration) {
        WorkOrderLineItem woli = new WorkOrderLineItem(
            WorkOrderId       = workOrderId,
            Subject           = subject,
            Status            = 'New',
            Duration          = duration,
            DurationType      = 'Minutes'
        );
        insert woli;
        return woli.Id;
    }

    // ─── Status transitions ───────────────────────────────────────────────────

    /**
     * Completes a Work Order and optionally closes its parent Case.
     *
     * @param workOrderId  Work Order to complete
     * @param closeCase    If true and a Case is linked, closes the Case as well
     */
    public static void completeWorkOrder(Id workOrderId, Boolean closeCase) {
        WorkOrder wo = [SELECT Id, CaseId FROM WorkOrder WHERE Id = :workOrderId];
        wo.Status = 'Completed';
        update wo;

        if (closeCase && wo.CaseId != null) {
            update new Case(Id = wo.CaseId, Status = 'Closed');
        }
    }

    /**
     * Marks a Work Order as Cannot Complete with a reason captured in Description.
     * Triggers a follow-up Work Order creation in the calling process.
     *
     * @param workOrderId  Work Order that could not be completed
     * @param reason       Reason for non-completion (stored in Description)
     */
    public static void markCannotComplete(Id workOrderId, String reason) {
        update new WorkOrder(
            Id          = workOrderId,
            Status      = 'Cannot Complete',
            Description = reason
        );
    }

    // ─── Work Order queries ───────────────────────────────────────────────────

    /**
     * Returns open Work Orders for an Account ordered by Priority then CreatedDate.
     *
     * Priority sort: Critical first — achieved by ordering on SortOrder of picklist
     * values is not possible in SOQL; use application-layer sort after query if needed.
     *
     * @param accountId  Account to query open Work Orders for
     */
    public static List<WorkOrder> getOpenWorkOrders(Id accountId) {
        return [
            SELECT Id, Subject, Status, Priority, WorkTypeId,
                   CreatedDate, CaseId, ContactId
            FROM   WorkOrder
            WHERE  AccountId = :accountId
              AND  Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Returns Work Orders that have been open longer than ageDays.
     * Used by monitoring jobs to flag stale work that needs attention.
     *
     * @param ageDays  Flag work orders open longer than this many days
     */
    public static List<WorkOrder> getStaleWorkOrders(Integer ageDays) {
        DateTime cutoff = DateTime.now().addDays(-ageDays);
        return [
            SELECT Id, Subject, AccountId, Status, Priority, CreatedDate
            FROM   WorkOrder
            WHERE  Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
              AND  CreatedDate < :cutoff
            ORDER BY CreatedDate ASC
        ];
    }
}
