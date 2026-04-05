/**
 * OutboundMessageHandler
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 17 — Salesforce Outbound Messaging: inbound SOAP handler.
 *
 * OUTBOUND MESSAGING OVERVIEW:
 * ═════════════════════════════
 * Outbound Messages are a declarative integration feature:
 *  1. Configure in Setup → Workflow Rules (or Flows) → Outbound Messages
 *  2. When the workflow fires, Salesforce POSTs an XML/SOAP message to your endpoint
 *  3. Your endpoint must return an ACK response (Ack=true) within the timeout
 *  4. Salesforce retries automatically if no ACK received (up to 24 hours)
 *  5. Delivery is guaranteed-at-least-once (may duplicate — design for idempotency)
 *
 * SOAP ENVELOPE SENT BY SALESFORCE:
 * ═══════════════════════════════════
 * POST https://your-endpoint.example.com/services/outbound-message
 * Content-Type: text/xml; charset=UTF-8
 * SOAPAction: ""
 *
 * <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
 *   <soapenv:Body>
 *     <notifications xmlns="http://soap.sforce.com/2005/09/outbound">
 *       <OrganizationId>00D000000000001AAA</OrganizationId>
 *       <ActionId>04k000000000001AAA</ActionId>
 *       <SessionId>token-for-callback-api-calls</SessionId>
 *       <EnterpriseUrl>https://na1.salesforce.com/services/Soap/c/62.0</EnterpriseUrl>
 *       <PartnerUrl>https://na1.salesforce.com/services/Soap/u/62.0</PartnerUrl>
 *       <Notification>
 *         <Id>04l000000000001AAA</Id>
 *         <sObject xsi:type="sf:Account"
 *                  xmlns:sf="urn:sobject.enterprise.soap.sforce.com">
 *           <sf:Id>001000000000001AAA</sf:Id>
 *           <sf:Name>Acme Corp</sf:Name>
 *           <sf:Type>Customer - Direct</sf:Type>
 *         </sObject>
 *       </Notification>
 *     </notifications>
 *   </soapenv:Body>
 * </soapenv:Envelope>
 *
 * EXPECTED ACK RESPONSE:
 * ═══════════════════════
 * HTTP 200
 * <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
 *   <soapenv:Body>
 *     <notificationsResponse xmlns="http://soap.sforce.com/2005/09/outbound">
 *       <Ack>true</Ack>
 *     </notificationsResponse>
 *   </soapenv:Body>
 * </soapenv:Envelope>
 *
 * IMPLEMENTATION NOTE:
 * This is a @RestResource endpoint that receives the SOAP POST.
 * Alternatively, implement as a global WebService class with a WSDL endpoint,
 * but @RestResource is simpler and avoids the need to publish a separate WSDL.
 *
 * IDEMPOTENCY:
 * Use the <Notification><Id> (notificationId) as a deduplication key.
 * Store processed Ids in a custom object and skip re-processing on duplicates.
 */
