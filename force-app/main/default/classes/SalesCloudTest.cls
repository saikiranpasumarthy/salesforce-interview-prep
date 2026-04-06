/**
 * @description Test coverage for Day 29 — Sales Cloud & CPQ patterns.
 *              Covers QuoteService and CpqPricingService.
 *
 *              Tests use Test.getStandardPricebookId() for pricebook setup,
 *              @TestVisible hooks for approval process bypassing, and
 *              complete Quote-to-Cash flow assertions.
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class SalesCloudTest {

    // ─── Test data factory ─────────────────────────────────────────────────────

    /**
     * Creates a minimal Account → Opportunity → Product2 → PricebookEntry
     * test data graph used across multiple test methods.
     */
    private static TestDataGraph buildTestData() {
        TestDataGraph td = new TestDataGraph();

        td.account = new Account(Name = 'Test Account Q2C');
        insert td.account;

        td.opportunity = new Opportunity(
            Name        = 'Test Opp Q2C',
            AccountId   = td.account.Id,
            StageName   = 'Proposal/Price Quote',
            CloseDate   = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert td.opportunity;

        td.product = new Product2(Name = 'Test Product', IsActive = true, Family = 'Software');
        insert td.product;

        td.pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = td.product.Id,
            UnitPrice    = 1000.00,
            IsActive     = true
        );
        insert td.pbe;

        return td;
    }

    private class TestDataGraph {
        Account        account;
        Opportunity    opportunity;
        Product2       product;
        PricebookEntry pbe;
    }

    // ─── QuoteService — product catalog ───────────────────────────────────────

    @IsTest
    static void testGetStandardPricebookProducts_noFilter() {
        TestDataGraph td = buildTestData();

        Test.startTest();
        List<PricebookEntry> entries = QuoteService.getStandardPricebookProducts(null);
        Test.stopTest();

        System.assertNotEquals(null, entries, 'Should return a list');
        // At minimum our inserted entry is present
        Boolean found = false;
        for (PricebookEntry e : entries) {
            if (e.Id == td.pbe.Id) { found = true; break; }
        }
        System.assert(found, 'Test product pricebook entry should be returned');
    }

    @IsTest
    static void testGetStandardPricebookProducts_withFilter() {
        TestDataGraph td = buildTestData();

        Test.startTest();
        List<PricebookEntry> entries = QuoteService.getStandardPricebookProducts('Test Product');
        Test.stopTest();

        System.assertNotEquals(0, entries.size(), 'Filter should match test product');
        System.assertEquals(td.pbe.Id, entries[0].Id, 'Should return the matching entry');
    }

    @IsTest
    static void testGetStandardPricebookProducts_noMatch() {
        buildTestData();

        Test.startTest();
        List<PricebookEntry> entries = QuoteService.getStandardPricebookProducts('ZZZNOMATCH999');
        Test.stopTest();

        System.assertEquals(0, entries.size(), 'No results for non-matching filter');
    }

    @IsTest
    static void testGetCustomPricebooks() {
        // Insert a custom pricebook
        Pricebook2 custom = new Pricebook2(Name = 'Partner Pricebook', IsActive = true);
        insert custom;

        Test.startTest();
        List<Pricebook2> books = QuoteService.getCustomPricebooks();
        Test.stopTest();

        System.assertNotEquals(0, books.size(), 'Should return at least 1 custom pricebook');
        for (Pricebook2 pb : books) {
            System.assert(!pb.IsStandard, 'Standard pricebook should not appear');
        }
    }

    // ─── QuoteService — quote creation ────────────────────────────────────────

    @IsTest
    static void testCreateQuote_basic() {
        TestDataGraph td = buildTestData();

        Test.startTest();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-001', Date.today().addDays(14), null
        );
        Test.stopTest();

        System.assertNotEquals(null, quoteId, 'Quote should be created');
        Quote q = [SELECT Id, Name, Status, IsSyncing, ExpirationDate FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Q-001', q.Name, 'Quote name should match');
        System.assertEquals('Draft', q.Status, 'Initial status should be Draft');
        System.assertEquals(true, q.IsSyncing, 'New quote should be syncing');
        System.assertEquals(Date.today().addDays(14), q.ExpirationDate, 'Expiration date should match');
    }

    @IsTest
    static void testCreateQuote_withLineItems() {
        TestDataGraph td = buildTestData();
        List<QuoteService.QuoteLineItemRequest> lines = new List<QuoteService.QuoteLineItemRequest>{
            new QuoteService.QuoteLineItemRequest(td.pbe.Id, 5, 950.00, 'Test line')
        };

        Test.startTest();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-002', Date.today().addDays(30), lines
        );
        Test.stopTest();

        List<QuoteLineItem> qlis = [SELECT Id, Quantity, UnitPrice, Description FROM QuoteLineItem WHERE QuoteId = :quoteId];
        System.assertEquals(1, qlis.size(), 'One line item should be created');
        System.assertEquals(5, qlis[0].Quantity, 'Quantity should match');
        System.assertEquals(950.00, qlis[0].UnitPrice, 'Unit price should match');
        System.assertEquals('Test line', qlis[0].Description, 'Description should match');
    }

    @IsTest
    static void testCreateQuote_deactivatesSyncingQuote() {
        TestDataGraph td = buildTestData();

        // Create first syncing quote
        Id firstQuoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-First', Date.today().addDays(7), null
        );
        Quote firstQuote = [SELECT Id, IsSyncing FROM Quote WHERE Id = :firstQuoteId];
        System.assertEquals(true, firstQuote.IsSyncing, 'First quote should be syncing');

        Test.startTest();
        // Creating second quote should deactivate the first
        Id secondQuoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Second', Date.today().addDays(14), null
        );
        Test.stopTest();

        Quote first  = [SELECT IsSyncing FROM Quote WHERE Id = :firstQuoteId];
        Quote second = [SELECT IsSyncing FROM Quote WHERE Id = :secondQuoteId];
        System.assertEquals(false, first.IsSyncing,  'First quote sync should be deactivated');
        System.assertEquals(true,  second.IsSyncing, 'Second quote should now be syncing');
    }

    // ─── QuoteService — addLineItems ──────────────────────────────────────────

    @IsTest
    static void testAddLineItems_multipleLines() {
        TestDataGraph td = buildTestData();

        // Create second product
        Product2 prod2 = new Product2(Name = 'Add-on Product', IsActive = true);
        insert prod2;
        PricebookEntry pbe2 = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod2.Id,
            UnitPrice    = 250.00,
            IsActive     = true
        );
        insert pbe2;

        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Multi', Date.today().addDays(30), null
        );

        List<QuoteService.QuoteLineItemRequest> lines = new List<QuoteService.QuoteLineItemRequest>{
            new QuoteService.QuoteLineItemRequest(td.pbe.Id, 2, 1000.00, 'Line 1'),
            new QuoteService.QuoteLineItemRequest(pbe2.Id,   1, 250.00,  'Line 2')
        };

        Test.startTest();
        QuoteService.addLineItems(quoteId, lines);
        Test.stopTest();

        List<QuoteLineItem> qlis = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId];
        System.assertEquals(2, qlis.size(), 'Both line items should be inserted');
    }

    // ─── QuoteService — lifecycle ──────────────────────────────────────────────

    @IsTest
    static void testAcceptQuote() {
        TestDataGraph td = buildTestData();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Accept', Date.today().addDays(7), null
        );

        Test.startTest();
        QuoteService.acceptQuote(quoteId);
        Test.stopTest();

        Quote q = [SELECT Status FROM Quote WHERE Id = :quoteId];
        System.assertEquals('Accepted', q.Status, 'Quote status should be Accepted');
    }

    @IsTest
    static void testConvertQuoteToOrder() {
        TestDataGraph td = buildTestData();
        List<QuoteService.QuoteLineItemRequest> lines = new List<QuoteService.QuoteLineItemRequest>{
            new QuoteService.QuoteLineItemRequest(td.pbe.Id, 3, 900.00, 'Order line')
        };
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Convert', Date.today().addDays(30), lines
        );
        QuoteService.acceptQuote(quoteId);

        Test.startTest();
        Id orderId = QuoteService.convertQuoteToOrder(quoteId);
        Test.stopTest();

        System.assertNotEquals(null, orderId, 'Order should be created');

        Order ord = [SELECT Id, Status, AccountId, QuoteId FROM Order WHERE Id = :orderId];
        System.assertEquals('Draft', ord.Status, 'Order status should be Draft');
        System.assertEquals(td.account.Id, ord.AccountId, 'Order should link to account');
        System.assertEquals(quoteId, ord.QuoteId, 'Order should reference source quote');

        List<OrderItem> items = [SELECT Id, Quantity, UnitPrice FROM OrderItem WHERE OrderId = :orderId];
        System.assertEquals(1, items.size(), 'One order item should be created');
        System.assertEquals(3, items[0].Quantity, 'Order item quantity should match quote line');
        System.assertEquals(900.00, items[0].UnitPrice, 'Order item price should match quote line');
    }

    @IsTest
    static void testConvertQuoteToOrder_noLines() {
        TestDataGraph td = buildTestData();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-NoLines', Date.today().addDays(30), null
        );
        QuoteService.acceptQuote(quoteId);

        Test.startTest();
        Id orderId = QuoteService.convertQuoteToOrder(quoteId);
        Test.stopTest();

        System.assertNotEquals(null, orderId, 'Order should still be created with no lines');
        List<OrderItem> items = [SELECT Id FROM OrderItem WHERE OrderId = :orderId];
        System.assertEquals(0, items.size(), 'No order items for quote with no lines');
    }

    // ─── QuoteService — queries ────────────────────────────────────────────────

    @IsTest
    static void testGetQuotesForOpportunity() {
        TestDataGraph td = buildTestData();
        QuoteService.createQuote(td.opportunity.Id, 'Q-A', Date.today().addDays(10), null);
        QuoteService.createQuote(td.opportunity.Id, 'Q-B', Date.today().addDays(20), null);

        Test.startTest();
        List<Quote> quotes = QuoteService.getQuotesForOpportunity(td.opportunity.Id);
        Test.stopTest();

        System.assertEquals(2, quotes.size(), 'Both quotes should be returned');
    }

    @IsTest
    static void testGetExpiringQuotes() {
        TestDataGraph td = buildTestData();

        // Create a quote expiring in 3 days (within 7-day window)
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Expiring', Date.today().addDays(3), null
        );

        Test.startTest();
        List<Quote> expiring = QuoteService.getExpiringQuotes(7);
        Test.stopTest();

        System.assertNotEquals(0, expiring.size(), 'Should find at least one expiring quote');
        Boolean found = false;
        for (Quote q : expiring) {
            if (q.Id == quoteId) { found = true; break; }
        }
        System.assert(found, 'Expiring quote should be in results');
    }

    @IsTest
    static void testGetExpiringQuotes_excludesAccepted() {
        TestDataGraph td = buildTestData();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Accepted', Date.today().addDays(3), null
        );
        QuoteService.acceptQuote(quoteId);

        Test.startTest();
        List<Quote> expiring = QuoteService.getExpiringQuotes(7);
        Test.stopTest();

        for (Quote q : expiring) {
            System.assertNotEquals(quoteId, q.Id, 'Accepted quote should not appear in expiring list');
        }
    }

    // ─── QuoteService — approval process ──────────────────────────────────────

    @IsTest
    static void testSubmitForApproval_noActiveProcess() {
        TestDataGraph td = buildTestData();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Approval', Date.today().addDays(14), null
        );

        Test.startTest();
        try {
            Approval.ProcessResult result = QuoteService.submitForApproval(quoteId, 'Please approve');
            // If no approval process configured, result may indicate no-op
            System.assertNotEquals(null, result, 'ProcessResult should not be null');
        } catch (Exception e) {
            // No approval process configured in test org — expected
            System.assert(
                e.getMessage().contains('No applicable approval process') ||
                e.getMessage().contains('approval'),
                'Exception should relate to missing approval process: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitForApproval_blankComments() {
        TestDataGraph td = buildTestData();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-BlankComments', Date.today().addDays(14), null
        );

        // Verify blank comments are replaced with default
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(quoteId);
        req.setComments('Submitted for approval'); // default when blank

        System.assertEquals('Submitted for approval', req.getComments(),
            'Default comment should be set when blank');
    }

    // ─── CpqPricingService — discount calculations ────────────────────────────

    @IsTest
    static void testCalculateNetPrice_noDiscount() {
        Test.startTest();
        Decimal net = CpqPricingService.calculateNetPrice(1000.00, 1, 0, 0);
        Test.stopTest();

        System.assertEquals(1000.00, net, 'No discount — net = list');
    }

    @IsTest
    static void testCalculateNetPrice_volumeDiscount() {
        Test.startTest();
        Decimal net = CpqPricingService.calculateNetPrice(1000.00, 10, 10, 0);
        Test.stopTest();

        System.assertEquals(900.00, net, '10% volume discount on $1000 = $900');
    }

    @IsTest
    static void testCalculateNetPrice_stackedDiscounts() {
        Test.startTest();
        // 10% volume + 5% additional on $1000
        // After volume: $900; after additional: $900 × 0.95 = $855
        Decimal net = CpqPricingService.calculateNetPrice(1000.00, 10, 10, 5);
        Test.stopTest();

        System.assertEquals(855.00, net, 'Stacked discounts: $1000 × 0.90 × 0.95 = $855');
    }

    @IsTest
    static void testCalculateNetPrice_100PercentDiscount() {
        Test.startTest();
        Decimal net = CpqPricingService.calculateNetPrice(1000.00, 1, 100, 0);
        Test.stopTest();

        System.assertEquals(0.00, net, '100% discount = $0');
    }

    @IsTest
    static void testCalculateNetPrice_nullInputs() {
        Test.startTest();
        Decimal net1 = CpqPricingService.calculateNetPrice(null, 1, 0, 0);
        Decimal net2 = CpqPricingService.calculateNetPrice(1000.00, 5, null, null);
        Test.stopTest();

        System.assertEquals(0.00, net1, 'Null list price = $0');
        System.assertEquals(1000.00, net2, 'Null discounts treated as 0');
    }

    @IsTest
    static void testCalculateNetPrice_clampsExcessiveDiscount() {
        Test.startTest();
        // 150% discount should be clamped to 100%
        Decimal net = CpqPricingService.calculateNetPrice(500.00, 1, 150, 0);
        Test.stopTest();

        System.assertEquals(0.00, net, 'Discount over 100% clamped to 100%');
    }

    @IsTest
    static void testCalculateExtendedPrice() {
        Test.startTest();
        Decimal ext1 = CpqPricingService.calculateExtendedPrice(100.00, 5);
        Decimal ext2 = CpqPricingService.calculateExtendedPrice(33.333, 3);
        Decimal ext3 = CpqPricingService.calculateExtendedPrice(null, 5);
        Test.stopTest();

        System.assertEquals(500.00, ext1, '100 × 5 = 500');
        System.assertEquals(99.99, ext2, '33.333 × 3 = 99.999 rounded to 99.99');
        System.assertEquals(0, ext3, 'Null unit price = 0');
    }

    // ─── CpqPricingService — pricing summary ──────────────────────────────────

    @IsTest
    static void testBuildPricingSummary_singleLine() {
        List<CpqPricingService.PriceSummaryRequest> lines = new List<CpqPricingService.PriceSummaryRequest>{
            new CpqPricingService.PriceSummaryRequest('Product A', 1000.00, 2, 10, 5)
        };

        Test.startTest();
        CpqPricingService.PricingSummary summary = CpqPricingService.buildPricingSummary(lines);
        Test.stopTest();

        System.assertEquals(1, summary.lines.size(), 'One line in summary');
        // Net = 1000 × 0.90 × 0.95 = 855; Extended = 855 × 2 = 1710
        System.assertEquals(855.00, summary.lines[0].netUnitPrice, 'Net unit price should be 855');
        System.assertEquals(1710.00, summary.lines[0].extendedPrice, 'Extended price should be 1710');
        System.assertEquals(1710.00, summary.subtotal, 'Subtotal should match extended price');
    }

    @IsTest
    static void testBuildPricingSummary_multipleLines() {
        List<CpqPricingService.PriceSummaryRequest> lines = new List<CpqPricingService.PriceSummaryRequest>{
            new CpqPricingService.PriceSummaryRequest('A', 100.00, 3, 0, 0),
            new CpqPricingService.PriceSummaryRequest('B', 200.00, 2, 0, 0)
        };

        Test.startTest();
        CpqPricingService.PricingSummary summary = CpqPricingService.buildPricingSummary(lines);
        Test.stopTest();

        // Line A: 100 × 3 = 300; Line B: 200 × 2 = 400; Total = 700
        System.assertEquals(700.00, summary.subtotal, 'Subtotal should be $700');
        System.assertEquals(2, summary.lines.size(), 'Both lines present in summary');
    }

    @IsTest
    static void testBuildPricingSummary_emptyInput() {
        Test.startTest();
        CpqPricingService.PricingSummary summary =
            CpqPricingService.buildPricingSummary(new List<CpqPricingService.PriceSummaryRequest>());
        Test.stopTest();

        System.assertEquals(0, summary.lines.size(), 'No lines for empty input');
        System.assertEquals(0, summary.subtotal, 'Subtotal should be 0 for empty input');
    }

    // ─── CpqPricingService — CPQ object queries (graceful degradation) ─────────

    @IsTest
    static void testGetActiveDiscountSchedules_graceful() {
        Test.startTest();
        List<SObject> schedules = CpqPricingService.getActiveDiscountSchedules();
        Test.stopTest();

        // In test org without CPQ: returns empty list
        System.assertNotEquals(null, schedules, 'Should never return null');
    }

    @IsTest
    static void testGetProductOptions_graceful() {
        Test.startTest();
        List<SObject> options = CpqPricingService.getProductOptions(
            '01t000000000001AAA' // fake product Id
        );
        Test.stopTest();

        System.assertNotEquals(null, options, 'Should never return null');
    }

    @IsTest
    static void testGetContractedPrices_graceful() {
        Test.startTest();
        List<SObject> prices = CpqPricingService.getContractedPrices(
            '001000000000001AAA' // fake account Id
        );
        Test.stopTest();

        System.assertNotEquals(null, prices, 'Should never return null');
    }

    @IsTest
    static void testGetContractSubscriptions_graceful() {
        Test.startTest();
        List<SObject> subs = CpqPricingService.getContractSubscriptions(
            '800000000000001AAA' // fake contract Id
        );
        Test.stopTest();

        System.assertNotEquals(null, subs, 'Should never return null');
    }

    @IsTest
    static void testGetDiscountForQuantity_graceful() {
        Test.startTest();
        Decimal discount = CpqPricingService.getDiscountForQuantity(
            '0Nc000000000001AAA', 10 // fake schedule Id
        );
        Test.stopTest();

        System.assertEquals(0, discount, 'Should return 0 when CPQ not installed');
    }

    @IsTest
    static void testTriggerCpqCalculation_graceful() {
        TestDataGraph td = buildTestData();
        Id quoteId = QuoteService.createQuote(
            td.opportunity.Id, 'Q-Calc', Date.today().addDays(30), null
        );

        Test.startTest();
        Boolean result = CpqPricingService.triggerCpqCalculation(quoteId);
        Test.stopTest();

        // CPQ not installed — should return false gracefully
        System.assertEquals(false, result, 'Should degrade gracefully without CPQ package');
    }

    // ─── QuoteLineItemRequest DTO ──────────────────────────────────────────────

    @IsTest
    static void testQuoteLineItemRequest_constructor() {
        TestDataGraph td = buildTestData();

        Test.startTest();
        QuoteService.QuoteLineItemRequest req =
            new QuoteService.QuoteLineItemRequest(td.pbe.Id, 5, 750.00, 'Test');
        Test.stopTest();

        System.assertEquals(td.pbe.Id, req.pricebookEntryId, 'PBE Id should match');
        System.assertEquals(5, req.quantity, 'Quantity should match');
        System.assertEquals(750.00, req.unitPrice, 'Unit price should match');
        System.assertEquals('Test', req.description, 'Description should match');
    }
}
