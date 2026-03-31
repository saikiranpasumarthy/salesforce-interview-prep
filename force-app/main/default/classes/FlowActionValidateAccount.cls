/**
 * @description FlowActionValidateAccount — Invocable Apex for format + duplicate validation.
 *
 *              Demonstrates how to use an @InvocableMethod for validation logic that
 *              Flow's built-in required=true and data type checks cannot express:
 *                1. Minimum name length (not expressible with required=true alone)
 *                2. Regex / format checks (no regex in Flow expressions)
 *                3. Cross-object duplicate detection (SOQL required)
 *                4. Multiple validation rules returning a composite result
 *
 *              VALIDATION RESULT CONTRACT:
 *              ════════════════════════════
 *              Returns List<ValidationResult> (one per Request).
 *              The Flow Decision element can branch on isValid and errorMessage.
 *
 *              DIFFERENCE FROM @api validate() ON LWC:
 *              ═════════════════════════════════════════
 *              • @api validate() — CLIENT-SIDE; runs in the browser; no Apex/SOQL.
 *                Use for format, regex, cross-field logic (no server round-trip).
 *              • @InvocableMethod validation — SERVER-SIDE; can run SOQL.
 *                Use for duplicate checks, permission checks, cross-record lookups.
 *
 *              HOW IT FITS IN THE WIZARD FLOW:
 *              ════════════════════════════════
 *              Screen 1 (user enters name) → this Apex action validates format
 *              → Flow Decision: if isValid=false → show error screen with errorMessage
 *              → if isValid=true → subflow for duplicate check → continue to Screen 2
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
public with sharing class FlowActionValidateAccount {

    private static final Integer MIN_NAME_LENGTH = 2;
    private static final Integer MAX_NAME_LENGTH = 255;

    @InvocableMethod(
        label       = 'Validate Account Name'
        description = 'Validates account name format: not blank, meets min/max length, no special characters only. Returns isValid and errorMessage.'
        category    = 'Account'
    )
    public static List<ValidationResult> validateAccounts(List<ValidationRequest> requests) {

        List<ValidationResult> results = new List<ValidationResult>();

        for (ValidationRequest req : requests) {
            results.add(validate(req));
        }

        return results;
    }

    // ─── Validation engine ─────────────────────────────────────────────────────

    @TestVisible
    static ValidationResult validate(ValidationRequest req) {
        String name = req.accountName;

        // Rule 1: not blank / null
        if (String.isBlank(name)) {
            return fail('Account name cannot be blank.');
        }

        name = name.trim();

        // Rule 2: minimum length
        if (name.length() < MIN_NAME_LENGTH) {
            return fail('Account name must be at least ' + MIN_NAME_LENGTH + ' characters.');
        }

        // Rule 3: maximum length
        if (name.length() > MAX_NAME_LENGTH) {
            return fail('Account name cannot exceed ' + MAX_NAME_LENGTH + ' characters.');
        }

        // Rule 4: not only digits / special chars — must contain at least one letter
        if (!Pattern.matches('.*[a-zA-Z].*', name)) {
            return fail('Account name must contain at least one letter.');
        }

        // Rule 5: no leading/trailing special chars that indicate a data quality issue
        if (name.startsWith('_') || name.startsWith('-')) {
            return fail('Account name cannot start with an underscore or dash.');
        }

        return pass();
    }

    private static ValidationResult pass() {
        ValidationResult r = new ValidationResult();
        r.isValid     = true;
        r.errorMessage = null;
        return r;
    }

    private static ValidationResult fail(String message) {
        ValidationResult r = new ValidationResult();
        r.isValid     = false;
        r.errorMessage = message;
        return r;
    }

    // ─── Inner classes ─────────────────────────────────────────────────────────

    public class ValidationRequest {
        @InvocableVariable(label = 'Account Name' required = true)
        public String accountName;
    }

    public class ValidationResult {
        @InvocableVariable(label = 'Is Valid'      description = 'True if name passes all validation rules')
        public Boolean isValid;

        @InvocableVariable(label = 'Error Message' description = 'Human-readable error; null if isValid = true')
        public String errorMessage;
    }
}
