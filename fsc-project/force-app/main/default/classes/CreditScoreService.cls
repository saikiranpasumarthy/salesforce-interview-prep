/**
 * CreditScoreService
 * Fetches credit scores from the Credit Bureau API via Named Credential.
 *
 * Named Credential: CreditBureauNC
 * Endpoint: POST /v1/scores
 * Request:  { "applicantId": "<Salesforce Account Id>", "consentObtained": true }
 * Response: { "score": 742, "band": "GOOD", "factors": ["PAYMENT_HISTORY", ...] }
 *
 * Score bands:
 *   EXCELLENT : 800 – 850
 *   VERY_GOOD : 740 – 799
 *   GOOD      : 670 – 739
 *   FAIR      : 580 – 669
 *   POOR      : 300 – 579
 */
public with sharing class CreditScoreService {

    // Band boundaries
    @TestVisible static final Integer EXCELLENT_MIN = 800;
    @TestVisible static final Integer VERY_GOOD_MIN = 740;
    @TestVisible static final Integer GOOD_MIN       = 670;
    @TestVisible static final Integer FAIR_MIN        = 580;

    // ─────────────────────────────────────────────────────────────────────────
    // FETCH SCORE
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fetches the credit score for an applicant (Account Id).
     * Uses Named Credential so no credentials appear in code.
     *
     * @param applicantId  Salesforce Account Id of the borrower
     * @param namedCred    Named Credential API name (e.g., 'CreditBureauNC')
     * @return CreditScoreResult DTO
     */
    public CreditScoreResult fetchScore(Id applicantId, String namedCred) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCred + '/v1/scores');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(15000);

        Map<String, Object> body = new Map<String, Object>{
            'applicantId'      => String.valueOf(applicantId),
            'consentObtained'  => true
        };
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new CreditScoreException(
                'Credit Bureau API error for applicant ' + applicantId +
                ' — HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }

        return parseResponse(res.getBody());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERPRET BAND
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Converts a numeric FICO score to a band label.
     * Independent of callout — safe to call in tests without mock.
     */
    public String interpretBand(Integer score) {
        if (score == null)            return 'UNKNOWN';
        if (score >= EXCELLENT_MIN)   return 'EXCELLENT';
        if (score >= VERY_GOOD_MIN)   return 'VERY_GOOD';
        if (score >= GOOD_MIN)        return 'GOOD';
        if (score >= FAIR_MIN)        return 'FAIR';
        return 'POOR';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    private CreditScoreResult parseResponse(String body) {
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(body);

        Integer score = data.containsKey('score') ? Integer.valueOf(String.valueOf(data.get('score'))) : null;
        String band   = data.containsKey('band')  ? (String) data.get('band')  : interpretBand(score);

        List<String> factors = new List<String>();
        if (data.containsKey('factors')) {
            for (Object f : (List<Object>) data.get('factors')) {
                factors.add((String) f);
            }
        }

        return new CreditScoreResult(score, band, factors);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DTOs
    // ─────────────────────────────────────────────────────────────────────────

    public class CreditScoreResult {
        public Integer      score   { get; private set; }
        public String       band    { get; private set; }
        public List<String> factors { get; private set; }

        public CreditScoreResult(Integer score, String band, List<String> factors) {
            this.score   = score;
            this.band    = band;
            this.factors = factors;
        }
    }

    public class CreditScoreException extends Exception {}
}
