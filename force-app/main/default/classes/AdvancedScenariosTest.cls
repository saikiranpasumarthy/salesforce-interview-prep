/**
 * Day 40 — Advanced Scenarios & Cross-Cloud Architecture Tests
 * Covers: AdvancedScenariosService + CrossCloudArchitectureService
 */
@IsTest
private class AdvancedScenariosTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // AdvancedScenariosService — Composite API builder
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testBuildCompositeRequest_defaultsAllOrNoneTrue() {
        Test.startTest();
        AdvancedScenariosService.CompositeRequest req =
            AdvancedScenariosService.buildCompositeRequest(null);
        Test.stopTest();

        System.assertEquals(true, req.allOrNone);
        System.assertEquals(0, req.subrequests.size());
    }

    @IsTest
    static void testAddSubrequest_appendsToList() {
        AdvancedScenariosService.CompositeRequest req =
            AdvancedScenariosService.buildCompositeRequest(true);

        Test.startTest();
        AdvancedScenariosService.addSubrequest(
            req, 'ref1', 'post', '/services/data/v59.0/sobjects/Account',
            new Map<String, Object>{ 'Name' => 'Test Corp' }
        );
        Test.stopTest();

        System.assertEquals(1, req.subrequests.size());
        System.assertEquals('ref1', req.subrequests[0].referenceId);
        System.assertEquals('POST', req.subrequests[0].method); // uppercased
    }

    @IsTest
    static void testBuildLeadConversionComposite_threeSubrequests() {
        Test.startTest();
        AdvancedScenariosService.CompositeRequest comp =
            AdvancedScenariosService.buildLeadConversionComposite(
                'ACME Corp', 'John', 'Doe', 'john@acme.com', 'ACME Deal', 50000
            );
        Test.stopTest();

        System.assertEquals(3, comp.subrequests.size());
        System.assertEquals('newAccount',     comp.subrequests[0].referenceId);
        System.assertEquals('newContact',     comp.subrequests[1].referenceId);
        System.assertEquals('newOpportunity', comp.subrequests[2].referenceId);
        // Verify reference ID usage in contact body
        System.assertEquals(
            '@{newAccount.id}',
            (String) comp.subrequests[1].body.get('AccountId')
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AdvancedScenariosService — Agentforce custom action
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetAccountHealthScore_healthyAccount() {
        Account acc = new Account(Name = 'HealthyAccount');
        insert acc;
        // No cases, recent activity (LastActivityDate updated by insert)

        AdvancedScenariosService.AccountHealthInput inp =
            new AdvancedScenariosService.AccountHealthInput();
        inp.accountId = acc.Id;

        Test.startTest();
        List<AdvancedScenariosService.AccountHealthOutput> outputs =
            AdvancedScenariosService.getAccountHealthScore(
                new List<AdvancedScenariosService.AccountHealthInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertNotEquals(null, outputs[0].healthScore);
        System.assertNotEquals(null, outputs[0].healthLabel);
        System.assertNotEquals(null, outputs[0].recommendation);
    }

    @IsTest
    static void testGetAccountHealthScore_criticalAccountWithCases() {
        Account acc = new Account(Name = 'CriticalAccount');
        insert acc;

        // Insert 5 open cases
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 5; i++) {
            cases.add(new Case(AccountId = acc.Id, Subject = 'Issue ' + i, Status = 'New'));
        }
        insert cases;

        AdvancedScenariosService.AccountHealthInput inp =
            new AdvancedScenariosService.AccountHealthInput();
        inp.accountId = acc.Id;

        Test.startTest();
        List<AdvancedScenariosService.AccountHealthOutput> outputs =
            AdvancedScenariosService.getAccountHealthScore(
                new List<AdvancedScenariosService.AccountHealthInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assert(outputs[0].healthScore <= 60,
            'Expected degraded score due to open cases: ' + outputs[0].healthScore);
        System.assertEquals(5, outputs[0].openCaseCount);
    }

    @IsTest
    static void testGetAccountHealthScore_unknownAccountId() {
        AdvancedScenariosService.AccountHealthInput inp =
            new AdvancedScenariosService.AccountHealthInput();
        inp.accountId = '001000000000000AAA'; // non-existent

        Test.startTest();
        List<AdvancedScenariosService.AccountHealthOutput> outputs =
            AdvancedScenariosService.getAccountHealthScore(
                new List<AdvancedScenariosService.AccountHealthInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals(0, outputs[0].healthScore);
        System.assertEquals('Unknown', outputs[0].healthLabel);
    }

    @IsTest
    static void testGetAccountHealthScore_emptyInputs() {
        Test.startTest();
        List<AdvancedScenariosService.AccountHealthOutput> outputs =
            AdvancedScenariosService.getAccountHealthScore(null);
        Test.stopTest();

        System.assertEquals(0, outputs.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AdvancedScenariosService — Token bucket rate limiter
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testConsumeToken_allowsUpToCapacity() {
        AdvancedScenariosService.tokenBuckets.clear();

        Test.startTest();
        Boolean first  = AdvancedScenariosService.consumeToken('TestSvc', 3);
        Boolean second = AdvancedScenariosService.consumeToken('TestSvc', 3);
        Boolean third  = AdvancedScenariosService.consumeToken('TestSvc', 3);
        Boolean fourth = AdvancedScenariosService.consumeToken('TestSvc', 3);
        Test.stopTest();

        System.assertEquals(true,  first);
        System.assertEquals(true,  second);
        System.assertEquals(true,  third);
        System.assertEquals(false, fourth); // bucket empty
    }

    @IsTest
    static void testGetRemainingTokens_reflectsConsumption() {
        AdvancedScenariosService.tokenBuckets.clear();
        AdvancedScenariosService.consumeToken('MySvc', 5);
        AdvancedScenariosService.consumeToken('MySvc', 5);

        Test.startTest();
        Integer remaining = AdvancedScenariosService.getRemainingTokens('MySvc');
        Test.stopTest();

        System.assertEquals(3, remaining);
    }

    @IsTest
    static void testRefillTokens_resetsToCapacity() {
        AdvancedScenariosService.tokenBuckets.clear();
        AdvancedScenariosService.consumeToken('RefillSvc', 2);
        AdvancedScenariosService.consumeToken('RefillSvc', 2);

        Test.startTest();
        AdvancedScenariosService.refillTokens('RefillSvc', 10);
        Integer remaining = AdvancedScenariosService.getRemainingTokens('RefillSvc');
        Test.stopTest();

        System.assertEquals(10, remaining);
    }

    @IsTest
    static void testGetRemainingTokens_unknownServiceReturnsMinus1() {
        AdvancedScenariosService.tokenBuckets.clear();

        Test.startTest();
        Integer remaining = AdvancedScenariosService.getRemainingTokens('UnknownSvc');
        Test.stopTest();

        System.assertEquals(-1, remaining);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AdvancedScenariosService — Multi-org record sync
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testSyncAccount_nullPayloadReturnsError() {
        Test.startTest();
        AdvancedScenariosService.SyncResult result =
            AdvancedScenariosService.syncAccountFromRemote(null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('externalId'));
    }

    @IsTest
    static void testSyncAccount_blankExternalIdReturnsError() {
        AdvancedScenariosService.AccountSyncPayload payload =
            new AdvancedScenariosService.AccountSyncPayload();
        payload.externalId = '';
        payload.name = 'Test';

        Test.startTest();
        AdvancedScenariosService.SyncResult result =
            AdvancedScenariosService.syncAccountFromRemote(payload);
        Test.stopTest();

        System.assertEquals(false, result.success);
    }

    @IsTest
    static void testComputeFingerprint_deterministicForSameInput() {
        List<String> values = new List<String>{ 'ACME', 'Tech', '555-1234', '1000000' };

        Test.startTest();
        String fp1 = AdvancedScenariosService.computeFingerprint(values);
        String fp2 = AdvancedScenariosService.computeFingerprint(values);
        Test.stopTest();

        System.assertEquals(fp1, fp2);
        System.assertEquals(16, fp1.length());
    }

    @IsTest
    static void testComputeFingerprint_differentForDifferentInput() {
        Test.startTest();
        String fp1 = AdvancedScenariosService.computeFingerprint(
            new List<String>{ 'ACME', 'Tech' }
        );
        String fp2 = AdvancedScenariosService.computeFingerprint(
            new List<String>{ 'BETA', 'Finance' }
        );
        Test.stopTest();

        System.assertNotEquals(fp1, fp2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AdvancedScenariosService — Bulk API job lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testCreateBulkIngestJob_calloutMock() {
        Test.setMock(HttpCalloutMock.class, new BulkJobMock(200,
            '{"id":"7503000000ABCDE","state":"Open"}'));

        Test.startTest();
        AdvancedScenariosService.BulkJobResult result =
            AdvancedScenariosService.createBulkIngestJob(
                'Account', 'insert', null, 'MyOrg'
            );
        Test.stopTest();

        System.assertEquals(true,  result.success);
        System.assertEquals('7503000000ABCDE', result.jobId);
        System.assertEquals('Open', result.state);
    }

    @IsTest
    static void testCreateBulkIngestJob_errorResponse() {
        Test.setMock(HttpCalloutMock.class, new BulkJobMock(400, '{"error":"Bad Request"}'));

        Test.startTest();
        AdvancedScenariosService.BulkJobResult result =
            AdvancedScenariosService.createBulkIngestJob(
                'Account', 'insert', null, 'MyOrg'
            );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('failed'));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AdvancedScenariosService — Idempotent webhook receiver
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testVerifyHmacSignature_correctSignature() {
        String payload = '{"event":"test"}';
        String secret  = 'my-shared-secret';
        Blob mac = Crypto.generateMac(
            'HmacSHA256', Blob.valueOf(payload), Blob.valueOf(secret)
        );
        String sig = EncodingUtil.convertToHex(mac);

        Test.startTest();
        Boolean valid = AdvancedScenariosService.verifyHmacSignature(payload, sig, secret);
        Test.stopTest();

        System.assertEquals(true, valid);
    }

    @IsTest
    static void testVerifyHmacSignature_wrongSignatureReturnsFalse() {
        Test.startTest();
        Boolean valid = AdvancedScenariosService.verifyHmacSignature(
            '{"event":"test"}', 'deadbeef1234', 'my-secret'
        );
        Test.stopTest();

        System.assertEquals(false, valid);
    }

    @IsTest
    static void testVerifyHmacSignature_blankSecretReturnsFalse() {
        Test.startTest();
        Boolean valid = AdvancedScenariosService.verifyHmacSignature(
            '{}', 'somesig', ''
        );
        Test.stopTest();

        System.assertEquals(false, valid);
    }

    @IsTest
    static void testProcessWebhook_badSignatureRejected() {
        Test.startTest();
        AdvancedScenariosService.WebhookResult result =
            AdvancedScenariosService.processInboundWebhook(
                'wh-001', '{"key":"value"}', 'badsig', 'secret123'
            );
        Test.stopTest();

        System.assertEquals(false, result.accepted);
        System.assert(result.message.contains('Signature verification failed'));
    }

    @IsTest
    static void testProcessWebhook_validSignatureAccepted() {
        String payload = '{"action":"create","entityId":"001xxx"}';
        String secret  = 'webhook-secret';
        Blob mac = Crypto.generateMac(
            'HmacSHA256', Blob.valueOf(payload), Blob.valueOf(secret)
        );
        String sig = EncodingUtil.convertToHex(mac);

        Test.startTest();
        AdvancedScenariosService.WebhookResult result =
            AdvancedScenariosService.processInboundWebhook('wh-002', payload, sig, secret);
        Test.stopTest();

        System.assertEquals(true, result.accepted);
        System.assertEquals(false, result.isDuplicate);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CrossCloudArchitectureService — Data Cloud activation
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testHandleDataCloudActivation_nullPayload() {
        Test.startTest();
        CrossCloudArchitectureService.ActivationResult result =
            CrossCloudArchitectureService.handleDataCloudActivation(null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('Empty'));
    }

    @IsTest
    static void testHandleDataCloudActivation_malformedJson() {
        Test.startTest();
        CrossCloudArchitectureService.ActivationResult result =
            CrossCloudArchitectureService.handleDataCloudActivation('not-json{{{');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('Malformed'));
    }

    @IsTest
    static void testHandleDataCloudActivation_emptyMemberProfiles() {
        String payload = JSON.serialize(new Map<String, Object>{
            'segmentName' => 'HighValue',
            'memberProfiles' => new List<Object>()
        });

        Test.startTest();
        CrossCloudArchitectureService.ActivationResult result =
            CrossCloudArchitectureService.handleDataCloudActivation(payload);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(0, result.updatedCount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CrossCloudArchitectureService — Revenue Cloud quote routing
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testRouteQuote_executiveTierForLargeAmount() {
        Account acc = new Account(Name = 'BigDeal Corp');
        insert acc;

        Test.startTest();
        CrossCloudArchitectureService.QuoteApprovalResult result =
            CrossCloudArchitectureService.routeQuoteForApproval(
                acc.Id, 600000, 'STANDARD'
            );
        Test.stopTest();

        System.assertEquals('EXECUTIVE', result.approvalTier);
        System.assert(result.requiredSigners.contains('CFO'));
        System.assertEquals(24, result.slaHours);
    }

    @IsTest
    static void testRouteQuote_directorTierForHighDiscount() {
        Account acc = new Account(Name = 'HighDiscount Corp');
        insert acc;

        Test.startTest();
        CrossCloudArchitectureService.QuoteApprovalResult result =
            CrossCloudArchitectureService.routeQuoteForApproval(acc.Id, 50000, 'HIGH');
        Test.stopTest();

        System.assertEquals('DIRECTOR', result.approvalTier);
        System.assertEquals(8, result.slaHours);
    }

    @IsTest
    static void testRouteQuote_autoApproveForSmallAmount() {
        Account acc = new Account(Name = 'SmallDeal Corp');
        insert acc;

        Test.startTest();
        CrossCloudArchitectureService.QuoteApprovalResult result =
            CrossCloudArchitectureService.routeQuoteForApproval(acc.Id, 5000, 'STANDARD');
        Test.stopTest();

        System.assertEquals('AUTO_APPROVE', result.approvalTier);
        System.assertEquals(0, result.slaHours);
        System.assertEquals(0, result.requiredSigners.size());
    }

    @IsTest
    static void testRouteQuote_strategicAlwaysExecutive() {
        Account acc = new Account(Name = 'Strategic Corp');
        insert acc;

        Test.startTest();
        CrossCloudArchitectureService.QuoteApprovalResult result =
            CrossCloudArchitectureService.routeQuoteForApproval(acc.Id, 1000, 'STRATEGIC');
        Test.stopTest();

        // Even small amounts are EXECUTIVE if STRATEGIC discount category
        System.assertEquals('EXECUTIVE', result.approvalTier);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CrossCloudArchitectureService — Agentforce grounding
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetAccountContextForAgent_validAccount() {
        Account acc = new Account(Name = 'GroundingTest', Industry = 'Technology');
        insert acc;

        CrossCloudArchitectureService.AgentContextInput inp =
            new CrossCloudArchitectureService.AgentContextInput();
        inp.accountId = acc.Id;

        Test.startTest();
        List<CrossCloudArchitectureService.AgentContextOutput> outputs =
            CrossCloudArchitectureService.getAccountContextForAgent(
                new List<CrossCloudArchitectureService.AgentContextInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assert(outputs[0].contextSummary.contains('GroundingTest'));
        System.assert(outputs[0].contextSummary.contains('Technology'));
    }

    @IsTest
    static void testGetAccountContextForAgent_unknownAccount() {
        CrossCloudArchitectureService.AgentContextInput inp =
            new CrossCloudArchitectureService.AgentContextInput();
        inp.accountId = '001000000000000AAA';

        Test.startTest();
        List<CrossCloudArchitectureService.AgentContextOutput> outputs =
            CrossCloudArchitectureService.getAccountContextForAgent(
                new List<CrossCloudArchitectureService.AgentContextInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assert(outputs[0].contextSummary.contains('No account data'));
    }

    @IsTest
    static void testGetAccountContextForAgent_nullInput() {
        Test.startTest();
        List<CrossCloudArchitectureService.AgentContextOutput> outputs =
            CrossCloudArchitectureService.getAccountContextForAgent(null);
        Test.stopTest();

        System.assertEquals(0, outputs.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CrossCloudArchitectureService — Canonical response builder
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testBuildCanonicalSuccessResponse_containsRequiredFields() {
        Test.startTest();
        String response = CrossCloudArchitectureService.buildCanonicalSuccessResponse(
            'corr-abc123', new Map<String, String>{ 'id' => '123' }
        );
        Test.stopTest();

        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(response);
        System.assertEquals(true,         parsed.get('success'));
        System.assertEquals('corr-abc123', parsed.get('correlationId'));
        System.assertNotEquals(null,       parsed.get('timestamp'));
        System.assertNotEquals(null,       parsed.get('data'));
    }

    @IsTest
    static void testBuildCanonicalErrorResponse_containsErrorFields() {
        Test.startTest();
        String response = CrossCloudArchitectureService.buildCanonicalErrorResponse(
            'corr-err1', 'NOT_FOUND', 'Account not found'
        );
        Test.stopTest();

        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(response);
        System.assertEquals(false,           parsed.get('success'));
        System.assertEquals('NOT_FOUND',     parsed.get('errorCode'));
        System.assertEquals('Account not found', parsed.get('errorMessage'));
        System.assertEquals('corr-err1',     parsed.get('correlationId'));
    }

    @IsTest
    static void testErrorCodeToHttpStatus_allCodesHaveMapping() {
        for (CrossCloudArchitectureService.IntegrationErrorCode code :
             CrossCloudArchitectureService.IntegrationErrorCode.values()) {
            String status = CrossCloudArchitectureService.errorCodeToHttpStatus(code);
            System.assertNotEquals(null, status, 'Missing mapping for: ' + code.name());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Mock HTTP callout
    // ═══════════════════════════════════════════════════════════════════════════

    private class BulkJobMock implements HttpCalloutMock {
        private final Integer statusCode;
        private final String  body;
        BulkJobMock(Integer code, String body) { statusCode = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }
}
