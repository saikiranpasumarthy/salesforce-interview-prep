/**
 * @description Tests for Day 24 — Performance Tuning & Large Data Volumes.
 *              Covers LdvQueryService (FOR LOOP, keyset pagination, selective queries,
 *              aggregate rollups) and PlatformCacheService (cache-aside, TTL, mock injection).
 *
 *              All Platform Cache tests use PlatformCacheService.useMock = true to
 *              bypass the need for a provisioned cache partition.
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class PerformanceTuningTest {

    // ─── Test setup ───────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 6; i++) {
            accounts.add(new Account(
                Name           = 'LDV Account ' + String.valueOf(i).leftPad(3, '0'),
                AnnualRevenue  = (i + 1) * 10000,
                Sync_Status__c = (Math.mod(i, 2) == 0) ? 'Pending' : 'Synced',
                Rating         = 'Cold'
            ));
        }
        insert accounts;

        List<Opportunity> opps = new List<Opportunity>();
        for (Account acc : accounts) {
            opps.add(new Opportunity(
                AccountId  = acc.Id,
                Name       = 'Opp for ' + acc.Name,
                StageName  = 'Closed Won',
                CloseDate  = Date.today().addDays(-10),
                Amount     = acc.AnnualRevenue * 0.5,
                IsWon__c   = null  // standard field IsWon is read-only; set via StageName
            ));
        }
        insert opps;
    }

    // ─── LdvQueryService — streamPendingAccounts (FOR LOOP) ───────────────────

    @IsTest static void streamPendingAccounts_invokesProcessorPerChunk() {
        CollectingProcessor processor = new CollectingProcessor();

        Test.startTest();
        LdvQueryService.streamPendingAccounts(processor);
        Test.stopTest();

        System.assert(processor.totalProcessed > 0, 'Processor should receive at least one record');
        System.assertEquals(processor.totalProcessed, processor.allRecords.size(),
            'All processed records should be collected');
    }

    @IsTest static void streamPendingAccounts_onlyPendingRecords() {
        CollectingProcessor processor = new CollectingProcessor();

        Test.startTest();
        LdvQueryService.streamPendingAccounts(processor);
        Test.stopTest();

        for (Account acc : processor.allRecords) {
            System.assertEquals('Pending', acc.Sync_Status__c,
                'FOR LOOP should only deliver Pending accounts');
        }
    }

    // ─── LdvQueryService — bulkUpdateSyncStatus ──────────────────────────────

    @IsTest static void bulkUpdateSyncStatus_updatesMatchingRecords() {
        Test.startTest();
        Integer updated = LdvQueryService.bulkUpdateSyncStatus('Pending', 'Synced');
        Test.stopTest();

        System.assertEquals(3, updated, 'Should update 3 Pending accounts');
        Integer remaining = [SELECT COUNT() FROM Account WHERE Sync_Status__c = 'Pending'];
        System.assertEquals(0, remaining, 'No Pending records should remain');
    }

    @IsTest static void bulkUpdateSyncStatus_noMatchReturnsZero() {
        Test.startTest();
        Integer updated = LdvQueryService.bulkUpdateSyncStatus('NonExistentStatus', 'Synced');
        Test.stopTest();

        System.assertEquals(0, updated);
    }

    // ─── LdvQueryService — keysetPage ────────────────────────────────────────

    @IsTest static void keysetPage_firstPage_startsFromBeginning() {
        Test.startTest();
        List<Account> page = LdvQueryService.keysetPage(null, 3);
        Test.stopTest();

        System.assertEquals(3, page.size(), 'First page should return pageSize records');
    }

    @IsTest static void keysetPage_subsequentPage_doesNotOverlap() {
        Test.startTest();
        List<Account> page1 = LdvQueryService.keysetPage(null, 3);
        Id lastId = page1[page1.size() - 1].Id;
        List<Account> page2 = LdvQueryService.keysetPage(lastId, 3);
        Test.stopTest();

        Set<Id> page1Ids = new Map<Id, Account>(page1).keySet();
        for (Account acc : page2) {
            System.assert(!page1Ids.contains(acc.Id), 'Page 2 should not overlap with Page 1');
        }
    }

    @IsTest static void keysetPage_allPages_coverAllRecords() {
        Test.startTest();
        List<Account> page1 = LdvQueryService.keysetPage(null, 4);
        Id lastId = page1[page1.size() - 1].Id;
        List<Account> page2 = LdvQueryService.keysetPage(lastId, 4);
        Test.stopTest();

        System.assertEquals(4, page1.size());
        System.assertEquals(2, page2.size(), 'Second page should return remaining 2 records');
    }

    @IsTest static void keysetPage_clampsPageSizeToMax2000() {
        Test.startTest();
        // Request size > 2000 — service should clamp to 2000 (we only have 6 test records)
        List<Account> page = LdvQueryService.keysetPage(null, 5000);
        Test.stopTest();

        System.assertEquals(6, page.size(), 'Should return all 6 test records (clamped safely)');
    }

    @IsTest static void keysetPage_nullPageSize_usesDefault200() {
        Test.startTest();
        List<Account> page = LdvQueryService.keysetPage(null, null);
        Test.stopTest();

        System.assertEquals(6, page.size(), 'Null pageSize should default to 200, returning all 6');
    }

    // ─── LdvQueryService — selectiveOpportunityQuery ─────────────────────────

    @IsTest static void selectiveOpportunityQuery_returnsMatchingDateRange() {
        Test.startTest();
        List<Opportunity> opps = LdvQueryService.selectiveOpportunityQuery(
            Date.today().addDays(-30), Date.today(), 'Closed Won');
        Test.stopTest();

        System.assertEquals(6, opps.size(), 'All 6 test Opps should fall in range');
    }

    @IsTest static void selectiveOpportunityQuery_noMatchReturnEmpty() {
        Test.startTest();
        List<Opportunity> opps = LdvQueryService.selectiveOpportunityQuery(
            Date.today().addDays(-365), Date.today().addDays(-180), 'Closed Won');
        Test.stopTest();

        System.assert(opps.isEmpty(), 'No opps in far past should be returned');
    }

    @IsTest static void selectiveOpportunityQuery_stageFilterNarrows() {
        Test.startTest();
        List<Opportunity> opps = LdvQueryService.selectiveOpportunityQuery(
            Date.today().addDays(-30), Date.today(), 'Prospecting');
        Test.stopTest();

        System.assert(opps.isEmpty(), 'Stage filter should exclude Closed Won records');
    }

    // ─── LdvQueryService — countPendingAccounts ──────────────────────────────

    @IsTest static void countPendingAccounts_returnsCorrectCount() {
        Test.startTest();
        Integer count = LdvQueryService.countPendingAccounts();
        Test.stopTest();

        System.assertEquals(3, count, 'Should count exactly 3 Pending accounts from test setup');
    }

    @IsTest static void countPendingAccounts_zeroAfterBulkUpdate() {
        LdvQueryService.bulkUpdateSyncStatus('Pending', 'Synced');

        Test.startTest();
        Integer count = LdvQueryService.countPendingAccounts();
        Test.stopTest();

        System.assertEquals(0, count);
    }

    // ─── LdvQueryService — lockForProcessing ─────────────────────────────────

    @IsTest static void lockForProcessing_returnsOnlyPendingRecords() {
        List<Account> pending = [SELECT Id FROM Account WHERE Sync_Status__c = 'Pending'];
        Set<Id> ids = new Map<Id, Account>(pending).keySet();

        Test.startTest();
        List<Account> locked = LdvQueryService.lockForProcessing(ids);
        Test.stopTest();

        System.assertEquals(3, locked.size(), 'FOR UPDATE should return only Pending records');
        for (Account acc : locked) {
            System.assertEquals('Pending', acc.Sync_Status__c);
        }
    }

    @IsTest static void lockForProcessing_excludesSyncedRecords() {
        List<Account> allAccounts = [SELECT Id FROM Account];
        Set<Id> allIds = new Map<Id, Account>(allAccounts).keySet();

        Test.startTest();
        List<Account> locked = LdvQueryService.lockForProcessing(allIds);
        Test.stopTest();

        // Should only return the 3 Pending ones, not all 6
        System.assertEquals(3, locked.size());
    }

    // ─── LdvQueryService — getOpportunityTotals ──────────────────────────────

    @IsTest static void getOpportunityTotals_computesCorrectSums() {
        List<Account> accounts = [SELECT Id, AnnualRevenue FROM Account];
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();

        Test.startTest();
        Map<Id, Decimal> totals = LdvQueryService.getOpportunityTotals(accountIds);
        Test.stopTest();

        System.assertEquals(6, totals.size(), 'Should compute totals for all 6 accounts');
        for (Account acc : accounts) {
            Decimal expected = acc.AnnualRevenue * 0.5;
            System.assertEquals(expected, totals.get(acc.Id),
                'Total should match 50% of AnnualRevenue for ' + acc.Id);
        }
    }

    @IsTest static void getOpportunityTotals_emptySet_returnsEmptyMap() {
        Test.startTest();
        Map<Id, Decimal> totals = LdvQueryService.getOpportunityTotals(new Set<Id>());
        Test.stopTest();

        System.assert(totals.isEmpty());
    }

    // ─── PlatformCacheService — sanitizeKey ──────────────────────────────────

    @IsTest static void sanitizeKey_replacesSpecialCharacters() {
        System.assertEquals('Account_Rating_Hot',
            PlatformCacheService.sanitizeKey('Account.Rating.Hot'));
    }

    @IsTest static void sanitizeKey_truncatesTo50Chars() {
        String longKey = 'a'.repeat(100);
        String safe    = PlatformCacheService.sanitizeKey(longKey);
        System.assertEquals(50, safe.length());
    }

    @IsTest static void sanitizeKey_blankInput_returnsFallback() {
        System.assertEquals('blank_key', PlatformCacheService.sanitizeKey(''));
        System.assertEquals('blank_key', PlatformCacheService.sanitizeKey(null));
    }

    @IsTest static void sanitizeKey_preservesAlphanumericAndUnderscore() {
        System.assertEquals('My_Cache_Key_123',
            PlatformCacheService.sanitizeKey('My_Cache_Key_123'));
    }

    // ─── PlatformCacheService — get / put ────────────────────────────────────

    @IsTest static void put_and_get_roundTrip() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();

        Test.startTest();
        PlatformCacheService.put('myKey', 'myValue', 3600);
        Object result = PlatformCacheService.get('myKey');
        Test.stopTest();

        System.assertEquals('myValue', result);
    }

    @IsTest static void get_returnsNull_onCacheMiss() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();

        Test.startTest();
        Object result = PlatformCacheService.get('nonExistentKey');
        Test.stopTest();

        System.assertNull(result);
    }

    @IsTest static void put_nullValue_doesNotStore() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();

        Test.startTest();
        PlatformCacheService.put('nullKey', null, 3600);
        Object result = PlatformCacheService.get('nullKey');
        Test.stopTest();

        System.assertNull(result, 'Null values should not be stored in cache');
    }

    // ─── PlatformCacheService — invalidate ───────────────────────────────────

    @IsTest static void invalidate_removesSpecificEntry() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();
        PlatformCacheService.put('key1', 'value1', 3600);
        PlatformCacheService.put('key2', 'value2', 3600);

        Test.startTest();
        PlatformCacheService.invalidate('key1');
        Test.stopTest();

        System.assertNull(PlatformCacheService.get('key1'),  'key1 should be removed');
        System.assertEquals('value2', PlatformCacheService.get('key2'), 'key2 should remain');
    }

    @IsTest static void invalidateAll_clearsAllEntries() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();
        PlatformCacheService.put('a', '1', 3600);
        PlatformCacheService.put('b', '2', 3600);
        PlatformCacheService.put('c', '3', 3600);

        Test.startTest();
        PlatformCacheService.invalidateAll();
        Test.stopTest();

        System.assertNull(PlatformCacheService.get('a'));
        System.assertNull(PlatformCacheService.get('b'));
        System.assertNull(PlatformCacheService.get('c'));
    }

    // ─── PlatformCacheService — getOrLoad (cache-aside) ──────────────────────

    @IsTest static void getOrLoad_callsLoaderOnCacheMiss() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();
        CountingLoader loader = new CountingLoader('loaded_value');

        Test.startTest();
        Object result = PlatformCacheService.getOrLoad('missKey', loader, 3600);
        Test.stopTest();

        System.assertEquals('loaded_value', result);
        System.assertEquals(1, loader.callCount, 'Loader should be called exactly once on miss');
    }

    @IsTest static void getOrLoad_doesNotCallLoaderOnCacheHit() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();
        PlatformCacheService.put('hitKey', 'cached_value', 3600);
        CountingLoader loader = new CountingLoader('loaded_value');

        Test.startTest();
        Object result = PlatformCacheService.getOrLoad('hitKey', loader, 3600);
        Test.stopTest();

        System.assertEquals('cached_value', result, 'Should return cached value, not loaded');
        System.assertEquals(0, loader.callCount, 'Loader should NOT be called on hit');
    }

    @IsTest static void getOrLoad_populatesCacheAfterMiss() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();
        CountingLoader loader = new CountingLoader('fresh');

        Test.startTest();
        PlatformCacheService.getOrLoad('popKey', loader, 3600);
        Object second = PlatformCacheService.getOrLoad('popKey', loader, 3600);
        Test.stopTest();

        System.assertEquals('fresh', second);
        System.assertEquals(1, loader.callCount, 'Loader should only be called once (first miss)');
    }

    @IsTest static void getOrLoad_nullLoaderResult_notCached() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();
        CountingLoader loader = new CountingLoader(null);

        Test.startTest();
        Object result = PlatformCacheService.getOrLoad('nullResult', loader, 3600);
        Test.stopTest();

        System.assertNull(result);
        System.assertNull(PlatformCacheService.get('nullResult'),
            'Null loader result should not be stored in cache');
    }

    // ─── PlatformCacheService — typed helpers ─────────────────────────────────

    @IsTest static void getString_returnsTypedString() {
        PlatformCacheService.useMock = true;
        PlatformCacheService.mockStore.clear();
        PlatformCacheService.put('strKey', 'hello', 3600);

        Test.startTest();
        String result = PlatformCacheService.getString('strKey');
        Test.stopTest();

        System.assertEquals('hello', result);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /** Collects all records streamed through the FOR LOOP processor */
    private class CollectingProcessor implements LdvQueryService.ChunkProcessor {
        public List<Account> allRecords  = new List<Account>();
        public Integer       totalProcessed = 0;
        public void process(List<Account> chunk) {
            allRecords.addAll(chunk);
            totalProcessed += chunk.size();
        }
    }

    /** Tracks how many times load() is called — verifies cache-aside hit/miss */
    private class CountingLoader implements PlatformCacheService.CacheLoader {
        private final Object returnValue;
        public Integer callCount = 0;
        CountingLoader(Object returnValue) { this.returnValue = returnValue; }
        public Object load(String key) {
            callCount++;
            return returnValue;
        }
    }
}