@RestResource(urlMapping='/outbound-message/account')
global class OutboundMessageHandler {

    private static final String OUTBOUND_NS = 'http://soap.sforce.com/2005/09/outbound';
    private static final String SOAP_NS     = 'http://schemas.xmlsoap.org/soap/envelope/';
    private static final String SF_NS       = 'urn:sobject.enterprise.soap.sforce.com';

    @HttpPost
    global static void handleAccountNotification() {
        RestRequest  req  = RestContext.request;
        RestResponse resp = RestContext.response;
        resp.addHeader('Content-Type', 'text/xml; charset=UTF-8');

        try {
            String body = req.requestBody.toString();
            ParsedNotification notification = parseNotification(body);
            processAccountUpdate(notification);
            resp.responseBody = Blob.valueOf(buildAckResponse(true));
            resp.statusCode   = 200;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'OutboundMessageHandler error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Return Ack=false to trigger Salesforce retry
            resp.responseBody = Blob.valueOf(buildAckResponse(false));
            resp.statusCode   = 200;  // Must return 200 even for Ack=false
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Notification parsing
    // ─────────────────────────────────────────────────────────────────────────

    @TestVisible
    static ParsedNotification parseNotification(String xmlBody) {
        Dom.Document doc = new Dom.Document();
        doc.load(xmlBody);

        Dom.XmlNode envelope     = doc.getRootElement();
        Dom.XmlNode body         = envelope.getChildElement('Body', SOAP_NS);
        Dom.XmlNode notifications = body.getChildElement('notifications', OUTBOUND_NS);

        ParsedNotification result  = new ParsedNotification();
        result.organizationId = getChildText(notifications, 'OrganizationId', OUTBOUND_NS);
        result.sessionId      = getChildText(notifications, 'SessionId',      OUTBOUND_NS);
        result.enterpriseUrl  = getChildText(notifications, 'EnterpriseUrl',  OUTBOUND_NS);

        Dom.XmlNode notification  = notifications.getChildElement('Notification', OUTBOUND_NS);
        if (notification != null) {
            result.notificationId = getChildText(notification, 'Id', OUTBOUND_NS);
            Dom.XmlNode sobj      = notification.getChildElement('sObject', null);
            if (sobj != null) {
                result.accountId = getChildText(sobj, 'Id',   SF_NS);
                result.name      = getChildText(sobj, 'Name', SF_NS);
                result.type      = getChildText(sobj, 'Type', SF_NS);
            }
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Business logic
    // ─────────────────────────────────────────────────────────────────────────

    private static void processAccountUpdate(ParsedNotification n) {
        if (String.isBlank(n.accountId)) { return; }

        // Idempotency check — skip if this notification was already processed
        if (isAlreadyProcessed(n.notificationId)) {
            System.debug('Duplicate notification skipped: ' + n.notificationId);
            return;
        }

        // Business action: e.g. sync to an external system, update a local mirror, etc.
        // Using the sessionId from the notification for a callback to Salesforce is also valid:
        //   ExternalApiClient.get('callout:SF_Callback/services/data/v62.0/sobjects/Account/' + n.accountId)
        //   with Authorization: Bearer <n.sessionId>

        // Mark processed (idempotency store)
        markProcessed(n.notificationId, n.accountId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ACK response builder
    // ─────────────────────────────────────────────────────────────────────────

    @TestVisible
    static String buildAckResponse(Boolean ack) {
        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
            + '  <soapenv:Body>'
            + '    <notificationsResponse xmlns="http://soap.sforce.com/2005/09/outbound">'
            + '      <Ack>' + String.valueOf(ack) + '</Ack>'
            + '    </notificationsResponse>'
            + '  </soapenv:Body>'
            + '</soapenv:Envelope>';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Idempotency helpers (simplified — use a custom object in production)
    // ─────────────────────────────────────────────────────────────────────────

    private static Boolean isAlreadyProcessed(String notificationId) {
        // Production: query an Outbound_Message_Log__c or similar dedup store
        // Simplified: check a platform cache key or custom object
        if (String.isBlank(notificationId)) { return false; }
        return false;  // Placeholder — always process in this demo
    }

    private static void markProcessed(String notificationId, String accountId) {
        // Production: insert Outbound_Message_Log__c(Notification_Id__c = notificationId, ...)
        System.debug('Processed notification: ' + notificationId + ' for account: ' + accountId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DOM helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static String getChildText(Dom.XmlNode parent, String childName, String ns) {
        Dom.XmlNode child = parent.getChildElement(childName, ns);
        return child != null ? child.getText() : null;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner result class
    // ─────────────────────────────────────────────────────────────────────────

    public class ParsedNotification {
        public String organizationId;
        public String sessionId;
        public String enterpriseUrl;
        public String notificationId;
        public String accountId;
        public String name;
        public String type;
    }
}
