/**
 * MetadataApiServiceTest
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 21 — Tests for MetadataApiService and EnvironmentService.
 *
 * TESTING APPROACH:
 * ══════════════════
 * MetadataApiService makes HTTP callouts to the Tooling API and Metadata API.
 * In tests, these callouts must be mocked via HttpCalloutMock.
 *
 * EnvironmentService queries the Organization sObject — always available,
 * no mocking needed. Tests assert on structural behavior (detect() returns
 * a non-null result with populated fields).
 *
 * TOOLING API MOCK STRATEGY:
 * ═══════════════════════════
 * Each test provides a JSON response matching the Tooling API shape:
 *   { "totalSize": N, "done": true, "records": [...] }
 */
@IsTest
private class MetadataApiServiceTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Mock HTTP responses
    // ─────────────────────────────────────────────────────────────────────────

    private class ToolingApiMock implements HttpCalloutMock {
        private Integer statusCode;
        private String  body;

        ToolingApiMock(Integer code, String responseBody) {
            statusCode = code;
            body       = responseBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    private static final String APEX_CLASS_RESPONSE = JSON.serialize(new Map<String, Object>{
        'totalSize' => 2,
        'done'      => true,
        'records'   => new List<Object>{
            new Map<String, Object>{
                'Id'                    => '01pXXXXXXXXXXXXXX1',
                'Name'                  => 'AccountService',
                'ApiVersion'            => 62.0,
                'Status'                => 'Active',
                'IsValid'               => true,
                'LengthWithoutComments' => 450,
                'CreatedDate'           => '2026-01-01T00:00:00.000Z',
                'LastModifiedDate'      => '2026-04-01T00:00:00.000Z',
                'LastModifiedBy'        => new Map<String,Object>{ 'Name' => 'Admin User' },
                'NamespacePrefix'       => null
            },
            new Map<String, Object>{
                'Id'                    => '01pXXXXXXXXXXXXXX2',
                'Name'                  => 'AccountServiceTest',
                'ApiVersion'            => 62.0,
                'Status'                => 'Active',
                'IsValid'               => true,
                'LengthWithoutComments' => 300,
                'CreatedDate'           => '2026-01-01T00:00:00.000Z',
                'LastModifiedDate'      => '2026-04-01T00:00:00.000Z',
                'LastModifiedBy'        => new Map<String,Object>{ 'Name' => 'Admin User' },
                'NamespacePrefix'       => null
            }
        }
    });

    private static final String CODE_COVERAGE_RESPONSE = JSON.serialize(new Map<String, Object>{
        'totalSize' => 2,
        'done'      => true,
        'records'   => new List<Object>{
            new Map<String, Object>{
                'ApexClassOrTriggerId'  => '01pXXXXXXXXXXXXXX1',
                'ApexClassOrTrigger'    => new Map<String,Object>{ 'Name' => 'AccountService' },
                'NumLinesCovered'       => 90,
                'NumLinesUncovered'     => 10
            },
            new Map<String, Object>{
                'ApexClassOrTriggerId'  => '01pXXXXXXXXXXXXXX2',
                'ApexClassOrTrigger'    => new Map<String,Object>{ 'Name' => 'OrgConfigService' },
                'NumLinesCovered'       => 60,
                'NumLinesUncovered'     => 40
            }
        }
    });

    private static final String TEST_RESULT_RESPONSE = JSON.serialize(new Map<String, Object>{
        'totalSize' => 3,
        'done'      => true,
        'records'   => new List<Object>{
            new Map<String, Object>{
                'Id'        => 'TestResultId1',
                'ApexClass' => new Map<String,Object>{ 'Name' => 'AccountServiceTest' },
                'MethodName'=> 'testGetAccounts',
                'Outcome'   => 'Pass',
                'RunTime'   => 45,
                'Message'   => null,
                'StackTrace'=> null
            },
            new Map<String, Object>{
                'Id'        => 'TestResultId2',
                'ApexClass' => new Map<String,Object>{ 'Name' => 'AccountServiceTest' },
                'MethodName'=> 'testCreateAccount',
                'Outcome'   => 'Fail',
                'RunTime'   => 12,
                'Message'   => 'System.AssertException: Assertion failed',
                'StackTrace'=> 'AccountServiceTest.testCreateAccount: line 42'
            },
            new Map<String, Object>{
                'Id'        => 'TestResultId3',
                'ApexClass' => new Map<String,Object>{ 'Name' => 'AccountServiceTest' },
                'MethodName'=> 'testDeleteAccount',
                'Outcome'   => 'Pass',
                'RunTime'   => 8,
                'Message'   => null,
                'StackTrace'=> null
            }
        }
    });

    private static final String DEPLOY_STATUS_RESPONSE = JSON.serialize(new Map<String, Object>{
        'id'           => '0AfXXXXXXXXXXXXXX1',
        'deployResult' => new Map<String, Object>{
            'done'                        => true,
            'success'                     => true,
            'status'                      => 'Succeeded',
            'numberComponentsDeployed'    => 5,
            'numberComponentTotal'        => 5,
            'numberTestsCompleted'        => 20,
            'numberTestErrors'            => 0,
            'details'                     => new Map<String, Object>{
                'componentFailures' => new List<Object>()
            }
        }
    });

    private static final String CUSTOM_FIELD_RESPONSE = JSON.serialize(new Map<String, Object>{
        'totalSize' => 2,
        'done'      => true,
        'records'   => new List<Object>{
            new Map<String, Object>{
                'Id'          => 'FieldId1',
                'DeveloperName' => 'Sync_Status',
                'Label'       => 'Sync Status',
                'DataType'    => 'Picklist',
                'Description' => 'Sync status for external system'
            },
            new Map<String, Object>{
                'Id'          => 'FieldId2',
                'DeveloperName' => 'Sync_Error',
                'Label'       => 'Sync Error',
                'DataType'    => 'Text(255)',
                'Description' => 'Error message from last sync attempt'
            }
        }
    });

    // ─────────────────────────────────────────────────────────────────────────
    // listApexClasses
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void listApexClasses_returnsParsedList() {
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, APEX_CLASS_RESPONSE));

        Test.startTest();
        List<MetadataApiService.ApexClassInfo> classes =
            MetadataApiService.listApexClasses();
        Test.stopTest();

        System.assertEquals(2, classes.size(), 'Should return 2 classes');
        System.assertEquals('AccountService', classes[0].name,  'First class name');
        System.assertEquals('Active',         classes[0].status, 'Status should be Active');
        System.assert(classes[0].isValid,                        'IsValid should be true');
        System.assertEquals('Admin User', classes[0].lastModifiedByName, 'LastModifiedBy');
        System.assertEquals(450, classes[0].lengthWithoutComments, 'LengthWithoutComments');
    }

    @IsTest
    static void listApexClasses_testClassDetection() {
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, APEX_CLASS_RESPONSE));
        List<MetadataApiService.ApexClassInfo> classes =
            MetadataApiService.listApexClasses();

        System.assert(!classes[0].isTestClass(), 'AccountService is not a test class');
        System.assert(classes[1].isTestClass(),  'AccountServiceTest is a test class');
    }

    @IsTest
    static void listApexClasses_emptyRecords_returnsEmptyList() {
        String emptyResponse = '{"totalSize":0,"done":true,"records":[]}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, emptyResponse));

        List<MetadataApiService.ApexClassInfo> classes =
            MetadataApiService.listApexClasses();

        System.assert(classes.isEmpty(), 'Empty records should return empty list');
    }

    @IsTest
    static void listApexClasses_httpError_throwsException() {
        Test.setMock(HttpCalloutMock.class,
            new ToolingApiMock(401, '[{"message":"Session expired"}]'));

        Test.startTest();
        try {
            MetadataApiService.listApexClasses();
            System.assert(false, 'Should have thrown ToolingApiException');
        } catch (MetadataApiService.ToolingApiException ex) {
            System.assertEquals(401, ex.statusCode, 'statusCode should be 401');
            System.assert(ex.getMessage().contains('401'), 'Message should contain status code');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getApexClassBody
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getApexClassBody_returnsBody() {
        String bodyResponse = JSON.serialize(new Map<String, Object>{
            'totalSize' => 1, 'done' => true,
            'records'   => new List<Object>{
                new Map<String, Object>{
                    'Id' => '01pXXX', 'Name' => 'MyClass',
                    'Body' => 'public class MyClass { }'
                }
            }
        });
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, bodyResponse));

        Test.startTest();
        String body = MetadataApiService.getApexClassBody('01pXXX');
        Test.stopTest();

        System.assertEquals('public class MyClass { }', body, 'Body should match');
    }

    @IsTest
    static void getApexClassBody_notFound_returnsNull() {
        String emptyResponse = '{"totalSize":0,"done":true,"records":[]}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, emptyResponse));

        String body = MetadataApiService.getApexClassBody('nonexistent');
        System.assertNull(body, 'Not found should return null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Code coverage
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getCodeCoverageAggregate_parsesCoverageData() {
        Test.setMock(HttpCalloutMock.class,
            new ToolingApiMock(200, CODE_COVERAGE_RESPONSE));

        Test.startTest();
        List<MetadataApiService.CodeCoverageInfo> coverage =
            MetadataApiService.getCodeCoverageAggregate();
        Test.stopTest();

        System.assertEquals(2, coverage.size(), 'Should return 2 coverage records');

        MetadataApiService.CodeCoverageInfo first = coverage[0];
        System.assertEquals('AccountService', first.apexClassOrTriggerName, 'Class name');
        System.assertEquals(90, first.numLinesCovered,   'Lines covered');
        System.assertEquals(10, first.numLinesUncovered, 'Lines uncovered');
        System.assertEquals(90.0, first.coveragePct,     'Coverage pct: 90/100 = 90%');
    }

    @IsTest
    static void coveragePct_calculatesCorrectly() {
        MetadataApiService.CodeCoverageInfo info = new MetadataApiService.CodeCoverageInfo();
        info.numLinesCovered   = 75;
        info.numLinesUncovered = 25;
        System.assertEquals(75.0, info.coveragePct, '75/100 = 75%');
    }

    @IsTest
    static void coveragePct_zeroLines_returnsZero() {
        MetadataApiService.CodeCoverageInfo info = new MetadataApiService.CodeCoverageInfo();
        info.numLinesCovered   = 0;
        info.numLinesUncovered = 0;
        System.assertEquals(0, info.coveragePct, '0 lines → 0% coverage');
    }

    @IsTest
    static void getUndercoveredClasses_filtersBelow75Pct() {
        Test.setMock(HttpCalloutMock.class,
            new ToolingApiMock(200, CODE_COVERAGE_RESPONSE));

        Test.startTest();
        List<MetadataApiService.CodeCoverageInfo> under =
            MetadataApiService.getUndercoveredClasses(75);
        Test.stopTest();

        // AccountService: 90% → above threshold
        // OrgConfigService: 60% → below threshold
        System.assertEquals(1, under.size(), 'Only 1 class below 75%');
        System.assertEquals('OrgConfigService', under[0].apexClassOrTriggerName,
            'OrgConfigService at 60% should be flagged');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test results
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getLatestTestResults_parsesResults() {
        Test.setMock(HttpCalloutMock.class,
            new ToolingApiMock(200, TEST_RESULT_RESPONSE));

        Test.startTest();
        List<MetadataApiService.TestResultInfo> results =
            MetadataApiService.getLatestTestResults('AccountServiceTest');
        Test.stopTest();

        System.assertEquals(3, results.size(), 'Should return 3 test results');

        MetadataApiService.TestResultInfo pass = results[0];
        System.assertEquals('Pass',               pass.outcome,    'First result passes');
        System.assertEquals('testGetAccounts',     pass.methodName, 'Method name');
        System.assertEquals('AccountServiceTest',  pass.apexClassName, 'Class name');
        System.assertEquals(45,                    pass.runTime,    'Run time ms');
        System.assertNull(pass.message,                             'Pass should have no message');

        MetadataApiService.TestResultInfo fail = results[1];
        System.assertEquals('Fail', fail.outcome, 'Second result fails');
        System.assert(fail.message.contains('AssertException'), 'Failure message set');
        System.assertNotEquals(null, fail.stackTrace, 'Stack trace should be set');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deploy status
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getDeployStatus_parsesSuccessResponse() {
        Test.setMock(HttpCalloutMock.class,
            new ToolingApiMock(200, DEPLOY_STATUS_RESPONSE));

        Test.startTest();
        MetadataApiService.DeployStatusInfo status =
            MetadataApiService.getDeployStatus('0AfXXXXXXXXXXXXXX1');
        Test.stopTest();

        System.assert(status.done,    'done should be true');
        System.assert(status.success, 'success should be true');
        System.assertEquals('Succeeded', status.status,               'status');
        System.assertEquals(5, status.numberComponentsDeployed,        'components deployed');
        System.assertEquals(20, status.numberTestsCompleted,           'tests completed');
        System.assertEquals(0,  status.numberTestErrors,               'test errors');
        System.assert(status.componentFailures.isEmpty(),               'no component failures');
    }

    @IsTest
    static void getDeployStatus_httpError_throwsException() {
        Test.setMock(HttpCalloutMock.class,
            new ToolingApiMock(404, '[{"message":"Deploy not found"}]'));

        try {
            MetadataApiService.getDeployStatus('badId');
            System.assert(false, 'Should throw');
        } catch (MetadataApiService.ToolingApiException ex) {
            System.assertEquals(404, ex.statusCode, 'Should be 404');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Custom fields
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void listCustomFields_returnsFieldMaps() {
        Test.setMock(HttpCalloutMock.class,
            new ToolingApiMock(200, CUSTOM_FIELD_RESPONSE));

        Test.startTest();
        List<Map<String, Object>> fields =
            MetadataApiService.listCustomFields('Account');
        Test.stopTest();

        System.assertEquals(2, fields.size(), 'Should return 2 fields');
        System.assertEquals('Sync_Status', fields[0].get('DeveloperName'), 'First field name');
        System.assertEquals('Picklist',    fields[0].get('DataType'),       'DataType');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EnvironmentService.detect()
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void detect_returnsNonNullResult() {
        Test.startTest();
        EnvironmentService.EnvironmentInfo info = EnvironmentService.detect();
        Test.stopTest();

        System.assertNotEquals(null, info,             'info should not be null');
        System.assertNotEquals(null, info.environment, 'environment should be set');
        System.assertNotEquals(null, info.orgId,       'orgId should be set');
        System.assertNotEquals(null, info.orgName,     'orgName should be set');
        System.assertNotEquals(null, info.domainUrl,   'domainUrl should be set');
    }

    @IsTest
    static void detect_environmentMatchesSandboxFlag() {
        EnvironmentService.EnvironmentInfo info = EnvironmentService.detect();

        if (info.isSandbox) {
            System.assert(
                info.environment == EnvironmentService.OrgEnvironment.DEVELOPER_SANDBOX
                || info.environment == EnvironmentService.OrgEnvironment.PARTIAL_SANDBOX
                || info.environment == EnvironmentService.OrgEnvironment.FULL_SANDBOX,
                'Sandbox org should map to a sandbox environment type'
            );
        } else if (!info.isScratch) {
            System.assertEquals(EnvironmentService.OrgEnvironment.PRODUCTION,
                info.environment, 'Non-sandbox, non-scratch = production');
        }
    }

    @IsTest
    static void detect_toString_containsEnvironmentName() {
        EnvironmentService.EnvironmentInfo info = EnvironmentService.detect();
        String str = info.toString();
        System.assert(str.contains(info.environment.name()),
            'toString should contain environment name');
        System.assert(str.contains(info.orgName),
            'toString should contain org name');
    }

    @IsTest
    static void detect_isLowerEnvironment_trueForScratch() {
        // We can only test this indirectly — create a mock-like scenario
        // by checking the logic directly
        EnvironmentService.EnvironmentInfo info = EnvironmentService.detect();
        if (info.environment == EnvironmentService.OrgEnvironment.SCRATCH) {
            System.assert(info.isLowerEnvironment(), 'Scratch should be lower environment');
        }
        if (info.environment == EnvironmentService.OrgEnvironment.PRODUCTION) {
            System.assert(!info.isLowerEnvironment(), 'Production is not lower environment');
            System.assert(!info.allowsDestructiveOperations(),
                'Production should not allow destructive operations');
        }
    }

    @IsTest
    static void detect_allowsDestructiveOperations_falseForProduction() {
        EnvironmentService.EnvironmentInfo info = EnvironmentService.detect();
        if (info.isProduction) {
            System.assert(!info.allowsDestructiveOperations(),
                'Production should not allow destructive operations');
        } else {
            System.assert(info.allowsDestructiveOperations(),
                'Non-production should allow destructive operations');
        }
    }

    @IsTest
    static void assertNotProduction_throwsInProd() {
        EnvironmentService.EnvironmentInfo info = EnvironmentService.detect();
        if (info.isProduction) {
            try {
                EnvironmentService.assertNotProduction('TestOp');
                System.assert(false, 'Should throw in production');
            } catch (EnvironmentService.EnvironmentGuardException ex) {
                System.assert(ex.getMessage().contains('TestOp'),
                    'Exception should mention operation name');
            }
        } else {
            // In non-production, should not throw
            EnvironmentService.assertNotProduction('TestOp');
            System.assert(true, 'Non-production should not throw');
        }
    }

    @IsTest
    static void getEnvironmentConfig_returnsMapWithRequiredKeys() {
        Test.startTest();
        Map<String, String> config = EnvironmentService.getEnvironmentConfig();
        Test.stopTest();

        System.assertNotEquals(null, config,                         'config not null');
        System.assert(config.containsKey('ENVIRONMENT'),             'has ENVIRONMENT key');
        System.assert(config.containsKey('ORG_ID'),                  'has ORG_ID key');
        System.assert(config.containsKey('IS_SANDBOX'),              'has IS_SANDBOX key');
        System.assert(config.containsKey('IS_PRODUCTION'),           'has IS_PRODUCTION key');
        System.assertNotEquals(null, config.get('ENVIRONMENT'),      'ENVIRONMENT has value');
    }

    @IsTest
    static void getExternalApiEndpoint_returnsNonBlankUrl() {
        Test.startTest();
        String endpoint = EnvironmentService.getExternalApiEndpoint();
        Test.stopTest();

        System.assert(String.isNotBlank(endpoint),     'endpoint should not be blank');
        System.assert(endpoint.startsWith('https://'), 'endpoint should be HTTPS');
    }
}
