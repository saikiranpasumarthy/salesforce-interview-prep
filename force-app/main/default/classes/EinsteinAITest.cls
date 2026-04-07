/**
 * Day 34 — Einstein Features & AI in Apex — Test Suite
 *
 * Coverage:
 *  EinsteinPredictionService: prediction field reading, bulk scoring,
 *    OOTB object graceful degradation, Language API (sentiment + intent),
 *    Next Best Action (mocked ConnectApi).
 *  EinsteinFlowService: all 5 @InvocableMethod actions, routing logic,
 *    priority classification, boundary conditions.
 *
 * All HTTP calls use SimpleMock. ConnectApi.Recommendations tested via
 *  EinsteinPredictionService.useMock + mockRecommendations.
 */
@IsTest
private class EinsteinAITest {

    // ═══════════════════════════════════════════════════════════════════════════
    // EinsteinPredictionService — Prediction field reading
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getPredictionScore_found() {
        Account acc = new Account(Name = 'Churn Test', AnnualRevenue = 500000);
        insert acc;

        Test.startTest();
        EinsteinPredictionService.PredictionScore result =
            EinsteinPredictionService.getPredictionScore(acc.Id, 'Account', 'AnnualRevenue', null);
        Test.stopTest();

        System.assertEquals(acc.Id,  result.recordId,  'Should return correct Id');
        System.assertEquals(500000,  result.score,     'Should return AnnualRevenue as score');
        System.assert(result.isSuccess,                 'Should be success');
        System.assertEquals(null, result.error);
    }

    @IsTest
    static void getPredictionScore_withTierField() {
        Account acc = new Account(Name = 'Tiered', AnnualRevenue = 75, Rating = 'Hot');
        insert acc;

        EinsteinPredictionService.PredictionScore result =
            EinsteinPredictionService.getPredictionScore(acc.Id, 'Account', 'AnnualRevenue', 'Rating');

        System.assert(result.isSuccess);
        System.assertEquals('Hot', result.tier);
    }

    @IsTest
    static void getPredictionScore_recordNotFound() {
        Id fakeId = '001000000000000AAA';

        EinsteinPredictionService.PredictionScore result =
            EinsteinPredictionService.getPredictionScore(fakeId, 'Account', 'AnnualRevenue', null);

        System.assertNotEquals(null, result);
        // Score should be null or result should be an error for non-existent record
        System.assert(!result.isSuccess || result.score == null);
    }

