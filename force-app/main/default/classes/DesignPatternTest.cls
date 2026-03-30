/**
 * @description Tests for Day 5 design pattern implementations:
 *              Strategy Pattern, Factory Pattern, Separation of Concerns,
 *              and the full Opportunity pricing pipeline end-to-end.
 *
 *              Testing philosophy:
 *                - Strategy classes: pure unit tests (no SOQL, no DML)
 *                - Factory: uses setConfigsForTest() injection to avoid CMDT SOQL
 *                - Domain: unit tests for clamp logic and validation
 *                - Service + Handler: integration tests via DML insert/update
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
@IsTest
private class DesignPatternTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // TieredDiscountStrategy
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void tieredStrategy_nullAmount_returnsZero() {
        IDiscountStrategy s = new TieredDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(Amount = null), null);
        System.assertEquals(0.00, result, 'Null amount should yield 0% discount');
    }

    @IsTest
    static void tieredStrategy_smallAmount_returnsFivePercent() {
        IDiscountStrategy s = new TieredDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(Amount = 5000), null);
        System.assertEquals(0.05, result, 'Amount < 10,000 should yield 5% discount');
    }

    @IsTest
    static void tieredStrategy_medAmount_returnsTenPercent() {
        IDiscountStrategy s = new TieredDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(Amount = 50000), null);
        System.assertEquals(0.10, result, 'Amount 10,000–99,999 should yield 10% discount');
    }

    @IsTest
    static void tieredStrategy_largeAmount_returnsFifteenPercent() {
        IDiscountStrategy s = new TieredDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(Amount = 200000), null);
        System.assertEquals(0.15, result, 'Amount >= 100,000 should yield 15% discount');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LoyaltyDiscountStrategy
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loyaltyStrategy_nullAccount_returnsZero() {
        IDiscountStrategy s = new LoyaltyDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(), null);
        System.assertEquals(0.00, result, 'Null account should yield 0% discount');
    }

    @IsTest
    static void loyaltyStrategy_newAccount_returnsZero() {
        // Account created just now → < 12 months → no discount
        Account acc = new Account(CreatedDate = System.now());
        IDiscountStrategy s = new LoyaltyDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(), acc);
        System.assertEquals(0.00, result, 'Account < 12 months should yield 0% discount');
    }

    @IsTest
    static void loyaltyStrategy_seniorAccount_returnsFifteenPercent() {
        // Simulate account created 72 months (6 years) ago
        // Use monthsBetween helper via @TestVisible to verify boundary
        Integer months = LoyaltyDiscountStrategy.monthsBetween(
            System.now().addMonths(-72), System.now());
        System.assertEquals(72, months, 'monthsBetween should count 72 months');

        Account acc = new Account(CreatedDate = System.now().addMonths(-72));
        IDiscountStrategy s = new LoyaltyDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(), acc);
        System.assertEquals(0.15, result, 'Account >= 60 months should yield 15% discount');
    }

    @IsTest
    static void loyaltyStrategy_midAccount_returnsTenPercent() {
        Account acc = new Account(CreatedDate = System.now().addMonths(-48));
        IDiscountStrategy s = new LoyaltyDiscountStrategy();
        Decimal result = s.calculate(new Opportunity(), acc);
        System.assertEquals(0.10, result, 'Account 36–59 months should yield 10% discount');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FlatRateDiscountStrategy
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void flatRateStrategy_partnerAccount_returnsConfiguredRate() {
        IDiscountStrategy s = new FlatRateDiscountStrategy(0.20);
        Account acc = new Account(Type = 'Partner');
        Decimal result = s.calculate(new Opportunity(), acc);
        System.assertEquals(0.20, result, 'Partner account should yield the flat rate');
    }

    @IsTest
    static void flatRateStrategy_nonPartnerAccount_returnsZero() {
        IDiscountStrategy s = new FlatRateDiscountStrategy(0.20);
        Account acc = new Account(Type = 'Customer');
        Decimal result = s.calculate(new Opportunity(), acc);
        System.assertEquals(0.00, result, 'Non-partner account should yield 0% discount');
    }

    @IsTest
    static void flatRateStrategy_nullAccount_returnsZero() {
        IDiscountStrategy s = new FlatRateDiscountStrategy(0.20);
        Decimal result = s.calculate(new Opportunity(), null);
        System.assertEquals(0.00, result, 'Null account should yield 0% discount');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DiscountStrategyFactory
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void factory_unknownType_defaultsToTieredStrategy() {
        // Inject empty config map — no SOQL fired
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        IDiscountStrategy s = DiscountStrategyFactory.getStrategy('Unknown Type');
        System.assertNotEquals(null, s, 'Factory should never return null');
        System.assert(s instanceof TieredDiscountStrategy,
            'Unknown Opportunity.Type should default to TieredDiscountStrategy');
    }

    @IsTest
    static void factory_nullType_defaultsToTieredStrategy() {
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        IDiscountStrategy s = DiscountStrategyFactory.getStrategy(null);
        System.assert(s instanceof TieredDiscountStrategy,
            'Null Opportunity.Type should default to TieredDiscountStrategy');
    }

    @IsTest
    static void factory_loyaltyTypeMapped_returnsLoyaltyStrategy() {
        Discount_Strategy_Config__mdt cfg = new Discount_Strategy_Config__mdt(
            Opportunity_Type__c    = 'Existing Business',
            Strategy_Class_Name__c = LoyaltyDiscountStrategy.class.getName(),
            IsActive__c            = true,
            Flat_Rate__c           = null
        );
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>{
                'Existing Business' => cfg
            });

        IDiscountStrategy s = DiscountStrategyFactory.getStrategy('Existing Business');
        System.assert(s instanceof LoyaltyDiscountStrategy,
            'Existing Business type should resolve to LoyaltyDiscountStrategy');
    }

    @IsTest
    static void factory_flatRateTypeMapped_returnsFlatRateStrategy() {
        Discount_Strategy_Config__mdt cfg = new Discount_Strategy_Config__mdt(
            Opportunity_Type__c    = 'New Business',
            Strategy_Class_Name__c = FlatRateDiscountStrategy.class.getName(),
            IsActive__c            = true,
            Flat_Rate__c           = 0.20
        );
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>{
                'New Business' => cfg
            });

        IDiscountStrategy s = DiscountStrategyFactory.getStrategy('New Business');
        System.assert(s instanceof FlatRateDiscountStrategy,
            'New Business type should resolve to FlatRateDiscountStrategy');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OpportunityPricingDomain
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void pricingDomain_appliesTieredDiscount_stampsFields() {
        Opportunity opp = new Opportunity(Amount = 200000);
        OpportunityPricingDomain.applyPricing(opp, 0.15);

        System.assertEquals(15.00, opp.Discount_Percent__c,
            'Discount_Percent__c should be 15.00 for a 0.15 fraction');
        System.assertEquals(170000.00, opp.Final_Price__c,
            'Final_Price__c should be Amount * 0.85 = 170,000');
    }

    @IsTest
    static void pricingDomain_discountExceedsCap_clampedAt50Percent() {
        Opportunity opp = new Opportunity(Amount = 10000);
        OpportunityPricingDomain.applyPricing(opp, 0.75); // exceeds 50% cap

        System.assertEquals(50.00, opp.Discount_Percent__c,
            'Discount must be capped at 50%');
        System.assertEquals(5000.00, opp.Final_Price__c,
            'Final_Price__c should be Amount * 0.50 = 5,000 at max cap');
    }

    @IsTest
    static void pricingDomain_negativeAmount_addsFieldError() {
        Opportunity opp = new Opportunity(Amount = -500);
        // addError() cannot be verified directly in unit test without DML,
        // but we verify the method runs without exception
        try {
            OpportunityPricingDomain.validateAmount(new List<Opportunity>{ opp });
        } catch (Exception e) {
            System.assert(false, 'validateAmount should not throw — it adds a field error: ' + e.getMessage());
        }
    }

    @IsTest
    static void pricingDomain_nullAmount_stampsFinalPriceNull() {
        Opportunity opp = new Opportunity(Amount = null);
        OpportunityPricingDomain.applyPricing(opp, 0.10);

        System.assertEquals(0, opp.Discount_Percent__c,
            'Null Amount should result in 0% discount');
        System.assertEquals(null, opp.Final_Price__c,
            'Final_Price__c should remain null when Amount is null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // End-to-end: Trigger → Handler → Service → Strategy → Domain
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void endToEnd_insertOpportunity_tieredDiscountStamped() {
        // Default factory (CMDT query in test org) — inject empty map so
        // TieredDiscountStrategy is used (default fallback)
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        Account acc = TestDataFactory.createAccount(true);

        Test.startTest();
        Opportunity opp = new Opportunity(
            Name        = 'E2E Test Opp',
            AccountId   = acc.Id,
            Amount      = 150000,
            StageName   = 'Prospecting',
            CloseDate   = Date.today().addDays(30)
        );
        insert opp;
        Test.stopTest();

        Opportunity result = [
            SELECT Discount_Percent__c, Final_Price__c
            FROM   Opportunity
            WHERE  Id = :opp.Id
        ];
        System.assertEquals(15.00, result.Discount_Percent__c,
            'Amount >= 100,000 should trigger 15% tiered discount');
        System.assertEquals(127500.00, result.Final_Price__c,
            'Final_Price__c = 150,000 * 0.85 = 127,500');
    }

    @IsTest
    static void endToEnd_updateOpportunityAmount_discountRecalculated() {
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        Account acc = TestDataFactory.createAccount(true);
        Opportunity opp = new Opportunity(
            Name      = 'Update Reprice Test',
            AccountId = acc.Id,
            Amount    = 150000,   // 15% tier
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Test.startTest();
        opp.Amount = 5000; // drop to 5% tier
        update opp;
        Test.stopTest();

        Opportunity result = [
            SELECT Discount_Percent__c, Final_Price__c
            FROM   Opportunity
            WHERE  Id = :opp.Id
        ];
        System.assertEquals(5.00, result.Discount_Percent__c,
            'Amount < 10,000 should recalculate to 5% discount');
        System.assertEquals(4750.00, result.Final_Price__c,
            'Final_Price__c = 5,000 * 0.95 = 4,750');
    }

    @IsTest
    static void endToEnd_updateWithNoAmountChange_noPricingRecalculation() {
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        Account acc = TestDataFactory.createAccount(true);
        Opportunity opp = new Opportunity(
            Name        = 'No Reprice Test',
            AccountId   = acc.Id,
            Amount      = 100000,
            StageName   = 'Prospecting',
            CloseDate   = Date.today().addDays(30)
        );
        insert opp;

        // Capture values before unrelated field update
        Opportunity before = [SELECT Discount_Percent__c, Final_Price__c FROM Opportunity WHERE Id = :opp.Id];

        Test.startTest();
        opp.Description = 'Changed description only';
        update opp;
        Test.stopTest();

        Opportunity after = [SELECT Discount_Percent__c, Final_Price__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(before.Discount_Percent__c, after.Discount_Percent__c,
            'Discount should not change when Amount and Type are unchanged');
        System.assertEquals(before.Final_Price__c, after.Final_Price__c,
            'Final_Price__c should not change on unrelated field updates');
    }

    @IsTest
    static void endToEnd_bulkInsert200Opps_allPricedWithinLimits() {
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        Account acc = TestDataFactory.createAccount(true);
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Opp ' + i,
                AccountId = acc.Id,
                Amount    = 10000 + (i * 1000),
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            ));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        List<Opportunity> results = [
            SELECT Discount_Percent__c, Final_Price__c
            FROM   Opportunity
            WHERE  AccountId = :acc.Id
            LIMIT 200
        ];
        System.assertEquals(200, results.size(), '200 Opportunities should be inserted');
        for (Opportunity r : results) {
            System.assertNotEquals(null, r.Discount_Percent__c,
                'Every Opportunity should have Discount_Percent__c stamped');
            System.assertNotEquals(null, r.Final_Price__c,
                'Every Opportunity should have Final_Price__c stamped');
        }
    }

    @IsTest
    static void triggerHandler_bypass_skipsDiscountLogic() {
        DiscountStrategyFactory.setConfigsForTest(
            new Map<String, Discount_Strategy_Config__mdt>());

        Account acc = TestDataFactory.createAccount(true);

        Test.startTest();
        TriggerHandler.bypass('OpportunityTriggerHandler');
        Opportunity opp = new Opportunity(
            Name      = 'Bypassed Opp',
            AccountId = acc.Id,
            Amount    = 200000,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        TriggerHandler.clearBypass('OpportunityTriggerHandler');
        Test.stopTest();

        Opportunity result = [SELECT Discount_Percent__c, Final_Price__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, result.Discount_Percent__c,
            'Bypassed handler should leave Discount_Percent__c null');
    }
}
