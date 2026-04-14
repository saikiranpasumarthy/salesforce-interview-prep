/**
 * @description Configurable HttpCalloutMock for ERP REST callouts.
 *              Supports four mock types used across all test classes
 *              that exercise ERPSyncService or any method that makes
 *              a callout to the RetailERP_API Named Credential.
 *
 *              Usage in tests:
 *                Test.setMock(HttpCalloutMock.class, new ERPCalloutMock(ERPCalloutMock.MockType.SUCCESS));
 *                Test.setMock(HttpCalloutMock.class, new ERPCalloutMock(ERPCalloutMock.MockType.FAILURE_500));
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
@isTest
public class ERPCalloutMock implements HttpCalloutMock {

    // ─── Mock Response Types ───────────────────────────────────────────────────
    public enum MockType {
        SUCCESS,       // 200 — ERP accepted the order, returns erpOrderId
        FAILURE_500,   // 500 — ERP server error, triggers retry logic
        FAILURE_400,   // 400 — Bad request, terminal failure (no retry)
        TIMEOUT        // 408 — Simulated request timeout
    }

    private MockType mockType;
    private String   erpOrderId;

    // ─── Constructors ─────────────────────────────────────────────────────────
    public ERPCalloutMock(MockType type) {
        this(type, 'ERP-TEST-' + String.valueOf(System.currentTimeMillis()).right(8));
    }

    public ERPCalloutMock(MockType type, String erpOrderId) {
        this.mockType   = type;
        this.erpOrderId = erpOrderId;
    }

    // ─── HttpCalloutMock Implementation ───────────────────────────────────────
    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        switch on mockType {
            when SUCCESS {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'erpOrderId' => erpOrderId,
                    'status'     => 'ACCEPTED',
                    'message'    => 'Order received and queued for processing'
                }));
            }
            when FAILURE_500 {
                res.setStatusCode(500);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'error'   => 'INTERNAL_SERVER_ERROR',
                    'message' => 'ERP system temporarily unavailable — please retry'
                }));
            }
            when FAILURE_400 {
                res.setStatusCode(400);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'error'   => 'BAD_REQUEST',
                    'message' => 'Invalid order payload — missing required field: productCode'
                }));
            }
            when TIMEOUT {
                res.setStatusCode(408);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'error'   => 'REQUEST_TIMEOUT',
                    'message' => 'ERP did not respond within the 30-second timeout window'
                }));
            }
        }

        return res;
    }

    // ─── Convenience Accessors (for assertion in tests) ───────────────────────
    public String getErpOrderId() {
        return erpOrderId;
    }
}
