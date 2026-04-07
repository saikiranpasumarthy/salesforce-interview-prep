/**
 * @description Test coverage for Day 32 — Data Cloud Architecture.
 *              Covers DataCloudIngestionService and DataCloudProfileService.
 *
 *              Testing strategy:
 *              - All Data Cloud API calls use HttpCalloutMock (static injection)
 *              - DataCloudIngestionService.calloutMock / DataCloudProfileService.calloutMock
 *              - No real Data Cloud org connection needed
 *              - Validates payload construction, chunking, error handling, parsing
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class DataCloudTest {

    // ─── DataCloudIngestionService — streamAccounts ───────────────────────────

    @IsTest
    static void testStreamAccounts_success() {
        DataCloudIngestionService.calloutMock = new IngestionMock(202, '{"accepted":true}');

        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 3; i++) {
            accounts.add(new Account(
                Name          = 'Acme ' + i,
                Industry      = 'Technology',
                AnnualRevenue = 100000 * i,
                BillingCity   = 'San Francisco',
                BillingCountry = 'US'
            ));
        }
        insert accounts;

        Test.startTest();
        List<DataCloudIngestionService.IngestionResult> results =
            DataCloudIngestionService.streamAccounts(accounts, 'CRM_Source', 'Account__dlm');
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Three records fit in one chunk (< 200)');
        System.assertEquals(true, results[0].isSuccess, 'Ingestion should succeed');
        System.assertEquals(3, results[0].recordsAccepted, 'Three records accepted');
        System.assertEquals(null, results[0].errorMessage, 'No error on success');
    }

    @IsTest
    static void testStreamAccounts_chunking() {
        DataCloudIngestionService.calloutMock = new IngestionMock(202, '{"accepted":true}');

        // Build 250 accounts — should chunk into 2 batches (200 + 50)
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 250; i++) {
            accounts.add(new Account(Name = 'Account ' + i));
        }
        insert accounts;

        Test.startTest();
        List<DataCloudIngestionService.IngestionResult> results =
            DataCloudIngestionService.streamAccounts(accounts, 'CRM_Source', 'Account__dlm');
        Test.stopTest();

        System.assertEquals(2, results.size(), '250 records = 2 chunks (200 + 50)');
        System.assertEquals(200, results[0].recordsAccepted, 'First chunk = 200');
        System.assertEquals(50,  results[1].recordsAccepted, 'Second chunk = 50');
        System.assertEquals(true, results[0].isSuccess, 'First chunk success');
        System.assertEquals(true, results[1].isSuccess, 'Second chunk success');
    }

    @IsTest
    static void testStreamAccounts_emptyList() {
        Test.startTest();
        List<DataCloudIngestionService.IngestionResult> results =
            DataCloudIngestionService.streamAccounts(
                new List<Account>(), 'CRM_Source', 'Account__dlm'
            );
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty list returns no results');
    }

    @IsTest
    static void testStreamAccounts_nullList() {
        Test.startTest();
        List<DataCloudIngestionService.IngestionResult> results =
            DataCloudIngestionService.streamAccounts(null, 'CRM_Source', 'Account__dlm');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Null list returns no results');
    }

    @IsTest
    static void testStreamAccounts_apiError() {
        DataCloudIngestionService.calloutMock = new IngestionMock(400,
            '{"message":"Schema validation failed: unknown field AnnualRevenue__x"}');

        Account acc = new Account(Name = 'Error Corp');
        insert acc;

        Test.startTest();
        List<DataCloudIngestionService.IngestionResult> results =
            DataCloudIngestionService.streamAccounts(
                new List<Account>{ acc }, 'CRM_Source', 'Account__dlm'
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, '400 should fail');
        System.assert(results[0].errorMessage.contains('400'),
            'Error should include status code');
        System.assert(results[0].errorMessage.contains('Schema validation'),
            'Error should include API message');
    }

    @IsTest
    static void testStreamAccounts_rateLimitRetryable() {
        DataCloudIngestionService.calloutMock = new IngestionMock(429,
            '{"message":"Rate limit exceeded. Retry after 60 seconds."}');

        Account acc = new Account(Name = 'Rate Limited Corp');
        insert acc;

        Test.startTest();
        List<DataCloudIngestionService.IngestionResult> results =
            DataCloudIngestionService.streamAccounts(
                new List<Account>{ acc }, 'CRM_Source', 'Account__dlm'
            );
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess, '429 should fail');
        System.assert(results[0].errorMessage.contains('429'),
            'Error should include 429');
    }

    // ─── DataCloudIngestionService — streamInteractionEvents ─────────────────

    @IsTest
    static void testStreamInteractionEvents_success() {
        DataCloudIngestionService.calloutMock = new IngestionMock(202, '{}');

        List<DataCloudIngestionService.InteractionEvent> events =
            new List<DataCloudIngestionService.InteractionEvent>{
                new DataCloudIngestionService.InteractionEvent(
                    'evt-001', 'ind-001', 'EmailOpen',
                    DateTime.now(), 'Email', 0.8
                ),
                new DataCloudIngestionService.InteractionEvent(
                    'evt-002', 'ind-001', 'WebVisit',
                    DateTime.now().addMinutes(-10), 'Web', 0.5
                )
            };

        Test.startTest();
        DataCloudIngestionService.IngestionResult result =
            DataCloudIngestionService.streamInteractionEvents(events, 'Engagement_Source');
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Events should be ingested');
        System.assertEquals(2, result.recordsAccepted, 'Two events accepted');
    }

    @IsTest
    static void testStreamInteractionEvents_empty() {
        Test.startTest();
        DataCloudIngestionService.IngestionResult result =
            DataCloudIngestionService.streamInteractionEvents(
                new List<DataCloudIngestionService.InteractionEvent>(), 'Src'
            );
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Empty events should fail gracefully');
        System.assert(result.errorMessage.contains('No events'), 'Error should mention no events');
    }

    // ─── DataCloudIngestionService — deleteRecords ────────────────────────────

    @IsTest
    static void testDeleteRecords_success() {
        DataCloudIngestionService.calloutMock = new IngestionMock(202, '{}');

        List<Map<String, String>> pks = new List<Map<String, String>>{
            new Map<String, String>{ 'AccountId__c' => '001xx0000000001' },
            new Map<String, String>{ 'AccountId__c' => '001xx0000000002' }
        };

        Test.startTest();
        DataCloudIngestionService.IngestionResult result =
            DataCloudIngestionService.deleteRecords(pks, 'CRM_Source', 'Account__dlm');
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Delete should succeed');
        System.assertEquals(2, result.recordsAccepted, 'Two records deleted');
    }

    @IsTest
    static void testDeleteRecords_empty() {
        Test.startTest();
        DataCloudIngestionService.IngestionResult result =
            DataCloudIngestionService.deleteRecords(
                new List<Map<String, String>>(), 'Src', 'Obj__dlm'
            );
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Empty delete should fail gracefully');
    }

    // ─── DataCloudIngestionService — validateRecordPayload ────────────────────

    @IsTest
    static void testValidateRecordPayload_valid() {
        Map<String, Object> record = new Map<String, Object>{
            'AccountId__c' => '001xx001',
            'Name__c'      => 'Test Corp'
        };
        Set<String> required = new Set<String>{ 'AccountId__c', 'Name__c' };

        Test.startTest();
        List<String> errors = DataCloudIngestionService.validateRecordPayload(record, required);
        Test.stopTest();

        System.assertEquals(0, errors.size(), 'Valid record should have no errors');
    }

    @IsTest
    static void testValidateRecordPayload_missingField() {
        Map<String, Object> record = new Map<String, Object>{
            'Name__c' => 'Test Corp'
            // AccountId__c missing
        };
        Set<String> required = new Set<String>{ 'AccountId__c', 'Name__c' };

        Test.startTest();
        List<String> errors = DataCloudIngestionService.validateRecordPayload(record, required);
        Test.stopTest();

        System.assertEquals(1, errors.size(), 'Should have one missing field error');
        System.assert(errors[0].contains('AccountId__c'), 'Error should name the missing field');
    }

    @IsTest
    static void testValidateRecordPayload_nullValue() {
        Map<String, Object> record = new Map<String, Object>{
            'AccountId__c' => null,
            'Name__c'      => 'Test Corp'
        };
        Set<String> required = new Set<String>{ 'AccountId__c', 'Name__c' };

        Test.startTest();
        List<String> errors = DataCloudIngestionService.validateRecordPayload(record, required);
        Test.stopTest();

        System.assertEquals(1, errors.size(), 'Null value counts as missing');
    }

    @IsTest
    static void testValidateRecordPayload_nullRecord() {
        Test.startTest();
        List<String> errors = DataCloudIngestionService.validateRecordPayload(
            null, new Set<String>{ 'Id__c' }
        );
        Test.stopTest();

        System.assertEquals(1, errors.size(), 'Null record should return error');
        System.assert(errors[0].contains('null'), 'Error should mention null payload');
    }

    // ─── DataCloudIngestionService — validateBatch ────────────────────────────

    @IsTest
    static void testValidateBatch_mixedValidity() {
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Id__c' => '001', 'Name__c' => 'Valid' },
            new Map<String, Object>{ 'Name__c' => 'Missing Id' }, // invalid
            new Map<String, Object>{ 'Id__c' => '003', 'Name__c' => 'Also Valid' }
        };
        Set<String> required = new Set<String>{ 'Id__c', 'Name__c' };

        Test.startTest();
        DataCloudIngestionService.BatchValidationResult result =
            DataCloudIngestionService.validateBatch(records, required);
        Test.stopTest();

        System.assertEquals(2, result.validCount(),   '2 valid records');
        System.assertEquals(1, result.invalidCount(), '1 invalid record');
        System.assertEquals(false, result.allValid(), 'Not all valid');
        System.assert(result.errorDetails[0].contains('Record[1]'),
            'Error should reference record index');
    }

    @IsTest
    static void testValidateBatch_allValid() {
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Id__c' => '001' },
            new Map<String, Object>{ 'Id__c' => '002' }
        };

        Test.startTest();
        DataCloudIngestionService.BatchValidationResult result =
            DataCloudIngestionService.validateBatch(records, new Set<String>{ 'Id__c' });
        Test.stopTest();

        System.assertEquals(true, result.allValid(), 'All records valid');
        System.assertEquals(2, result.validCount(), '2 valid records');
        System.assertEquals(0, result.invalidCount(), '0 invalid records');
    }

    // ─── DataCloudIngestionService — toIso8601Utc ─────────────────────────────

    @IsTest
    static void testToIso8601Utc() {
        DateTime dt = DateTime.newInstanceGmt(2024, 6, 15, 10, 30, 0);

        Test.startTest();
        String iso = DataCloudIngestionService.toIso8601Utc(dt);
        String nullResult = DataCloudIngestionService.toIso8601Utc(null);
        Test.stopTest();

        System.assertEquals('2024-06-15T10:30:00Z', iso, 'ISO format should match');
        System.assertEquals(null, nullResult, 'Null datetime returns null');
    }

    // ─── DataCloudIngestionService — extractErrorMessage ─────────────────────

    @IsTest
    static void testExtractErrorMessage() {
        Test.startTest();
        String msg1 = DataCloudIngestionService.extractErrorMessage(
            '{"message":"Schema validation failed"}');
        String msg2 = DataCloudIngestionService.extractErrorMessage(
            '{"error":"Unauthorized"}');
        String msg3 = DataCloudIngestionService.extractErrorMessage('Plain text error');
        String msg4 = DataCloudIngestionService.extractErrorMessage(null);
        String msg5 = DataCloudIngestionService.extractErrorMessage('');
        Test.stopTest();

        System.assertEquals('Schema validation failed', msg1, 'message field extracted');
        System.assertEquals('Unauthorized', msg2, 'error field extracted');
        System.assertEquals('Plain text error', msg3, 'Non-JSON body returned as-is');
        System.assertEquals('No response body', msg4, 'Null = no response body');
        System.assertEquals('No response body', msg5, 'Blank = no response body');
    }

    // ─── DataCloudProfileService — lookupByEmail ──────────────────────────────

    @IsTest
    static void testLookupByEmail_found() {
        String mockResponse = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{
                    'UnifiedIndividualId__c' => 'uid-abc-123',
                    'FirstName__c'           => 'Jane',
                    'LastName__c'            => 'Doe',
                    'EmailAddress__c'        => 'jane.doe@acme.com',
                    'IsPrimary__c'           => true
                }
            },
            'totalSize' => 1
        });
        DataCloudProfileService.calloutMock = new QueryMock(200, mockResponse);

        Test.startTest();
        DataCloudProfileService.UnifiedProfileResult profile =
            DataCloudProfileService.lookupByEmail('jane.doe@acme.com');
        Test.stopTest();

        System.assertNotEquals(null, profile, 'Profile should be found');
        System.assertEquals('uid-abc-123', profile.unifiedIndividualId, 'Unified Id correct');
        System.assertEquals('Jane', profile.firstName, 'First name correct');
        System.assertEquals('Doe',  profile.lastName,  'Last name correct');
        System.assertEquals('jane.doe@acme.com', profile.primaryEmail, 'Email correct');
        System.assertEquals('Jane Doe', profile.fullName(), 'Full name assembled correctly');
    }

    @IsTest
    static void testLookupByEmail_notFound() {
        DataCloudProfileService.calloutMock = new QueryMock(200,
            '{"data":[],"totalSize":0}');

        Test.startTest();
        DataCloudProfileService.UnifiedProfileResult profile =
            DataCloudProfileService.lookupByEmail('nobody@nowhere.com');
        Test.stopTest();

        System.assertEquals(null, profile, 'Null returned when no results');
    }

    @IsTest
    static void testLookupByEmail_blankEmail() {
        Test.startTest();
        DataCloudProfileService.UnifiedProfileResult profile =
            DataCloudProfileService.lookupByEmail('');
        Test.stopTest();

        System.assertEquals(null, profile, 'Blank email returns null');
    }

    @IsTest
    static void testLookupByEmail_apiError() {
        DataCloudProfileService.calloutMock = new QueryMock(500,
            '{"message":"Internal server error"}');

        Test.startTest();
        DataCloudProfileService.UnifiedProfileResult profile =
            DataCloudProfileService.lookupByEmail('test@test.com');
        Test.stopTest();

        System.assertEquals(null, profile, 'API error returns null gracefully');
    }

    // ─── DataCloudProfileService — lookupByCrmContactId ──────────────────────

    @IsTest
    static void testLookupByCrmContactId_found() {
        Contact c = new Contact(FirstName = 'Test', LastName = 'Contact');
        insert c;

        String mockResponse = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{
                    'UnifiedIndividualId__c' => 'uid-xyz-456',
                    'FirstName__c'           => 'Test',
                    'LastName__c'            => 'Contact'
                }
            },
            'totalSize' => 1
        });
        DataCloudProfileService.calloutMock = new QueryMock(200, mockResponse);

        Test.startTest();
        DataCloudProfileService.UnifiedProfileResult profile =
            DataCloudProfileService.lookupByCrmContactId(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, profile, 'Profile should be found');
        System.assertEquals('uid-xyz-456', profile.unifiedIndividualId, 'Unified Id correct');
        System.assertEquals('Test Contact', profile.fullName(), 'Full name correct');
    }

    @IsTest
    static void testLookupByCrmContactId_nullId() {
        Test.startTest();
        DataCloudProfileService.UnifiedProfileResult result =
            DataCloudProfileService.lookupByCrmContactId(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Null Id returns null');
    }

    // ─── DataCloudProfileService — getContactPoints ───────────────────────────

    @IsTest
    static void testGetContactPoints_withEmailAndPhone() {
        // Two separate queries — use SequencedQueryMock
        String emailResponse = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{
                    'EmailAddress__c' => 'primary@test.com',
                    'IsPrimary__c'    => true,
                    'EmailDomain__c'  => 'test.com'
                },
                new Map<String, Object>{
                    'EmailAddress__c' => 'secondary@test.com',
                    'IsPrimary__c'    => false,
                    'EmailDomain__c'  => 'test.com'
                }
            },
            'totalSize' => 2
        });
        String phoneResponse = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{
                    'FormattedNationalPhoneNumber__c' => '+1-415-555-0100',
                    'IsPrimary__c' => true,
                    'PhoneType__c' => 'Mobile'
                }
            },
            'totalSize' => 1
        });

        DataCloudProfileService.calloutMock =
            new SequencedQueryMock(new List<String>{ emailResponse, phoneResponse });

        Test.startTest();
        DataCloudProfileService.ContactPoints points =
            DataCloudProfileService.getContactPoints('uid-abc-123');
        Test.stopTest();

        System.assertEquals(2, points.emails.size(), 'Two email contact points');
        System.assertEquals(1, points.phones.size(), 'One phone contact point');
        System.assertEquals('primary@test.com', points.getPrimaryEmail(),
            'Primary email correct');
        System.assertEquals('+1-415-555-0100', points.getPrimaryPhone(),
            'Primary phone correct');
        System.assertEquals('test.com', points.emails[0].emailDomain, 'Domain correct');
        System.assertEquals('Mobile', points.phones[0].phoneType, 'Phone type correct');
    }

    @IsTest
    static void testGetContactPoints_blankId() {
        Test.startTest();
        DataCloudProfileService.ContactPoints points =
            DataCloudProfileService.getContactPoints('');
        Test.stopTest();

        System.assertEquals(0, points.emails.size(), 'Empty emails for blank Id');
        System.assertEquals(0, points.phones.size(), 'Empty phones for blank Id');
        System.assertEquals(null, points.getPrimaryEmail(), 'Null primary email');
    }

    // ─── DataCloudProfileService — getCalculatedInsight ──────────────────────

    @IsTest
    static void testGetCalculatedInsight_found() {
        String mockResponse = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{
                    'UnifiedIndividualId__c' => 'uid-abc-123',
                    'TotalLifetimeValue__c'  => 12500.00,
                    'PurchaseCount__c'       => 8
                }
            },
            'totalSize' => 1
        });
        DataCloudProfileService.calloutMock = new QueryMock(200, mockResponse);

        Test.startTest();
        Map<String, Object> insight =
            DataCloudProfileService.getCalculatedInsight('uid-abc-123', 'LifetimeValue');
        Test.stopTest();

        System.assertNotEquals(null, insight, 'Insight should be returned');
        System.assertEquals(12500.00, (Decimal) insight.get('TotalLifetimeValue__c'),
            'LTV should match');
        System.assertEquals(8, (Integer) insight.get('PurchaseCount__c'),
            'Purchase count should match');
    }

    @IsTest
    static void testGetCalculatedInsight_appendsDlmSuffix() {
        DataCloudProfileService.calloutMock = new QueryMock(200, '{"data":[],"totalSize":0}');

        Test.startTest();
        // Pass name without __dlm — should still work (suffix auto-appended)
        Map<String, Object> result =
            DataCloudProfileService.getCalculatedInsight('uid-001', 'LifetimeValue');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return (empty) map not null');
        System.assertEquals(0, result.size(), 'Empty map when no data');
    }

    @IsTest
    static void testGetCalculatedInsight_blankInputs() {
        Test.startTest();
        Map<String, Object> r1 = DataCloudProfileService.getCalculatedInsight('', 'MyInsight');
        Map<String, Object> r2 = DataCloudProfileService.getCalculatedInsight('uid-001', '');
        Test.stopTest();

        System.assertEquals(0, r1.size(), 'Blank Id returns empty map');
        System.assertEquals(0, r2.size(), 'Blank insight name returns empty map');
    }

    // ─── DataCloudProfileService — isInSegment ────────────────────────────────

    @IsTest
    static void testIsInSegment_memberFound() {
        DataCloudProfileService.calloutMock = new QueryMock(200,
            '{"data":[{"UnifiedIndividualId__c":"uid-001"}],"totalSize":1}');

        Test.startTest();
        Boolean inSegment = DataCloudProfileService.isInSegment('uid-001', 'seg-premium');
        Test.stopTest();

        System.assertEquals(true, inSegment, 'Profile should be in segment');
    }

    @IsTest
    static void testIsInSegment_notMember() {
        DataCloudProfileService.calloutMock = new QueryMock(200,
            '{"data":[],"totalSize":0}');

        Test.startTest();
        Boolean inSegment = DataCloudProfileService.isInSegment('uid-001', 'seg-premium');
        Test.stopTest();

        System.assertEquals(false, inSegment, 'Profile should not be in segment');
    }

    @IsTest
    static void testIsInSegment_blankInputs() {
        Test.startTest();
        Boolean r1 = DataCloudProfileService.isInSegment('', 'seg-001');
        Boolean r2 = DataCloudProfileService.isInSegment('uid-001', '');
        Test.stopTest();

        System.assertEquals(false, r1, 'Blank individual Id = false');
        System.assertEquals(false, r2, 'Blank segment Id = false');
    }

    // ─── DataCloudProfileService — getMemberSegments ─────────────────────────

    @IsTest
    static void testGetMemberSegments_multiple() {
        DataCloudProfileService.calloutMock = new QueryMock(200, JSON.serialize(
            new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{ 'SegmentId__c' => 'seg-001', 'MembershipDate__c' => '2024-01-01' },
                    new Map<String, Object>{ 'SegmentId__c' => 'seg-002', 'MembershipDate__c' => '2024-02-01' }
                },
                'totalSize' => 2
            }
        ));

        Test.startTest();
        List<String> segments = DataCloudProfileService.getMemberSegments('uid-001');
        Test.stopTest();

        System.assertEquals(2, segments.size(), 'Two segments returned');
        System.assert(segments.contains('seg-001'), 'seg-001 in list');
        System.assert(segments.contains('seg-002'), 'seg-002 in list');
    }

    @IsTest
    static void testGetMemberSegments_blankId() {
        Test.startTest();
        List<String> segments = DataCloudProfileService.getMemberSegments('');
        Test.stopTest();

        System.assertEquals(0, segments.size(), 'Empty list for blank Id');
    }

    // ─── DataCloudProfileService — getPurchaseHistory ─────────────────────────

    @IsTest
    static void testGetPurchaseHistory_withOrders() {
        DataCloudProfileService.calloutMock = new QueryMock(200, JSON.serialize(
            new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{
                        'SalesOrderId__c'       => 'ord-001',
                        'GrandTotalAmount__c'   => 299.99,
                        'Status__c'            => 'Fulfilled',
                        'ChannelType__c'       => 'Web'
                    }
                },
                'totalSize' => 1
            }
        ));

        Test.startTest();
        List<Map<String, Object>> orders =
            DataCloudProfileService.getPurchaseHistory('uid-001', 365);
        Test.stopTest();

        System.assertEquals(1, orders.size(), 'One order returned');
        System.assertEquals('ord-001', (String) orders[0].get('SalesOrderId__c'),
            'Order Id correct');
        System.assertEquals(299.99, (Decimal) orders[0].get('GrandTotalAmount__c'),
            'Amount correct');
    }

    @IsTest
    static void testGetPurchaseHistory_blankId() {
        Test.startTest();
        List<Map<String, Object>> orders =
            DataCloudProfileService.getPurchaseHistory('', 365);
        Test.stopTest();

        System.assertEquals(0, orders.size(), 'Empty list for blank Id');
    }

    // ─── DataCloudProfileService — getHighValueProfiles ─────────────────────

    @IsTest
    static void testGetHighValueProfiles_withNextBatch() {
        DataCloudProfileService.calloutMock = new QueryMock(200, JSON.serialize(
            new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{
                        'UnifiedIndividualId__c' => 'uid-001',
                        'TotalLifetimeValue__c'  => 50000
                    }
                },
                'totalSize'   => 500,
                'nextBatchId' => 'batch-abc-123'
            }
        ));

        Test.startTest();
        DataCloudProfileService.PaginatedInsightResult result =
            DataCloudProfileService.getHighValueProfiles(10000.00, 1);
        Test.stopTest();

        System.assertEquals(1, result.records.size(), 'One record in this page');
        System.assertEquals(500, result.totalSize, 'Total size correct');
        System.assertEquals(true, result.hasMore, 'Has more pages');
        System.assertEquals('batch-abc-123', result.nextBatchId, 'Next batch Id set');
    }

    // ─── DataCloudProfileService — parseQueryResponse ─────────────────────────

    @IsTest
    static void testParseQueryResponse_complete() {
        String json = '{"data":[{"Name__c":"Acme"},{"Name__c":"Beta"}],"totalSize":2,"nextBatchId":"nxt"}';

        Test.startTest();
        DataCloudProfileService.QueryApiResponse result =
            DataCloudProfileService.parseQueryResponse(json);
        Test.stopTest();

        System.assertEquals(2, result.data.size(), 'Two data rows');
        System.assertEquals(2, result.totalSize, 'Total size = 2');
        System.assertEquals('nxt', result.nextBatchId, 'Next batch Id parsed');
        System.assertEquals('Acme', (String) result.data[0].get('Name__c'), 'First row data');
    }

    @IsTest
    static void testParseQueryResponse_malformed() {
        Test.startTest();
        DataCloudProfileService.QueryApiResponse result =
            DataCloudProfileService.parseQueryResponse('not-valid-json');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return empty result, not null');
        System.assertEquals(0, result.data.size(), 'No data on parse error');
    }

    // ─── UnifiedProfileResult — fullName ──────────────────────────────────────

    @IsTest
    static void testUnifiedProfileResult_fullName() {
        Test.startTest();
        DataCloudProfileService.UnifiedProfileResult p1 =
            new DataCloudProfileService.UnifiedProfileResult();
        p1.firstName = 'John'; p1.lastName = 'Smith';

        DataCloudProfileService.UnifiedProfileResult p2 =
            new DataCloudProfileService.UnifiedProfileResult();
        // no names

        DataCloudProfileService.UnifiedProfileResult p3 =
            new DataCloudProfileService.UnifiedProfileResult();
        p3.firstName = 'Madonna'; // no last name
        Test.stopTest();

        System.assertEquals('John Smith', p1.fullName(), 'Full name assembled');
        System.assertEquals('Unknown', p2.fullName(), 'No name = Unknown');
        System.assertEquals('Madonna', p3.fullName(), 'First name only');
    }

    // ─── Mock helpers ─────────────────────────────────────────────────────────

    private class IngestionMock implements HttpCalloutMock {
        Integer statusCode; String body;
        IngestionMock(Integer code, String body) { this.statusCode = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(statusCode); r.setBody(body);
            r.setHeader('Content-Type', 'application/json');
            return r;
        }
    }

    private class QueryMock implements HttpCalloutMock {
        Integer statusCode; String body;
        QueryMock(Integer code, String body) { this.statusCode = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(statusCode); r.setBody(body);
            r.setHeader('Content-Type', 'application/json');
            return r;
        }
    }

    // Returns different responses for sequential calls (email query then phone query)
    private class SequencedQueryMock implements HttpCalloutMock {
        List<String> responses;
        Integer callIndex = 0;
        SequencedQueryMock(List<String> bodies) { this.responses = bodies; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody(callIndex < responses.size() ? responses[callIndex++] : '{"data":[]}');
            r.setHeader('Content-Type', 'application/json');
            return r;
        }
    }
}
