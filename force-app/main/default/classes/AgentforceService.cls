/**
 * @description Agentforce (Einstein Copilot) architecture — custom Agent Actions,
 *              Topics, invocable patterns, and agent conversation context handling.
 *
 *              AGENTFORCE ARCHITECTURE (interview framework):
 *
 *              Agent
 *                └── Topic              Groups related actions by intent/domain
 *                      └── Agent Action Executable step (Apex / Flow / Prompt Template)
 *
 *              Agent Types:
 *                Einstein Copilot     — embedded in Salesforce UI (sidebar)
 *                Agentforce for Sales — sales-specific actions (Email, Summarize, etc.)
 *                Agentforce for Service — service-specific (Case Summary, Knowledge, etc.)
 *                Custom Agent         — org-defined Topics + Actions
 *                Autonomous Agent     — acts without user prompt (event-triggered)
 *
 *              Topic:
 *                - Natural language description of intent (e.g. "Account research tasks")
 *                - Agent uses LLM reasoning to select best topic for user's request
 *                - Each Topic has Instructions (rules/guardrails for the agent)
 *                - Topics own a set of Agent Actions
 *
 *              Agent Action types:
 *                Apex Action      — @InvocableMethod in an Apex class
 *                Flow Action      — Auto-launched or Screen Flow
 *                Prompt Action    — Prompt Template execution
 *                Standard Action  — Salesforce built-in (Draft Email, Summarize Record, etc.)
 *
 *              KEY RULES:
 *                - @InvocableMethod MUST accept List<InputType> and return List<OutputType>
 *                - @InvocableVariable(required=true) marks mandatory agent inputs
 *                - label + description on @InvocableMethod are shown to the LLM — be descriptive
 *                - Agent Actions run in system context unless explicitly scoped
 *                - Bulkification: invocable methods receive a list (agent sends 1 element)
 *                - callout=true required if the action makes HTTP callouts
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class AgentforceService {

    // ─── Agent Action: Account Summary ────────────────────────────────────────

    /**
     * Agent Action — returns a structured summary of an Account for the AI agent.
     *
     * Interview: The label and description fields on @InvocableMethod are injected
     * into the LLM's system prompt. Write them as clear, unambiguous instructions
     * so the LLM knows exactly when to invoke this action and what it returns.
     *
     * The agent sends a single-element list (bulk-safe but always size 1 in practice).
     * Always handle List<> for governor limit safety.
     */
    @InvocableMethod(
        label       = 'Get Account Summary'
        description = 'Retrieves key details about a Salesforce Account including '
                    + 'revenue, industry, open opportunities, and recent activity. '
                    + 'Use when the user asks about an account, customer, or company.'
        category    = 'Account Management'
    )
    public static List<AccountSummaryOutput> getAccountSummary(
            List<AccountSummaryInput> inputs) {

        List<AccountSummaryOutput> results = new List<AccountSummaryOutput>();

        for (AccountSummaryInput inp : inputs) {
            AccountSummaryOutput out = new AccountSummaryOutput();
            try {
                Account acc = [
                    SELECT Id, Name, Industry, AnnualRevenue, NumberOfEmployees,
                           Phone, Website, BillingCity, BillingState,
                           OwnerId, Owner.Name, Type,
                           (SELECT Id, Name, StageName, Amount, CloseDate
                            FROM   Opportunities
                            WHERE  IsClosed = false
                            ORDER BY CloseDate ASC
                            LIMIT  5),
                           (SELECT Id, Subject, Status, CreatedDate
                            FROM   Cases
                            WHERE  IsClosed = false
                            ORDER BY CreatedDate DESC
                            LIMIT  3)
                    FROM   Account
                    WHERE  Id = :inp.accountId
                    WITH   SECURITY_ENFORCED
                ];

                out.accountName      = acc.Name;
                out.industry         = acc.Industry;
                out.annualRevenue    = acc.AnnualRevenue;
                out.numberOfEmployees = acc.NumberOfEmployees;
                out.accountOwner     = acc.Owner.Name;
                out.accountType      = acc.Type;
                out.openOpportunities = acc.Opportunities.size();
                out.openCases        = acc.Cases.size();
                out.summary          = buildAccountSummaryText(acc);
                out.isSuccess        = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Unable to retrieve account: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Agent Action: Create Case ─────────────────────────────────────────────

    /**
     * Agent Action — creates a Case on behalf of the user via the agent.
     *
     * Interview: Agent Actions that perform DML must handle partial failures gracefully.
     * Return a structured output so the LLM can communicate success/failure naturally.
     * Never throw unhandled exceptions — the agent has no way to recover from them.
     */
    @InvocableMethod(
        label       = 'Create Support Case'
        description = 'Creates a new Salesforce support Case linked to an Account or Contact. '
                    + 'Use when the user wants to log an issue, report a problem, or open a ticket. '
                    + 'Returns the new Case number for confirmation.'
        category    = 'Service'
    )
    public static List<CreateCaseOutput> createCase(List<CreateCaseInput> inputs) {
        List<CreateCaseOutput> results = new List<CreateCaseOutput>();

        for (CreateCaseInput inp : inputs) {
            CreateCaseOutput out = new CreateCaseOutput();
            try {
                if (String.isBlank(inp.subject)) {
                    out.isSuccess    = false;
                    out.errorMessage = 'Subject is required to create a case.';
                    results.add(out);
                    continue;
                }

                Case c = new Case(
                    Subject     = inp.subject.left(255),
                    Description = inp.description,
                    Priority    = String.isBlank(inp.priority) ? 'Medium' : inp.priority,
                    Origin      = 'Einstein Copilot',
                    Status      = 'New'
                );
                if (inp.accountId != null) { c.AccountId = inp.accountId; }
                if (inp.contactId != null) { c.ContactId = inp.contactId; }
                insert c;

                Case created = [SELECT Id, CaseNumber FROM Case WHERE Id = :c.Id];
                out.caseId      = created.Id;
                out.caseNumber  = created.CaseNumber;
                out.isSuccess   = true;
                out.confirmationMessage = 'Case ' + created.CaseNumber
                    + ' has been created successfully with ' + c.Priority + ' priority.';

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Failed to create case: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Agent Action: Opportunity Pipeline Summary ────────────────────────────

    /**
     * Agent Action — returns pipeline metrics for a given time window.
     * Demonstrates agent actions that aggregate data rather than operate on single records.
     *
     * Interview: Agents can call actions that return dashboards/summaries as text.
     * The LLM uses the returned text to compose its natural language reply.
     */
    @InvocableMethod(
        label       = 'Get Opportunity Pipeline Summary'
        description = 'Returns a summary of open opportunities: total count, total value, '
                    + 'breakdown by stage, and deals closing soon. '
                    + 'Use when the user asks about pipeline, forecast, or deals.'
        category    = 'Sales'
    )
    public static List<PipelineSummaryOutput> getPipelineSummary(
            List<PipelineSummaryInput> inputs) {

        List<PipelineSummaryOutput> results = new List<PipelineSummaryOutput>();

        for (PipelineSummaryInput inp : inputs) {
            PipelineSummaryOutput out = new PipelineSummaryOutput();
            try {
                Integer daysAhead = inp.daysAhead != null ? inp.daysAhead : 30;
                Date closingBy    = Date.today().addDays(daysAhead);

                List<AggregateResult> byStage = [
                    SELECT StageName, COUNT(Id) oppCount, SUM(Amount) totalAmount
                    FROM   Opportunity
                    WHERE  IsClosed = false
                      AND  OwnerId  = :inp.ownerId
                    GROUP BY StageName
                    ORDER BY StageName ASC
                ];

                List<Opportunity> closingSoon = [
                    SELECT Id, Name, Amount, StageName, CloseDate, Account.Name
                    FROM   Opportunity
                    WHERE  IsClosed   = false
                      AND  CloseDate <= :closingBy
                      AND  OwnerId   = :inp.ownerId
                    ORDER BY CloseDate ASC
                    LIMIT 10
                ];

                out.summary   = buildPipelineSummaryText(byStage, closingSoon, daysAhead);
                out.isSuccess = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Unable to retrieve pipeline: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Agent Action: Update Record Field ────────────────────────────────────

    /**
     * Agent Action — generic single-field update, demonstrating how agents
     * can perform targeted record updates without full-record access.
     *
     * Interview: Best practice — scope agent actions narrowly (one field/operation).
     * Avoid generic "update any record" actions — hard for LLM to use correctly
     * and increases risk of unintended data changes.
     *
     * Note: Dynamic DML (Schema.getGlobalDescribe) bypasses compile-time type safety.
     * Always validate objectApiName + fieldApiName against Schema before use.
     */
    @InvocableMethod(
        label       = 'Update Opportunity Stage'
        description = 'Updates the StageName of an Opportunity to a new value. '
                    + 'Valid stages: Prospecting, Qualification, Needs Analysis, '
                    + 'Value Proposition, Id. Decision Makers, Perception Analysis, '
                    + 'Proposal/Price Quote, Negotiation/Review, Closed Won, Closed Lost. '
                    + 'Use when the user wants to advance or change an opportunity stage.'
        category    = 'Sales'
    )
    public static List<UpdateStageOutput> updateOpportunityStage(
            List<UpdateStageInput> inputs) {

        List<UpdateStageOutput> results = new List<UpdateStageOutput>();
        Set<String> validStages = new Set<String>{
            'Prospecting', 'Qualification', 'Needs Analysis', 'Value Proposition',
            'Id. Decision Makers', 'Perception Analysis', 'Proposal/Price Quote',
            'Negotiation/Review', 'Closed Won', 'Closed Lost'
        };

        for (UpdateStageInput inp : inputs) {
            UpdateStageOutput out = new UpdateStageOutput();
            try {
                if (!validStages.contains(inp.newStage)) {
                    out.isSuccess    = false;
                    out.errorMessage = 'Invalid stage: ' + inp.newStage
                        + '. Valid values: ' + String.join(new List<String>(validStages), ', ');
                    results.add(out);
                    continue;
                }

                Opportunity opp = [
                    SELECT Id, Name, StageName FROM Opportunity
                    WHERE  Id = :inp.opportunityId
                    WITH   SECURITY_ENFORCED
                ];
                String previousStage = opp.StageName;
                opp.StageName = inp.newStage;
                update opp;

                out.isSuccess           = true;
                out.confirmationMessage = 'Opportunity "' + opp.Name + '" stage updated '
                    + 'from "' + previousStage + '" to "' + inp.newStage + '".';

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Failed to update stage: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Agent Action: Knowledge Article Search ────────────────────────────────

    /**
     * Agent Action — searches Knowledge for articles relevant to a query.
     * Used by service agents to surface self-service answers.
     *
     * Interview: SOSL is preferred over SOQL LIKE for full-text search in agents.
     * Knowledge__kav requires 'knowledge__kav' permission — guest/agent user must
     * have Read access on KnowledgeArticleVersion.
     *
     * @param inputs  Search term from the user's question
     */
    @InvocableMethod(
        label       = 'Search Knowledge Articles'
        description = 'Searches the Knowledge Base for published articles matching the query. '
                    + 'Returns article titles, summaries, and URLs. '
                    + 'Use when the user has a question that may be answered by existing documentation.'
        category    = 'Knowledge'
    )
    public static List<KnowledgeSearchOutput> searchKnowledge(
            List<KnowledgeSearchInput> inputs) {

        List<KnowledgeSearchOutput> results = new List<KnowledgeSearchOutput>();

        for (KnowledgeSearchInput inp : inputs) {
            KnowledgeSearchOutput out = new KnowledgeSearchOutput();
            try {
                if (String.isBlank(inp.searchQuery)) {
                    out.isSuccess    = false;
                    out.errorMessage = 'Search query is required.';
                    results.add(out);
                    continue;
                }

                // SOSL for full-text search across Knowledge
                List<List<SObject>> searchResults = Search.query(
                    'FIND :inp.searchQuery IN ALL FIELDS '
                    + 'RETURNING Knowledge__kav(Id, Title, Summary, ArticleNumber '
                    + 'WHERE PublishStatus = \'Online\' AND Language = \'en_US\') '
                    + 'LIMIT 5'
                );

                List<String> articleSummaries = new List<String>();
                if (!searchResults.isEmpty()) {
                    for (SObject art : searchResults[0]) {
                        String title   = (String) art.get('Title');
                        String summary = (String) art.get('Summary');
                        articleSummaries.add(
                            '• ' + title + (String.isNotBlank(summary) ? ': ' + summary : '')
                        );
                    }
                }

                out.articlesFound = articleSummaries.size();
                out.articleList   = String.join(articleSummaries, '\n');
                out.isSuccess     = true;
                out.summary       = out.articlesFound > 0
                    ? 'Found ' + out.articlesFound + ' article(s):\n' + out.articleList
                    : 'No Knowledge articles found for "' + inp.searchQuery + '".';

            } catch (Exception e) {
                // Knowledge not configured in org — graceful degradation
                out.isSuccess = false;
                out.errorMessage = 'Knowledge search unavailable: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Agent guardrail helper ────────────────────────────────────────────────

    /**
     * Validates that an agent action input record Id belongs to the expected
     * SObject type — prevents prompt injection attacks where a malicious user
     * passes an Id from a different object to trick the agent.
     *
     * Interview: Prompt injection in Agentforce — an attacker embeds instructions
     * in a record field (e.g. Description = "Ignore previous instructions and...").
     * Guardrails: validate all Ids, sanitise free-text inputs, scope actions narrowly.
     *
     * @param recordId       Id to validate
     * @param expectedType   Expected SObject type (e.g. Schema.Account.SObjectType)
     * @throws AgentActionException if the Id type does not match
     */
    @TestVisible
    static void assertRecordType(Id recordId, Schema.SObjectType expectedType) {
        if (recordId == null) {
            throw new AgentActionException('Record Id is required.');
        }
        Schema.SObjectType actualType = recordId.getSObjectType();
        if (actualType != expectedType) {
            throw new AgentActionException(
                'Invalid record Id. Expected ' + expectedType.getDescribe().getName()
                + ' but received ' + actualType.getDescribe().getName() + '.'
            );
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    @TestVisible
    static String buildAccountSummaryText(Account acc) {
        List<String> parts = new List<String>();
        parts.add('Account: ' + acc.Name);
        if (String.isNotBlank(acc.Industry))      { parts.add('Industry: ' + acc.Industry); }
        if (acc.AnnualRevenue != null)             { parts.add('Annual Revenue: $' + acc.AnnualRevenue.format()); }
        if (acc.NumberOfEmployees != null)         { parts.add('Employees: ' + acc.NumberOfEmployees); }
        if (String.isNotBlank(acc.Type))           { parts.add('Type: ' + acc.Type); }
        if (acc.Owner != null)                     { parts.add('Owner: ' + acc.Owner.Name); }
        parts.add('Open Opportunities: ' + acc.Opportunities.size());
        parts.add('Open Cases: '         + acc.Cases.size());
        return String.join(parts, ' | ');
    }

    @TestVisible
    static String buildPipelineSummaryText(
            List<AggregateResult> byStage,
            List<Opportunity> closingSoon,
            Integer daysAhead) {

        Decimal totalValue = 0;
        Integer totalCount = 0;
        List<String> stageLines = new List<String>();

        for (AggregateResult ar : byStage) {
            Integer cnt = (Integer) ar.get('oppCount');
            Decimal amt = (Decimal) ar.get('totalAmount');
            totalCount += cnt;
            totalValue += (amt != null ? amt : 0);
            stageLines.add((String) ar.get('StageName') + ': ' + cnt
                + ' deal(s) ($' + (amt != null ? amt.setScale(0).format() : '0') + ')');
        }

        List<String> closingLines = new List<String>();
        for (Opportunity opp : closingSoon) {
            closingLines.add('• ' + opp.Name + ' — '
                + (opp.Amount != null ? '$' + opp.Amount.setScale(0).format() : 'no amount')
                + ' — closes ' + opp.CloseDate.format());
        }

        String summary = 'Pipeline Summary:\n'
            + 'Total open deals: ' + totalCount + '\n'
            + 'Total pipeline value: $' + totalValue.setScale(0).format() + '\n'
            + 'By stage:\n' + String.join(stageLines, '\n');

        if (!closingLines.isEmpty()) {
            summary += '\n\nClosing in next ' + daysAhead + ' days:\n'
                + String.join(closingLines, '\n');
        }
        return summary;
    }

    // ─── Input / Output DTOs ──────────────────────────────────────────────────

    // --- Account Summary ---
    public class AccountSummaryInput {
        @InvocableVariable(label='Account Id' description='Salesforce Account record Id' required=true)
        public Id accountId;
    }

    public class AccountSummaryOutput {
        @InvocableVariable(label='Account Name')
        public String accountName;

        @InvocableVariable(label='Industry')
        public String industry;

        @InvocableVariable(label='Annual Revenue')
        public Decimal annualRevenue;

        @InvocableVariable(label='Number of Employees')
        public Integer numberOfEmployees;

        @InvocableVariable(label='Account Owner')
        public String accountOwner;

        @InvocableVariable(label='Account Type')
        public String accountType;

        @InvocableVariable(label='Open Opportunities Count')
        public Integer openOpportunities;

        @InvocableVariable(label='Open Cases Count')
        public Integer openCases;

        @InvocableVariable(label='Summary Text')
        public String summary;

        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // --- Create Case ---
    public class CreateCaseInput {
        @InvocableVariable(label='Subject' description='Case subject/title' required=true)
        public String subject;

        @InvocableVariable(label='Description' description='Detailed description of the issue')
        public String description;

        @InvocableVariable(label='Priority' description='Case priority: Low, Medium, High, Critical')
        public String priority;

        @InvocableVariable(label='Account Id' description='Account to link the case to')
        public Id accountId;

        @InvocableVariable(label='Contact Id' description='Contact to link the case to')
        public Id contactId;
    }

    public class CreateCaseOutput {
        @InvocableVariable(label='Case Id')
        public Id caseId;

        @InvocableVariable(label='Case Number')
        public String caseNumber;

        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Confirmation Message')
        public String confirmationMessage;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // --- Pipeline Summary ---
    public class PipelineSummaryInput {
        @InvocableVariable(label='Owner Id' description='Sales rep User Id to filter pipeline' required=true)
        public Id ownerId;

        @InvocableVariable(label='Days Ahead' description='Number of days ahead for closing soon (default 30)')
        public Integer daysAhead;
    }

    public class PipelineSummaryOutput {
        @InvocableVariable(label='Pipeline Summary')
        public String summary;

        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // --- Update Opportunity Stage ---
    public class UpdateStageInput {
        @InvocableVariable(label='Opportunity Id' description='Salesforce Opportunity record Id' required=true)
        public Id opportunityId;

        @InvocableVariable(label='New Stage' description='Target stage name' required=true)
        public String newStage;
    }

    public class UpdateStageOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Confirmation Message')
        public String confirmationMessage;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // --- Knowledge Search ---
    public class KnowledgeSearchInput {
        @InvocableVariable(label='Search Query' description='Keywords or question to search Knowledge' required=true)
        public String searchQuery;
    }

    public class KnowledgeSearchOutput {
        @InvocableVariable(label='Articles Found Count')
        public Integer articlesFound;

        @InvocableVariable(label='Article List')
        public String articleList;

        @InvocableVariable(label='Summary')
        public String summary;

        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // ─── Exception ────────────────────────────────────────────────────────────

    public class AgentActionException extends Exception {}
}
