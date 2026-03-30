/**
 * @description Scheduled Apex class that launches OpportunityRollupBatch nightly.
 *              Runs at 03:00 AM — one hour after AccountRatingBatch finishes —
 *              to prevent both batch jobs competing for the same database resources.
 *
 *              Scheduling sequence (nightly):
 *                02:00 AM  →  AccountRatingBatch       (via AccountRatingScheduler)
 *                03:00 AM  →  OpportunityRollupBatch   (via this class)
 *
 *              Gap reasoning: AccountRatingBatch at 200 scope on 1M accounts = ~5,000
 *              chunks. At ~1 chunk/second, runtime ≈ 83 minutes. A 1-hour gap is a
 *              conservative buffer; monitor AsyncApexJob.CompletedDate and adjust.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class OpportunityRollupScheduler implements Schedulable {

    public static final String JOB_NAME     = 'Opportunity Revenue Rollup — Nightly';
    public static final String DEFAULT_CRON  = '0 0 3 * * ?';

    public void execute(SchedulableContext ctx) {
        Database.executeBatch(
            new OpportunityRollupBatch(),
            OpportunityRollupBatch.DEFAULT_SCOPE
        );
    }

    public static String scheduleMe() {
        return System.schedule(JOB_NAME, DEFAULT_CRON, new OpportunityRollupScheduler());
    }

    public static String scheduleWith(String cronExpression) {
        return System.schedule(JOB_NAME, cronExpression, new OpportunityRollupScheduler());
    }
}
