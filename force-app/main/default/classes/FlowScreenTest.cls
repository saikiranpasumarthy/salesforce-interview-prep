/**
 * @description FlowScreenTest — Tests for Day 13 Screen Flow patterns.
 *
 *              TEST STRATEGY FOR SCREEN FLOWS:
 *              ════════════════════════════════
 *              Screen Flows cannot be tested in isolation from the Flow engine
 *              (no Test.invokeFlow equivalent). Testing strategies:
 *
 *              1. INVOCABLE APEX UNIT TESTS (this file, most tests):
 *                 Test FlowActionValidateAccount directly with List<Request>.
 *                 Fast, no governor overhead, fully isolated.
 *
 *              2. SUBFLOW INTEGRATION (Flow.Interview):
 *                 Test Validate_Account_Data subflow via Flow.Interview.
 *                 Verifies the Flow XML variable mapping is correct.
 *                 Requires the subflow to be Active in the org.
 *
 *              3. SCREEN FLOW APEX CONTEXT (Record Creates):
 *                 The Account/Contact/Opportunity creation in the wizard
 *                 is just standard DML — test the equivalent DML directly
 *                 to verify field mapping without invoking the full flow.
 *
 *              4. E2E (manual / UI automation):
 *                 Screen Flows with user interaction (button clicks, input)
 *                 require manual QA or Selenium/Playwright E2E tests.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
@IsTest
private class FlowScreenTest {

    @TestSetup
    static void setup() {
        insert new Account(Name = 'Existing Account', AnnualRevenue = 500_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FlowActionValidateAccount — format validation unit tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validate_validName_passes() {
        FlowActionValidateAccount.ValidationRequest req = makeRequest('Acme Corp');

        Test.startTest();
        List<FlowActionValidateAccount.ValidationResult> results =
            FlowActionValidateAccount.validateAccounts(
                new List<FlowActionValidateAccount.ValidationRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1,    results.size(),      'Should return one result');
        System.assertEquals(true, results[0].isValid,  'Valid name should pass');
        System.assertNull(results[0].errorMessage,     'No error for valid name');
    }

    @IsTest
    static void validate_blankName_fails() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest(''));
        System.assertEquals(false, r.isValid, 'Blank name should fail');
        System.assert(r.errorMessage.containsIgnoreCase('blank'), 'Error should mention blank');
    }

    @IsTest
    static void validate_nullName_fails() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest(null));
        System.assertEquals(false, r.isValid, 'Null name should fail');
    }

    @IsTest
    static void validate_singleChar_fails() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest('A'));
        System.assertEquals(false, r.isValid, 'Single-char name should fail min length');
        System.assert(r.errorMessage.containsIgnoreCase('2'), 'Error should mention min length');
    }

    @IsTest
    static void validate_twoChars_passes() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest('AB'));
        System.assertEquals(true, r.isValid, '2-char name should pass minimum length');
    }

    @IsTest
    static void validate_digitsOnly_fails() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest('12345'));
        System.assertEquals(false, r.isValid, 'Digits-only name should fail');
        System.assert(r.errorMessage.containsIgnoreCase('letter'), 'Error should mention letter requirement');
    }

    @IsTest
    static void validate_alphanumeric_passes() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest('Corp 123'));
        System.assertEquals(true, r.isValid, 'Alphanumeric name should pass');
    }

    @IsTest
    static void validate_leadingUnderscore_fails() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest('_Test Corp'));
        System.assertEquals(false, r.isValid, 'Leading underscore should fail');
    }

    @IsTest
    static void validate_leadingDash_fails() {
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest('-Test Corp'));
        System.assertEquals(false, r.isValid, 'Leading dash should fail');
    }

    @IsTest
    static void validate_nameTooLong_fails() {
        String longName = 'A'.repeat(256); // 256 chars > MAX_NAME_LENGTH (255)
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest(longName));
        System.assertEquals(false, r.isValid, '256-char name should fail max length');
    }

    @IsTest
    static void validate_exactly255Chars_passes() {
        String borderName = 'A' + 'x'.repeat(254); // 255 chars = exactly MAX
        FlowActionValidateAccount.ValidationResult r =
            FlowActionValidateAccount.validate(makeRequest(borderName));
        System.assertEquals(true, r.isValid, '255-char name should pass max length');
    }

    @IsTest
    static void validate_bulk_returnsIndexAlignedResults() {
        /**
         * Key test: index alignment.
         * Result[0] corresponds to Request[0], result[1] to request[1], etc.
         * This is essential for the Flow to correctly map outputs to variables.
         */
        List<FlowActionValidateAccount.ValidationRequest> requests =
            new List<FlowActionValidateAccount.ValidationRequest>{
                makeRequest('Valid Corp'),    // should pass
                makeRequest(''),             // should fail
                makeRequest('Another Valid') // should pass
            };

        Test.startTest();
        List<FlowActionValidateAccount.ValidationResult> results =
            FlowActionValidateAccount.validateAccounts(requests);
        Test.stopTest();

        System.assertEquals(3, results.size(), 'Should return 3 results');
        System.assertEquals(true,  results[0].isValid, 'Result 0 should pass');
        System.assertEquals(false, results[1].isValid, 'Result 1 should fail');
        System.assertEquals(true,  results[2].isValid, 'Result 2 should pass');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Validate_Account_Data subflow — integration test via Flow.Interview
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validateSubflow_existingAccount_returnsDuplicate() {
        /**
         * Flow.Interview pattern for testing Auto-Launched flows.
         * The flow must be ACTIVE in the org for this to run.
         *
         * Steps:
         * 1. Build inputs map (matches flow variable names marked isInput=true)
         * 2. createInterview(flowApiName, inputs)
         * 3. flow.start()
         * 4. flow.getVariableValue(variableName) reads isOutput=true variables
         */
        Map<String, Object> inputs = new Map<String, Object>{
            'accountName' => 'Existing Account'  // created in @TestSetup
        };

        Flow.Interview flowInterview = Flow.Interview.createInterview(
            'Validate_Account_Data', inputs
        );

        Test.startTest();
        flowInterview.start();
        Test.stopTest();

        Boolean isDuplicate = (Boolean) flowInterview.getVariableValue('isDuplicate');
        System.assertEquals(true, isDuplicate,
            'Subflow should detect existing account as duplicate');
    }

    @IsTest
    static void validateSubflow_newAccountName_returnsNotDuplicate() {
        Map<String, Object> inputs = new Map<String, Object>{
            'accountName' => 'Brand New Unique Corp XYZ'
        };

        Flow.Interview flowInterview = Flow.Interview.createInterview(
            'Validate_Account_Data', inputs
        );

        Test.startTest();
        flowInterview.start();
        Test.stopTest();

        Boolean isDuplicate = (Boolean) flowInterview.getVariableValue('isDuplicate');
        System.assertEquals(false, isDuplicate,
            'Subflow should return false for non-duplicate account name');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Wizard DML context — verify Account+Contact+Opportunity creation chain
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void wizardDml_createAccountContactOpportunity_linkedCorrectly() {
        /**
         * Tests the DML sequence the wizard flow performs.
         * Not testing the Flow XML itself — tests the Apex equivalent to verify
         * the record relationships are correct (Contact.AccountId, Opp.AccountId).
         */
        Test.startTest();

        Account acc = new Account(
            Name          = 'Wizard Test Corp',
            Industry      = 'Technology',
            AnnualRevenue = 1_500_000
        );
        insert acc;

        Contact con = new Contact(
            FirstName = 'Jane',
            LastName  = 'Doe',
            Email     = 'jane.doe@wizardtest.com',
            AccountId = acc.Id
        );
        insert con;

        Opportunity opp = new Opportunity(
            Name      = 'Wizard Test Corp — New Deal',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id,
            Amount    = 75_000
        );
        insert opp;

        Test.stopTest();

        // Verify contact linked to account
        Contact cResult = [SELECT AccountId FROM Contact WHERE Id = :con.Id];
        System.assertEquals(acc.Id, cResult.AccountId, 'Contact should be linked to account');

        // Verify opportunity linked to account
        Opportunity oResult = [SELECT AccountId, StageName FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(acc.Id,        oResult.AccountId, 'Opportunity should be linked to account');
        System.assertEquals('Prospecting', oResult.StageName, 'Stage should be Prospecting');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helper
    // ═══════════════════════════════════════════════════════════════════════════

    private static FlowActionValidateAccount.ValidationRequest makeRequest(String name) {
        FlowActionValidateAccount.ValidationRequest req =
            new FlowActionValidateAccount.ValidationRequest();
        req.accountName = name;
        return req;
    }
}
