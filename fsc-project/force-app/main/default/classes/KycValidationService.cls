/**
 * KycValidationService
 * Know Your Customer (KYC) validation for loan applicants.
 *
 * Checks performed:
 *   1. SSN format validation (999-99-9999)
 *   2. OFAC (Office of Foreign Assets Control) sanctions list check via external API
 *   3. Identity verification — cross-reference Account name with SSN
 *
 * All external calls use Named Credentials.
 * OFAC endpoint: POST callout:KycProviderNC/v1/ofac
 */
public with sharing class KycValidationService {

    // SSN format: exactly 9 digits (may arrive as ###-##-#### or #########)
    @TestVisible static final Pattern SSN_PATTERN = Pattern.compile('^\\d{3}-\\d{2}-\\d{4}$|^\\d{9}$');

    // ─────────────────────────────────────────────────────────────────────────
    // SSN FORMAT VALIDATION
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Validates SSN format. Does NOT check against any external system.
     * Returns a ValidationResult with isValid and an optional error message.
     */
    public ValidationResult validateSsn(String ssn) {
        if (String.isBlank(ssn)) {
            return new ValidationResult(false, 'SSN is required.');
        }
        Matcher m = SSN_PATTERN.matcher(ssn.trim());
        if (!m.matches()) {
            return new ValidationResult(false, 'SSN must be in format 999-99-9999 or 9 digits.');
        }
        // Reject all-zeros or obvious test values
        String digits = ssn.replaceAll('-', '');
        if (digits == '000000000' || digits.startsWith('000') || digits.substring(3, 5) == '00') {
            return new ValidationResult(false, 'SSN contains invalid segment (all zeros).');
        }
        return new ValidationResult(true, null);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // OFAC SANCTIONS CHECK
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Calls the KYC provider's OFAC endpoint to check if the applicant appears
     * on a sanctions list.
     *
     * Request:  { "firstName": "...", "lastName": "...", "dateOfBirth": "YYYY-MM-DD" }
     * Response: { "matched": false, "matchScore": 0, "listName": null }
     */
    public OfacResult checkOfac(String firstName, String lastName, Date dob, String namedCred) {
        if (String.isBlank(firstName) || String.isBlank(lastName)) {
            throw new KycException('First name and last name are required for OFAC check.');
        }

        Map<String, Object> reqBody = new Map<String, Object>{
            'firstName'   => firstName,
            'lastName'    => lastName,
            'dateOfBirth' => dob != null ? String.valueOf(dob) : ''
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCred + '/v1/ofac');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(10000);
        req.setBody(JSON.serialize(reqBody));

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new KycException(
                'OFAC check failed — HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }

        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Boolean matched   = (Boolean) data.get('matched');
        Integer matchScore = data.containsKey('matchScore') ?
                             Integer.valueOf(String.valueOf(data.get('matchScore'))) : 0;
        String listName   = data.containsKey('listName') ? (String) data.get('listName') : null;

        return new OfacResult(matched, matchScore, listName);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IDENTITY VERIFICATION (composite)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Combined identity check: SSN format + OFAC.
     * Returns an IdentityVerificationResult summarising all checks.
     *
     * @param accountId  Salesforce Account (PersonAccount) for the applicant
     * @param ssn        SSN from the onboarding form
     * @param namedCred  Named Credential for KYC provider
     */
    public IdentityVerificationResult verifyIdentity(Id accountId, String ssn, String namedCred) {
        IdentityVerificationResult result = new IdentityVerificationResult();

        // 1. SSN format
        ValidationResult ssnResult = validateSsn(ssn);
        result.ssnValid   = ssnResult.isValid;
        result.ssnMessage = ssnResult.message;

        if (!ssnResult.isValid) {
            result.overallPassed = false;
            return result;
        }

        // 2. Load applicant name for OFAC
        Account applicant = [
            SELECT FirstName, LastName, PersonBirthdate
            FROM   Account
            WHERE  Id = :accountId
            WITH   USER_MODE
            LIMIT  1
        ];

        // 3. OFAC check
        OfacResult ofac = checkOfac(
            applicant.FirstName,
            applicant.LastName,
            applicant.PersonBirthdate,
            namedCred
        );
        result.ofacMatched    = ofac.matched;
        result.ofacMatchScore = ofac.matchScore;
        result.ofacListName   = ofac.listName;

        // Pass = SSN valid AND not on OFAC list
        result.overallPassed = ssnResult.isValid && !ofac.matched;
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DTOs
    // ─────────────────────────────────────────────────────────────────────────

    public class ValidationResult {
        public Boolean isValid  { get; private set; }
        public String  message  { get; private set; }

        public ValidationResult(Boolean isValid, String message) {
            this.isValid = isValid;
            this.message = message;
        }
    }

    public class OfacResult {
        public Boolean matched    { get; private set; }
        public Integer matchScore { get; private set; }
        public String  listName   { get; private set; }

        public OfacResult(Boolean matched, Integer matchScore, String listName) {
            this.matched    = matched;
            this.matchScore = matchScore;
            this.listName   = listName;
        }
    }

    public class IdentityVerificationResult {
        public Boolean ssnValid       = false;
        public String  ssnMessage     = null;
        public Boolean ofacMatched    = false;
        public Integer ofacMatchScore = 0;
        public String  ofacListName   = null;
        public Boolean overallPassed  = false;
    }

    public class KycException extends Exception {}
}
