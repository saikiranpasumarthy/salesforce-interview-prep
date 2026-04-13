/**
 * LoanEligibilityService
 * Core decisioning engine for loan applications.
 *
 * Decision flow:
 *   1. Load LoanApplication__c
 *   2. Fetch credit score from CreditScoreService (or use cached value if < 30 days old)
 *   3. Calculate Debt-to-Income ratio
 *   4. Look up eligibility thresholds from LoanEligibilityThreshold__mdt
 *   5. Determine AUTO_APPROVED / MANUAL_REVIEW / DECLINED
 *   6. Write decision back to LoanApplication__c
 *   7. Route to approval if MANUAL_REVIEW
 */
public with sharing class LoanEligibilityService {

    // ── DTI thresholds ────────────────────────────────────────────────────────
    @TestVisible static final Decimal MAX_DTI_AUTO_APPROVE = 36.0;  // % — below this: auto approve
    @TestVisible static final Decimal MAX_DTI_MANUAL_REVIEW = 50.0; // % — above this: decline

    // ── Credit score minimums ─────────────────────────────────────────────────
    @TestVisible static final Integer MIN_SCORE_AUTO_APPROVE = 720;
    @TestVisible static final Integer MIN_SCORE_MANUAL_REVIEW = 620;
    // < MIN_SCORE_MANUAL_REVIEW → always DECLINED

    // ── Score cache TTL ───────────────────────────────────────────────────────
    @TestVisible static final Integer SCORE_CACHE_DAYS = 30;

    // ── Approval amount thresholds ────────────────────────────────────────────
    @TestVisible static final Decimal DIRECTOR_THRESHOLD   = 100000;
    @TestVisible static final Decimal EXECUTIVE_THRESHOLD  = 500000;

    private CreditScoreService creditScoreService;

    public LoanEligibilityService() {
        this.creditScoreService = new CreditScoreService();
    }

    @TestVisible
    private LoanEligibilityService(CreditScoreService mockCreditSvc) {
        this.creditScoreService = mockCreditSvc;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MAIN ENTRY POINT
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Full eligibility scoring for a single loan application.
     * Called by LoanEligibilityQueueable after status → SUBMITTED.
     */
    public EligibilityResult scoreEligibility(Id loanAppId) {
        LoanApplication__c app = fetchApplication(loanAppId);

        // Step 1: Get credit score (cached or fresh)
        Integer creditScore = resolveCreditScore(app);

        // Step 2: Calculate DTI
        Decimal dti = calcDebtToIncomeRatio(app.MonthlyDebtPayments__c, app.AnnualIncome__c);

        // Step 3: Determine decision
        String decision = determineDecision(creditScore, dti);

        // Step 4: Write back
        app.CreditScore__c          = creditScore;
        app.DebtToIncomeRatio__c    = dti;
        app.EligibilityDecision__c  = decision;
        app.EligibilityEvaluatedAt__c = Datetime.now();

        if (decision == 'AUTO_APPROVED') {
            app.Status__c = 'APPROVED';
        } else if (decision == 'DECLINED') {
            app.Status__c = 'DECLINED';
        } else {
            app.Status__c = 'IN_REVIEW';
        }

        update as user app;

        // Step 5: Route to approval if manual review
        if (decision == 'MANUAL_REVIEW') {
            routeToApproval(app.Id, app.RequestedAmount__c);
        }

        return new EligibilityResult(app.Id, decision, creditScore, dti);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DEBT-TO-INCOME
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Calculates DTI as (monthlyDebt / monthlyIncome) * 100.
     * Returns 100 if income is 0 or null (fail safe → worst case).
     */
    public Decimal calcDebtToIncomeRatio(Decimal monthlyDebt, Decimal annualIncome) {
        if (annualIncome == null || annualIncome == 0) return 100;
        if (monthlyDebt  == null) monthlyDebt = 0;
        Decimal monthlyIncome = annualIncome / 12;
        return (monthlyDebt / monthlyIncome * 100).setScale(2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DECISION LOGIC
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Determines eligibility decision from credit score and DTI.
     *
     * Matrix:
     * Score >= 720 AND DTI <= 36%  → AUTO_APPROVED
     * Score >= 620 AND DTI <= 50%  → MANUAL_REVIEW
     * Otherwise                    → DECLINED
     */
    public String determineDecision(Integer creditScore, Decimal dti) {
        if (creditScore == null) return 'DECLINED';

        if (creditScore >= MIN_SCORE_AUTO_APPROVE && dti <= MAX_DTI_AUTO_APPROVE) {
            return 'AUTO_APPROVED';
        }
        if (creditScore >= MIN_SCORE_MANUAL_REVIEW && dti <= MAX_DTI_MANUAL_REVIEW) {
            return 'MANUAL_REVIEW';
        }
        return 'DECLINED';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // APPROVAL ROUTING
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Routes the loan application to the appropriate approval tier based on
     * requested amount.
     *
     * < $100k        → Branch Manager approval
     * $100k – $500k  → Director approval
     * > $500k        → Executive approval
     */
    public ApprovalRoute routeToApproval(Id loanAppId, Decimal requestedAmount) {
        String tier;
        if (requestedAmount == null || requestedAmount < DIRECTOR_THRESHOLD) {
            tier = 'BRANCH_MANAGER';
        } else if (requestedAmount < EXECUTIVE_THRESHOLD) {
            tier = 'DIRECTOR';
        } else {
            tier = 'EXECUTIVE';
        }

        // Submit to standard Salesforce approval process
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(loanAppId);
        req.setComments('Auto-submitted by LoanEligibilityService. Tier: ' + tier);
        req.setProcessDefinitionNameOrId('LoanApproval_' + tier);

        Approval.ProcessResult result;
        try {
            result = Approval.process(req);
        } catch (Exception e) {
            // Log and continue — approval submission failure should not block status update
            System.debug(LoggingLevel.ERROR,
                'Approval submission failed for ' + loanAppId + ': ' + e.getMessage());
        }

        return new ApprovalRoute(loanAppId, tier);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    private LoanApplication__c fetchApplication(Id loanAppId) {
        return [
            SELECT Id, Applicant__c, LoanType__c, RequestedAmount__c, AnnualIncome__c,
                   MonthlyDebtPayments__c, CreditScore__c, EligibilityDecision__c,
                   Status__c, ExternalId__c, CreditScoreFetchedAt__c,
                   EligibilityEvaluatedAt__c
            FROM   LoanApplication__c
            WHERE  Id = :loanAppId
            WITH   USER_MODE
            LIMIT  1
        ];
    }

    private Integer resolveCreditScore(LoanApplication__c app) {
        // Use cached score if it was fetched within SCORE_CACHE_DAYS
        if (app.CreditScore__c != null && app.CreditScoreFetchedAt__c != null) {
            Integer daysSinceFetch = app.CreditScoreFetchedAt__c.date().daysBetween(Date.today());
            if (daysSinceFetch <= SCORE_CACHE_DAYS) {
                return app.CreditScore__c.intValue();
            }
        }
        // Fetch fresh score
        CreditScoreService.CreditScoreResult scoreResult =
            creditScoreService.fetchScore(app.Applicant__c, 'CreditBureauNC');
        return scoreResult.score;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RESULT DTOs
    // ─────────────────────────────────────────────────────────────────────────

    public class EligibilityResult {
        public Id     loanAppId   { get; private set; }
        public String decision    { get; private set; }
        public Integer creditScore { get; private set; }
        public Decimal dti        { get; private set; }

        public EligibilityResult(Id id, String dec, Integer score, Decimal dti) {
            this.loanAppId   = id;
            this.decision    = dec;
            this.creditScore = score;
            this.dti         = dti;
        }
    }

    public class ApprovalRoute {
        public Id     loanAppId { get; private set; }
        public String tier      { get; private set; }

        public ApprovalRoute(Id id, String tier) {
            this.loanAppId = id;
            this.tier      = tier;
        }
    }
}
