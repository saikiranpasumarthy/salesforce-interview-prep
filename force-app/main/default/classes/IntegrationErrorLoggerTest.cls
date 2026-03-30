/**
 * @description Tests for IntegrationErrorLogger (Platform Event publisher) and
 *              IntegrationErrorLogTrigger (Platform Event subscriber).
 *
 *              Platform Event testing in Apex (API 48.0+):
 *                - EventBus.publish() inside Test.startTest() enqueues events but does
 *                  NOT fire the subscriber trigger automatically.
 *                - Test.getEventBus().deliver() forces the subscriber trigger to fire
 *                  synchronously within the test transaction. Must be called INSIDE
 *                  Test.startTest() / Test.stopTest() for accurate async simulation.
 *                - Without deliver(), you can only assert that publish() succeeded
 *                  (SaveResult check) — the Integration_Error_Log__c records won't exist.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
@IsTest
private class IntegrationErrorLoggerTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // IntegrationErrorLogger — publish API
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void log_singleError_publishesEventAndSubscriberWritesLog() {
        Test.startTest();
        IntegrationErrorLogger.log(
            'TestClass.testMethod',
            'FIELD_CUSTOM_VALIDATION_EXCEPTION: Field required',
            'FIELD_CUSTOM_VALIDATION_EXCEPTION',
            '0010000000ABC123'
        );
        // Force subscriber trigger to execute within test transaction
        Test.getEventBus().deliver();
        Test.stopTest();

        List<Integration_Error_Log__c> logs = [
            SELECT Context__c, Error_Message__c, Status_Code__c, Record_Id__c
            FROM   Integration_Error_Log__c
        ];
        System.assertEquals(1, logs.size(),
            'One Integration_Error_Log__c should be created by subscriber trigger');
        System.assertEquals('TestClass.testMethod',          logs[0].Context__c);
        System.assertEquals('FIELD_CUSTOM_VALIDATION_EXCEPTION', logs[0].Status_Code__c);
        System.assertEquals('0010000000ABC123',               logs[0].Record_Id__c);
    }

    @IsTest
    static void logSaveResults_multipleFailures_allLogged() {
        // Simulate two failed SaveResult records
        Account acc1 = TestDataFactory.createAccount(
            new Map<String,Object>{'Name' => 'Fail Account 1'}, true
        );
        Account acc2 = TestDataFactory.createAccount(
            new Map<String,Object>{'Name' => 'Fail Account 2'}, true
        );

        // Force DML failures by attempting to update with a required field violation
        List<Account> badUpdates = new List<Account>{
            new Account(Id = acc1.Id, Name = ''),  // Name is required
            new Account(Id = acc2.Id, Name = '')
        };

        List<Database.SaveResult> results = Database.update(badUpdates, false);

        Test.startTest();
        IntegrationErrorLogger.logSaveResults(
            results,
            'IntegrationErrorLoggerTest.logSaveResults_multipleFailures_allLogged'
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        List<Integration_Error_Log__c> logs = [
            SELECT Context__c, Status_Code__c
            FROM   Integration_Error_Log__c
        ];
        System.assertEquals(2, logs.size(),
            'Two DML failures should produce two Integration_Error_Log__c records');
        for (Integration_Error_Log__c logRecord : logs) {
            System.assertNotEquals(null, logRecord.Status_Code__c,
                'Each log record should carry the Salesforce StatusCode from the DML error');
        }
    }

    @IsTest
    static void logSaveResults_allSuccessful_noEventsPublished() {
        Account acc = TestDataFactory.createAccount(true);
        List<Database.SaveResult> results = Database.update(
            new List<Account>{ new Account(Id = acc.Id, Name = 'Updated Name') },
            false
        );

        Test.startTest();
        IntegrationErrorLogger.logSaveResults(results, 'TestContext');
        Test.getEventBus().deliver();
        Test.stopTest();

        Integer logCount = [SELECT COUNT() FROM Integration_Error_Log__c];
        System.assertEquals(0, logCount,
            'No log records should be created when all SaveResults are successful');
    }

    @IsTest
    static void logException_catchedException_writesStackTrace() {
        String recordId = '0010000000ABC999';

        Test.startTest();
        try {
            Integer result = 1 / 0; // Force a MathException
        } catch (MathException ex) {
            IntegrationErrorLogger.logException('TestClass.divisionMethod', ex, recordId);
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        List<Integration_Error_Log__c> logs = [
            SELECT Error_Message__c, Status_Code__c, Record_Id__c
            FROM   Integration_Error_Log__c
        ];
        System.assertEquals(1, logs.size(), 'One log record expected for caught exception');
        System.assertEquals('EXCEPTION', logs[0].Status_Code__c,
            'Exception logs should carry EXCEPTION as the status code');
        System.assertEquals(recordId, logs[0].Record_Id__c);
        System.assert(logs[0].Error_Message__c.contains('MathException'),
            'Error message should include exception type name');
    }

    @IsTest
    static void log_contextExceeds255Chars_truncatedGracefully() {
        String longContext = 'A'.repeat(300); // 300 chars — exceeds Text(255) limit

        Test.startTest();
        IntegrationErrorLogger.log(longContext, 'Test message', '500', null);
        Test.getEventBus().deliver();
        Test.stopTest();

        Integration_Error_Log__c log = [
            SELECT Context__c FROM Integration_Error_Log__c LIMIT 1
        ];
        System.assert(log.Context__c.length() <= 255,
            'Context should be truncated to 255 chars by abbreviate() before publish');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IntegrationErrorLogTrigger — subscriber
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void subscriberTrigger_bulkEvents_allWrittenToCustomObject() {
        // Publish 10 events in one call — subscriber must handle bulk delivery
        Test.startTest();
        for (Integer i = 0; i < 10; i++) {
            IntegrationErrorLogger.log(
                'BulkTest.method' + i,
                'Bulk error ' + i,
                'DML_EXCEPTION',
                '001000000000' + String.valueOf(i).leftPad(6, '0')
            );
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Integration_Error_Log__c];
        System.assertEquals(10, count,
            'All 10 platform events should result in 10 Integration_Error_Log__c records');
    }

    @IsTest
    static void subscriberTrigger_replayIdPopulated_onLogRecord() {
        Test.startTest();
        IntegrationErrorLogger.log('ReplayTest', 'Test error', '400', null);
        Test.getEventBus().deliver();
        Test.stopTest();

        Integration_Error_Log__c log = [
            SELECT Replay_Id__c FROM Integration_Error_Log__c LIMIT 1
        ];
        // ReplayId is a platform-assigned string — assert it is populated (not null)
        System.assertNotEquals(null, log.Replay_Id__c,
            'ReplayId should be populated by the subscriber trigger from the event record');
    }
}
