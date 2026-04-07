/**
 * Day 36 — System Design & Multi-Cloud Architecture — Test Suite
 *
 * Coverage:
 *  SystemDesignService: Circuit Breaker state machine, Idempotency Guard,
 *    Governor Limit Tracker, Bulk Processor, Retry with Exponential Backoff.
 *  MultiCloudOrchestrator: Platform Event publishing, Lead 360 routing,
 *    Case routing matrix, Saga success + compensation, Dead Letter Queue.
 */
@IsTest
private class SystemDesignTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // Circuit Breaker — state machine
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void circuitBreaker_initialStateClosed() {
        SystemDesignService.resetCircuit('PaymentService');

        System.assertEquals(
            SystemDesignService.CircuitState.CLOSED,
            SystemDesignService.getState('PaymentService'),
            'New circuit should be CLOSED'
        );
        System.assert(
            SystemDesignService.allowRequest('PaymentService'),
            'CLOSED circuit should allow requests'
        );
    }

    @IsTest
    static void circuitBreaker_opensAfterFailureThreshold() {
        SystemDesignService.resetCircuit('InventoryService');
        SystemDesignService.FAILURE_THRESHOLD = 3;

        // Record failures up to threshold
        SystemDesignService.recordFailure('InventoryService');
        SystemDesignService.recordFailure('InventoryService');
        System.assertEquals(
            SystemDesignService.CircuitState.CLOSED,
            SystemDesignService.getState('InventoryService'),
            'Should still be CLOSED at 2 failures (threshold=3)'
        );

        SystemDesignService.recordFailure('InventoryService');
        System.assertEquals(
            SystemDesignService.CircuitState.OPEN,
            SystemDesignService.getState('InventoryService'),
            'Should be OPEN after 3rd failure'
        );
    }

    @IsTest
    static void circuitBreaker_openRejectsAllRequests() {
        SystemDesignService.resetCircuit('ShippingService');
        SystemDesignService.FAILURE_THRESHOLD  = 2;
        SystemDesignService.RESET_TIMEOUT_SECS = 9999; // far future → stays OPEN

        SystemDesignService.recordFailure('ShippingService');
        SystemDesignService.recordFailure('ShippingService');

        System.assert(
            !SystemDesignService.allowRequest('ShippingService'),
            'OPEN circuit must reject all requests'
        );
    }

    @IsTest
    static void circuitBreaker_transitionsToHalfOpenAfterTimeout() {
        SystemDesignService.resetCircuit('CrmSync');
        SystemDesignService.FAILURE_THRESHOLD  = 1;
        SystemDesignService.RESET_TIMEOUT_SECS = 0; // timeout = 0 → immediate transition

        SystemDesignService.recordFailure('CrmSync');
        System.assertEquals(
            SystemDesignService.CircuitState.OPEN,
            SystemDesignService.getState('CrmSync')
        );

        // Set openedAt to the past to simulate timeout elapsed
        SystemDesignService.circuitRegistry.get('CrmSync').openedAt =
            DateTime.now().addMinutes(-2).getTime();

        // allowRequest should now transition OPEN → HALF_OPEN
        Boolean allowed = SystemDesignService.allowRequest('CrmSync');
        System.assertEquals(
            SystemDesignService.CircuitState.HALF_OPEN,
            SystemDesignService.getState('CrmSync'),
            'Should transition to HALF_OPEN after reset timeout'
        );
        System.assert(allowed, 'First HALF_OPEN probe should be allowed');
    }

    @IsTest
    static void circuitBreaker_halfOpenClosesOnSuccess() {
        SystemDesignService.resetCircuit('DataSync');
        // Manually set to HALF_OPEN
        SystemDesignService.CircuitBreakerState st =
            SystemDesignService.circuitRegistry.get('DataSync');
        st.circuitState = SystemDesignService.CircuitState.HALF_OPEN;

        SystemDesignService.recordSuccess('DataSync');

        System.assertEquals(
            SystemDesignService.CircuitState.CLOSED,
            SystemDesignService.getState('DataSync'),
            'Success in HALF_OPEN should close the circuit'
        );
        System.assertEquals(0,
            SystemDesignService.circuitRegistry.get('DataSync').failureCount,
            'Failure count should reset to 0'
        );
    }

    @IsTest
    static void circuitBreaker_halfOpenProbeLimitExceeded() {
        SystemDesignService.resetCircuit('ExtAPI');
        SystemDesignService.HALF_OPEN_PROBE_MAX = 2;
        SystemDesignService.CircuitBreakerState st =
            SystemDesignService.circuitRegistry.get('ExtAPI');
        st.circuitState  = SystemDesignService.CircuitState.HALF_OPEN;
        st.halfOpenCalls = 2; // already at limit

        System.assert(
            !SystemDesignService.allowRequest('ExtAPI'),
            'Probe limit exhausted — should reject request'
        );
    }

    @IsTest
    static void circuitBreaker_resetRestoresClosedState() {
        SystemDesignService.FAILURE_THRESHOLD = 1;
        SystemDesignService.recordFailure('ERP');
        System.assertEquals(SystemDesignService.CircuitState.OPEN, SystemDesignService.getState('ERP'));

        SystemDesignService.resetCircuit('ERP');
        System.assertEquals(SystemDesignService.CircuitState.CLOSED, SystemDesignService.getState('ERP'));
        System.assert(SystemDesignService.allowRequest('ERP'));
    }

    @IsTest
    static void circuitBreaker_multipleServicesIndependent() {
        SystemDesignService.FAILURE_THRESHOLD = 2;
        SystemDesignService.resetCircuit('ServiceA');
        SystemDesignService.resetCircuit('ServiceB');

        SystemDesignService.recordFailure('ServiceA');
        SystemDesignService.recordFailure('ServiceA');

        System.assertEquals(SystemDesignService.CircuitState.OPEN,   SystemDesignService.getState('ServiceA'));
        System.assertEquals(SystemDesignService.CircuitState.CLOSED, SystemDesignService.getState('ServiceB'),
            'ServiceB should be unaffected by ServiceA failures');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Idempotency Guard — graceful degradation
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void isAlreadyProcessed_blankKey_returnsFalse() {
        System.assert(!SystemDesignService.isAlreadyProcessed(''));
        System.assert(!SystemDesignService.isAlreadyProcessed(null));
    }

    @IsTest
    static void isAlreadyProcessed_objectNotProvisioned_returnsFalse() {
        // IdempotencyKey__c not in scratch org → graceful degradation
        Boolean result = SystemDesignService.isAlreadyProcessed('PLATFORM_EVENT:LEAD_SCORED:001xxx');
        System.assert(!result, 'Should return false when object not provisioned');
    }

    @IsTest
    static void markProcessed_blankKey_noOp() {
        // Should not throw
        SystemDesignService.markProcessed('');
        SystemDesignService.markProcessed(null);
        System.assert(true, 'Blank key should be silently ignored');
    }

    @IsTest
    static void markProcessed_objectNotProvisioned_graceful() {
        // Should not throw when IdempotencyKey__c not provisioned
        SystemDesignService.markProcessed('PLATFORM_EVENT:TEST:12345');
        System.assert(true, 'Should degrade gracefully without the custom object');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Governor Limit Tracker
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void snapshotLimits_returnsNonNullValues() {
        SystemDesignService.LimitSnapshot snap = SystemDesignService.snapshotLimits();
        System.assertNotEquals(null, snap);
        System.assert(snap.dmlLimit > 0,  'DML limit should be positive');
        System.assert(snap.soqlLimit > 0, 'SOQL limit should be positive');
        System.assert(snap.cpuLimit > 0,  'CPU limit should be positive');
    }

    @IsTest
    static void snapshotLimits_percentageCalculations() {
        SystemDesignService.LimitSnapshot snap = SystemDesignService.snapshotLimits();
        System.assert(snap.dmlPct()  >= 0 && snap.dmlPct()  <= 100, 'DML %  must be 0-100');
        System.assert(snap.soqlPct() >= 0 && snap.soqlPct() <= 100, 'SOQL % must be 0-100');
        System.assert(snap.cpuPct()  >= 0 && snap.cpuPct()  <= 100, 'CPU %  must be 0-100');
    }

    @IsTest
    static void safeBatchSize_normal() {
        Integer sz = SystemDesignService.safeBatchSize(200, 500);
        System.assertEquals(200, sz, 'Plenty of remaining rows → use full desired size');
    }

    @IsTest
    static void safeBatchSize_constrainedByRemaining() {
        Integer sz = SystemDesignService.safeBatchSize(200, 50);
        System.assertEquals(40, sz, '50 remaining - 10 buffer = 40');
    }

    @IsTest
    static void safeBatchSize_zeroRemaining() {
        Integer sz = SystemDesignService.safeBatchSize(200, 0);
        System.assertEquals(0, sz, 'Zero remaining → batch size 0');
    }

    @IsTest
    static void hasHeadroom_belowThreshold() {
        System.assert( SystemDesignService.hasHeadroom(50, 50), '50%/50% = headroom OK');
        System.assert( SystemDesignService.hasHeadroom(84, 84), '84%/84% = just under limit');
    }

    @IsTest
    static void hasHeadroom_atOrAboveThreshold() {
        System.assert(!SystemDesignService.hasHeadroom(85, 50), 'DML at 85% → no headroom');
        System.assert(!SystemDesignService.hasHeadroom(50, 85), 'CPU at 85% → no headroom');
        System.assert(!SystemDesignService.hasHeadroom(90, 90), 'Both at 90% → no headroom');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Retry with Exponential Backoff
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void calculateBackoffMs_exponentialSequence() {
        System.assertEquals(1000,  SystemDesignService.calculateBackoffMs(1), 'Attempt 1 = 1 s');
        System.assertEquals(2000,  SystemDesignService.calculateBackoffMs(2), 'Attempt 2 = 2 s');
        System.assertEquals(4000,  SystemDesignService.calculateBackoffMs(3), 'Attempt 3 = 4 s');
        System.assertEquals(8000,  SystemDesignService.calculateBackoffMs(4), 'Attempt 4 = 8 s');
        System.assertEquals(16000, SystemDesignService.calculateBackoffMs(5), 'Attempt 5 = 16 s');
    }

    @IsTest
    static void calculateBackoffMs_cappedAt60s() {
        System.assertEquals(60000, SystemDesignService.calculateBackoffMs(10), 'Attempt 10 capped at 60 s');
        System.assertEquals(60000, SystemDesignService.calculateBackoffMs(20), 'Attempt 20 capped at 60 s');
    }

    @IsTest
    static void calculateBackoffMs_nullOrZeroAttempt() {
        System.assertEquals(1000, SystemDesignService.calculateBackoffMs(null), 'null → defaults to attempt 1');
        System.assertEquals(1000, SystemDesignService.calculateBackoffMs(0),    '0 → defaults to attempt 1');
    }

    @IsTest
    static void shouldRetry_maxAttemptsReached() {
        System.assert(!SystemDesignService.shouldRetry(3, 3, '500'), 'At max → do not retry');
        System.assert(!SystemDesignService.shouldRetry(5, 3, '500'), 'Beyond max → do not retry');
    }

    @IsTest
    static void shouldRetry_nonRetryableHttpCodes() {
        System.assert(!SystemDesignService.shouldRetry(1, 5, '400'), '400 Bad Request → non-retryable');
        System.assert(!SystemDesignService.shouldRetry(1, 5, '401'), '401 Unauthorized → non-retryable');
        System.assert(!SystemDesignService.shouldRetry(1, 5, '403'), '403 Forbidden → non-retryable');
        System.assert(!SystemDesignService.shouldRetry(1, 5, '404'), '404 Not Found → non-retryable');
        System.assert(!SystemDesignService.shouldRetry(1, 5, '422'), '422 Unprocessable → non-retryable');
    }

    @IsTest
    static void shouldRetry_retryableHttpCodes() {
        System.assert(SystemDesignService.shouldRetry(1, 5, '500'), '500 Internal Error → retryable');
        System.assert(SystemDesignService.shouldRetry(1, 5, '503'), '503 Service Unavailable → retryable');
        System.assert(SystemDesignService.shouldRetry(1, 5, '429'), '429 Rate Limited → retryable');
        System.assert(SystemDesignService.shouldRetry(2, 5, '502'), '502 Bad Gateway → retryable');
    }

    @IsTest
    static void shouldRetry_nullInputs() {
        System.assert(!SystemDesignService.shouldRetry(null, 5, '500'));
        System.assert(!SystemDesignService.shouldRetry(1, null, '500'));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Bulk Processor
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void processInChunks_emptyList() {
        SystemDesignService.BulkProcessResult result =
            SystemDesignService.processInChunks(new List<Id>(), 200, 'AccountProcessor');
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('No records'));
    }

    @IsTest
    static void processInChunks_blankProcessorClass() {
        SystemDesignService.BulkProcessResult result =
            SystemDesignService.processInChunks(new List<Id>{ UserInfo.getUserId() }, 200, '');
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void processInChunks_smallList_processedInTransaction() {
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 5; i++) accs.add(new Account(Name = 'Bulk ' + i));
        insert accs;
        List<Id> ids = new List<Id>();
        for (Account a : accs) ids.add(a.Id);

        Test.startTest();
        SystemDesignService.BulkProcessResult result =
            SystemDesignService.processInChunks(ids, 200, 'AccountEnrichmentProcessor');
        Test.stopTest();

        System.assert(result.isSuccess);
        System.assertEquals(5, result.processed + result.deferred,
            'All 5 records should be accounted for');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Lead 360 Orchestration — routing decisions
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void determineLeadRouting_highScoreCategoryA() {
        System.assertEquals('AGENTFORCE_HIGH_VALUE',
            MultiCloudOrchestrator.determineLeadRouting(85, 'A'));
    }

    @IsTest
    static void determineLeadRouting_highScoreNotCategoryA() {
        System.assertEquals('SALES_DIRECT',
            MultiCloudOrchestrator.determineLeadRouting(80, 'B'),
            'Score 80 but category B → Sales Direct, not Agentforce');
    }

    @IsTest
    static void determineLeadRouting_mediumScore() {
        System.assertEquals('SALES_DIRECT',
            MultiCloudOrchestrator.determineLeadRouting(65, null));
        System.assertEquals('SALES_DIRECT',
            MultiCloudOrchestrator.determineLeadRouting(60, 'C'));
    }

    @IsTest
    static void determineLeadRouting_lowScore() {
        System.assertEquals('NURTURE_SEQUENCE',
            MultiCloudOrchestrator.determineLeadRouting(40, 'D'));
    }

    @IsTest
    static void determineLeadRouting_nullScore() {
        System.assertEquals('NURTURE_SEQUENCE',
            MultiCloudOrchestrator.determineLeadRouting(null, null),
            'Null score → nurture sequence (cannot determine value)');
    }

    @IsTest
    static void orchestrateLead360_nullId() {
        MultiCloudOrchestrator.Lead360Result result =
            MultiCloudOrchestrator.orchestrateLead360(null);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void orchestrateLead360_success() {
        Lead l = new Lead(
            FirstName = 'Taylor', LastName = 'Smith',
            Company = 'Acme Corp', Status = 'Open - Not Contacted'
        );
        insert l;

        Test.startTest();
        MultiCloudOrchestrator.Lead360Result result =
            MultiCloudOrchestrator.orchestrateLead360(l.Id);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should succeed: ' + result.error);
        System.assertEquals('Taylor Smith', result.leadName);
        System.assertEquals('NURTURE_SEQUENCE', result.routingDecision,
            'No Einstein score available → nurture sequence');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Event-driven Case Routing
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void determineCaseQueue_allPaths() {
        System.assertEquals('Critical_Response_Queue', MultiCloudOrchestrator.determineCaseQueue('Critical', 'Phone'));
        System.assertEquals('High_Priority_Queue',     MultiCloudOrchestrator.determineCaseQueue('High',     'Phone'));
        System.assertEquals('Email_Queue',             MultiCloudOrchestrator.determineCaseQueue('Medium',   'Email'));
        System.assertEquals('Web_Queue',               MultiCloudOrchestrator.determineCaseQueue('Low',      'Web'));
        System.assertEquals('General_Support_Queue',   MultiCloudOrchestrator.determineCaseQueue('Medium',   'Phone'));
        System.assertEquals('General_Support_Queue',   MultiCloudOrchestrator.determineCaseQueue(null,       null));
    }

    @IsTest
    static void routeCase_nullId() {
        MultiCloudOrchestrator.CaseRoutingResult result =
            MultiCloudOrchestrator.routeCaseEventDriven(null);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void routeCase_criticalPriority_escalates() {
        Account acc = new Account(Name = 'Routing Test');
        insert acc;
        Case c = new Case(AccountId = acc.Id, Subject = 'System Down', Priority = 'Critical', Origin = 'Phone');
        insert c;

        Test.startTest();
        MultiCloudOrchestrator.CaseRoutingResult result =
            MultiCloudOrchestrator.routeCaseEventDriven(c.Id);
        Test.stopTest();

        // isSuccess may be false if CrossCloudEvent__e not provisioned — check routing
        System.assertEquals('Critical_Response_Queue', result.targetQueue);
        System.assert(result.escalate, 'Critical priority must trigger escalation');
    }

    @IsTest
    static void routeCase_standardPriority_noEscalation() {
        Account acc = new Account(Name = 'Standard Case Test');
        insert acc;
        Case c = new Case(AccountId = acc.Id, Subject = 'General Query', Priority = 'Low', Origin = 'Web');
        insert c;

        MultiCloudOrchestrator.CaseRoutingResult result =
            MultiCloudOrchestrator.routeCaseEventDriven(c.Id);

        System.assertEquals('Web_Queue', result.targetQueue);
        System.assert(!result.escalate);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Platform Event publishing
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishCrossCloudEvent_blankEventType() {
        MultiCloudOrchestrator.EventPublishResult result =
            MultiCloudOrchestrator.publishCrossCloudEvent('', null, null);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void publishCrossCloudEvent_platformEventNotProvisioned_graceful() {
        // CrossCloudEvent__e doesn't exist in scratch org → structured error, no exception
        MultiCloudOrchestrator.EventPublishResult result =
            MultiCloudOrchestrator.publishCrossCloudEvent(
                'TEST_EVENT',
                UserInfo.getUserId(),
                new Map<String, Object>{ 'test' => true }
            );
        System.assertNotEquals(null, result, 'Must never return null');
    }

    @IsTest
    static void generateCorrelationId_isUnique() {
        String id1 = MultiCloudOrchestrator.generateCorrelationId();
        String id2 = MultiCloudOrchestrator.generateCorrelationId();
        System.assertEquals(32, id1.length(), 'Correlation Id should be 32 hex chars');
        System.assertNotEquals(id1, id2,       'Each call should generate a unique Id');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Saga Pattern
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void saga_nullQuoteId() {
        MultiCloudOrchestrator.SagaResult result =
            MultiCloudOrchestrator.executeQuoteToOrderSaga(null);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void saga_quoteNotFound_failsAndCompensates() {
        Id fakeQuoteId = '0Q0000000000001AAA';

        Test.startTest();
        MultiCloudOrchestrator.SagaResult result =
            MultiCloudOrchestrator.executeQuoteToOrderSaga(fakeQuoteId);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Non-existent quote → saga should fail');
        System.assertNotEquals(null, result.error);
        System.assert(result.sagaId.startsWith('Q2O_'), 'sagaId should include quote prefix');
    }

    @IsTest
    static void saga_allStepsSucceed() {
        // Full setup for a valid Quote in 'Presented' status
        Account acc = new Account(Name = 'Saga Test Account');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'Saga Test Opp', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Id pb2Id = Test.getStandardPricebookId();
        Quote q = new Quote(
            Name = 'Saga Test Quote', OpportunityId = opp.Id,
            Pricebook2Id = pb2Id, Status = 'Presented'
        );
        insert q;

        Test.startTest();
        MultiCloudOrchestrator.SagaResult result =
            MultiCloudOrchestrator.executeQuoteToOrderSaga(q.Id);
        Test.stopTest();

        System.assert(result.isSuccess, 'All saga steps should succeed: ' + result.error);
        System.assertNotEquals(null, result.sagaId);
        // Verify Order was created as part of the saga
        List<Order> orders = [SELECT Id FROM Order WHERE AccountId = :acc.Id];
        System.assertEquals(1, orders.size(), 'Saga should have created 1 Order');
    }

    @IsTest
    static void saga_invalidQuoteStatus_failsAndCompensates() {
        Account acc = new Account(Name = 'Invalid Status Saga');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'Status Test', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Draft Quote', OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'  // Invalid for Q2O saga
        );
        insert q;

        Test.startTest();
        MultiCloudOrchestrator.SagaResult result =
            MultiCloudOrchestrator.executeQuoteToOrderSaga(q.Id);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Draft quote should fail saga validation');
        // Verify no orphaned Order was left behind (compensation ran)
        List<Order> orphanedOrders = [SELECT Id FROM Order WHERE AccountId = :acc.Id];
        System.assertEquals(0, orphanedOrders.size(), 'Compensation should have prevented Order creation');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Dead Letter Queue
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void sendToDeadLetterQueue_blankMessageId() {
        MultiCloudOrchestrator.DlqResult result =
            MultiCloudOrchestrator.sendToDeadLetterQueue('', 'payload', 'error', 3);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void sendToDeadLetterQueue_objectNotProvisioned_graceful() {
        // DeadLetterMessage__c doesn't exist in scratch org → structured failure, no exception
        MultiCloudOrchestrator.DlqResult result =
            MultiCloudOrchestrator.sendToDeadLetterQueue(
                'MSG-001', '{"event":"LEAD_SCORED"}', 'Connection timeout', 5
            );
        System.assertNotEquals(null, result, 'Must never return null');
        // Either isSuccess=true (if object exists) or isSuccess=false with error message
        if (!result.isSuccess) {
            System.assertNotEquals(null, result.error, 'Failed DLQ must include error message');
        }
    }
}
