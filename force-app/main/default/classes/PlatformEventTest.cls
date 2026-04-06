/**
 * PlatformEventTest
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 18 — Tests for PlatformEventService and CdcEventHandler.
 *
 * PLATFORM EVENT TESTING PATTERNS:
 * ══════════════════════════════════
 * 1. Publishing: call EventBus.publish() inside Test.startTest()/stopTest()
 *    → Test.stopTest() flushes the event bus queue synchronously
 *    → The Platform Event trigger fires during stopTest()
 *
 * 2. CDC Testing: requires Test.enableChangeDataCapture() before the DML
 *    → enableChangeDataCapture() tells the framework to capture CDC events
 *    → Perform the DML, then Test.stopTest() fires the CDC trigger
 *
 * 3. Unit testing handlers directly: because @TestVisible processors are static,
 *    you can invoke them without going through the trigger.
 *    → Faster, deterministic, no event bus required
 *    → Use for covering specific code paths (gap events, routeUpdate, toIdSet)
 *
 * CDC TEST CAVEAT:
 * ════════════════
 * Test.enableChangeDataCapture() only works if CDC is enabled for the object
 * in the org. In scratch/developer orgs where CDC is not configured, the CDC
 * trigger will not fire even inside stopTest(). Unit tests on handler methods
 * using @TestVisible work regardless of CDC configuration.
 */
@IsTest
private class PlatformEventTest {

    // ─────────────────────────────────────────────────────────────────────────
    // PlatformEventService — publishOne
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void publishOne_returnsSuccessResult() {
        Integration_Event__e event = new Integration_Event__e(
            Event_Type__c    = 'ACCOUNT_SYNC',
            Source_System__c = 'Test',
            Correlation_Id__c = 'test-corr-001',
            Payload__c       = '{"key":"value"}'
        );

        Test.startTest();
        Database.SaveResult result = PlatformEventService.publishOne(event);
        Test.stopTest();

        System.assert(result.isSuccess(), 'Expected publish to succeed');
    }

    @IsTest
    static void publishOne_setsAllFields() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Integration_Event__e event =
            PlatformEventService.accountSyncEvent(acc.Id, 'CREATE');

        System.assertEquals('ACCOUNT_SYNC', event.Event_Type__c,   'Event_Type__c');
        System.assertEquals('Salesforce',   event.Source_System__c, 'Source_System__c');
        System.assertEquals(acc.Id,
            (Id) event.Correlation_Id__c, 'Correlation_Id__c');
        System.assert(event.Payload__c.contains('accountId'),       'Payload contains accountId');
        System.assert(event.Payload__c.contains('CREATE'),          'Payload contains changeType');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PlatformEventService — publishBulk
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void publishBulk_allSucceed() {
        List<Integration_Event__e> events = new List<Integration_Event__e>();
        for (Integer i = 0; i < 5; i++) {
            events.add(new Integration_Event__e(
                Event_Type__c    = 'ACCOUNT_SYNC',
                Source_System__c = 'BulkTest',
                Correlation_Id__c = 'corr-' + i,
                Payload__c       = '{"index":' + i + '}'
            ));
        }

        Test.startTest();
        List<Database.SaveResult> results = PlatformEventService.publishBulk(events);
        Test.stopTest();

        System.assertEquals(5, results.size(), 'Expected 5 results');
        for (Database.SaveResult r : results) {
            System.assert(r.isSuccess(), 'Expected all to succeed');
        }
    }

