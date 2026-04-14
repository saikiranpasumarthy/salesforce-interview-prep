/**
 * @description Asynchronous Queueable that handles the REST callout to the
 *              external ERP system for order synchronisation.
 *
 *              Triggered by:
 *                Order_Submitted__e Platform Event subscriber
 *                (or direct System.enqueueJob in tests)
 *
 *              Pattern:
 *                POST callout:RetailERP_API/orders
 *                ├── 200/201 → OrderCaptureService.handleERPResponse(Success)
 *                ├── 5xx     → Retry once (enqueue new ERPSyncService instance)
 *                └── 4xx / timeout / 2nd 5xx → Terminal failure
 *                      → OrderCaptureService.handleERPResponse(Failed)
 *                      → Integration_Error_Log__c record
 *
 *              Idempotency:
 *                Before calling out, guard checks ERP_Sync_Status__c == 'Synced'.
 *                ERP endpoint uses salesforceOrderId as idempotency key.
 *
 *              Named Credential: RetailERP_API
 *                Configured in org — no endpoint or credentials in code.
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
public with sharing class ERPSyncService implements Queueable, Database.AllowsCallouts {

    // ─── Constants ────────────────────────────────────────────────────────────
    private static final String  NC_BASE      = 'callout:RetailERP_API';
    private static final String  ORDERS_PATH  = '/orders';
    private static final Integer TIMEOUT_MS   = 30000;  // 30 seconds
    private static final Integer MAX_RETRIES  = 1;

    // ─── Instance State ───────────────────────────────────────────────────────
    private final Id      orderId;
    private final Integer retryCount;

    // ─── Constructors ─────────────────────────────────────────────────────────
    public ERPSyncService(Id orderId) {
        this(orderId, 0);
    }

    public ERPSyncService(Id orderId, Integer retryCount) {
        this.orderId    = orderId;
        this.retryCount = retryCount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EXECUTE — Queueable entry point
    // ─────────────────────────────────────────────────────────────────────────
    public void execute(QueueableContext context) {
        // ── 1. Query Order + OrderItems ───────────────────────────────────────
        Order order;
        try {
            order = [
                SELECT Id, OrderNumber, AccountId, Account.Name,
                       TotalAmount, ERP_Sync_Status__c, ERP_Order_Id__c,
                       (SELECT Id, Product2Id, Product2.ProductCode,
                               Quantity, UnitPrice, TotalPrice
                        FROM   OrderItems)
                FROM   Order
                WHERE  Id = :orderId
                WITH   USER_MODE
                LIMIT  1
            ];
        } catch (QueryException ex) {
            logError(orderId, 'Order not found — cannot sync to ERP. ' + ex.getMessage(), null);
            return;
        }

        // ── 2. Idempotency guard ──────────────────────────────────────────────
        if (order.ERP_Sync_Status__c == 'Synced') {
            System.debug(
                'ERPSyncService — Order ' + orderId +
                ' already synced (ERP_Sync_Status__c = Synced). Skipping.'
            );
            return;
        }

        // ── 3. Build payload ──────────────────────────────────────────────────
        String requestBody = buildPayload(order);

        // ── 4. HTTP callout ───────────────────────────────────────────────────
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC_BASE + ORDERS_PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept',       'application/json');
        req.setBody(requestBody);
        req.setTimeout(TIMEOUT_MS);

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException ex) {
            // Network-level failure (timeout, DNS, etc.)
            handleFailure('Callout exception: ' + ex.getMessage(), null);
            return;
        }

        Integer statusCode = res.getStatusCode();

        // ── 5. Handle response ────────────────────────────────────────────────
        if (statusCode >= 200 && statusCode < 300) {
            // Success
            Map<String, Object> body =
                (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String erpOrderId = (String) body.get('erpOrderId');

            OrderCaptureService.handleERPResponse(
                orderId, erpOrderId, 'Success',
                'ERP sync successful. ERP Order ID: ' + erpOrderId
            );

        } else if (statusCode >= 500 && retryCount < MAX_RETRIES) {
            // Server error — retry once
            System.debug(
                'ERPSyncService — HTTP ' + statusCode + ' on attempt ' +
                (retryCount + 1) + '. Enqueuing retry.'
            );
            System.enqueueJob(new ERPSyncService(orderId, retryCount + 1));

        } else {
            // Terminal failure (4xx, or 5xx after max retries)
            handleFailure(
                'HTTP ' + statusCode + ' (attempt ' + (retryCount + 1) + '): ' +
                res.getBody()?.abbreviate(1000),
                res
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE — buildPayload
    // Constructs the ERP JSON request body from Order and OrderItems
    // ─────────────────────────────────────────────────────────────────────────
    private static String buildPayload(Order order) {
        List<Map<String, Object>> lineItems = new List<Map<String, Object>>();
        for (OrderItem oi : order.OrderItems) {
            lineItems.add(new Map<String, Object>{
                'productCode' => oi.Product2.ProductCode,
                'quantity'    => oi.Quantity,
                'unitPrice'   => oi.UnitPrice,
                'totalPrice'  => oi.TotalPrice
            });
        }

        return JSON.serialize(new Map<String, Object>{
            'salesforceOrderId' => order.Id,
            'orderNumber'       => order.OrderNumber,
            'storeId'           => order.AccountId,
            'storeName'         => order.Account.Name,
            'totalAmount'       => order.TotalAmount,
            'lineItems'         => lineItems
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE — handleFailure
    // Updates order to Failed status, logs to Integration_Error_Log__c
    // ─────────────────────────────────────────────────────────────────────────
    private void handleFailure(String errorMessage, HttpResponse res) {
        OrderCaptureService.handleERPResponse(orderId, null, 'Failed', errorMessage);
        logError(orderId, errorMessage, res);
    }

    private static void logError(Id orderId, String message, HttpResponse res) {
        Integration_Error_Log__c log = new Integration_Error_Log__c();
        log.Record_Id__c         = orderId;
        log.Error_Message__c     = message;
        log.Integration_Type__c  = 'ERP Order Sync';
        log.Http_Status_Code__c  = (res != null) ? String.valueOf(res.getStatusCode()) : null;
        log.Response_Body__c     = (res != null) ? res.getBody()?.left(32768) : null;
        log.Occurred_At__c       = Datetime.now();

        List<Database.SaveResult> results = Database.insert(
            new List<Integration_Error_Log__c>{ log }, false
        );
        if (!results[0].isSuccess()) {
            System.debug(LoggingLevel.ERROR,
                'ERPSyncService — Integration_Error_Log__c insert failed: ' +
                results[0].getErrors());
        }
    }
}
