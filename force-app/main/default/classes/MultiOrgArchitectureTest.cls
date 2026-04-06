/**
 * @description Tests for Day 23: Multi-Org Architecture.
 *              Covers OrgBridgeService (callout patterns) and OrgTopologyService
 *              (hub-spoke routing logic).
 *
 *              All HTTP callouts are intercepted via Test.setMock(HttpCalloutMock).
 *              CMDT routes are injected via OrgTopologyService.mockRoutes.
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class MultiOrgArchitectureTest {

    // ─── Mock helpers ─────────────────────────────────────────────────────────

    /** Single-use mock that returns a fixed status + body */
    private class StaticMock implements HttpCalloutMock {
        private final Integer statusCode;
        private final String  body;
        StaticMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body       = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    /** Sequence mock — returns responses in order, one per callout */
    private class SequenceMock implements HttpCalloutMock {
        private List<HttpResponse> responses;
        private Integer            idx = 0;
        SequenceMock(List<HttpResponse> responses) { this.responses = responses; }
        public HttpResponse respond(HttpRequest req) {
            return responses[Math.min(idx++, responses.size() - 1)];
        }
    }

    private static HttpResponse makeResponse(Integer statusCode, String body) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(statusCode);
        res.setBody(body);
        return res;
    }

    private static String queryBody(Integer total, List<Object> records) {
        return JSON.serialize(new Map<String, Object>{
            'totalSize' => total,
            'done'      => true,
            'records'   => records
        });
    }

    private static String compositeSuccessBody(Integer count) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (Integer i = 0; i < count; i++) {
            results.add(new Map<String, Object>{
                'id'      => '001000000000' + String.valueOf(i).leftPad(3, '0') + 'AAA',
                'success' => true,
                'errors'  => new List<Object>()
            });
        }
        return JSON.serialize(results);
    }

    private static String compositePartialBody() {
        List<Map<String, Object>> results = new List<Map<String, Object>>{
            new Map<String, Object>{
                'id' => '0010000000000001AAA', 'success' => true, 'errors' => new List<Object>()
            },
            new Map<String, Object>{
                'id' => null, 'success' => false,
                'errors' => new List<Object>{
                    new Map<String, Object>{ 'statusCode' => 'FIELD_CUSTOM_VALIDATION_EXCEPTION',
                        'message' => 'Name required' }
                }
            }
        };
        return JSON.serialize(results);
    }

    private static String userInfoBody(Boolean isSandbox) {
        return JSON.serialize(new Map<String, Object>{
            'organization_id'   => '00D000000000001AAA',
            'organization_type' => isSandbox ? 'Sandbox' : 'Enterprise Edition',
            'preferred_username'=> 'svc@example.com',
            'instance_url'      => 'https://example.salesforce.com',
            'is_sandbox'        => String.valueOf(isSandbox)
        });
    }

    // ─── OrgBridgeService — queryRemoteOrg ───────────────────────────────────

    @IsTest static void queryRemoteOrg_returnsRecords() {
        List<Object> recs = new List<Object>{
            new Map<String, Object>{ 'Id' => '001xx000000001', 'Name' => 'Acme' }
        };
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, queryBody(1, recs)));

        Test.startTest();
        List<Map<String, Object>> result =
            OrgBridgeService.queryRemoteOrg('Hub_Org', 'SELECT Id, Name FROM Account LIMIT 1');
        Test.stopTest();

        System.assertEquals(1, result.size());
        System.assertEquals('Acme', result[0].get('Name'));
    }

    @IsTest static void queryRemoteOrg_emptyRecordList() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, queryBody(0, new List<Object>())));

        Test.startTest();
        List<Map<String, Object>> result =
            OrgBridgeService.queryRemoteOrg('Hub_Org', 'SELECT Id FROM Account WHERE Id = null');
        Test.stopTest();

        System.assert(result.isEmpty());
    }

    @IsTest static void queryRemoteOrg_blankInputs_returnsEmpty() {
        Test.startTest();
        List<Map<String, Object>> r1 = OrgBridgeService.queryRemoteOrg(null, 'SELECT Id FROM Account');
        List<Map<String, Object>> r2 = OrgBridgeService.queryRemoteOrg('Hub_Org', '');
        Test.stopTest();

        System.assert(r1.isEmpty());
        System.assert(r2.isEmpty());
    }

    @IsTest static void queryRemoteOrg_httpError_throws() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(401, '{"errorCode":"INVALID_SESSION_ID"}'));

        Test.startTest();
        try {
            OrgBridgeService.queryRemoteOrg('Hub_Org', 'SELECT Id FROM Account');
            System.assert(false, 'Expected exception');
        } catch (OrgBridgeService.OrgBridgeException e) {
            System.assert(e.getMessage().contains('401'));
        }
        Test.stopTest();
    }

    // ─── OrgBridgeService — compositeUpsert ──────────────────────────────────

    @IsTest static void compositeUpsert_success() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, compositeSuccessBody(2)));
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Name' => 'Acme', 'External_Id__c' => 'EXT-001' },
            new Map<String, Object>{ 'Name' => 'Beta', 'External_Id__c' => 'EXT-002' }
        };

        Test.startTest();
        List<OrgBridgeService.CompositeResult> results =
            OrgBridgeService.compositeUpsert('Hub_Org', 'Account', 'External_Id__c', records);
        Test.stopTest();

        System.assertEquals(2, results.size());
        for (OrgBridgeService.CompositeResult r : results) {
            System.assert(r.success);
            System.assert(r.errors.isEmpty());
        }
    }

    @IsTest static void compositeUpsert_emptyList_returnsEmpty() {
        Test.startTest();
        List<OrgBridgeService.CompositeResult> results =
            OrgBridgeService.compositeUpsert('Hub_Org', 'Account', 'External_Id__c',
                new List<Map<String, Object>>());
        Test.stopTest();

        System.assert(results.isEmpty());
    }

    @IsTest static void compositeUpsert_partialFailure_reportsCorrectly() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, compositePartialBody()));
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Name' => 'Acme',   'External_Id__c' => 'EXT-001' },
            new Map<String, Object>{ 'Name' => null,     'External_Id__c' => 'EXT-002' }
        };

        Test.startTest();
        List<OrgBridgeService.CompositeResult> results =
            OrgBridgeService.compositeUpsert('Hub_Org', 'Account', 'External_Id__c', records);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assert(results[0].success,  'First record should succeed');
        System.assert(!results[1].success, 'Second record should fail');
        System.assertEquals(1, results[1].errors.size());
    }

    @IsTest static void compositeUpsert_httpError_throws() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(400, '{"errorCode":"MALFORMED_QUERY"}'));
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            new Map<String, Object>{ 'Name' => 'Acme', 'External_Id__c' => 'EXT-001' }
        };

        Test.startTest();
        try {
            OrgBridgeService.compositeUpsert('Hub_Org', 'Account', 'External_Id__c', records);
            System.assert(false, 'Expected exception');
        } catch (OrgBridgeService.OrgBridgeException e) {
            System.assert(e.getMessage().contains('400'));
        }
        Test.stopTest();
    }

    // ─── OrgBridgeService — getRemoteOrgInfo ─────────────────────────────────

    @IsTest static void getRemoteOrgInfo_production() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, userInfoBody(false)));

        Test.startTest();
        OrgBridgeService.OrgIdentity identity = OrgBridgeService.getRemoteOrgInfo('Hub_Org');
        Test.stopTest();

        System.assertEquals('00D000000000001AAA', identity.orgId);
        System.assertEquals('Enterprise Edition',  identity.orgType);
        System.assert(!identity.isSandbox);
    }

    @IsTest static void getRemoteOrgInfo_sandbox() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, userInfoBody(true)));

        Test.startTest();
        OrgBridgeService.OrgIdentity identity = OrgBridgeService.getRemoteOrgInfo('Hub_Org');
        Test.stopTest();

        System.assert(identity.isSandbox);
    }

    @IsTest static void getRemoteOrgInfo_httpError_throws() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(403, '{"errorCode":"FORBIDDEN"}'));

        Test.startTest();
        try {
            OrgBridgeService.getRemoteOrgInfo('Hub_Org');
            System.assert(false, 'Expected exception');
        } catch (OrgBridgeService.OrgBridgeException e) {
            System.assert(e.getMessage().contains('403'));
        }
        Test.stopTest();
    }

    // ─── OrgBridgeService — healthCheck ──────────────────────────────────────

    @IsTest static void healthCheck_returnsTrue_on200() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, '{"limitInfos":[]}'));

        Test.startTest();
        Boolean healthy = OrgBridgeService.healthCheck('Hub_Org');
        Test.stopTest();

        System.assert(healthy);
    }

    @IsTest static void healthCheck_returnsFalse_on500() {
        Test.setMock(HttpCalloutMock.class, new StaticMock(500, 'Internal Server Error'));

        Test.startTest();
        Boolean healthy = OrgBridgeService.healthCheck('Hub_Org');
        Test.stopTest();

        System.assert(!healthy);
    }

    // ─── OrgTopologyService — getRoute ───────────────────────────────────────

    @IsTest static void getRoute_returnsNull_whenNoMockRoutes() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>();

        Test.startTest();
        Org_Routing_Config__mdt route = OrgTopologyService.getRoute('Account');
        Test.stopTest();

        System.assertNull(route);
    }

    @IsTest static void getRoute_returnsFirstActiveRoute() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>{
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_APAC',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 1
            )
        };

        Test.startTest();
        Org_Routing_Config__mdt route = OrgTopologyService.getRoute('Account');
        Test.stopTest();

        System.assertNotNull(route);
        System.assertEquals('Spoke_APAC', route.Named_Credential__c);
    }

    @IsTest static void getRoute_ignoresInactiveRoutes() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>{
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_APAC',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = false,
                Routing_Priority__c = 1
            )
        };

        Test.startTest();
        Org_Routing_Config__mdt route = OrgTopologyService.getRoute('Account');
        Test.stopTest();

        System.assertNull(route);
    }

    // ─── OrgTopologyService — getAllSpokeRoutes ───────────────────────────────

    @IsTest static void getAllSpokeRoutes_excludesHubRoutes() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>{
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Hub_Org',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = true,
                Is_Active__c        = true,
                Routing_Priority__c = 1
            ),
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_EMEA',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 2
            )
        };

        Test.startTest();
        List<Org_Routing_Config__mdt> spokes = OrgTopologyService.getAllSpokeRoutes('Account');
        Test.stopTest();

        System.assertEquals(1, spokes.size());
        System.assertEquals('Spoke_EMEA', spokes[0].Named_Credential__c);
    }

    // ─── OrgTopologyService — syncToTargetOrg ────────────────────────────────

    @IsTest static void syncToTargetOrg_throwsWhenNoRoute() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>();

        Test.startTest();
        try {
            OrgTopologyService.syncToTargetOrg('Account', new List<Map<String, Object>>());
            System.assert(false, 'Expected TopologyException');
        } catch (OrgTopologyService.TopologyException e) {
            System.assert(e.getMessage().contains('Account'));
        }
        Test.stopTest();
    }

    @IsTest static void syncToTargetOrg_throwsOnHealthCheckFailure() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>{
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_APAC',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 1
            )
        };
        // Health check returns 500 → healthCheck() returns false
        Test.setMock(HttpCalloutMock.class, new StaticMock(500, 'Service unavailable'));

        Test.startTest();
        try {
            OrgTopologyService.syncToTargetOrg('Account',
                new List<Map<String, Object>>{
                    new Map<String, Object>{ 'Name' => 'Acme', 'External_Id__c' => 'E1' }
                });
            System.assert(false, 'Expected TopologyException');
        } catch (OrgTopologyService.TopologyException e) {
            System.assert(e.getMessage().contains('Health check'));
        }
        Test.stopTest();
    }

    @IsTest static void syncToTargetOrg_countsSuccessesCorrectly() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>{
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_APAC',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 1
            )
        };
        // Sequence: health check (200) → composite upsert (200 with 2 successes)
        Test.setMock(HttpCalloutMock.class, new SequenceMock(new List<HttpResponse>{
            makeResponse(200, '{"limitInfos":[]}'),
            makeResponse(200, compositeSuccessBody(2))
        }));

        Test.startTest();
        OrgTopologyService.SyncResult result = OrgTopologyService.syncToTargetOrg('Account',
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'Name' => 'Acme', 'External_Id__c' => 'E1' },
                new Map<String, Object>{ 'Name' => 'Beta', 'External_Id__c' => 'E2' }
            });
        Test.stopTest();

        System.assertEquals(2, result.successCount);
        System.assertEquals(0, result.failureCount);
        System.assert(result.isFullSuccess);
    }

    // ─── OrgTopologyService — broadcastToAllSpokes ────────────────────────────

    @IsTest static void broadcastToAllSpokes_returnsResultPerSpoke() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>{
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_EMEA',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 1
            ),
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_APAC',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 2
            )
        };
        Test.setMock(HttpCalloutMock.class, new StaticMock(200, compositeSuccessBody(1)));

        Test.startTest();
        Map<String, OrgTopologyService.SyncResult> results =
            OrgTopologyService.broadcastToAllSpokes('Account',
                new List<Map<String, Object>>{
                    new Map<String, Object>{ 'Name' => 'Acme', 'External_Id__c' => 'E1' }
                });
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assert(results.containsKey('Spoke_EMEA'));
        System.assert(results.containsKey('Spoke_APAC'));
        System.assert(results.get('Spoke_EMEA').isFullSuccess);
        System.assert(results.get('Spoke_APAC').isFullSuccess);
    }

    @IsTest static void broadcastToAllSpokes_capturesPerSpokeFailure() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>{
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_EMEA',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 1
            ),
            new Org_Routing_Config__mdt(
                Named_Credential__c = 'Spoke_APAC',
                Object_API_Name__c  = 'Account',
                External_Id_Field__c= 'External_Id__c',
                Is_Hub__c           = false,
                Is_Active__c        = true,
                Routing_Priority__c = 2
            )
        };
        // EMEA fails, APAC succeeds
        Test.setMock(HttpCalloutMock.class, new SequenceMock(new List<HttpResponse>{
            makeResponse(503, 'Service Unavailable'),
            makeResponse(200, compositeSuccessBody(1))
        }));

        Test.startTest();
        Map<String, OrgTopologyService.SyncResult> results =
            OrgTopologyService.broadcastToAllSpokes('Account',
                new List<Map<String, Object>>{
                    new Map<String, Object>{ 'Name' => 'Acme', 'External_Id__c' => 'E1' }
                });
        Test.stopTest();

        System.assert(!results.get('Spoke_EMEA').isFullSuccess);
        System.assertNotNull(results.get('Spoke_EMEA').errorMessage);
        System.assert(results.get('Spoke_APAC').isFullSuccess);
    }

    @IsTest static void broadcastToAllSpokes_noSpokes_returnsEmptyMap() {
        OrgTopologyService.mockRoutes = new List<Org_Routing_Config__mdt>();

        Test.startTest();
        Map<String, OrgTopologyService.SyncResult> results =
            OrgTopologyService.broadcastToAllSpokes('Account',
                new List<Map<String, Object>>{
                    new Map<String, Object>{ 'Name' => 'Acme', 'External_Id__c' => 'E1' }
                });
        Test.stopTest();

        System.assert(results.isEmpty());
    }

    // ─── SyncResult helper ────────────────────────────────────────────────────

    @IsTest static void syncResult_isFullSuccess_falseOnPartial() {
        OrgTopologyService.SyncResult sr = new OrgTopologyService.SyncResult();
        sr.successCount = 3;
        sr.failureCount = 1;
        System.assert(!sr.isFullSuccess);
    }

    @IsTest static void syncResult_isFullSuccess_trueWhenAllPass() {
        OrgTopologyService.SyncResult sr = new OrgTopologyService.SyncResult();
        sr.successCount = 5;
        sr.failureCount = 0;
        System.assert(sr.isFullSuccess);
    }
}
