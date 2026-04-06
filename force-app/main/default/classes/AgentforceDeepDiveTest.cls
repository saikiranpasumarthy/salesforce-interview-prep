/**
 * @description Test coverage for Day 31 — Agentforce Deep Dive.
 *              Covers AgentConversationService and EinsteinCopilotService.
 *
 *              Testing strategy:
 *              - Platform Cache: PlatformCacheService.useMock = true (auto-set via Test.isRunningTest())
 *              - Callout actions: Mock HttpCalloutMock for enrichAccountData
 *              - SOSL: Test.setFixedSearchResults() for deterministic search
 *              - Autonomous actions: direct invocation with test Case records
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class AgentforceDeepDiveTest {

    // ─── Test data setup ──────────────────────────────────────────────────────

    private static TestData setup() {
        TestData td = new TestData();

        td.account = new Account(
            Name             = 'Deep Dive Corp',
            Industry         = 'Technology',
            AnnualRevenue    = 8000000,
            NumberOfEmployees = 400,
            Type             = 'Customer'
        );
        insert td.account;

        td.contact = new Contact(
            FirstName = 'Alex',
            LastName  = 'Smith',
            Email     = 'alex.smith@deepdive.com',
            AccountId = td.account.Id
        );
        insert td.contact;

        td.theCase = new Case(
            Subject     = 'Integration failing since deployment',
            Description = 'The API integration stopped working after the update. '
                        + 'I am frustrated and need this resolved immediately.',
            Priority    = 'Medium',
            Status      = 'New',
            AccountId   = td.account.Id,
            ContactId   = td.contact.Id
        );
        insert td.theCase;

        return td;
    }

    private class TestData {
        Account account;
        Contact contact;
        Case    theCase;
    }

    // ─── AgentConversationService — saveConversationContext ───────────────────

    @IsTest
    static void testSaveConversationContext_success() {
        AgentConversationService.ContextSaveInput inp =
            new AgentConversationService.ContextSaveInput();
        inp.sessionId    = 'test-session-001';
        inp.contextKey   = 'lastAccountId';
        inp.contextValue = '001xx0000000001';

        Test.startTest();
        List<AgentConversationService.ContextSaveOutput> results =
            AgentConversationService.saveConversationContext(
                new List<AgentConversationService.ContextSaveInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One result');
        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assert(results[0].confirmationMessage.contains('lastAccountId'),
            'Confirmation should mention the key');
    }

    @IsTest
    static void testSaveConversationContext_blankSessionId() {
        AgentConversationService.ContextSaveInput inp =
            new AgentConversationService.ContextSaveInput();
        inp.sessionId  = '';
        inp.contextKey = 'someKey';

        Test.startTest();
        List<AgentConversationService.ContextSaveOutput> results =
            AgentConversationService.saveConversationContext(
                new List<AgentConversationService.ContextSaveInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Blank sessionId should fail');
    }

    // ─── AgentConversationService — getConversationContext ────────────────────

    @IsTest
    static void testGetConversationContext_notFound() {
        AgentConversationService.ContextGetInput inp =
            new AgentConversationService.ContextGetInput();
        inp.sessionId  = 'test-session-999';
        inp.contextKey = 'nonExistentKey';

        Test.startTest();
        List<AgentConversationService.ContextGetOutput> results =
            AgentConversationService.getConversationContext(
                new List<AgentConversationService.ContextGetInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed even when not found');
        System.assertEquals(false, results[0].found, 'Key should not be found');
        System.assertEquals(null, results[0].contextValue, 'Value should be null');
    }

    @IsTest
    static void testSaveAndGetConversationContext_roundTrip() {
        // Save then retrieve
        AgentConversationService.ContextSaveInput saveInp =
            new AgentConversationService.ContextSaveInput();
        saveInp.sessionId    = 'test-session-round-trip';
        saveInp.contextKey   = 'preferredLanguage';
        saveInp.contextValue = 'en_US';

        Test.startTest();
        AgentConversationService.saveConversationContext(
            new List<AgentConversationService.ContextSaveInput>{ saveInp }
        );

        AgentConversationService.ContextGetInput getInp =
            new AgentConversationService.ContextGetInput();
        getInp.sessionId  = 'test-session-round-trip';
        getInp.contextKey = 'preferredLanguage';

        List<AgentConversationService.ContextGetOutput> results =
            AgentConversationService.getConversationContext(
                new List<AgentConversationService.ContextGetInput>{ getInp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Get should succeed');
        System.assertEquals(true, results[0].found, 'Key should be found after save');
        System.assertEquals('en_US', results[0].contextValue, 'Value should match saved value');
    }

    // ─── AgentConversationService — escalateToHuman ───────────────────────────

    @IsTest
    static void testEscalateToHuman_createNewCase() {
        TestData td = setup();

        AgentConversationService.EscalationInput inp =
            new AgentConversationService.EscalationInput();
        inp.subject             = 'Urgent billing issue';
        inp.conversationSummary = 'Customer unable to access account after payment';
        inp.escalationReason    = 'Customer requested human agent';
        inp.priority            = 'High';
        inp.accountId           = td.account.Id;
        inp.contactId           = td.contact.Id;

        Test.startTest();
        List<AgentConversationService.EscalationOutput> results =
            AgentConversationService.escalateToHuman(
                new List<AgentConversationService.EscalationInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertNotEquals(null, results[0].caseId, 'Case should be created');
        System.assert(results[0].confirmationMessage.contains('human agent'),
            'Confirmation should mention human agent');

        Case created = [SELECT Priority, Origin, AccountId FROM Case WHERE Id = :results[0].caseId];
        System.assertEquals('High', created.Priority, 'Priority should be High');
        System.assertEquals('Einstein Copilot', created.Origin, 'Origin should be Einstein Copilot');
        System.assertEquals(td.account.Id, created.AccountId, 'Account should be linked');
    }

    @IsTest
    static void testEscalateToHuman_existingCase() {
        TestData td = setup();

        AgentConversationService.EscalationInput inp =
            new AgentConversationService.EscalationInput();
        inp.existingCaseId   = td.theCase.Id;
        inp.escalationReason = 'Complex technical issue';

        Test.startTest();
        List<AgentConversationService.EscalationOutput> results =
            AgentConversationService.escalateToHuman(
                new List<AgentConversationService.EscalationInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertEquals(td.theCase.Id, results[0].caseId,
            'Should use existing case Id');

        // Verify escalation comment was added
        List<CaseComment> comments = [
            SELECT CommentBody FROM CaseComment WHERE ParentId = :td.theCase.Id
        ];
        System.assertNotEquals(0, comments.size(), 'Escalation comment should be added');
        System.assert(comments[0].CommentBody.contains('AI Agent Escalation'),
            'Comment should include escalation header');
    }

    // ─── AgentConversationService — getCustomer360 ────────────────────────────

    @IsTest
    static void testGetCustomer360_success() {
        TestData td = setup();

        AgentConversationService.Customer360Input inp =
            new AgentConversationService.Customer360Input();
        inp.accountId = td.account.Id;

        Test.startTest();
        List<AgentConversationService.Customer360Output> results =
            AgentConversationService.getCustomer360(
                new List<AgentConversationService.Customer360Input>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertEquals('Deep Dive Corp', results[0].accountName, 'Account name correct');
        System.assertEquals('Technology', results[0].industry, 'Industry correct');
        System.assertEquals(8000000, results[0].annualRevenue, 'Revenue correct');
        System.assertEquals(1, results[0].contactCount, 'One contact');
        System.assertEquals(0, results[0].openOpps, 'No open opps');
        System.assertEquals(1, results[0].openCases, 'One open case');
        System.assertNotEquals(null, results[0].summary, 'Summary should be set');
        System.assert(results[0].summary.contains('Deep Dive Corp'),
            'Summary should include account name');
    }

    @IsTest
    static void testGetCustomer360_invalidAccount() {
        AgentConversationService.Customer360Input inp =
            new AgentConversationService.Customer360Input();
        inp.accountId = '001000000000001AAA';

        Test.startTest();
        List<AgentConversationService.Customer360Output> results =
            AgentConversationService.getCustomer360(
                new List<AgentConversationService.Customer360Input>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Invalid Id should fail gracefully');
        System.assertNotEquals(null, results[0].errorMessage, 'Error message should be set');
    }

    // ─── AgentConversationService — enrichAccountData ─────────────────────────

    @IsTest
    static void testEnrichAccountData_success() {
        // Mock HTTP response
        Test.setMock(HttpCalloutMock.class, new EnrichmentMock(200,
            '{"employeeRange":"201-500","fundingStage":"Series B",'
            + '"primaryTechnology":"Salesforce","confidenceScore":92}'));

        AgentConversationService.EnrichmentInput inp =
            new AgentConversationService.EnrichmentInput();
        inp.companyDomain = 'deepdive.com';

        Test.startTest();
        List<AgentConversationService.EnrichmentOutput> results =
            AgentConversationService.enrichAccountData(
                new List<AgentConversationService.EnrichmentInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertEquals('201-500', results[0].companySize, 'Company size correct');
        System.assertEquals('Series B', results[0].fundingStage, 'Funding stage correct');
        System.assertEquals('Salesforce', results[0].techStack, 'Tech stack correct');
        System.assertEquals(92, results[0].enrichmentScore, 'Confidence score correct');
        System.assert(results[0].summary.contains('Series B'),
            'Summary should include funding stage');
    }

    @IsTest
    static void testEnrichAccountData_apiError() {
        Test.setMock(HttpCalloutMock.class, new EnrichmentMock(500, '{"error":"server error"}'));

        AgentConversationService.EnrichmentInput inp =
            new AgentConversationService.EnrichmentInput();
        inp.companyDomain = 'error.com';

        Test.startTest();
        List<AgentConversationService.EnrichmentOutput> results =
            AgentConversationService.enrichAccountData(
                new List<AgentConversationService.EnrichmentInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, '500 error should fail gracefully');
        System.assert(results[0].errorMessage.contains('500'),
            'Error should mention status code');
    }

    @IsTest
    static void testEnrichAccountData_blankDomain() {
        AgentConversationService.EnrichmentInput inp =
            new AgentConversationService.EnrichmentInput();
        inp.companyDomain = '';

        Test.startTest();
        List<AgentConversationService.EnrichmentOutput> results =
            AgentConversationService.enrichAccountData(
                new List<AgentConversationService.EnrichmentInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Blank domain should fail');
        System.assert(results[0].errorMessage.contains('required'),
            'Error should say domain is required');
    }

    // ─── AgentConversationService — detectSentiment ───────────────────────────

    @IsTest
    static void testDetectSentiment_negative() {
        Test.startTest();
        AgentConversationService.SentimentResult result =
            AgentConversationService.detectSentiment(
                'I am very frustrated and angry about this terrible service!'
            );
        Test.stopTest();

        System.assert(result.label.contains('Negative'), 'Should detect negative sentiment');
        System.assert(result.score < 0, 'Score should be negative');
    }

    @IsTest
    static void testDetectSentiment_escalation() {
        Test.startTest();
        AgentConversationService.SentimentResult result =
            AgentConversationService.detectSentiment(
                'This is ridiculous! I want to escalate to a manager and cancel my account.'
            );
        Test.stopTest();

        System.assertEquals(true, result.shouldEscalate,
            'Multiple negative keywords should trigger escalation');
    }

    @IsTest
    static void testDetectSentiment_positive() {
        Test.startTest();
        AgentConversationService.SentimentResult result =
            AgentConversationService.detectSentiment(
                'Thank you so much, this is amazing and very helpful!'
            );
        Test.stopTest();

        System.assertEquals('Positive', result.label, 'Should detect positive');
        System.assert(result.score > 0, 'Score should be positive');
        System.assertEquals(false, result.shouldEscalate, 'Positive should not escalate');
    }

    @IsTest
    static void testDetectSentiment_neutral() {
        Test.startTest();
        AgentConversationService.SentimentResult result =
            AgentConversationService.detectSentiment('How do I reset my password?');
        Test.stopTest();

        System.assertEquals('Neutral', result.label, 'Should be neutral');
        System.assertEquals(0.0, result.score, 'Score should be 0');
        System.assertEquals(false, result.shouldEscalate, 'Neutral should not escalate');
    }

    @IsTest
    static void testDetectSentiment_blank() {
        Test.startTest();
        AgentConversationService.SentimentResult result =
            AgentConversationService.detectSentiment(null);
        Test.stopTest();

        System.assertEquals('Neutral', result.label, 'Null input should be Neutral');
    }

    // ─── AgentConversationService — analyseSentiment invocable ────────────────

    @IsTest
    static void testAnalyseSentiment_invocable() {
        AgentConversationService.SentimentInput inp = new AgentConversationService.SentimentInput();
        inp.messageText = 'I am so frustrated with this product!';

        Test.startTest();
        List<AgentConversationService.SentimentOutput> results =
            AgentConversationService.analyseSentiment(
                new List<AgentConversationService.SentimentInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertNotEquals(null, results[0].sentimentLabel, 'Label should be set');
        System.assertNotEquals(null, results[0].recommendation,
            'Recommendation should be set');
    }

    // ─── AgentConversationService — processAutonomousCaseEvent ───────────────

    @IsTest
    static void testProcessAutonomousCaseEvent_sentimentEscalation() {
        TestData td = setup();
        // Case description contains frustrated/immediately — should trigger priority escalation

        AgentConversationService.AutonomousEventInput inp =
            new AgentConversationService.AutonomousEventInput();
        inp.caseId    = td.theCase.Id;
        inp.eventType = 'case_assigned';

        Test.startTest();
        List<AgentConversationService.AutonomousEventOutput> results =
            AgentConversationService.processAutonomousCaseEvent(
                new List<AgentConversationService.AutonomousEventInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');

        // Verify Chatter post was created
        List<FeedItem> feed = [SELECT Body FROM FeedItem WHERE ParentId = :td.theCase.Id];
        System.assertNotEquals(0, feed.size(), 'Chatter post should be created');
        System.assert(feed[0].Body.contains('Agentforce Autonomous Agent'),
            'Feed post should identify autonomous agent');
    }

    @IsTest
    static void testProcessAutonomousCaseEvent_slaBreach() {
        TestData td = setup();

        AgentConversationService.AutonomousEventInput inp =
            new AgentConversationService.AutonomousEventInput();
        inp.caseId    = td.theCase.Id;
        inp.eventType = 'sla_breach';

        Test.startTest();
        List<AgentConversationService.AutonomousEventOutput> results =
            AgentConversationService.processAutonomousCaseEvent(
                new List<AgentConversationService.AutonomousEventInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');

        Case updated = [SELECT Priority FROM Case WHERE Id = :td.theCase.Id];
        System.assertEquals('Critical', updated.Priority,
            'SLA breach should set priority to Critical');
    }

    @IsTest
    static void testProcessAutonomousCaseEvent_invalidCase() {
        AgentConversationService.AutonomousEventInput inp =
            new AgentConversationService.AutonomousEventInput();
        inp.caseId    = '500000000000001AAA';
        inp.eventType = 'case_assigned';

        Test.startTest();
        List<AgentConversationService.AutonomousEventOutput> results =
            AgentConversationService.processAutonomousCaseEvent(
                new List<AgentConversationService.AutonomousEventInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Invalid Case Id should fail gracefully');
        System.assertNotEquals(null, results[0].errorMessage, 'Error message should be set');
    }

    // ─── AgentConversationService — buildSessionCacheKey ─────────────────────

    @IsTest
    static void testBuildSessionCacheKey() {
        Test.startTest();
        String key1 = AgentConversationService.buildSessionCacheKey('sess-123', 'accountId');
        String key2 = AgentConversationService.buildSessionCacheKey('sess 456!', 'my key');
        Test.stopTest();

        System.assert(key1.startsWith('agent_'), 'Key should start with agent_');
        System.assert(!key1.contains('-'), 'Hyphens should be replaced');
        System.assert(!key2.contains(' '), 'Spaces should be replaced');
        System.assert(!key2.contains('!'), 'Special chars should be replaced');
        System.assert(key1.length() <= 50, 'Key should be 50 chars or fewer');
    }

    // ─── EinsteinCopilotService — retrieveRagContext ─────────────────────────

    @IsTest
    static void testRetrieveRagContext_noContext() {
        EinsteinCopilotService.RagContextInput inp = new EinsteinCopilotService.RagContextInput();
        inp.userQuery       = 'ZZZNOMATCH_XYZ';
        inp.includeAccounts = true;
        inp.includeCases    = true;
        inp.includeKnowledge = false;

        Test.startTest();
        List<EinsteinCopilotService.RagContextOutput> results =
            EinsteinCopilotService.retrieveRagContext(
                new List<EinsteinCopilotService.RagContextInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed even with no results');
        System.assertNotEquals(null, results[0].contextText, 'Context text should not be null');
    }

    @IsTest
    static void testRetrieveRagContext_gracefulDegradation() {
        EinsteinCopilotService.RagContextInput inp = new EinsteinCopilotService.RagContextInput();
        inp.userQuery        = 'Deep Dive';
        inp.includeAccounts  = true;
        inp.includeCases     = true;
        inp.includeKnowledge = true;

        Test.startTest();
        List<EinsteinCopilotService.RagContextOutput> results =
            EinsteinCopilotService.retrieveRagContext(
                new List<EinsteinCopilotService.RagContextInput>{ inp }
            );
        Test.stopTest();

        // SOSL in tests returns empty by default — verify graceful response
        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertNotEquals(null, results[0].contextText, 'Context text should not be null');
        System.assert(results[0].contextLength >= 0, 'Length should be non-negative');
    }

    // ─── EinsteinCopilotService — semanticSearch ──────────────────────────────

    @IsTest
    static void testSemanticSearch_blankTerm() {
        EinsteinCopilotService.SemanticSearchInput inp =
            new EinsteinCopilotService.SemanticSearchInput();
        inp.searchTerm = '';

        Test.startTest();
        List<EinsteinCopilotService.SemanticSearchOutput> results =
            EinsteinCopilotService.semanticSearch(
                new List<EinsteinCopilotService.SemanticSearchInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, 'Blank search term should fail');
        System.assert(results[0].errorMessage.contains('required'),
            'Error should mention required');
    }

    @IsTest
    static void testSemanticSearch_withResults() {
        TestData td = setup();
        // Use fixed search results to make SOSL deterministic in tests
        Test.setFixedSearchResults(new List<Id>{ td.account.Id });

        EinsteinCopilotService.SemanticSearchInput inp =
            new EinsteinCopilotService.SemanticSearchInput();
        inp.searchTerm   = 'Deep Dive Corp';
        inp.maxPerObject = 5;

        Test.startTest();
        List<EinsteinCopilotService.SemanticSearchOutput> results =
            EinsteinCopilotService.semanticSearch(
                new List<EinsteinCopilotService.SemanticSearchInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertNotEquals(null, results[0].searchSummary, 'Summary should not be null');
    }

    // ─── EinsteinCopilotService — qualifyAndAssign ────────────────────────────

    @IsTest
    static void testQualifyAndAssign_hotTier() {
        TestData td = setup(); // AnnualRevenue = 8M, Employees = 400 → Hot

        EinsteinCopilotService.QualificationInput inp =
            new EinsteinCopilotService.QualificationInput();
        inp.accountId     = td.account.Id;
        inp.targetIndustry = 'Software';

        Test.startTest();
        List<EinsteinCopilotService.QualificationOutput> results =
            EinsteinCopilotService.qualifyAndAssign(
                new List<EinsteinCopilotService.QualificationInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertEquals('Hot', results[0].accountTier, '8M revenue = Hot tier');
        System.assertNotEquals(null, results[0].taskId, 'Task should be created');
        System.assert(results[0].stepsSummary.contains('Hot'),
            'Steps summary should mention Hot');
        System.assert(results[0].confirmationMessage.contains('Hot'),
            'Confirmation should mention Hot');

        Account updated = [SELECT Rating, Industry FROM Account WHERE Id = :td.account.Id];
        System.assertEquals('Hot', updated.Rating, 'Rating should be Hot');
        System.assertEquals('Software', updated.Industry, 'Industry should be updated');

        Task task = [SELECT Priority, ActivityDate FROM Task WHERE Id = :results[0].taskId];
        System.assertEquals('High', task.Priority, 'Hot tier task should be High priority');
        System.assertEquals(Date.today().addDays(1), task.ActivityDate,
            'Hot tier task due tomorrow');
    }

    @IsTest
    static void testQualifyAndAssign_coldTier() {
        Account smallAcc = new Account(
            Name          = 'Small Startup',
            AnnualRevenue = 50000,
            NumberOfEmployees = 5
        );
        insert smallAcc;

        EinsteinCopilotService.QualificationInput inp =
            new EinsteinCopilotService.QualificationInput();
        inp.accountId = smallAcc.Id;

        Test.startTest();
        List<EinsteinCopilotService.QualificationOutput> results =
            EinsteinCopilotService.qualifyAndAssign(
                new List<EinsteinCopilotService.QualificationInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals('Cold', results[0].accountTier, 'Small account = Cold');

        Task task = [SELECT Priority, ActivityDate FROM Task WHERE Id = :results[0].taskId];
        System.assertEquals('Normal', task.Priority, 'Cold tier task should be Normal priority');
        System.assertEquals(Date.today().addDays(5), task.ActivityDate,
            'Cold tier task due in 5 days');
    }

    // ─── EinsteinCopilotService — determineTier ───────────────────────────────

    @IsTest
    static void testDetermineTier() {
        Test.startTest();
        String t1 = EinsteinCopilotService.determineTier(15000000, 100);  // Revenue qualifies Hot
        String t2 = EinsteinCopilotService.determineTier(500,      600);  // Employees qualify Hot
        String t3 = EinsteinCopilotService.determineTier(2000000,  50);   // Revenue qualifies Warm
        String t4 = EinsteinCopilotService.determineTier(500,      150);  // Employees qualify Warm
        String t5 = EinsteinCopilotService.determineTier(10000,    5);    // Cold
        String t6 = EinsteinCopilotService.determineTier(null,     null); // No data = Cold
        Test.stopTest();

        System.assertEquals('Hot',  t1, '$15M revenue = Hot');
        System.assertEquals('Hot',  t2, '600 employees = Hot');
        System.assertEquals('Warm', t3, '$2M revenue = Warm');
        System.assertEquals('Warm', t4, '150 employees = Warm');
        System.assertEquals('Cold', t5, '$10K / 5 employees = Cold');
        System.assertEquals('Cold', t6, 'Null inputs = Cold');
    }

    // ─── EinsteinCopilotService — formatSObjectSummary ────────────────────────

    @IsTest
    static void testFormatSObjectSummary() {
        TestData td = setup();

        Test.startTest();
        String accSummary  = EinsteinCopilotService.formatSObjectSummary(td.account);
        String contSummary = EinsteinCopilotService.formatSObjectSummary(td.contact);
        String caseSummary = EinsteinCopilotService.formatSObjectSummary(
            [SELECT Id, CaseNumber, Subject FROM Case WHERE Id = :td.theCase.Id]
        );
        Test.stopTest();

        System.assert(accSummary.contains('Account'), 'Account summary should say Account');
        System.assert(accSummary.contains('Deep Dive Corp'), 'Should include account name');
        System.assert(contSummary.contains('Contact'), 'Contact summary should say Contact');
        System.assert(caseSummary.contains('Case'), 'Case summary should say Case');
    }

    // ─── EinsteinCopilotService — getActiveAgents / getAgentTopics ────────────

    @IsTest
    static void testGetActiveAgents_graceful() {
        Test.startTest();
        List<SObject> agents = EinsteinCopilotService.getActiveAgents();
        Test.stopTest();

        System.assertNotEquals(null, agents,
            'Should return list (empty if BotDefinition not available)');
    }

    @IsTest
    static void testGetAgentTopics_graceful() {
        Test.startTest();
        List<SObject> topics = EinsteinCopilotService.getAgentTopics(
            '0Xx000000000001AAA' // fake bot Id
        );
        Test.stopTest();

        System.assertNotEquals(null, topics,
            'Should return list (empty if BotTopic not available)');
    }

    // ─── Mock HTTP for enrichment ─────────────────────────────────────────────

    private class EnrichmentMock implements HttpCalloutMock {
        Integer statusCode;
        String  body;

        EnrichmentMock(Integer code, String responseBody) {
            this.statusCode = code;
            this.body       = responseBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(statusCode);
            resp.setBody(body);
            resp.setHeader('Content-Type', 'application/json');
            return resp;
        }
    }
}
