/**
 * ExternalApiClient
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 16 — REST API Integrations: production-ready HTTP callout patterns.
 *
 * KEY CONCEPTS DEMONSTRATED:
 *  • HttpRequest / HttpResponse / Http.send()
 *  • Named Credential endpoint: 'callout:NC_Name/path'
 *  • GET / POST / PATCH / DELETE patterns
 *  • setCompressed(true) for large payloads
 *  • setTimeout() — default 10s; max 120,000ms; always set explicitly
 *  • JSON.serialize(obj, suppressNulls) / JSON.deserialize(body, Type.class)
 *  • JSON.deserializeUntyped() → Map<String,Object> / List<Object> tree
 *  • Retry on 429 / 5xx with exponential back-off (Queueable-based in production)
 *  • ApiErrorException carries statusCode + raw body for caller logging
 *
 * GOVERNOR LIMITS (callouts):
 *  • Max callouts per transaction: 100
 *  • Max callout timeout: 120,000ms
 *  • Cannot make callouts after DML in same transaction
 *    → solution: use @future(callout=true) or Queueable with Database.AllowsCallouts
 *
 * NAMED CREDENTIAL ENDPOINT FORMAT:
 *  'callout:<NC_DeveloperName><path>'
 *  The platform appends <path> to the NC base URL and injects auth headers.
 *  Remote Site Settings are NOT required when using Named Credentials.
 */
public with sharing class ExternalApiClient {

    public class CalloutException  extends Exception {}
    public class ApiErrorException extends Exception {
        public Integer statusCode;
        public String  errorBody;
        public ApiErrorException(Integer code, String body) {
            super('HTTP ' + code + ': ' + body);
            this.statusCode = code;
            this.errorBody  = body;
        }
    }

    // Named Credential developer name (matches .namedCredential-meta.xml filename)
    @TestVisible
    private static final String NC_NAME         = 'Demo_External_API';
    private static final Integer TIMEOUT_MS     = 30000;  // 30 seconds
    @TestVisible
    private static Integer MAX_RETRIES          = 3;      // overridable in tests

    // ─────────────────────────────────────────────────────────────────────────
    // Public API — GET
    // ─────────────────────────────────────────────────────────────────────────

    public static String get(String path) {
        return sendAndAssert(buildRequest('GET', path, null, null));
    }

    public static String get(String path, Map<String, String> extraHeaders) {
        return sendAndAssert(buildRequest('GET', path, null, extraHeaders));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public API — POST
    // ─────────────────────────────────────────────────────────────────────────

    public static String post(String path, Object body) {
        return sendAndAssert(buildRequest('POST', path, body, null));
    }

    public static String post(String path, Object body, Map<String, String> extraHeaders) {
        return sendAndAssert(buildRequest('POST', path, body, extraHeaders));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public API — PATCH
    // ─────────────────────────────────────────────────────────────────────────

    public static String patch(String path, Object body) {
        return sendAndAssert(buildRequest('PATCH', path, body, null));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public API — DELETE
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * DELETE does not retry (deleting twice can cause a 404 on the second attempt).
     */
    public static void deleteResource(String path) {
        HttpResponse resp = new Http().send(buildRequest('DELETE', path, null, null));
        assertSuccess(resp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JSON helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Type-safe deserialization.
     *
     * Usage:
     *   AccountDto dto = (AccountDto) ExternalApiClient.deserialize(body, AccountDto.class);
     *
     * Caution: JSON field names must match Apex field names exactly (case-insensitive).
     * Use @JsonAccess or wrapper maps for snake_case → camelCase translation.
     */
    public static Object deserialize(String jsonBody, Type targetType) {
        try {
            return JSON.deserialize(jsonBody, targetType);
        } catch (JSONException e) {
            throw new CalloutException('JSON parse error — ' + e.getMessage()
                + ' | body prefix: ' + jsonBody.abbreviate(200));
        }
    }

    /**
     * Untyped parsing — returns Map<String,Object> or List<Object>.
     * Use when the schema is dynamic, partially known, or deeply nested.
     *
     * Traverse: ((Map<String,Object>) result.get('data')).get('id')
     */
    public static Object deserializeUntyped(String jsonBody) {
        return JSON.deserializeUntyped(jsonBody);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Retry logic
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Sends the request and retries on 429 (Rate Limit) and 5xx (Server Error).
     *
     * PRODUCTION NOTE:
     *  Apex cannot sleep — back-off between attempts burns CPU.
     *  For long back-off windows (>5s), chain via Queueable:
     *    System.enqueueJob(new RetryCalloutJob(req, attempt + 1));
     *  This method uses immediate retry, which is acceptable for short bursts.
     */
    private static HttpResponse sendWithRetry(HttpRequest req) {
        Http http = new Http();
        HttpResponse resp;
        for (Integer attempt = 0; attempt <= MAX_RETRIES; attempt++) {
            resp = http.send(req);
            Integer code      = resp.getStatusCode();
            Boolean retryable = (code == 429 || (code >= 500 && code < 600));
            if (!retryable || attempt == MAX_RETRIES) {
                return resp;
            }
            // No real sleep in Apex — immediate retry is the only synchronous option
        }
        return resp;
    }

    private static String sendAndAssert(HttpRequest req) {
        HttpResponse resp = sendWithRetry(req);
        assertSuccess(resp);
        return resp.getBody();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Request builder
    // ─────────────────────────────────────────────────────────────────────────

    private static HttpRequest buildRequest(
            String method, String path, Object body, Map<String, String> extraHeaders) {

        HttpRequest req = new HttpRequest();
        // Named Credential prefix — Salesforce injects auth + base URL automatically
        req.setEndpoint('callout:' + NC_NAME + path);
        req.setMethod(method);
        req.setTimeout(TIMEOUT_MS);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');

        if (body != null) {
            // suppressApexObjectNulls=true omits null fields from the JSON output
            String jsonBody = JSON.serialize(body, true);
            req.setBody(jsonBody);
            // Compress payloads > 100KB to reduce bandwidth
            req.setCompressed(jsonBody.length() > 100_000);
        }

        if (extraHeaders != null) {
            for (String key : extraHeaders.keySet()) {
                req.setHeader(key, extraHeaders.get(key));
            }
        }

        return req;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Assertion
    // ─────────────────────────────────────────────────────────────────────────

    private static void assertSuccess(HttpResponse resp) {
        Integer code = resp.getStatusCode();
        if (code < 200 || code >= 300) {
            throw new ApiErrorException(code, resp.getBody());
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Response DTOs
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * DTOs match the external API's JSON schema.
     * JSON.deserialize() is case-insensitive for field name matching.
     * Fields not present in the JSON remain null — no exception thrown.
     */
    public class AccountDto {
        public String          id;
        public String          name;
        public String          type;
        public String          status;
        public List<ContactDto> contacts;
    }

    public class ContactDto {
        public String id;
        public String email;
        public String firstName;
        public String lastName;
    }

    public class ErrorDto {
        public String code;
        public String message;
        public String correlationId;
    }

    public class PagedResponse {
        public Integer         total;
        public Integer         page;
        public Integer         pageSize;
        public List<Object>    items;
    }
}
