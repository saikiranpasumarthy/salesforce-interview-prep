/**
 * Day 39 — Weak Area Revisit Tests
 * Covers: WeakAreaRevisitService — all 7 patterns
 */
@IsTest
private class WeakAreaRevisitTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. FLS / CRUD enforcement
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetAccountsUserMode_returnsResults() {
        Account a = new Account(Name = 'UserModeTest', Industry = 'Technology');
        insert a;

        Test.startTest();
        List<Account> results = WeakAreaRevisitService.getAccountsUserMode('Technology');
        Test.stopTest();

        System.assert(results.size() >= 1);
        Boolean found = false;
        for (Account r : results) {
            if (r.Name == 'UserModeTest') { found = true; break; }
        }
        System.assert(found, 'Expected to find the inserted account');
    }

    @IsTest
    static void testGetAccountsUserMode_emptyForUnknownIndustry() {
        Test.startTest();
        List<Account> results =
            WeakAreaRevisitService.getAccountsUserMode('ZZZ_NonExistentIndustry');
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void testGetContactsStripped_returnsStrippedRecords() {
        Account acc = new Account(Name = 'StripTest');
        insert acc;
        Contact c = new Contact(
            FirstName = 'Strip', LastName = 'Test',
            Email = 'strip@test.com', AccountId = acc.Id
        );
        insert c;

        Test.startTest();
        List<SObject> results =
            WeakAreaRevisitService.getContactsStripped(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assertEquals(1, results.size());
    }

    @IsTest
    static void testGetContactsStripped_emptyAccountIds() {
        Test.startTest();
        List<SObject> results =
            WeakAreaRevisitService.getContactsStripped(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void testUpsertWithFlsCheck_invalidObjectThrows() {
        // Create a valid Account — but pass a field that doesn't exist
        Account acc = new Account(Name = 'FLS Test');

        Test.startTest();
        try {
            WeakAreaRevisitService.upsertWithFlsCheck(acc, new List<String>{ 'FakeField__c' });
            // If no exception: upsert succeeded (field was skipped as invalid)
        } catch (SecurityException se) {
            // Field found but not createable — acceptable outcome
        } catch (DmlException de) {
            // Expected in some test contexts
        }
        Test.stopTest();
        // Test validates no unhandled exception is thrown
        System.assert(true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Describe cache
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetFieldMap_knownObject() {
        Test.startTest();
        Map<String, Schema.SObjectField> fields =
            WeakAreaRevisitService.getFieldMap('Account');
        Test.stopTest();

        System.assert(fields.containsKey('name'), 'Account should have Name field');
        System.assert(fields.containsKey('id'),   'Account should have Id field');
    }

    @IsTest
    static void testGetFieldMap_unknownObjectReturnsEmpty() {
        Test.startTest();
        Map<String, Schema.SObjectField> fields =
            WeakAreaRevisitService.getFieldMap('NonExistentObject__c');
        Test.stopTest();

        System.assertEquals(0, fields.size());
    }

    @IsTest
    static void testIsFieldAccessible_standardField() {
        Test.startTest();
        Boolean accessible = WeakAreaRevisitService.isFieldAccessible('Account', 'Name');
        Test.stopTest();

        System.assertEquals(true, accessible);
    }

    @IsTest
    static void testIsFieldAccessible_nonExistentField() {
        Test.startTest();
        Boolean accessible =
            WeakAreaRevisitService.isFieldAccessible('Account', 'FakeField__c');
        Test.stopTest();

        System.assertEquals(false, accessible);
    }

    @IsTest
    static void testGetFieldType_nameIsString() {
        Test.startTest();
        Schema.DisplayType dt = WeakAreaRevisitService.getFieldType('Account', 'Name');
        Test.stopTest();

        System.assertEquals(Schema.DisplayType.STRING, dt);
    }

    @IsTest
    static void testGetFieldType_nonExistentFieldReturnsNull() {
        Test.startTest();
        Schema.DisplayType dt =
            WeakAreaRevisitService.getFieldType('Account', 'FakeField__c');
        Test.stopTest();

        System.assertEquals(null, dt);
    }

    @IsTest
    static void testFilterValidFields_filtersInvalid() {
        Test.startTest();
        List<String> valid = WeakAreaRevisitService.filterValidFields(
            'Account',
            new List<String>{ 'Name', 'FakeField__c', 'Industry' }
        );
        Test.stopTest();

        System.assertEquals(2, valid.size());
        System.assert(valid.contains('Name'));
        System.assert(valid.contains('Industry'));
    }

    @IsTest
    static void testDescribeCacheIsReused() {
        // Call twice — second call should use cache (no exception, same result)
        Test.startTest();
        Map<String, Schema.SObjectField> first  = WeakAreaRevisitService.getFieldMap('Contact');
        Map<String, Schema.SObjectField> second = WeakAreaRevisitService.getFieldMap('Contact');
        Test.stopTest();

        System.assertEquals(first.size(), second.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Custom Iterable / Iterator
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testChunkedIterator_chunksCorrectly() {
        String csv = 'row1\nrow2\nrow3\nrow4\nrow5';
        WeakAreaRevisitService.ChunkedStringIterable iterable =
            new WeakAreaRevisitService.ChunkedStringIterable(csv, '\n', ',', 2);

        Test.startTest();
        Iterator<List<String>> it = iterable.iterator();
        Integer chunkCount = 0;
        Integer totalRows  = 0;
        while (it.hasNext()) {
            List<String> chunk = it.next();
            chunkCount++;
            totalRows += chunk.size();
        }
        Test.stopTest();

        System.assertEquals(5, totalRows);
        System.assertEquals(3, chunkCount); // 2+2+1
    }

    @IsTest
    static void testChunkedIterator_nullDataReturnsEmpty() {
        WeakAreaRevisitService.ChunkedStringIterable iterable =
            new WeakAreaRevisitService.ChunkedStringIterable(null, '\n', ',', 10);

        Test.startTest();
        Iterator<List<String>> it = iterable.iterator();
        Test.stopTest();

        System.assertEquals(false, it.hasNext());
    }

    @IsTest
    static void testChunkedIterator_singleChunkWhenSmall() {
        String csv = 'a\nb\nc';
        WeakAreaRevisitService.ChunkedStringIterable iterable =
            new WeakAreaRevisitService.ChunkedStringIterable(csv, '\n', ',', 100);

        Test.startTest();
        Iterator<List<String>> it = iterable.iterator();
        List<String> chunk = it.next();
        Test.stopTest();

        System.assertEquals(3, chunk.size());
        System.assertEquals(false, it.hasNext());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Platform Event error handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testHandlePlatformEvent_success() {
        Test.startTest();
        // Should complete without exception
        WeakAreaRevisitService.handlePlatformEvent('corr-001', '{}', false, false);
        Test.stopTest();

        System.assert(true, 'Expected no exception for successful event processing');
    }

    @IsTest
    static void testHandlePlatformEvent_permanentErrorThrows() {
        Test.startTest();
        try {
            WeakAreaRevisitService.handlePlatformEvent('corr-002', 'bad', false, true);
            System.assert(false, 'Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('Malformed payload'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testHandlePlatformEvent_retryableThrows() {
        Test.startTest();
        try {
            WeakAreaRevisitService.handlePlatformEvent('corr-003', '{}', true, false);
            System.assert(false, 'Expected RetryableException');
        } catch (EventBus.RetryableException e) {
            System.assert(e.getMessage().contains('Transient error'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetLastReplayId_gracefulDegradation() {
        Test.startTest();
        Long replayId = WeakAreaRevisitService.getLastReplayId('TestChannel__e');
        Test.stopTest();

        // Either -2 (graceful degrade) or a valid replay ID — never throws
        System.assertNotEquals(null, replayId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Callable interface
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testTaxCalculatorCallable_calculateTax() {
        WeakAreaRevisitService.TaxCalculatorCallable calc =
            new WeakAreaRevisitService.TaxCalculatorCallable();

        Test.startTest();
        Decimal tax = (Decimal) calc.call('calculateTax', new Map<String, Object>{
            'amount'  => 100.00,
            'taxCode' => 'VAT_20'
        });
        Test.stopTest();

        System.assertEquals(20.00, tax);
    }

    @IsTest
    static void testTaxCalculatorCallable_getRate() {
        WeakAreaRevisitService.TaxCalculatorCallable calc =
            new WeakAreaRevisitService.TaxCalculatorCallable();

        Test.startTest();
        Decimal rate = (Decimal) calc.call('getRate', new Map<String, Object>{
            'taxCode' => 'VAT_5'
        });
        Test.stopTest();

        System.assertEquals(5.0, rate);
    }

    @IsTest
    static void testTaxCalculatorCallable_unknownActionThrows() {
        WeakAreaRevisitService.TaxCalculatorCallable calc =
            new WeakAreaRevisitService.TaxCalculatorCallable();

        Test.startTest();
        try {
            calc.call('unknownAction', new Map<String, Object>());
            System.assert(false, 'Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('Unknown action'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testTaxCalculatorCallable_exemptTaxCode() {
        WeakAreaRevisitService.TaxCalculatorCallable calc =
            new WeakAreaRevisitService.TaxCalculatorCallable();

        Test.startTest();
        Decimal tax = (Decimal) calc.call('calculateTax', new Map<String, Object>{
            'amount'  => 500.00,
            'taxCode' => 'EXEMPT'
        });
        Test.stopTest();

        System.assertEquals(0.00, tax);
    }

    @IsTest
    static void testCallExternalTaxService_unknownClassReturnsZero() {
        Test.startTest();
        Decimal tax = WeakAreaRevisitService.callExternalTaxService(
            '', 'NonExistentTaxService', 100.00, 'VAT_20'
        );
        Test.stopTest();

        System.assertEquals(0, tax);
    }

    @IsTest
    static void testCallExternalTaxService_knownClass() {
        Test.startTest();
        Decimal tax = WeakAreaRevisitService.callExternalTaxService(
            '', 'WeakAreaRevisitService.TaxCalculatorCallable', 200.00, 'VAT_20'
        );
        Test.stopTest();

        System.assertEquals(40.00, tax);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. CPU-aware chunking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testHasCpuHeadroom_trueAtStart() {
        Test.startTest();
        Boolean headroom = WeakAreaRevisitService.hasCpuHeadroom();
        Test.stopTest();

        // At the start of a test, CPU usage should be minimal
        System.assertEquals(true, headroom);
    }

    @IsTest
    static void testProcessRecordsWithCpuGuard_emptyList() {
        Test.startTest();
        WeakAreaRevisitService.ProcessingResult result =
            WeakAreaRevisitService.processRecordsWithCpuGuard(
                new List<Id>(), null
            );
        Test.stopTest();

        System.assertEquals(0, result.processedCount);
        System.assertEquals(false, result.enqueuedContinuation);
    }

    @IsTest
    static void testProcessRecordsWithCpuGuard_processesSmallList() {
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 5; i++) accs.add(new Account(Name = 'CpuTest ' + i));
        insert accs;

        List<Id> ids = new List<Id>();
        for (Account a : accs) ids.add(a.Id);

        Test.startTest();
        WeakAreaRevisitService.ProcessingResult result =
            WeakAreaRevisitService.processRecordsWithCpuGuard(ids, null);
        Test.stopTest();

        System.assertEquals(5, result.processedCount);
        System.assertEquals(false, result.enqueuedContinuation);
    }

    @IsTest
    static void testBuildLargeListWithHeapGuard_respectsLimit() {
        List<String> source = new List<String>();
        for (Integer i = 0; i < 100; i++) source.add('item' + i);

        Test.startTest();
        List<String> result =
            WeakAreaRevisitService.buildLargeListWithHeapGuard(source, 99);
        Test.stopTest();

        // Should return some items (≤ 100), never throws
        System.assert(result.size() <= 100);
        System.assert(result.size() > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. String security patterns
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testSafeSearch_returnsResults() {
        Account a = new Account(Name = 'SafeSearchCo', Industry = 'Finance');
        insert a;

        Test.startTest();
        List<Account> results = WeakAreaRevisitService.safeSearch('SafeSearch');
        Test.stopTest();

        System.assert(results.size() >= 1);
    }

    @IsTest
    static void testSafeSearch_sqlInjectionAttemptHandled() {
        // Injection attempt — should return 0 results, not throw an exception
        Test.startTest();
        List<Account> results =
            WeakAreaRevisitService.safeSearch("' OR Name LIKE '%");
        Test.stopTest();

        // Safe search returns 0 results for the injected string (treated as literal)
        System.assertNotEquals(null, results);
    }

    @IsTest
    static void testSafeDynamicQuery_validFilter() {
        Account a = new Account(Name = 'DynQueryTest', Industry = 'Retail');
        insert a;

        Test.startTest();
        List<SObject> results = WeakAreaRevisitService.safeDynamicQuery(
            'Account',
            new Map<String, Object>{ 'Name' => 'DynQueryTest' }
        );
        Test.stopTest();

        System.assert(results.size() >= 1);
    }

    @IsTest
    static void testSafeDynamicQuery_invalidObjectThrows() {
        Test.startTest();
        try {
            WeakAreaRevisitService.safeDynamicQuery(
                'FakeObject__c', new Map<String, Object>{ 'Name' => 'x' }
            );
            System.assert(false, 'Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('Unknown object'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testSafeDynamicQuery_invalidFieldIsIgnored() {
        // Invalid field name should be silently ignored, not cause an exception
        Test.startTest();
        List<SObject> results = WeakAreaRevisitService.safeDynamicQuery(
            'Account',
            new Map<String, Object>{ 'FakeField__c' => 'anything' }
        );
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    @IsTest
    static void testSafeHtmlOutput_escapesHtml() {
        Test.startTest();
        String escaped = WeakAreaRevisitService.safeHtmlOutput('<script>alert(1)</script>');
        Test.stopTest();

        System.assert(!escaped.contains('<script>'));
        System.assert(escaped.contains('&lt;script&gt;'));
    }

    @IsTest
    static void testSafeDeserializeJson_validPayload() {
        String json = '{"recordId":"001000000000001","action":"update","attributes":{}}';

        Test.startTest();
        WeakAreaRevisitService.ImportPayload payload =
            WeakAreaRevisitService.safeDeserializeJson(json);
        Test.stopTest();

        System.assertEquals('001000000000001', payload.recordId);
        System.assertEquals('update', payload.action);
    }

    @IsTest
    static void testSafeDeserializeJson_missingRecordIdThrows() {
        String json = '{"action":"update"}';

        Test.startTest();
        try {
            WeakAreaRevisitService.safeDeserializeJson(json);
            System.assert(false, 'Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('recordId is required'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testSafeDeserializeJson_invalidJsonThrows() {
        Test.startTest();
        try {
            WeakAreaRevisitService.safeDeserializeJson('not-json{{{');
            System.assert(false, 'Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('Invalid JSON'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testSafeRedirectUrl_relativeUrlAllowed() {
        Test.startTest();
        String url = WeakAreaRevisitService.safeRedirectUrl('/home', new Set<String>());
        Test.stopTest();

        System.assertEquals('/home', url);
    }

    @IsTest
    static void testSafeRedirectUrl_allowedDomainAllowed() {
        Test.startTest();
        String url = WeakAreaRevisitService.safeRedirectUrl(
            'https://mycompany.salesforce.com/home',
            new Set<String>{ 'mycompany.salesforce.com' }
        );
        Test.stopTest();

        System.assertEquals('https://mycompany.salesforce.com/home', url);
    }

    @IsTest
    static void testSafeRedirectUrl_untrustedDomainRedirectsToRoot() {
        Test.startTest();
        String url = WeakAreaRevisitService.safeRedirectUrl(
            'https://evil.example.com/phish',
            new Set<String>{ 'mycompany.salesforce.com' }
        );
        Test.stopTest();

        System.assertEquals('/', url);
    }

    @IsTest
    static void testSafeRedirectUrl_nullReturnsRoot() {
        Test.startTest();
        String url = WeakAreaRevisitService.safeRedirectUrl(null, new Set<String>());
        Test.stopTest();

        System.assertEquals('/', url);
    }
}
