/**
 * @description Entitlement and Milestone management service.
 *
 *              ENTITLEMENT MODEL (interview framework):
 *
 *              Entitlement
 *                └── defines the service level: support hours, SLA process, BH record
 *                └── linked to: Account (AccountId) and/or Contact (via EntitlementContact)
 *                └── fields: Status (Active/Inactive/Expired), StartDate, EndDate,
 *                            RemainingCases, CasesPerEntitlement, BusinessHoursId,
 *                            SlaProcessId (the Entitlement Process)
 *
 *              SlaProcess (Entitlement Process)
 *                └── ordered list of MilestoneType + time criteria
 *                └── platform generates CaseMilestone records on a Case when
 *                    Case.EntitlementId is populated
 *
 *              CaseMilestone
 *                └── instance of a MilestoneType on a specific Case
 *                └── key fields: TargetDate, IsCompleted, CompletionDate,
 *                                IsViolated, ElapsedTimeInMins
 *                └── created/managed by the platform — NOT insertable via Apex DML
 *                └── completable via Apex: update CaseMilestone(Id=id, IsCompleted=true)
 *
 *              MilestoneType
 *                └── template: name, recurrence criteria, time trigger
 *                └── examples: First Response (2 BH), Resolution (8 BH), Follow-up (1 day)
 *
 *              Common interview scenario:
 *                "A case comes in. How does the SLA start?"
 *                1. Case is created (or converted from Lead/Email-to-Case)
 *                2. Assignment rule assigns the case to a queue/user
 *                3. Entitlement is linked to the case (EntitlementId populated)
 *                4. Platform looks up SlaProcess from the Entitlement
 *                5. Platform creates CaseMilestone records per the process definition
 *                6. SLA stopwatch starts (Case.SlaStartDate = now)
 *                7. Agents work the case — milestones completed or violated at TargetDate
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class EntitlementService {

    // TestVisible injection — Entitlement/CaseMilestone require org config to exist
    @TestVisible static List<Entitlement>   mockEntitlements;
    @TestVisible static List<CaseMilestone> mockCaseMilestones;

    // ─── Entitlement lookup ───────────────────────────────────────────────────

    /**
     * Returns active, non-expired Entitlements for an Account.
     * Ordered by EndDate ascending (soonest-to-expire first) so callers can
     * prefer the most urgently-expiring entitlement.
     *
     * @param accountId  Account to look up entitlements for
     * @return           Active entitlements, soonest expiry first
     */
    public static List<Entitlement> getActiveEntitlements(Id accountId) {
        if (Test.isRunningTest() && mockEntitlements != null) {
            List<Entitlement> result = new List<Entitlement>();
            for (Entitlement e : mockEntitlements) {
                if (e.AccountId == accountId && e.Status == 'Active') { result.add(e); }
            }
            return result;
        }
        return [
            SELECT Id, Name, AccountId, Status, StartDate, EndDate,
                   RemainingCases, CasesPerEntitlement, BusinessHoursId, SlaProcessId
            FROM   Entitlement
            WHERE  AccountId = :accountId
              AND  Status    = 'Active'
              AND  (EndDate = null OR EndDate >= TODAY)
            ORDER BY EndDate ASC NULLS LAST
        ];
    }

    /**
     * Returns Entitlements associated with a Contact via the EntitlementContact junction.
     * EntitlementContact is a many-to-many junction — a contact can have multiple
     * entitlements, and an entitlement can cover multiple contacts.
     *
     * @param contactId  Contact to look up entitlements for
     * @return           Active entitlements the contact is covered by
     */
    public static List<Entitlement> getContactEntitlements(Id contactId) {
        List<Id> entitlementIds = new List<Id>();
        for (EntitlementContact ec : [
            SELECT EntitlementId
            FROM   EntitlementContact
            WHERE  ContactId = :contactId
        ]) {
            entitlementIds.add(ec.EntitlementId);
        }
        if (entitlementIds.isEmpty()) { return new List<Entitlement>(); }
        return [
            SELECT Id, Name, AccountId, Status, StartDate, EndDate, BusinessHoursId
            FROM   Entitlement
            WHERE  Id     IN :entitlementIds
              AND  Status  = 'Active'
        ];
    }

    /**
     * Returns the best-fit Entitlement for a Case: active, account-matched,
     * with the soonest expiry (use-it-before-it-expires logic).
     *
     * @param accountId  Account on the incoming Case
     * @return           Best-fit Entitlement, or null if none found
     */
    public static Entitlement getBestEntitlement(Id accountId) {
        List<Entitlement> active = getActiveEntitlements(accountId);
        return active.isEmpty() ? null : active[0];
    }

    // ─── Case → Entitlement linking ───────────────────────────────────────────

    /**
     * Links an Entitlement to a Case.
     *
     * Setting Case.EntitlementId triggers the platform to:
     *   1. Start the SLA stopwatch (Case.SlaStartDate = now)
     *   2. Look up the SlaProcess from the Entitlement
     *   3. Generate CaseMilestone records per the process definition
     *
     * Call this after Case creation — NOT before — so the Case Id is available.
     *
     * @param caseId         Case to link
     * @param entitlementId  Entitlement to apply
     */
    public static void applyEntitlementToCase(Id caseId, Id entitlementId) {
        if (caseId == null || entitlementId == null) { return; }
        update new Case(Id = caseId, EntitlementId = entitlementId);
    }

    /**
     * Auto-assigns the best active entitlement for a Case's account.
     * If no entitlement exists, returns false and leaves the case unchanged.
     *
     * @param caseId  Case record to apply entitlement to
     * @return        true if an entitlement was applied, false if none found
     */
    public static Boolean autoApplyEntitlement(Id caseId) {
        Case c = [SELECT Id, AccountId FROM Case WHERE Id = :caseId];
        if (c.AccountId == null) { return false; }
        Entitlement best = getBestEntitlement(c.AccountId);
        if (best == null) { return false; }
        applyEntitlementToCase(caseId, best.Id);
        return true;
    }

    // ─── Milestone tracking ───────────────────────────────────────────────────

    /**
     * Returns violated (breached) CaseMilestones across all cases in the lookback window.
     * Used by daily monitoring jobs to identify SLA breaches requiring attention.
     *
     * @param lookbackDays  Query milestones with TargetDate in the last N days
     */
    public static List<CaseMilestone> getViolatedMilestones(Integer lookbackDays) {
        if (Test.isRunningTest() && mockCaseMilestones != null) {
            List<CaseMilestone> violated = new List<CaseMilestone>();
            for (CaseMilestone cm : mockCaseMilestones) {
                if (cm.IsViolated) { violated.add(cm); }
            }
            return violated;
        }
        DateTime since = DateTime.now().addDays(-lookbackDays);
        return [
            SELECT Id, CaseId, MilestoneTypeId, TargetDate, IsCompleted,
                   IsViolated, CompletionDate, ElapsedTimeInMins
            FROM   CaseMilestone
            WHERE  IsViolated  = true
              AND  TargetDate >= :since
            ORDER BY TargetDate ASC
            LIMIT  500
        ];
    }

    /**
     * Returns a milestone completion summary for a set of cases.
     * Uses in-memory aggregation to count totals/completed/violated per case.
     *
     * MilestoneStats.pending is derived: total - completed - violated.
     *
     * @param caseIds  Cases to summarise milestone status for
     * @return         Map of CaseId → MilestoneStats
     */
    public static Map<Id, MilestoneStats> getMilestoneStats(Set<Id> caseIds) {
        Map<Id, MilestoneStats> statsMap = new Map<Id, MilestoneStats>();
        if (caseIds == null || caseIds.isEmpty()) { return statsMap; }

        List<CaseMilestone> milestones;
        if (Test.isRunningTest() && mockCaseMilestones != null) {
            milestones = new List<CaseMilestone>();
            for (CaseMilestone cm : mockCaseMilestones) {
                if (caseIds.contains(cm.CaseId)) { milestones.add(cm); }
            }
        } else {
            milestones = [
                SELECT CaseId, IsCompleted, IsViolated
                FROM   CaseMilestone
                WHERE  CaseId IN :caseIds
            ];
        }

        for (CaseMilestone cm : milestones) {
            if (!statsMap.containsKey(cm.CaseId)) {
                statsMap.put(cm.CaseId, new MilestoneStats());
            }
            MilestoneStats s = statsMap.get(cm.CaseId);
            s.total++;
            if      (cm.IsCompleted) { s.completed++; }
            else if (cm.IsViolated)  { s.violated++;  }
        }
        return statsMap;
    }

    /**
     * Marks a CaseMilestone as completed.
     *
     * Interview: CaseMilestones are platform-managed but can be manually completed
     * via Apex DML. Setting IsCompleted = true stops the milestone clock and records
     * CompletionDate = now. Cannot be un-completed.
     *
     * @param milestoneId  CaseMilestone Id to complete
     */
    public static void completeMilestone(Id milestoneId) {
        update new CaseMilestone(Id = milestoneId, IsCompleted = true);
    }

    // ─── Result types ─────────────────────────────────────────────────────────

    public class MilestoneStats {
        public Integer total     = 0;
        public Integer completed = 0;
        public Integer violated  = 0;
        public Integer pending   { get { return Math.max(0, total - completed - violated); } }
        public Boolean allMet    { get { return total > 0 && violated == 0 && pending == 0; } }
    }
}
