/**
 * MetadataApiService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 21 — Metadata API & Tooling API: reading org metadata programmatically
 * from within Apex using HTTP callouts to the REST-based Metadata API and
 * Tooling API endpoints.
 *
 * TWO METADATA APIS:
 * ═══════════════════
 * 1. Metadata API  (/services/data/vXX.0/metadata/*)
 *    - CRUD on metadata containers (CustomObject, ApexClass, Flow, etc.)
 *    - Async operations: deploy(), retrieve(), checkDeployStatus()
 *    - Used by sf CLI, Workbench, ANT Migration Tool under the hood
 *    - SOAP-based (WSDL) OR REST-based in newer API versions
 *
 * 2. Tooling API  (/services/data/vXX.0/tooling/*)
 *    - Exposes developer-focused sObjects: ApexClass, ApexTrigger,
 *      ApexTestResult, ApexCodeCoverage, FlowDefinition, CustomField, etc.
 *    - Query via SOQL: /tooling/query?q=SELECT+...
 *    - CRUD on individual metadata components (create class, run test)
 *    - Returns richer developer metadata than standard SOQL
 *
 * APEX CALLOUT APPROACH:
 * ═══════════════════════
 * Both APIs are accessible from Apex via callouts using the session ID
 * (UserInfo.getSessionId()) as the Bearer token. This requires:
 *   1. The org is NOT a scratch org (scratch orgs block session-based callouts)
 *   2. The running user has API Enabled permission
 *   3. The endpoint is whitelisted in Remote Site Settings or Named Credential
 *
 * ALTERNATIVE: sf CLI from pipelines
 *   sf org list metadata --metadata-type ApexClass --target-org my-org
 *   sf org list metadata-types --target-org my-org
 */
