/**
 * LoanEligibilityQueueable
 * Asynchronous wrapper for LoanEligibilityService.
 * Enqueued by LoanApplicationTriggerHandler when status → SUBMITTED.
 * Uses Queueable (not Future) to allow callouts and chaining.
 */
public class LoanEligibilityQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> loanAppIds;

    public LoanEligibilityQueueable(List<Id> loanAppIds) {
        this.loanAppIds = loanAppIds;
    }

    public void execute(QueueableContext ctx) {
        LoanEligibilityService service = new LoanEligibilityService();
        List<String> errors = new List<String>();

        for (Id appId : loanAppIds) {
            try {
                service.scoreEligibility(appId);
            } catch (Exception e) {
                errors.add('LoanApp ' + appId + ': ' + e.getMessage());
                System.debug(LoggingLevel.ERROR, 'LoanEligibilityQueueable error: ' + e.getMessage());
            }
        }

        if (!errors.isEmpty()) {
            // In production: publish Platform Event or write to Error_Log__c
            System.debug(LoggingLevel.ERROR, 'LoanEligibilityQueueable completed with errors: ' +
                         String.join(errors, ' | '));
        }
    }
}
