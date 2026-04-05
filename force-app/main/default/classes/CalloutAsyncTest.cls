/**
 * CalloutAsyncTest
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 17 — Tests for SoapApiService, AsyncCalloutService, OutboundMessageHandler.
 *
 * ASYNC CALLOUT TEST PATTERNS:
 * ═════════════════════════════
 * @future:
 *   Cannot directly test @future callout results synchronously.
 *   Call the future method inside Test.startTest()/stopTest() — stopTest() drains
 *   the async queue and executes the future job before returning.
 *   Test.setMock must be set before startTest.
 *
 * Queueable:
 *   System.enqueueJob(job) inside startTest()/stopTest() — stopTest() executes it.
 *   Assert on side effects (DML changes) after stopTest().
 *
 * Batch:
 *   Database.executeBatch(batch) inside startTest()/stopTest().
 *   All three phases (start/execute/finish) run synchronously within stopTest().
 */
@IsTest
public class CalloutAsyncTest {

    // ───────────────────────────────────────────────────��─────────────────────
    // Test data
    // ─────────────────────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        Account acc = new Account(
            Name           = 'Async Test Corp',
            Type           = 'Customer - Direct',
            Sync_Status__c = 'Pending'
        );
        insert acc;
    }

    private static Account getTestAccount() {
        return [SELECT Id, Name, Sync_Status__c FROM Account WHERE Name = 'Async Test Corp' LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SoapApiService — envelope building
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void buildEnvelope_withParams_containsOperationAndParams() {
        Map<String, String> params = new Map<String, String>{
            'accountId' => 'ACC-001',
            'type'      => 'Customer'
        };

        Test.startTest();
        String envelope = SoapApiService.buildEnvelope(
            'http://example.com/services', 'getAccount', params);
        Test.stopTest();

        System.assert(envelope.contains('getAccount'),       'Envelope should contain operation name');
        System.assert(envelope.contains('ACC-001'),          'Envelope should contain accountId value');
        System.assert(envelope.contains('Customer'),         'Envelope should contain type value');
        System.assert(envelope.contains('soap:Envelope'),    'Envelope should have SOAP wrapper');
        System.assert(envelope.contains('soap:Body'),        'Envelope should have soap:Body');
    }

    @IsTest
    static void buildEnvelope_xmlInjection_isEscaped() {
        Map<String, String> params = new Map<String, String>{
            'name' => '<script>alert("xss")</script>'
        };

        Test.startTest();
        String envelope = SoapApiService.buildEnvelope(
            'http://example.com', 'doSomething', params);
        Test.stopTest();

        System.assert(!envelope.contains('<script>'),
            'XML injection characters should be escaped');
        System.assert(envelope.contains('&lt;script&gt;'),
            'Angle brackets should be XML-escaped');
    }

    @IsTest
    static void buildEnvelopeWithSecurity_containsWsSecurityHeader() {
        Test.startTest();
        String envelope = SoapApiService.buildEnvelopeWithSecurity(
            'http://example.com', 'getAccounts', null,
            'integrationUser', 'p@ssw0rd');
        Test.stopTest();

        System.assert(envelope.contains('wsse:Security'),      'Should have WS-Security header');
        System.assert(envelope.contains('wsse:UsernameToken'), 'Should have UsernameToken');
        System.assert(envelope.contains('integrationUser'),    'Should contain username');
        System.assert(envelope.contains('p@ssw0rd'),           'Should contain password');
    }

    @IsTest
    static void buildEnvelope_nullParams_producesValidEnvelope() {
        Test.startTest();
        String envelope = SoapApiService.buildEnvelope('http://ns.example.com', 'ping', null);
        Test.stopTest();

        System.assert(envelope.contains('ping'),       'Should contain operation name');
        System.assert(envelope.contains('soap:Body'), 'Should have soap:Body');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SoapApiService — request sending
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void sendSoapRequest_success_returnsBody() {
        String mockXml = '<?xml version="1.0"?>'
            + '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
            + '  <soap:Body>'
            + '    <getAccountResponse xmlns="http://example.com">'
            + '      <id>ACC-001</id><name>Acme Corp</name>'
            + '    </getAccountResponse>'
            + '  </soap:Body>'
            + '</soap:Envelope>';

        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, mockXml, 'text/xml'));

        Test.startTest();
        String result = SoapApiService.sendSoapRequest(
            'https://api.example.com/soap',
            'getAccount',
            SoapApiService.buildEnvelope('http://example.com', 'getAccount',
                new Map<String, String>{ 'accountId' => 'ACC-001' })
        );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.contains('Acme Corp'), 'Response should contain account name');
    }

    @IsTest
    static void sendSoapRequest_soapFault_throwsSoapFaultException() {
        String faultXml = '<?xml version="1.0"?>'
            + '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
            + '  <soap:Body>'
            + '    <soap:Fault>'
            + '      <faultcode>soap:Client</faultcode>'
            + '      <faultstring>Invalid account Id</faultstring>'
            + '    </soap:Fault>'
            + '  </soap:Body>'
            + '</soap:Envelope>';

        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(500, faultXml, 'text/xml'));

        Test.startTest();
        try {
            SoapApiService.sendSoapRequest(
                'https://api.example.com/soap', 'getAccount', '<dummy/>');
            System.assert(false, 'Expected SoapFaultException');
        } catch (SoapApiService.SoapFaultException e) {
            System.assert(e.getMessage().contains('Invalid account Id'),
                'Exception should contain fault string: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void sendSoapRequest_http404_throwsSoapFaultException() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(404, 'Not Found', 'text/plain'));

        Test.startTest();
        try {
            SoapApiService.sendSoapRequest('https://api.example.com/soap', 'op', '<req/>');
            System.assert(false, 'Expected SoapFaultException for HTTP 404');
        } catch (SoapApiService.SoapFaultException e) {
            System.assert(e.faultCode.contains('404'),
                'faultCode should contain the HTTP status: ' + e.faultCode);
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SoapApiService — DOM response parsing
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void parseSoapResponse_validXml_returnsChildMap() {
        String xml = '<?xml version="1.0"?>'
            + '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
            + '  <soap:Body>'
            + '    <getAccountResponse xmlns="http://example.com/ns">'
            + '      <id>ACC-001</id>'
            + '      <name>Acme</name>'
            + '      <status>Active</status>'
            + '    </getAccountResponse>'
            + '  </soap:Body>'
            + '</soap:Envelope>';

        Test.startTest();
        Map<String, String> result = SoapApiService.parseSoapResponse(
            xml, 'getAccountResponse', 'http://example.com/ns');
        Test.stopTest();

        System.assertEquals('ACC-001', result.get('id'));
        System.assertEquals('Acme',    result.get('name'));
        System.assertEquals('Active',  result.get('status'));
    }

    @IsTest
    static void extractElement_findsNestedElement() {
        String xml = '<?xml version="1.0"?>'
            + '<root><wrapper><target xmlns="http://ns.example.com">found-value</target></wrapper></root>';

        Test.startTest();
        String value = SoapApiService.extractElement(xml, 'target', 'http://ns.example.com');
        Test.stopTest();

        System.assertEquals('found-value', value);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AsyncCalloutService — @future
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void syncAccountFuture_success_updatesSyncStatus() {
        // Limit retries so the future job completes fast inside stopTest()
        ExternalApiClient.MAX_RETRIES = 0;
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, '{"id":"ACC-001","status":"synced"}'));

        Account acc = getTestAccount();

        Test.startTest();
        AsyncCalloutService.syncAccountFuture(acc.Id);
        Test.stopTest();  // drains @future queue

        Account updated = [SELECT Sync_Status__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Synced', updated.Sync_Status__c,
            'Sync status should be Synced after successful callout');
    }

    @IsTest
    static void syncAccountFuture_calloutError_setsFailedStatus() {
        ExternalApiClient.MAX_RETRIES = 0;
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(503, '{"error":"service unavailable"}'));

        Account acc = getTestAccount();

        Test.startTest();
        AsyncCalloutService.syncAccountFuture(acc.Id);
        Test.stopTest();

        Account updated = [SELECT Sync_Status__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Failed', updated.Sync_Status__c,
            'Sync status should be Failed after callout error');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AsyncCalloutService — Queueable
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void syncAccountsJob_success_jobEnqueuesWithoutException() {
        ExternalApiClient.MAX_RETRIES = 0;
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, '{"status":"ok"}'));

        Account acc = getTestAccount();

        Test.startTest();
        Id jobId = AsyncCalloutService.enqueueSyncJob(new List<Id>{ acc.Id });
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Job Id should be returned');
    }

    @IsTest
    static void syncAccountsJob_emptySlice_completesGracefully() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, '{"status":"ok"}'));

        Test.startTest();
        // Pass a batchIndex beyond the list size — should exit early without error
        AsyncCalloutService.SyncAccountsJob job =
            new AsyncCalloutService.SyncAccountsJob(new List<Id>(), 5);
        job.execute(null);
        Test.stopTest();
        // No exception = success
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AsyncCalloutService — Batch
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void syncAccountBatch_success_updatesSyncStatus() {
        ExternalApiClient.MAX_RETRIES = 0;
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, '{"status":"synced"}'));

        Test.startTest();
        Id batchId = AsyncCalloutService.startSyncBatch(10);
        Test.stopTest();

        System.assertNotEquals(null, batchId, 'Batch job Id should be returned');
        Account updated = [SELECT Sync_Status__c FROM Account WHERE Name = 'Async Test Corp' LIMIT 1];
        System.assertEquals('Synced', updated.Sync_Status__c,
            'Batch should update Sync_Status__c to Synced');
    }

    @IsTest
    static void notifyWebhookJob_success_completesWithoutException() {
        Test.setMock(HttpCalloutMock.class,
            new CalloutMocks.SingleResponse(200, '{"received":true}'));

        Test.startTest();
        System.enqueueJob(new AsyncCalloutService.NotifyWebhookJob(42));
        Test.stopTest();
        // No exception = success
    }

    // ─────────────────────────────────────────────────────────────────────────
    // OutboundMessageHandler — SOAP parsing
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void parseNotification_validEnvelope_extractsAllFields() {
        String soapBody = '<?xml version="1.0"?>'
            + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
            + '  <soapenv:Body>'
            + '    <notifications xmlns="http://soap.sforce.com/2005/09/outbound">'
            + '      <OrganizationId>00D000000000001AAA</OrganizationId>'
            + '      <SessionId>session-token-123</SessionId>'
            + '      <EnterpriseUrl>https://na1.salesforce.com/services/Soap/c/62.0</EnterpriseUrl>'
            + '      <Notification>'
            + '        <Id>04l000000000001AAA</Id>'
            + '        <sObject xmlns:sf="urn:sobject.enterprise.soap.sforce.com">'
            + '          <sf:Id>001000000000001AAA</sf:Id>'
            + '          <sf:Name>Acme Corp</sf:Name>'
            + '          <sf:Type>Customer - Direct</sf:Type>'
            + '        </sObject>'
            + '      </Notification>'
            + '    </notifications>'
            + '  </soapenv:Body>'
            + '</soapenv:Envelope>';

        Test.startTest();
        OutboundMessageHandler.ParsedNotification n =
            OutboundMessageHandler.parseNotification(soapBody);
        Test.stopTest();

        System.assertEquals('00D000000000001AAA',  n.organizationId);
        System.assertEquals('session-token-123',   n.sessionId);
        System.assertEquals('04l000000000001AAA',  n.notificationId);
        System.assertEquals('001000000000001AAA',  n.accountId);
        System.assertEquals('Acme Corp',           n.name);
        System.assertEquals('Customer - Direct',   n.type);
    }

    @IsTest
    static void buildAckResponse_true_containsAckTrue() {
        Test.startTest();
        String ack = OutboundMessageHandler.buildAckResponse(true);
        Test.stopTest();

        System.assert(ack.contains('<Ack>true</Ack>'),         'ACK response should be true');
        System.assert(ack.contains('notificationsResponse'),   'Should have notificationsResponse element');
    }

    @IsTest
    static void buildAckResponse_false_containsAckFalse() {
        Test.startTest();
        String nack = OutboundMessageHandler.buildAckResponse(false);
        Test.stopTest();

        System.assert(nack.contains('<Ack>false</Ack>'), 'NACK response should be false');
    }

    @IsTest
    static void handleAccountNotification_validPost_returns200WithAck() {
        String soapBody = '<?xml version="1.0"?>'
            + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
            + '  <soapenv:Body>'
            + '    <notifications xmlns="http://soap.sforce.com/2005/09/outbound">'
            + '      <OrganizationId>00D000000000001AAA</OrganizationId>'
            + '      <SessionId>test-session</SessionId>'
            + '      <EnterpriseUrl>https://na1.salesforce.com</EnterpriseUrl>'
            + '      <Notification>'
            + '        <Id>04l000000000002AAA</Id>'
            + '        <sObject xmlns:sf="urn:sobject.enterprise.soap.sforce.com">'
            + '          <sf:Id>001000000000002AAA</sf:Id>'
            + '          <sf:Name>Test Account</sf:Name>'
            + '        </sObject>'
            + '      </Notification>'
            + '    </notifications>'
            + '  </soapenv:Body>'
            + '</soapenv:Envelope>';

        RestRequest req   = new RestRequest();
        req.requestBody   = Blob.valueOf(soapBody);
        req.httpMethod    = 'POST';
        req.requestURI    = '/services/apexrest/outbound-message/account';
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        OutboundMessageHandler.handleAccountNotification();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        String respBody = RestContext.response.responseBody.toString();
        System.assert(respBody.contains('<Ack>true</Ack>'),
            'Handler should return Ack=true for valid notification');
    }
}
