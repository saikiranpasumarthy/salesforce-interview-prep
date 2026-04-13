/**
 * WealthManagementCallable
 * Implements the Callable interface to bridge OmniStudio Integration Procedures
 * with Salesforce Apex service classes.
 *
 * OmniStudio Integration Procedures invoke Apex via a registered Callable class.
 * This single class routes all IP → Apex calls to the correct service method.
 *
 * Supported actions:
 *   'calculateLoanEligibility'  → LoanEligibilityService.scoreEligibility(loanAppId)
 *   'fetchCreditScore'          → CreditScoreService.fetchScore(applicantId, namedCred)
 *   'getHouseholdNetWorth'      → FinancialAccountService.householdNetWorth(householdId)
 *   'getPortfolioHealth'        → FinancialAccountService.portfolioHealthForHousehold(householdId)
 *   'validateKyc'               → KycValidationService.verifyIdentity(accountId, ssn, namedCred)
 *   'interpretCreditBand'       → CreditScoreService.interpretBand(score)
 *   'calcDebtToIncome'          → LoanEligibilityService.calcDebtToIncomeRatio(monthlyDebt, annualIncome)
 *
 * Usage from Integration Procedure:
 *   Apex Action step:
 *     className: WealthManagementCallable
 *     methodName: call
 *     inputs:
 *       action: 'calculateLoanEligibility'
 *       args:   { loanAppId: '{loanApplicationId}' }
 */
public class WealthManagementCallable implements Callable {

    // ─────────────────────────────────────────────────────────────────────────
    // CALLABLE ENTRY POINT
    // ─────────────────────────────────────────────────────────────────────────

