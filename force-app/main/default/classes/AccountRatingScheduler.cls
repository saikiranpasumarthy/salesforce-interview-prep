/**
 * @description Scheduled Apex class that launches AccountRatingBatch nightly.
 *              Closes the loop from Day 2: batch is now fully wired into the
 *              Salesforce scheduler so it runs without manual intervention.
 *
 *              Cron format: Seconds Minutes Hours DayOfMonth Month DayOfWeek Year
 *              DEFAULT_CRON runs at 02:00:00 AM every day.
 *
 *              Deployment note:
 *                Scheduled jobs are not metadata — they must be activated via anonymous
 *                Apex or the Setup UI after deployment. Use scheduleMe() for convenience.
 *                To abort: System.abortJob(jobId) where jobId is from CronTrigger.Id.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class AccountRatingScheduler implements Schedulable {

    public static final String JOB_NAME    = 'Account Rating Batch — Nightly';
    public static final String DEFAULT_CRON = '0 0 2 * * ?';

    /**
     * @description Called by the Salesforce scheduler at the configured cron time.
     *              Launches AccountRatingBatch at the recommended scope size.
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new AccountRatingBatch(), AccountRatingBatch.DEFAULT_SCOPE);
    }

    /**
     * @description Convenience method to schedule this job from anonymous Apex.
     *              Returns the CronTrigger ID for monitoring or future abort.
     *
     *              Usage:
     *                String jobId = AccountRatingScheduler.scheduleMe();
     *                System.debug(jobId); // save this to abort later
     *
     * @return  CronTrigger.Id (String) of the newly scheduled job
     */
    public static String scheduleMe() {
        return System.schedule(JOB_NAME, DEFAULT_CRON, new AccountRatingScheduler());
    }

    /**
     * @description Schedules the job with a custom cron expression.
     *              Use when running in multiple time zones or need non-default cadence.
     *
     * @param cronExpression  Salesforce cron string (6 or 7 fields)
     * @return CronTrigger.Id
     */
    public static String scheduleWith(String cronExpression) {
        return System.schedule(JOB_NAME, cronExpression, new AccountRatingScheduler());
    }
}
