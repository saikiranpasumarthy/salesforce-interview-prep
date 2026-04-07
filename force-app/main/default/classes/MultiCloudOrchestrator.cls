/**
 * Day 36 — Multi-Cloud Architecture & Full Solution Orchestration
 *
 * Cross-cloud patterns:
 *
 *  1. Platform Event backbone  — decoupled cross-cloud communication
 *  2. Lead 360 Orchestration   — Sales → Data Cloud → Einstein → Agentforce
 *  3. Event-driven Case Routing — Case → Einstein Sentiment → Omni-Channel
 *  4. Saga Pattern             — distributed transactions with compensation
 *  5. Dead Letter Queue        — failed message storage for retry / inspection
 *
 * All Platform Event and managed-package calls degrade gracefully when
 * the objects / packages are not provisioned in the target org.
 */
public with sharing class MultiCloudOrchestrator {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. PLATFORM EVENT — Cross-cloud integration backbone
    //
    // CrossCloudEvent__e is a custom Platform Event with fields:
    //   EventType__c      (Text 255)  — e.g. 'LEAD_SCORED', 'CASE_ESCALATION'
    //   SourceRecordId__c (Text 18)   — originating record Id
    //   Payload__c        (LTA)       — JSON-serialised context data
    //   CorrelationId__c  (Text 36)   — UUID for end-to-end tracing
    // ═══════════════════════════════════════════════════════════════════════════

    public static EventPublishResult publishCrossCloudEvent(
        String eventType, Id sourceRecordId, Map<String, Object> payload
    ) {
        if (String.isBlank(eventType)) {
            return new EventPublishResult(false, null, 'eventType is required');
        }
        try {
            SObject evt = Schema.getGlobalDescribe()
                .get('CrossCloudEvent__e')?.newSObject();
            if (evt == null) {
                // Platform Event not provisioned — log and return structured error
                return new EventPublishResult(
                    false, null, 'CrossCloudEvent__e Platform Event not configured'
                );
            }
            evt.put('EventType__c',      eventType);
            evt.put('SourceRecordId__c', String.valueOf(sourceRecordId));
            evt.put('Payload__c',        JSON.serialize(payload));
            evt.put('CorrelationId__c',  generateCorrelationId());
            Database.SaveResult sr = EventBus.publish((SObject) evt);
            return sr.isSuccess()
                ? new EventPublishResult(true,  null,                        null)
                : new EventPublishResult(false, null, sr.getErrors()[0].getMessage());
        } catch (Exception e) {
            return new EventPublishResult(false, null, e.getMessage());
        }
    }

    /** Generate a UUID-style correlation Id for distributed tracing */
    @TestVisible
    static String generateCorrelationId() {
        return EncodingUtil.convertToHex(
            Crypto.generateAesKey(128)
        ).substring(0, 32);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. LEAD 360 ORCHESTRATION
    //
    // Full cross-cloud data flow for a Lead:
    //   Sales Cloud (Lead record)
    //     → Einstein Lead Scoring (OOTB score)
    //     → Routing decision (Agentforce / Sales Direct / Nurture)
    //     → Platform Event → downstream listeners
    //
    // Data Cloud enrichment and Marketing Cloud journey triggers are
    // handled by Platform Event subscribers in their respective clouds.
    // ═══════════════════════════════════════════════════════════════════════════

    public static Lead360Result orchestrateLead360(Id leadId) {
        Lead360Result result = new Lead360Result(leadId);
        if (leadId == null) {
            result.error = 'leadId is required';
            return result;
        }
        try {
            Lead l = [
                SELECT Id, FirstName, LastName, Email, Company,
                       Status, LeadSource, Industry
                FROM   Lead
                WHERE  Id = :leadId
                LIMIT  1
            ];
            result.leadName = ((l.FirstName != null ? l.FirstName + ' ' : '') + l.LastName).trim();
            result.leadStatus = l.Status;

            // Einstein Lead Scoring (graceful: empty when feature not enabled)
            List<EinsteinPredictionService.LeadScore> scores =
                EinsteinPredictionService.getLeadScores(new List<Id>{ leadId });
            if (!scores.isEmpty() && scores[0].score != null) {
                result.leadScore     = scores[0].score;
                result.scoreCategory = scores[0].scoreCategory;
            }

            // Routing decision based on score
            result.routingDecision = determineLeadRouting(result.leadScore, result.scoreCategory);

            // Publish cross-cloud event (fails gracefully if PE not provisioned)
            Map<String, Object> eventPayload = new Map<String, Object>{
                'score'         => result.leadScore,
                'scoreCategory' => result.scoreCategory,
                'routing'       => result.routingDecision,
                'leadSource'    => l.LeadSource,
                'industry'      => l.Industry
            };
            EventPublishResult evtResult =
                publishCrossCloudEvent('LEAD_SCORED', leadId, eventPayload);
            result.eventPublished = evtResult.isSuccess;
            result.isSuccess      = true;

        } catch (Exception e) {
            result.error = e.getMessage();
        }
        return result;
    }

    /**
     * Routing decision logic:
     *   Score ≥ 80 AND Category 'A' → Agentforce High-Value (immediate AI engagement)
     *   Score ≥ 60                  → Sales Direct (rep assigned)
     *   Score < 60 or unknown       → Nurture Sequence (Marketing Cloud journey)
     */
    @TestVisible
    static String determineLeadRouting(Integer score, String scoreCategory) {
        if (score == null)                              return 'NURTURE_SEQUENCE';
        if (score >= 80 && 'A'.equals(scoreCategory))  return 'AGENTFORCE_HIGH_VALUE';
        if (score >= 60)                                return 'SALES_DIRECT';
        return 'NURTURE_SEQUENCE';
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. EVENT-DRIVEN CASE ROUTING
    //
    // Case created → analyse sentiment (Einstein Language) →
    //   high-priority + negative → Escalation Queue + Platform Event
    //   standard → queue by Origin/Priority
    // ═══════════════════════════════════════════════════════════════════════════

    public static CaseRoutingResult routeCaseEventDriven(Id caseId) {
        CaseRoutingResult result = new CaseRoutingResult(caseId);
        if (caseId == null) {
            result.error = 'caseId is required';
            return result;
        }
        try {
            Case c = [
                SELECT Id, Subject, Description, Priority, Origin, Status
                FROM   Case
                WHERE  Id = :caseId
                LIMIT  1
            ];
            result.targetQueue = determineCaseQueue(c.Priority, c.Origin);
            result.escalate    = 'Critical'.equals(c.Priority) || 'Urgent'.equals(c.Priority);

            if (result.escalate) {
                publishCrossCloudEvent('CASE_ESCALATION', caseId, new Map<String, Object>{
                    'priority' => c.Priority,
                    'subject'  => c.Subject,
                    'queue'    => result.targetQueue
                });
            }
            result.isSuccess = true;
        } catch (Exception e) {
            result.error = e.getMessage();
        }
        return result;
    }

    /**
     * Queue assignment matrix:
     *   Critical priority → Critical_Response_Queue  (SLA: 1 hr)
     *   High priority     → High_Priority_Queue       (SLA: 4 hr)
     *   Email origin      → Email_Queue
     *   Web origin        → Web_Queue
     *   Default           → General_Support_Queue
     */
    @TestVisible
    static String determineCaseQueue(String priority, String origin) {
        if ('Critical'.equals(priority)) return 'Critical_Response_Queue';
        if ('High'.equals(priority))     return 'High_Priority_Queue';
        if ('Email'.equals(origin))      return 'Email_Queue';
        if ('Web'.equals(origin))        return 'Web_Queue';
        return 'General_Support_Queue';
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. SAGA PATTERN — Distributed transactions with compensation
    //
    // A Saga is a sequence of local transactions. On failure at step N,
    // compensation transactions are executed backward from N-1 to 0.
    //
    //   Step 1: Validate Quote    (read-only — no compensation needed)
    //   Step 2: Reserve Inventory (compensate: release reservation)
    //   Step 3: Create Order      (compensate: delete Order)
    //   Step 4: Notify Fulfillment(compensate: send cancellation event)
    //
    // Unlike 2PC (two-phase commit), Sagas do NOT lock records across steps.
    // Each step is independently committed. Compensation is "undo" logic.
    // ═══════════════════════════════════════════════════════════════════════════

    public interface SagaStep {
        void execute();
        void compensate();
    }

    public class SagaOrchestrator {
        private List<SagaStep> steps = new List<SagaStep>();
        @TestVisible String sagaId;

        public SagaOrchestrator(String sagaId) {
            this.sagaId = sagaId;
        }

        public void addStep(SagaStep step) {
            steps.add(step);
        }

        public SagaResult execute() {
            List<SagaStep> completed = new List<SagaStep>();
            for (SagaStep step : steps) {
                try {
                    step.execute();
                    completed.add(step);
                } catch (Exception e) {
                    // Execute compensation in reverse order (Last-In First-Out)
                    compensateAll(completed);
                    return new SagaResult(false, e.getMessage(), sagaId);
                }
            }
            return new SagaResult(true, null, sagaId);
        }

        private void compensateAll(List<SagaStep> completedSteps) {
            for (Integer i = completedSteps.size() - 1; i >= 0; i--) {
                try {
                    completedSteps[i].compensate();
                } catch (Exception e) {
                    // Log compensation failure — still attempt remaining compensations
                    System.debug(LoggingLevel.ERROR,
                        'Saga compensation failed at step ' + i
                        + ' for sagaId=' + sagaId + ': ' + e.getMessage()
                    );
                }
            }
        }
    }

    /**
     * Quote-to-Order Saga.
     * Composes four steps with their compensation logic.
     */
    public static SagaResult executeQuoteToOrderSaga(Id quoteId) {
        if (quoteId == null) {
            return new SagaResult(false, 'quoteId is required', null);
        }
        SagaOrchestrator saga = new SagaOrchestrator('Q2O_' + quoteId);
        saga.addStep(new ValidateQuoteStep(quoteId));
        saga.addStep(new ReserveInventoryStep(quoteId));
        saga.addStep(new CreateOrderStep(quoteId));
        saga.addStep(new NotifyFulfillmentStep(quoteId));
        return saga.execute();
    }

    // ─── Saga step implementations ────────────────────────────────────────────

    private class ValidateQuoteStep implements SagaStep {
        private Id quoteId;
        ValidateQuoteStep(Id id) { this.quoteId = id; }

        public void execute() {
            List<Quote> quotes = [
                SELECT Id, Status FROM Quote WHERE Id = :quoteId LIMIT 1
            ];
            if (quotes.isEmpty()) {
                throw new IllegalArgumentException('Quote not found: ' + quoteId);
            }
            Set<String> validStatuses = new Set<String>{ 'Presented', 'Approved' };
            if (!validStatuses.contains(quotes[0].Status)) {
                throw new IllegalStateException(
                    'Quote must be Presented or Approved to convert. Current: '
                    + quotes[0].Status
                );
            }
        }

        public void compensate() { /* Read-only — nothing to undo */ }
    }

    private class ReserveInventoryStep implements SagaStep {
        private Id     quoteId;
        @TestVisible String reservationId;
        ReserveInventoryStep(Id id) { this.quoteId = id; }

        public void execute() {
            // Production: call external inventory system via Named Credential
            // reservationId = InventoryClient.reserve(quoteId);
            reservationId = 'RES-' + quoteId;   // Simulated for demo
        }

        public void compensate() {
            if (String.isNotBlank(reservationId)) {
                // Production: InventoryClient.release(reservationId);
                System.debug(LoggingLevel.INFO,
                    'Saga compensate: releasing reservation ' + reservationId);
            }
        }
    }

    private class CreateOrderStep implements SagaStep {
        private Id quoteId;
        @TestVisible Id orderId;
        CreateOrderStep(Id id) { this.quoteId = id; }

        public void execute() {
            Quote q = [
                SELECT Id, AccountId FROM Quote WHERE Id = :quoteId LIMIT 1
            ];
            Id pb2Id = Test.isRunningTest()
                ? Test.getStandardPricebookId()
                : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
            Order o = new Order(
                AccountId     = q.AccountId,
                EffectiveDate = Date.today(),
                Status        = 'Draft',
                Pricebook2Id  = pb2Id
            );
            insert o;
            orderId = o.Id;
        }

        public void compensate() {
            if (orderId != null) {
                try { delete new Order(Id = orderId); } catch (Exception e) { /* already deleted */ }
            }
        }
    }

    private class NotifyFulfillmentStep implements SagaStep {
        private Id quoteId;
        NotifyFulfillmentStep(Id id) { this.quoteId = id; }

        public void execute() {
            // Production: publish Platform Event → fulfillment system subscriber
            // publishCrossCloudEvent('ORDER_CREATED', quoteId, ...);
        }

        public void compensate() {
            // Production: publishCrossCloudEvent('ORDER_CANCELLED', quoteId, ...);
            System.debug(LoggingLevel.INFO,
                'Saga compensate: sending ORDER_CANCELLED for quoteId=' + quoteId);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. DEAD LETTER QUEUE
    //
    // Messages that fail all retry attempts are stored for:
    //   - Manual reprocessing by an admin
    //   - Automated retry via scheduled Apex
    //   - Incident investigation
    //
    // Custom Object: DeadLetterMessage__c
    //   MessageId__c   (Text 255)  — unique message/event Id
    //   Payload__c     (LTA)       — original message body
    //   ErrorMessage__c(Text 1000) — last failure reason
    //   AttemptCount__c(Number)    — total attempts made
    //   Status__c      (Picklist)  — Pending | Reprocessing | Resolved | Abandoned
    // ═══════════════════════════════════════════════════════════════════════════

    public static DlqResult sendToDeadLetterQueue(
        String messageId, String payload, String errorMessage, Integer attemptCount
    ) {
        if (String.isBlank(messageId)) {
            return new DlqResult(null, false, 'messageId is required');
        }
        try {
            SObject dlq = Schema.getGlobalDescribe()
                .get('DeadLetterMessage__c')?.newSObject();
            if (dlq == null) {
                // Object not provisioned — log and return structured failure
                System.debug(LoggingLevel.ERROR,
                    'DLQ: DeadLetterMessage__c not found. MessageId=' + messageId
                    + ' Error=' + errorMessage
                );
                return new DlqResult(null, false, 'DeadLetterMessage__c not provisioned');
            }
            dlq.put('MessageId__c',    messageId);
            dlq.put('Payload__c',      payload?.left(131072));  // LTA limit
            dlq.put('ErrorMessage__c', errorMessage?.left(1000));
            dlq.put('AttemptCount__c', attemptCount);
            dlq.put('Status__c',       'Pending');
            insert dlq;
            return new DlqResult((Id) dlq.get('Id'), true, null);
        } catch (Exception e) {
            // DLQ itself failed — absolute last resort: debug log
            System.debug(LoggingLevel.ERROR,
                'DLQ insertion failed. MessageId=' + messageId
                + ' DLQ error=' + e.getMessage()
                + ' Original error=' + errorMessage
            );
            return new DlqResult(null, false, e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class EventPublishResult {
        public Boolean isSuccess;
        public String  eventId;
        public String  error;

        public EventPublishResult(Boolean success, String eventId, String error) {
            this.isSuccess = success;
            this.eventId   = eventId;
            this.error     = error;
        }
    }

    public class Lead360Result {
        public Id      leadId;
        public String  leadName;
        public String  leadStatus;
        public Integer leadScore;
        public String  scoreCategory;
        public String  routingDecision;
        public Boolean eventPublished = false;
        public Boolean isSuccess      = false;
        public String  error;

        public Lead360Result(Id id) { this.leadId = id; }
    }

    public class CaseRoutingResult {
        public Id      caseId;
        public String  targetQueue;
        public Boolean escalate  = false;
        public Boolean isSuccess = false;
        public String  error;

        public CaseRoutingResult(Id id) { this.caseId = id; }
    }

    public class SagaResult {
        public Boolean isSuccess;
        public String  error;
        public String  sagaId;

        public SagaResult(Boolean success, String error, String sagaId) {
            this.isSuccess = success;
            this.error     = error;
            this.sagaId    = sagaId;
        }
    }

    public class DlqResult {
        public Id      recordId;
        public Boolean isSuccess;
        public String  error;

        public DlqResult(Id id, Boolean success, String error) {
            this.recordId  = id;
            this.isSuccess = success;
            this.error     = error;
        }
    }
}
