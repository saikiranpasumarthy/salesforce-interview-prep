/**
 * @description Field Service Lightning — Service Appointment scheduling, dispatch,
 *              resource management, and Optimization API integration.
 *
 *              SERVICE APPOINTMENT LIFECYCLE:
 *
 *                None → Scheduled → Dispatched → In Progress → Completed
 *                                               ↘ Cannot Complete
 *                          ↘ Canceled
 *                          ↘ In Jeopardy (SLA at risk)
 *
 *              SCHEDULING MODES:
 *
 *                Automatic (Scheduling Engine):
 *                  FSL.ScheduleService.schedule(schedulingPolicyId, serviceAppointmentId)
 *                  Returns ScheduleResult with scheduledTime, serviceResourceId, score.
 *
 *                Manual (drag-and-drop in Dispatcher Console):
 *                  Agent sets SchedStartTime + SchedEndTime + ServiceResourceId.
 *
 *                Global Optimization:
 *                  FSL.GlobalOptimizationRequest — runs asynchronously, optimises all SAs
 *                  in a territory. Returns an optimization request Id.
 *                  Results in a Platform Event (FSL.OptimizationEvent) on completion.
 *
 *              INTERVIEW: Difference between Scheduling and Optimization?
 *                Scheduling finds the NEXT available slot for ONE appointment.
 *                Optimization resequences ALL appointments to minimize travel time /
 *                maximize SLA compliance / balance workload — runs as a background job.
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class ServiceAppointmentService {

    // Allow test injection of FSL scheduling results
    @TestVisible static FSL.ScheduleResult mockScheduleResult;

    // ─── Create Service Appointment ───────────────────────────────────────────

    /**
     * Creates a Service Appointment linked to a Work Order.
     *
     * Interview: One WorkOrder can have multiple ServiceAppointments (multi-visit jobs).
     * One WorkOrderLineItem can also have its own SA for task-level scheduling.
     *
     * EarliestStartTime / DueDate drive the scheduling window.
     * The Scheduling Engine will only place the SA within this window.
     *
     * @param workOrderId       Parent Work Order
     * @param subject           Appointment subject
     * @param earliestStart     Earliest acceptable start time
     * @param dueDate           Latest acceptable completion time (SLA deadline)
     * @param durationMinutes   Estimated duration
     * @return                  Newly created ServiceAppointment Id
     */
    public static Id createForWorkOrder(
            Id workOrderId, String subject,
            DateTime earliestStart, DateTime dueDate, Integer durationMinutes) {
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId    = workOrderId,
            Subject           = subject,
            EarliestStartTime = earliestStart,
            DueDate           = dueDate,
            Duration          = durationMinutes,
            DurationType      = 'Minutes',
            Status            = 'None'
        );
        insert sa;
        return sa.Id;
    }

    // ─── Scheduling Engine ────────────────────────────────────────────────────

    /**
     * Schedules a Service Appointment using the FSL Scheduling Engine.
     *
     * FSL.ScheduleService.schedule() evaluates:
     *   - Available ServiceResources in the territory
     *   - Resource skills vs appointment skill requirements (from WorkType)
     *   - Travel time from previous appointment
     *   - Operating Hours and Resource Absences
     *   - Scheduling Policy rules (e.g. prefer high-priority, minimize travel)
     *
     * Returns null if no suitable slot is found (no available resource).
     *
     * Requires FSL managed package to be installed in the org.
     *
     * @param serviceAppointmentId  SA to schedule
     * @param schedulingPolicyId    FSL Scheduling Policy Id
     * @return                      ScheduleResult, or null if unschedulable
     */
    public static FSL.ScheduleResult scheduleAppointment(
            Id serviceAppointmentId, Id schedulingPolicyId) {
        if (Test.isRunningTest() && mockScheduleResult != null) {
            return mockScheduleResult;
        }
        try {
            return FSL.ScheduleService.schedule(schedulingPolicyId, serviceAppointmentId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'FSL scheduling failed for SA ' + serviceAppointmentId + ': ' + e.getMessage());
            return null;
        }
    }

    // ─── Status management ────────────────────────────────────────────────────

    /**
     * Dispatches a Service Appointment — transitions from Scheduled to Dispatched.
     * Dispatching typically triggers a mobile push notification to the technician.
     *
     * @param saId        Service Appointment to dispatch
     * @param resourceId  ServiceResource (technician) assigned to this appointment
     */
    public static void dispatch(Id saId, Id resourceId) {
        ServiceAppointment sa = [
            SELECT Id, Status FROM ServiceAppointment WHERE Id = :saId
        ];
        if (sa.Status != 'Scheduled') {
            throw new FslException(
                'Cannot dispatch SA in status: ' + sa.Status
                + '. Expected: Scheduled');
        }
        sa.Status            = 'Dispatched';
        sa.ServiceResourceId = resourceId;
        update sa;
    }

    /**
     * Marks a Service Appointment as In Progress (technician has arrived on site).
     */
    public static void startAppointment(Id saId) {
        update new ServiceAppointment(Id = saId, Status = 'In Progress',
            ActualStartTime = DateTime.now());
    }

    /**
     * Completes a Service Appointment.
     *
     * @param saId          Service Appointment to complete
     * @param closedStatus  Status value to set ('Completed' or 'Cannot Complete')
     * @param notes         Completion notes stored in Description
     */
    public static void completeAppointment(Id saId, String closedStatus, String notes) {
        update new ServiceAppointment(
            Id             = saId,
            Status         = closedStatus,
            ActualEndTime  = DateTime.now(),
            Description    = notes
        );
    }

    // ─── Resource management ──────────────────────────────────────────────────

    /**
     * Returns available ServiceResources in a territory who have a given skill.
     *
     * Interview: Skill matching is a core FSL concept. The Scheduling Engine does
     * this automatically, but Apex-based pre-filtering helps build custom scheduling UIs
     * or validate resource selection before calling FSL.ScheduleService.schedule().
     *
     * @param territoryId  ServiceTerritory to search within
     * @param skillId      Skill the resource must have (not expired)
     * @return             Matching ServiceResources
     */
    public static List<ServiceResource> getAvailableResourcesWithSkill(
            Id territoryId, Id skillId) {
        // Step 1: get resource IDs in the territory
        Set<Id> resourceIds = new Set<Id>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId
            FROM   ServiceTerritoryMember
            WHERE  ServiceTerritoryId = :territoryId
              AND  IsActive           = true
        ]) {
            resourceIds.add(stm.ServiceResourceId);
        }
        if (resourceIds.isEmpty()) { return new List<ServiceResource>(); }

        // Step 2: filter to resources with the required skill (not expired)
        Set<Id> skilledResourceIds = new Set<Id>();
        for (ServiceResourceSkill srs : [
            SELECT ServiceResourceId
            FROM   ServiceResourceSkill
            WHERE  ServiceResourceId IN :resourceIds
              AND  SkillId            = :skillId
              AND  (ExpirationDate = null OR ExpirationDate >= TODAY)
        ]) {
            skilledResourceIds.add(srs.ServiceResourceId);
        }
        if (skilledResourceIds.isEmpty()) { return new List<ServiceResource>(); }

        // Step 3: return ServiceResource records
        return [
            SELECT Id, Name, RelatedRecordId, IsActive, ResourceType
            FROM   ServiceResource
            WHERE  Id       IN :skilledResourceIds
              AND  IsActive  = true
        ];
    }

    /**
     * Returns scheduled Service Appointments for a resource on a given date.
     * Used by mobile FSL components to display the technician's day view.
     *
     * @param resourceId  ServiceResource (technician)
     * @param workDate    Date to retrieve appointments for
     */
    public static List<ServiceAppointment> getAppointmentsForResource(
            Id resourceId, Date workDate) {
        DateTime dayStart = DateTime.newInstance(workDate, Time.newInstance(0, 0, 0, 0));
        DateTime dayEnd   = DateTime.newInstance(workDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        return [
            SELECT Id, Subject, Status, SchedStartTime, SchedEndTime,
                   ActualStartTime, ActualEndTime, Duration, ParentRecordId
            FROM   ServiceAppointment
            WHERE  ServiceResourceId  = :resourceId
              AND  SchedStartTime    >= :dayStart
              AND  SchedStartTime    <  :dayEnd
            ORDER BY SchedStartTime ASC
        ];
    }

    // ─── In-Jeopardy detection ────────────────────────────────────────────────

    /**
     * Returns Service Appointments at risk of missing their DueDate
     * within the next warningMinutes window.
     *
     * In-Jeopardy is a platform-managed status but can also be set by custom logic
     * when the scheduling engine detects a travel-time conflict.
     *
     * @param territoryId    Territory to check
     * @param warningMinutes Flag SAs due within this many minutes
     */
    public static List<ServiceAppointment> getInJeopardyAppointments(
            Id territoryId, Integer warningMinutes) {
        DateTime threshold = DateTime.now().addMinutes(warningMinutes);
        return [
            SELECT Id, Subject, Status, DueDate, SchedStartTime,
                   ServiceResourceId, ParentRecordId
            FROM   ServiceAppointment
            WHERE  ServiceTerritoryId = :territoryId
              AND  Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
              AND  DueDate != null
              AND  DueDate <= :threshold
            ORDER BY DueDate ASC
        ];
    }

    // ─── Exception type ───────────────────────────────────────────────────────

    public class FslException extends Exception {}
}
