/**
 * @description Prompt Templates, Einstein LLM APIs, and AI-powered text generation
 *              patterns for Agentforce and Einstein Generative AI features.
 *
 *              PROMPT TEMPLATE TYPES (interview framework):
 *
 *              Sales Email Template    — generates personalised outreach emails
 *              Field Generation        — populates a single record field via AI
 *              Flex Template           — general-purpose, callable from Apex/Flow/Agent
 *              Record Summary          — summarises a record into natural language
 *
 *              EINSTEIN LLM APEX APIS:
 *
 *              ConnectApi.EinsteinLLM
 *                .generateMessages()   — invoke LLM with a prompt, returns generated text
 *                .generateMessagesExt()— extended version with additional parameters
 *
 *              ConnectApi.EinsteinLLMGenerationInput
 *                .promptTemplate       — template API name or dynamic prompt text
 *                .additionalParameters — Map<String,ConnectApi.WrappedValue> merge fields
 *                .numGenerations       — number of candidate responses (default 1)
 *
 *              ConnectApi.EinsteinLLMGenerationOutput
 *                .generations          — List<ConnectApi.EinsteinLLMGeneration>
 *                  .text               — generated text content
 *                  .id                 — generation Id
 *                  .parameters         — model parameters used
 *
 *              PROMPT TEMPLATE MERGE FIELDS:
 *                {!$Input.fieldName}    — input variables passed at invocation time
 *                {!$Record.fieldName}   — fields from the context record
 *                {!$User.Name}          — running user fields
 *                {!$Organisation.Name}  — org fields
 *
 *              KEY RULES:
 *                - ConnectApi calls count toward callout governor limits (100/tx)
 *                - Cannot call ConnectApi from Batch Apex execute() or @future
 *                - Prompt Templates stored as Metadata (PromptTemplate sObject)
 *                - Token limits: GPT-4 ~8k tokens; Claude ~100k; model-dependent
 *                - Einstein Trust Layer: all LLM calls go through Salesforce Trust Layer
 *                  (data masking, toxicity filter, audit log — no data sent to model directly)
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class PromptTemplateService {

    // Allow test injection of LLM responses
    @TestVisible static Boolean useMock         = false;
    @TestVisible static String  mockLlmResponse = 'Mocked AI response for testing.';

    // ─── Prompt Template invocation ───────────────────────────────────────────

    /**
     * Invokes a stored Prompt Template by its developer name, passing merge field values.
     *
     * Interview: Prompt Templates are metadata records (PromptTemplate sObject).
     * They are authored in Setup → Einstein → Prompt Builder.
     * The merge field map keys must match the {!$Input.xxx} placeholders in the template.
     *
     * Einstein Trust Layer ensures:
     *   - PII/sensitive data is masked before leaving Salesforce
     *   - Response is scanned for toxicity before returned to user
     *   - All calls are logged in Einstein Generative AI Audit Log
     *
     * @param templateApiName  Developer name of the PromptTemplate (e.g. 'Account_Summary_v1')
     * @param mergeFields      Map of {inputVariableName → value} to substitute in template
     * @return                 Generated text from the LLM; null if generation fails
     */
    public static String invokePromptTemplate(
            String templateApiName, Map<String, String> mergeFields) {

        if (useMock) { return mockLlmResponse; }

        try {
            ConnectApi.EinsteinLLMGenerationInput input =
                new ConnectApi.EinsteinLLMGenerationInput();
            input.promptTemplateDeveloperName = templateApiName;

            if (mergeFields != null && !mergeFields.isEmpty()) {
                Map<String, ConnectApi.WrappedValue> params =
                    new Map<String, ConnectApi.WrappedValue>();
                for (String key : mergeFields.keySet()) {
                    ConnectApi.WrappedValue val = new ConnectApi.WrappedValue();
                    val.value = mergeFields.get(key);
                    params.put(key, val);
                }
                input.additionalParameters = params;
            }

            ConnectApi.EinsteinLLMGenerationOutput output =
                ConnectApi.EinsteinLLM.generateMessages(input);

            if (output != null && !output.generations.isEmpty()) {
                return output.generations[0].text;
            }
            return null;

        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'PromptTemplate invocation failed [' + templateApiName + ']: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Invokes the LLM with a dynamically constructed prompt (no stored template).
     *
     * Interview: Dynamic prompts are used when the prompt text varies at runtime.
     * Prefer stored Prompt Templates when possible — they are versionable, auditable,
     * and can be edited by admins without code deployments.
     *
     * Dynamic prompts bypass some Trust Layer masking — validate inputs carefully.
     *
     * @param systemPrompt    Instructions for how the model should behave
     * @param userPrompt      The actual user request / content to process
     * @return                Generated text; null if LLM unavailable
     */
    public static String generateWithDynamicPrompt(String systemPrompt, String userPrompt) {
        if (useMock) { return mockLlmResponse; }

        try {
            ConnectApi.EinsteinLLMGenerationInput input =
                new ConnectApi.EinsteinLLMGenerationInput();

            // Build a simple prompt by combining system + user context
            // In production use ConnectApi.EinsteinLLMChatGenerationInput for chat-style
            Map<String, ConnectApi.WrappedValue> params =
                new Map<String, ConnectApi.WrappedValue>();

            ConnectApi.WrappedValue sysVal = new ConnectApi.WrappedValue();
            sysVal.value = String.isBlank(systemPrompt)
                ? 'You are a helpful Salesforce assistant.' : systemPrompt;
            params.put('systemPrompt', sysVal);

            ConnectApi.WrappedValue userVal = new ConnectApi.WrappedValue();
            userVal.value = userPrompt;
            params.put('userPrompt', userVal);

            input.additionalParameters = params;

            ConnectApi.EinsteinLLMGenerationOutput output =
                ConnectApi.EinsteinLLM.generateMessages(input);

            return (output != null && !output.generations.isEmpty())
                ? output.generations[0].text : null;

        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Dynamic LLM call failed: ' + e.getMessage());
            return null;
        }
    }

    // ─── Record summarisation ─────────────────────────────────────────────────

    /**
     * Generates an AI summary for a Case using a Prompt Template.
     *
     * Pattern: Field Generation template — result written back to a rich-text field
     * (e.g. Case.AI_Summary__c) for agent display or email composition.
     *
     * Interview: Field Generation templates are triggered by a button ("Generate")
     * or automatically on record save. They update a single target field.
     * The template references {!$Record.fieldName} — Salesforce injects field values.
     *
     * @param caseId           Case to summarise
     * @param templateApiName  Field Generation template developer name
     * @return                 AI-generated summary text; null if unavailable
     */
    public static String generateCaseSummary(Id caseId, String templateApiName) {
        Case c = [
            SELECT Id, CaseNumber, Subject, Description, Status, Priority,
                   Account.Name, Contact.Name, CreatedDate
            FROM   Case
            WHERE  Id = :caseId
            WITH   SECURITY_ENFORCED
        ];

        Map<String, String> mergeFields = new Map<String, String>{
            'CaseNumber'   => c.CaseNumber,
            'Subject'      => c.Subject,
            'Description'  => c.Description,
            'Status'       => c.Status,
            'Priority'     => c.Priority,
            'AccountName'  => c.Account != null ? c.Account.Name : '',
            'ContactName'  => c.Contact != null ? c.Contact.Name : '',
            'CreatedDate'  => String.valueOf(c.CreatedDate)
        };

        return invokePromptTemplate(templateApiName, mergeFields);
    }

    /**
     * Generates a personalised sales email for an Opportunity using the LLM.
     *
     * Interview: Sales Email templates are the most common Agentforce use case.
     * They pull in Account, Contact, and Opportunity context automatically
     * when configured as Sales Email type in Prompt Builder.
     *
     * @param opportunityId    Opportunity context for email
     * @param recipientName    Name of the email recipient
     * @param emailObjective   Instruction for tone/goal (e.g. 'follow-up after demo')
     * @param templateApiName  Sales Email Prompt Template developer name
     * @return                 AI-generated email body
     */
    public static String generateSalesEmail(
            Id opportunityId, String recipientName,
            String emailObjective, String templateApiName) {

        Opportunity opp = [
            SELECT Id, Name, StageName, Amount, CloseDate,
                   Account.Name, Account.Industry
            FROM   Opportunity
            WHERE  Id = :opportunityId
            WITH   SECURITY_ENFORCED
        ];

        Map<String, String> mergeFields = new Map<String, String>{
            'RecipientName'    => recipientName,
            'OpportunityName'  => opp.Name,
            'AccountName'      => opp.Account.Name,
            'Industry'         => opp.Account.Industry,
            'Stage'            => opp.StageName,
            'Amount'           => opp.Amount != null ? '$' + opp.Amount.format() : '',
            'CloseDate'        => opp.CloseDate != null ? opp.CloseDate.format() : '',
            'EmailObjective'   => emailObjective,
            'SenderName'       => UserInfo.getName()
        };

        return invokePromptTemplate(templateApiName, mergeFields);
    }

    // ─── Prompt Template metadata queries ─────────────────────────────────────

    /**
     * Returns all active Prompt Templates of a given type.
     *
     * Interview: PromptTemplate is a standard sObject (queryable via SOQL).
     * Type values: 'sales_email', 'field_generation', 'flex'
     * Status: 'Published' = active, 'Draft' = not yet usable
     *
     * @param templateType  Filter by template type; null returns all
     */
    public static List<PromptTemplate> getPromptTemplates(String templateType) {
        if (String.isBlank(templateType)) {
            return [
                SELECT Id, DeveloperName, MasterLabel, TemplateType,
                       Description, LastModifiedDate
                FROM   PromptTemplate
                WHERE  Status = 'Published'
                ORDER BY MasterLabel ASC
            ];
        }
        return [
            SELECT Id, DeveloperName, MasterLabel, TemplateType,
                   Description, LastModifiedDate
            FROM   PromptTemplate
            WHERE  Status       = 'Published'
              AND  TemplateType = :templateType
            ORDER BY MasterLabel ASC
        ];
    }

    // ─── Token estimation ─────────────────────────────────────────────────────

    /**
     * Estimates the token count for a prompt string.
     * Approximation: ~4 characters per token (OpenAI GPT average).
     *
     * Interview: Token limits are a critical LLM constraint.
     * GPT-4: ~8,192 tokens context window (32k / 128k extended)
     * Claude 3: ~200,000 tokens
     * Einstein uses a Trust Layer proxy — limits may be lower than raw model limits.
     *
     * Best practice: keep prompts under 2,000 tokens to leave room for the response.
     *
     * @param promptText  The prompt string to estimate
     * @return            Estimated token count
     */
    @TestVisible
    static Integer estimateTokenCount(String promptText) {
        if (String.isBlank(promptText)) { return 0; }
        return (Integer) Math.ceil(promptText.length() / 4.0);
    }

    /**
     * Truncates a text input to fit within a token budget.
     * Used to prevent context window overflows when injecting long record descriptions.
     *
     * @param text        Input text to truncate
     * @param maxTokens   Token budget for this input
     * @return            Truncated text safe for the token budget
     */
    @TestVisible
    static String truncateToTokenBudget(String text, Integer maxTokens) {
        if (String.isBlank(text)) { return ''; }
        Integer maxChars = maxTokens * 4; // ~4 chars per token
        if (text.length() <= maxChars) { return text; }
        return text.left(maxChars - 3) + '...'; // reserve 3 chars for ellipsis
    }

    // ─── Prompt construction helpers ──────────────────────────────────────────

    /**
     * Builds a structured prompt string for record summarisation.
     * Used with generateWithDynamicPrompt() when no stored template exists.
     *
     * Best practice prompt structure (RISEN framework):
     *   Role        — who the AI should act as
     *   Instructions — what to do
     *   Steps       — how to do it
     *   End Goal    — the desired output format
     *   Narrowing   — constraints / guardrails
     *
     * @param recordType   Type of record being summarised (e.g. 'Case', 'Account')
     * @param recordData   Key-value pairs of field name → value
     * @param outputFormat Desired output format description
     * @return             Structured prompt string
     */
    @TestVisible
    static String buildSummarisationPrompt(
            String recordType, Map<String, String> recordData, String outputFormat) {

        List<String> fieldLines = new List<String>();
        if (recordData != null) {
            for (String field : recordData.keySet()) {
                String val = recordData.get(field);
                if (String.isNotBlank(val)) {
                    fieldLines.add(field + ': ' + val);
                }
            }
        }

        String roleInstr = 'You are a Salesforce CRM assistant helping a sales/service professional.';
        String task      = 'Summarise the following ' + recordType + ' record concisely.';
        String data      = String.join(fieldLines, '\n');
        String format    = String.isBlank(outputFormat)
            ? 'Provide a 2-3 sentence summary suitable for display in a Salesforce record page.'
            : outputFormat;
        String constraint = 'Only use the information provided. Do not fabricate details. '
            + 'If a field is empty, ignore it.';

        return roleInstr + '\n\n'
            + task + '\n\n'
            + 'Record data:\n' + data + '\n\n'
            + 'Output format: ' + format + '\n\n'
            + 'Constraints: ' + constraint;
    }

    // ─── Audit / Trust Layer ──────────────────────────────────────────────────

    /**
     * Returns recent Einstein Generative AI usage logs.
     * Used for auditing LLM calls — who invoked what template, when.
     *
     * Interview: Einstein Trust Layer captures:
     *   - Prompt text sent (after masking)
     *   - Response received
     *   - Model used
     *   - Token counts (input + output)
     *   - User who triggered the call
     *   Accessible via: Setup > Einstein > Generative AI Audit Log
     *   Also queryable via sObject: AiGenerativeJobItem (limited availability)
     *
     * @param daysBack  How many days of history to retrieve
     */
    public static List<SObject> getAiAuditLog(Integer daysBack) {
        Integer days = daysBack != null ? Math.min(daysBack, 30) : 7;
        DateTime since = DateTime.now().addDays(-days);
        try {
            return Database.query(
                'SELECT Id, CreatedDate, CreatedById, CreatedBy.Name, ' +
                '       ModelName__c, InputTokenCount__c, OutputTokenCount__c, ' +
                '       PromptTemplateName__c ' +
                'FROM   AiGenerativeJobItem ' +
                'WHERE  CreatedDate >= :since ' +
                'ORDER BY CreatedDate DESC ' +
                'LIMIT 200'
            );
        } catch (System.QueryException e) {
            // AiGenerativeJobItem not available in this org
            System.debug(LoggingLevel.WARN, 'AI audit log unavailable: ' + e.getMessage());
            return new List<SObject>();
        }
    }
}
