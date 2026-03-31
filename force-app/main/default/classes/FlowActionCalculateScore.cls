/**
 * @description FlowActionCalculateScore — Invocable Apex action for Flows.
 *
 *              INVOCABLE APEX RULES (interview key points):
 *              ─────────────────────────────────────────────
 *              1. Only ONE @InvocableMethod allowed per class.
 *              2. Method must be static and public or global.
 *              3. Parameter: List<Request> — platform passes all records in one call (bulk-safe).
 *              4. Return: List<Result> — one Result per Request (index-aligned).
 *              5. Inner classes need @InvocableVariable on each field used by Flow.
 *              6. @InvocableVariable fields must be primitive, sObject, or supported collections.
 *              7. Cannot call from: @future, Batch execute(), Queueable, another @InvocableMethod.
 *              8. Can call from: trigger, controller, anonymous Apex, another non-invocable method.
 *
 *              BULK-SAFE PATTERN:
 *              ───────────────────
 *              Flow bulkification: if 200 Account records trigger this flow,
 *              the platform collects all 200 into one List<Request> and calls
 *              the method ONCE. A non-bulk implementation (querying inside a loop)
 *              would hit SOQL limits immediately.
 *              Solution: collect all accountIds → one SOQL → map results → build List<Result>.
 *
 *              SCORE ALGORITHM:
 *              ────────────────
 *              Base score from AnnualRevenue:
 *                >= 10M  → 60 pts
 *                >= 1M   → 40 pts
 *                >= 500K → 20 pts
 *                < 500K  → 10 pts
 *
 *              Employees bonus:
 *                >= 1000 → +20 pts
 *                >= 100  → +10 pts
 *                >= 10   → +5  pts
 *
 *              Industry bonus:
 *                Technology, Finance → +15 pts
 *                Healthcare, Retail  → +10 pts
 *                Others              → +5  pts
 *
 *              Tier:
 *                >= 80 → Platinum
 *                >= 60 → Gold
 *                >= 40 → Silver
 *                <  40 → Bronze
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
public with sharing class FlowActionCalculateScore {

    // ─── @InvocableMethod ─────────────────────────────────────────────────────

    /**
     * @description Calculates engagement scores for a list of Account Ids.
     *
     *              label     — displayed in Flow Builder's Action picker (required)
     *              description — tooltip in Flow Builder (optional but helpful)
     *              category  — groups the action in Flow Builder's search palette
     *
     * @param  requests  List of Request objects (one per Account)
     * @return           List of Result objects (index-aligned with requests)
     */
    @InvocableMethod(
        label       = 'Calculate Account Score'
        description = 'Computes an engagement score (0-95) and tier (Bronze/Silver/Gold/Platinum) for each Account based on Revenue, Employees, and Industry.'
        category    = 'Account'
    )
    public static List<Result> calculateScores(List<Request> requests) {

        // ── Step 1: collect all Ids into a Set (one SOQL for all requests) ───
        Set<Id> accountIds = new Set<Id>();
        for (Request req : requests) {
            if (req.accountId != null) {
                accountIds.add(req.accountId);
            }
        }

        // ── Step 2: single SOQL ───────────────────────────────────────────────
        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Name, AnnualRevenue, NumberOfEmployees, Industry
            FROM   Account
            WHERE  Id IN :accountIds
            WITH   SECURITY_ENFORCED
        ]);

        // ── Step 3: build results (index-aligned with requests) ───────────────
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Account acc = accountMap.get(req.accountId);
            if (acc == null) {
                results.add(buildEmptyResult('Account not found'));
                continue;
            }
            results.add(computeResult(acc));
        }
        return results;
    }

    // ─── Private computation ──────────────────────────────────────────────────

    @TestVisible
    static Result computeResult(Account acc) {
        Integer score = revenueScore(acc.AnnualRevenue)
                      + employeeScore(acc.NumberOfEmployees)
                      + industryScore(acc.Industry);

        Result res   = new Result();
        res.score    = score;
        res.tier     = scoreTier(score);
        res.label    = acc.Name + ' — ' + res.tier + ' (' + score + ' pts)';
        res.success  = true;
        res.errorMessage = null;
        return res;
    }

    private static Integer revenueScore(Decimal revenue) {
        if (revenue == null) return 0;
        if (revenue >= 10_000_000) return 60;
        if (revenue >= 1_000_000)  return 40;
        if (revenue >= 500_000)    return 20;
        return 10;
    }

    private static Integer employeeScore(Integer employees) {
        if (employees == null) return 0;
        if (employees >= 1000) return 20;
        if (employees >= 100)  return 10;
        if (employees >= 10)   return 5;
        return 0;
    }

    private static Integer industryScore(String industry) {
        if (industry == null) return 0;
        Set<String> high   = new Set<String>{ 'Technology', 'Finance' };
        Set<String> medium = new Set<String>{ 'Healthcare', 'Retail' };
        if (high.contains(industry))   return 15;
        if (medium.contains(industry)) return 10;
        return 5;
    }

    @TestVisible
    static String scoreTier(Integer score) {
        if (score >= 80) return 'Platinum';
        if (score >= 60) return 'Gold';
        if (score >= 40) return 'Silver';
        return 'Bronze';
    }

    private static Result buildEmptyResult(String errorMsg) {
        Result res       = new Result();
        res.score        = 0;
        res.tier         = 'Bronze';
        res.label        = 'Unknown';
        res.success      = false;
        res.errorMessage = errorMsg;
        return res;
    }

    // ─── Inner classes ────────────────────────────────────────────────────────

    /**
     * Request — input contract for the Flow action.
     *
     * @InvocableVariable rules:
     *   label     — shown in Flow Builder's input mapping panel
     *   required  — Flow Builder enforces this field is mapped
     *   description — tooltip in Flow Builder
     */
    public class Request {
        @InvocableVariable(
            label       = 'Account Id'
            description = 'Salesforce Id of the Account to score'
            required    = true
        )
        public Id accountId;
    }

    /**
     * Result — output contract returned to the Flow.
     *
     * Flow reads output variables and can route them to:
     *   - Assignments (store in Flow variables)
     *   - Decision conditions (branch on tier)
     *   - Record Update fields
     */
    public class Result {
        @InvocableVariable(label = 'Score (0-95)'       description = 'Computed numeric engagement score')
        public Integer score;

        @InvocableVariable(label = 'Tier'               description = 'Bronze / Silver / Gold / Platinum')
        public String tier;

        @InvocableVariable(label = 'Score Label'        description = 'Human-readable label: Name — Tier (N pts)')
        public String label;

        @InvocableVariable(label = 'Success'            description = 'True if score was computed successfully')
        public Boolean success;

        @InvocableVariable(label = 'Error Message'      description = 'Populated if success = false')
        public String errorMessage;
    }
}
