/**
 * @description Data Cloud advanced segmentation — segment management API,
 *              waterfall segmentation, activation targets, suppression lists,
 *              and segment analytics patterns.
 *
 *              SEGMENTATION CONCEPTS (interview framework):
 *
 *              Segment
 *                └── Criteria node tree (AND/OR conditions)
 *                      ├── Attribute filter  (DMO field = value)
 *                      ├── Relationship filter (related DMO condition)
 *                      └── Segment filter  (member of another segment)
 *
 *              SEGMENT TYPES:
 *                Standard     — filter criteria on DMO data
 *                Lookalike    — similar profiles to a seed segment (via ad platforms)
 *                Suppression  — profiles to EXCLUDE from activation
 *
 *              WATERFALL SEGMENTATION:
 *                Priority-ordered, mutually exclusive segments.
 *                Profile assigned to highest-priority segment it qualifies for.
 *                Used for tiered offers: Platinum → Gold → Silver → General
 *
 *              SEGMENT REFRESH:
 *                Manual    — triggered on demand
 *                Streaming — near-real-time (requires Streaming Insights)
 *                Scheduled — hourly / daily / weekly
 *                Full      — reprocesses all profiles
 *                Incremental — only evaluates profiles changed since last refresh
 *
 *              ACTIVATION:
 *                Segment → Activation Target → downstream system
 *                Targets: Marketing Cloud, Google Ads, Facebook Ads, S3, SFTP, Webhooks
 *
 *              SEGMENT API:
 *                GET  /api/v1/segments                    — list segments
 *                GET  /api/v1/segments/{id}               — get segment detail
 *                POST /api/v1/segments/{id}/publishjobs   — trigger refresh (publish job)
 *                GET  /api/v1/segments/{id}/publishjobs   — check refresh status
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class DataCloudSegmentService {

    @TestVisible static String DATA_CLOUD_NC = 'DataCloud_Org';
    @TestVisible static HttpCalloutMock calloutMock;

    // ─── Segment retrieval ────────────────────────────────────────────────────

    /**
     * Lists all segments in the Data Cloud org with their metadata.
     *
     * Interview: Segments are authored in Data Cloud → Segments UI or via API.
     * Key fields: Id, Name, Type ('Standard'/'Lookalike'/'Suppression'),
     * Status ('Draft'/'Published'), MemberCount, LastPublishDate.
     *
     * @return  List of SegmentSummary; empty if API unavailable
     */
    public static List<SegmentSummary> listSegments() {
        HttpResponse resp = get('/api/v1/segments');
        if (resp == null || resp.getStatusCode() != 200) {
            return new List<SegmentSummary>();
        }
        return parseSegmentList(resp.getBody());
    }

    /**
     * Returns full detail for a single segment including criteria tree
     * and member count.
     *
     * @param segmentId  Data Cloud segment Id
     * @return           SegmentDetail; null if not found
     */
    public static SegmentDetail getSegmentDetail(String segmentId) {
        if (String.isBlank(segmentId)) { return null; }
        HttpResponse resp = get('/api/v1/segments/' + segmentId);
        if (resp == null || resp.getStatusCode() != 200) { return null; }
        return parseSegmentDetail(resp.getBody());
    }

    // ─── Segment publish (refresh) ────────────────────────────────────────────

    /**
     * Triggers a segment refresh (publish job) — re-evaluates all profiles
     * against the segment criteria and updates SegmentMembership__dlm.
     *
     * Interview: Publish job = the process of evaluating segment membership.
     * Full refresh: recalculates all profiles.
     * Incremental: only evaluates profiles modified since the last publish.
     *
     * Use cases for triggering programmatically:
     *   - After a batch data load (ensure latest data reflected in segment)
     *   - Before an activation to Marketing Cloud (freshen the list first)
     *   - After an Identity Resolution run completes
     *
     * @param segmentId  Segment to refresh
     * @param fullRefresh If true, runs full refresh; false = incremental
     * @return            PublishJobResult with job Id and status
     */
    public static PublishJobResult triggerSegmentRefresh(
            String segmentId, Boolean fullRefresh) {

        if (String.isBlank(segmentId)) {
            return new PublishJobResult(false, null, 'Segment Id is required.');
        }

        Map<String, Object> body = new Map<String, Object>{
            'publishType' => fullRefresh == true ? 'Full' : 'Incremental'
        };

        HttpResponse resp = post(
            '/api/v1/segments/' + segmentId + '/publishjobs',
            JSON.serialize(body)
        );

        if (resp == null) {
            return new PublishJobResult(false, null, 'No response from Data Cloud.');
        }

        Integer code = resp.getStatusCode();
        if (code == 200 || code == 202) {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            String jobId = (String) parsed.get('id');
            return new PublishJobResult(true, jobId, null);
        }
        return new PublishJobResult(false, null,
            'Publish job failed. HTTP ' + code + ': ' + resp.getBody().left(200));
    }

    /**
     * Polls the status of a segment publish job.
     *
     * Interview: Publish jobs are async. Status values:
     *   'Pending'    — queued, not started
     *   'Running'    — evaluation in progress
     *   'Succeeded'  — complete, SegmentMembership__dlm updated
     *   'Failed'     — evaluation error (check error details)
     *   'Cancelled'  — job was cancelled
     *
     * @param segmentId  Segment the job belongs to
     * @param jobId      Publish job Id
     * @return           Job status string; null if not found
     */
    public static String getPublishJobStatus(String segmentId, String jobId) {
        if (String.isBlank(segmentId) || String.isBlank(jobId)) { return null; }
        HttpResponse resp = get('/api/v1/segments/' + segmentId + '/publishjobs/' + jobId);
        if (resp == null || resp.getStatusCode() != 200) { return null; }
        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            return (String) parsed.get('status');
        } catch (Exception e) { return null; }
    }

    // ─── Waterfall segmentation ───────────────────────────────────────────────

    /**
     * Assigns a unified profile to the highest-priority segment it qualifies for
     * (waterfall segmentation pattern).
     *
     * Interview: Waterfall segmentation ensures mutual exclusivity.
     * A customer can be in only ONE tier. The waterfall checks from highest
     * to lowest priority and stops at the first match.
     *
     * Implementation: check SegmentMembership__dlm in priority order via
     * Data Cloud Query API. Return the first matched segment.
     *
     * Common use case: tiered pricing/offers:
     *   Priority 1: Platinum (LTV > $50,000)
     *   Priority 2: Gold    (LTV > $10,000)
     *   Priority 3: Silver  (LTV > $1,000)
     *   Priority 4: General (everyone else)
     *
     * @param unifiedIndividualId  Data Cloud unified profile Id
     * @param prioritisedSegments  List of segment Ids in priority order (highest first)
     * @return                     First matching segment Id; null = no match (General tier)
     */
    public static String assignWaterfallTier(
            String unifiedIndividualId, List<String> prioritisedSegments) {

        if (String.isBlank(unifiedIndividualId)
                || prioritisedSegments == null || prioritisedSegments.isEmpty()) {
            return null;
        }

        // Build IN clause for single-query efficiency
        List<String> quotedIds = new List<String>();
        for (String segId : prioritisedSegments) {
            quotedIds.add('\'' + String.escapeSingleQuotes(segId) + '\'');
        }

        String sql =
            'SELECT SegmentId__c '
            + 'FROM   SegmentMembership__dlm '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + '  AND  SegmentId__c IN (' + String.join(quotedIds, ',') + ')';

        HttpResponse resp = queryApi(sql);
        if (resp == null || resp.getStatusCode() != 200) { return null; }

        Set<String> memberSegments = new Set<String>();
        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> rows = (List<Object>) parsed.get('data');
            for (Object row : rows) {
                Map<String, Object> r = (Map<String, Object>) row;
                memberSegments.add((String) r.get('SegmentId__c'));
            }
        } catch (Exception e) { return null; }

        // Walk in priority order — return first match
        for (String segId : prioritisedSegments) {
            if (memberSegments.contains(segId)) { return segId; }
        }
        return null; // Not in any priority segment
    }

    // ─── Suppression lists ────────────────────────────────────────────────────

    /**
     * Checks if a profile is on a suppression list — should be excluded from
     * activations (e.g. unsubscribed, opted out, legally suppressed).
     *
     * Interview: Suppression segments are special-type segments that mark
     * profiles to exclude from downstream activations.
     * Examples: global unsubscribe list, GDPR opted-out, churned customers.
     *
     * During activation setup, suppression segments are specified as
     * "suppress by" — Data Cloud automatically excludes their members.
     *
     * This method provides an Apex-side check for real-time decisioning.
     *
     * @param unifiedIndividualId  Profile to check
     * @param suppressionSegmentIds  List of suppression segment Ids
     * @return true if the profile is on ANY of the suppression lists
     */
    public static Boolean isOnSuppressionList(
            String unifiedIndividualId, List<String> suppressionSegmentIds) {

        if (String.isBlank(unifiedIndividualId)
                || suppressionSegmentIds == null || suppressionSegmentIds.isEmpty()) {
            return false;
        }

        List<String> quotedIds = new List<String>();
        for (String segId : suppressionSegmentIds) {
            quotedIds.add('\'' + String.escapeSingleQuotes(segId) + '\'');
        }

        String sql =
            'SELECT SegmentId__c '
            + 'FROM   SegmentMembership__dlm '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + '  AND  SegmentId__c IN (' + String.join(quotedIds, ',') + ') '
            + 'LIMIT  1';

        HttpResponse resp = queryApi(sql);
        if (resp == null || resp.getStatusCode() != 200) { return false; }

        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> rows = (List<Object>) parsed.get('data');
            return !rows.isEmpty();
        } catch (Exception e) { return false; }
    }

    // ─── Segment analytics ────────────────────────────────────────────────────

    /**
     * Returns segment membership counts for a set of segments — for building
     * audience size reports in Salesforce CRM dashboards.
     *
     * Interview: Segment size is visible in Data Cloud UI (member count badge).
     * For CRM-side reporting, query SegmentMembership__dlm with GROUP BY
     * equivalent (use COUNT in Calculated Insights or Apex aggregation).
     *
     * @param segmentIds  Segments to count membership for
     * @return            Map of segmentId → member count
     */
    public static Map<String, Integer> getSegmentMemberCounts(List<String> segmentIds) {
        Map<String, Integer> counts = new Map<String, Integer>();
        if (segmentIds == null || segmentIds.isEmpty()) { return counts; }

        // Initialise all to 0
        for (String segId : segmentIds) { counts.put(segId, 0); }

        List<String> quotedIds = new List<String>();
        for (String segId : segmentIds) {
            quotedIds.add('\'' + String.escapeSingleQuotes(segId) + '\'');
        }

        // Note: Data Cloud Query API supports COUNT in Calculated Insights.
        // For direct membership count, fetch records and count in Apex.
        String sql =
            'SELECT SegmentId__c '
            + 'FROM   SegmentMembership__dlm '
            + 'WHERE  SegmentId__c IN (' + String.join(quotedIds, ',') + ') '
            + 'LIMIT  10000';

        HttpResponse resp = queryApi(sql);
        if (resp == null || resp.getStatusCode() != 200) { return counts; }

        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> rows = (List<Object>) parsed.get('data');
            for (Object row : rows) {
                String segId = (String) ((Map<String, Object>) row).get('SegmentId__c');
                if (counts.containsKey(segId)) {
                    counts.put(segId, counts.get(segId) + 1);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Segment count error: ' + e.getMessage());
        }
        return counts;
    }

    // ─── Activation management ────────────────────────────────────────────────

    /**
     * Returns the activation targets configured for a segment.
     *
     * Interview: Activation = publishing segment member list to a downstream system.
     * Activation targets: Marketing Cloud (SF MC), Google Ads, Facebook Ads,
     *   S3/SFTP (file export), Webhook (HTTP POST to external endpoint).
     *
     * Activation fields:
     *   ActivationId     — unique activation Id
     *   TargetType       — 'MarketingCloud' | 'GoogleAds' | 'FacebookAds' | 'Webhook'
     *   Status           — 'Active' | 'Inactive' | 'Error'
     *   LastActivation   — DateTime of last successful activation
     *   RecordCount      — members sent in last activation
     *
     * @param segmentId  Segment to get activations for
     * @return           List of ActivationTarget summaries
     */
    public static List<ActivationTarget> getActivationTargets(String segmentId) {
        if (String.isBlank(segmentId)) { return new List<ActivationTarget>(); }

        HttpResponse resp = get('/api/v1/segments/' + segmentId + '/activations');
        if (resp == null || resp.getStatusCode() != 200) {
            return new List<ActivationTarget>();
        }
        return parseActivationTargets(resp.getBody());
    }

    /**
     * Triggers an activation run for a segment to a specific target.
     *
     * Interview: Activation run = taking current segment members and publishing
     * them to the downstream target system. In Marketing Cloud, this creates/updates
     * a Subscriber List or Journey entry event source.
     *
     * @param segmentId    Segment to activate
     * @param activationId Activation target configuration Id
     * @return             true if activation was successfully triggered
     */
    public static Boolean triggerActivation(String segmentId, String activationId) {
        if (String.isBlank(segmentId) || String.isBlank(activationId)) { return false; }

        HttpResponse resp = post(
            '/api/v1/segments/' + segmentId + '/activations/' + activationId + '/runs',
            '{}'
        );
        return resp != null && (resp.getStatusCode() == 200 || resp.getStatusCode() == 202);
    }

    // ─── HTTP helpers ─────────────────────────────────────────────────────────

    @TestVisible
    static HttpResponse get(String path) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + DATA_CLOUD_NC + path);
            req.setMethod('GET');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(30000);
            Http http = new Http();
            return (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req) : http.send(req);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DC GET failed [' + path + ']: ' + e.getMessage());
            return null;
        }
    }

    @TestVisible
    static HttpResponse post(String path, String body) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + DATA_CLOUD_NC + path);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setBody(body);
            req.setTimeout(30000);
            Http http = new Http();
            return (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req) : http.send(req);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DC POST failed [' + path + ']: ' + e.getMessage());
            return null;
        }
    }

    @TestVisible
    static HttpResponse queryApi(String sql) {
        return post('/api/v1/query', JSON.serialize(new Map<String, Object>{ 'sql' => sql }));
    }

    // ─── Response parsers ─────────────────────────────────────────────────────

    @TestVisible
    static List<SegmentSummary> parseSegmentList(String responseBody) {
        List<SegmentSummary> results = new List<SegmentSummary>();
        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object> segments = (List<Object>) parsed.get('segments');
            if (segments == null) { return results; }
            for (Object seg : segments) {
                Map<String, Object> s = (Map<String, Object>) seg;
                SegmentSummary ss = new SegmentSummary();
                ss.segmentId    = (String)  s.get('id');
                ss.name         = (String)  s.get('name');
                ss.segmentType  = (String)  s.get('type');
                ss.status       = (String)  s.get('status');
                ss.memberCount  = s.get('memberCount') != null
                    ? (Integer) s.get('memberCount') : 0;
                results.add(ss);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Segment list parse error: ' + e.getMessage());
        }
        return results;
    }

    @TestVisible
    static SegmentDetail parseSegmentDetail(String responseBody) {
        try {
            Map<String, Object> s =
                (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            SegmentDetail d = new SegmentDetail();
            d.segmentId    = (String)  s.get('id');
            d.name         = (String)  s.get('name');
            d.segmentType  = (String)  s.get('type');
            d.status       = (String)  s.get('status');
            d.memberCount  = s.get('memberCount') != null ? (Integer) s.get('memberCount') : 0;
            d.description  = (String)  s.get('description');
            d.refreshType  = (String)  s.get('refreshScheduleFrequency');
            return d;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Segment detail parse error: ' + e.getMessage());
            return null;
        }
    }

    @TestVisible
    static List<ActivationTarget> parseActivationTargets(String responseBody) {
        List<ActivationTarget> results = new List<ActivationTarget>();
        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object> activations = (List<Object>) parsed.get('activations');
            if (activations == null) { return results; }
            for (Object act : activations) {
                Map<String, Object> a = (Map<String, Object>) act;
                ActivationTarget at = new ActivationTarget();
                at.activationId  = (String) a.get('id');
                at.targetType    = (String) a.get('targetType');
                at.status        = (String) a.get('status');
                at.recordCount   = a.get('recordCount') != null
                    ? (Integer) a.get('recordCount') : 0;
                results.add(at);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Activation parse error: ' + e.getMessage());
        }
        return results;
    }

    // ─── Result types ──────────────────────────────────────────────────────────

    public class SegmentSummary {
        public String  segmentId;
        public String  name;
        public String  segmentType;   // 'Standard' | 'Lookalike' | 'Suppression'
        public String  status;        // 'Draft' | 'Published'
        public Integer memberCount;
    }

    public class SegmentDetail {
        public String  segmentId;
        public String  name;
        public String  segmentType;
        public String  status;
        public Integer memberCount;
        public String  description;
        public String  refreshType;   // 'Manual' | 'Streaming' | 'Hourly' | 'Daily'
    }

    public class PublishJobResult {
        public Boolean isSuccess;
        public String  jobId;
        public String  errorMessage;

        public PublishJobResult(Boolean success, String jobId, String error) {
            this.isSuccess    = success;
            this.jobId        = jobId;
            this.errorMessage = error;
        }
    }

    public class ActivationTarget {
        public String  activationId;
        public String  targetType;    // 'MarketingCloud' | 'GoogleAds' | 'Webhook'
        public String  status;        // 'Active' | 'Inactive' | 'Error'
        public Integer recordCount;
    }
}
