/**
 * @description Tests for OrderCaptureService and ERPSyncService.
 *
 *              Coverage targets (85%+):
 *                OrderCaptureService  — 95%+ (all three public methods)
 *                ERPSyncService       — 90%+ (success + terminal failure paths)
 *
 *              Test strategy:
 *                • createOrderFromVisit: tests Order + OrderItem creation and
 *                  PriceBook fallback when PriceBook_Config__mdt is absent
 *                  (standard in test context — no Custom Metadata deployed).
 *                • ERP callout tests use ERPCalloutMock with SUCCESS and
 *                  FAILURE_400 (terminal — no retry) to cover both branches
 *                  without waiting for a retry Queueable chain.
 *                • For ERPSyncService, full Order with Account + OrderItems +
 *                  Product2.ProductCode is required — mirrors the real
 *                  relationship query in the Queueable.
 *                • handleERPResponse tested directly (not via Queueable) to
 *                  isolate DML logic from callout mock complexity.
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
@isTest
private class OrderCaptureServiceTest {

    // ── Shared Test Data ─────────────────────────────────────────────────────
    @testSetup
    static void setup() {
        // Store Account
        Account store = new Account(Name = 'Test Store — Orders');
        insert store;

        // Products with ProductCode (required by ERPSyncService payload)
        List<Product2> products = new List<Product2>{
            new Product2(Name = 'Widget A', ProductCode = 'WGT-A001', IsActive = true),
            new Product2(Name = 'Widget B', ProductCode = 'WGT-B002', IsActive = true)
        };
        insert products;

        // PricebookEntries against Standard Pricebook
        Id stdPbId = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = stdPbId,
                Product2Id   = products[0].Id,
                UnitPrice    = 49.99,
                IsActive     = true
            ),
            new PricebookEntry(
                Pricebook2Id = stdPbId,
                Product2Id   = products[1].Id,
                UnitPrice    = 89.99,
                IsActive     = true
            )
        };
        insert pbes;

        // RetailVisit__c linked to the store
        RetailVisit__c visit = new RetailVisit__c(
            Store__c                 = store.Id,
            Status__c                = 'In Progress',
            PlannedVisitStartTime__c = Datetime.now()
        );
        insert visit;
    }

    // ─── Data Helpers ─────────────────────────────────────────────────────────
    static Account getStore() {
        return [SELECT Id FROM Account WHERE Name = 'Test Store — Orders' LIMIT 1];
    }

    static List<Product2> getProducts() {
        return [SELECT Id FROM Product2 WHERE ProductCode IN ('WGT-A001','WGT-B002')];
    }

    static RetailVisit__c getVisit() {
        return [SELECT Id, Store__c FROM RetailVisit__c LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — createOrderFromVisit: creates Order and correct OrderItems
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testCreateOrderFromVisit_createsOrderAndLineItems() {
        RetailVisit__c  visit    = getVisit();
        List<Product2>  products = getProducts();

        Map<Id, Integer> quantities = new Map<Id, Integer>{
            products[0].Id => 10,
            products[1].Id => 5
        };

        Test.startTest();
        Id orderId = OrderCaptureService.createOrderFromVisit(visit.Id, quantities);
        Test.stopTest();

        System.assertNotEquals(null, orderId,
            'createOrderFromVisit should return a non-null Order Id.');

        Order o = [
            SELECT Id, AccountId, Status, Visit__c, Pricebook2Id
            FROM   Order
            WHERE  Id = :orderId
        ];
        System.assertEquals(visit.Store__c, o.AccountId,
            'Order should be linked to the visit store Account.');
        System.assertEquals('Draft', o.Status,
            'New orders should have Status = Draft.');
        System.assertEquals(visit.Id, o.Visit__c,
            'Order should be linked to the originating Visit.');

        List<OrderItem> lineItems = [
            SELECT Id, Quantity, UnitPrice
            FROM   OrderItem
            WHERE  OrderId = :orderId
        ];
        System.assertEquals(2, lineItems.size(),
            'Should create 2 OrderItems — one per product.');

        // Verify quantities
        Map<Decimal, Integer> qtyByUnitPrice = new Map<Decimal, Integer>();
        for (OrderItem li : lineItems) {
            qtyByUnitPrice.put(li.UnitPrice, (Integer) li.Quantity);
        }
        System.assertEquals(10, qtyByUnitPrice.get(49.99),
            'Widget A (UnitPrice 49.99) should have Quantity = 10.');
        System.assertEquals(5, qtyByUnitPrice.get(89.99),
            'Widget B (UnitPrice 89.99) should have Quantity = 5.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — createOrderFromVisit: applies correct PriceBook
    //
    // PriceBook_Config__mdt is not deployed in test context → service falls
    // back to the Standard PriceBook. Verify Order.Pricebook2Id matches.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testCreateOrderFromVisit_appliesCorrectPriceBook() {
        RetailVisit__c visit   = getVisit();
        List<Product2> products = getProducts();

        Test.startTest();
        Id orderId = OrderCaptureService.createOrderFromVisit(
            visit.Id, new Map<Id, Integer>{ products[0].Id => 3 }
        );
        Test.stopTest();

        Order o = [SELECT Pricebook2Id FROM Order WHERE Id = :orderId];

        // When Custom Metadata is absent, service queries Pricebook2 WHERE IsStandard = true
        Id expectedPbId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        System.assertEquals(expectedPbId, o.Pricebook2Id,
            'Order should use the Standard PriceBook when no PriceBook_Config__mdt is present.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — submitOrderToERP: publishes Order_Submitted__e Platform Event
    //
    // Platform Event publish is verified by absence of exception. In test
    // context events are buffered — delivery is not testable without a
    // trigger subscriber. Coverage of EventBus.publish() call is confirmed
    // by line coverage.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testSubmitOrderToERP_publishesPlatformEvent() {
        RetailVisit__c  visit    = getVisit();
        List<Product2>  products = getProducts();

        // Create a complete Order with OrderItem
        Id stdPbId = Test.getStandardPricebookId();
        Order o    = new Order(
            AccountId       = visit.Store__c,
            Status          = 'Draft',
            EffectiveDate   = Date.today(),
            Pricebook2Id    = stdPbId,
            Visit__c        = visit.Id
        );
        insert o;

        PricebookEntry pbe = [
            SELECT Id FROM PricebookEntry
            WHERE  Pricebook2Id = :stdPbId
              AND  Product2Id   = :products[0].Id
            LIMIT 1
        ];
        insert new OrderItem(
            OrderId          = o.Id,
            Product2Id       = products[0].Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 5,
            UnitPrice        = 49.99
        );

        Test.startTest();
        // submitOrderToERP expects List<Order>; a queried Order has TotalAmount
        List<Order> orders = [SELECT Id, AccountId, TotalAmount FROM Order WHERE Id = :o.Id];
        Boolean exceptionThrown = false;
        try {
            OrderCaptureService.submitOrderToERP(orders);
        } catch (Exception ex) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(!exceptionThrown,
            'submitOrderToERP should publish platform event without throwing an exception.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — handleERPResponse: success path updates all ERP fields on Order
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testHandleERPResponse_success_updatesOrder() {
        Account store  = getStore();
        Id stdPbId     = Test.getStandardPricebookId();

        Order o = new Order(
            AccountId      = store.Id,
            Status         = 'Draft',
            EffectiveDate  = Date.today(),
            Pricebook2Id   = stdPbId,
            ERP_Sync_Status__c = 'Pending'
        );
        insert o;

        Test.startTest();
        OrderCaptureService.handleERPResponse(
            o.Id, 'ERP-ORDER-9999', 'Success', 'Synced successfully.'
        );
        Test.stopTest();

        Order result = [
            SELECT ERP_Order_Id__c, ERP_Sync_Status__c,
                   ERP_Sync_Message__c, ERP_Sync_DateTime__c
            FROM   Order
            WHERE  Id = :o.Id
        ];

        System.assertEquals('ERP-ORDER-9999', result.ERP_Order_Id__c,
            'ERP_Order_Id__c should be set to the value returned by ERP.');
        System.assertEquals('Synced', result.ERP_Sync_Status__c,
            'ERP_Sync_Status__c should be Synced on success.');
        System.assertEquals('Synced successfully.', result.ERP_Sync_Message__c,
            'ERP_Sync_Message__c should record the ERP response message.');
        System.assertNotEquals(null, result.ERP_Sync_DateTime__c,
            'ERP_Sync_DateTime__c should be populated.');

        // No failure Task should exist
        Integer failureTasks = [SELECT COUNT() FROM Task WHERE WhatId = :o.Id];
        System.assertEquals(0, failureTasks,
            'No failure investigation Task should be created on success.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5 — handleERPResponse: failure path creates Operations Team Task
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testHandleERPResponse_failure_createsTask() {
        Account store = getStore();
        Id stdPbId    = Test.getStandardPricebookId();

        Order o = new Order(
            AccountId      = store.Id,
            Status         = 'Draft',
            EffectiveDate  = Date.today(),
            Pricebook2Id   = stdPbId,
            ERP_Sync_Status__c = 'Pending'
        );
        insert o;

        Test.startTest();
        OrderCaptureService.handleERPResponse(
            o.Id, null, 'Failed', 'HTTP 500 — ERP server unavailable.'
        );
        Test.stopTest();

        Order result = [
            SELECT ERP_Sync_Status__c, ERP_Order_Id__c
            FROM   Order
            WHERE  Id = :o.Id
        ];
        System.assertEquals('Failed', result.ERP_Sync_Status__c,
            'ERP_Sync_Status__c should be Failed.');
        System.assertEquals(null, result.ERP_Order_Id__c,
            'ERP_Order_Id__c should be null on failure (no ERP ID returned).');

        List<Task> failureTasks = [
            SELECT Id, Subject, Priority, Description
            FROM   Task
            WHERE  WhatId = :o.Id
        ];
        System.assertEquals(1, failureTasks.size(),
            'Exactly 1 investigation Task should be created on ERP sync failure.');
        System.assertEquals('High', failureTasks[0].Priority,
            'Failure investigation Task should be High priority.');
        System.assert(
            failureTasks[0].Subject.containsIgnoreCase('ERP Sync Failure'),
            'Task subject should reference ERP Sync Failure.');
        System.assert(
            failureTasks[0].Description.contains('HTTP 500'),
            'Task description should include the error message.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 6 — ERPSyncService: callout success → Order updated to Synced
    //
    // Uses ERPCalloutMock(SUCCESS) — Queueable runs synchronously within
    // Test.startTest()/stopTest() block.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testERPSync_calloutSuccess() {
        Account        store    = getStore();
        List<Product2> products = getProducts();
        Id stdPbId              = Test.getStandardPricebookId();

        // Build a complete Order matching ERPSyncService SOQL (Account.Name required)
        Order o = new Order(
            AccountId          = store.Id,
            Status             = 'Draft',
            EffectiveDate      = Date.today(),
            Pricebook2Id       = stdPbId,
            ERP_Sync_Status__c = 'Pending'
        );
        insert o;

        PricebookEntry pbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND Product2Id = :products[0].Id LIMIT 1
        ];
        insert new OrderItem(
            OrderId          = o.Id,
            Product2Id       = products[0].Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 8,
            UnitPrice        = 49.99
        );

        String mockErpId = 'ERP-MOCK-12345';
        Test.setMock(HttpCalloutMock.class, new ERPCalloutMock(
            ERPCalloutMock.MockType.SUCCESS, mockErpId
        ));

        Test.startTest();
        System.enqueueJob(new ERPSyncService(o.Id));
        Test.stopTest();  // Forces synchronous Queueable execution

        Order result = [
            SELECT ERP_Sync_Status__c, ERP_Order_Id__c
            FROM   Order
            WHERE  Id = :o.Id
        ];

        System.assertEquals('Synced', result.ERP_Sync_Status__c,
            'ERP_Sync_Status__c should be Synced after successful callout.');
        System.assertEquals(mockErpId, result.ERP_Order_Id__c,
            'ERP_Order_Id__c should match the erpOrderId returned by the mock.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 7 — ERPSyncService: callout failure → Integration_Error_Log__c
    //
    // Uses ERPCalloutMock(FAILURE_400) — 400 is a terminal failure (no retry),
    // so the Queueable logs the error and does not re-enqueue.
    // Verifies both Order.ERP_Sync_Status__c = Failed AND
    // Integration_Error_Log__c record created.
    // ─────────────────────────────────────────────────────────────────────────
    @isTest
    static void testERPSync_calloutFailure_logsError() {
        Account        store    = getStore();
        List<Product2> products = getProducts();
        Id stdPbId              = Test.getStandardPricebookId();

        Order o = new Order(
            AccountId          = store.Id,
            Status             = 'Draft',
            EffectiveDate      = Date.today(),
            Pricebook2Id       = stdPbId,
            ERP_Sync_Status__c = 'Pending'
        );
        insert o;

        PricebookEntry pbe = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPbId AND Product2Id = :products[1].Id LIMIT 1
        ];
        insert new OrderItem(
            OrderId          = o.Id,
            Product2Id       = products[1].Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 3,
            UnitPrice        = 89.99
        );

        // FAILURE_400 = bad request, terminal failure (no retry enqueued)
        Test.setMock(HttpCalloutMock.class, new ERPCalloutMock(
            ERPCalloutMock.MockType.FAILURE_400
        ));

        Test.startTest();
        System.enqueueJob(new ERPSyncService(o.Id));
        Test.stopTest();

        // Order should be marked Failed
        Order result = [
            SELECT ERP_Sync_Status__c, ERP_Order_Id__c
            FROM   Order
            WHERE  Id = :o.Id
        ];
        System.assertEquals('Failed', result.ERP_Sync_Status__c,
            'ERP_Sync_Status__c should be Failed after 400 response.');
        System.assertEquals(null, result.ERP_Order_Id__c,
            'ERP_Order_Id__c should be null — ERP rejected the request.');

        // Integration error log should be created
        List<Integration_Error_Log__c> logs = [
            SELECT Id, Record_Id__c, Integration_Type__c, Http_Status_Code__c
            FROM   Integration_Error_Log__c
            WHERE  Record_Id__c = :o.Id
        ];
        System.assertEquals(1, logs.size(),
            'Exactly 1 Integration_Error_Log__c record should be created on terminal failure.');
        System.assertEquals('ERP Order Sync', logs[0].Integration_Type__c,
            'Integration_Type__c should identify the ERP sync process.');
        System.assertEquals('400', logs[0].Http_Status_Code__c,
            'Http_Status_Code__c should record the HTTP 400 response code.');

        // Operations Team Task should also be created (via handleERPResponse)
        List<Task> opsTasks = [SELECT Id FROM Task WHERE WhatId = :o.Id];
        System.assertEquals(1, opsTasks.size(),
            'One investigation Task should be created for Operations Team on failure.');
    }
}
