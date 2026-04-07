/**
 * @description Data Cloud Real-Time CDP — personalisation at point of interaction,
 *              Data Actions (webhook from Data Cloud to CRM), CRM ↔ Data Cloud
 *              bi-directional integration patterns, and streaming insight patterns.
 *
 *              REAL-TIME CDP PATTERNS (interview framework):
 *
 *              Pattern 1: CRM → Data Cloud (event streaming)
 *                CRM trigger/Flow → @InvocableMethod → Streaming Ingestion API
 *                Use: push CRM interactions to Data Cloud in near-real-time
 *
 *              Pattern 2: Data Cloud → CRM (personalisation)
 *                Apex reads unified profile + insights via Query API
 *                → personalises Salesforce UI, email, offer
 *                Use: next-best-action, offer selection, priority routing
 *
 *              Pattern 3: Data Cloud → CRM (Data Actions)
 *                Data Cloud detects segment entry/exit
 *                → fires webhook to Connected Org
 *                → Salesforce receives as Platform Event
 *                → Apex trigger processes and updates CRM record
 *
 *              Pattern 4: Batch Apex reads Data Cloud, updates CRM
 *                Scheduled Batch reads high-LTV profiles from Query API
 *                → creates/updates Tasks, Opportunities, Campaigns in CRM
 *
 *              STREAMING INSIGHTS:
 *                Standard Calculated Insights: batch-computed (hourly/daily)
 *                Streaming Insights: near-real-time, updated as events arrive
 *                  - Requires Streaming Ingestion + Streaming Insight licence
 *                  - Latency: seconds to minutes
 *                  - Use for: engagement score, cart abandonment, churn risk
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class DataCloudPersonalisationService {

    @TestVisible static String DATA_CLOUD_NC = 'DataCloud_Org';
    @TestVisible static HttpCalloutMock calloutMock;

    // ─── Real-time personalisation ────────────────────────────────────────────

    /**
     * Returns a personalised offer for a Contact based on their Data Cloud
     * unified profile, LTV tier, and segment memberships.
     *
     * Interview: This is the core Real-Time CDP use case.
     * Steps:
     *   1. Resolve CRM Contact → Data Cloud UnifiedIndividualId (Party Identification)
     *   2. Retrieve Calculated Insight (LTV, Engagement Score)
     *   3. Check segment memberships (High Value, At Risk, New Customer)
     *   4. Apply offer decision logic based on profile data
     *   5. Return personalised offer for display in Salesforce UI/Flow/API
     *
     * @param contactId  Salesforce Contact Id
     * @return           PersonalisedOffer with recommended offer + rationale
     */
    @InvocableMethod(
        label       = 'Get Personalised Offer'
        description = 'Returns a personalised offer for a customer based on their '
                    + 'Data Cloud unified profile, lifetime value, and segment membership. '
                    + 'Use for next-best-action, upsell recommendations, or renewal offers.'
        category    = 'Data Cloud'
    )
    public static List<PersonalisedOfferOutput> getPersonalisedOffer(
            List<PersonalisedOfferInput> inputs) {

        List<PersonalisedOfferOutput> results = new List<PersonalisedOfferOutput>();

        for (PersonalisedOfferInput inp : inputs) {
            PersonalisedOfferOutput out = new PersonalisedOfferOutput();
            try {
                // Step 1: Get unified profile Id via Party Identification
                String unifiedId = resolveUnifiedId(inp.contactId);
                if (String.isBlank(unifiedId)) {
                    out.offerCode    = 'DEFAULT';
                    out.offerTitle   = 'Standard Offer';
                    out.rationale    = 'No unified profile found for this contact.';
                    out.isSuccess    = true;
                    results.add(out);
                    continue;
                }

                // Step 2: Retrieve LTV and engagement score
                Map<String, Object> ltv = getLtvInsight(unifiedId);
                Decimal lifetimeValue   = ltv != null && ltv.get('TotalLifetimeValue__c') != null
                    ? (Decimal) ltv.get('TotalLifetimeValue__c') : 0;
                Decimal engagementScore = ltv != null && ltv.get('EngagementScore__c') != null
                    ? (Decimal) ltv.get('EngagementScore__c') : 0;

                // Step 3: Apply offer decision logic
                OfferDecision decision = selectOffer(
                    lifetimeValue, engagementScore, inp.offerContext
                );

                out.unifiedIndividualId = unifiedId;
                out.lifetimeValue       = lifetimeValue;
                out.engagementScore     = engagementScore;
                out.offerCode           = decision.offerCode;
                out.offerTitle          = decision.offerTitle;
                out.discountPercent     = decision.discountPercent;
                out.rationale           = decision.rationale;
                out.isSuccess           = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Personalisation failed: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Data Action receiver (CRM-side webhook handler) ──────────────────────

    /**
     * Processes an inbound Data Action webhook from Data Cloud.
     *
     * Interview: Data Actions are webhooks fired by Data Cloud when a profile
     * enters or exits a segment. The webhook payload is received by a Salesforce
     * Connected App endpoint (e.g. a REST Resource or Platform Event).
     *
     * Data Action payload structure:
     * {
     *   "actionType": "SegmentEntry" | "SegmentExit",
     *   "segmentId":  "seg-high-value-001",
     *   "segmentName": "High Value Customers",
     *   "unifiedIndividualId": "uid-abc-123",
     *   "eventTime": "2024-06-15T10:30:00Z",
     *   "attributes": {
     *     "ContactId__c": "003xx...",
     *     "TotalLifetimeValue__c": 52000
     *   }
     * }
     *
     * CRM-side actions on SegmentEntry:
     *   - Update Contact/Account field to record segment membership
     *   - Create follow-up Task for sales rep
     *   - Publish Platform Event for downstream processing
     *
     * @param payload  Parsed Data Action webhook body
     * @return         Processing result
     */
    public static DataActionResult processDataAction(DataActionPayload payload) {
        DataActionResult result = new DataActionResult();
        try {
            if (payload == null || String.isBlank(payload.actionType)) {
                result.isSuccess    = false;
                result.errorMessage = 'Invalid Data Action payload.';
                return result;
            }

            Id contactId = resolveContactIdFromAttributes(payload.attributes);

            if (payload.actionType == 'SegmentEntry') {
                result = handleSegmentEntry(contactId, payload);
            } else if (payload.actionType == 'SegmentExit') {
                result = handleSegmentExit(contactId, payload);
            } else {
                result.isSuccess    = false;
                result.errorMessage = 'Unknown actionType: ' + payload.actionType;
            }

        } catch (Exception e) {
            result.isSuccess    = false;
            result.errorMessage = 'Data Action processing failed: ' + e.getMessage();
        }
        return result;
    }

    // ─── CRM ↔ Data Cloud bi-directional sync ─────────────────────────────────

    /**
     * Pushes a CRM interaction to Data Cloud immediately after it occurs.
     * Called from a trigger or Flow when a key CRM event happens.
     *
     * Interview: This is the CRM → Data Cloud pattern.
     * CRM Connector handles bulk object sync, but for custom events
     * (e.g. "customer called support", "proposal viewed") use Streaming Ingestion.
     *
     * Pattern: Apex trigger (after insert/update) → enqueue Queueable
     *   → Queueable calls DataCloudIngestionService.streamInteractionEvents()
     *
     * Note: Cannot call callouts directly from trigger — must use Queueable.
     *
     * @param caseId  Case that triggered the interaction
     * @return        Ingestion result
     */
    @InvocableMethod(
        label       = 'Stream Case Interaction to Data Cloud'
        description = 'Streams a Case interaction event to Data Cloud for profile enrichment. '
                    + 'Updates the customer engagement profile in near-real-time. '
                    + 'Use when a Case is created or a key milestone is reached.'
        category    = 'Data Cloud'
        callout     = true
    )
    public static List<StreamCaseOutput> streamCaseInteraction(
            List<StreamCaseInput> inputs) {

        List<StreamCaseOutput> results = new List<StreamCaseOutput>();

        for (StreamCaseInput inp : inputs) {
            StreamCaseOutput out = new StreamCaseOutput();
            try {
                Case c = [
                    SELECT Id, CaseNumber, Subject, Status, Priority,
                           AccountId, ContactId, CreatedDate, OwnerId
                    FROM   Case
                    WHERE  Id = :inp.caseId
                    WITH   SECURITY_ENFORCED
                ];

                // Resolve Data Cloud Individual Id from Contact
                String individualId = String.isNotBlank(inp.overrideIndividualId)
                    ? inp.overrideIndividualId
                    : String.valueOf(c.ContactId); // fallback: CRM Id as individualId

                List<DataCloudIngestionService.InteractionEvent> events =
                    new List<DataCloudIngestionService.InteractionEvent>{
                        new DataCloudIngestionService.InteractionEvent(
                            'CASE-' + c.CaseNumber,
                            individualId,
                            'CaseCreated',
                            c.CreatedDate,
                            'Service',
                            inp.engagementScore != null ? inp.engagementScore : 0.3
                        )
                    };

                DataCloudIngestionService.IngestionResult ingResult =
                    DataCloudIngestionService.streamInteractionEvents(
                        events, inp.sourceApiName != null ? inp.sourceApiName : 'CRM_Events'
                    );

                out.isSuccess     = ingResult.isSuccess;
                out.errorMessage  = ingResult.errorMessage;
                out.individualId  = individualId;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Stream failed: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    /**
     * Batch Apex pattern: reads high-LTV profiles from Data Cloud and
     * creates follow-up Tasks in CRM for the assigned sales rep.
     *
     * Interview: This is the Data Cloud → CRM batch pattern.
     * Use Batch Apex to avoid callout limits on large result sets.
     * Each batch execute() calls Query API with pagination (nextBatchId).
     *
     * @param minimumLtv   Only process profiles above this LTV
     * @param taskDueInDays Follow-up task due date offset
     * @return             Number of tasks created
     */
    public static Integer syncHighLtvProfilesToCrm(Decimal minimumLtv, Integer taskDueInDays) {
        Integer tasksCreated = 0;
        Decimal minLtv   = minimumLtv  != null ? minimumLtv  : 10000;
        Integer dueDays  = taskDueInDays != null ? taskDueInDays : 7;

        String sql =
            'SELECT pid.PartyIdentificationNumber__c, lv.TotalLifetimeValue__c '
            + 'FROM   LifetimeValue__dlm lv '
            + 'JOIN   PartyIdentification__dlm pid '
            + '         ON lv.UnifiedIndividualId__c = pid.UnifiedIndividualId__c '
            + 'WHERE  lv.TotalLifetimeValue__c >= ' + minLtv + ' '
            + '  AND  pid.IdentityType__c = \'ContactId\' '
            + 'ORDER BY lv.TotalLifetimeValue__c DESC '
            + 'LIMIT  200';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + DATA_CLOUD_NC + '/api/v1/query');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{ 'sql' => sql }));
        req.setTimeout(30000);

        try {
            Http http = new Http();
            HttpResponse resp = (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req) : http.send(req);

            if (resp.getStatusCode() != 200) { return 0; }

            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> rows = (List<Object>) parsed.get('data');

            List<Task> tasks = new List<Task>();
            for (Object row : rows) {
                Map<String, Object> r = (Map<String, Object>) row;
                String contactIdStr = (String) r.get('PartyIdentificationNumber__c');
                Decimal ltv         = (Decimal) r.get('TotalLifetimeValue__c');

                if (String.isBlank(contactIdStr)) { continue; }

                try {
                    Id contactId = Id.valueOf(contactIdStr);
                    tasks.add(new Task(
                        WhatId       = null,
                        WhoId        = contactId,
                        Subject      = 'High LTV Customer Follow-up (LTV: $' + ltv.format() + ')',
                        Priority     = 'High',
                        Status       = 'Not Started',
                        ActivityDate = Date.today().addDays(dueDays),
                        Description  = 'Identified by Data Cloud as high lifetime value customer.'
                    ));
                } catch (Exception e) { /* invalid Id format */ }
            }

            if (!tasks.isEmpty()) {
                insert tasks;
                tasksCreated = tasks.size();
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'syncHighLtvProfilesToCrm: ' + e.getMessage());
        }
        return tasksCreated;
    }

    // ─── Streaming insight pattern ────────────────────────────────────────────

    /**
     * Retrieves a streaming insight value for a unified profile.
     *
     * Interview: Streaming Insights differ from batch Calculated Insights:
     *   Batch CI   — computed on schedule (hourly/daily), higher latency
     *   Streaming  — updated as events arrive (seconds), near-real-time
     *
     * Both are stored as DMOs and queried the same way via Query API.
     * The difference is in how they are configured (Data Cloud Calculated Insights
     * with "Streaming" compute mode vs standard batch mode).
     *
     * Common streaming insights:
     *   - 30-minute session score (cart abandonment signal)
     *   - Real-time engagement score (last 24 hours)
     *   - Purchase propensity score (ML model, updated on each event)
     *
     * @param unifiedIndividualId  Profile to retrieve streaming insight for
     * @param insightDmoName       DMO name for the streaming insight
     * @param scoreField           Field name containing the insight score
     * @return                     Score value; null if not found
     */
    public static Decimal getStreamingInsightScore(
            String unifiedIndividualId, String insightDmoName, String scoreField) {

        if (String.isBlank(unifiedIndividualId)) { return null; }

        String dmo = insightDmoName.endsWith('__dlm')
            ? insightDmoName : insightDmoName + '__dlm';
        String field = String.isNotBlank(scoreField) ? scoreField : 'Score__c';

        String sql =
            'SELECT ' + field + ' '
            + 'FROM   ' + dmo + ' '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + 'LIMIT  1';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + DATA_CLOUD_NC + '/api/v1/query');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{ 'sql' => sql }));
        req.setTimeout(10000); // shorter timeout for real-time use cases

        try {
            Http http = new Http();
            HttpResponse resp = (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req) : http.send(req);

            if (resp.getStatusCode() != 200) { return null; }
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> rows = (List<Object>) parsed.get('data');
            if (rows.isEmpty()) { return null; }
            Object val = ((Map<String, Object>) rows[0]).get(field);
            return val != null ? Decimal.valueOf(String.valueOf(val)) : null;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Streaming insight retrieval failed: ' + e.getMessage());
            return null;
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /**
     * Resolves CRM Contact Id → Data Cloud UnifiedIndividualId via Party Identification.
     */
    @TestVisible
    static String resolveUnifiedId(Id contactId) {
        if (contactId == null) { return null; }

        String sql =
            'SELECT UnifiedIndividualId__c '
            + 'FROM   PartyIdentification__dlm '
            + 'WHERE  IdentityType__c = \'ContactId\' '
            + '  AND  PartyIdentificationNumber__c = \''
            + String.escapeSingleQuotes(String.valueOf(contactId)) + '\' '
            + 'LIMIT  1';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + DATA_CLOUD_NC + '/api/v1/query');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{ 'sql' => sql }));
        req.setTimeout(15000);

        try {
            Http http = new Http();
            HttpResponse resp = (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req) : http.send(req);

            if (resp.getStatusCode() != 200) { return null; }
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> rows = (List<Object>) parsed.get('data');
            if (rows.isEmpty()) { return null; }
            return (String) ((Map<String, Object>) rows[0]).get('UnifiedIndividualId__c');
        } catch (Exception e) { return null; }
    }

    /**
     * Retrieves LTV and engagement score for a unified profile.
     */
    @TestVisible
    static Map<String, Object> getLtvInsight(String unifiedIndividualId) {
        String sql =
            'SELECT TotalLifetimeValue__c, EngagementScore__c '
            + 'FROM   LifetimeValue__dlm '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + 'LIMIT  1';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + DATA_CLOUD_NC + '/api/v1/query');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{ 'sql' => sql }));
        req.setTimeout(15000);

        try {
            Http http = new Http();
            HttpResponse resp = (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req) : http.send(req);
            if (resp.getStatusCode() != 200) { return null; }
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> rows = (List<Object>) parsed.get('data');
            return rows.isEmpty() ? null : (Map<String, Object>) rows[0];
        } catch (Exception e) { return null; }
    }

    /**
     * Applies offer decision logic based on LTV and engagement score.
     * Interview: This is the "next-best-action" decisioning layer.
     */
    @TestVisible
    static OfferDecision selectOffer(
            Decimal ltv, Decimal engagementScore, String context) {

        OfferDecision d = new OfferDecision();

        if (ltv >= 50000) {
            d.offerCode       = 'PLATINUM_RENEWAL';
            d.offerTitle      = 'Platinum Renewal — Exclusive 20% Loyalty Discount';
            d.discountPercent = 20;
            d.rationale       = 'High LTV customer (>$50K). Maximum retention offer.';
        } else if (ltv >= 10000) {
            d.offerCode       = 'GOLD_UPSELL';
            d.offerTitle      = 'Gold Customer Upsell — 10% Upgrade Discount';
            d.discountPercent = 10;
            d.rationale       = 'Gold tier LTV ($10K–$50K). Upsell opportunity.';
        } else if (engagementScore >= 0.7) {
            d.offerCode       = 'ENGAGED_PROSPECT';
            d.offerTitle      = 'Engaged Customer — 5% First Purchase Discount';
            d.discountPercent = 5;
            d.rationale       = 'High engagement score (' + engagementScore + '). Convert to buyer.';
        } else {
            d.offerCode       = 'STANDARD';
            d.offerTitle      = 'Standard Welcome Offer';
            d.discountPercent = 0;
            d.rationale       = 'New or low-engagement profile. Standard offer.';
        }
        return d;
    }

    /**
     * Handles SegmentEntry Data Action: updates CRM record + creates follow-up Task.
     */
    @TestVisible
    static DataActionResult handleSegmentEntry(Id contactId, DataActionPayload payload) {
        DataActionResult result = new DataActionResult();
        List<String> actions   = new List<String>();

        if (contactId != null) {
            // Mark Contact with segment entry
            Contact c = new Contact(
                Id = contactId,
                Description = 'Entered Data Cloud segment: ' + payload.segmentName
                    + ' on ' + payload.eventTime
            );
            update c;
            actions.add('Contact description updated');

            // Create follow-up task
            insert new Task(
                WhoId        = contactId,
                Subject      = 'Data Cloud: Entered ' + payload.segmentName,
                Priority     = 'Normal',
                Status       = 'Not Started',
                ActivityDate = Date.today().addDays(3),
                Description  = 'Unified Id: ' + payload.unifiedIndividualId
            );
            actions.add('Follow-up task created');
        }

        result.isSuccess     = true;
        result.actionsSummary = String.join(actions, '; ');
        return result;
    }

    /**
     * Handles SegmentExit Data Action: clears CRM segment flags.
     */
    @TestVisible
    static DataActionResult handleSegmentExit(Id contactId, DataActionPayload payload) {
        DataActionResult result = new DataActionResult();
        if (contactId != null) {
            Contact c = new Contact(
                Id = contactId,
                Description = 'Exited Data Cloud segment: ' + payload.segmentName
                    + ' on ' + payload.eventTime
            );
            update c;
        }
        result.isSuccess      = true;
        result.actionsSummary = 'Contact description updated for segment exit';
        return result;
    }

    @TestVisible
    static Id resolveContactIdFromAttributes(Map<String, Object> attributes) {
        if (attributes == null) { return null; }
        Object contactIdVal = attributes.get('ContactId__c');
        if (contactIdVal == null) { return null; }
        try { return Id.valueOf(String.valueOf(contactIdVal)); }
        catch (Exception e) { return null; }
    }

    // ─── DTOs ─────────────────────────────────────────────────────────────────

    // Personalised offer
    public class PersonalisedOfferInput {
        @InvocableVariable(label='Contact Id' required=true)
        public Id contactId;
        @InvocableVariable(label='Offer Context' description='Hint for offer selection: renewal | upsell | acquisition')
        public String offerContext;
    }
    public class PersonalisedOfferOutput {
        @InvocableVariable(label='Unified Individual Id')
        public String unifiedIndividualId;
        @InvocableVariable(label='Lifetime Value')
        public Decimal lifetimeValue;
        @InvocableVariable(label='Engagement Score')
        public Decimal engagementScore;
        @InvocableVariable(label='Offer Code')
        public String offerCode;
        @InvocableVariable(label='Offer Title')
        public String offerTitle;
        @InvocableVariable(label='Discount Percent')
        public Decimal discountPercent;
        @InvocableVariable(label='Rationale')
        public String rationale;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Stream case interaction
    public class StreamCaseInput {
        @InvocableVariable(label='Case Id' required=true)
        public Id caseId;
        @InvocableVariable(label='Override Individual Id')
        public String overrideIndividualId;
        @InvocableVariable(label='Engagement Score')
        public Decimal engagementScore;
        @InvocableVariable(label='Source API Name')
        public String sourceApiName;
    }
    public class StreamCaseOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Individual Id')
        public String individualId;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Data Action
    public class DataActionPayload {
        public String actionType;          // 'SegmentEntry' | 'SegmentExit'
        public String segmentId;
        public String segmentName;
        public String unifiedIndividualId;
        public String eventTime;
        public Map<String, Object> attributes;
    }
    public class DataActionResult {
        public Boolean isSuccess      = false;
        public String  actionsSummary = '';
        public String  errorMessage;
    }

    // Internal offer decision
    @TestVisible
    class OfferDecision {
        String  offerCode;
        String  offerTitle;
        Decimal discountPercent;
        String  rationale;
    }
}
