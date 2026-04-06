/**
 * @description Hub-spoke org routing service driven by Org_Routing_Config__mdt.
 *
 *              Multi-org topology patterns:
 *
 *              HUB-AND-SPOKE (implemented here)
 *                Hub org = source of truth, owns master records.
 *                Spoke orgs = regional / functional orgs, receive subsets from hub.
 *                Config in CMDT = zero code deployment to add a new spoke.
 *
 *              MESH
 *                Any org can push/pull to any other.
 *                Higher callout complexity; requires conflict resolution strategy.
 *
 *              FEDERATED
 *                Shared identity (SSO), separate data stores.
 *                Often combined with hub-spoke for data; Connected App + Auth Provider.
 *
 *              When to use multiple orgs (interview Q):
 *                - Legal / data residency requirements (EU vs US data sovereignty)
 *                - Distinct business units with different release cadences
 *                - ISV: each customer gets a managed-package-installed org
 *                - Blast-radius isolation: one org's batch runaway cannot affect others
 *
 *              When NOT to use multiple orgs:
 *                - Simple sandbox strategy — use sandboxes, not separate production orgs
 *                - Shared objects needed across units — cross-org callouts add latency
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class OrgTopologyService {

    // Inject mock routes in tests — CMDT records cannot be DML-inserted in tests
    @TestVisible static List<Org_Routing_Config__mdt> mockRoutes;

    // ─── Route lookup ─────────────────────────────────────────────────────────

    /**
     * Returns the highest-priority active route for the given SObject type.
     * Returns null if no active route is configured — callers must handle gracefully.
     *
     * @param objectApiName  SObject API name, e.g. 'Account'
     */
    public static Org_Routing_Config__mdt getRoute(String objectApiName) {
        List<Org_Routing_Config__mdt> routes = queryRoutes(objectApiName, false);
        return routes.isEmpty() ? null : routes[0];
    }

    /**
     * Returns all active spoke routes for a given SObject type.
     * Hub routes (Is_Hub__c = true) are excluded — the hub is the sender, not a target.
     *
     * @param objectApiName  SObject API name
     */
    public static List<Org_Routing_Config__mdt> getAllSpokeRoutes(String objectApiName) {
        return queryRoutes(objectApiName, true);
    }

    // ─── Sync operations ──────────────────────────────────────────────────────

    /**
     * Syncs records to the primary configured target org for the given SObject.
     * Runs a health check first to fail fast before attempting bulk callouts.
     *
     * @param objectApiName  Used to look up the Org_Routing_Config__mdt route
     * @param records        Records as field-value maps for Composite API upsert
     * @return               SyncResult with success/failure counts
     */
    public static SyncResult syncToTargetOrg(
            String objectApiName, List<Map<String, Object>> records) {
        Org_Routing_Config__mdt route = getRoute(objectApiName);
        if (route == null) {
            throw new TopologyException('No active routing config found for: ' + objectApiName);
        }
        if (!OrgBridgeService.healthCheck(route.Named_Credential__c)) {
            throw new TopologyException('Health check failed for: ' + route.Named_Credential__c);
        }
        List<OrgBridgeService.CompositeResult> results = OrgBridgeService.compositeUpsert(
            route.Named_Credential__c, objectApiName, route.External_Id_Field__c, records);
        return buildSyncResult(results);
    }

    /**
     * Broadcasts records to ALL active spoke orgs for the given SObject type.
     * Each spoke is attempted independently — one failure does not abort the others.
     *
     * Returns a map of Named Credential developer name → SyncResult for per-spoke reporting.
     *
     * Callout budget: for S spokes and N records → ceil(N/200) × S callouts.
     * Callers should verify total callout count before invoking in bulk-trigger context.
     *
     * @param objectApiName  SObject API name
     * @param records        Records to broadcast
     * @return               Per-spoke SyncResult keyed by Named Credential name
     */
    public static Map<String, SyncResult> broadcastToAllSpokes(
            String objectApiName, List<Map<String, Object>> records) {
        List<Org_Routing_Config__mdt> spokes = getAllSpokeRoutes(objectApiName);
        Map<String, SyncResult> resultMap = new Map<String, SyncResult>();

        for (Org_Routing_Config__mdt spoke : spokes) {
            try {
                List<OrgBridgeService.CompositeResult> raw = OrgBridgeService.compositeUpsert(
                    spoke.Named_Credential__c, objectApiName,
                    spoke.External_Id_Field__c, records);
                resultMap.put(spoke.Named_Credential__c, buildSyncResult(raw));
            } catch (Exception e) {
                SyncResult failed    = new SyncResult();
                failed.successCount  = 0;
                failed.failureCount  = records.size();
                failed.errorMessage  = e.getMessage();
                resultMap.put(spoke.Named_Credential__c, failed);
            }
        }
        return resultMap;
    }

    // ─── Result types ─────────────────────────────────────────────────────────

    public class SyncResult {
        public Integer successCount = 0;
        public Integer failureCount = 0;
        public String  errorMessage;
        public Boolean isFullSuccess { get { return failureCount == 0 && errorMessage == null; } }
    }

    public class TopologyException extends Exception {}

    // ─── Private helpers ──────────────────────────────────────────────────────

    @TestVisible
    private static List<Org_Routing_Config__mdt> queryRoutes(
            String objectApiName, Boolean spokesOnly) {
        if (Test.isRunningTest() && mockRoutes != null) {
            List<Org_Routing_Config__mdt> filtered = new List<Org_Routing_Config__mdt>();
            for (Org_Routing_Config__mdt r : mockRoutes) {
                if (r.Object_API_Name__c == objectApiName
                        && r.Is_Active__c
                        && (!spokesOnly || !r.Is_Hub__c)) {
                    filtered.add(r);
                }
            }
            filtered.sort();
            return filtered;
        }
        if (spokesOnly) {
            return [
                SELECT Named_Credential__c, Object_API_Name__c,
                       External_Id_Field__c, Is_Hub__c,
                       Is_Active__c, Routing_Priority__c
                FROM   Org_Routing_Config__mdt
                WHERE  Object_API_Name__c = :objectApiName
                  AND  Is_Active__c       = true
                  AND  Is_Hub__c          = false
                ORDER BY Routing_Priority__c ASC
            ];
        }
        return [
            SELECT Named_Credential__c, Object_API_Name__c,
                   External_Id_Field__c, Is_Hub__c,
                   Is_Active__c, Routing_Priority__c
            FROM   Org_Routing_Config__mdt
            WHERE  Object_API_Name__c = :objectApiName
              AND  Is_Active__c       = true
            ORDER BY Routing_Priority__c ASC
            LIMIT 1
        ];
    }

    private static SyncResult buildSyncResult(List<OrgBridgeService.CompositeResult> results) {
        SyncResult sr = new SyncResult();
        for (OrgBridgeService.CompositeResult r : results) {
            if (r.success) { sr.successCount++; }
            else           { sr.failureCount++; }
        }
        return sr;
    }
}
