/**
 * @description Quote-to-Cash service — standard Salesforce Quote object patterns,
 *              product catalog management, price book operations, and quote lifecycle.
 *
 *              QUOTE-TO-CASH OBJECT MODEL (interview framework):
 *
 *              Opportunity
 *                └── Quote                  (price proposal sent to customer)
 *                      └── QuoteLineItem    (one line per product + price)
 *                            └── PricebookEntry (links Product2 → Pricebook2 → price)
 *
 *              Product2          — master product catalogue
 *              Pricebook2        — price list (Standard, Partner, Regional, etc.)
 *              PricebookEntry    — price of a Product2 in a specific Pricebook2
 *
 *              Order             — confirmed sale (converted from Quote or Opportunity)
 *                └── OrderItem   — one line per product
 *
 *              Contract          — executed legal agreement (linked to Account)
 *
 *              KEY RULES:
 *                - Opportunity.Pricebook2Id must be set before adding OpportunityLineItems
 *                - Quote sync: when Quote.IsSyncing=true, changes to QuoteLineItems
 *                  automatically sync back to Opportunity.Amount
 *                - Only ONE Quote per Opportunity can have IsSyncing=true at a time
 *                - A Quote must be accepted (IsAccepted=true or via approval) before
 *                  it can be converted to an Order
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class QuoteService {

    // ─── Product catalog ──────────────────────────────────────────────────────

    /**
     * Returns all active products from the standard Pricebook with their list price.
     *
     * Interview: PricebookEntry connects Product2 to a Pricebook2.
     * Every org has one Standard Pricebook (IsStandard=true).
     * Products must have an entry in the Standard Pricebook before they can
     * be added to any custom Pricebook.
     *
     * @param searchTerm  Optional product name filter; null returns all active products
     */
    public static List<PricebookEntry> getStandardPricebookProducts(String searchTerm) {
        Id stdPricebookId = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        if (String.isBlank(searchTerm)) {
            return [
                SELECT Id, Product2Id, Product2.Name, Product2.Description,
                       Product2.Family, UnitPrice, IsActive
                FROM   PricebookEntry
                WHERE  Pricebook2Id = :stdPricebookId
                  AND  IsActive     = true
                ORDER BY Product2.Name ASC
            ];
        }
        String pattern = '%' + searchTerm + '%';
        return [
            SELECT Id, Product2Id, Product2.Name, Product2.Description,
                   Product2.Family, UnitPrice, IsActive
            FROM   PricebookEntry
            WHERE  Pricebook2Id    = :stdPricebookId
              AND  IsActive        = true
              AND  Product2.Name LIKE :pattern
            ORDER BY Product2.Name ASC
        ];
    }

    /**
     * Returns all active custom Pricebooks (excluding Standard).
     * Used to populate the pricebook selector when creating an Opportunity/Quote.
     */
    public static List<Pricebook2> getCustomPricebooks() {
        return [
            SELECT Id, Name, Description, IsActive
            FROM   Pricebook2
            WHERE  IsStandard = false
              AND  IsActive   = true
            ORDER BY Name ASC
        ];
    }

    // ─── Quote creation ───────────────────────────────────────────────────────

    /**
     * Creates a Quote for an Opportunity with an optional set of line items.
     *
     * Sets IsSyncing=true so Quote Amount stays in sync with Opportunity Amount.
     * Only one Quote per Opportunity can have IsSyncing=true — this method
     * deactivates sync on any existing syncing quote before enabling it on the new one.
     *
     * @param opportunityId   Opportunity the Quote belongs to
     * @param quoteName       Quote name/title
     * @param expirationDate  Quote validity deadline
     * @param lineItems       Optional initial line items (product + quantity + price)
     * @return                Newly created Quote Id
     */
    public static Id createQuote(
            Id opportunityId, String quoteName, Date expirationDate,
            List<QuoteLineItemRequest> lineItems) {

        // Deactivate sync on any existing syncing quote
        List<Quote> syncingQuotes = [
            SELECT Id FROM Quote
            WHERE  OpportunityId = :opportunityId AND IsSyncing = true
        ];
        if (!syncingQuotes.isEmpty()) {
            for (Quote q : syncingQuotes) { q.IsSyncing = false; }
            update syncingQuotes;
        }

        Quote q = new Quote(
            OpportunityId  = opportunityId,
            Name           = quoteName,
            ExpirationDate = expirationDate,
            IsSyncing      = true,
            Status         = 'Draft'
        );
        insert q;

        if (lineItems != null && !lineItems.isEmpty()) {
            addLineItems(q.Id, lineItems);
        }
        return q.Id;
    }

    /**
     * Adds QuoteLineItems to an existing Quote.
     *
     * Interview: QuoteLineItem.PricebookEntryId must match the Pricebook2Id
     * on the linked Opportunity. Mixing entries from different pricebooks throws
     * a DML exception.
     *
     * @param quoteId    Quote to add lines to
     * @param requests   Line item requests (pricebookEntryId + quantity + unitPrice)
     */
    public static void addLineItems(Id quoteId, List<QuoteLineItemRequest> requests) {
        List<QuoteLineItem> items = new List<QuoteLineItem>();
        for (QuoteLineItemRequest req : requests) {
            items.add(new QuoteLineItem(
                QuoteId          = quoteId,
                PricebookEntryId = req.pricebookEntryId,
                Quantity         = req.quantity,
                UnitPrice        = req.unitPrice,
                Description      = req.description
            ));
        }
        insert items;
    }

    // ─── Quote lifecycle ──────────────────────────────────────────────────────

    /**
     * Marks a Quote as accepted — prerequisite before converting to an Order.
     *
     * Interview: Setting Status='Accepted' alone is not always enough — many orgs
     * configure an Approval Process that must complete before conversion is allowed.
     * The Approval Process gates the transition programmatically.
     *
     * @param quoteId  Quote to accept
     */
    public static void acceptQuote(Id quoteId) {
        update new Quote(Id = quoteId, Status = 'Accepted');
    }

    /**
     * Converts an accepted Quote into an Order.
     *
     * Standard platform supports Quote → Order conversion via UI.
     * This Apex pattern handles the programmatic equivalent:
     *   1. Read Quote + QuoteLineItems
     *   2. Read the Opportunity's Pricebook2Id
     *   3. Create Order + OrderItems
     *
     * @param quoteId  Accepted Quote to convert
     * @return         Newly created Order Id
     */
    public static Id convertQuoteToOrder(Id quoteId) {
        Quote q = [
            SELECT Id, OpportunityId, Name, AccountId, Pricebook2Id,
                   ExpirationDate, IsSyncing
            FROM   Quote
            WHERE  Id = :quoteId
        ];

        List<QuoteLineItem> lines = [
            SELECT PricebookEntryId, Quantity, UnitPrice, Description
            FROM   QuoteLineItem
            WHERE  QuoteId = :quoteId
        ];

        Order ord = new Order(
            OpportunityId  = q.OpportunityId,
            AccountId      = q.AccountId,
            Pricebook2Id   = q.Pricebook2Id,
            Name           = 'Order - ' + q.Name,
            EffectiveDate  = Date.today(),
            Status         = 'Draft',
            QuoteId        = quoteId
        );
        insert ord;

        List<OrderItem> orderItems = new List<OrderItem>();
        for (QuoteLineItem qli : lines) {
            orderItems.add(new OrderItem(
                OrderId          = ord.Id,
                PricebookEntryId = qli.PricebookEntryId,
                Quantity         = qli.Quantity,
                UnitPrice        = qli.UnitPrice,
                Description      = qli.Description
            ));
        }
        if (!orderItems.isEmpty()) { insert orderItems; }

        return ord.Id;
    }

    // ─── Quote queries ────────────────────────────────────────────────────────

    /**
     * Returns all Quotes for an Opportunity with their line item totals.
     *
     * @param opportunityId  Opportunity to retrieve quotes for
     */
    public static List<Quote> getQuotesForOpportunity(Id opportunityId) {
        return [
            SELECT Id, Name, Status, IsSyncing, ExpirationDate,
                   TotalPrice, GrandTotal, CreatedDate,
                   (SELECT Id, Product2.Name, Quantity, UnitPrice, TotalPrice
                    FROM   QuoteLineItems
                    ORDER BY CreatedDate ASC)
            FROM   Quote
            WHERE  OpportunityId = :opportunityId
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Returns Quotes expiring within the next N days — used for proactive renewal alerts.
     *
     * @param daysUntilExpiry  Flag quotes expiring within this window
     */
    public static List<Quote> getExpiringQuotes(Integer daysUntilExpiry) {
        Date threshold = Date.today().addDays(daysUntilExpiry);
        return [
            SELECT Id, Name, Status, ExpirationDate, OpportunityId,
                   Opportunity.Name, Opportunity.AccountId
            FROM   Quote
            WHERE  Status         != 'Accepted'
              AND  Status         != 'Denied'
              AND  ExpirationDate <= :threshold
              AND  ExpirationDate >= TODAY
            ORDER BY ExpirationDate ASC
        ];
    }

    // ─── Approval process submission ──────────────────────────────────────────

    /**
     * Submits a Quote for approval via the standard Approval Process API.
     *
     * Interview: Approval.ProcessSubmitRequest — key fields:
     *   setObjectId()     — the record to submit
     *   setSubmitterId()  — user submitting (defaults to running user)
     *   setComments()     — submission comments
     *   setProcessDefinitionNameOrId() — target a specific approval process by name
     *
     * Approval.ProcessResult — key fields:
     *   isSuccess()       — true if successfully submitted
     *   getNewWorkitemIds() — list of new WorkItem Ids created
     *   getErrors()       — list of ProcessResultError if failed
     *
     * @param quoteId   Quote to submit for approval
     * @param comments  Submitter comments
     * @return          ProcessResult for caller to inspect
     */
    public static Approval.ProcessResult submitForApproval(Id quoteId, String comments) {
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(quoteId);
        req.setComments(String.isBlank(comments) ? 'Submitted for approval' : comments);
        return Approval.process(req);
    }

    /**
     * Approves or rejects a pending approval WorkItem.
     *
     * @param workItemId  ProcessWorkitem Id from getNewWorkitemIds()
     * @param approve     true = approve; false = reject
     * @param comments    Approver comments
     * @return            ProcessResult for the approval action
     */
    public static Approval.ProcessResult processApprovalDecision(
            Id workItemId, Boolean approve, String comments) {
        Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
        req.setWorkitemId(workItemId);
        req.setAction(approve ? 'Approve' : 'Reject');
        req.setComments(comments);
        return Approval.process(req);
    }

    // ─── Request DTO ──────────────────────────────────────────────────────────

    public class QuoteLineItemRequest {
        public Id      pricebookEntryId;
        public Decimal quantity;
        public Decimal unitPrice;
        public String  description;

        public QuoteLineItemRequest(Id pbeId, Decimal qty, Decimal price, String desc) {
            this.pricebookEntryId = pbeId;
            this.quantity         = qty;
            this.unitPrice        = price;
            this.description      = desc;
        }
    }
}
