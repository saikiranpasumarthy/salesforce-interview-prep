/**
 * @description Salesforce Data Cloud — Unified Profiles, Identity Resolution,
 *              Data Model Objects (DMO) query API, Calculated Insights, and
 *              Segment membership patterns.
 *
 *              UNIFIED PROFILE MODEL (interview framework):
 *
 *              Multiple source records (CRM Contact, MC Subscriber, Web visitor...)
 *                         ↓
 *              Identity Resolution (matching + reconciliation rules)
 *                ├── Match Rule: EmailAddress exact match
 *                ├── Match Rule: Phone exact match
 *                ├── Match Rule: Name + Postal code fuzzy match
 *                └── Reconciliation Rule: most-recent-wins for conflicting fields
 *                         ↓
 *              Unified Individual (UnifiedIndividual__dlm)
 *                ├── UnifiedIndividualId__c    — synthetic key (not a Salesforce Id)
 *                ├── FirstName__c, LastName__c — reconciled from sources
 *                ├── ContactPointEmail__dlm    — linked email addresses
 *                ├── ContactPointPhone__dlm    — linked phone numbers
 *                └── Party Identification      — links back to source record Ids
 *
 *              DATA CLOUD QUERY API:
 *                Endpoint: POST /api/v1/query
 *                Body:     { "sql": "SELECT ... FROM DMO__dlm WHERE ..." }
 *                Returns:  { "data": [...], "totalSize": N, "nextBatchId": "..." }
 *
 *              KEY DMO OBJECTS (interview vocabulary):
 *                UnifiedIndividual__dlm     — merged unified profile
 *                Individual__dlm            — source individual records
 *                ContactPointEmail__dlm     — email contact points
 *                ContactPointPhone__dlm     — phone contact points
 *                SalesOrder__dlm            — purchase/order data
 *                UnifiedLinkContactPoint__dlm — junction: unified ↔ contact points
 *                PartyIdentification__dlm   — source system record linkage
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class DataCloudProfileService {

    @TestVisible static String DATA_CLOUD_NC = 'DataCloud_Org';
    @TestVisible static HttpCalloutMock calloutMock;

    // ─── Unified Profile lookup ────────────────────────────────────────────────

    /**
     * Looks up a Unified Individual profile by email address via Data Cloud Query API.
     *
     * Interview: The Query API uses a SQL-like dialect (ANSI SQL subset).
     * DMO tables end in __dlm suffix. Field names end in __c.
     * Queries are case-sensitive. JOINs between DMOs are supported.
     *
     * SQL dialect notes:
     *   - No subqueries in FROM clause
     *   - LIMIT and OFFSET supported for pagination
     *   - No GROUP BY in initial release (use Calculated Insights for aggregations)
     *   - Date functions: DATE(), TIMESTAMP()
     *   - LIKE operator supported for pattern matching
     *
     * @param emailAddress  Email to search unified profiles for
     * @return              UnifiedProfileResult; null if not found
     */
    public static UnifiedProfileResult lookupByEmail(String emailAddress) {
        if (String.isBlank(emailAddress)) { return null; }

        // Query joins UnifiedIndividual to ContactPointEmail via link table
        String sql =
            'SELECT ui.UnifiedIndividualId__c, ui.FirstName__c, ui.LastName__c, '
            + '       cpe.EmailAddress__c, cpe.IsPrimary__c '
            + 'FROM   UnifiedIndividual__dlm ui '
            + 'JOIN   UnifiedLinkContactPoint__dlm link '
            + '         ON ui.UnifiedIndividualId__c = link.UnifiedIndividualId__c '
            + 'JOIN   ContactPointEmail__dlm cpe '
            + '         ON link.ContactPointId__c = cpe.ContactPointId__c '
            + 'WHERE  cpe.EmailAddress__c = \'' + String.escapeSingleQuotes(emailAddress) + '\' '
            + 'LIMIT  1';

        QueryApiResponse response = executeQuery(sql);
        if (response == null || response.data.isEmpty()) { return null; }

        return parseUnifiedProfile(response.data[0]);
    }

    /**
     * Looks up a Unified Individual by CRM Contact Id (Party Identification).
     *
     * Interview: Party Identification is the bridge between Data Cloud unified profiles
     * and source system record Ids (e.g. Salesforce Contact Id, Marketo Lead Id).
     * PartyIdentification__dlm stores: UnifiedIndividualId__c, IdentityType__c ('ContactId'),
     * PartyIdentificationNumber__c (the CRM Id), SourceSystem__c.
     *
     * @param contactId  Salesforce Contact Id
     * @return           UnifiedProfileResult; null if not found
     */
    public static UnifiedProfileResult lookupByCrmContactId(Id contactId) {
        if (contactId == null) { return null; }

        String sql =
            'SELECT ui.UnifiedIndividualId__c, ui.FirstName__c, ui.LastName__c '
            + 'FROM   UnifiedIndividual__dlm ui '
            + 'JOIN   PartyIdentification__dlm pid '
            + '         ON ui.UnifiedIndividualId__c = pid.UnifiedIndividualId__c '
            + 'WHERE  pid.IdentityType__c = \'ContactId\' '
            + '  AND  pid.PartyIdentificationNumber__c = \''
            + String.escapeSingleQuotes(String.valueOf(contactId)) + '\' '
            + 'LIMIT  1';

        QueryApiResponse response = executeQuery(sql);
        if (response == null || response.data.isEmpty()) { return null; }

        return parseUnifiedProfile(response.data[0]);
    }

    /**
     * Returns all email and phone contact points for a Unified Individual.
     *
     * Interview: A single Unified Individual may have multiple email addresses
     * (from different source systems). ContactPointEmail__dlm and
     * ContactPointPhone__dlm hold all known contact points.
     * IsPrimary__c = true marks the reconciled "best" contact point.
     *
     * @param unifiedIndividualId  Data Cloud unified individual Id
     * @return                     ContactPoints wrapper
     */
    public static ContactPoints getContactPoints(String unifiedIndividualId) {
        ContactPoints result = new ContactPoints();
        if (String.isBlank(unifiedIndividualId)) { return result; }

        // Email contact points
        String emailSql =
            'SELECT cpe.EmailAddress__c, cpe.IsPrimary__c, cpe.EmailDomain__c '
            + 'FROM   ContactPointEmail__dlm cpe '
            + 'JOIN   UnifiedLinkContactPoint__dlm link '
            + '         ON cpe.ContactPointId__c = link.ContactPointId__c '
            + 'WHERE  link.UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + 'ORDER BY cpe.IsPrimary__c DESC';

        QueryApiResponse emailResp = executeQuery(emailSql);
        if (emailResp != null) {
            for (Map<String, Object> row : emailResp.data) {
                ContactPointEmail cpe = new ContactPointEmail();
                cpe.emailAddress = (String) row.get('EmailAddress__c');
                cpe.isPrimary    = row.get('IsPrimary__c') == true;
                cpe.emailDomain  = (String) row.get('EmailDomain__c');
                result.emails.add(cpe);
            }
        }

        // Phone contact points
        String phoneSql =
            'SELECT cpp.FormattedNationalPhoneNumber__c, cpp.IsPrimary__c, cpp.PhoneType__c '
            + 'FROM   ContactPointPhone__dlm cpp '
            + 'JOIN   UnifiedLinkContactPoint__dlm link '
            + '         ON cpp.ContactPointId__c = link.ContactPointId__c '
            + 'WHERE  link.UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + 'ORDER BY cpp.IsPrimary__c DESC';

        QueryApiResponse phoneResp = executeQuery(phoneSql);
        if (phoneResp != null) {
            for (Map<String, Object> row : phoneResp.data) {
                ContactPointPhone cpp = new ContactPointPhone();
                cpp.phoneNumber = (String) row.get('FormattedNationalPhoneNumber__c');
                cpp.isPrimary   = row.get('IsPrimary__c') == true;
                cpp.phoneType   = (String) row.get('PhoneType__c');
                result.phones.add(cpp);
            }
        }

        return result;
    }

    // ─── Calculated Insights ──────────────────────────────────────────────────

    /**
     * Retrieves Calculated Insight metrics for a Unified Individual.
     *
     * Interview: Calculated Insights are batch-computed aggregations stored
     * as metrics on Data Model Objects. They run on a schedule (hourly/daily).
     * Examples:
     *   - Lifetime Value (total spend across all orders)
     *   - 30-day Engagement Score (sum of engagement events)
     *   - Churn Risk Score (ML model output stored as a metric)
     *   - Purchase Frequency (orders per quarter)
     *
     * Calculated Insights are stored in a custom DMO created per insight.
     * DMO naming: {InsightApiName}__dlm (e.g. LifetimeValue__dlm)
     *
     * @param unifiedIndividualId  Data Cloud unified Id
     * @param insightApiName       DMO API name for the insight (without __dlm)
     * @return                     Map of metric field names to values
     */
    public static Map<String, Object> getCalculatedInsight(
            String unifiedIndividualId, String insightApiName) {

        if (String.isBlank(unifiedIndividualId) || String.isBlank(insightApiName)) {
            return new Map<String, Object>();
        }

        String dmoName = insightApiName.endsWith('__dlm')
            ? insightApiName : insightApiName + '__dlm';

        String sql =
            'SELECT * '
            + 'FROM   ' + dmoName + ' '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + 'LIMIT  1';

        QueryApiResponse response = executeQuery(sql);
        if (response == null || response.data.isEmpty()) {
            return new Map<String, Object>();
        }
        return response.data[0];
    }

    /**
     * Returns a batch of Lifetime Value insights — demonstrates paginated
     * Data Cloud Query API results.
     *
     * Interview: Data Cloud Query API returns a max of 10,000 rows per request.
     * For larger result sets: use `nextBatchId` from the response to paginate.
     * GET /api/v1/query/{nextBatchId} to fetch the next page.
     *
     * @param minimumLifetimeValue  Filter: only return profiles above this LTV
     * @param pageSize              Records per page (max 10,000)
     * @return                      Paginated LifetimeValue result
     */
    public static PaginatedInsightResult getHighValueProfiles(
            Decimal minimumLifetimeValue, Integer pageSize) {

        Integer size = pageSize != null ? Math.min(pageSize, 10000) : 100;
        Decimal minLtv = minimumLifetimeValue != null ? minimumLifetimeValue : 0;

        String sql =
            'SELECT UnifiedIndividualId__c, TotalLifetimeValue__c, '
            + '       PurchaseCount__c, LastPurchaseDate__c '
            + 'FROM   LifetimeValue__dlm '
            + 'WHERE  TotalLifetimeValue__c >= ' + minLtv + ' '
            + 'ORDER BY TotalLifetimeValue__c DESC '
            + 'LIMIT  ' + size;

        QueryApiResponse response = executeQuery(sql);
        PaginatedInsightResult result = new PaginatedInsightResult();

        if (response != null) {
            result.records     = response.data;
            result.totalSize   = response.totalSize;
            result.nextBatchId = response.nextBatchId;
            result.hasMore     = String.isNotBlank(response.nextBatchId);
        }
        return result;
    }

    // ─── Segment membership ───────────────────────────────────────────────────

    /**
     * Checks whether a Unified Individual is a member of a Data Cloud Segment.
     *
     * Interview: Segments are filter criteria applied to DMO data.
     * Segment activation publishes member lists to downstream systems (MC, Advertising, etc.).
     * Segment members are stored in SegmentMembership__dlm after each segment refresh.
     *
     * Segment refresh: manual or scheduled (hourly / daily).
     * SegmentMembership__dlm fields:
     *   UnifiedIndividualId__c  — profile in the segment
     *   SegmentId__c            — segment record Id
     *   MembershipDate__c       — when the profile joined the segment
     *
     * @param unifiedIndividualId  Data Cloud unified Id
     * @param segmentId            Segment record Id
     * @return                     true if the profile is in the segment
     */
    public static Boolean isInSegment(String unifiedIndividualId, String segmentId) {
        if (String.isBlank(unifiedIndividualId) || String.isBlank(segmentId)) {
            return false;
        }

        String sql =
            'SELECT UnifiedIndividualId__c '
            + 'FROM   SegmentMembership__dlm '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + '  AND  SegmentId__c = \''
            + String.escapeSingleQuotes(segmentId) + '\' '
            + 'LIMIT  1';

        QueryApiResponse response = executeQuery(sql);
        return response != null && !response.data.isEmpty();
    }

    /**
     * Returns all Segments a Unified Individual belongs to.
     *
     * @param unifiedIndividualId  Data Cloud unified Id
     * @return                     List of segment Ids the profile is in
     */
    public static List<String> getMemberSegments(String unifiedIndividualId) {
        if (String.isBlank(unifiedIndividualId)) { return new List<String>(); }

        String sql =
            'SELECT SegmentId__c, MembershipDate__c '
            + 'FROM   SegmentMembership__dlm '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + 'ORDER BY MembershipDate__c DESC';

        QueryApiResponse response = executeQuery(sql);
        List<String> segmentIds = new List<String>();
        if (response != null) {
            for (Map<String, Object> row : response.data) {
                String segId = (String) row.get('SegmentId__c');
                if (String.isNotBlank(segId)) { segmentIds.add(segId); }
            }
        }
        return segmentIds;
    }

    // ─── Purchase history ─────────────────────────────────────────────────────

    /**
     * Returns order history for a Unified Individual from Data Cloud.
     *
     * Interview: SalesOrder__dlm is a standard Data Cloud DMO for purchase data.
     * It can be populated from:
     *   - Salesforce Order records (via CRM Connector)
     *   - Commerce Cloud orders (via Commerce Connector)
     *   - Custom ingestion (CSV/API)
     *
     * @param unifiedIndividualId  Data Cloud unified Id
     * @param lookbackDays         Days of history to retrieve
     * @return                     List of order records
     */
    public static List<Map<String, Object>> getPurchaseHistory(
            String unifiedIndividualId, Integer lookbackDays) {

        if (String.isBlank(unifiedIndividualId)) { return new List<Map<String, Object>>(); }
        Integer days = lookbackDays != null ? lookbackDays : 365;

        String sql =
            'SELECT SalesOrderId__c, OrderedDate__c, GrandTotalAmount__c, '
            + '       Status__c, ChannelType__c '
            + 'FROM   SalesOrder__dlm '
            + 'WHERE  UnifiedIndividualId__c = \''
            + String.escapeSingleQuotes(unifiedIndividualId) + '\' '
            + '  AND  OrderedDate__c >= DATE_ADD(TODAY(), -' + days + ') '
            + 'ORDER BY OrderedDate__c DESC '
            + 'LIMIT  50';

        QueryApiResponse response = executeQuery(sql);
        return response != null ? response.data : new List<Map<String, Object>>();
    }

    // ─── Core Query API HTTP client ───────────────────────────────────────────

    /**
     * Executes a Data Cloud SQL query via the Query API.
     *
     * Response structure:
     * {
     *   "data":        [ { "FieldName__c": value, ... }, ... ],
     *   "totalSize":   N,
     *   "nextBatchId": "abc123" or null (null = last page)
     * }
     *
     * @param sql  ANSI SQL query against Data Cloud DMOs
     * @return     QueryApiResponse; null on error
     */
    @TestVisible
    static QueryApiResponse executeQuery(String sql) {
        try {
            Map<String, Object> reqBody = new Map<String, Object>{ 'sql' => sql };

            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + DATA_CLOUD_NC + '/api/v1/query');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setBody(JSON.serialize(reqBody));
            req.setTimeout(30000);

            Http http = new Http();
            HttpResponse resp = (calloutMock != null && Test.isRunningTest())
                ? calloutMock.respond(req)
                : http.send(req);

            if (resp.getStatusCode() != 200) {
                System.debug(LoggingLevel.WARN,
                    'Data Cloud Query API returned: ' + resp.getStatusCode()
                    + ' — ' + resp.getBody());
                return null;
            }

            return parseQueryResponse(resp.getBody());

        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Data Cloud Query failed: ' + e.getMessage());
            return null;
        }
    }

    // ─── Response parsers ─────────────────────────────────────────────────────

    @TestVisible
    static QueryApiResponse parseQueryResponse(String json) {
        QueryApiResponse result = new QueryApiResponse();
        try {
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(json);

            if (parsed.containsKey('data')) {
                List<Object> rows = (List<Object>) parsed.get('data');
                for (Object row : rows) {
                    result.data.add((Map<String, Object>) row);
                }
            }
            if (parsed.containsKey('totalSize')) {
                result.totalSize = (Integer) parsed.get('totalSize');
            }
            if (parsed.containsKey('nextBatchId')) {
                result.nextBatchId = (String) parsed.get('nextBatchId');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Query response parse error: ' + e.getMessage());
        }
        return result;
    }

    @TestVisible
    static UnifiedProfileResult parseUnifiedProfile(Map<String, Object> row) {
        UnifiedProfileResult p = new UnifiedProfileResult();
        p.unifiedIndividualId = (String) row.get('UnifiedIndividualId__c');
        p.firstName           = (String) row.get('FirstName__c');
        p.lastName            = (String) row.get('LastName__c');
        p.primaryEmail        = (String) row.get('EmailAddress__c');
        return p;
    }

    // ─── Result / DTO types ───────────────────────────────────────────────────

    public class UnifiedProfileResult {
        public String unifiedIndividualId;
        public String firstName;
        public String lastName;
        public String primaryEmail;
        public String primaryPhone;

        public String fullName() {
            List<String> parts = new List<String>();
            if (String.isNotBlank(firstName)) { parts.add(firstName); }
            if (String.isNotBlank(lastName))  { parts.add(lastName); }
            return parts.isEmpty() ? 'Unknown' : String.join(parts, ' ');
        }
    }

    public class ContactPoints {
        public List<ContactPointEmail> emails = new List<ContactPointEmail>();
        public List<ContactPointPhone> phones = new List<ContactPointPhone>();

        public String getPrimaryEmail() {
            for (ContactPointEmail e : emails) { if (e.isPrimary) { return e.emailAddress; } }
            return emails.isEmpty() ? null : emails[0].emailAddress;
        }
        public String getPrimaryPhone() {
            for (ContactPointPhone p : phones) { if (p.isPrimary) { return p.phoneNumber; } }
            return phones.isEmpty() ? null : phones[0].phoneNumber;
        }
    }

    public class ContactPointEmail {
        public String  emailAddress;
        public Boolean isPrimary;
        public String  emailDomain;
    }

    public class ContactPointPhone {
        public String  phoneNumber;
        public Boolean isPrimary;
        public String  phoneType;  // 'Mobile' | 'Home' | 'Work'
    }

    public class PaginatedInsightResult {
        public List<Map<String, Object>> records     = new List<Map<String, Object>>();
        public Integer                   totalSize   = 0;
        public String                    nextBatchId;
        public Boolean                   hasMore     = false;
    }

    // Internal query API response wrapper
    @TestVisible
    class QueryApiResponse {
        List<Map<String, Object>> data        = new List<Map<String, Object>>();
        Integer                   totalSize   = 0;
        String                    nextBatchId;
    }
}
