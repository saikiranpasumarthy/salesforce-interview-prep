/**
 * SoapApiService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 17 — SOAP callout patterns: raw envelope construction, DOM parsing,
 * fault handling, and the WSDL2Apex stub invocation pattern.
 *
 * TWO APPROACHES TO SOAP CALLOUTS:
 * ═════════════════════════════════
 * 1. WSDL2Apex (recommended when WSDL is available):
 *    • Upload WSDL in Setup → Apex Classes → Generate from WSDL
 *    • Salesforce generates type classes + a stub class (e.g. AccountService_stub.cls)
 *    • Call: new AccountServiceStub().getAccount(request)
 *    • Underlying implementation uses WebServiceCallout.invoke()
 *    • Limitations: complex/large WSDLs may fail; WS-Security not supported natively
 *
 * 2. Manual SOAP (raw XML):
 *    • Use when WSDL2Apex fails, the WSDL changes frequently, or fine-grained
 *      control is needed (custom SOAP headers, WS-Security, etc.)
 *    • Build XML string → HttpRequest with text/xml content type → parse response DOM
 *
 * SOAP VS REST:
 * ═════════════
 * SOAP                          REST
 * ────────────────────────────  ─────────────────────────────
 * Structured contract (WSDL)    No formal contract (OpenAPI optional)
 * XML only                      JSON, XML, others
 * Built-in standards (WS-Sec)   Auth via headers (Bearer, Basic)
 * Stateful operations possible  Stateless
 * Enterprise/legacy systems     Modern APIs
 *
 * GOVERNOR LIMITS:
 * Same as REST callouts — 100 per tx, 120s max timeout.
 */
