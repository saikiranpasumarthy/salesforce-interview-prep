/**
 * LoanApplicationTriggerHandler
 * Handles all trigger events on LoanApplication__c.
 *
 * Before Insert : set default Status (DRAFT), generate ExternalId if blank
 * Before Update : enforce status state machine (no backward transitions)
 * After Insert  : if Status = SUBMITTED, kick off async eligibility evaluation
 * After Update  : if Status changed to SUBMITTED, kick off async eligibility evaluation
 */
public class LoanApplicationTriggerHandler extends TriggerHandler {

    // Valid forward transitions: key = current status, value = allowed next statuses
    @TestVisible
    static final Map<String, Set<String>> VALID_TRANSITIONS = new Map<String, Set<String>>{
        'DRAFT'      => new Set<String>{'SUBMITTED', 'DRAFT'},
        'SUBMITTED'  => new Set<String>{'IN_REVIEW', 'DECLINED', 'SUBMITTED'},
        'IN_REVIEW'  => new Set<String>{'APPROVED', 'DECLINED', 'IN_REVIEW'},
        'APPROVED'   => new Set<String>{'FUNDED', 'APPROVED'},
        'DECLINED'   => new Set<String>{'DECLINED'},
        'FUNDED'     => new Set<String>{'FUNDED'}
    };

    // ─────────────────────────────────────────────────────────────────────────
    // BEFORE INSERT
    // ─────────────────────────────────────────────────────────────────────────
    protected override void beforeInsert(List<SObject> newRecords) {
        List<LoanApplication__c> newApps = (List<LoanApplication__c>) newRecords;

        for (LoanApplication__c app : newApps) {
            // Default status
            if (String.isBlank(app.Status__c)) {
                app.Status__c = 'DRAFT';
            }
            // Generate External ID for idempotent upsert from OmniScript
            if (String.isBlank(app.ExternalId__c)) {
                app.ExternalId__c = generateExternalId(app);
            }
            // Default EligibilityDecision to PENDING
            if (String.isBlank(app.EligibilityDecision__c)) {
                app.EligibilityDecision__c = 'PENDING';
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BEFORE UPDATE
    // ─────────────────────────────────────────────────────────────────────────
    protected override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
        List<LoanApplication__c> newApps = (List<LoanApplication__c>) newRecords;
        Map<Id, LoanApplication__c> oldApps = (Map<Id, LoanApplication__c>) oldMap;

        for (LoanApplication__c app : newApps) {
            LoanApplication__c oldApp = oldApps.get(app.Id);
            String oldStatus = oldApp.Status__c;
            String newStatus = app.Status__c;

            if (oldStatus == newStatus) continue;

            Set<String> allowed = VALID_TRANSITIONS.get(oldStatus);
            if (allowed == null || !allowed.contains(newStatus)) {
                app.Status__c.addError(
                    'Invalid status transition from ' + oldStatus + ' to ' + newStatus +
                    '. Allowed: ' + (allowed != null ? String.join(new List<String>(allowed), ', ') : 'none')
                );
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER INSERT
    // ─────────────────────────────────────────────────────────────────────────
    protected override void afterInsert(List<SObject> newRecords) {
        List<LoanApplication__c> newApps = (List<LoanApplication__c>) newRecords;
        List<Id> toEvaluate = new List<Id>();

        for (LoanApplication__c app : newApps) {
            if (app.Status__c == 'SUBMITTED') {
                toEvaluate.add(app.Id);
            }
        }

        if (!toEvaluate.isEmpty()) {
            enqueueEligibilityEvaluation(toEvaluate);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER UPDATE
    // ─────────────────────────────────────────────────────────────────────────
    protected override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
        List<LoanApplication__c> newApps = (List<LoanApplication__c>) newRecords;
        Map<Id, LoanApplication__c> oldApps = (Map<Id, LoanApplication__c>) oldMap;
        List<Id> toEvaluate = new List<Id>();

        for (LoanApplication__c app : newApps) {
            LoanApplication__c oldApp = oldApps.get(app.Id);
            // Trigger eligibility only when status transitions to SUBMITTED
            if (app.Status__c == 'SUBMITTED' && oldApp.Status__c != 'SUBMITTED') {
                toEvaluate.add(app.Id);
            }
        }

        if (!toEvaluate.isEmpty()) {
            enqueueEligibilityEvaluation(toEvaluate);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────
    private void enqueueEligibilityEvaluation(List<Id> appIds) {
        // Enqueue a Queueable to avoid callout limitations in trigger context
        if (!System.isFuture() && !System.isBatch()) {
            System.enqueueJob(new LoanEligibilityQueueable(appIds));
        }
    }

    private String generateExternalId(LoanApplication__c app) {
        // Deterministic ID based on applicant + loan type + timestamp for dedup
        String seed = (app.Applicant__c != null ? app.Applicant__c : '') +
                      (app.LoanType__c  != null ? app.LoanType__c  : '') +
                      String.valueOf(Datetime.now().getTime());
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(seed));
        return EncodingUtil.convertToHex(hash).substring(0, 32);
    }
}
