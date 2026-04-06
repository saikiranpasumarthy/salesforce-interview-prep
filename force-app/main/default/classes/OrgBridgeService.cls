/**
 * @description Cross-org REST integration service — Salesforce-to-Salesforce patterns.
 *
 *              Uses Named Credentials (callout:<NC>) so auth is fully platform-managed:
 *              token refresh, credential rotation, and sandbox→prod URL switching all
 *              happen in Setup without a code deployment.
 *
 *              Key patterns:
 *                1. queryRemoteOrg   — SOQL via Data API /query endpoint
 *                2. compositeUpsert  — Composite SObject Collections API; N records in 1 callout
 *                3. getRemoteOrgInfo — /services/oauth2/userinfo for org fingerprinting
 *                4. healthCheck      — lightweight connectivity probe
 *
 *              Composite API limits:
 *                - Max 200 records per PATCH with allOrNone=false
 *                - allOrNone=true is an atomic batch — one failure rolls back all
 *                - Large batches are auto-chunked inside compositeUpsert
 *
 *              Callout governor: 100 per transaction. With 3 spokes × ceil(500/200)=3 chunks
 *              that is 9 callouts — always estimate before doing fan-out.
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class OrgBridgeService {

    @TestVisible static final String API_VERSION     = '63.0';
    private static final String      DATA_API        = '/services/data/v' + API_VERSION;
    private static final Integer     CHUNK_SIZE      = 200;
    private static final Integer     DEFAULT_TIMEOUT = 30000;

    // ─── Remote SOQL Query ────────────────────────────────────────────────────

    /**
     * Executes SOQL on a remote Salesforce org via its REST Data API.
     * Named Credential handles auth — zero token management in Apex.
     *
     * Interview point: pagination — the response includes a `nextRecordsUrl`
     * when totalSize > 2000. Loop on queryMore for full result sets.
     *
     * @param namedCredential  Developer name of the Named Credential (points to target org)
     * @param soql             SOQL to execute on the remote org
     * @return                 Records as untyped maps (field → value)
     */
    public static List<Map<String, Object>> queryRemoteOrg(
            String namedCredential, String soql) {
        if (String.isBlank(namedCredential) || String.isBlank(soql)) {
            return new List<Map<String, Object>>();
        }
        HttpRequest  req = buildRequest(namedCredential,
            DATA_API + '/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'),
            'GET', null);
        HttpResponse res = new Http().send(req);
        assertSuccess(res, 200, 'queryRemoteOrg');

        Map<String, Object> parsed  = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object>        records = (List<Object>) parsed.get('records');
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object r : records) { result.add((Map<String, Object>) r); }
        return result;
    }

    // ─── Composite Upsert ─────────────────────────────────────────────────────

    /**
     * Upserts records on a remote org using the Composite SObject Collections API.
     * Auto-chunks into batches of 200 to stay within the API record limit.
     *
     * allOrNone=false: partial success — inspect individual CompositeResult.success.
     * allOrNone=true:  atomic — any failure rolls back the entire chunk.
     *
     * @param namedCredential  Named Credential developer name
     * @param objectApiName    SObject API name (e.g. 'Account')
     * @param externalIdField  External ID field used as the upsert key
     * @param records          Records as field-value maps; must include externalIdField
     * @return                 One CompositeResult per input record in original order
     */
    public static List<CompositeResult> compositeUpsert(
            String namedCredential,
            String objectApiName,
            String externalIdField,
            List<Map<String, Object>> records) {
        if (records == null || records.isEmpty()) { return new List<CompositeResult>(); }

        List<CompositeResult> allResults = new List<CompositeResult>();
        Integer idx = 0;
        while (idx < records.size()) {
            Integer end   = Math.min(idx + CHUNK_SIZE, records.size());
            List<Map<String, Object>> chunk = new List<Map<String, Object>>();
            for (Integer i = idx; i < end; i++) { chunk.add(records[i]); }

            String body = JSON.serialize(new Map<String, Object>{
                'allOrNone' => false,
                'records'   => chunk
            });
            HttpRequest req = buildRequest(
                namedCredential,
                DATA_API + '/composite/sobjects/' + objectApiName + '/' + externalIdField,
                'PATCH', body
            );
            req.setTimeout(120000);
            HttpResponse res = new Http().send(req);
            assertSuccess(res, 200, 'compositeUpsert');
            allResults.addAll(parseCompositeResults(res.getBody()));
            idx = end;
        }
        return allResults;
    }

    // ─── Remote Org Identity ──────────────────────────────────────────────────

    /**
     * Retrieves identity info from the target org's OAuth userinfo endpoint.
     * Use for org fingerprinting — verify you are talking to the right org and
     * detect sandbox vs production before sending sensitive data.
     *
     * @param namedCredential  Named Credential pointing to target org
     * @return                 OrgIdentity with orgId, sandbox flag, instanceUrl, etc.
     */
    public static OrgIdentity getRemoteOrgInfo(String namedCredential) {
        HttpRequest  req = buildRequest(namedCredential, '/services/oauth2/userinfo', 'GET', null);
        HttpResponse res = new Http().send(req);
        assertSuccess(res, 200, 'getRemoteOrgInfo');

        Map<String, Object> info = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        OrgIdentity identity     = new OrgIdentity();
        identity.orgId           = (String) info.get('organization_id');
        identity.orgType         = (String) info.get('organization_type');
        identity.username        = (String) info.get('preferred_username');
        identity.instanceUrl     = (String) info.get('instance_url');
        identity.isSandbox       = 'true'.equalsIgnoreCase(String.valueOf(info.get('is_sandbox')));
        return identity;
    }

    /**
     * Lightweight connectivity probe — GET /limits returns 200 when the org is reachable.
     * Returns false instead of throwing so callers can branch gracefully.
     */
    public static Boolean healthCheck(String namedCredential) {
        try {
            HttpRequest  req = buildRequest(namedCredential, DATA_API + '/limits', 'GET', null);
            req.setTimeout(10000);
            return new Http().send(req).getStatusCode() == 200;
        } catch (Exception e) {
            return false;
        }
    }

    // ─── Result types ─────────────────────────────────────────────────────────

    public class CompositeResult {
        public Boolean success;
        public String  id;
        public List<Map<String, Object>> errors = new List<Map<String, Object>>();
    }

    public class OrgIdentity {
        public String  orgId;
        public String  orgType;
        public String  username;
        public String  instanceUrl;
        public Boolean isSandbox;
    }

    public class OrgBridgeException extends Exception {}

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static HttpRequest buildRequest(
            String namedCredential, String path, String method, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCredential + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(DEFAULT_TIMEOUT);
        if (String.isNotBlank(body)) { req.setBody(body); }
        return req;
    }

    private static void assertSuccess(HttpResponse res, Integer expected, String context) {
        if (res.getStatusCode() != expected) {
            throw new OrgBridgeException(
                context + ' failed [' + res.getStatusCode() + ']: ' + res.getBody());
        }
    }

    private static List<CompositeResult> parseCompositeResults(String body) {
        List<CompositeResult> results = new List<CompositeResult>();
        for (Object item : (List<Object>) JSON.deserializeUntyped(body)) {
            Map<String, Object> m = (Map<String, Object>) item;
            CompositeResult cr    = new CompositeResult();
            cr.success = (Boolean) m.get('success');
            cr.id      = (String)  m.get('id');
            if (m.containsKey('errors')) {
                for (Object e : (List<Object>) m.get('errors')) {
                    cr.errors.add((Map<String, Object>) e);
                }
            }
            results.add(cr);
        }
        return results;
    }
}
