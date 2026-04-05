/**
 * CalloutMocks
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 16 — HttpCalloutMock implementations for testing callout Apex.
 *
 * USAGE:
 *   Test.setMock(HttpCalloutMock.class, new CalloutMocks.SingleResponse(200, body));
 *
 * RULES FOR CALLOUT TESTS:
 *  • Test.setMock() MUST be called before Test.startTest()
 *  • Callout code MUST be inside Test.startTest() / Test.stopTest()
 *  • Without Test.setMock(), callouts in tests throw:
 *    "Methods defined as TestMethod do not support Web service callouts"
 *
 * MOCK TYPES PROVIDED:
 *  SingleResponse   — one fixed response for any request
 *  MultiEndpoint    — URL-matched routing (different response per endpoint)
 *  SequentialResponse — ordered list; useful for retry / pagination testing
 *
 * ALTERNATIVE: StaticResourceCalloutMock
 *   Test.setMock(HttpCalloutMock.class, new StaticResourceCalloutMock());
 *   Uses a static resource as the response body — good for large payloads.
 */
@IsTest
public class CalloutMocks {

    // ─────────────────────────────────────────────────────────────────────────
    // SingleResponse — returns the same response for every request
    // ─────────────────────────────────────────────────────────────────────────

    public class SingleResponse implements HttpCalloutMock {
        private Integer statusCode;
        private String  body;
        private String  contentType;

        public SingleResponse(Integer statusCode, String body) {
            this(statusCode, body, 'application/json');
        }

        public SingleResponse(Integer statusCode, String body, String contentType) {
            this.statusCode  = statusCode;
            this.body        = body;
            this.contentType = contentType;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(statusCode);
            resp.setBody(body != null ? body : '');
            resp.setHeader('Content-Type', contentType);
            return resp;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MultiEndpoint — routes to different responses based on URL substring
    // ─────────────────────────────────────────────────────────────────────────

    public class MultiEndpoint implements HttpCalloutMock {
        // Ordered list so more-specific patterns can be added before generic ones
        private List<String>        keys      = new List<String>();
        private Map<String, HttpResponse> map = new Map<String, HttpResponse>();
        private HttpResponse        fallback;

        public MultiEndpoint addResponse(String urlContains, Integer code, String body) {
            HttpResponse resp = buildResponse(code, body);
            keys.add(urlContains);
            map.put(urlContains, resp);
            return this;   // fluent API
        }

        public MultiEndpoint setDefault(Integer code, String body) {
            fallback = buildResponse(code, body);
            return this;
        }

        public HttpResponse respond(HttpRequest req) {
            String url = req.getEndpoint();
            for (String key : keys) {
                if (url.contains(key)) { return map.get(key); }
            }
            return fallback != null ? fallback : buildResponse(404, ERROR_JSON);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SequentialResponse — returns responses in order (for retry / pagination)
    // ─────────────────────────────────────────────────────────────────────────

    public class SequentialResponse implements HttpCalloutMock {
        private List<HttpResponse> responses;
        private Integer callCount = 0;

        public SequentialResponse(List<HttpResponse> responses) {
            this.responses = responses;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = (callCount < responses.size())
                ? responses[callCount]
                : responses[responses.size() - 1];  // repeat last if exhausted
            callCount++;
            return resp;
        }

        public Integer getCallCount() { return callCount; }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Factory helpers
    // ─────────────────────────────────────────────────────────────────────────

    public static HttpResponse buildResponse(Integer code, String body) {
        HttpResponse resp = new HttpResponse();
        resp.setStatusCode(code);
        resp.setBody(body != null ? body : '');
        resp.setHeader('Content-Type', 'application/json');
        return resp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Canned payloads — reuse across test classes
    // ─────────────────────────────────────────────────────────────────────────

    public static final String ACCOUNT_JSON =
        '{"id":"ACC-001","name":"Acme Corp","type":"Customer","status":"Active",' +
        '"contacts":[{"id":"CON-001","email":"john@acme.com",' +
        '"firstName":"John","lastName":"Doe"}]}';

    public static final String ACCOUNT_CREATED_JSON =
        '{"id":"ACC-NEW","name":"New Corp","type":"Prospect","status":"Active"}';

    public static final String TOKEN_JSON =
        '{"access_token":"eyJhbGciOiJSUzI1NiJ9.test.sig","token_type":"Bearer",' +
        '"expires_in":3600,"scope":"api","instance_url":"https://na1.salesforce.com"}';

    public static final String ERROR_JSON =
        '{"code":"NOT_FOUND","message":"Resource not found","correlationId":"abc-123"}';

    public static final String SERVER_ERROR_JSON =
        '{"code":"INTERNAL_ERROR","message":"Unexpected server error"}';

    public static final String RATE_LIMIT_JSON =
        '{"code":"RATE_LIMIT","message":"Too many requests. Retry after 60 seconds."}';
}
