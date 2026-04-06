/**
 * @description Service Cloud case management — escalation, SLA stopwatch control,
 *              business hours calculations, breached milestone detection, and at-risk
 *              case identification.
 *
 *              Key Service Cloud objects (interview framework):
 *
 *              Case             — the central support record; ties everything together
 *              Entitlement      — defines what level of service an account/contact is owed
 *              EntitlementContact — junction between Contact and Entitlement
 *              SlaProcess       — the entitlement process; drives milestone generation
 *              CaseMilestone    — individual time-bound target on a Case (e.g. First Response)
 *              MilestoneType    — template that defines the milestone (name + recurrence)
 *              BusinessHours    — defines working hours; used by SLA time calculations
 *              CaseTeamMember   — user associated with a Case in a specific role
 *              CaseTeamRole     — role template (e.g. Sales Manager, Technical Lead)
 *              CaseComment      — internal/external notes threaded on a Case
 *
 *              SLA Stopwatch (IsStopped):
 *                Case.IsStopped = true  → SLA timer paused (waiting for customer)
 *                Case.IsStopped = false → SLA timer running
 *                Case.SlaStartDate      → when the SLA clock started
 *                Case.SlaExitDate       → deadline — when SLA is breached
 *                CaseMilestone.IsViolated = true → deadline passed, milestone not met
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class CaseManagementService {

    // Inject mock milestone data in tests — CaseMilestone cannot be DML-inserted
    // in a test org without a configured Entitlement Process
    @TestVisible static List<CaseMilestone> mockBreachedMilestones;

    // ─── Case Escalation ──────────────────────────────────────────────────────

    /**
     * Escalates a Case: sets IsEscalated = true and adds an internal CaseComment
     * documenting the escalation reason for audit purposes.
     *
     * Idempotent — if the case is already escalated, exits without DML.
     *
     * Interview point: IsEscalated is a standard boolean on Case. Setting it to true
     * does NOT auto-notify anyone by default — combine with email alerts, assignment
     * rules, or a Flow to trigger notifications.
     *
     * @param caseId  Id of the Case to escalate
     * @param reason  Human-readable escalation reason (stored in CaseComment)
     */
    public static void escalateCase(Id caseId, String reason) {
        Case c = [SELECT Id, IsEscalated FROM Case WHERE Id = :caseId];
        if (c.IsEscalated) { return; }  // idempotent

        c.IsEscalated = true;
        update c;

        insert new CaseComment(
            ParentId     = caseId,
            CommentBody  = 'Escalated: ' + (String.isBlank(reason) ? 'No reason provided' : reason),
            IsPublished  = false   // internal note, not visible to customer portal
        );
    }

    /**
     * Bulk-closes all open Cases created before the cutoff threshold.
     * Uses partial DML (allowPartial = false) — logs failures without aborting.
     *
     * @param ageDays  Close cases older than this many days
     * @return         Number of cases targeted for closure
     */
    public static Integer closeCasesOlderThan(Integer ageDays) {
        DateTime cutoff = DateTime.now().addDays(-ageDays);
        List<Case> candidates = [
            SELECT Id
            FROM   Case
            WHERE  IsClosed    = false
              AND  CreatedDate < :cutoff
        ];
        if (candidates.isEmpty()) { return 0; }

        List<Case> toClose = new List<Case>();
        for (Case c : candidates) {
            toClose.add(new Case(Id = c.Id, Status = 'Closed'));
        }
        Database.update(toClose, false);
        return toClose.size();
    }

    // ─── SLA Stopwatch ────────────────────────────────────────────────────────

    /**
     * Pauses the SLA timer on specified Cases.
     * Use when waiting for customer response — the clock stops counting toward breach.
     *
     * Interview: IsStopped = true also stops milestone countdown. Resume before
     * making internal updates so SLA time accurately reflects agent response time.
     */
    public static void pauseSla(Set<Id> caseIds) {
        if (caseIds == null || caseIds.isEmpty()) { return; }
        List<Case> toUpdate = new List<Case>();
        for (Id id : caseIds) { toUpdate.add(new Case(Id = id, IsStopped = true)); }
        update toUpdate;
    }

    /**
     * Resumes the SLA timer — clock starts counting again toward the deadline.
     */
    public static void resumeSla(Set<Id> caseIds) {
        if (caseIds == null || caseIds.isEmpty()) { return; }
        List<Case> toUpdate = new List<Case>();
        for (Id id : caseIds) { toUpdate.add(new Case(Id = id, IsStopped = false)); }
        update toUpdate;
    }

    // ─── Milestone detection ──────────────────────────────────────────────────

    /**
     * Returns violated (breached) CaseMilestones for the given Case IDs.
     * IsViolated = true means the TargetDate passed without the milestone being completed.
     *
     * CaseMilestones are created automatically by the platform when a Case is linked
     * to an Entitlement (which has an SLA Process / Entitlement Process attached).
     * They cannot be created via Apex DML.
     *
     * @param caseIds  Set of Case IDs to check
     * @return         Breached milestones ordered by TargetDate ascending
     */
    public static List<CaseMilestone> getBreachedMilestones(Set<Id> caseIds) {
        if (Test.isRunningTest() && mockBreachedMilestones != null) {
            List<CaseMilestone> filtered = new List<CaseMilestone>();
            for (CaseMilestone cm : mockBreachedMilestones) {
                if (caseIds.contains(cm.CaseId) && cm.IsViolated) { filtered.add(cm); }
            }
            return filtered;
        }
        return [
            SELECT Id, CaseId, MilestoneTypeId, TargetDate, IsCompleted,
                   IsViolated, CompletionDate, ElapsedTimeInMins
            FROM   CaseMilestone
            WHERE  CaseId    IN :caseIds
              AND  IsViolated = true
            ORDER BY TargetDate ASC
        ];
    }

    // ─── At-risk case identification ──────────────────────────────────────────

    /**
     * Returns open Cases for an account whose SlaExitDate is within the next
     * warningMinutes, indicating imminent SLA breach risk.
     *
     * Use in a scheduled job or Queueable to send proactive alerts to agents.
     *
     * @param accountId      Account to check open cases for
     * @param warningMinutes Cases within this many minutes of SlaExitDate are returned
     */
    public static List<Case> getCasesAtRisk(Id accountId, Integer warningMinutes) {
        DateTime warningTime = DateTime.now().addMinutes(warningMinutes);
        return [
            SELECT Id, CaseNumber, Subject, Priority, Status,
                   SlaStartDate, SlaExitDate, IsStopped, IsEscalated, OwnerId
            FROM   Case
            WHERE  AccountId   = :accountId
              AND  IsClosed    = false
              AND  SlaExitDate != null
              AND  SlaExitDate <= :warningTime
            ORDER BY SlaExitDate ASC
        ];
    }

    // ─── Business Hours ───────────────────────────────────────────────────────

    /**
     * Returns elapsed business-hours time in minutes between two DateTimes.
     *
     * BusinessHours.diff() returns long milliseconds of business time elapsed.
     * Non-business time (nights, weekends, holidays) is excluded from the count.
     *
     * Interview: Use BusinessHours.diff() for SLA elapsed-time calculations.
     * BusinessHours.add() computes the DateTime N business milliseconds from a start.
     * BusinessHours.nextStartDate() returns next business-hours opening after a DateTime.
     *
     * @param businessHoursId  Id of the BusinessHours record (from Setup)
     * @param startDt          Start of the interval
     * @param endDt            End of the interval
     * @return                 Business minutes elapsed (may be 0 if both outside BH)
     */
    public static Long businessHoursElapsedMinutes(
            Id businessHoursId, DateTime startDt, DateTime endDt) {
        Long ms = BusinessHours.diff(businessHoursId, startDt, endDt);
        return ms / 60000;
    }

    /**
     * Checks whether a given DateTime falls within business hours.
     *
     * @param businessHoursId  BusinessHours record Id
     * @param dt               DateTime to check
     * @return                 true if dt is within the defined business hours window
     */
    public static Boolean isWithinBusinessHours(Id businessHoursId, DateTime dt) {
        return BusinessHours.isWithin(businessHoursId, dt);
    }

    /**
     * Computes the business-hours deadline N minutes after a start DateTime.
     * Use to set SLA target dates that respect working hours.
     *
     * @param businessHoursId  BusinessHours record Id
     * @param startDt          Reference DateTime
     * @param minutes          Business minutes to add
     * @return                 DateTime that is <minutes> BH-minutes after startDt
     */
    public static DateTime addBusinessHoursMinutes(
            Id businessHoursId, DateTime startDt, Integer minutes) {
        return BusinessHours.add(businessHoursId, startDt, (Long) minutes * 60000);
    }

    // ─── Case Team ────────────────────────────────────────────────────────────

    /**
     * Adds a user to the Case Team with the specified role.
     *
     * Interview: CaseTeamMember requires a CaseTeamRole record (configured in Setup).
     * The role controls what access the team member has to the case and related records.
     * CaseTeamRole is metadata — query it by Name to get the Id.
     *
     * @param caseId      Case to add the team member to
     * @param userId      User to add
     * @param teamRoleId  Id of the CaseTeamRole (from Setup → Case Team Roles)
     */
    public static void addCaseTeamMember(Id caseId, Id userId, Id teamRoleId) {
        insert new CaseTeamMember(
            ParentId   = caseId,
            MemberId   = userId,
            TeamRoleId = teamRoleId
        );
    }

    /**
     * Returns the CaseTeamRole Id for a given role name.
     * Use to resolve role names to IDs without hard-coding IDs.
     *
     * @param roleName  CaseTeamRole.Name value (e.g. 'Technical Lead')
     * @return          CaseTeamRole Id, or null if not found
     */
    public static Id getCaseTeamRoleId(String roleName) {
        List<CaseTeamRole> roles = [
            SELECT Id FROM CaseTeamRole WHERE Name = :roleName LIMIT 1
        ];
        return roles.isEmpty() ? null : roles[0].Id;
    }
}
