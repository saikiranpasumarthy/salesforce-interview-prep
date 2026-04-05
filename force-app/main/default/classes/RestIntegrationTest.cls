/**
 * RestIntegrationTest
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 16 — Tests for ExternalApiClient, JwtTokenService, and CalloutMocks.
 *
 * CALLOUT TEST PATTERN:
 *   1. Test.setMock(HttpCalloutMock.class, mock)  ← must be before startTest
 *   2. Test.startTest()
 *   3. Call the method under test
 *   4. Test.stopTest()
 *   5. Assert results
 *
 * Without setMock, Apex throws:
 *   "Methods defined as TestMethod do not support Web service callouts"
 */
@IsTest
public class RestIntegrationTest {

    // ─────────────────────────────────────────────────────────────────────────
    // ExternalApiClient — GET
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void get_success_returnsResponseBody() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, CalloutMocks.ACCOUNT_JSON));

        Test.startTest();
        String body = ExternalApiClient.get('/accounts/ACC-001');
        Test.stopTest();

        System.assertNotEquals(null, body);
        System.assert(body.contains('Acme Corp'), 'Body should contain account name');
    }

    @IsTest
    static void get_withExtraHeaders_success() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, CalloutMocks.ACCOUNT_JSON));

        Test.startTest();
        String body = ExternalApiClient.get(
            '/accounts/ACC-001',
            new Map<String, String>{ 'X-Correlation-ID' => 'test-123' }
        );
        Test.stopTest();

        System.assertNotEquals(null, body);
    }

    @IsTest
    static void get_notFound_throwsApiErrorException() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(404, CalloutMocks.ERROR_JSON));

        Test.startTest();
        try {
            ExternalApiClient.get('/accounts/MISSING');
            System.assert(false, 'Expected ApiErrorException');
        } catch (ExternalApiClient.ApiErrorException e) {
            System.assertEquals(404, e.statusCode);
            System.assert(e.errorBody.contains('NOT_FOUND'),
                'errorBody should contain the API error code');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ExternalApiClient — POST
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void post_success_returnsCreatedBody() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(201, CalloutMocks.ACCOUNT_CREATED_JSON));

        ExternalApiClient.AccountDto dto = new ExternalApiClient.AccountDto();
        dto.name = 'New Corp';
        dto.type = 'Prospect';

        Test.startTest();
        String body = ExternalApiClient.post('/accounts', dto);
        Test.stopTest();

        System.assert(body.contains('ACC-NEW'), 'Response should include new record Id');
    }

    @IsTest
    static void post_serverError_throwsApiErrorException() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(500, CalloutMocks.SERVER_ERROR_JSON));

        // Override max retries to 0 to avoid the test timing out on spin-wait
        ExternalApiClient.MAX_RETRIES = 0;

        Test.startTest();
        try {
            ExternalApiClient.post('/accounts', new ExternalApiClient.AccountDto());
            System.assert(false, 'Expected ApiErrorException');
        } catch (ExternalApiClient.ApiErrorException e) {
            System.assertEquals(500, e.statusCode);
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ExternalApiClient — PATCH
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void patch_success_returnsUpdatedBody() {
        String updatedJson = '{"id":"ACC-001","name":"Acme Updated","status":"Active"}';
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, updatedJson));

        ExternalApiClient.AccountDto dto = new ExternalApiClient.AccountDto();
        dto.name = 'Acme Updated';

        Test.startTest();
        String body = ExternalApiClient.patch('/accounts/ACC-001', dto);
        Test.stopTest();

        System.assert(body.contains('Updated'));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ExternalApiClient — DELETE
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void deleteResource_success_noException() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(204, ''));

        Test.startTest();
        ExternalApiClient.deleteResource('/accounts/ACC-DEL');
        Test.stopTest();
        // Reaching here = success (no exception thrown)
    }

    @IsTest
    static void deleteResource_notFound_throwsApiErrorException() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(404, CalloutMocks.ERROR_JSON));

        Test.startTest();
        try {
            ExternalApiClient.deleteResource('/accounts/GONE');
            System.assert(false, 'Expected ApiErrorException');
        } catch (ExternalApiClient.ApiErrorException e) {
            System.assertEquals(404, e.statusCode);
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ExternalApiClient — retry behaviour
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void get_serverError_retriesUpToMaxAndThrows() {
        // 4 consecutive 500s — exhausts MAX_RETRIES=3 (4 total attempts)
        List<HttpResponse> responses = new List<HttpResponse>{
            CalloutMocks.buildResponse(500, CalloutMocks.SERVER_ERROR_JSON),
            CalloutMocks.buildResponse(500, CalloutMocks.SERVER_ERROR_JSON),
            CalloutMocks.buildResponse(500, CalloutMocks.SERVER_ERROR_JSON),
            CalloutMocks.buildResponse(500, CalloutMocks.SERVER_ERROR_JSON)
        };
        CalloutMocks.SequentialResponse mock =
            new CalloutMocks.SequentialResponse(responses);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            ExternalApiClient.get('/retry-test');
            System.assert(false, 'Expected ApiErrorException after retries exhausted');
        } catch (ExternalApiClient.ApiErrorException e) {
            System.assertEquals(500, e.statusCode);
        }
        Test.stopTest();

        // MAX_RETRIES=3 → 1 initial + 3 retries = 4 total calls
        System.assertEquals(4, mock.getCallCount(),
            'Should have retried 3 times (4 total attempts)');
    }

    @IsTest
    static void get_serverErrorThenSuccess_recoversAfterRetry() {
        // First call returns 500, second returns 200 — retry succeeds
        List<HttpResponse> responses = new List<HttpResponse>{
            CalloutMocks.buildResponse(500, CalloutMocks.SERVER_ERROR_JSON),
            CalloutMocks.buildResponse(200, CalloutMocks.ACCOUNT_JSON)
        };
        CalloutMocks.SequentialResponse mock =
            new CalloutMocks.SequentialResponse(responses);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        String body = ExternalApiClient.get('/flaky-endpoint');
        Test.stopTest();

        System.assert(body.contains('Acme Corp'), 'Should return success body after retry');
        System.assertEquals(2, mock.getCallCount(), 'Should have called twice (1 fail + 1 success)');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ExternalApiClient — JSON parsing
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void deserialize_typedAccountDto_parsesAllFields() {
        Test.startTest();
        ExternalApiClient.AccountDto dto =
            (ExternalApiClient.AccountDto) ExternalApiClient.deserialize(
                CalloutMocks.ACCOUNT_JSON, ExternalApiClient.AccountDto.class);
        Test.stopTest();

        System.assertEquals('ACC-001',   dto.id);
        System.assertEquals('Acme Corp', dto.name);
        System.assertEquals('Customer',  dto.type);
        System.assertEquals(1,           dto.contacts.size());
        System.assertEquals('john@acme.com', dto.contacts[0].email);
        System.assertEquals('John',      dto.contacts[0].firstName);
    }

    @IsTest
    static void deserializeUntyped_parsesTopLevelMap() {
        Test.startTest();
        Map<String, Object> result =
            (Map<String, Object>) ExternalApiClient.deserializeUntyped(
                CalloutMocks.ACCOUNT_JSON);
        Test.stopTest();

        System.assertEquals('ACC-001',   (String) result.get('id'));
        System.assertEquals('Acme Corp', (String) result.get('name'));
        System.assertNotEquals(null, result.get('contacts'));
        System.assert(result.get('contacts') instanceof List<Object>);
    }

    @IsTest
    static void deserialize_malformedJson_throwsCalloutException() {
        Test.startTest();
        try {
            ExternalApiClient.deserialize('{invalid json}', ExternalApiClient.AccountDto.class);
            System.assert(false, 'Expected CalloutException for malformed JSON');
        } catch (ExternalApiClient.CalloutException e) {
            System.assert(e.getMessage().contains('JSON parse error'));
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CalloutMocks — MultiEndpoint routing
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void multiEndpointMock_routesToCorrectResponse() {
        CalloutMocks.MultiEndpoint mock = new CalloutMocks.MultiEndpoint()
            .addResponse('/accounts', 200, CalloutMocks.ACCOUNT_JSON)
            .addResponse('/token',    200, CalloutMocks.TOKEN_JSON)
            .setDefault(404, CalloutMocks.ERROR_JSON);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        String accountBody = ExternalApiClient.get('/accounts/ACC-001');
        Test.stopTest();

        System.assert(accountBody.contains('Acme Corp'),
            'Multi-endpoint mock should route /accounts to account response');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JwtTokenService — Client Credentials
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getTokenViaClientCredentials_success_parsesTokenResponse() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, CalloutMocks.TOKEN_JSON));

        Test.startTest();
        JwtTokenService.TokenResponse token = JwtTokenService.getTokenViaClientCredentials(
            'https://auth.example.com/oauth/token',
            'client-id-123',
            'client-secret-xyz',
            'api read:accounts'
        );
        Test.stopTest();

        System.assertNotEquals(null,     token.access_token, 'access_token should be set');
        System.assertEquals('Bearer',    token.token_type);
        System.assertEquals(3600,        token.expires_in);
        System.assertEquals('https://na1.salesforce.com', token.instance_url);
    }

    @IsTest
    static void getTokenViaClientCredentials_invalidCreds_throwsTokenException() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(401, '{"error":"invalid_client","error_description":"Bad credentials"}'));

        Test.startTest();
        try {
            JwtTokenService.getTokenViaClientCredentials(
                'https://auth.example.com/oauth/token',
                'bad-id', 'bad-secret', null
            );
            System.assert(false, 'Expected TokenException for 401 response');
        } catch (JwtTokenService.TokenException e) {
            System.assert(e.getMessage().contains('Client Credentials grant failed'),
                'Exception message should describe the failure: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JwtTokenService — utilities
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void buildBearerHeader_returnsCorrectFormat() {
        Test.startTest();
        String header = JwtTokenService.buildBearerHeader('my-access-token');
        Test.stopTest();

        System.assertEquals('Bearer my-access-token', header);
    }

    @IsTest
    static void isTokenExpiring_expiredToken_returnsTrue() {
        // Token fetched 1 hour ago, expires_in=3600 → already expired
        Datetime fetchedAt = Datetime.now().addHours(-1);

        Test.startTest();
        Boolean expiring = JwtTokenService.isTokenExpiring(fetchedAt, 3600, 60);
        Test.stopTest();

        System.assertEquals(true, expiring, 'Token fetched 1h ago with 3600s lifetime should be expiring');
    }

    @IsTest
    static void isTokenExpiring_freshToken_returnsFalse() {
        // Token just fetched, 1 hour lifetime, 60s buffer
        Datetime fetchedAt = Datetime.now();

        Test.startTest();
        Boolean expiring = JwtTokenService.isTokenExpiring(fetchedAt, 3600, 60);
        Test.stopTest();

        System.assertEquals(false, expiring, 'Freshly fetched token should not be expiring');
    }
}
