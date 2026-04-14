/**
 * WealthManagementCallableTest
 * Unit tests for WealthManagementCallable (Callable interface bridge).
 * Tests each action routing, arg validation, and error handling.
 */
@isTest
private class WealthManagementCallableTest {

    @TestSetup
    static void makeData() {
        Account household = new Account(Name = 'Callable Test Household');
        insert household;

        insert new FinancialAccount__c(
            Account__c     = household.Id,
            AccountType__c = 'INVESTMENT',
            Balance__c     = 50000,
            IsActive__c    = true
        );

        Account applicant = new Account(
            FirstName = 'Test',
            LastName  = 'Applicant',
            RecordTypeId = getPersonAccountRTId()
        );
        insert applicant;

        insert new LoanApplication__c(
            Applicant__c           = applicant.Id,
            LoanType__c            = 'PERSONAL',
            RequestedAmount__c     = 50000,
            AnnualIncome__c        = 80000,
            MonthlyDebtPayments__c = 500,
            Status__c              = 'SUBMITTED',
            EligibilityDecision__c = 'PENDING'
        );
    }

    // ── Unknown action ────────────────────────────────────────────────────────

    @isTest
    static void testCall_unknownAction_throwsCallableException() {
        WealthManagementCallable callable = new WealthManagementCallable();
        Boolean threw = false;

        Test.startTest();
        try {
            callable.call('nonExistentAction', new Map<String, Object>());
        } catch (WealthManagementCallable.CallableException e) {
            threw = true;
            System.assert(e.getMessage().contains('Unknown action'));
        }
        Test.stopTest();

        System.assert(threw, 'Unknown action should throw CallableException');
    }

    @isTest
    static void testCall_blankAction_throwsCallableException() {
        WealthManagementCallable callable = new WealthManagementCallable();
        Boolean threw = false;

        Test.startTest();
        try {
            callable.call('', new Map<String, Object>());
        } catch (WealthManagementCallable.CallableException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Blank action should throw CallableException');
    }

    // ── getHouseholdNetWorth ──────────────────────────────────────────────────

    @isTest
    static void testCall_getHouseholdNetWorth_returnsNetWorth() {
        Account household = [SELECT Id FROM Account WHERE Name = 'Callable Test Household' LIMIT 1];
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'getHouseholdNetWorth',
            new Map<String, Object>{ 'householdId' => household.Id }
        );
        Test.stopTest();

        System.assertNotEquals(null, result.get('netWorth'), 'Net worth should be returned');
        System.assertEquals(50000, (Decimal) result.get('netWorth'));
        System.assertEquals(String.valueOf(household.Id), (String) result.get('householdId'));
    }

    @isTest
    static void testCall_getHouseholdNetWorth_missingArg_throwsException() {
        WealthManagementCallable callable = new WealthManagementCallable();
        Boolean threw = false;

        Test.startTest();
        try {
            callable.call('getHouseholdNetWorth', new Map<String, Object>());
        } catch (WealthManagementCallable.CallableException e) {
            threw = true;
            System.assert(e.getMessage().contains('householdId'));
        }
        Test.stopTest();

        System.assert(threw);
    }

    // ── getPortfolioHealth ────────────────────────────────────────────────────

    @isTest
    static void testCall_getPortfolioHealth_returnsBands() {
        Account household = [SELECT Id FROM Account WHERE Name = 'Callable Test Household' LIMIT 1];
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'getPortfolioHealth',
            new Map<String, Object>{ 'householdId' => household.Id }
        );
        Test.stopTest();

