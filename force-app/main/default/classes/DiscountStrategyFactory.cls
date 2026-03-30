/**
 * @description Factory that resolves the correct IDiscountStrategy implementation
 *              based on the Discount_Strategy_Config__mdt record for a given
 *              Opportunity.Type.
 *
 *              Factory Pattern responsibilities:
 *                1. Load CMDT config (once per transaction, cached in a static Map)
 *                2. Match the Opportunity.Type to a Strategy_Class_Name__c value
 *                3. Instantiate the correct IDiscountStrategy via Type.forName()
 *                4. Return a safe default (TieredDiscountStrategy) when no match
 *
 *              Why Type.forName() instead of if/else?
 *                Adding a new strategy class requires only a new CMDT record.
 *                The factory code itself never changes — satisfying Open/Closed Principle.
 *                If forName() returns null (typo in CMDT), getStrategy() returns the
 *                default and logs a warning rather than throwing — defensive programming.
 *
 *              Why @TestVisible on the cache map?
 *                Tests inject CMDT records via setConfigsForTest() without deploying to org.
 *                This mirrors the TestDataFactory.getDefaultRatingConfigs() pattern from Day 1.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class DiscountStrategyFactory {

    // ─── Cache ───────────────────────────────────────────────────────────────────
    // Keyed by Opportunity_Type__c value (e.g. 'Existing Business', 'New Business')
    @TestVisible
    private static Map<String, Discount_Strategy_Config__mdt> configsByType;

    // ─── Test injection hook ──────────────────────────────────────────────────────
    /**
     * @description Replaces the CMDT cache with caller-supplied records.
     *              Call this in @IsTest methods before invoking getStrategy() so that
     *              no SOQL is issued and no org metadata is required.
     *
     * @param configs  Map of Opportunity_Type__c → CMDT record.
     */
    @TestVisible
    private static void setConfigsForTest(
            Map<String, Discount_Strategy_Config__mdt> configs) {
        configsByType = configs;
    }

    // ─── Public API ───────────────────────────────────────────────────────────────
    /**
     * @description Returns the IDiscountStrategy for the given Opportunity.Type.
     *              Falls back to TieredDiscountStrategy when no CMDT record exists.
     *
     * @param oppType  Value of Opportunity.Type (may be null).
     * @return         Instantiated IDiscountStrategy — never null.
     */
    public static IDiscountStrategy getStrategy(String oppType) {
        loadConfigs();

        if (String.isBlank(oppType) || !configsByType.containsKey(oppType)) {
            return new TieredDiscountStrategy();
        }

        Discount_Strategy_Config__mdt config = configsByType.get(oppType);
        return instantiate(config);
    }

    // ─── Private helpers ──────────────────────────────────────────────────────────
    private static void loadConfigs() {
        if (configsByType != null) return; // already loaded this transaction

        configsByType = new Map<String, Discount_Strategy_Config__mdt>();
        for (Discount_Strategy_Config__mdt cfg : [
            SELECT Opportunity_Type__c, Strategy_Class_Name__c, Flat_Rate__c
            FROM   Discount_Strategy_Config__mdt
            WHERE  IsActive__c = true
        ]) {
            configsByType.put(cfg.Opportunity_Type__c, cfg);
        }
    }

    /**
     * @description Instantiates the strategy using Type.forName().
     *              Handles FlatRateDiscountStrategy specially — it requires constructor
     *              injection of the flat rate. All other strategies use a no-arg constructor.
     *
     * @param config  CMDT record with Strategy_Class_Name__c and Flat_Rate__c.
     * @return        Instantiated IDiscountStrategy or TieredDiscountStrategy as default.
     */
    private static IDiscountStrategy instantiate(
            Discount_Strategy_Config__mdt config) {

        String className = config.Strategy_Class_Name__c;

        if (className == FlatRateDiscountStrategy.class.getName()) {
            return new FlatRateDiscountStrategy(config.Flat_Rate__c);
        }

        Type t = Type.forName(className);
        if (t == null) {
            System.debug(LoggingLevel.WARN,
                'DiscountStrategyFactory: unknown class "' + className
                + '" — defaulting to TieredDiscountStrategy');
            return new TieredDiscountStrategy();
        }
        return (IDiscountStrategy) t.newInstance();
    }
}