public with sharing class SoapApiService {

    public class SoapFaultException extends Exception {
        public String faultCode;
        public String faultString;
        public SoapFaultException(String code, String message) {
            super('[' + code + '] ' + message);
            this.faultCode   = code;
            this.faultString = message;
        }
    }

    // SOAP 1.1 namespace (most enterprise systems use 1.1)
    private static final String SOAP_NS   = 'http://schemas.xmlsoap.org/soap/envelope/';
    private static final Integer TIMEOUT  = 30000;

    // ─────────────────────────────────────────────────────────────────────────
    // Generic SOAP sender
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Sends a raw SOAP envelope and returns the response XML body.
     * Use when WSDL2Apex is not feasible (complex/large WSDL, WS-Security, etc.).
     *
     * @param endpoint    Target service URL (or 'callout:NC_Name/path')
     * @param soapAction  SOAPAction header value (required by SOAP 1.1)
     * @param envelope    Full SOAP envelope XML string
     * @return            Raw XML response body string
     */
    public static String sendSoapRequest(
            String endpoint, String soapAction, String envelope) {

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '"' + soapAction + '"');  // SOAP 1.1 requires quoted value
        req.setTimeout(TIMEOUT);
        req.setBody(envelope);

        HttpResponse resp = new Http().send(req);

        // SOAP faults are returned as HTTP 500 with a Fault element
        String respBody = resp.getBody();
        if (resp.getStatusCode() == 500 || respBody.contains('<soap:Fault>') || respBody.contains('<Fault>')) {
            parseSoapFaultAndThrow(respBody);
        }
        if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
            throw new SoapFaultException('HTTP_' + resp.getStatusCode(), resp.getBody());
        }
        return respBody;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Envelope builders
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Builds a SOAP 1.1 envelope string.
     *
     * @param targetNamespace  The service's target namespace (from WSDL targetNamespace)
     * @param operationName    SOAP operation name (maps to the method name in WSDL)
     * @param bodyParams       Map of parameter name → value to include in the body
     */
    public static String buildEnvelope(
            String targetNamespace, String operationName,
            Map<String, String> bodyParams) {

        String params = '';
        if (bodyParams != null) {
            for (String key : bodyParams.keySet()) {
                String value = bodyParams.get(key);
                // Escape XML special characters to prevent injection
                params += '<' + key + '>' + escapeXml(value) + '</' + key + '>';
            }
        }

        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soap:Envelope'
            + '  xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"'
            + '  xmlns:tns="' + escapeXml(targetNamespace) + '">'
            + '  <soap:Header/>'
            + '  <soap:Body>'
            + '    <tns:' + operationName + '>'
            + params
            + '    </tns:' + operationName + '>'
            + '  </soap:Body>'
            + '</soap:Envelope>';
    }

    /**
     * Builds a SOAP envelope with a WS-Security UsernameToken header.
     * Required by older enterprise services that don't support OAuth.
     */
    public static String buildEnvelopeWithSecurity(
            String targetNamespace, String operationName,
            Map<String, String> bodyParams, String username, String password) {

        String params = '';
        if (bodyParams != null) {
            for (String key : bodyParams.keySet()) {
                params += '<' + key + '>' + escapeXml(bodyParams.get(key)) + '</' + key + '>';
            }
        }

        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soap:Envelope'
            + '  xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"'
            + '  xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"'
            + '  xmlns:tns="' + escapeXml(targetNamespace) + '">'
            + '  <soap:Header>'
            + '    <wsse:Security>'
            + '      <wsse:UsernameToken>'
            + '        <wsse:Username>' + escapeXml(username) + '</wsse:Username>'
            + '        <wsse:Password>' + escapeXml(password) + '</wsse:Password>'
            + '      </wsse:UsernameToken>'
            + '    </wsse:Security>'
            + '  </soap:Header>'
            + '  <soap:Body>'
            + '    <tns:' + operationName + '>'
            + params
            + '    </tns:' + operationName + '>'
            + '  </soap:Body>'
            + '</soap:Envelope>';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DOM response parsing
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Parses a SOAP response using the Apex DOM API.
     * Returns a map of the first-level child element names → text content
     * within the operation response element.
     *
     * @param xmlBody         Raw SOAP XML response string
     * @param responseElement The expected response wrapper element name (e.g. 'getAccountResponse')
     * @param responseNs      Namespace of the response element
     */
    public static Map<String, String> parseSoapResponse(
            String xmlBody, String responseElement, String responseNs) {

        Dom.Document doc  = new Dom.Document();
        doc.load(xmlBody);

        Dom.XmlNode envelope = doc.getRootElement();
        // Navigate: Envelope → Body → OperationResponse
        Dom.XmlNode body = envelope.getChildElement('Body', SOAP_NS);
        if (body == null) {
            throw new SoapFaultException('PARSE_ERROR', 'No soap:Body found in response');
        }
        Dom.XmlNode opResponse = body.getChildElement(responseElement, responseNs);
        if (opResponse == null) {
            throw new SoapFaultException('PARSE_ERROR',
                'Expected <' + responseElement + '> not found in Body');
        }

        Map<String, String> result = new Map<String, String>();
        for (Dom.XmlNode child : opResponse.getChildElements()) {
            result.put(child.getName(), child.getText());
        }
        return result;
    }

    /**
     * Extracts text content of a named element anywhere in the response using XPath-style traversal.
     */
    public static String extractElement(String xmlBody, String elementName, String namespace) {
        Dom.Document doc = new Dom.Document();
        doc.load(xmlBody);
        Dom.XmlNode node = findElement(doc.getRootElement(), elementName, namespace);
        return node != null ? node.getText() : null;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WSDL2Apex stub invocation pattern (illustration)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Demonstrates how to invoke a WSDL2Apex-generated stub.
     *
     * WSDL2Apex PROCESS:
     *  1. Setup → Apex Classes → Generate from WSDL
     *  2. Upload your WSDL file
     *  3. Salesforce generates:
     *       - <ServiceName>.cls          — type classes (request/response DTOs)
     *       - <ServiceName>Stub.cls      — the callout stub
     *       - <ServiceName>AsyncStub.cls — for async callout (Apex Continuation)
     *
     * GENERATED STUB USAGE (AccountServiceStub is hypothetical):
     *
     *   AccountServiceStub stub = new AccountServiceStub();
     *   stub.endpoint_x = 'callout:My_Named_Credential';  // override endpoint
     *   stub.timeout_x  = 30000;
     *
     *   AccountService.GetAccountRequest req = new AccountService.GetAccountRequest();
     *   req.accountId = '001000000000001';
     *
     *   AccountService.GetAccountResponse resp = stub.getAccount(req);
     *   System.debug(resp.account.Name);
     *
     * STUB INTERNALS:
     *   The generated stub calls WebServiceCallout.invoke() which handles:
     *   - XML serialization of the request object
     *   - HTTP POST with correct SOAP headers
     *   - XML deserialization of the response
     *   - SOAP fault detection → throws CalloutException
     *
     * WS-SECURITY LIMITATION:
     *   WSDL2Apex-generated stubs do NOT support WS-Security natively.
     *   Use the manual envelope approach (buildEnvelopeWithSecurity) for WS-Sec.
     */
    public static String getStubInvocationPattern() {
        return 'See class-level Javadoc for WSDL2Apex usage pattern.';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static void parseSoapFaultAndThrow(String xmlBody) {
        try {
            Dom.Document doc   = new Dom.Document();
            doc.load(xmlBody);
            Dom.XmlNode root   = doc.getRootElement();
            Dom.XmlNode body   = root.getChildElement('Body', SOAP_NS);
            Dom.XmlNode fault  = body != null ? body.getChildElement('Fault', SOAP_NS) : null;

            // SOAP 1.1 Fault is NOT namespace-qualified inside Body
            if (fault == null && body != null) {
                fault = body.getChildElement('Fault', null);
            }

            if (fault != null) {
                Dom.XmlNode codeNode   = fault.getChildElement('faultcode',   null);
                Dom.XmlNode stringNode = fault.getChildElement('faultstring', null);
                String code   = codeNode   != null ? codeNode.getText()   : 'UNKNOWN';
                String detail = stringNode != null ? stringNode.getText() : xmlBody.abbreviate(300);
                throw new SoapFaultException(code, detail);
            }
        } catch (SoapFaultException rethrow) {
            throw rethrow;
        } catch (Exception e) {
            // DOM parse failed — surface raw body
        }
        throw new SoapFaultException('SOAP_FAULT', xmlBody.abbreviate(500));
    }

    private static Dom.XmlNode findElement(Dom.XmlNode node, String name, String ns) {
        if (node.getName() == name && (ns == null || node.getNamespace() == ns)) {
            return node;
        }
        for (Dom.XmlNode child : node.getChildElements()) {
            Dom.XmlNode found = findElement(child, name, ns);
            if (found != null) { return found; }
        }
        return null;
    }

    private static String escapeXml(String input) {
        if (input == null) { return ''; }
        return input
            .replace('&',  '&amp;')
            .replace('<',  '&lt;')
            .replace('>',  '&gt;')
            .replace('"',  '&quot;')
            .replace('\'', '&apos;');
    }
}