        Map<String, String> bands = (Map<String, String>) result.get('bands');
        System.assertNotEquals(null, bands, 'bands should be present');
        System.assertEquals(1, bands.size(), 'Should have 1 account');
        // Balance 50000 → GREEN
        System.assertEquals('GREEN', bands.values()[0]);
    }

    // ── interpretCreditBand ───────────────────────────────────────────────────

    @isTest
    static void testCall_interpretCreditBand_excellent() {
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'interpretCreditBand',
            new Map<String, Object>{ 'score' => 820 }
        );
        Test.stopTest();

        System.assertEquals('EXCELLENT', (String) result.get('band'));
        System.assertEquals(820, (Integer) result.get('score'));
    }

    @isTest
    static void testCall_interpretCreditBand_poor() {
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'interpretCreditBand',
            new Map<String, Object>{ 'score' => 520 }
        );
        Test.stopTest();

        System.assertEquals('POOR', (String) result.get('band'));
    }

    // ── calcDebtToIncomeRatio ─────────────────────────────────────────────────

    @isTest
    static void testCall_calcDebtToIncome_returnsCorrectDti() {
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'calcDebtToIncomeRatio',
            new Map<String, Object>{ 'monthlyDebt' => 2000, 'annualIncome' => 120000 }
        );
        Test.stopTest();

        // 2000 / (120000/12) * 100 = 2000/10000*100 = 20%
        System.assertEquals(20.00, (Decimal) result.get('dti'));
    }

    @isTest
    static void testCall_calcDebtToIncome_zeroIncome() {
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'calcDebtToIncomeRatio',
            new Map<String, Object>{ 'monthlyDebt' => 1000, 'annualIncome' => 0 }
        );
        Test.stopTest();

        System.assertEquals(100, (Decimal) result.get('dti'));
    }

    // ── calculateLoanEligibility (with callout mock) ──────────────────────────

    @isTest
    static void testCall_calculateLoanEligibility_autoApproved() {
        LoanApplication__c app = [SELECT Id FROM LoanApplication__c LIMIT 1];
        // Pre-populate cached credit score to avoid callout
        app.CreditScore__c          = 780;
        app.CreditScoreFetchedAt__c = Datetime.now();
        update app;

        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'calculateLoanEligibility',
            new Map<String, Object>{ 'loanAppId' => app.Id }
        );
        Test.stopTest();

        System.assertNotEquals(null, result.get('decision'));
        System.assertEquals(String.valueOf(app.Id), (String) result.get('loanAppId'));
    }

    @isTest
    static void testCall_calculateLoanEligibility_withMockCallout() {
        LoanApplication__c app = [SELECT Id FROM LoanApplication__c LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CreditScoreMock(CreditScoreMock.MockType.CREDIT_SCORE_HIGH));

        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'calculateLoanEligibility',
            new Map<String, Object>{ 'loanAppId' => app.Id }
        );
        Test.stopTest();

        System.assertEquals('AUTO_APPROVED', (String) result.get('decision'));
        System.assertEquals(820, (Integer) result.get('creditScore'));
    }

    // ── fetchCreditScore (with callout mock) ──────────────────────────────────

    @isTest
    static void testCall_fetchCreditScore_returnsScore() {
        Account applicant = [SELECT Id FROM Account WHERE LastName = 'Applicant' LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CreditScoreMock(CreditScoreMock.MockType.CREDIT_SCORE_SUCCESS));

        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'fetchCreditScore',
            new Map<String, Object>{
                'applicantId'    => applicant.Id,
                'namedCredential'=> 'CreditBureauNC'
            }
        );
        Test.stopTest();

        System.assertEquals(742, (Integer) result.get('score'));
        System.assertEquals('GOOD', (String) result.get('band'));
    }

    @isTest
    static void testCall_fetchCreditScore_apiError_throwsException() {
        Account applicant = [SELECT Id FROM Account WHERE LastName = 'Applicant' LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CreditScoreMock(CreditScoreMock.MockType.CREDIT_SCORE_HTTP_ERROR));

        WealthManagementCallable callable = new WealthManagementCallable();
        Boolean threw = false;

        Test.startTest();
        try {
            callable.call(
                'fetchCreditScore',
                new Map<String, Object>{
                    'applicantId'    => applicant.Id,
                    'namedCredential'=> 'CreditBureauNC'
                }
            );
        } catch (CreditScoreService.CreditScoreException e) {
            threw = true;
            System.assert(e.getMessage().contains('HTTP 503'));
        }
        Test.stopTest();

        System.assert(threw, 'Should propagate credit score API error');
    }

    // ── validateKyc ───────────────────────────────────────────────────────────

    @isTest
    static void testCall_validateKyc_invalidSsn_failsWithoutCallout() {
        Account applicant = [SELECT Id FROM Account WHERE LastName = 'Applicant' LIMIT 1];
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'validateKyc',
            new Map<String, Object>{
                'accountId'      => applicant.Id,
                'ssn'            => '123',          // Invalid format
                'namedCredential'=> 'KycProviderNC'
            }
        );
        Test.stopTest();

        System.assertEquals(false, (Boolean) result.get('overallPassed'));
        System.assertEquals(false, (Boolean) result.get('ssnValid'));
    }

    @isTest
    static void testCall_validateKyc_validSsn_ofacNoMatch() {
        Account applicant = [SELECT Id FROM Account WHERE LastName = 'Applicant' LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CreditScoreMock(CreditScoreMock.MockType.OFAC_NO_MATCH));

        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'validateKyc',
            new Map<String, Object>{
                'accountId'      => applicant.Id,
                'ssn'            => '123-45-6789',
                'namedCredential'=> 'KycProviderNC'
            }
        );
        Test.stopTest();

        System.assertEquals(true,  (Boolean) result.get('ssnValid'));
        System.assertEquals(false, (Boolean) result.get('ofacMatched'));
        System.assertEquals(true,  (Boolean) result.get('overallPassed'));
    }

    @isTest
    static void testCall_validateKyc_ofacMatch_fails() {
        Account applicant = [SELECT Id FROM Account WHERE LastName = 'Applicant' LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CreditScoreMock(CreditScoreMock.MockType.OFAC_MATCH));

        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'validateKyc',
            new Map<String, Object>{
                'accountId'      => applicant.Id,
                'ssn'            => '987-65-4321',
                'namedCredential'=> 'KycProviderNC'
            }
        );
        Test.stopTest();

        System.assertEquals(true,  (Boolean) result.get('ssnValid'));
        System.assertEquals(true,  (Boolean) result.get('ofacMatched'));
        System.assertEquals(false, (Boolean) result.get('overallPassed'));
        System.assertEquals('SDN', (String) result.get('ofacListName'));
    }

    // ── Case insensitivity ────────────────────────────────────────────────────

    @isTest
    static void testCall_actionIsCaseInsensitive() {
        Account household = [SELECT Id FROM Account WHERE Name = 'Callable Test Household' LIMIT 1];
        WealthManagementCallable callable = new WealthManagementCallable();

        Test.startTest();
        // 'GETHOUSEHOLDNETWORTH' should match 'getHouseholdNetWorth'
        Map<String, Object> result = (Map<String, Object>) callable.call(
            'GETHOUSEHOLDNETWORTH',
            new Map<String, Object>{ 'householdId' => household.Id }
        );
        Test.stopTest();

        System.assertNotEquals(null, result.get('netWorth'));
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static Id getPersonAccountRTId() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND DeveloperName = 'PersonAccount'
            LIMIT 1
        ];
        return rts.isEmpty() ? null : rts[0].Id;
    }
}
