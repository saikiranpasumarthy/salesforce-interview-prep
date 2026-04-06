/**
 * @description Agentforce Deep Dive — autonomous agent patterns, multi-step action
 *              orchestration, human escalation via Omni-Channel, conversation context
 *              management, external API callout actions, and advanced agent output patterns.
 *
 *              AUTONOMOUS AGENT PATTERNS (interview framework):
 *
 *              Triggered Agent (user-initiated):
 *                User message → LLM routing → Topic → Agent Action → Response
 *
 *              Autonomous Agent (event-triggered):
 *                Platform Event / Record Change / Schedule
 *                  → Agent activated (no user in loop)
 *                  → Executes Actions automatically
 *                  → Posts result to Chatter / sends email / updates record
 *
 *              AGENT ESCALATION FLOW:
 *                Agent handles request
 *                  → Detects complexity / sentiment / escalation trigger
 *                  → Calls handoff action → creates PendingServiceRouting
 *                  → Routes to Omni-Channel queue
 *                  → Human agent picks up with full conversation context
 *
 *              CONVERSATION CONTEXT:
 *                - No built-in "memory" across sessions in base Agentforce
 *                - Pattern: store context in custom object (Agent_Session__c) or Platform Cache
 *                - Pass context as merge fields in next prompt invocation
 *                - $Context.LastBotMessage / $Context.SessionId available in Flow
 *
 *              MULTI-STEP ORCHESTRATION:
 *                - Single Agent Action can call multiple services internally
 *                - Return structured output — LLM decides whether to call next action
 *                - For deterministic multi-step: use Flow Action (sequential steps)
 *                - For LLM-driven multi-step: separate actions + Topic Instructions
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class AgentConversationService {

    // ─── Conversation context management ─────────────────────────────────────

    /**
     * Saves agent conversation context between turns.
     * Enables the agent to "remember" prior interactions within a session.
     *
     * Interview: Agentforce has no built-in cross-session memory.
     * Pattern: use a custom sObject (Agent_Session__c) keyed by session Id.
     * Session Id comes from $Context.SessionId in Flow / passed explicitly in Apex actions.
     *
     * @param sessionId   Unique session identifier (from Flow context or custom)
     * @param contextKey  Key to store (e.g. 'lastAccountId', 'preferredLanguage')
     * @param contextValue Value to store (serialised to String)
     */
    @InvocableMethod(
        label       = 'Save Conversation Context'
        description = 'Saves a key-value pair to the agent conversation session context. '
                    + 'Use to remember information across multiple turns of the same conversation.'
        category    = 'Agent Utilities'
    )
    public static List<ContextSaveOutput> saveConversationContext(
            List<ContextSaveInput> inputs) {

        List<ContextSaveOutput> results = new List<ContextSaveOutput>();

        for (ContextSaveInput inp : inputs) {
            ContextSaveOutput out = new ContextSaveOutput();
            try {
                if (String.isBlank(inp.sessionId) || String.isBlank(inp.contextKey)) {
                    out.isSuccess    = false;
                    out.errorMessage = 'sessionId and contextKey are required.';
                    results.add(out);
                    continue;
                }

                // Upsert using Platform Cache for lightweight session storage
                // In production: use custom sObject for persistence + audit trail
                PlatformCacheService.useMock = Test.isRunningTest();
                String cacheKey = buildSessionCacheKey(inp.sessionId, inp.contextKey);
                PlatformCacheService.put(cacheKey, inp.contextValue, 3600); // 1-hour TTL

                out.isSuccess = true;
                out.confirmationMessage = 'Context saved: ' + inp.contextKey;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Failed to save context: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    /**
     * Retrieves previously saved conversation context.
     *
     * @param sessionId   Session to retrieve context for
     * @param contextKey  Key to look up
     */
    @InvocableMethod(
        label       = 'Get Conversation Context'
        description = 'Retrieves a previously saved value from the agent conversation context. '
                    + 'Use to recall information from earlier in the same conversation.'
        category    = 'Agent Utilities'
    )
    public static List<ContextGetOutput> getConversationContext(
            List<ContextGetInput> inputs) {

        List<ContextGetOutput> results = new List<ContextGetOutput>();

        for (ContextGetInput inp : inputs) {
            ContextGetOutput out = new ContextGetOutput();
            try {
                PlatformCacheService.useMock = Test.isRunningTest();
                String cacheKey = buildSessionCacheKey(inp.sessionId, inp.contextKey);
                Object cached   = PlatformCacheService.get(cacheKey);

                out.contextValue = cached != null ? String.valueOf(cached) : null;
                out.found        = cached != null;
                out.isSuccess    = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Failed to retrieve context: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Human escalation / handoff ───────────────────────────────────────────

    /**
     * Escalates the conversation to a human agent via Omni-Channel routing.
     *
     * Interview: Omni-Channel escalation flow:
     *   1. Agent Action creates a Case (if not already open)
     *   2. Creates PendingServiceRouting record → triggers Omni-Channel routing
     *   3. Case routed to queue / agent based on routing configuration
     *   4. Human agent sees full conversation transcript in Live Agent / Messaging
     *
     * PendingServiceRouting fields:
     *   WorkItemId       — Id of the record to route (Case, MessagingSession, etc.)
     *   RoutingType      — 'Omni' | 'QueueBased' | 'SkillsBased'
     *   QueueId          — target queue (for QueueBased routing)
     *   CapacityWeight   — relative capacity consumed by this work item
     *
     * @param inputs  Escalation request with case details and reason
     */
    @InvocableMethod(
        label       = 'Escalate to Human Agent'
        description = 'Escalates the current conversation to a human support agent. '
                    + 'Creates a Case and routes it via Omni-Channel. '
                    + 'Use when: the issue is complex, the customer is frustrated, '
                    + 'or the request cannot be resolved by the AI agent.'
        category    = 'Service'
    )
    public static List<EscalationOutput> escalateToHuman(List<EscalationInput> inputs) {
        List<EscalationOutput> results = new List<EscalationOutput>();

        for (EscalationInput inp : inputs) {
            EscalationOutput out = new EscalationOutput();
            try {
                // Create the Case if not already provided
                Id caseId = inp.existingCaseId;
                if (caseId == null) {
                    Case c = new Case(
                        Subject      = inp.subject != null ? inp.subject : 'Agent Escalation',
                        Description  = inp.conversationSummary,
                        Priority     = inp.priority != null ? inp.priority : 'Medium',
                        Origin       = 'Einstein Copilot',
                        Status       = 'New'
                    );
                    if (inp.accountId != null) { c.AccountId = inp.accountId; }
                    if (inp.contactId != null) { c.ContactId = inp.contactId; }
                    insert c;
                    caseId = c.Id;
                }

                // Create escalation note on the case
                String noteBody = 'AI Agent Escalation\n'
                    + 'Reason: ' + (inp.escalationReason != null ? inp.escalationReason : 'Requested by user') + '\n'
                    + (String.isNotBlank(inp.conversationSummary)
                        ? 'Summary: ' + inp.conversationSummary : '');
                insert new CaseComment(
                    ParentId    = caseId,
                    CommentBody = noteBody,
                    IsPublished = false
                );

                // Route via Omni-Channel (PendingServiceRouting)
                Id routingQueueId = getEscalationQueueId(inp.escalationQueue);
                if (routingQueueId != null) {
                    PendingServiceRouting psr = new PendingServiceRouting(
                        WorkItemId     = caseId,
                        RoutingType    = 'QueueBased',
                        CapacityWeight = 1,
                        IsReadyForRouting = true
                    );
                    insert psr;
                }

                out.caseId              = caseId;
                out.isSuccess           = true;
                out.confirmationMessage = 'Your request has been escalated to a human agent. '
                    + 'A support specialist will be with you shortly.';

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Escalation failed: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Multi-source research action ─────────────────────────────────────────

    /**
     * Aggregates data from multiple Salesforce objects into a single agent response.
     * Demonstrates multi-step orchestration within a single Agent Action.
     *
     * Interview: A single @InvocableMethod can call multiple SOQLs, services,
     * and callouts internally. The LLM sees one structured output.
     * This is more efficient than chaining multiple actions when the data
     * always needs to be retrieved together.
     *
     * @param inputs  Customer research request (account Id)
     * @return        360° customer view with account, contacts, opps, cases
     */
    @InvocableMethod(
        label       = 'Get Customer 360 View'
        description = 'Returns a comprehensive 360° view of a customer: '
                    + 'account details, key contacts, open opportunities, recent cases, '
                    + 'and last activity date. Use for pre-call research or account reviews.'
        category    = 'Account Management'
    )
    public static List<Customer360Output> getCustomer360(List<Customer360Input> inputs) {
        List<Customer360Output> results = new List<Customer360Output>();

        for (Customer360Input inp : inputs) {
            Customer360Output out = new Customer360Output();
            try {
                // Account + sub-queries for related records
                Account acc = [
                    SELECT Id, Name, Industry, AnnualRevenue, Type, Phone, Website,
                           BillingCity, BillingState, BillingCountry,
                           (SELECT Id, FirstName, LastName, Title, Email, Phone
                            FROM   Contacts
                            ORDER BY LastName ASC LIMIT 5),
                           (SELECT Id, Name, StageName, Amount, CloseDate
                            FROM   Opportunities
                            WHERE  IsClosed = false
                            ORDER BY CloseDate ASC LIMIT 5),
                           (SELECT Id, CaseNumber, Subject, Status, Priority, CreatedDate
                            FROM   Cases
                            WHERE  IsClosed = false
                            ORDER BY CreatedDate DESC LIMIT 3)
                    FROM   Account
                    WHERE  Id = :inp.accountId
                    WITH   SECURITY_ENFORCED
                ];

                // Last activity
                List<Task> lastActivity = [
                    SELECT Id, Subject, ActivityDate, Status
                    FROM   Task
                    WHERE  WhatId = :inp.accountId
                    ORDER BY ActivityDate DESC NULLS LAST
                    LIMIT  1
                ];

                out.accountName    = acc.Name;
                out.industry       = acc.Industry;
                out.annualRevenue  = acc.AnnualRevenue;
                out.accountType    = acc.Type;
                out.contactCount   = acc.Contacts.size();
                out.openOpps       = acc.Opportunities.size();
                out.openCases      = acc.Cases.size();
                out.lastActivityDate = lastActivity.isEmpty()
                    ? null : lastActivity[0].ActivityDate;

                out.summary = buildCustomer360Summary(acc, lastActivity);
                out.isSuccess = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Customer 360 retrieval failed: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── External API callout action ──────────────────────────────────────────

    /**
     * Agent Action that makes an external HTTP callout.
     *
     * Interview: @InvocableMethod(callout=true) is required for actions that
     * make HTTP callouts. Standard callout governor limits apply (100/tx).
     * Cannot call from Batch, @future, or scheduled Apex without Queueable.
     *
     * Pattern: Named Credential handles auth — never hardcode credentials in action.
     * Always set a timeout — agents have a response time budget.
     * Return a structured output so the LLM can present results naturally.
     *
     * @param inputs  Enrichment request with company name/domain
     * @return        External data payload (mock-safe)
     */
    @InvocableMethod(
        label       = 'Enrich Account from External Data'
        description = 'Fetches additional company information from an external data provider. '
                    + 'Returns company size, funding stage, and technographics. '
                    + 'Use when the user asks for company intel not in Salesforce.'
        category    = 'Account Management'
        callout     = true
    )
    public static List<EnrichmentOutput> enrichAccountData(List<EnrichmentInput> inputs) {
        List<EnrichmentOutput> results = new List<EnrichmentOutput>();

        for (EnrichmentInput inp : inputs) {
            EnrichmentOutput out = new EnrichmentOutput();
            try {
                if (String.isBlank(inp.companyDomain)) {
                    out.isSuccess    = false;
                    out.errorMessage = 'Company domain is required for enrichment.';
                    results.add(out);
                    continue;
                }

                // Named Credential pattern — auth handled by platform
                HttpRequest req = new HttpRequest();
                req.setEndpoint('callout:DataEnrichmentAPI/v1/company?domain='
                    + EncodingUtil.urlEncode(inp.companyDomain, 'UTF-8'));
                req.setMethod('GET');
                req.setTimeout(10000); // 10s — agent response budget
                req.setHeader('Accept', 'application/json');

                Http http = new Http();
                HttpResponse resp = http.send(req);

                if (resp.getStatusCode() == 200) {
                    Map<String, Object> payload =
                        (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());

                    out.companySize     = (String) payload.get('employeeRange');
                    out.fundingStage    = (String) payload.get('fundingStage');
                    out.techStack       = (String) payload.get('primaryTechnology');
                    out.enrichmentScore = (Integer) payload.get('confidenceScore');
                    out.isSuccess       = true;
                    out.summary         = buildEnrichmentSummary(out);
                } else {
                    out.isSuccess    = false;
                    out.errorMessage = 'Enrichment service returned: ' + resp.getStatusCode();
                }

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Enrichment failed: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Sentiment detection ──────────────────────────────────────────────────

    /**
     * Detects customer sentiment from free text — used to trigger escalation.
     *
     * Interview: In Agentforce, sentiment detection is commonly implemented as
     * an intermediate step within an action or as a Topic Instruction condition.
     * Pattern: run simple keyword/phrase matching in Apex for latency-sensitive paths;
     * invoke LLM for nuanced sentiment when latency budget allows.
     *
     * This Apex implementation uses keyword scoring — fast and no LLM callout required.
     *
     * @param text  Customer message text to analyse
     * @return      SentimentResult with score (-1.0 to 1.0) and label
     */
    @TestVisible
    static SentimentResult detectSentiment(String text) {
        if (String.isBlank(text)) {
            return new SentimentResult('Neutral', 0.0, false);
        }
        String lower = text.toLowerCase();

        Set<String> negativeKeywords = new Set<String>{
            'frustrated', 'angry', 'terrible', 'unacceptable', 'worst',
            'useless', 'ridiculous', 'awful', 'disappointed', 'furious',
            'escalate', 'manager', 'cancel', 'refund', 'lawsuit'
        };
        Set<String> positiveKeywords = new Set<String>{
            'thank', 'great', 'excellent', 'helpful', 'amazing',
            'love', 'perfect', 'awesome', 'satisfied', 'happy'
        };

        Integer negScore = 0;
        Integer posScore = 0;
        for (String kw : negativeKeywords) {
            if (lower.contains(kw)) { negScore++; }
        }
        for (String kw : positiveKeywords) {
            if (lower.contains(kw)) { posScore++; }
        }

        Decimal score;
        String  label;
        Boolean shouldEscalate;

        if (negScore > posScore) {
            score          = -(Decimal.valueOf(negScore) / negativeKeywords.size());
            label          = negScore >= 3 ? 'Very Negative' : 'Negative';
            shouldEscalate = negScore >= 2;
        } else if (posScore > negScore) {
            score          = Decimal.valueOf(posScore) / positiveKeywords.size();
            label          = 'Positive';
            shouldEscalate = false;
        } else {
            score          = 0;
            label          = 'Neutral';
            shouldEscalate = false;
        }
        return new SentimentResult(label, score, shouldEscalate);
    }

    /**
     * Agent Action wrapping sentiment detection — returns escalation recommendation.
     *
     * Pattern: Topic Instructions can reference the output field `shouldEscalate`
     * to automatically chain to the escalation action when true.
     */
    @InvocableMethod(
        label       = 'Analyse Customer Sentiment'
        description = 'Analyses the sentiment of a customer message. '
                    + 'Returns sentiment label (Positive/Neutral/Negative/Very Negative) '
                    + 'and a flag indicating whether human escalation is recommended. '
                    + 'Use when evaluating whether a conversation needs human intervention.'
        category    = 'Service'
    )
    public static List<SentimentOutput> analyseSentiment(List<SentimentInput> inputs) {
        List<SentimentOutput> results = new List<SentimentOutput>();

        for (SentimentInput inp : inputs) {
            SentimentOutput out = new SentimentOutput();
            SentimentResult result = detectSentiment(inp.messageText);
            out.sentimentLabel     = result.label;
            out.sentimentScore     = result.score;
            out.shouldEscalate     = result.shouldEscalate;
            out.recommendation     = result.shouldEscalate
                ? 'Customer sentiment is ' + result.label + '. Human escalation recommended.'
                : 'Sentiment is ' + result.label + '. Agent can continue handling.';
            out.isSuccess          = true;
            results.add(out);
        }
        return results;
    }

    // ─── Autonomous agent trigger pattern ────────────────────────────────────

    /**
     * Processes a Platform Event to autonomously update records and notify users.
     * Represents the entry point for an autonomous (event-triggered) agent action.
     *
     * Interview: Autonomous agents are triggered by:
     *   - Platform Events (subscribe via Trigger on __e object)
     *   - Record-Triggered Flows (agent action called from Flow)
     *   - Scheduled Flows (time-based autonomous tasks)
     *   - Einstein Activity Capture events
     *
     * Key difference from user-triggered agents:
     *   - No conversation context (no user in loop)
     *   - Must be idempotent — Platform Events can be replayed
     *   - Must post results somewhere (Chatter, email, record field update)
     *   - Needs explicit error handling — no user to report failures to
     *
     * @param caseId     Case that triggered the autonomous action
     * @param eventType  Type of event ('case_assigned', 'sla_breach', 'sentiment_spike')
     * @return           Result of the autonomous processing
     */
    @InvocableMethod(
        label       = 'Process Autonomous Case Event'
        description = 'Autonomously processes a case event without user interaction. '
                    + 'Analyses the case, updates priority if needed, and posts a Chatter update. '
                    + 'Designed for autonomous agent workflows triggered by Platform Events.'
        category    = 'Service'
    )
    public static List<AutonomousEventOutput> processAutonomousCaseEvent(
            List<AutonomousEventInput> inputs) {

        List<AutonomousEventOutput> results = new List<AutonomousEventOutput>();

        for (AutonomousEventInput inp : inputs) {
            AutonomousEventOutput out = new AutonomousEventOutput();
            try {
                Case c = [
                    SELECT Id, CaseNumber, Subject, Description, Priority,
                           Status, AccountId, ContactId, OwnerId
                    FROM   Case
                    WHERE  Id = :inp.caseId
                    WITH   SECURITY_ENFORCED
                ];

                List<String> actions = new List<String>();

                // Analyse sentiment of description
                if (String.isNotBlank(c.Description)) {
                    SentimentResult sentiment = detectSentiment(c.Description);
                    if (sentiment.shouldEscalate && c.Priority != 'High') {
                        c.Priority = 'High';
                        actions.add('Priority escalated to High based on sentiment analysis');
                    }
                }

                // Event-specific handling
                if (inp.eventType == 'sla_breach') {
                    c.Priority = 'Critical';
                    actions.add('Priority set to Critical due to SLA breach');
                }

                if (!actions.isEmpty()) { update c; }

                // Post autonomous action summary to Chatter
                String chatterBody = '[Agentforce Autonomous Agent]\n'
                    + 'Case: ' + c.CaseNumber + '\n'
                    + 'Event: ' + inp.eventType + '\n'
                    + (actions.isEmpty()
                        ? 'No automated actions required.'
                        : 'Actions taken:\n• ' + String.join(actions, '\n• '));
                insert new FeedItem(
                    ParentId = inp.caseId,
                    Body     = chatterBody,
                    Type     = 'TextPost'
                );

                out.actionsCount    = actions.size();
                out.actionsSummary  = String.join(actions, '; ');
                out.isSuccess       = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Autonomous processing failed: ' + e.getMessage();
                // Log to debug — no user to notify
                System.debug(LoggingLevel.ERROR,
                    'AgentConversationService.processAutonomousCaseEvent: ' + e.getMessage());
            }
            results.add(out);
        }
        return results;
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    @TestVisible
    static String buildSessionCacheKey(String sessionId, String contextKey) {
        String raw = 'agent_' + sessionId + '_' + contextKey;
        return raw.replaceAll('[^a-zA-Z0-9_]', '_').left(50);
    }

    @TestVisible
    static String buildCustomer360Summary(Account acc, List<Task> lastActivity) {
        List<String> parts = new List<String>();
        parts.add(acc.Name + ' (' + (acc.Type != null ? acc.Type : 'Unknown type') + ')');
        if (acc.Industry != null)       { parts.add('Industry: ' + acc.Industry); }
        if (acc.AnnualRevenue != null)  { parts.add('Revenue: $' + acc.AnnualRevenue.format()); }
        parts.add('Key Contacts: '   + acc.Contacts.size());
        parts.add('Open Deals: '     + acc.Opportunities.size());
        parts.add('Open Cases: '     + acc.Cases.size());
        if (!lastActivity.isEmpty()) {
            parts.add('Last Activity: ' + lastActivity[0].Subject
                + ' (' + (lastActivity[0].ActivityDate != null
                    ? lastActivity[0].ActivityDate.format() : 'no date') + ')');
        }
        return String.join(parts, ' | ');
    }

    @TestVisible
    static String buildEnrichmentSummary(EnrichmentOutput out) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(out.companySize))  { parts.add('Size: ' + out.companySize); }
        if (String.isNotBlank(out.fundingStage)) { parts.add('Funding: ' + out.fundingStage); }
        if (String.isNotBlank(out.techStack))    { parts.add('Tech: ' + out.techStack); }
        if (out.enrichmentScore != null)         { parts.add('Confidence: ' + out.enrichmentScore + '%'); }
        return parts.isEmpty() ? 'No enrichment data available.' : String.join(parts, ' | ');
    }

    @TestVisible
    static Id getEscalationQueueId(String queueName) {
        if (String.isBlank(queueName)) { return null; }
        List<Group> queues = [
            SELECT Id FROM Group
            WHERE  Type    = 'Queue'
              AND  DeveloperName = :queueName
            LIMIT  1
        ];
        return queues.isEmpty() ? null : queues[0].Id;
    }

    // ─── Inner DTOs ───────────────────────────────────────────────────────────

    // Conversation context
    public class ContextSaveInput {
        @InvocableVariable(label='Session Id' required=true)
        public String sessionId;
        @InvocableVariable(label='Context Key' required=true)
        public String contextKey;
        @InvocableVariable(label='Context Value')
        public String contextValue;
    }
    public class ContextSaveOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Confirmation Message')
        public String confirmationMessage;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
    public class ContextGetInput {
        @InvocableVariable(label='Session Id' required=true)
        public String sessionId;
        @InvocableVariable(label='Context Key' required=true)
        public String contextKey;
    }
    public class ContextGetOutput {
        @InvocableVariable(label='Context Value')
        public String contextValue;
        @InvocableVariable(label='Found')
        public Boolean found;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Escalation
    public class EscalationInput {
        @InvocableVariable(label='Existing Case Id')
        public Id existingCaseId;
        @InvocableVariable(label='Subject')
        public String subject;
        @InvocableVariable(label='Conversation Summary')
        public String conversationSummary;
        @InvocableVariable(label='Escalation Reason')
        public String escalationReason;
        @InvocableVariable(label='Priority')
        public String priority;
        @InvocableVariable(label='Account Id')
        public Id accountId;
        @InvocableVariable(label='Contact Id')
        public Id contactId;
        @InvocableVariable(label='Escalation Queue Developer Name')
        public String escalationQueue;
    }
    public class EscalationOutput {
        @InvocableVariable(label='Case Id')
        public Id caseId;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Confirmation Message')
        public String confirmationMessage;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Customer 360
    public class Customer360Input {
        @InvocableVariable(label='Account Id' required=true)
        public Id accountId;
    }
    public class Customer360Output {
        @InvocableVariable(label='Account Name')
        public String accountName;
        @InvocableVariable(label='Industry')
        public String industry;
        @InvocableVariable(label='Annual Revenue')
        public Decimal annualRevenue;
        @InvocableVariable(label='Account Type')
        public String accountType;
        @InvocableVariable(label='Contact Count')
        public Integer contactCount;
        @InvocableVariable(label='Open Opportunities')
        public Integer openOpps;
        @InvocableVariable(label='Open Cases')
        public Integer openCases;
        @InvocableVariable(label='Last Activity Date')
        public Date lastActivityDate;
        @InvocableVariable(label='Summary')
        public String summary;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Enrichment
    public class EnrichmentInput {
        @InvocableVariable(label='Company Domain' required=true)
        public String companyDomain;
    }
    public class EnrichmentOutput {
        @InvocableVariable(label='Company Size Range')
        public String companySize;
        @InvocableVariable(label='Funding Stage')
        public String fundingStage;
        @InvocableVariable(label='Primary Tech Stack')
        public String techStack;
        @InvocableVariable(label='Enrichment Confidence Score')
        public Integer enrichmentScore;
        @InvocableVariable(label='Summary')
        public String summary;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Sentiment
    public class SentimentInput {
        @InvocableVariable(label='Message Text' required=true)
        public String messageText;
    }
    public class SentimentOutput {
        @InvocableVariable(label='Sentiment Label')
        public String sentimentLabel;
        @InvocableVariable(label='Sentiment Score')
        public Decimal sentimentScore;
        @InvocableVariable(label='Should Escalate')
        public Boolean shouldEscalate;
        @InvocableVariable(label='Recommendation')
        public String recommendation;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
    }

    // Autonomous event
    public class AutonomousEventInput {
        @InvocableVariable(label='Case Id' required=true)
        public Id caseId;
        @InvocableVariable(label='Event Type' description='case_assigned | sla_breach | sentiment_spike')
        public String eventType;
    }
    public class AutonomousEventOutput {
        @InvocableVariable(label='Actions Count')
        public Integer actionsCount;
        @InvocableVariable(label='Actions Summary')
        public String actionsSummary;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Sentiment inner result (not invocable — internal use only)
    @TestVisible
    class SentimentResult {
        String  label;
        Decimal score;
        Boolean shouldEscalate;
        SentimentResult(String lbl, Decimal sc, Boolean esc) {
            this.label          = lbl;
            this.score          = sc;
            this.shouldEscalate = esc;
        }
    }
}