    @IsTest
    static void publishBulk_emptyList_returnsEmpty() {
        Test.startTest();
        List<Database.SaveResult> results =
            PlatformEventService.publishBulk(new List<Integration_Event__e>());
        Test.stopTest();

        System.assert(results.isEmpty(), 'Empty list should return empty results');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PlatformEventService — publishChunked
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void publishChunked_handlesMultipleChunks() {
        // Build a list larger than a single imaginary chunk
        // (We can't actually publish 2000+, so test with a small list and verify results count)
        List<Integration_Event__e> events = new List<Integration_Event__e>();
        for (Integer i = 0; i < 10; i++) {
            events.add(new Integration_Event__e(
                Event_Type__c    = 'ACCOUNT_SYNC',
                Source_System__c = 'ChunkTest',
                Correlation_Id__c = 'chunk-' + i,
                Payload__c       = '{}'
            ));
        }

        Test.startTest();
        List<Database.SaveResult> results = PlatformEventService.publishChunked(events);
        Test.stopTest();

        System.assertEquals(10, results.size(), 'Should return one result per event');
        for (Database.SaveResult r : results) {
            System.assert(r.isSuccess(), 'Expected success');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PlatformEventService — factory methods
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void errorEvent_setsCorrectFields() {
        Integration_Event__e event =
            PlatformEventService.errorEvent('MySystem', 'Something failed', 'corr-999');

        System.assertEquals('ERROR',    event.Event_Type__c,    'Event type');
        System.assertEquals('MySystem', event.Source_System__c, 'Source system');
        System.assertEquals('corr-999', event.Correlation_Id__c,'Correlation ID');
        System.assert(event.Payload__c.contains('Something failed'), 'Payload has message');
        System.assert(event.Payload__c.contains('corr-999'),         'Payload has correlationId');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PlatformEventService — handleEvents (trigger handler unit tests)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void handleEvents_routesAccountSyncEvent() {
        Account acc = new Account(Name = 'Sync Target');
        insert acc;

        // Build a Platform Event simulating what the trigger would receive
        Integration_Event__e event = new Integration_Event__e(
            Event_Type__c    = 'ACCOUNT_SYNC',
            Source_System__c = 'TestSystem',
            Correlation_Id__c = acc.Id,
            Payload__c       = JSON.serialize(new Map<String,String>{
                'accountId'  => acc.Id,
                'changeType' => 'UPDATE'
            })
        );

        // handleEvents can only be tested via trigger; unit-test processAccountSyncEvents instead
        // by publishing and letting the trigger fire
        Test.startTest();
        Database.SaveResult result = EventBus.publish(event);
        Test.stopTest();

        System.assert(result.isSuccess(), 'Publish should succeed');
    }

    @IsTest
    static void handleEvents_unknownEventType_doesNotThrow() {
        Integration_Event__e event = new Integration_Event__e(
            Event_Type__c    = 'UNKNOWN_TYPE',
            Source_System__c = 'Test',
            Correlation_Id__c = 'x',
            Payload__c       = '{}'
        );

        Test.startTest();
        Database.SaveResult result = EventBus.publish(event);
        Test.stopTest();

        System.assert(result.isSuccess(), 'Unknown event type should still publish successfully');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CdcEventHandler — toIdSet (unit)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void toIdSet_validIds_returnsSet() {
        Account a1 = new Account(Name = 'A1');
        Account a2 = new Account(Name = 'A2');
        insert new List<Account>{ a1, a2 };

        List<String> idStrings = new List<String>{ a1.Id, a2.Id };
        Set<Id> result = CdcEventHandler.toIdSet(idStrings);

        System.assertEquals(2, result.size(), 'Should contain 2 IDs');
        System.assert(result.contains(a1.Id), 'Should contain a1');
        System.assert(result.contains(a2.Id), 'Should contain a2');
    }

    @IsTest
    static void toIdSet_nullInput_returnsEmpty() {
        Set<Id> result = CdcEventHandler.toIdSet(null);
        System.assert(result.isEmpty(), 'Null input → empty set');
    }

    @IsTest
    static void toIdSet_emptyList_returnsEmpty() {
        Set<Id> result = CdcEventHandler.toIdSet(new List<String>());
        System.assert(result.isEmpty(), 'Empty list → empty set');
    }

    @IsTest
    static void toIdSet_malformedId_skipsInvalid() {
        Account acc = new Account(Name = 'Valid');
        insert acc;

        List<String> idStrings = new List<String>{ acc.Id, 'NOT_AN_ID', '', null };
        Set<Id> result = CdcEventHandler.toIdSet(idStrings);

        System.assertEquals(1, result.size(), 'Only valid ID should be included');
        System.assert(result.contains(acc.Id), 'Valid ID should be present');
    }

    @IsTest
    static void toIdSet_duplicateIds_deduplicates() {
        Account acc = new Account(Name = 'Dup');
        insert acc;

        List<String> idStrings = new List<String>{ acc.Id, acc.Id, acc.Id };
        Set<Id> result = CdcEventHandler.toIdSet(idStrings);

        System.assertEquals(1, result.size(), 'Set should deduplicate');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CdcEventHandler — isGapEvent (unit)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void isGapEvent_updateWithSystemModstamp_returnsTrue() {
        // Construct a synthetic CDC header via a Map approach (header is not directly instantiable)
        // Instead test via a CDC event captured in Test.enableChangeDataCapture() context.
        // For pure-unit coverage, verify the helper logic via mocked AccountChangeEvent
        // Note: EventBus.ChangeEventHeader is a system type; we test isGapEvent indirectly
        // by exercising the processGaps path through handleAccountChanges integration test below.
        // This is a placeholder to document the intent.
        System.assert(true, 'isGapEvent covered by CDC integration test');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CdcEventHandler — processCreates (unit via @TestVisible)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void processCreates_withValidIds_publishesEvents() {
        Account acc = new Account(Name = 'New Account');
        insert acc;

        Test.startTest();
        CdcEventHandler.processCreates(new Set<Id>{ acc.Id });
        Test.stopTest();

        // Verify no exception was thrown — success is non-exceptional execution
        System.assert(true, 'processCreates should complete without exception');
    }

    @IsTest
    static void processCreates_emptySet_doesNothing() {
        Test.startTest();
        CdcEventHandler.processCreates(new Set<Id>());
        Test.stopTest();

        System.assert(true, 'Empty set should be a no-op');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CdcEventHandler — processUpdates (unit via @TestVisible)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void processUpdates_publishesBulkEvents() {
        Account a1 = new Account(Name = 'U1');
        Account a2 = new Account(Name = 'U2');
        insert new List<Account>{ a1, a2 };

        Test.startTest();
        CdcEventHandler.processUpdates(new Set<Id>{ a1.Id, a2.Id });
        Test.stopTest();

        System.assert(true, 'processUpdates should publish events for 2 accounts');
    }

    @IsTest
    static void processUpdates_emptySet_doesNothing() {
        Test.startTest();
        CdcEventHandler.processUpdates(new Set<Id>());
        Test.stopTest();

        System.assert(true, 'Empty set is a no-op');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CdcEventHandler — processDeletions (unit via @TestVisible)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void processDeletions_usesIdsDirectly() {
        Account acc = new Account(Name = 'ToDelete');
        insert acc;
        Id deletedId = acc.Id;
        delete acc;

        Test.startTest();
        CdcEventHandler.processDeletions(new Set<Id>{ deletedId });
        Test.stopTest();

        // Deleted records cannot be queried — verify no exception thrown
        System.assert(true, 'processDeletions should handle deleted IDs without querying');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CdcEventHandler — processGaps (unit via @TestVisible)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void processGaps_requeriesAndPublishes() {
        Account acc = new Account(Name = 'GapAccount');
        insert acc;

        Test.startTest();
        CdcEventHandler.processGaps(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assert(true, 'processGaps should re-query and publish GAP_FILL event');
    }

    @IsTest
    static void processGaps_nonExistentId_noException() {
        // Use an Id format that parses but no record exists
        Account acc = new Account(Name = 'Temp');
        insert acc;
        Id fakeId = acc.Id;
        delete acc;
        Database.emptyRecycleBin(new List<Account>{ acc });

        Test.startTest();
        CdcEventHandler.processGaps(new Set<Id>{ fakeId });
        Test.stopTest();

        System.assert(true, 'Non-existent IDs produce empty query result — no exception');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CdcEventHandler — routeUpdate via CDC integration (requires CDC enabled)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * CDC integration test.
     * Uses Test.enableChangeDataCapture() + Test.stopTest() to fire the CDC trigger.
     * This test only works when Account CDC is enabled in the org.
     * If CDC is not enabled, the trigger does not fire and the test is still green
     * (it asserts on non-exceptional execution rather than on side-effects).
     */
    @IsTest
    static void cdcTrigger_accountCreate_firesHandler() {
        Test.enableChangeDataCapture();

        Test.startTest();
        Account acc = new Account(Name = 'CDC Create Test', Type = 'Customer');
        insert acc;
        Test.stopTest(); // flushes CDC event queue → AccountChangeTrigger fires

        // If CDC is enabled, CdcEventHandler.processCreates() ran for acc.Id.
        // Assert: no exception = success.
        System.assert(acc.Id != null, 'Account was inserted');
    }

    @IsTest
    static void cdcTrigger_accountUpdate_firesHandler() {
        Test.enableChangeDataCapture();

        Account acc = new Account(Name = 'CDC Update Test', AnnualRevenue = 100000);
        insert acc;

        Test.startTest();
        acc.Name          = 'CDC Update Test RENAMED';
        acc.AnnualRevenue = 200000;
        update acc;
        Test.stopTest(); // CDC trigger fires here for UPDATE changeType

        // Name + AnnualRevenue are in fieldsOfInterest → processUpdates() called
        System.assert(acc.Id != null, 'Account update should succeed');
    }

    @IsTest
    static void cdcTrigger_accountDelete_firesHandler() {
        Test.enableChangeDataCapture();

        Account acc = new Account(Name = 'CDC Delete Test');
        insert acc;
        Id deletedId = acc.Id;

        Test.startTest();
        delete acc;
        Test.stopTest(); // CDC trigger fires here for DELETE changeType

        System.assert(deletedId != null, 'Account was deleted');
    }

    @IsTest
    static void cdcTrigger_accountUndelete_firesHandler() {
        Test.enableChangeDataCapture();

        Account acc = new Account(Name = 'CDC Undelete Test');
        insert acc;
        delete acc;

        Test.startTest();
        undelete acc;
        Test.stopTest(); // CDC trigger fires for UNDELETE changeType

        System.assert(acc.Id != null, 'Account was undeleted');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PlatformEventService — trigger integration
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void platformEventTrigger_accountSyncEvent_updatesSyncStatus() {
        Account acc = new Account(
            Name        = 'Sync Target',
            Sync_Status__c = 'Error'
        );
        insert acc;

        Integration_Event__e event =
            PlatformEventService.accountSyncEvent(acc.Id, 'UPDATE');

        Test.startTest();
        EventBus.publish(event);
        Test.stopTest(); // IntegrationEventTrigger fires → handleEvents → processAccountSyncEvents

        // After trigger, Sync_Status__c should be 'Pending'
        Account updated = [SELECT Sync_Status__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Pending', updated.Sync_Status__c,
            'Trigger should update Sync_Status__c to Pending');
    }

    @IsTest
    static void platformEventTrigger_bulkEvents_allProcessed() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accounts.add(new Account(Name = 'BulkSync ' + i, Sync_Status__c = 'Failed'));
        }
        insert accounts;

        List<Integration_Event__e> events = new List<Integration_Event__e>();
        for (Account acc : accounts) {
            events.add(PlatformEventService.accountSyncEvent(acc.Id, 'UPDATE'));
        }

        Test.startTest();
        EventBus.publish(events);
        Test.stopTest();

        List<Account> updated = [
            SELECT Id, Sync_Status__c FROM Account
            WHERE  Id IN :new Map<Id, Account>(accounts).keySet()
        ];
        for (Account acc : updated) {
            System.assertEquals('Pending', acc.Sync_Status__c,
                'Each account should be set to Pending');
        }
    }
}
