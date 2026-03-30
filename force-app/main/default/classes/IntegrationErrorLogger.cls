/**
 * @description Centralised error logging utility. Publishes Integration_Error_Log__e
 *              Platform Events from any Apex context — triggers, services, batch jobs,
 *              Queueable jobs, @future methods. The Platform Event subscriber trigger
 *              writes events to Integration_Error_Log__c for persistent, queryable storage.
 *
 *              Why Platform Events over direct DML to the log object:
 *                - Platform Event publish is fire-and-forget within the publishing transaction.
 *                  The subscriber runs in a separate async transaction, so subscriber DML
 *                  failures cannot roll back the publisher's work.
 *                - PublishAfterCommit ensures errors are only logged when the source
 *                  transaction actually commits — avoids noise from rolled-back transactions.
 *                - The subscriber's separate governor limits mean large batch jobs that log
 *                  thousands of errors don't hit DML limits in their own execute() context.
 *
 *              Declared without sharing — error logs must be written regardless of
 *              the running user's record-level access. Logging is a system concern.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public without sharing class IntegrationErrorLogger {

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Log a single error from a DML or callout failure.
     *
     * @param context    Fully-qualified class.method origin (e.g. 'AccountService.syncCaseOwner')
     * @param message    Error message string
     * @param statusCode Salesforce StatusCode enum value or HTTP status code as string
     * @param recordId   ID of the record that failed (null for non-record errors)
     */
    public static void log(
        String context,
        String message,
        String statusCode,
        String recordId
    ) {
        publish(new List<Integration_Error_Log__e>{
            buildEvent(context, message, statusCode, recordId)
        });
    }

    /**
     * @description Extract and log all failures from a Database.SaveResult list.
     *              Designed for use after Database.update/insert/delete(list, false).
     *
     * @param results  List of SaveResult from a partial-success DML operation
     * @param context  Origin class.method for all errors in this batch
     */
    public static void logSaveResults(
        List<Database.SaveResult> results,
        String context
    ) {
        List<Integration_Error_Log__e> events = new List<Integration_Error_Log__e>();
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) {
                for (Database.Error err : sr.getErrors()) {
                    events.add(buildEvent(
                        context,
                        err.getMessage(),
                        String.valueOf(err.getStatusCode()),
                        sr.getId()
                    ));
                }
            }
        }
        if (!events.isEmpty()) { publish(events); }
    }

    /**
     * @description Log a caught exception (e.g. from a callout or DML outside of SaveResult).
     *
     * @param context  Origin class.method
     * @param ex       The caught exception
     * @param recordId ID of the related record (null if not applicable)
     */
    public static void logException(String context, Exception ex, String recordId) {
        publish(new List<Integration_Error_Log__e>{
            buildEvent(
                context,
                ex.getTypeName() + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString(),
                'EXCEPTION',
                recordId
            )
        });
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    private static Integration_Error_Log__e buildEvent(
        String context,
        String message,
        String statusCode,
        String recordId
    ) {
        return new Integration_Error_Log__e(
            Context__c       = context?.abbreviate(255),
            Error_Message__c  = message,
            Status_Code__c   = statusCode?.abbreviate(50),
            Record_Id__c     = recordId
        );
    }

    /**
     * @description Publishes events via EventBus. Failures here are logged to
     *              System.debug only — we cannot use IntegrationErrorLogger to log
     *              IntegrationErrorLogger failures (infinite recursion).
     */
    private static void publish(List<Integration_Error_Log__e> events) {
        List<Database.SaveResult> publishResults = EventBus.publish(events);
        for (Database.SaveResult sr : publishResults) {
            if (!sr.isSuccess()) {
                for (Database.Error err : sr.getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'IntegrationErrorLogger: EventBus.publish failed. '
                        + err.getStatusCode() + ' | ' + err.getMessage()
                    );
                }
            }
        }
    }
}
