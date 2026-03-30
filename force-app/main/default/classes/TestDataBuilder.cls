/**
 * @description Fluent Builder pattern for test data construction.
 *
 *              Solves the "test setup readability problem" — most test methods
 *              spend 60-70% of their lines building records with magic values and
 *              no context about which fields actually matter for the assertion.
 *
 *              Builder pattern makes test intent explicit:
 *                // Before — which of these fields matters for the test?
 *                Account acc = new Account(Name='X', Type='Y', Rating='Z',
 *                    AnnualRevenue=100000, BillingCity='NYC');
 *
 *                // After — the test reads like a specification
 *                Account acc = new TestDataBuilder.AccountBuilder()
 *                    .withRevenue(100000) // ← the field this test cares about
 *                    .build();
 *
 *              Design decisions:
 *                - Sensible defaults on every builder so callers only set what matters
 *                - `build()` returns the SObject without DML (unit test friendly)
 *                - `buildAndInsert()` performs DML (integration test friendly)
 *                - Bulk helpers are static — no need to instantiate the outer class
 *                - Inner classes (AccountBuilder, OpportunityBuilder, CaseBuilder)
 *                  mirror the SObject they build for clarity
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public class TestDataBuilder {

    // ═══════════════════════════════════════════════════════════════════════════
    // AccountBuilder
    // ═══════════════════════════════════════════════════════════════════════════

    public class AccountBuilder {

        private Account record = new Account(
            Name          = 'Test Account',
            Type          = 'Prospect',
            Rating        = 'Warm',
            AnnualRevenue = 50000
        );

        public AccountBuilder withName(String name) {
            record.Name = name; return this;
        }
        public AccountBuilder withType(String type) {
            record.Type = type; return this;
        }
        public AccountBuilder withRating(String rating) {
            record.Rating = rating; return this;
        }
        public AccountBuilder withRevenue(Decimal revenue) {
            record.AnnualRevenue = revenue; return this;
        }
        public AccountBuilder asPartner() {
            record.Type = 'Partner'; return this;
        }
        public AccountBuilder asCustomer() {
            record.Type = 'Customer'; return this;
        }

        /** Returns the Account without performing DML. Useful for unit tests. */
        public Account build() { return record; }

        /** Inserts the Account and returns the record with Id populated. */
        public Account buildAndInsert() {
            insert record;
            return record;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OpportunityBuilder
    // ═══════════════════════════════════════════════════════════════════════════

    public class OpportunityBuilder {

        private Opportunity record;

        public OpportunityBuilder(Id accountId) {
            record = new Opportunity(
                Name      = 'Test Opportunity',
                AccountId = accountId,
                StageName = 'Prospecting',
                Amount    = 50000,
                CloseDate = Date.today().addDays(30)
            );
        }

        public OpportunityBuilder withName(String name) {
            record.Name = name; return this;
        }
        public OpportunityBuilder withAmount(Decimal amount) {
            record.Amount = amount; return this;
        }
        public OpportunityBuilder withStage(String stage) {
            record.StageName = stage; return this;
        }
        public OpportunityBuilder withType(String type) {
            record.Type = type; return this;
        }
        public OpportunityBuilder closingInDays(Integer days) {
            record.CloseDate = Date.today().addDays(days); return this;
        }
        public OpportunityBuilder asClosedWon() {
            record.StageName = 'Closed Won'; return this;
        }

        public Opportunity build() { return record; }

        public Opportunity buildAndInsert() {
            insert record;
            return record;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CaseBuilder
    // ═══════════════════════════════════════════════════════════════════════════

    public class CaseBuilder {

        private Case record;

        public CaseBuilder(Id accountId) {
            record = new Case(
                AccountId = accountId,
                Subject   = 'Test Case',
                Status    = 'New',
                Priority  = 'Medium',
                Origin    = 'Web'
            );
        }

        public CaseBuilder withSubject(String subject) {
            record.Subject = subject; return this;
        }
        public CaseBuilder withStatus(String status) {
            record.Status = status; return this;
        }
        public CaseBuilder withPriority(String priority) {
            record.Priority = priority; return this;
        }
        public CaseBuilder asClosed() {
            record.Status = 'Closed'; return this;
        }
        public CaseBuilder asHighPriority() {
            record.Priority = 'High'; return this;
        }

        public Case build() { return record; }

        public Case buildAndInsert() {
            insert record;
            return record;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Bulk helpers — static so callers don't need to instantiate TestDataBuilder
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Builds N Account records with sequential names.
     *              AnnualRevenue scales with index so tests can verify tier logic.
     *
     * @param count     Number of Account records to build.
     * @param doInsert  If true, inserts and returns records with Ids populated.
     * @return          List of Account records.
     */
    public static List<Account> buildAccounts(Integer count, Boolean doInsert) {
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accs.add(new Account(
                Name          = 'Bulk Account ' + String.valueOf(i).leftPad(3, '0'),
                Type          = 'Prospect',
                AnnualRevenue = 10000 * (i + 1)
            ));
        }
        if (doInsert) insert accs;
        return accs;
    }

    /**
     * @description Builds N Opportunity records linked to one Account.
     *              Amount scales with index to exercise tiered discount logic.
     *
     * @param accountId  Parent Account Id.
     * @param count      Number of Opportunity records to build.
     * @param doInsert   If true, inserts and returns records with Ids populated.
     * @return           List of Opportunity records.
     */
    public static List<Opportunity> buildOpportunities(
            Id accountId, Integer count, Boolean doInsert) {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Opp ' + String.valueOf(i).leftPad(3, '0'),
                AccountId = accountId,
                Amount    = 5000 * (i + 1),
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            ));
        }
        if (doInsert) insert opps;
        return opps;
    }

    /**
     * @description Builds a string of exactly `length` characters.
     *              Used in boundary tests for Text fields with max-length constraints
     *              (e.g., a 255-char Subject field that truncates beyond the limit).
     *
     * @param length  Desired string length.
     * @param ch      Character to repeat (single character string).
     * @return        String of exactly `length` characters.
     */
    public static String buildStringOfLength(Integer length, String ch) {
        String result = '';
        String unit   = String.isBlank(ch) ? 'X' : ch.left(1);
        for (Integer i = 0; i < length; i++) {
            result += unit;
        }
        return result;
    }
}