public with sharing class MetadataApiService {

    private static final String API_VERSION = '62.0';
    // Use Named Credential 'Salesforce_Org_Self' pointing to the org's base URL
    // OR use UserInfo.getOrganizationId() to build endpoint dynamically
    private static final String BASE_URL =
        URL.getOrgDomainUrl().toExternalForm();

    // ─────────────────────────────────────────────────────────────────────────
    // Inner types
    // ─────────────────────────────────────────────────────────────────────────

    public class ApexClassInfo {
        public String  id;
        public String  name;
        public String  apiVersion;
        public String  status;        // Active | Inactive
        public Boolean isValid;
        public Integer lengthWithoutComments;
        public String  createdDate;
        public String  lastModifiedDate;
        public String  lastModifiedByName;
        public String  namespacePrefix;

        public Boolean isTestClass() {
            // Heuristic — Tooling API Body field can be inspected for @IsTest
            return name != null && name.endsWithIgnoreCase('Test');
        }
    }

    public class CodeCoverageInfo {
        public String  apexClassOrTriggerId;
        public String  apexClassOrTriggerName;
        public Integer numLinesCovered;
        public Integer numLinesUncovered;
        public Decimal coveragePct {
            get {
                Integer total = (numLinesCovered  != null ? numLinesCovered  : 0)
                              + (numLinesUncovered != null ? numLinesUncovered : 0);
                if (total == 0) { return 0; }
                return ((Decimal) numLinesCovered / total * 100).setScale(1);
            }
        }
    }

    public class TestResultInfo {
        public String  id;
        public String  apexClassName;
        public String  methodName;
        public String  outcome;      // Pass | Fail | CompileFail | Skip
        public Integer runTime;      // ms
        public String  message;      // failure message (null on pass)
        public String  stackTrace;
    }

    public class DeployStatusInfo {
        public String  id;
        public Boolean done;
        public Boolean success;
        public String  status;       // Pending | InProgress | Succeeded | Failed | Canceled
        public Integer numberComponentsDeployed;
        public Integer numberComponentsTotal;
        public Integer numberTestsCompleted;
        public Integer numberTestErrors;
        public List<String> componentFailures;
    }

    public class ToolingApiException extends Exception {
        public Integer statusCode;
        public String  errorBody;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tooling API — Apex Classes
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Lists all active Apex classes in the org via Tooling API SOQL.
     *
     * Why Tooling API over standard SOQL?
     *  • Tooling API ApexClass includes Body (source code), SymbolTable
     *    (variables, methods, inner types), and FullName.
     *  • Standard SOQL ApexClass does NOT expose Body.
     *  • For CI/CD tools that need source: Tooling API is required.
     */
    public static List<ApexClassInfo> listApexClasses() {
        String query =
            'SELECT+Id,Name,ApiVersion,Status,IsValid,LengthWithoutComments,'
            + 'CreatedDate,LastModifiedDate,LastModifiedBy.Name,NamespacePrefix'
            + '+FROM+ApexClass'
            + '+WHERE+Status+=+\'Active\''
            + '+AND+NamespacePrefix+=+null'
            + '+ORDER+BY+Name'
            + '+LIMIT+500';

        Map<String, Object> response = toolingQuery(query);
        List<ApexClassInfo> result = new List<ApexClassInfo>();

        List<Object> records = (List<Object>) response.get('records');
        if (records == null) { return result; }

        for (Object rec : records) {
            Map<String, Object> r = (Map<String, Object>) rec;
            ApexClassInfo info = new ApexClassInfo();
            info.id                   = (String)  r.get('Id');
            info.name                 = (String)  r.get('Name');
            info.status               = (String)  r.get('Status');
            info.isValid              = r.get('IsValid') == true;
            info.lengthWithoutComments = r.get('LengthWithoutComments') != null
                ? Integer.valueOf(String.valueOf(r.get('LengthWithoutComments'))) : 0;
            info.createdDate          = String.valueOf(r.get('CreatedDate'));
            info.lastModifiedDate     = String.valueOf(r.get('LastModifiedDate'));
            info.namespacePrefix      = (String)  r.get('NamespacePrefix');

            Map<String, Object> lastModBy = (Map<String, Object>) r.get('LastModifiedBy');
            if (lastModBy != null) {
                info.lastModifiedByName = (String) lastModBy.get('Name');
            }
            result.add(info);
        }
        return result;
    }

    /**
     * Returns the source body of a single Apex class.
     * Only available via Tooling API — not via standard SOQL.
     */
    public static String getApexClassBody(String classId) {
        String query = 'SELECT+Id,Name,Body+FROM+ApexClass+WHERE+Id+=+\'' + classId + '\'';
        Map<String, Object> response = toolingQuery(query);
        List<Object> records = (List<Object>) response.get('records');
        if (records == null || records.isEmpty()) { return null; }
        Map<String, Object> r = (Map<String, Object>) records[0];
        return (String) r.get('Body');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tooling API — Code Coverage
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns aggregate code coverage for all Apex classes/triggers.
     *
     * ApexCodeCoverageAggregate is a Tooling API sObject that aggregates
     * coverage across all test runs. It is updated each time tests are run.
     *
     * Key sObjects:
     *   ApexCodeCoverage           — per test class → per covered class
     *   ApexCodeCoverageAggregate  — aggregated across all test runs (preferred)
     */
    public static List<CodeCoverageInfo> getCodeCoverageAggregate() {
        String query =
            'SELECT+ApexClassOrTriggerId,ApexClassOrTrigger.Name,'
            + 'NumLinesCovered,NumLinesUncovered'
            + '+FROM+ApexCodeCoverageAggregate'
            + '+ORDER+BY+ApexClassOrTrigger.Name';

        Map<String, Object> response = toolingQuery(query);
        List<CodeCoverageInfo> result = new List<CodeCoverageInfo>();

        List<Object> records = (List<Object>) response.get('records');
        if (records == null) { return result; }

        for (Object rec : records) {
            Map<String, Object> r = (Map<String, Object>) rec;
            CodeCoverageInfo info  = new CodeCoverageInfo();
            info.apexClassOrTriggerId   = (String) r.get('ApexClassOrTriggerId');
            info.numLinesCovered        = r.get('NumLinesCovered')   != null
                ? Integer.valueOf(String.valueOf(r.get('NumLinesCovered')))   : 0;
            info.numLinesUncovered      = r.get('NumLinesUncovered') != null
                ? Integer.valueOf(String.valueOf(r.get('NumLinesUncovered'))) : 0;

            Map<String, Object> classOrTrigger =
                (Map<String, Object>) r.get('ApexClassOrTrigger');
            if (classOrTrigger != null) {
                info.apexClassOrTriggerName = (String) classOrTrigger.get('Name');
            }
            result.add(info);
        }
        return result;
    }

    /**
     * Returns classes below the 75% coverage threshold.
     */
    public static List<CodeCoverageInfo> getUndercoveredClasses(Decimal threshold) {
        List<CodeCoverageInfo> all = getCodeCoverageAggregate();
        List<CodeCoverageInfo> under = new List<CodeCoverageInfo>();
        for (CodeCoverageInfo c : all) {
            if (c.coveragePct < threshold) { under.add(c); }
        }
        return under;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tooling API — Test Results
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns the most recent test results for a given class name.
     * ApexTestResult stores individual test method outcomes.
     */
    public static List<TestResultInfo> getLatestTestResults(String apexClassName) {
        String query =
            'SELECT+Id,ApexClass.Name,MethodName,Outcome,RunTime,Message,StackTrace'
            + '+FROM+ApexTestResult'
            + '+WHERE+ApexClass.Name+=+\'' + String.escapeSingleQuotes(apexClassName) + '\''
            + '+ORDER+BY+TestTimestamp+DESC'
            + '+LIMIT+200';

        Map<String, Object> response = toolingQuery(query);
        List<TestResultInfo> result = new List<TestResultInfo>();

        List<Object> records = (List<Object>) response.get('records');
        if (records == null) { return result; }

        for (Object rec : records) {
            Map<String, Object> r = (Map<String, Object>) rec;
            TestResultInfo info  = new TestResultInfo();
            info.id              = (String) r.get('Id');
            info.methodName      = (String) r.get('MethodName');
            info.outcome         = (String) r.get('Outcome');
            info.message         = (String) r.get('Message');
            info.stackTrace      = (String) r.get('StackTrace');
            info.runTime         = r.get('RunTime') != null
                ? Integer.valueOf(String.valueOf(r.get('RunTime'))) : 0;

            Map<String, Object> apexClass = (Map<String, Object>) r.get('ApexClass');
            if (apexClass != null) {
                info.apexClassName = (String) apexClass.get('Name');
            }
            result.add(info);
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Metadata API — Deploy Status
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Checks the status of an async deployment by job ID.
     * Deploy IDs are returned by sf project deploy start and start with '0Af'.
     *
     * REST Metadata API endpoint:
     *   GET /services/data/vXX.0/metadata/deployRequest/<deployId>?includeDetails=true
     */
    public static DeployStatusInfo getDeployStatus(String deployId) {
        String endpoint = BASE_URL
            + '/services/data/v' + API_VERSION
            + '/metadata/deployRequest/' + deployId
            + '?includeDetails=true';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            ToolingApiException ex = new ToolingApiException(
                'Deploy status check failed: ' + res.getStatus());
            ex.statusCode = res.getStatusCode();
            ex.errorBody  = res.getBody();
            throw ex;
        }

        Map<String, Object> body = (Map<String, Object>)
            JSON.deserializeUntyped(res.getBody());

        DeployStatusInfo info = new DeployStatusInfo();
        info.id = deployId;

        // deployResult is nested inside the response
        Map<String, Object> deployResult =
            (Map<String, Object>) body.get('deployResult');

        if (deployResult != null) {
            info.done    = deployResult.get('done')    == true;
            info.success = deployResult.get('success') == true;
            info.status  = (String) deployResult.get('status');
            info.numberComponentsDeployed =
                deployResult.get('numberComponentsDeployed') != null
                ? Integer.valueOf(String.valueOf(deployResult.get('numberComponentsDeployed'))) : 0;
            info.numberComponentsTotal =
                deployResult.get('numberComponentTotal') != null
                ? Integer.valueOf(String.valueOf(deployResult.get('numberComponentTotal'))) : 0;
            info.numberTestsCompleted =
                deployResult.get('numberTestsCompleted') != null
                ? Integer.valueOf(String.valueOf(deployResult.get('numberTestsCompleted'))) : 0;
            info.numberTestErrors =
                deployResult.get('numberTestErrors') != null
                ? Integer.valueOf(String.valueOf(deployResult.get('numberTestErrors'))) : 0;

            // Component failures
            info.componentFailures = new List<String>();
            Map<String, Object> details = (Map<String, Object>) deployResult.get('details');
            if (details != null) {
                Object compFailures = details.get('componentFailures');
                if (compFailures instanceof List<Object>) {
                    for (Object f : (List<Object>) compFailures) {
                        Map<String, Object> failure = (Map<String, Object>) f;
                        info.componentFailures.add(
                            failure.get('componentType') + ': '
                            + failure.get('fullName') + ' — '
                            + failure.get('problem'));
                    }
                }
            }
        }
        return info;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tooling API — Custom Fields (metadata inspection)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Lists all custom fields on a given sObject via Tooling API.
     * Useful for documentation generation or migration scripts.
     *
     * NOTE: This is different from Schema.getDescribe() which only returns
     * fields the running user can access. Tooling API returns all fields.
     */
    public static List<Map<String, Object>> listCustomFields(String sObjectName) {
        String query =
            'SELECT+Id,DeveloperName,Label,DataType,Description'
            + '+FROM+CustomField'
            + '+WHERE+EntityDefinition.QualifiedApiName+=+\'' + sObjectName + '\''
            + '+ORDER+BY+DeveloperName';

        Map<String, Object> response = toolingQuery(query);
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        List<Object> records = (List<Object>) response.get('records');
        if (records == null) { return result; }

        for (Object rec : records) {
            result.add((Map<String, Object>) rec);
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private HTTP helper — Tooling API SOQL query
    // ─────────────────────────────────────────────────────────────────────────

    private static Map<String, Object> toolingQuery(String encodedQuery) {
        String endpoint = BASE_URL
            + '/services/data/v' + API_VERSION
            + '/tooling/query?q=' + encodedQuery;

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            ToolingApiException ex = new ToolingApiException(
                'Tooling API query failed [' + res.getStatusCode() + ']: '
                + res.getStatus());
            ex.statusCode = res.getStatusCode();
            ex.errorBody  = res.getBody();
            throw ex;
        }

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }
}
