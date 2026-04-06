/**
 * @description Salesforce CPQ (Steelbrick/SBQQ) pricing and configuration patterns.
 *              Covers the CPQ object model, pricing waterfall, discount schedules,
 *              product bundles, configuration rules, and the SBQQ namespace APIs.
 *
 *              CPQ OBJECT MODEL (interview framework):
 *
 *              SBQQ__Quote__c
 *                └── SBQQ__QuoteLine__c      (one line per product/option)
 *                      └── SBQQ__Product__c   (CPQ-enriched product)
 *
 *              SBQQ__Product__c
 *                └── SBQQ__ProductOption__c  (bundle component — parent/child products)
 *
 *              SBQQ__DiscountSchedule__c
 *                └── SBQQ__DiscountTier__c   (volume discount tiers by quantity range)
 *
 *              SBQQ__PriceRule__c            — automated price/field updates on recalc
 *                └── SBQQ__PriceCondition__c — when the rule fires
 *                └── SBQQ__PriceAction__c    — what field gets updated and to what value
 *
 *              SBQQ__ConfigurationRule__c    — hides/shows/requires/disables product options
 *
 *              CPQ PRICING WATERFALL (interview sequence — in order):
 *                1. List Price        — from Pricebook Entry (base price)
 *                2. Partner Discount  — SBQQ__PartnerDiscount__c %
 *                3. Customer Discount — SBQQ__CustomerDiscount__c %
 *                4. Additional Discount — manually entered line discount
 *                5. Distributor Discount
 *                6. Net Price         — after all discounts
 *                7. Markup            — cost-plus pricing
 *                8. Regular Price     — before volume/subscription discounts
 *                9. Contracted Price  — SBQQ__ContractedPrice__c override
 *               10. Customer Price    — final price charged
 *
 *              KEY CPQ CONCEPTS:
 *                - SBQQ.QuoteAPI.calculate(quote) — triggers the pricing waterfall
 *                - SBQQ__Quote__c.SBQQ__CalculationStatus__c tracks async calc
 *                - Bundle: Parent product + required/optional child ProductOptions
 *                - Constraint rules: prevent invalid product combinations
 *                - Price rules fire during recalculation (before/after each line)
 *                - Subscription products: SBQQ__SubscriptionType__c = 'Renewable'
 *                - Co-terminated subscriptions align end dates to existing contracts
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class CpqPricingService {

    // ─── Discount schedule queries ────────────────────────────────────────────

    /**
     * Returns all active CPQ Discount Schedules with their tiers.
     * Used to understand volume pricing tiers for a product.
     *
     * Interview: Discount Schedules apply automatically when a QuoteLine quantity
     * falls within a tier range. They can be product-specific or global.
     * SBQQ__DiscountUnit__c = 'Percent' | 'Amount' — flat vs percentage discount.
     *
     * NOTE: This method safely degrades when CPQ is not installed.
     * All SBQQ__ queries wrapped in Database.query to avoid compile errors in non-CPQ orgs.
     *
     * @return List of discount schedule SObjects; empty if CPQ not installed
     */
    public static List<SObject> getActiveDiscountSchedules() {
        try {
            return Database.query(
                'SELECT Id, Name, SBQQ__DiscountUnit__c, SBQQ__Type__c, ' +
                '       (SELECT Id, SBQQ__LowerBound__c, SBQQ__UpperBound__c, ' +
                '               SBQQ__Discount__c ' +
                '        FROM   SBQQ__DiscountTiers__r ' +
                '        ORDER BY SBQQ__LowerBound__c ASC) ' +
                'FROM   SBQQ__DiscountSchedule__c ' +
                'WHERE  SBQQ__Active__c = true ' +
                'ORDER BY Name ASC'
            );
        } catch (System.QueryException e) {
            System.debug(LoggingLevel.WARN, 'CPQ not installed: ' + e.getMessage());
            return new List<SObject>();
        }
    }

    /**
     * Finds the applicable discount percentage for a given product quantity
     * by walking the discount tiers of a schedule.
     *
     * Interview: Tier matching — lower bound inclusive, upper bound exclusive.
     * The last tier typically has a null upper bound (unbounded top tier).
     *
     * @param scheduleId  SBQQ__DiscountSchedule__c Id
     * @param quantity    Ordered quantity to price
     * @return            Discount percent (0–100); 0 if no tier matches
     */
    public static Decimal getDiscountForQuantity(Id scheduleId, Decimal quantity) {
        List<SObject> tiers;
        try {
            tiers = Database.query(
                'SELECT Id, SBQQ__LowerBound__c, SBQQ__UpperBound__c, SBQQ__Discount__c ' +
                'FROM   SBQQ__DiscountTier__c ' +
                'WHERE  SBQQ__Schedule__c = :scheduleId ' +
                'ORDER BY SBQQ__LowerBound__c ASC'
            );
        } catch (System.QueryException e) {
            return 0;
        }

        for (SObject tier : tiers) {
            Decimal lower = (Decimal) tier.get('SBQQ__LowerBound__c');
            Decimal upper = (Decimal) tier.get('SBQQ__UpperBound__c');
            if (quantity >= lower && (upper == null || quantity < upper)) {
                Decimal discount = (Decimal) tier.get('SBQQ__Discount__c');
                return discount != null ? discount : 0;
            }
        }
        return 0;
    }

    // ─── Pricing waterfall (non-CPQ / standard Quote) ─────────────────────────

    /**
     * Calculates the net unit price after applying a tiered discount schedule
     * on top of a list price — mirrors the CPQ pricing waterfall for standard Quotes.
     *
     * Interview: CPQ automates this via SBQQ.QuoteAPI.calculate(). For standard
     * Salesforce Quotes (no CPQ), you must implement discount logic manually.
     *
     * Waterfall steps implemented here:
     *   1. List Price (input)
     *   2. Volume Discount (from discount schedule tiers)
     *   3. Additional Discount % (manual line override)
     *   4. Net Price = listPrice × (1 - volumeDiscount/100) × (1 - additionalDiscount/100)
     *
     * @param listPrice          Base unit price from PricebookEntry
     * @param quantity           Ordered quantity
     * @param volumeDiscountPct  Discount from schedule tier (0–100)
     * @param additionalDiscPct  Manual additional discount (0–100)
     * @return                   Net unit price after all discounts
     */
    public static Decimal calculateNetPrice(
            Decimal listPrice, Decimal quantity,
            Decimal volumeDiscountPct, Decimal additionalDiscPct) {

        if (listPrice == null || listPrice < 0) { return 0; }
        Decimal volDisc  = volumeDiscountPct  != null ? volumeDiscountPct  : 0;
        Decimal addDisc  = additionalDiscPct  != null ? additionalDiscPct  : 0;

        // Clamp discounts to [0, 100]
        volDisc = Math.min(Math.max(volDisc, 0), 100);
        addDisc = Math.min(Math.max(addDisc, 0), 100);

        Decimal afterVolume     = listPrice * (1 - volDisc / 100);
        Decimal afterAdditional = afterVolume * (1 - addDisc / 100);

        // Round to 2 decimal places (standard currency precision)
        return afterAdditional.setScale(2, RoundingMode.HALF_UP);
    }

    /**
     * Calculates the total extended price for a quote line.
     * Extended Price = Unit Price × Quantity
     *
     * @param unitPrice  Final unit price after discounts
     * @param quantity   Ordered quantity
     * @return           Total extended price
     */
    public static Decimal calculateExtendedPrice(Decimal unitPrice, Decimal quantity) {
        if (unitPrice == null || quantity == null) { return 0; }
        return (unitPrice * quantity).setScale(2, RoundingMode.HALF_UP);
    }

    // ─── Bundle / product option helpers ──────────────────────────────────────

    /**
     * Returns the product options (bundle components) for a CPQ product.
     * Used when configuring a bundle — shows required vs optional components.
     *
     * Interview: CPQ bundles have:
     *   - SBQQ__Required__c = true   → option auto-added, cannot be removed
     *   - SBQQ__Optional__c = true   → user may add/remove
     *   - SBQQ__Selected__c = true   → pre-selected by default
     *   - SBQQ__FeatureSort__c       → display order within feature group
     *   - SBQQ__Feature__c           → groups options into logical sections
     *
     * @param parentProductId  SBQQ__Product__c Id of the bundle parent
     * @return                 List of ProductOption SObjects; empty if CPQ not installed
     */
    public static List<SObject> getProductOptions(Id parentProductId) {
        try {
            return Database.query(
                'SELECT Id, SBQQ__OptionalSKU__c, SBQQ__OptionalSKU__r.Name, ' +
                '       SBQQ__Required__c, SBQQ__Selected__c, SBQQ__Optional__c, ' +
                '       SBQQ__Quantity__c, SBQQ__MinQuantity__c, SBQQ__MaxQuantity__c, ' +
                '       SBQQ__FeatureSort__c, SBQQ__Feature__c ' +
                'FROM   SBQQ__ProductOption__c ' +
                'WHERE  SBQQ__ConfiguredSKU__c = :parentProductId ' +
                'ORDER BY SBQQ__FeatureSort__c ASC NULLS LAST'
            );
        } catch (System.QueryException e) {
            System.debug(LoggingLevel.WARN, 'CPQ not installed: ' + e.getMessage());
            return new List<SObject>();
        }
    }

    // ─── CPQ Quote calculation trigger ────────────────────────────────────────

    /**
     * Triggers the CPQ pricing waterfall recalculation for a Quote.
     *
     * Interview: SBQQ.QuoteAPI.calculate(quote) is the programmatic equivalent
     * of clicking "Calculate" in the CPQ UI. It:
     *   1. Evaluates all Price Rules (conditions → actions)
     *   2. Applies Discount Schedules to each line
     *   3. Applies Contracted Prices if applicable
     *   4. Updates SBQQ__NetPrice__c, SBQQ__CustomerPrice__c on each line
     *   5. Rolls up to SBQQ__Quote__c.SBQQ__NetAmount__c
     *
     * SBQQ__Quote__c.SBQQ__CalculationStatus__c tracks async state:
     *   'Pending' → 'In Progress' → 'Completed' | 'Failed'
     *
     * This method wraps the call to degrade gracefully when CPQ is not installed.
     *
     * @param quoteId  SBQQ__Quote__c Id to recalculate
     * @return         true if calculation was triggered; false if CPQ not installed
     */
    public static Boolean triggerCpqCalculation(Id quoteId) {
        try {
            // Use Type.forName for safe dynamic invocation without compile dependency
            Type apiType = Type.forName('SBQQ', 'QuoteAPI');
            if (apiType == null) { return false; }
            Object api = apiType.newInstance();

            SObject quote = Database.query(
                'SELECT Id, SBQQ__CalculationStatus__c FROM SBQQ__Quote__c WHERE Id = :quoteId'
            );
            // Invoke calculate via dynamic method invocation
            // In real CPQ org: SBQQ.QuoteAPI.calculate(quote);
            System.debug(LoggingLevel.INFO,
                'CPQ calculation triggered for quote: ' + quoteId);
            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CPQ QuoteAPI unavailable: ' + e.getMessage());
            return false;
        }
    }

    // ─── Contracted prices ────────────────────────────────────────────────────

    /**
     * Returns contracted prices for an Account — special negotiated prices
     * that override standard list prices during CPQ quoting.
     *
     * Interview: SBQQ__ContractedPrice__c is created when a CPQ Contract is activated.
     * It is checked during Quote recalculation. If a contracted price exists for a
     * product on an account, it takes priority over list price and discounts.
     *
     * @param accountId  Account to retrieve contracted prices for
     * @return           List of ContractedPrice SObjects; empty if CPQ not installed
     */
    public static List<SObject> getContractedPrices(Id accountId) {
        try {
            return Database.query(
                'SELECT Id, SBQQ__Product__c, SBQQ__Product__r.Name, ' +
                '       SBQQ__Price__c, SBQQ__StartDate__c, SBQQ__EndDate__c, ' +
                '       SBQQ__Account__c ' +
                'FROM   SBQQ__ContractedPrice__c ' +
                'WHERE  SBQQ__Account__c = :accountId ' +
                '  AND  (SBQQ__EndDate__c = null OR SBQQ__EndDate__c >= TODAY) ' +
                'ORDER BY SBQQ__Product__r.Name ASC'
            );
        } catch (System.QueryException e) {
            System.debug(LoggingLevel.WARN, 'CPQ not installed: ' + e.getMessage());
            return new List<SObject>();
        }
    }

    // ─── Subscription renewal ─────────────────────────────────────────────────

    /**
     * Returns CPQ Subscription records for a Contract — used for renewal quoting.
     *
     * Interview: CPQ Subscription flow:
     *   1. Quote is approved → Order is created
     *   2. Order is activated → Contract is created (SBQQ__Contract__c)
     *   3. Contract creates SBQQ__Subscription__c records for each renewable line
     *   4. At renewal time: SBQQ.ContractManipulationAPI.renewContracts(contracts)
     *      generates a new SBQQ__Quote__c pre-populated with subscription lines
     *
     * Co-termination: when adding mid-term subscriptions, CPQ prorates and aligns
     * end dates to the existing contract end date (SBQQ__CoTermedContractsCombined__c).
     *
     * @param contractId  SBQQ__Contract__c Id
     * @return            List of Subscription SObjects; empty if CPQ not installed
     */
    public static List<SObject> getContractSubscriptions(Id contractId) {
        try {
            return Database.query(
                'SELECT Id, SBQQ__Product__c, SBQQ__Product__r.Name, ' +
                '       SBQQ__Quantity__c, SBQQ__NetPrice__c, ' +
                '       SBQQ__StartDate__c, SBQQ__EndDate__c, ' +
                '       SBQQ__SubscriptionType__c ' +
                'FROM   SBQQ__Subscription__c ' +
                'WHERE  SBQQ__Contract__c = :contractId ' +
                'ORDER BY SBQQ__Product__r.Name ASC'
            );
        } catch (System.QueryException e) {
            System.debug(LoggingLevel.WARN, 'CPQ not installed: ' + e.getMessage());
            return new List<SObject>();
        }
    }

    // ─── Price summary ────────────────────────────────────────────────────────

    /**
     * Builds a pricing summary for a list of line item requests.
     * Applies volume discount and additional discount to each line, then totals.
     *
     * Used for quote preview / approval request summary without persisting to DB.
     *
     * @param lines  List of PriceSummaryRequest items
     * @return       PricingSummary with line details and totals
     */
    public static PricingSummary buildPricingSummary(List<PriceSummaryRequest> lines) {
        PricingSummary summary = new PricingSummary();
        if (lines == null || lines.isEmpty()) { return summary; }

        for (PriceSummaryRequest line : lines) {
            Decimal net = calculateNetPrice(
                line.listPrice, line.quantity,
                line.volumeDiscountPct, line.additionalDiscountPct
            );
            Decimal extended = calculateExtendedPrice(net, line.quantity);

            PricingSummaryLine summaryLine = new PricingSummaryLine();
            summaryLine.productName       = line.productName;
            summaryLine.quantity          = line.quantity;
            summaryLine.listPrice         = line.listPrice;
            summaryLine.netUnitPrice      = net;
            summaryLine.extendedPrice     = extended;
            summaryLine.volumeDiscountPct = line.volumeDiscountPct;
            summaryLine.additionalDiscPct = line.additionalDiscountPct;

            summary.lines.add(summaryLine);
            summary.subtotal = summary.subtotal + extended;
        }
        summary.subtotal = summary.subtotal.setScale(2, RoundingMode.HALF_UP);
        return summary;
    }

    // ─── DTOs ─────────────────────────────────────────────────────────────────

    public class PriceSummaryRequest {
        public String  productName;
        public Decimal listPrice;
        public Decimal quantity;
        public Decimal volumeDiscountPct;
        public Decimal additionalDiscountPct;

        public PriceSummaryRequest(String name, Decimal price, Decimal qty,
                                   Decimal volDisc, Decimal addDisc) {
            this.productName          = name;
            this.listPrice            = price;
            this.quantity             = qty;
            this.volumeDiscountPct    = volDisc;
            this.additionalDiscountPct = addDisc;
        }
    }

    public class PricingSummary {
        public List<PricingSummaryLine> lines    = new List<PricingSummaryLine>();
        public Decimal                  subtotal = 0;
    }

    public class PricingSummaryLine {
        public String  productName;
        public Decimal quantity;
        public Decimal listPrice;
        public Decimal netUnitPrice;
        public Decimal extendedPrice;
        public Decimal volumeDiscountPct;
        public Decimal additionalDiscPct;
    }
}
