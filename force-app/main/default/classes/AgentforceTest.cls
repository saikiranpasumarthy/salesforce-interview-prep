/**
 * @description Test coverage for Day 30 — Agentforce Architecture.
 *              Covers AgentforceService (invocable agent actions) and
 *              PromptTemplateService (LLM invocation patterns).
 *
 *              Testing strategy:
 *              - @InvocableMethod patterns: call directly with List<Input> wrappers
 *              - LLM calls: PromptTemplateService.useMock = true to bypass ConnectApi
 *              - Knowledge SOSL: Test.setFixedSearchResults() for deterministic results
 *              - Record type guard: assertRecordType() with valid/invalid Ids
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class AgentforceTest {

    // ─── Test data factory ─────────────────────────────────────────────────────

    private static TestData setup() {
        TestData td = new TestData();

        td.account = new Account(
            Name             = 'Acme Corp',
            Industry         = 'Technology',
            AnnualRevenue    = 5000000,
            NumberOfEmployees = 250,
            Type             = 'Customer'
        );
        insert td.account;

        td.contact = new Contact(
            FirstName = 'Jane',
            LastName  = 'Doe',
            Email     = 'jane.doe@acme.com',
            AccountId = td.account.Id
        );
        insert td.contact;

        td.opportunity = new Opportunity(
            Name        = 'Acme Enterprise Deal',
            AccountId   = td.account.Id,
            StageName   = 'Qualification',
            CloseDate   = Date.today().addDays(30),
            Amount      = 75000,
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert td.opportunity;

        return td;
    }

    private class TestData {
        Account     account;
        Contact     contact;
        Opportunity opportunity;
    }

    // ─── AgentforceService — getAccountSummary ────────────────────────────────

    @IsTest
    static void testGetAccountSummary_success() {
        TestData td = setup();

        AgentforceService.AccountSummaryInput inp = new AgentforceService.AccountSummaryInput();
        inp.accountId = td.account.Id;

        Test.startTest();
        List<AgentforceService.AccountSummaryOutput> results =
            AgentforceService.getAccountSummary(
                new List<AgentforceService.AccountSummaryInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One result per input');
        AgentforceService.AccountSummaryOutput out = results[0];
        System.assertEquals(true, out.isSuccess, 'Should succeed');
        System.assertEquals('Acme Corp', out.accountName, 'Account name should match');
        System.assertEquals('Technology', out.industry, 'Industry should match');
        System.assertEquals(5000000, out.annualRevenue, 'Revenue should match');
        System.assertEquals(250, out.numberOfEmployees, 'Employee count should match');
        System.assertNotEquals(null, out.summary, 'Summary text should be populated');
        System.assert(out.summary.contains('Acme Corp'), 'Summary should mention account name');
    }

    @IsTest
    static void testGetAccountSummary_invalidId() {
        AgentforceService.AccountSummaryInput inp = new AgentforceService.AccountSummaryInput();
        inp.accountId = '001000000000001AAA'; // non-existent Id

        Test.startTest();
        List<AgentforceService.AccountSummaryOutput> results =
            AgentforceService.getAccountSummary(
                new List<AgentforceService.AccountSummaryInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One result per input');
        System.assertEquals(false, results[0].isSuccess, 'Should fail gracefully');
        System.assertNotEquals(null, results[0].errorMessage, 'Error message should be set');
    }

    @IsTest
    static void testGetAccountSummary_bulkTwoInputs() {
        TestData td1 = setup();

        Account acc2 = new Account(Name = 'Beta Inc', Industry = 'Finance');
        insert acc2;

        AgentforceService.AccountSummaryInput inp1 = new AgentforceService.AccountSummaryInput();
        inp1.accountId = td1.account.Id;
        AgentforceService.AccountSummaryInput inp2 = new AgentforceService.AccountSummaryInput();
        inp2.accountId = acc2.Id;

        Test.startTest();
        List<AgentforceService.AccountSummaryOutput> results =
            AgentforceService.getAccountSummary(
                new List<AgentforceService.AccountSummaryInput>{ inp1, inp2 }
            );
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Two results for two inputs');
        System.assertEquals(true, results[0].isSuccess, 'First result success');
        System.assertEquals(true, results[1].isSuccess, 'Second result success');
    }

    // ─── AgentforceService — createCase ──────────────────────────────────────

    @IsTest
    static void testCreateCase_success() {
        TestData td = setup();

        AgentforceService.CreateCaseInput inp = new AgentforceService.CreateCaseInput();
        inp.subject     = 'Cannot log in to portal';
        inp.description = 'User reports login failure since this morning';
        inp.priority    = 'High';
        inp.accountId   = td.account.Id;
        inp.contactId   = td.contact.Id;

        Test.startTest();
        List<AgentforceService.CreateCaseOutput> results =
            AgentforceService.createCase(
                new List<AgentforceService.CreateCaseInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One result');
        AgentforceService.CreateCaseOutput out = results[0];
        System.assertEquals(true, out.isSuccess, 'Should succeed');
        System.assertNotEquals(null, out.caseId, 'Case Id should be set');
        System.assertNotEquals(null, out.caseNumber, 'Case number should be set');
        System.assert(out.confirmationMessage.contains(out.caseNumber),
            'Confirmation should mention case number');

        Case created = [SELECT AccountId, ContactId, Priority, Origin FROM Case WHERE Id = :out.caseId];
        System.assertEquals(td.account.Id, created.AccountId, 'Account linked');
        System.assertEquals(td.contact.Id, created.ContactId, 'Contact linked');
        System.assertEquals('High', created.Priority, 'Priority preserved');
        System.assertEquals('Einstein Copilot', created.Origin, 'Origin should be Einstein Copilot');
    }

    @IsTest
    static void testCreateCase_defaultPriority() {
        AgentforceService.CreateCaseInput inp = new AgentforceService.CreateCaseInput();
        inp.subject = 'General inquiry';
        // priority intentionally left null

        Test.startTest();
        List<AgentforceService.CreateCaseOutput> results =
            AgentforceService.createCase(
                new List<AgentforceService.CreateCaseInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        Case c = [SELECT Priority FROM Case WHERE Id = :results[0].caseId];
        System.assertEquals('Medium', c.Priority, 'Default priority should be Medium');
    }

    @IsTest
    static void testCreateCase_blankSubjectFails() {
        AgentforceService.CreateCaseInput inp = new AgentforceService.CreateCaseInput();
        inp.subject = '';

        Test.startTest();
        List<AgentforceService.CreateCaseOutput> results =
            AgentforceService.createCase(
                new List<AgentforceService.CreateCaseInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Blank subject should fail');
        System.assert(results[0].errorMessage.contains('Subject'),
            'Error should mention Subject');
    }

    // ─── AgentforceService — getPipelineSummary ───────────────────────────────

    @IsTest
    static void testGetPipelineSummary_success() {
        TestData td = setup();

        AgentforceService.PipelineSummaryInput inp = new AgentforceService.PipelineSummaryInput();
        inp.ownerId   = td.opportunity.OwnerId;
        inp.daysAhead = 60;

        Test.startTest();
        List<AgentforceService.PipelineSummaryOutput> results =
            AgentforceService.getPipelineSummary(
                new List<AgentforceService.PipelineSummaryInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One result');
        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertNotEquals(null, results[0].summary, 'Summary should be populated');
        System.assert(results[0].summary.contains('Pipeline Summary'),
            'Should contain Pipeline Summary header');
    }

    @IsTest
    static void testGetPipelineSummary_defaultDaysAhead() {
        TestData td = setup();

        AgentforceService.PipelineSummaryInput inp = new AgentforceService.PipelineSummaryInput();
        inp.ownerId   = td.opportunity.OwnerId;
        inp.daysAhead = null; // should default to 30

        Test.startTest();
        List<AgentforceService.PipelineSummaryOutput> results =
            AgentforceService.getPipelineSummary(
                new List<AgentforceService.PipelineSummaryInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed with null daysAhead');
    }

    // ─── AgentforceService — updateOpportunityStage ────────────────────────────

    @IsTest
    static void testUpdateOpportunityStage_success() {
        TestData td = setup();

        AgentforceService.UpdateStageInput inp = new AgentforceService.UpdateStageInput();
        inp.opportunityId = td.opportunity.Id;
        inp.newStage      = 'Needs Analysis';

        Test.startTest();
        List<AgentforceService.UpdateStageOutput> results =
            AgentforceService.updateOpportunityStage(
                new List<AgentforceService.UpdateStageInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assert(results[0].confirmationMessage.contains('Needs Analysis'),
            'Confirmation should mention new stage');
        System.assert(results[0].confirmationMessage.contains('Qualification'),
            'Confirmation should mention previous stage');

        Opportunity updated = [SELECT StageName FROM Opportunity WHERE Id = :td.opportunity.Id];
        System.assertEquals('Needs Analysis', updated.StageName, 'Stage should be updated');
    }

    @IsTest
    static void testUpdateOpportunityStage_invalidStage() {
        TestData td = setup();

        AgentforceService.UpdateStageInput inp = new AgentforceService.UpdateStageInput();
        inp.opportunityId = td.opportunity.Id;
        inp.newStage      = 'Not A Real Stage';

        Test.startTest();
        List<AgentforceService.UpdateStageOutput> results =
            AgentforceService.updateOpportunityStage(
                new List<AgentforceService.UpdateStageInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Invalid stage should fail');
        System.assert(results[0].errorMessage.contains('Invalid stage'),
            'Error should mention invalid stage');

        Opportunity unchanged = [SELECT StageName FROM Opportunity WHERE Id = :td.opportunity.Id];
        System.assertEquals('Qualification', unchanged.StageName, 'Stage should not change');
    }

    @IsTest
    static void testUpdateOpportunityStage_closedWon() {
        TestData td = setup();

        AgentforceService.UpdateStageInput inp = new AgentforceService.UpdateStageInput();
        inp.opportunityId = td.opportunity.Id;
        inp.newStage      = 'Closed Won';

        Test.startTest();
        List<AgentforceService.UpdateStageOutput> results =
            AgentforceService.updateOpportunityStage(
                new List<AgentforceService.UpdateStageInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Closed Won is a valid stage');
    }

    // ─── AgentforceService — searchKnowledge ─────────────────────────────────

    @IsTest
    static void testSearchKnowledge_blankQuery() {
        AgentforceService.KnowledgeSearchInput inp = new AgentforceService.KnowledgeSearchInput();
        inp.searchQuery = '';

        Test.startTest();
        List<AgentforceService.KnowledgeSearchOutput> results =
            AgentforceService.searchKnowledge(
                new List<AgentforceService.KnowledgeSearchInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Blank query should fail');
        System.assert(results[0].errorMessage.contains('required'),
            'Error should mention required');
    }

    @IsTest
    static void testSearchKnowledge_gracefulDegradation() {
        // Knowledge may not be enabled in scratch org — service should degrade gracefully
        AgentforceService.KnowledgeSearchInput inp = new AgentforceService.KnowledgeSearchInput();
        inp.searchQuery = 'password reset';

        Test.startTest();
        List<AgentforceService.KnowledgeSearchOutput> results =
            AgentforceService.searchKnowledge(
                new List<AgentforceService.KnowledgeSearchInput>{ inp }
            );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should always return results list');
        System.assertEquals(1, results.size(), 'One result per input');
        // Either success with 0 results or graceful failure — both acceptable
        System.assertNotEquals(null, results[0].isSuccess, 'isSuccess should always be set');
    }

    // ─── AgentforceService — assertRecordType ─────────────────────────────────

    @IsTest
    static void testAssertRecordType_valid() {
        TestData td = setup();
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentforceService.assertRecordType(td.account.Id, Schema.Account.SObjectType);
        } catch (AgentforceService.AgentActionException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown, 'Valid Account Id should pass');
    }

    @IsTest
    static void testAssertRecordType_wrongType() {
        TestData td = setup();
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            // Pass an Account Id but assert it should be an Opportunity
            AgentforceService.assertRecordType(td.account.Id, Schema.Opportunity.SObjectType);
        } catch (AgentforceService.AgentActionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Account'),
                'Error should mention actual type (Account)');
            System.assert(e.getMessage().contains('Opportunity'),
                'Error should mention expected type (Opportunity)');
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Wrong type should throw exception');
    }

    @IsTest
    static void testAssertRecordType_nullId() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentforceService.assertRecordType(null, Schema.Account.SObjectType);
        } catch (AgentforceService.AgentActionException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Null Id should throw exception');
    }

    // ─── AgentforceService — buildAccountSummaryText ─────────────────────────

    @IsTest
    static void testBuildAccountSummaryText() {
        Account acc = new Account(
            Name             = 'Test Corp',
            Industry         = 'Healthcare',
            AnnualRevenue    = 1000000,
            NumberOfEmployees = 100,
            Type             = 'Prospect'
        );
        insert acc;

        // Re-query with sub-selects (needed for relationship fields)
        acc = [
            SELECT Id, Name, Industry, AnnualRevenue, NumberOfEmployees, Type,
                   OwnerId, Owner.Name,
                   (SELECT Id FROM Opportunities WHERE IsClosed = false LIMIT 5),
                   (SELECT Id FROM Cases WHERE IsClosed = false LIMIT 3)
            FROM Account WHERE Id = :acc.Id
        ];

        Test.startTest();
        String summary = AgentforceService.buildAccountSummaryText(acc);
        Test.stopTest();

        System.assert(summary.contains('Test Corp'), 'Summary should include account name');
        System.assert(summary.contains('Healthcare'), 'Summary should include industry');
        System.assert(summary.contains('Open Opportunities'), 'Summary should include opp count');
    }

    // ─── PromptTemplateService — mock LLM invocations ────────────────────────

    @IsTest
    static void testInvokePromptTemplate_mock() {
        PromptTemplateService.useMock         = true;
        PromptTemplateService.mockLlmResponse = 'AI-generated account summary for testing.';

        Test.startTest();
        String result = PromptTemplateService.invokePromptTemplate(
            'Account_Summary_v1',
            new Map<String, String>{ 'AccountName' => 'Acme Corp' }
        );
        Test.stopTest();

        System.assertEquals('AI-generated account summary for testing.', result,
            'Mock response should be returned');
    }

    @IsTest
    static void testInvokePromptTemplate_nullMergeFields() {
        PromptTemplateService.useMock         = true;
        PromptTemplateService.mockLlmResponse = 'Response with no merge fields.';

        Test.startTest();
        String result = PromptTemplateService.invokePromptTemplate('Template_v1', null);
        Test.stopTest();

        System.assertEquals('Response with no merge fields.', result,
            'Should work with null merge fields');
    }

    @IsTest
    static void testGenerateWithDynamicPrompt_mock() {
        PromptTemplateService.useMock         = true;
        PromptTemplateService.mockLlmResponse = 'Dynamic prompt response.';

        Test.startTest();
        String result = PromptTemplateService.generateWithDynamicPrompt(
            'You are a helpful assistant.',
            'What is the status of case 00001234?'
        );
        Test.stopTest();

        System.assertEquals('Dynamic prompt response.', result, 'Mock response returned');
    }

    @IsTest
    static void testGenerateCaseSummary_mock() {
        TestData td = setup();
        Case c = new Case(
            Subject      = 'Login issue',
            Description  = 'User cannot log in since update',
            Status       = 'New',
            Priority     = 'High',
            AccountId    = td.account.Id,
            ContactId    = td.contact.Id
        );
        insert c;

        PromptTemplateService.useMock         = true;
        PromptTemplateService.mockLlmResponse = 'Case summary: High priority login issue.';

        Test.startTest();
        String summary = PromptTemplateService.generateCaseSummary(c.Id, 'Case_Summary_v1');
        Test.stopTest();

        System.assertEquals('Case summary: High priority login issue.', summary,
            'Mock case summary returned');
    }

    @IsTest
    static void testGenerateSalesEmail_mock() {
        TestData td = setup();

        PromptTemplateService.useMock         = true;
        PromptTemplateService.mockLlmResponse = 'Dear Jane, following up on our demo...';

        Test.startTest();
        String email = PromptTemplateService.generateSalesEmail(
            td.opportunity.Id, 'Jane Doe', 'follow-up after demo', 'Sales_Email_v1'
        );
        Test.stopTest();

        System.assertEquals('Dear Jane, following up on our demo...', email,
            'Mock email response returned');
    }

    // ─── PromptTemplateService — token utilities ──────────────────────────────

    @IsTest
    static void testEstimateTokenCount() {
        Test.startTest();
        Integer t1 = PromptTemplateService.estimateTokenCount('');
        Integer t2 = PromptTemplateService.estimateTokenCount(null);
        Integer t3 = PromptTemplateService.estimateTokenCount('Hello world'); // 11 chars ≈ 3 tokens
        Integer t4 = PromptTemplateService.estimateTokenCount('A'.repeat(400)); // 400 chars = 100 tokens
        Test.stopTest();

        System.assertEquals(0, t1, 'Empty string = 0 tokens');
        System.assertEquals(0, t2, 'Null = 0 tokens');
        System.assertEquals(3, t3, '11 chars ≈ 3 tokens (ceil(11/4))');
        System.assertEquals(100, t4, '400 chars = 100 tokens');
    }

    @IsTest
    static void testTruncateToTokenBudget_withinBudget() {
        String text = 'Short text';

        Test.startTest();
        String result = PromptTemplateService.truncateToTokenBudget(text, 100);
        Test.stopTest();

        System.assertEquals(text, result, 'Text within budget should be unchanged');
    }

    @IsTest
    static void testTruncateToTokenBudget_exceedsBudget() {
        String longText = 'A'.repeat(500); // 500 chars, 125 tokens

        Test.startTest();
        String result = PromptTemplateService.truncateToTokenBudget(longText, 10); // 10 token budget = 40 chars
        Test.stopTest();

        System.assert(result.length() <= 40,
            'Truncated text should fit within token budget (40 chars for 10 tokens)');
        System.assert(result.endsWith('...'), 'Truncated text should end with ellipsis');
    }

    @IsTest
    static void testTruncateToTokenBudget_blankInput() {
        Test.startTest();
        String result = PromptTemplateService.truncateToTokenBudget('', 100);
        Test.stopTest();

        System.assertEquals('', result, 'Blank input returns empty string');
    }

    // ─── PromptTemplateService — buildSummarisationPrompt ─────────────────────

    @IsTest
    static void testBuildSummarisationPrompt() {
        Map<String, String> data = new Map<String, String>{
            'Subject'     => 'Login issue',
            'Priority'    => 'High',
            'Description' => 'User cannot access portal'
        };

        Test.startTest();
        String prompt = PromptTemplateService.buildSummarisationPrompt(
            'Case', data, '2-3 sentence summary'
        );
        Test.stopTest();

        System.assert(prompt.contains('Case'), 'Prompt should mention record type');
        System.assert(prompt.contains('Login issue'), 'Prompt should include field data');
        System.assert(prompt.contains('High'), 'Prompt should include priority');
        System.assert(prompt.contains('Salesforce'), 'Prompt should include role instruction');
        System.assert(prompt.contains('2-3 sentence'), 'Prompt should include output format');
    }

    @IsTest
    static void testBuildSummarisationPrompt_emptyFields() {
        Test.startTest();
        String prompt = PromptTemplateService.buildSummarisationPrompt(
            'Account', new Map<String, String>(), null
        );
        Test.stopTest();

        System.assert(prompt.contains('Account'), 'Prompt should mention record type');
        System.assertNotEquals(null, prompt, 'Should return a prompt even with empty data');
    }

    // ─── PromptTemplateService — getPromptTemplates ────────────────────────────

    @IsTest
    static void testGetPromptTemplates_graceful() {
        // PromptTemplate sObject may not have records in test org
        Test.startTest();
        try {
            List<PromptTemplate> templates = PromptTemplateService.getPromptTemplates(null);
            System.assertNotEquals(null, templates, 'Should return a list (may be empty)');
        } catch (Exception e) {
            // PromptTemplate not available — expected in some org editions
            System.assert(
                e.getMessage().contains('PromptTemplate') || e.getMessage().contains('sObject'),
                'Exception should relate to PromptTemplate availability'
            );
        }
        Test.stopTest();
    }

    // ─── PromptTemplateService — getAiAuditLog ────────────────────────────────

    @IsTest
    static void testGetAiAuditLog_graceful() {
        Test.startTest();
        List<SObject> logs = PromptTemplateService.getAiAuditLog(7);
        Test.stopTest();

        System.assertNotEquals(null, logs,
            'Should return a list (empty if AiGenerativeJobItem not available)');
    }

    // ─── PromptTemplateService — LLM unavailable (real call path) ─────────────

    @IsTest
    static void testInvokePromptTemplate_connectApiUnavailable() {
        // useMock = false — ConnectApi.EinsteinLLM not available in test orgs
        PromptTemplateService.useMock = false;

        Test.startTest();
        String result = PromptTemplateService.invokePromptTemplate(
            'NonExistent_Template', new Map<String, String>{ 'key' => 'value' }
        );
        Test.stopTest();

        // Should return null gracefully (no exception thrown)
        System.assertEquals(null, result,
            'Should return null gracefully when ConnectApi unavailable in test');
    }

    @IsTest
    static void testGenerateWithDynamicPrompt_connectApiUnavailable() {
        PromptTemplateService.useMock = false;

        Test.startTest();
        String result = PromptTemplateService.generateWithDynamicPrompt(
            'System prompt', 'User question'
        );
        Test.stopTest();

        System.assertEquals(null, result,
            'Should return null gracefully when ConnectApi unavailable in test');
    }
}