    @IsTest
    static void getPredictionScore_nullId() {
        EinsteinPredictionService.PredictionScore result =
            EinsteinPredictionService.getPredictionScore(null, 'Account', 'AnnualRevenue', null);

        System.assert(!result.isSuccess, 'Should fail for null Id');
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void getPredictionScore_invalidField() {
        Account acc = new Account(Name = 'Field Test');
        insert acc;

        EinsteinPredictionService.PredictionScore result =
            EinsteinPredictionService.getPredictionScore(
                acc.Id, 'Account', 'NonExistentField__xyz', null
            );

        System.assert(!result.isSuccess, 'Should fail for invalid field name');
        System.assertNotEquals(null, result.error);
    }

    @IsTest
    static void bulkGetPredictionScores_success() {
        List<Account> accs = new List<Account>{
            new Account(Name = 'Bulk1', AnnualRevenue = 1000000),
            new Account(Name = 'Bulk2', AnnualRevenue = 250000)
        };
        insert accs;
        List<Id> ids = new List<Id>{ accs[0].Id, accs[1].Id };

        Test.startTest();
        List<EinsteinPredictionService.PredictionScore> results =
            EinsteinPredictionService.bulkGetPredictionScores(ids, 'Account', 'AnnualRevenue', null);
        Test.stopTest();

        System.assertEquals(2, results.size());
        for (EinsteinPredictionService.PredictionScore ps : results) {
            System.assert(ps.isSuccess, 'All results should be success');
            System.assertNotEquals(null, ps.score);
        }
    }

    @IsTest
    static void bulkGetPredictionScores_emptyList() {
        List<EinsteinPredictionService.PredictionScore> results =
            EinsteinPredictionService.bulkGetPredictionScores(
                new List<Id>(), 'Account', 'AnnualRevenue', null
            );
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void bulkGetPredictionScores_nullList() {
        List<EinsteinPredictionService.PredictionScore> results =
            EinsteinPredictionService.bulkGetPredictionScores(
                null, 'Account', 'AnnualRevenue', null
            );
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void getTierFromScore_allThresholds() {
        EinsteinPredictionService.PredictionScore high =
            new EinsteinPredictionService.PredictionScore(null, 95,   null, null);
        EinsteinPredictionService.PredictionScore med  =
            new EinsteinPredictionService.PredictionScore(null, 70,   null, null);
        EinsteinPredictionService.PredictionScore low  =
            new EinsteinPredictionService.PredictionScore(null, 30,   null, null);
        EinsteinPredictionService.PredictionScore none =
            new EinsteinPredictionService.PredictionScore(null, null, null, null);
        EinsteinPredictionService.PredictionScore boundary90 =
            new EinsteinPredictionService.PredictionScore(null, 90,   null, null);
        EinsteinPredictionService.PredictionScore boundary60 =
            new EinsteinPredictionService.PredictionScore(null, 60,   null, null);

        System.assertEquals('High',    high.getTierFromScore());
        System.assertEquals('Medium',  med.getTierFromScore());
        System.assertEquals('Low',     low.getTierFromScore());
        System.assertEquals('Unknown', none.getTierFromScore());
        System.assertEquals('High',    boundary90.getTierFromScore(), 'Score 90 = High');
        System.assertEquals('Medium',  boundary60.getTierFromScore(), 'Score 60 = Medium');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OOTB Scoring — graceful degradation
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getOpportunityScores_emptyInput() {
        List<EinsteinPredictionService.OpportunityScore> results =
            EinsteinPredictionService.getOpportunityScores(new List<Id>());
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void getOpportunityScores_gracefulDegradation() {
        // OpportunityScore object not available in scratch org → empty list, no exception
        Account acc  = new Account(Name = 'Opp Score Test');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'Test Opp', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30)
        );
        insert opp;

        List<EinsteinPredictionService.OpportunityScore> results =
            EinsteinPredictionService.getOpportunityScores(new List<Id>{ opp.Id });

        System.assertNotEquals(null, results, 'Should never return null');
        // 0 results expected in scratch org without Einstein Opportunity Scoring
    }

    @IsTest
    static void getLeadScores_emptyInput() {
        List<EinsteinPredictionService.LeadScore> results =
            EinsteinPredictionService.getLeadScores(new List<Id>());
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void getLeadScores_gracefulDegradation() {
        Lead l = new Lead(
            FirstName = 'AI', LastName = 'Test',
            Company = 'Test Co', Status = 'Open - Not Contacted'
        );
        insert l;

        List<EinsteinPredictionService.LeadScore> results =
            EinsteinPredictionService.getLeadScores(new List<Id>{ l.Id });

        System.assertNotEquals(null, results, 'Should never return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Einstein Language API — Sentiment
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void analyzeSentiment_positive() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"positive","probability":0.92},'
            + '{"label":"negative","probability":0.05},{"label":"neutral","probability":0.03}]}'
        );

        Test.startTest();
        EinsteinPredictionService.SentimentResult result =
            EinsteinPredictionService.analyzeSentiment('I love this product!');
        Test.stopTest();

        System.assertEquals('positive', result.label);
        System.assert(result.probability > 0.9);
        System.assert(result.isPositive);
        System.assert(!result.isNegative);
        System.assert(result.isSuccess);
    }

    @IsTest
    static void analyzeSentiment_negative() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"negative","probability":0.87}]}'
        );

        EinsteinPredictionService.SentimentResult result =
            EinsteinPredictionService.analyzeSentiment('Terrible service, I am furious!');

        System.assertEquals('negative', result.label);
        System.assert(result.isNegative);
        System.assert(result.isSuccess);
    }

    @IsTest
    static void analyzeSentiment_blankText() {
        EinsteinPredictionService.SentimentResult result =
            EinsteinPredictionService.analyzeSentiment('');

        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void analyzeSentiment_apiError401() {
        EinsteinPredictionService.calloutMock = new SimpleMock(401, '{"message":"Unauthorized"}');

        EinsteinPredictionService.SentimentResult result =
            EinsteinPredictionService.analyzeSentiment('Some text');

        System.assert(!result.isSuccess);
        System.assert(result.error.contains('401'));
    }

    @IsTest
    static void analyzeSentiment_emptyProbabilities() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200, '{"probabilities":[]}');

        EinsteinPredictionService.SentimentResult result =
            EinsteinPredictionService.analyzeSentiment('Test text');

        System.assert(!result.isSuccess, 'Empty probabilities should fail');
    }

    @IsTest
    static void analyzeSentiment_malformedJson() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200, 'not-json-at-all');

        EinsteinPredictionService.SentimentResult result =
            EinsteinPredictionService.analyzeSentiment('Test text');

        System.assert(!result.isSuccess, 'Malformed JSON should fail gracefully');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Einstein Language API — Intent
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void classifyIntent_success() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"Complaint","probability":0.89},'
            + '{"label":"Inquiry","probability":0.11}]}'
        );

        Test.startTest();
        EinsteinPredictionService.IntentResult result =
            EinsteinPredictionService.classifyIntent('I am unhappy with my bill', null);
        Test.stopTest();

        System.assertEquals('Complaint', result.label);
        System.assert(result.probability > 0.8);
        System.assert(result.isSuccess);
    }

    @IsTest
    static void classifyIntent_blankText() {
        EinsteinPredictionService.IntentResult result =
            EinsteinPredictionService.classifyIntent('', 'my-model');

        System.assert(!result.isSuccess);
        System.assertNotEquals(null, result.error);
    }

    @IsTest
    static void classifyIntent_defaultModelUsedWhenNull() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"Inquiry","probability":0.75}]}'
        );

        EinsteinPredictionService.IntentResult result =
            EinsteinPredictionService.classifyIntent('Tell me about pricing', null);

        System.assert(result.isSuccess, 'Should succeed with default model');
        System.assertEquals('Inquiry', result.label);
    }

    @IsTest
    static void classifyIntent_apiError() {
        EinsteinPredictionService.calloutMock = new SimpleMock(500, '{"error":"Internal Server Error"}');

        EinsteinPredictionService.IntentResult result =
            EinsteinPredictionService.classifyIntent('Some text', 'model-v1');

        System.assert(!result.isSuccess);
        System.assert(result.error.contains('500'));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Einstein NBA — ConnectApi mock
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getNextBestActions_mockReturnsItems() {
        EinsteinPredictionService.useMock = true;
        EinsteinPredictionService.mockRecommendations =
            new List<EinsteinPredictionService.RecommendationItem>{
                new EinsteinPredictionService.RecommendationItem(
                    'Upsell Premium', 'Offer premium tier upgrade', null, 'Accept', 'Decline'
                ),
                new EinsteinPredictionService.RecommendationItem(
                    'Schedule Demo', 'Book a product demo', null, 'Book', 'Skip'
                )
            };

        Test.startTest();
        List<EinsteinPredictionService.RecommendationItem> results =
            EinsteinPredictionService.getNextBestActions('001000000000001AAA', 'CrossSell_Strategy', 5);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assertEquals('Upsell Premium', results[0].name);
        System.assertEquals('Schedule Demo',  results[1].name);
        System.assertEquals('Accept', results[0].acceptanceLabel);
    }

    @IsTest
    static void getNextBestActions_emptyMock() {
        EinsteinPredictionService.useMock = true;
        EinsteinPredictionService.mockRecommendations =
            new List<EinsteinPredictionService.RecommendationItem>();

        List<EinsteinPredictionService.RecommendationItem> results =
            EinsteinPredictionService.getNextBestActions('001000000000001AAA', 'Strategy', 3);

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void getNextBestActions_gracefulDegradationNoConnectApi() {
        // Without mock, ConnectApi.Recommendations will fail in scratch org → empty list
        List<EinsteinPredictionService.RecommendationItem> results =
            EinsteinPredictionService.getNextBestActions('001000000000001AAA', 'Test_Strategy', 3);

        System.assertNotEquals(null, results, 'Must never return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EinsteinFlowService — predictChurnRisk
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void predictChurnRisk_highRisk() {
        Account acc = new Account(Name = 'High Risk', AnnualRevenue = 95);
        insert acc;

        EinsteinFlowService.ChurnRiskInput inp = new EinsteinFlowService.ChurnRiskInput();
        inp.accountId  = acc.Id;
        inp.scoreField = 'AnnualRevenue'; // proxy for custom score field in tests

        Test.startTest();
        List<EinsteinFlowService.ChurnRiskOutput> outputs =
            EinsteinFlowService.predictChurnRisk(
                new List<EinsteinFlowService.ChurnRiskInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals('High', outputs[0].tier);
        System.assert(outputs[0].isHighRisk, 'Score 95 >= 90 → high risk');
        System.assertEquals(null, outputs[0].error);
    }

    @IsTest
    static void predictChurnRisk_mediumRisk() {
        Account acc = new Account(Name = 'Med Risk', AnnualRevenue = 70);
        insert acc;

        EinsteinFlowService.ChurnRiskInput inp = new EinsteinFlowService.ChurnRiskInput();
        inp.accountId  = acc.Id;
        inp.scoreField = 'AnnualRevenue';

        List<EinsteinFlowService.ChurnRiskOutput> outputs =
            EinsteinFlowService.predictChurnRisk(
                new List<EinsteinFlowService.ChurnRiskInput>{ inp }
            );

        System.assertEquals('Medium', outputs[0].tier);
        System.assert(!outputs[0].isHighRisk);
    }

    @IsTest
    static void predictChurnRisk_lowRisk() {
        Account acc = new Account(Name = 'Low Risk', AnnualRevenue = 30);
        insert acc;

        EinsteinFlowService.ChurnRiskInput inp = new EinsteinFlowService.ChurnRiskInput();
        inp.accountId  = acc.Id;
        inp.scoreField = 'AnnualRevenue';

        List<EinsteinFlowService.ChurnRiskOutput> outputs =
            EinsteinFlowService.predictChurnRisk(
                new List<EinsteinFlowService.ChurnRiskInput>{ inp }
            );

        System.assertEquals('Low', outputs[0].tier);
        System.assert(!outputs[0].isHighRisk);
    }

    @IsTest
    static void predictChurnRisk_nullAccountId() {
        EinsteinFlowService.ChurnRiskInput inp = new EinsteinFlowService.ChurnRiskInput();
        inp.accountId = null;

        List<EinsteinFlowService.ChurnRiskOutput> outputs =
            EinsteinFlowService.predictChurnRisk(
                new List<EinsteinFlowService.ChurnRiskInput>{ inp }
            );

        System.assertNotEquals(null, outputs[0].error, 'Null Id should produce error');
    }

    @IsTest
    static void predictChurnRisk_nullInputElement() {
        List<EinsteinFlowService.ChurnRiskOutput> outputs =
            EinsteinFlowService.predictChurnRisk(
                new List<EinsteinFlowService.ChurnRiskInput>{ null }
            );

        System.assertEquals(1, outputs.size());
        System.assertNotEquals(null, outputs[0].error);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EinsteinFlowService — scoreLeads
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void scoreLeads_emptyInput() {
        List<EinsteinFlowService.LeadScoringOutput> outputs =
            EinsteinFlowService.scoreLeads(new List<EinsteinFlowService.LeadScoringInput>());
        System.assertEquals(0, outputs.size());
    }

    @IsTest
    static void scoreLeads_nullLeadId() {
        EinsteinFlowService.LeadScoringInput inp = new EinsteinFlowService.LeadScoringInput();
        inp.leadId = null;

        List<EinsteinFlowService.LeadScoringOutput> outputs =
            EinsteinFlowService.scoreLeads(
                new List<EinsteinFlowService.LeadScoringInput>{ inp }
            );

        System.assertEquals(1, outputs.size());
        System.assertNotEquals(null, outputs[0].error);
    }

    @IsTest
    static void scoreLeads_noEinsteinLicence_gracefulDegradation() {
        Lead l = new Lead(
            FirstName = 'AI', LastName = 'Lead',
            Company = 'Test Co', Status = 'Open - Not Contacted'
        );
        insert l;

        EinsteinFlowService.LeadScoringInput inp = new EinsteinFlowService.LeadScoringInput();
        inp.leadId = l.Id;

        List<EinsteinFlowService.LeadScoringOutput> outputs =
            EinsteinFlowService.scoreLeads(
                new List<EinsteinFlowService.LeadScoringInput>{ inp }
            );

        System.assertEquals(1, outputs.size());
        // LeadScore object not available in scratch org — error message expected
        System.assertNotEquals(null, outputs[0]);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EinsteinFlowService — classifyEmailIntent
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void classifyEmailIntent_complaint_highPriority() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"Complaint","probability":0.91}]}'
        );

        EinsteinFlowService.EmailIntentInput inp = new EinsteinFlowService.EmailIntentInput();
        inp.text    = 'I want to escalate my complaint immediately';
        inp.modelId = 'support-intent-v1';

        Test.startTest();
        List<EinsteinFlowService.EmailIntentOutput> outputs =
            EinsteinFlowService.classifyEmailIntent(
                new List<EinsteinFlowService.EmailIntentInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals('Complaint',        outputs[0].intent);
        System.assertEquals('Escalation_Queue', outputs[0].routingQueue);
        System.assert(outputs[0].isHighPriority, 'Complaint + 0.91 confidence = high priority');
    }

    @IsTest
    static void classifyEmailIntent_billing() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"Billing_Issue","probability":0.85}]}'
        );

        EinsteinFlowService.EmailIntentInput inp = new EinsteinFlowService.EmailIntentInput();
        inp.text = 'My invoice shows an incorrect amount';

        List<EinsteinFlowService.EmailIntentOutput> outputs =
            EinsteinFlowService.classifyEmailIntent(
                new List<EinsteinFlowService.EmailIntentInput>{ inp }
            );

        System.assertEquals('Billing_Queue', outputs[0].routingQueue);
    }

    @IsTest
    static void classifyEmailIntent_unknownIntent_defaultQueue() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"General_Feedback","probability":0.6}]}'
        );

        EinsteinFlowService.EmailIntentInput inp = new EinsteinFlowService.EmailIntentInput();
        inp.text = 'Just wanted to say hi!';

        List<EinsteinFlowService.EmailIntentOutput> outputs =
            EinsteinFlowService.classifyEmailIntent(
                new List<EinsteinFlowService.EmailIntentInput>{ inp }
            );

        System.assertEquals('General_Support', outputs[0].routingQueue,
            'Unknown intent should map to General_Support');
        System.assert(!outputs[0].isHighPriority);
    }

    @IsTest
    static void classifyEmailIntent_blankText() {
        EinsteinFlowService.EmailIntentInput inp = new EinsteinFlowService.EmailIntentInput();
        inp.text = '';

        List<EinsteinFlowService.EmailIntentOutput> outputs =
            EinsteinFlowService.classifyEmailIntent(
                new List<EinsteinFlowService.EmailIntentInput>{ inp }
            );

        System.assertNotEquals(null, outputs[0].error);
    }

    @IsTest
    static void classifyEmailIntent_apiError() {
        EinsteinPredictionService.calloutMock = new SimpleMock(503, '{"error":"Service Unavailable"}');

        EinsteinFlowService.EmailIntentInput inp = new EinsteinFlowService.EmailIntentInput();
        inp.text = 'Test email text';

        List<EinsteinFlowService.EmailIntentOutput> outputs =
            EinsteinFlowService.classifyEmailIntent(
                new List<EinsteinFlowService.EmailIntentInput>{ inp }
            );

        System.assertNotEquals(null, outputs[0].error);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EinsteinFlowService — routing logic helpers
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void mapIntentToQueue_allMappings() {
        System.assertEquals('Escalation_Queue', EinsteinFlowService.mapIntentToQueue('Complaint'));
        System.assertEquals('Billing_Queue',    EinsteinFlowService.mapIntentToQueue('Billing_Issue'));
        System.assertEquals('Technical_Queue',  EinsteinFlowService.mapIntentToQueue('Technical_Issue'));
        System.assertEquals('Renewal_Queue',    EinsteinFlowService.mapIntentToQueue('Renewal_Inquiry'));
        System.assertEquals('Retention_Queue',  EinsteinFlowService.mapIntentToQueue('Cancellation'));
        System.assertEquals('General_Support',  EinsteinFlowService.mapIntentToQueue('Unknown_Intent'));
        System.assertEquals('General_Support',  EinsteinFlowService.mapIntentToQueue(null));
    }

    @IsTest
    static void isHighPriorityIntent_scenarios() {
        // High priority: escalation-worthy intent + confidence >= 0.7
        System.assert(
            EinsteinFlowService.isHighPriorityIntent('Complaint', 0.85),
            'Complaint + 0.85 = high priority'
        );
        System.assert(
            EinsteinFlowService.isHighPriorityIntent('Cancellation', 0.70),
            'Cancellation + 0.70 = boundary high priority'
        );
        System.assert(
            !EinsteinFlowService.isHighPriorityIntent('Complaint', 0.65),
            'Confidence below 0.7 = not high priority'
        );
        System.assert(
            !EinsteinFlowService.isHighPriorityIntent('Inquiry', 0.95),
            'Non-HP intent = not high priority'
        );
        System.assert(
            !EinsteinFlowService.isHighPriorityIntent(null, 0.95),
            'Null intent = not high priority'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EinsteinFlowService — getNextBestActions
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getNextBestActionsFlow_missingInputs() {
        EinsteinFlowService.NbaInput inp = new EinsteinFlowService.NbaInput();
        inp.recordId     = null;
        inp.strategyName = null;

        List<EinsteinFlowService.NbaOutput> outputs =
            EinsteinFlowService.getNextBestActions(
                new List<EinsteinFlowService.NbaInput>{ inp }
            );

        System.assertNotEquals(null, outputs[0].error);
    }

    @IsTest
    static void getNextBestActionsFlow_withMockRecommendations() {
        EinsteinPredictionService.useMock = true;
        EinsteinPredictionService.mockRecommendations =
            new List<EinsteinPredictionService.RecommendationItem>{
                new EinsteinPredictionService.RecommendationItem(
                    'Renew Contract', 'Contract expiring in 30 days', null, 'Renew', 'Skip'
                )
            };

        Account acc = new Account(Name = 'NBA Flow Test');
        insert acc;

        EinsteinFlowService.NbaInput inp = new EinsteinFlowService.NbaInput();
        inp.recordId     = acc.Id;
        inp.strategyName = 'Account_NBA_Strategy';
        inp.maxResults   = 3;

        Test.startTest();
        List<EinsteinFlowService.NbaOutput> outputs =
            EinsteinFlowService.getNextBestActions(
                new List<EinsteinFlowService.NbaInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1,                outputs[0].recommendationCount);
        System.assertEquals('Renew Contract', outputs[0].recommendationNames[0]);
        System.assert(outputs[0].recommendationDescriptions[0].contains('30 days'));
    }

    @IsTest
    static void getNextBestActionsFlow_defaultMaxResults() {
        EinsteinPredictionService.useMock = true;
        EinsteinPredictionService.mockRecommendations =
            new List<EinsteinPredictionService.RecommendationItem>();

        Account acc = new Account(Name = 'NBA Default Max');
        insert acc;

        EinsteinFlowService.NbaInput inp = new EinsteinFlowService.NbaInput();
        inp.recordId     = acc.Id;
        inp.strategyName = 'Test_Strategy';
        // maxResults = null → should default to 3

        List<EinsteinFlowService.NbaOutput> outputs =
            EinsteinFlowService.getNextBestActions(
                new List<EinsteinFlowService.NbaInput>{ inp }
            );

        System.assertEquals(0, outputs[0].recommendationCount, 'Empty mock → 0 results');
        System.assertEquals(null, outputs[0].error, 'No error for valid input');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EinsteinFlowService — analyseSentiment
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void analyseSentiment_requiresEscalation() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"negative","probability":0.95}]}'
        );

        EinsteinFlowService.SentimentInput inp = new EinsteinFlowService.SentimentInput();
        inp.text = 'This is absolutely horrible. I am furious and demand a refund!';

        Test.startTest();
        List<EinsteinFlowService.SentimentOutput> outputs =
            EinsteinFlowService.analyseSentiment(
                new List<EinsteinFlowService.SentimentInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals('negative',  outputs[0].label);
        System.assert(outputs[0].isNegative);
        System.assert(outputs[0].requiresEscalation,
            'Negative sentiment with 0.95 confidence should require escalation');
    }

    @IsTest
    static void analyseSentiment_negativeBelow080_noEscalation() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"negative","probability":0.72}]}'
        );

        EinsteinFlowService.SentimentInput inp = new EinsteinFlowService.SentimentInput();
        inp.text = 'Not great, could be better.';

        List<EinsteinFlowService.SentimentOutput> outputs =
            EinsteinFlowService.analyseSentiment(
                new List<EinsteinFlowService.SentimentInput>{ inp }
            );

        System.assert(outputs[0].isNegative);
        System.assert(!outputs[0].requiresEscalation,
            'Negative < 0.80 probability should NOT require escalation');
    }

    @IsTest
    static void analyseSentiment_positiveNoEscalation() {
        EinsteinPredictionService.calloutMock = new SimpleMock(200,
            '{"probabilities":[{"label":"positive","probability":0.88}]}'
        );

        EinsteinFlowService.SentimentInput inp = new EinsteinFlowService.SentimentInput();
        inp.text = 'Great service, very satisfied!';

        List<EinsteinFlowService.SentimentOutput> outputs =
            EinsteinFlowService.analyseSentiment(
                new List<EinsteinFlowService.SentimentInput>{ inp }
            );

        System.assert(!outputs[0].requiresEscalation);
        System.assert(!outputs[0].isNegative);
    }

    @IsTest
    static void analyseSentiment_blankText() {
        EinsteinFlowService.SentimentInput inp = new EinsteinFlowService.SentimentInput();
        inp.text = null;

        List<EinsteinFlowService.SentimentOutput> outputs =
            EinsteinFlowService.analyseSentiment(
                new List<EinsteinFlowService.SentimentInput>{ inp }
            );

        System.assertNotEquals(null, outputs[0].error);
    }

    @IsTest
    static void analyseSentiment_apiError() {
        EinsteinPredictionService.calloutMock = new SimpleMock(429, '{"error":"Rate limit exceeded"}');

        EinsteinFlowService.SentimentInput inp = new EinsteinFlowService.SentimentInput();
        inp.text = 'Test text';

        List<EinsteinFlowService.SentimentOutput> outputs =
            EinsteinFlowService.analyseSentiment(
                new List<EinsteinFlowService.SentimentInput>{ inp }
            );

        System.assertNotEquals(null, outputs[0].error);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Mock infrastructure
    // ═══════════════════════════════════════════════════════════════════════════

    private class SimpleMock implements HttpCalloutMock {
        private final Integer statusCode;
        private final String  body;

        SimpleMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body       = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(statusCode);
            resp.setBody(body);
            return resp;
        }
    }
}