    public Object call(String action, Map<String, Object> args) {
        if (String.isBlank(action)) {
            throw new CallableException('action parameter is required.');
        }

        switch on action.toLowerCase() {
            when 'calculateloaneligibility' {
                return calculateLoanEligibility(args);
            }
            when 'fetchcreditscore' {
                return fetchCreditScore(args);
            }
            when 'gethouseholdnetworth' {
                return getHouseholdNetWorth(args);
            }
            when 'getportfoliohealth' {
                return getPortfolioHealth(args);
            }
            when 'validatekyc' {
                return validateKyc(args);
            }
            when 'interpretcreditband' {
                return interpretCreditBand(args);
            }
            when 'calcdebttoincomeratio' {
                return calcDebtToIncome(args);
            }
            when else {
                throw new CallableException('Unknown action: ' + action +
                    '. Supported: calculateLoanEligibility, fetchCreditScore, ' +
                    'getHouseholdNetWorth, getPortfolioHealth, validateKyc, ' +
                    'interpretCreditBand, calcDebtToIncomeRatio');
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ACTION HANDLERS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs full loan eligibility scoring and writes decision back to LoanApplication__c.
     * Args: { loanAppId: String }
     * Returns: Map<String, Object> { decision, creditScore, dti, loanAppId }
     */
    private Map<String, Object> calculateLoanEligibility(Map<String, Object> args) {
        Id loanAppId = requireId(args, 'loanAppId');
        LoanEligibilityService svc = new LoanEligibilityService();
        LoanEligibilityService.EligibilityResult result = svc.scoreEligibility(loanAppId);

        return new Map<String, Object>{
            'loanAppId'   => String.valueOf(result.loanAppId),
            'decision'    => result.decision,
            'creditScore' => result.creditScore,
            'dti'         => result.dti
        };
    }

    /**
     * Fetches a credit score from the Credit Bureau API.
     * Args: { applicantId: String, namedCredential: String }
     * Returns: Map<String, Object> { score, band, factors }
     */
    private Map<String, Object> fetchCreditScore(Map<String, Object> args) {
        Id applicantId   = requireId(args, 'applicantId');
        String namedCred = requireString(args, 'namedCredential');

        CreditScoreService svc = new CreditScoreService();
        CreditScoreService.CreditScoreResult result = svc.fetchScore(applicantId, namedCred);

        return new Map<String, Object>{
            'score'   => result.score,
            'band'    => result.band,
            'factors' => result.factors
        };
    }

    /**
     * Returns total net worth for a household.
     * Args: { householdId: String }
     * Returns: Map<String, Object> { householdId, netWorth }
     */
    private Map<String, Object> getHouseholdNetWorth(Map<String, Object> args) {
        Id householdId = requireId(args, 'householdId');
        FinancialAccountService svc = new FinancialAccountService();
        Decimal netWorth = svc.householdNetWorth(householdId);

        return new Map<String, Object>{
            'householdId' => String.valueOf(householdId),
            'netWorth'    => netWorth
        };
    }

    /**
     * Returns portfolio health bands for all active accounts in a household.
     * Args: { householdId: String }
     * Returns: Map<String, Object> { bands: Map<String, String> (faId → GREEN/YELLOW/RED) }
     */
    private Map<String, Object> getPortfolioHealth(Map<String, Object> args) {
        Id householdId = requireId(args, 'householdId');
        FinancialAccountService svc = new FinancialAccountService();
        Map<Id, String> bands = svc.portfolioHealthForHousehold(householdId);

        // Convert Id keys to String for JSON serialization
        Map<String, String> bandStrings = new Map<String, String>();
        for (Id faId : bands.keySet()) {
            bandStrings.put(String.valueOf(faId), bands.get(faId));
        }

        return new Map<String, Object>{
            'householdId' => String.valueOf(householdId),
            'bands'       => bandStrings
        };
    }

    /**
     * Runs KYC identity verification (SSN format + OFAC check).
     * Args: { accountId: String, ssn: String, namedCredential: String }
     * Returns: Map<String, Object> { overallPassed, ssnValid, ofacMatched, ofacMatchScore }
     */
    private Map<String, Object> validateKyc(Map<String, Object> args) {
        Id accountId     = requireId(args, 'accountId');
        String ssn       = requireString(args, 'ssn');
        String namedCred = requireString(args, 'namedCredential');

        KycValidationService svc = new KycValidationService();
        KycValidationService.IdentityVerificationResult result =
            svc.verifyIdentity(accountId, ssn, namedCred);

        return new Map<String, Object>{
            'overallPassed' => result.overallPassed,
            'ssnValid'      => result.ssnValid,
            'ssnMessage'    => result.ssnMessage,
            'ofacMatched'   => result.ofacMatched,
            'ofacMatchScore'=> result.ofacMatchScore,
            'ofacListName'  => result.ofacListName
        };
    }

    /**
     * Converts a numeric credit score to a band label (no callout).
     * Args: { score: Integer }
     * Returns: Map<String, Object> { score, band }
     */
    private Map<String, Object> interpretCreditBand(Map<String, Object> args) {
        Integer score = requireInteger(args, 'score');
        CreditScoreService svc = new CreditScoreService();
        String band = svc.interpretBand(score);

        return new Map<String, Object>{
            'score' => score,
            'band'  => band
        };
    }

    /**
     * Calculates DTI from monthly debt and annual income (no callout, no DML).
     * Args: { monthlyDebt: Decimal, annualIncome: Decimal }
     * Returns: Map<String, Object> { dti }
     */
    private Map<String, Object> calcDebtToIncome(Map<String, Object> args) {
        Decimal monthlyDebt  = requireDecimal(args, 'monthlyDebt');
        Decimal annualIncome = requireDecimal(args, 'annualIncome');
        LoanEligibilityService svc = new LoanEligibilityService();
        Decimal dti = svc.calcDebtToIncomeRatio(monthlyDebt, annualIncome);

        return new Map<String, Object>{ 'dti' => dti };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ARG HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    private Id requireId(Map<String, Object> args, String key) {
        Object val = args.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new CallableException('Missing required argument: ' + key);
        }
        try {
            return (Id) Id.valueOf(String.valueOf(val));
        } catch (Exception e) {
            throw new CallableException('Invalid Salesforce Id for argument ' + key + ': ' + val);
        }
    }

    private String requireString(Map<String, Object> args, String key) {
        Object val = args.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new CallableException('Missing required argument: ' + key);
        }
        return (String) val;
    }

    private Integer requireInteger(Map<String, Object> args, String key) {
        Object val = args.get(key);
        if (val == null) throw new CallableException('Missing required argument: ' + key);
        return Integer.valueOf(String.valueOf(val));
    }

    private Decimal requireDecimal(Map<String, Object> args, String key) {
        Object val = args.get(key);
        if (val == null) throw new CallableException('Missing required argument: ' + key);
        return Decimal.valueOf(String.valueOf(val));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INNER EXCEPTION
    // ─────────────────────────────────────────────────────────────────────────
    public class CallableException extends Exception {}
}
