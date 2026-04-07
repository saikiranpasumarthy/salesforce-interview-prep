/**
 * @description Einstein Copilot customisation — RAG (Retrieval-Augmented Generation)
 *              patterns, grounding, semantic search, action chaining strategies,
 *              agent testing patterns, and Copilot configuration best practices.
 *
 *              RAG PATTERN (interview framework):
 *
 *              User Question
 *                → Retrieve relevant context (SOQL / SOSL / Vector Search)
 *                → Inject context into Prompt Template as merge fields
 *                → LLM generates grounded response (uses retrieved facts, not hallucination)
 *                → Return response to user
 *
 *              RAG vs Fine-tuning:
 *                RAG         — retrieves fresh data at runtime; no model training needed;
 *                              Salesforce-recommended approach for CRM grounding
 *                Fine-tuning — bakes knowledge into model weights; expensive; stale over time
 *
 *              GROUNDING SOURCES:
 *                Knowledge Base     — Articles via SOSL
 *                CRM Records        — SOQL with WITH SECURITY_ENFORCED
 *                Einstein Search    — Salesforce semantic search (SOSL IN ALL FIELDS)
 *                Data Cloud         — Unified profiles for personalisation
 *                External Systems   — HTTP callout (Named Credential)
 *
 *              COPILOT CUSTOMISATION LAYERS:
 *                1. System Instructions  — always-on behaviour rules for all conversations
 *                2. Topic Instructions   — rules specific to a topic
 *                3. Action Descriptions  — guide LLM action selection
 *                4. Output Formatting    — structure outputs for downstream parsing
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class EinsteinCopilotService {

    // ─── RAG: context retrieval ────────────────────────────────────────────────

    /**
     * Retrieves relevant CRM context to ground an LLM response.
     *
     * RAG Retrieval Pattern:
     *   1. Identify entities from user query (account name, case number, product)
     *   2. Query CRM for matching records (SOSL full-text or SOQL by Id)
     *   3. Serialise results into structured text
     *   4. Inject into Prompt Template via merge fields
     *   5. LLM generates response grounded in retrieved facts
     *
     * Interview: Why RAG instead of passing all data to LLM?
     *   - Context window limits (can't pass entire Salesforce org)
     *   - Cost — more tokens = higher cost per LLM call
     *   - Latency — smaller prompts respond faster
     *   - Relevance — irrelevant context degrades response quality
     *
     * @param userQuery    The user's natural language question
     * @param contextTypes Which context sources to query ('account','case','knowledge')
     * @return             Grounded context string for prompt injection
     */
    @InvocableMethod(
        label       = 'Retrieve RAG Context'
        description = 'Retrieves relevant CRM context to ground an AI response. '
                    + 'Searches accounts, cases, and Knowledge articles matching the query. '
                    + 'Returns a structured context string for use in a Prompt Template. '
                    + 'Use before generating any response that requires CRM data.'
        category    = 'Agent Utilities'
    )
    public static List<RagContextOutput> retrieveRagContext(List<RagContextInput> inputs) {
        List<RagContextOutput> results = new List<RagContextOutput>();

        for (RagContextInput inp : inputs) {
            RagContextOutput out = new RagContextOutput();
            try {
                List<String> contextParts = new List<String>();

                // Query relevant accounts
                if (inp.includeAccounts && String.isNotBlank(inp.userQuery)) {
                    List<Account> accounts = searchRelevantAccounts(inp.userQuery, 3);
                    if (!accounts.isEmpty()) {
                        contextParts.add(formatAccountContext(accounts));
                    }
                }

                // Query relevant cases
                if (inp.includeCases && String.isNotBlank(inp.userQuery)) {
                    List<Case> cases = searchRelevantCases(inp.userQuery, 3);
                    if (!cases.isEmpty()) {
                        contextParts.add(formatCaseContext(cases));
                    }
                }

                // Query Knowledge articles
                if (inp.includeKnowledge && String.isNotBlank(inp.userQuery)) {
                    List<String> articles = searchKnowledgeContext(inp.userQuery, 5);
                    if (!articles.isEmpty()) {
                        contextParts.add('Knowledge Articles:\n' + String.join(articles, '\n'));
                    }
                }

                out.contextText   = contextParts.isEmpty()
                    ? 'No relevant context found for: ' + inp.userQuery
                    : String.join(contextParts, '\n\n');
                out.contextLength = out.contextText.length();
                out.isSuccess     = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'RAG retrieval failed: ' + e.getMessage();
                out.contextText  = '';
            }
            results.add(out);
        }
        return results;
    }

    // ─── Semantic search ──────────────────────────────────────────────────────

    /**
     * Performs semantic search across multiple Salesforce objects using SOSL.
     *
     * Interview: SOSL vs SOQL for agent actions:
     *   SOSL — cross-object full-text search; returns records from multiple objects
     *          in one query; ideal for "find anything related to X" queries
     *   SOQL — structured, targeted; use when you know the object and filter criteria
     *
     *   SOSL IN ALL FIELDS      — searches all indexed text fields
     *   SOSL IN NAME FIELDS     — searches only Name/Title fields (faster)
     *   SOSL IN EMAIL FIELDS    — searches email fields only
     *
     * @param searchTerm   Term to search across CRM
     * @param maxPerObject Max results per object type
     * @return             Structured search results
     */
    @InvocableMethod(
        label       = 'Semantic CRM Search'
        description = 'Searches across Accounts, Contacts, Cases, and Opportunities '
                    + 'using full-text SOSL search. Returns matching records from all objects. '
                    + 'Use when the user references a name, number, or term that could be '
                    + 'in any part of Salesforce.'
        category    = 'Search'
    )
    public static List<SemanticSearchOutput> semanticSearch(List<SemanticSearchInput> inputs) {
        List<SemanticSearchOutput> results = new List<SemanticSearchOutput>();

        for (SemanticSearchInput inp : inputs) {
            SemanticSearchOutput out = new SemanticSearchOutput();
            try {
                if (String.isBlank(inp.searchTerm)) {
                    out.isSuccess    = false;
                    out.errorMessage = 'Search term is required.';
                    results.add(out);
                    continue;
                }

                Integer maxPer = inp.maxPerObject != null ? Math.min(inp.maxPerObject, 10) : 5;

                // SOSL cross-object search
                List<List<SObject>> searchResults = Search.query(
                    'FIND :inp.searchTerm IN ALL FIELDS '
                    + 'RETURNING '
                    + 'Account(Id, Name, Industry, Type), '
                    + 'Contact(Id, FirstName, LastName, Email, Title, Account.Name), '
                    + 'Case(Id, CaseNumber, Subject, Status, Account.Name), '
                    + 'Opportunity(Id, Name, StageName, Amount, Account.Name) '
                    + 'LIMIT ' + (maxPer * 4)
                );

                List<String> summaryParts = new List<String>();
                Integer totalFound = 0;

                String[] objectNames = new String[]{ 'Accounts', 'Contacts', 'Cases', 'Opportunities' };
                for (Integer i = 0; i < searchResults.size(); i++) {
                    List<SObject> objs = searchResults[i];
                    if (!objs.isEmpty()) {
                        totalFound += objs.size();
                        summaryParts.add(objectNames[i] + ' (' + objs.size() + '):');
                        for (SObject obj : objs) {
                            summaryParts.add('  • ' + formatSObjectSummary(obj));
                        }
                    }
                }

                out.totalFound   = totalFound;
                out.searchSummary = totalFound > 0
                    ? 'Found ' + totalFound + ' result(s) for "' + inp.searchTerm + '":\n'
                        + String.join(summaryParts, '\n')
                    : 'No results found for "' + inp.searchTerm + '".';
                out.isSuccess    = true;

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Search failed: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Action chaining coordinator ──────────────────────────────────────────

    /**
     * Demonstrates the coordinator action pattern: a single action that orchestrates
     * a multi-step workflow, hiding complexity from the LLM.
     *
     * Interview: Two strategies for multi-step agent workflows:
     *
     *   LLM-driven chaining (ReAct pattern):
     *     - Separate atomic actions; LLM decides which to call and in what order
     *     - More flexible but less predictable
     *     - Risk: LLM may skip steps or call in wrong order
     *     - Best for: exploratory tasks where sequence depends on results
     *
     *   Coordinator action (this pattern):
     *     - One action encapsulates all steps; deterministic sequence
     *     - LLM calls one action; Apex handles orchestration internally
     *     - Best for: fixed-sequence workflows (e.g. "qualify + assign + notify")
     *
     * @param inputs  Qualification request for a new lead/account
     * @return        Complete qualification result with all steps
     */
    @InvocableMethod(
        label       = 'Qualify and Assign Account'
        description = 'Runs the full account qualification workflow: '
                    + 'checks eligibility criteria, sets account tier, assigns to sales rep, '
                    + 'and creates a follow-up task. Returns a summary of all steps taken. '
                    + 'Use when a new account needs to be qualified and routed.'
        category    = 'Sales'
    )
    public static List<QualificationOutput> qualifyAndAssign(
            List<QualificationInput> inputs) {

        List<QualificationOutput> results = new List<QualificationOutput>();

        for (QualificationInput inp : inputs) {
            QualificationOutput out = new QualificationOutput();
            List<String> steps = new List<String>();

            try {
                Account acc = [
                    SELECT Id, Name, AnnualRevenue, NumberOfEmployees, Industry,
                           Rating, OwnerId
                    FROM   Account
                    WHERE  Id = :inp.accountId
                    WITH   SECURITY_ENFORCED
                ];

                // Step 1: Determine tier
                String tier = determineTier(acc.AnnualRevenue, acc.NumberOfEmployees);
                acc.Rating = tier;
                steps.add('Step 1: Tier determined — ' + tier);

                // Step 2: Set account type based on industry
                if (String.isNotBlank(inp.targetIndustry)
                        && acc.Industry != inp.targetIndustry) {
                    acc.Industry = inp.targetIndustry;
                    steps.add('Step 2: Industry updated to ' + inp.targetIndustry);
                } else {
                    steps.add('Step 2: Industry unchanged (' + acc.Industry + ')');
                }

                update acc;

                // Step 3: Create follow-up task
                Task followUp = new Task(
                    WhatId      = acc.Id,
                    Subject     = 'Qualification follow-up: ' + acc.Name,
                    Priority    = tier == 'Hot' ? 'High' : 'Normal',
                    Status      = 'Not Started',
                    ActivityDate = Date.today().addDays(tier == 'Hot' ? 1 : 5),
                    Description  = 'Account qualified by Agentforce. Tier: ' + tier
                );
                if (inp.assignToUserId != null) { followUp.OwnerId = inp.assignToUserId; }
                insert followUp;
                steps.add('Step 3: Follow-up task created (due '
                    + followUp.ActivityDate.format() + ')');

                out.accountTier      = tier;
                out.taskId           = followUp.Id;
                out.stepsSummary     = String.join(steps, '\n');
                out.isSuccess        = true;
                out.confirmationMessage = 'Account "' + acc.Name + '" qualified as ' + tier
                    + '. Follow-up task created.';

            } catch (Exception e) {
                out.isSuccess    = false;
                out.errorMessage = 'Qualification failed: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    // ─── Copilot configuration introspection ──────────────────────────────────

    /**
     * Returns the currently active Agents in the org.
     *
     * Interview: BotDefinition sObject represents an Einstein Bot/Copilot configuration.
     * Fields: DeveloperName, MasterLabel, Status ('Active'/'Inactive'), Type.
     * BotVersion — represents a specific version of the bot configuration.
     *
     * @return List of active BotDefinition records
     */
    public static List<SObject> getActiveAgents() {
        try {
            return Database.query(
                'SELECT Id, DeveloperName, MasterLabel, Status, Type ' +
                'FROM   BotDefinition ' +
                'WHERE  Status = \'Active\' ' +
                'ORDER BY MasterLabel ASC'
            );
        } catch (System.QueryException e) {
            System.debug(LoggingLevel.WARN, 'BotDefinition not available: ' + e.getMessage());
            return new List<SObject>();
        }
    }

    /**
     * Returns available Agent Topics for a given bot.
     *
     * @param botId  BotDefinition Id
     */
    public static List<SObject> getAgentTopics(Id botId) {
        try {
            return Database.query(
                'SELECT Id, DeveloperName, MasterLabel, Description ' +
                'FROM   BotTopic ' +
                'WHERE  BotDefinitionId = :botId ' +
                'ORDER BY MasterLabel ASC'
            );
        } catch (System.QueryException e) {
            System.debug(LoggingLevel.WARN, 'BotTopic not available: ' + e.getMessage());
            return new List<SObject>();
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    @TestVisible
    static List<Account> searchRelevantAccounts(String query, Integer maxResults) {
        try {
            List<List<SObject>> results = Search.query(
                'FIND :query IN NAME FIELDS RETURNING Account(Id, Name, Industry, Type) '
                + 'LIMIT ' + maxResults
            );
            return (List<Account>) results[0];
        } catch (Exception e) {
            return new List<Account>();
        }
    }

    @TestVisible
    static List<Case> searchRelevantCases(String query, Integer maxResults) {
        try {
            List<List<SObject>> results = Search.query(
                'FIND :query IN ALL FIELDS '
                + 'RETURNING Case(Id, CaseNumber, Subject, Status, Priority) '
                + 'LIMIT ' + maxResults
            );
            return (List<Case>) results[0];
        } catch (Exception e) {
            return new List<Case>();
        }
    }

    @TestVisible
    static List<String> searchKnowledgeContext(String query, Integer maxResults) {
        try {
            List<List<SObject>> results = Search.query(
                'FIND :query IN ALL FIELDS '
                + 'RETURNING Knowledge__kav(Id, Title, Summary '
                + 'WHERE PublishStatus = \'Online\') '
                + 'LIMIT ' + maxResults
            );
            List<String> summaries = new List<String>();
            for (SObject art : results[0]) {
                String title   = (String) art.get('Title');
                String summary = (String) art.get('Summary');
                summaries.add('• ' + title + (String.isNotBlank(summary) ? ': ' + summary : ''));
            }
            return summaries;
        } catch (Exception e) {
            return new List<String>();
        }
    }

    @TestVisible
    static String formatAccountContext(List<Account> accounts) {
        List<String> lines = new List<String>{ 'Relevant Accounts:' };
        for (Account a : accounts) {
            lines.add('  • ' + a.Name
                + (a.Industry != null ? ' (' + a.Industry + ')' : '')
                + (a.Type     != null ? ' [' + a.Type + ']' : ''));
        }
        return String.join(lines, '\n');
    }

    @TestVisible
    static String formatCaseContext(List<Case> cases) {
        List<String> lines = new List<String>{ 'Related Cases:' };
        for (Case c : cases) {
            lines.add('  • Case ' + c.CaseNumber + ': ' + c.Subject
                + ' [' + c.Status + ', ' + c.Priority + ']');
        }
        return String.join(lines, '\n');
    }

    @TestVisible
    static String formatSObjectSummary(SObject obj) {
        String type = obj.getSObjectType().getDescribe().getName();
        if (type == 'Account') {
            return (String) obj.get('Name') + ' (Account)';
        } else if (type == 'Contact') {
            String name = (String) obj.get('FirstName') + ' ' + (String) obj.get('LastName');
            return name.trim() + ' (Contact)';
        } else if (type == 'Case') {
            return 'Case ' + (String) obj.get('CaseNumber') + ': ' + (String) obj.get('Subject');
        } else if (type == 'Opportunity') {
            return (String) obj.get('Name') + ' — ' + (String) obj.get('StageName') + ' (Opp)';
        }
        return obj.getId();
    }

    @TestVisible
    static String determineTier(Decimal annualRevenue, Integer employees) {
        if ((annualRevenue != null && annualRevenue >= 10000000)
                || (employees != null && employees >= 500)) {
            return 'Hot';
        }
        if ((annualRevenue != null && annualRevenue >= 1000000)
                || (employees != null && employees >= 100)) {
            return 'Warm';
        }
        return 'Cold';
    }

    // ─── Input / Output DTOs ──────────────────────────────────────────────────

    // RAG context
    public class RagContextInput {
        @InvocableVariable(label='User Query' required=true)
        public String userQuery;
        @InvocableVariable(label='Include Accounts')
        public Boolean includeAccounts;
        @InvocableVariable(label='Include Cases')
        public Boolean includeCases;
        @InvocableVariable(label='Include Knowledge')
        public Boolean includeKnowledge;
    }
    public class RagContextOutput {
        @InvocableVariable(label='Context Text')
        public String contextText;
        @InvocableVariable(label='Context Character Length')
        public Integer contextLength;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Semantic search
    public class SemanticSearchInput {
        @InvocableVariable(label='Search Term' required=true)
        public String searchTerm;
        @InvocableVariable(label='Max Results Per Object')
        public Integer maxPerObject;
    }
    public class SemanticSearchOutput {
        @InvocableVariable(label='Total Found')
        public Integer totalFound;
        @InvocableVariable(label='Search Summary')
        public String searchSummary;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // Qualification
    public class QualificationInput {
        @InvocableVariable(label='Account Id' required=true)
        public Id accountId;
        @InvocableVariable(label='Target Industry')
        public String targetIndustry;
        @InvocableVariable(label='Assign To User Id')
        public Id assignToUserId;
    }
    public class QualificationOutput {
        @InvocableVariable(label='Account Tier')
        public String accountTier;
        @InvocableVariable(label='Task Id')
        public Id taskId;
        @InvocableVariable(label='Steps Summary')
        public String stepsSummary;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Confirmation Message')
        public String confirmationMessage;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
}
