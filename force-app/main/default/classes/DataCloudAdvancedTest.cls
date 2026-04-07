/**
 * @description Test coverage for Day 33 — Data Cloud Segmentation, Real-Time CDP.
 *              Covers DataCloudSegmentService and DataCloudPersonalisationService.
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class DataCloudAdvancedTest {

    // ─── Shared mock builders ─────────────────────────────────────────────────

    private static HttpResponse makeResp(Integer code, String body) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(code);
        r.setBody(body);
        r.setHeader('Content-Type', 'application/json');
        return r;
    }

    // Single-response mock
    private class SimpleMock implements HttpCalloutMock {
        Integer code; String body;
        SimpleMock(Integer c, String b) { code = c; body = b; }
        public HttpResponse respond(HttpRequest req) { return makeResp(code, body); }
    }

    // Returns different responses per sequential call
    private class SequencedMock implements HttpCalloutMock {
        List<String> bodies;
        List<Integer> codes;
        Integer idx = 0;
        SequencedMock(List<Integer> c, List<String> b) { codes = c; bodies = b; }
        public HttpResponse respond(HttpRequest req) {
            Integer i = Math.min(idx++, codes.size() - 1);
            return makeResp(codes[i], bodies[i]);
        }
    }

    // ─── DataCloudSegmentService — listSegments ────────────────────────────────

    @IsTest
    static void testListSegments_success() {
        String body = JSON.serialize(new Map<String, Object>{
            'segments' => new List<Object>{
                new Map<String, Object>{
                    'id' => 'seg-001', 'name' => 'High Value',
                    'type' => 'Standard', 'status' => 'Published', 'memberCount' => 1500
                },
                new Map<String, Object>{
                    'id' => 'seg-002', 'name' => 'Opted Out',
                    'type' => 'Suppression', 'status' => 'Published', 'memberCount' => 300
                }
            }
        });
        DataCloudSegmentService.calloutMock = new SimpleMock(200, body);

        Test.startTest();
        List<DataCloudSegmentService.SegmentSummary> segments =
            DataCloudSegmentService.listSegments();
        Test.stopTest();

        System.assertEquals(2, segments.size(), 'Two segments returned');
        System.assertEquals('seg-001', segments[0].segmentId, 'First segment Id');
        System.assertEquals('High Value', segments[0].name, 'First segment name');
        System.assertEquals('Standard', segments[0].segmentType, 'Type correct');
        System.assertEquals('Published', segments[0].status, 'Status correct');
        System.assertEquals(1500, segments[0].memberCount, 'Member count correct');
        System.assertEquals('Suppression', segments[1].segmentType, 'Suppression type correct');
    }

    @IsTest
    static void testListSegments_apiError() {
        DataCloudSegmentService.calloutMock = new SimpleMock(500, '{"error":"server error"}');

        Test.startTest();
        List<DataCloudSegmentService.SegmentSummary> segments =
            DataCloudSegmentService.listSegments();
        Test.stopTest();

        System.assertEquals(0, segments.size(), 'Empty list on error');
    }

    @IsTest
    static void testListSegments_emptySegments() {
        DataCloudSegmentService.calloutMock = new SimpleMock(200, '{"segments":[]}');

        Test.startTest();
        List<DataCloudSegmentService.SegmentSummary> segments =
            DataCloudSegmentService.listSegments();
        Test.stopTest();

        System.assertEquals(0, segments.size(), 'Empty segment list');
    }

    // ─── DataCloudSegmentService — getSegmentDetail ───────────────────────────

    @IsTest
    static void testGetSegmentDetail_found() {
        String body = JSON.serialize(new Map<String, Object>{
            'id' => 'seg-001', 'name' => 'High Value Customers',
            'type' => 'Standard', 'status' => 'Published',
            'memberCount' => 2500, 'description' => 'LTV > $10K',
            'refreshScheduleFrequency' => 'Hourly'
        });
        DataCloudSegmentService.calloutMock = new SimpleMock(200, body);

        Test.startTest();
        DataCloudSegmentService.SegmentDetail detail =
            DataCloudSegmentService.getSegmentDetail('seg-001');
        Test.stopTest();

        System.assertNotEquals(null, detail, 'Detail should be returned');
        System.assertEquals('seg-001', detail.segmentId, 'Segment Id correct');
        System.assertEquals('High Value Customers', detail.name, 'Name correct');
        System.assertEquals(2500, detail.memberCount, 'Member count correct');
        System.assertEquals('LTV > $10K', detail.description, 'Description correct');
        System.assertEquals('Hourly', detail.refreshType, 'Refresh type correct');
    }

    @IsTest
    static void testGetSegmentDetail_blankId() {
        Test.startTest();
        DataCloudSegmentService.SegmentDetail detail =
            DataCloudSegmentService.getSegmentDetail('');
        Test.stopTest();

        System.assertEquals(null, detail, 'Blank Id returns null');
    }

    @IsTest
    static void testGetSegmentDetail_notFound() {
        DataCloudSegmentService.calloutMock = new SimpleMock(404, '{}');

        Test.startTest();
        DataCloudSegmentService.SegmentDetail detail =
            DataCloudSegmentService.getSegmentDetail('seg-nonexistent');
        Test.stopTest();

        System.assertEquals(null, detail, '404 returns null');
    }

    // ─── DataCloudSegmentService — triggerSegmentRefresh ─────────────────────

    @IsTest
    static void testTriggerSegmentRefresh_full() {
        DataCloudSegmentService.calloutMock = new SimpleMock(202,
            '{"id":"job-abc-123","status":"Pending"}');

        Test.startTest();
        DataCloudSegmentService.PublishJobResult result =
            DataCloudSegmentService.triggerSegmentRefresh('seg-001', true);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Should succeed');
        System.assertEquals('job-abc-123', result.jobId, 'Job Id set');
        System.assertEquals(null, result.errorMessage, 'No error');
    }

    @IsTest
    static void testTriggerSegmentRefresh_incremental() {
        DataCloudSegmentService.calloutMock = new SimpleMock(202,
            '{"id":"job-incr-456","status":"Pending"}');

        Test.startTest();
        DataCloudSegmentService.PublishJobResult result =
            DataCloudSegmentService.triggerSegmentRefresh('seg-001', false);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Incremental refresh succeeds');
        System.assertEquals('job-incr-456', result.jobId, 'Job Id set');
    }

    @IsTest
    static void testTriggerSegmentRefresh_blankSegmentId() {
        Test.startTest();
        DataCloudSegmentService.PublishJobResult result =
            DataCloudSegmentService.triggerSegmentRefresh('', true);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Blank Id should fail');
        System.assert(result.errorMessage.contains('required'), 'Error mentions required');
    }

    @IsTest
    static void testTriggerSegmentRefresh_apiError() {
        DataCloudSegmentService.calloutMock = new SimpleMock(500, '{"error":"server error"}');

        Test.startTest();
        DataCloudSegmentService.PublishJobResult result =
            DataCloudSegmentService.triggerSegmentRefresh('seg-001', true);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, '500 should fail');
        System.assert(result.errorMessage.contains('500'), 'Error mentions status code');
    }

    // ─── DataCloudSegmentService — getPublishJobStatus ────────────────────────

    @IsTest
    static void testGetPublishJobStatus_succeeded() {
        DataCloudSegmentService.calloutMock = new SimpleMock(200,
            '{"id":"job-abc","status":"Succeeded"}');

        Test.startTest();
        String status = DataCloudSegmentService.getPublishJobStatus('seg-001', 'job-abc');
        Test.stopTest();

        System.assertEquals('Succeeded', status, 'Status should be Succeeded');
    }

    @IsTest
    static void testGetPublishJobStatus_blankInputs() {
        Test.startTest();
        String r1 = DataCloudSegmentService.getPublishJobStatus('', 'job-001');
        String r2 = DataCloudSegmentService.getPublishJobStatus('seg-001', '');
        Test.stopTest();

        System.assertEquals(null, r1, 'Blank segment Id returns null');
        System.assertEquals(null, r2, 'Blank job Id returns null');
    }

    // ─── DataCloudSegmentService — assignWaterfallTier ────────────────────────

    @IsTest
    static void testAssignWaterfallTier_firstMatch() {
        // Profile is in seg-platinum and seg-gold → should get platinum (higher priority)
        String queryResp = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{ 'SegmentId__c' => 'seg-platinum' },
                new Map<String, Object>{ 'SegmentId__c' => 'seg-gold' }
            }
        });
        DataCloudSegmentService.calloutMock = new SimpleMock(200, queryResp);

        List<String> waterfall = new List<String>{
            'seg-platinum', 'seg-gold', 'seg-silver', 'seg-general'
        };

        Test.startTest();
        String tier = DataCloudSegmentService.assignWaterfallTier('uid-001', waterfall);
        Test.stopTest();

        System.assertEquals('seg-platinum', tier, 'Should assign highest priority segment');
    }

    @IsTest
    static void testAssignWaterfallTier_midMatch() {
        // Profile only in seg-silver
        String queryResp = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{ 'SegmentId__c' => 'seg-silver' }
            }
        });
        DataCloudSegmentService.calloutMock = new SimpleMock(200, queryResp);

        List<String> waterfall = new List<String>{
            'seg-platinum', 'seg-gold', 'seg-silver', 'seg-general'
        };

        Test.startTest();
        String tier = DataCloudSegmentService.assignWaterfallTier('uid-001', waterfall);
        Test.stopTest();

        System.assertEquals('seg-silver', tier, 'Should assign silver (first match)');
    }

    @IsTest
    static void testAssignWaterfallTier_noMatch() {
        DataCloudSegmentService.calloutMock = new SimpleMock(200, '{"data":[]}');

        Test.startTest();
        String tier = DataCloudSegmentService.assignWaterfallTier('uid-001',
            new List<String>{ 'seg-platinum', 'seg-gold' });
        Test.stopTest();

        System.assertEquals(null, tier, 'No match returns null (General tier)');
    }

    @IsTest
    static void testAssignWaterfallTier_blankInputs() {
        Test.startTest();
        String r1 = DataCloudSegmentService.assignWaterfallTier('', new List<String>{'seg-001'});
        String r2 = DataCloudSegmentService.assignWaterfallTier('uid-001', null);
        String r3 = DataCloudSegmentService.assignWaterfallTier('uid-001', new List<String>());
        Test.stopTest();

        System.assertEquals(null, r1, 'Blank Id returns null');
        System.assertEquals(null, r2, 'Null list returns null');
        System.assertEquals(null, r3, 'Empty list returns null');
    }

    // ─── DataCloudSegmentService — isOnSuppressionList ────────────────────────

    @IsTest
    static void testIsOnSuppressionList_suppressed() {
        DataCloudSegmentService.calloutMock = new SimpleMock(200,
            '{"data":[{"SegmentId__c":"seg-unsubscribed"}]}');

        Test.startTest();
        Boolean suppressed = DataCloudSegmentService.isOnSuppressionList(
            'uid-001', new List<String>{ 'seg-unsubscribed', 'seg-gdpr-out' }
        );
        Test.stopTest();

        System.assertEquals(true, suppressed, 'Profile on suppression list');
    }

    @IsTest
    static void testIsOnSuppressionList_notSuppressed() {
        DataCloudSegmentService.calloutMock = new SimpleMock(200, '{"data":[]}');

        Test.startTest();
        Boolean suppressed = DataCloudSegmentService.isOnSuppressionList(
            'uid-001', new List<String>{ 'seg-unsubscribed' }
        );
        Test.stopTest();

        System.assertEquals(false, suppressed, 'Profile not on suppression list');
    }

    @IsTest
    static void testIsOnSuppressionList_blankInputs() {
        Test.startTest();
        Boolean r1 = DataCloudSegmentService.isOnSuppressionList('', new List<String>{'seg'});
        Boolean r2 = DataCloudSegmentService.isOnSuppressionList('uid', null);
        Boolean r3 = DataCloudSegmentService.isOnSuppressionList('uid', new List<String>());
        Test.stopTest();

        System.assertEquals(false, r1, 'Blank Id = false');
        System.assertEquals(false, r2, 'Null list = false');
        System.assertEquals(false, r3, 'Empty list = false');
    }

    // ─── DataCloudSegmentService — getSegmentMemberCounts ────────────────────

    @IsTest
    static void testGetSegmentMemberCounts_twoSegments() {
        String queryResp = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{ 'SegmentId__c' => 'seg-A' },
                new Map<String, Object>{ 'SegmentId__c' => 'seg-A' },
                new Map<String, Object>{ 'SegmentId__c' => 'seg-B' }
            }
        });
        DataCloudSegmentService.calloutMock = new SimpleMock(200, queryResp);

        Test.startTest();
        Map<String, Integer> counts = DataCloudSegmentService.getSegmentMemberCounts(
            new List<String>{ 'seg-A', 'seg-B' }
        );
        Test.stopTest();

        System.assertEquals(2, counts.get('seg-A'), 'seg-A has 2 members');
        System.assertEquals(1, counts.get('seg-B'), 'seg-B has 1 member');
    }

    @IsTest
    static void testGetSegmentMemberCounts_emptyInput() {
        Test.startTest();
        Map<String, Integer> counts =
            DataCloudSegmentService.getSegmentMemberCounts(new List<String>());
        Test.stopTest();

        System.assertEquals(0, counts.size(), 'Empty input returns empty map');
    }

    // ─── DataCloudSegmentService — getActivationTargets ──────────────────────

    @IsTest
    static void testGetActivationTargets_found() {
        String body = JSON.serialize(new Map<String, Object>{
            'activations' => new List<Object>{
                new Map<String, Object>{
                    'id' => 'act-001', 'targetType' => 'MarketingCloud',
                    'status' => 'Active', 'recordCount' => 5000
                }
            }
        });
        DataCloudSegmentService.calloutMock = new SimpleMock(200, body);

        Test.startTest();
        List<DataCloudSegmentService.ActivationTarget> targets =
            DataCloudSegmentService.getActivationTargets('seg-001');
        Test.stopTest();

        System.assertEquals(1, targets.size(), 'One activation target');
        System.assertEquals('MarketingCloud', targets[0].targetType, 'Type correct');
        System.assertEquals('Active', targets[0].status, 'Status correct');
        System.assertEquals(5000, targets[0].recordCount, 'Record count correct');
    }

    @IsTest
    static void testGetActivationTargets_blankSegmentId() {
        Test.startTest();
        List<DataCloudSegmentService.ActivationTarget> targets =
            DataCloudSegmentService.getActivationTargets('');
        Test.stopTest();

        System.assertEquals(0, targets.size(), 'Blank Id returns empty list');
    }

    // ─── DataCloudSegmentService — triggerActivation ─────────────────────────

    @IsTest
    static void testTriggerActivation_success() {
        DataCloudSegmentService.calloutMock = new SimpleMock(202, '{}');

        Test.startTest();
        Boolean result = DataCloudSegmentService.triggerActivation('seg-001', 'act-001');
        Test.stopTest();

        System.assertEquals(true, result, 'Activation should succeed');
    }

    @IsTest
    static void testTriggerActivation_blankInputs() {
        Test.startTest();
        Boolean r1 = DataCloudSegmentService.triggerActivation('', 'act-001');
        Boolean r2 = DataCloudSegmentService.triggerActivation('seg-001', '');
        Test.stopTest();

        System.assertEquals(false, r1, 'Blank segment Id = false');
        System.assertEquals(false, r2, 'Blank activation Id = false');
    }

    // ─── DataCloudPersonalisationService — selectOffer ────────────────────────

    @IsTest
    static void testSelectOffer_platinum() {
        Test.startTest();
        DataCloudPersonalisationService.OfferDecision d =
            DataCloudPersonalisationService.selectOffer(55000, 0.9, 'renewal');
        Test.stopTest();

        System.assertEquals('PLATINUM_RENEWAL', d.offerCode, 'Platinum offer for LTV > $50K');
        System.assertEquals(20, d.discountPercent, '20% platinum discount');
    }

    @IsTest
    static void testSelectOffer_gold() {
        Test.startTest();
        DataCloudPersonalisationService.OfferDecision d =
            DataCloudPersonalisationService.selectOffer(15000, 0.5, null);
        Test.stopTest();

        System.assertEquals('GOLD_UPSELL', d.offerCode, 'Gold offer for LTV $10K–$50K');
        System.assertEquals(10, d.discountPercent, '10% gold discount');
    }

    @IsTest
    static void testSelectOffer_highEngagement() {
        Test.startTest();
        DataCloudPersonalisationService.OfferDecision d =
            DataCloudPersonalisationService.selectOffer(500, 0.85, null);
        Test.stopTest();

        System.assertEquals('ENGAGED_PROSPECT', d.offerCode,
            'Engaged prospect for high engagement score');
        System.assertEquals(5, d.discountPercent, '5% engaged discount');
    }

    @IsTest
    static void testSelectOffer_standard() {
        Test.startTest();
        DataCloudPersonalisationService.OfferDecision d =
            DataCloudPersonalisationService.selectOffer(0, 0.2, null);
        Test.stopTest();

        System.assertEquals('STANDARD', d.offerCode, 'Standard offer for low LTV + low engagement');
        System.assertEquals(0, d.discountPercent, 'No discount for standard');
    }

    // ─── DataCloudPersonalisationService — getPersonalisedOffer ──────────────

    @IsTest
    static void testGetPersonalisedOffer_platinumCustomer() {
        Contact c = new Contact(FirstName = 'Platinum', LastName = 'Customer');
        insert c;

        // Sequence: 1) Party Identification query → unified Id
        //           2) LTV insight query → LTV + engagement
        String pidResp = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{ 'UnifiedIndividualId__c' => 'uid-platinum' }
            }
        });
        String ltvResp = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{
                    'TotalLifetimeValue__c' => 65000,
                    'EngagementScore__c'    => 0.95
                }
            }
        });

        DataCloudPersonalisationService.calloutMock = new SequencedMock(
            new List<Integer>{ 200, 200 },
            new List<String>{ pidResp, ltvResp }
        );

        DataCloudPersonalisationService.PersonalisedOfferInput inp =
            new DataCloudPersonalisationService.PersonalisedOfferInput();
        inp.contactId = c.Id;

        Test.startTest();
        List<DataCloudPersonalisationService.PersonalisedOfferOutput> results =
            DataCloudPersonalisationService.getPersonalisedOffer(
                new List<DataCloudPersonalisationService.PersonalisedOfferInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed');
        System.assertEquals('PLATINUM_RENEWAL', results[0].offerCode, 'Platinum offer');
        System.assertEquals(20, results[0].discountPercent, '20% discount');
        System.assertEquals('uid-platinum', results[0].unifiedIndividualId, 'Unified Id set');
        System.assertEquals(65000, results[0].lifetimeValue, 'LTV set');
    }

    @IsTest
    static void testGetPersonalisedOffer_noUnifiedProfile() {
        Contact c = new Contact(FirstName = 'Unknown', LastName = 'Profile');
        insert c;

        // Party Identification query returns no results
        DataCloudPersonalisationService.calloutMock = new SimpleMock(200, '{"data":[]}');

        DataCloudPersonalisationService.PersonalisedOfferInput inp =
            new DataCloudPersonalisationService.PersonalisedOfferInput();
        inp.contactId = c.Id;

        Test.startTest();
        List<DataCloudPersonalisationService.PersonalisedOfferOutput> results =
            DataCloudPersonalisationService.getPersonalisedOffer(
                new List<DataCloudPersonalisationService.PersonalisedOfferInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Should succeed gracefully');
        System.assertEquals('DEFAULT', results[0].offerCode, 'Default offer when no profile');
    }

    // ─── DataCloudPersonalisationService — processDataAction ─────────────────

    @IsTest
    static void testProcessDataAction_segmentEntry() {
        Contact c = new Contact(FirstName = 'Action', LastName = 'Test');
        insert c;

        DataCloudPersonalisationService.DataActionPayload payload =
            new DataCloudPersonalisationService.DataActionPayload();
        payload.actionType          = 'SegmentEntry';
        payload.segmentId           = 'seg-high-value';
        payload.segmentName         = 'High Value Customers';
        payload.unifiedIndividualId = 'uid-001';
        payload.eventTime           = '2024-06-15T10:30:00Z';
        payload.attributes          = new Map<String, Object>{
            'ContactId__c' => (Object) String.valueOf(c.Id)
        };

        Test.startTest();
        DataCloudPersonalisationService.DataActionResult result =
            DataCloudPersonalisationService.processDataAction(payload);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Segment entry should succeed');
        System.assert(result.actionsSummary.contains('Contact description updated'),
            'Contact should be updated');
        System.assert(result.actionsSummary.contains('Follow-up task created'),
            'Task should be created');

        Contact updated = [SELECT Description FROM Contact WHERE Id = :c.Id];
        System.assert(updated.Description.contains('High Value Customers'),
            'Description should mention segment');

        List<Task> tasks = [SELECT Subject FROM Task WHERE WhoId = :c.Id];
        System.assertEquals(1, tasks.size(), 'One follow-up task created');
        System.assert(tasks[0].Subject.contains('High Value Customers'),
            'Task subject should mention segment');
    }

    @IsTest
    static void testProcessDataAction_segmentExit() {
        Contact c = new Contact(FirstName = 'Exit', LastName = 'Test');
        insert c;

        DataCloudPersonalisationService.DataActionPayload payload =
            new DataCloudPersonalisationService.DataActionPayload();
        payload.actionType = 'SegmentExit';
        payload.segmentName = 'At Risk';
        payload.eventTime   = '2024-06-15T11:00:00Z';
        payload.attributes  = new Map<String, Object>{
            'ContactId__c' => (Object) String.valueOf(c.Id)
        };

        Test.startTest();
        DataCloudPersonalisationService.DataActionResult result =
            DataCloudPersonalisationService.processDataAction(payload);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Segment exit should succeed');

        Contact updated = [SELECT Description FROM Contact WHERE Id = :c.Id];
        System.assert(updated.Description.contains('Exited'),
            'Description should mention exit');
    }

    @IsTest
    static void testProcessDataAction_nullPayload() {
        Test.startTest();
        DataCloudPersonalisationService.DataActionResult result =
            DataCloudPersonalisationService.processDataAction(null);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Null payload should fail');
        System.assert(result.errorMessage.contains('Invalid'), 'Error mentions invalid payload');
    }

    @IsTest
    static void testProcessDataAction_unknownActionType() {
        DataCloudPersonalisationService.DataActionPayload payload =
            new DataCloudPersonalisationService.DataActionPayload();
        payload.actionType = 'UnknownType';

        Test.startTest();
        DataCloudPersonalisationService.DataActionResult result =
            DataCloudPersonalisationService.processDataAction(payload);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Unknown action type should fail');
        System.assert(result.errorMessage.contains('Unknown'), 'Error should mention Unknown');
    }

    // ─── DataCloudPersonalisationService — streamCaseInteraction ─────────────

    @IsTest
    static void testStreamCaseInteraction_success() {
        Contact c = new Contact(FirstName = 'Stream', LastName = 'Test');
        insert c;
        Case theCase = new Case(
            Subject   = 'Test streaming',
            Status    = 'New',
            ContactId = c.Id
        );
        insert theCase;

        DataCloudIngestionService.calloutMock = new SimpleMock(202, '{}');
        DataCloudPersonalisationService.calloutMock = new SimpleMock(202, '{}');

        DataCloudPersonalisationService.StreamCaseInput inp =
            new DataCloudPersonalisationService.StreamCaseInput();
        inp.caseId           = theCase.Id;
        inp.overrideIndividualId = 'ind-manual-001';
        inp.engagementScore  = 0.6;

        Test.startTest();
        List<DataCloudPersonalisationService.StreamCaseOutput> results =
            DataCloudPersonalisationService.streamCaseInteraction(
                new List<DataCloudPersonalisationService.StreamCaseInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, 'Stream should succeed');
        System.assertEquals('ind-manual-001', results[0].individualId,
            'Override individualId used');
    }

    // ─── DataCloudPersonalisationService — syncHighLtvProfilesToCrm ──────────

    @IsTest
    static void testSyncHighLtvProfilesToCrm_createsTasks() {
        Contact c = new Contact(FirstName = 'HighLTV', LastName = 'Contact');
        insert c;

        String queryResp = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{
                    'PartyIdentificationNumber__c' => (Object) String.valueOf(c.Id),
                    'TotalLifetimeValue__c'         => 75000.00
                }
            }
        });
        DataCloudPersonalisationService.calloutMock = new SimpleMock(200, queryResp);

        Test.startTest();
        Integer count = DataCloudPersonalisationService.syncHighLtvProfilesToCrm(50000.00, 7);
        Test.stopTest();

        System.assertEquals(1, count, 'One task created');
        List<Task> tasks = [SELECT Subject, Priority, ActivityDate FROM Task WHERE WhoId = :c.Id];
        System.assertEquals(1, tasks.size(), 'Task exists');
        System.assertEquals('High', tasks[0].Priority, 'High priority task');
        System.assertEquals(Date.today().addDays(7), tasks[0].ActivityDate,
            'Due in 7 days');
        System.assert(tasks[0].Subject.contains('75,000'), 'Subject includes LTV');
    }

    @IsTest
    static void testSyncHighLtvProfilesToCrm_apiError() {
        DataCloudPersonalisationService.calloutMock = new SimpleMock(500, '{}');

        Test.startTest();
        Integer count = DataCloudPersonalisationService.syncHighLtvProfilesToCrm(10000.00, 5);
        Test.stopTest();

        System.assertEquals(0, count, 'Zero tasks on API error');
    }

    // ─── DataCloudPersonalisationService — getStreamingInsightScore ──────────

    @IsTest
    static void testGetStreamingInsightScore_found() {
        DataCloudPersonalisationService.calloutMock = new SimpleMock(200, JSON.serialize(
            new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{ 'PropensityScore__c' => '0.87' }
                }
            }
        ));

        Test.startTest();
        Decimal score = DataCloudPersonalisationService.getStreamingInsightScore(
            'uid-001', 'PurchasePropensity', 'PropensityScore__c'
        );
        Test.stopTest();

        System.assertNotEquals(null, score, 'Score should be returned');
        System.assertEquals(0.87, score, 'Score should be 0.87');
    }

    @IsTest
    static void testGetStreamingInsightScore_notFound() {
        DataCloudPersonalisationService.calloutMock = new SimpleMock(200, '{"data":[]}');

        Test.startTest();
        Decimal score = DataCloudPersonalisationService.getStreamingInsightScore(
            'uid-001', 'PurchasePropensity', 'PropensityScore__c'
        );
        Test.stopTest();

        System.assertEquals(null, score, 'Null when no data');
    }

    @IsTest
    static void testGetStreamingInsightScore_blankId() {
        Test.startTest();
        Decimal score = DataCloudPersonalisationService.getStreamingInsightScore(
            '', 'SomeInsight', 'Score__c'
        );
        Test.stopTest();

        System.assertEquals(null, score, 'Blank Id returns null');
    }

    @IsTest
    static void testGetStreamingInsightScore_appendsDlmSuffix() {
        DataCloudPersonalisationService.calloutMock = new SimpleMock(200,
            '{"data":[{"Score__c":"0.5"}]}');

        Test.startTest();
        // Pass name without __dlm — suffix should be auto-appended
        Decimal score = DataCloudPersonalisationService.getStreamingInsightScore(
            'uid-001', 'EngagementScore', 'Score__c'
        );
        Test.stopTest();

        System.assertEquals(0.5, score, '__dlm suffix auto-appended, score returned');
    }

    // ─── DataCloudPersonalisationService — resolveContactIdFromAttributes ─────

    @IsTest
    static void testResolveContactIdFromAttributes() {
        Contact c = new Contact(FirstName = 'Attr', LastName = 'Test');
        insert c;

        Test.startTest();
        Id result1 = DataCloudPersonalisationService.resolveContactIdFromAttributes(
            new Map<String, Object>{ 'ContactId__c' => (Object) String.valueOf(c.Id) }
        );
        Id result2 = DataCloudPersonalisationService.resolveContactIdFromAttributes(null);
        Id result3 = DataCloudPersonalisationService.resolveContactIdFromAttributes(
            new Map<String, Object>{ 'OtherId__c' => 'no-contact-key' }
        );
        Id result4 = DataCloudPersonalisationService.resolveContactIdFromAttributes(
            new Map<String, Object>{ 'ContactId__c' => 'not-valid-id' }
        );
        Test.stopTest();

        System.assertEquals(c.Id, result1, 'Valid Contact Id resolved');
        System.assertEquals(null, result2, 'Null map returns null');
        System.assertEquals(null, result3, 'Missing ContactId__c returns null');
        System.assertEquals(null, result4, 'Invalid Id string returns null');
    }
}
