/**
 * @description Service layer for in-visit order creation and ERP synchronisation.
 *
 *              Three core responsibilities:
 *
 *              1. createOrderFromVisit — creates an Order linked to the Visit's
 *                 Account with correct regional PriceBook (from PriceBook_Config__mdt)
 *                 and OrderItem records for each captured product quantity.
 *                 Returns the created Order Id.
 *
 *              2. submitOrderToERP — publishes Order_Submitted__e Platform Event
 *                 so ERPSyncService (Queueable) handles the callout asynchronously.
 *                 No synchronous callout; decouples UI response from ERP latency.
 *
 *              3. handleERPResponse — called by ERPSyncService after the callout
 *                 resolves. Updates Order ERP fields and creates a Task for the
 *                 Operations Team when sync fails.
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
public with sharing class OrderCaptureService {

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 1 — createOrderFromVisit
    //
    // Input:  visitId               — parent RetailVisit__c record
    //         productQuantities     — Map<Product2Id, quantity>
    //
    // Steps:
    //   a) Query visit + store region
    //   b) Resolve PriceBook from PriceBook_Config__mdt by region
    //   c) Query PricebookEntry for all products in that PriceBook
    //   d) Insert Order, then bulk-insert OrderItems
    //
    // Returns the Id of the created Order.
    // ─────────────────────────────────────────────────────────────────────────
    public static Id createOrderFromVisit(Id visitId, Map<Id, Integer> productQuantities) {
        if (visitId == null) {
            throw new OrderCaptureException('createOrderFromVisit — visitId is required.');
        }
        if (productQuantities == null || productQuantities.isEmpty()) {
            throw new OrderCaptureException('createOrderFromVisit — productQuantities cannot be empty.');
        }

        // ── a) Query visit and store ──────────────────────────────────────────
        RetailVisit__c visit = [
            SELECT Id, Name, Store__c, Store__r.Region__c, OwnerId
            FROM   RetailVisit__c
            WHERE  Id = :visitId
            WITH   USER_MODE
            LIMIT 1
        ];

        // ── b) Resolve regional PriceBook from Custom Metadata ───────────────
        String region = visit.Store__r.Region__c;
        PriceBook_Config__mdt pbConfig = (String.isNotBlank(region))
            ? PriceBook_Config__mdt.getInstance(region)
            : null;

        Id priceBookId;
        if (pbConfig != null && String.isNotBlank(pbConfig.Pricebook_Id__c)) {
            priceBookId = pbConfig.Pricebook_Id__c;
        } else {
            // Fall back to standard PriceBook — works in test context too
            priceBookId = [
                SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1
            ].Id;
        }

        // ── c) Query PricebookEntries ─────────────────────────────────────────
        Set<Id> productIds = productQuantities.keySet();
        Map<Id, PricebookEntry> pbeMap = new Map<Id, PricebookEntry>();

        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, UnitPrice
            FROM   PricebookEntry
            WHERE  Pricebook2Id = :priceBookId
              AND  Product2Id   IN :productIds
              AND  IsActive      = true
            WITH   USER_MODE
        ]) {
            pbeMap.put(pbe.Product2Id, pbe);
        }

        // ── d) Insert Order ───────────────────────────────────────────────────
        Order order = new Order();
        order.AccountId          = visit.Store__c;
        order.Visit__c           = visitId;
        order.Status             = 'Draft';
        order.EffectiveDate      = Date.today();
        order.Pricebook2Id       = priceBookId;
        order.ERP_Sync_Status__c = 'Pending';

        List<Database.SaveResult> orderResults = Database.insert(
            new List<Order>{ order }, false
        );
        if (!orderResults[0].isSuccess()) {
            throw new OrderCaptureException(
                'Order creation failed: ' + orderResults[0].getErrors()
            );
        }
        Id orderId = orderResults[0].getId();

        // ── Insert OrderItems ─────────────────────────────────────────────────
        List<OrderItem> lineItems = new List<OrderItem>();
        for (Id productId : productQuantities.keySet()) {
            PricebookEntry pbe = pbeMap.get(productId);
            if (pbe == null) {
                System.debug(LoggingLevel.WARN,
                    'OrderCaptureService — no PricebookEntry for product ' + productId +
                    ' in PriceBook ' + priceBookId + '. Skipping line item.');
                continue;
            }
            OrderItem oi       = new OrderItem();
            oi.OrderId         = orderId;
            oi.Product2Id      = productId;
            oi.PricebookEntryId = pbe.Id;
            oi.Quantity        = productQuantities.get(productId);
            oi.UnitPrice       = pbe.UnitPrice;
            lineItems.add(oi);
        }

        if (!lineItems.isEmpty()) {
            for (Database.SaveResult sr : Database.insert(lineItems, false)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'OrderCaptureService — OrderItem insert failed: ' + sr.getErrors());
                }
            }
        }

        return orderId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 2 — submitOrderToERP
    //
    // Input:  List<Order> — orders whose status just changed to Submitted
    //
    // Publishes Order_Submitted__e Platform Event per order.
    // ERPSyncService (Queueable) subscribes via CometD / trigger subscriber
    // and performs the actual callout asynchronously.
    //
    // WHY Platform Event instead of direct callout:
    //   • Trigger context prohibits callouts
    //   • Decouples rep's UI response from ERP latency
    //   • Platform Events are at-least-once — no silent drops
    //   • Event replay allows Operations to replay failed syncs
    // ─────────────────────────────────────────────────────────────────────────
    public static void submitOrderToERP(List<Order> orders) {
        if (orders == null || orders.isEmpty()) return;

        // Query full line-item count needed for event payload
        Set<Id> orderIds = new Set<Id>();
        for (Order o : orders) orderIds.add(o.Id);

        Map<Id, Integer> lineCountMap = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT OrderId, COUNT(Id) lineCount
            FROM   OrderItem
            WHERE  OrderId IN :orderIds
            GROUP BY OrderId
            WITH   USER_MODE
        ]) {
            lineCountMap.put((Id) ar.get('OrderId'), (Integer) ar.get('lineCount'));
        }

        List<Order_Submitted__e> events = new List<Order_Submitted__e>();
        for (Order o : orders) {
            events.add(new Order_Submitted__e(
                Order_Id__c        = o.Id,
                Store_Id__c        = o.AccountId,
                Total_Amount__c    = o.TotalAmount,
                Line_Item_Count__c = lineCountMap.containsKey(o.Id)
                    ? lineCountMap.get(o.Id) : 0
            ));
        }

        for (Database.SaveResult sr : EventBus.publish(events)) {
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'OrderCaptureService — Order_Submitted__e publish failed: ' + sr.getErrors());
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 3 — handleERPResponse
    //
    // Called by ERPSyncService after the ERP callout resolves.
    // Updates Order ERP tracking fields.
    // On failure: creates a High-priority Task for the Operations Team.
    // ─────────────────────────────────────────────────────────────────────────
    public static void handleERPResponse(
        Id     orderId,
        String erpOrderId,
        String status,      // 'Success' or 'Failed'
        String message
    ) {
        if (orderId == null) {
            System.debug(LoggingLevel.ERROR,
                'OrderCaptureService.handleERPResponse — orderId is null.');
            return;
        }

        Boolean isSuccess = (status == 'Success');

        Order order = new Order(
            Id                   = orderId,
            ERP_Order_Id__c      = erpOrderId,
            ERP_Sync_Status__c   = isSuccess ? 'Synced' : 'Failed',
            ERP_Sync_Message__c  = message,
            ERP_Sync_DateTime__c = Datetime.now()
        );

        List<Database.SaveResult> results = Database.update(
            new List<Order>{ order }, false
        );
        if (!results[0].isSuccess()) {
            System.debug(LoggingLevel.ERROR,
                'OrderCaptureService — ERP response Order update failed: ' + results[0].getErrors());
            return;
        }

        // Create investigation Task for Operations Team on failure
        if (!isSuccess) {
            Task t        = new Task();
            t.Subject     = 'ERP Sync Failure — Investigate Order ' + orderId;
            t.WhatId      = orderId;
            t.Status      = 'Not Started';
            t.Priority    = 'High';
            t.ActivityDate = Date.today();
            t.Description =
                'ERP synchronisation failed for Order: ' + orderId +
                '\n\nError Message:\n' + message +
                '\n\nERP Order ID Attempted: ' + (String.isNotBlank(erpOrderId) ? erpOrderId : 'N/A') +
                '\n\nAction Required:\n' +
                '1. Review the Integration_Error_Log__c record for full HTTP details.\n' +
                '2. Confirm the ERP system status.\n' +
                '3. Manually resubmit the order once the ERP system is available.';

            for (Database.SaveResult sr : Database.insert(new List<Task>{ t }, false)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'OrderCaptureService — Operations Task insert failed: ' + sr.getErrors());
                }
            }
        }
    }

    // ─── Inner Exception ──────────────────────────────────────────────────────
    public class OrderCaptureException extends Exception {}
}
