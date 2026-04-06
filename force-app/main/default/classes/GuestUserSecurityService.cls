/**
 * @description Guest User security patterns — safe data access, sharing enforcement,
 *              input sanitisation, and anti-patterns to avoid in Experience Cloud.
 *
 *              GUEST USER SECURITY CHECKLIST (most common interview scenario):
 *
 *              1. CLASS SHARING KEYWORD
 *                 - All Apex accessed by guest MUST be 'with sharing'
 *                 - 'without sharing' in a guest-accessible class is a critical finding
 *                 - 'inherited sharing' is safe ONLY if the caller is 'with sharing'
 *
 *              2. FLS / CRUD ENFORCEMENT
 *                 - WITH SECURITY_ENFORCED or Security.stripInaccessible() on all queries
 *                 - Schema.describe().isAccessible() on all fields before read
 *                 - Guest profile has very limited field access — never assume access
 *
 *              3. RECORD VISIBILITY
 *                 - Guest user sees only records shared to the Guest profile via:
 *                   a) OWD set to Public Read (rare — use sparingly)
 *                   b) Sharing Rules — criteria-based (e.g. Status = 'Published')
 *                   c) Apex Managed Sharing — programmatic share creation
 *                 - Guest user CANNOT own records
 *
 *              4. INPUT VALIDATION
 *                 - All guest-submitted inputs must be validated and sanitised
 *                 - Never use guest input directly in dynamic SOQL (injection risk)
 *                 - Use bind variables (:variable) always
 *
 *              5. RATE LIMITING
 *                 - Guest users share API limits with the org — DoS risk
 *                 - Implement request throttling via Platform Cache counter
 *
 *              6. SITE SETTINGS AUDIT
 *                 - Disable "Allow Guest users to access public APIs"
 *                 - Disable "View All Users" on Guest profile
 *                 - Disable "Password Never Expires" on Guest profile
 *                 - Review all Apex classes, Flows, and LWC accessible without login
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class GuestUserSecurityService {

    // Configurable rate limit — requests per window per session
    @TestVisible static Integer RATE_LIMIT_MAX   = 10;
    @TestVisible static Integer RATE_LIMIT_WINDOW = 60; // seconds

    // ─── Safe data access for guest users ────────────────────────────────────

    /**
     * Returns publicly visible Knowledge Articles for a given topic.
     * Enforces FLS via WITH SECURITY_ENFORCED.
     * 'with sharing' on the class enforces record-level visibility (sharing rules).
     *
     * Interview: Knowledge__kav queries require 'knowledge__kav' permissions.
     * Guest users typically have Read access on KnowledgeArticleVersion only —
     * they see Published articles shared to the guest profile via sharing rules.
     *
     * @param topic     Topic to filter by (bind variable — prevents SOQL injection)
     * @param pageSize  Max records to return
     */
    public static List<SObject> getPublicArticles(String topic, Integer pageSize) {
        Integer size = Math.min(pageSize != null ? pageSize : 10, 50);
        try {
            return Database.query(
                'SELECT Id, Title, Summary, LastPublishedDate '
                + 'FROM Knowledge__kav '
                + 'WHERE PublishStatus = \'Online\' '
                + 'AND Language = \'en_US\' '
                + 'AND (Topic__c = :topic OR :topic = null) '
                + 'WITH SECURITY_ENFORCED '
                + 'ORDER BY LastPublishedDate DESC '
                + 'LIMIT :size'
            );
        } catch (System.QueryException e) {
            // Knowledge not enabled in this org
            return new List<SObject>();
        }
    }

    /**
     * Submits a web-to-case equivalent form from an Experience Cloud site.
     * Validates and sanitises all guest-submitted inputs before DML.
     *
     * Interview: Guest users CAN create Cases if:
     *   a) Case OWD includes Create for guest profile, OR
     *   b) A 'without sharing' service class creates the Case (anti-pattern — use sparingly)
     *   c) Use Site.createExternalUser() / guest sharing rule for the created record
     *
     * In 'with sharing' context, guest user can only create if their profile has
     * Create permission on Case (typically granted via permission set).
     *
     * @param subject      Case subject (required)
     * @param description  Case description (optional)
     * @param email        Reporter's email (stored in SuppliedEmail)
     * @param name         Reporter's name (stored in SuppliedName)
     * @return             Created Case Id, or null if validation fails
     */
    public static Id submitSupportRequest(
            String subject, String description, String email, String name) {
        // Input validation
        List<String> errors = validateSupportRequest(subject, email);
        if (!errors.isEmpty()) {
            throw new GuestSecurityException('Validation failed: ' + String.join(errors, '; '));
        }

        Case c = new Case(
            Subject       = sanitise(subject, 255),
            Description   = sanitise(description, 32000),
            SuppliedEmail = sanitise(email, 80),
            SuppliedName  = sanitise(name, 80),
            Origin        = 'Web',
            Status        = 'New'
        );
        insert c;
        return c.Id;
    }

    // ─── Input sanitisation ───────────────────────────────────────────────────

    /**
     * Sanitises a string value for safe storage:
     *   - Strips HTML tags (XSS prevention)
     *   - Trims leading/trailing whitespace
     *   - Truncates to maxLength
     *
     * @param input      Raw user input
     * @param maxLength  Maximum allowed length
     * @return           Sanitised string, or null if input is blank
     */
    @TestVisible
    static String sanitise(String input, Integer maxLength) {
        if (String.isBlank(input)) { return null; }
        String cleaned = input
            .replaceAll('<[^>]+>', '')      // strip HTML tags
            .replaceAll('&[a-zA-Z]+;', '') // strip HTML entities
            .trim();
        return cleaned.length() > maxLength ? cleaned.left(maxLength) : cleaned;
    }

    /**
     * Validates a support request submission — returns list of validation messages.
     */
    @TestVisible
    static List<String> validateSupportRequest(String subject, String email) {
        List<String> errors = new List<String>();
        if (String.isBlank(subject)) { errors.add('Subject is required'); }
        if (subject != null && subject.length() > 255) {
            errors.add('Subject must be 255 characters or fewer');
        }
        if (String.isBlank(email)) { errors.add('Email is required'); }
        if (String.isNotBlank(email) && !isValidEmail(email)) {
            errors.add('Email format is invalid');
        }
        return errors;
    }

    /**
     * Basic email format validation using a simple pattern.
     * Use for guest-submitted forms — not a replacement for email verification flow.
     */
    @TestVisible
    static Boolean isValidEmail(String email) {
        if (String.isBlank(email)) { return false; }
        String pattern = '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$';
        return Pattern.matches(pattern, email);
    }

    // ─── Rate limiting (guest request throttling) ─────────────────────────────

    /**
     * Enforces a per-session request rate limit using Platform Cache.
     *
     * Pattern:
     *   - Cache key = 'ratelimit_' + sessionHash (hashed session Id for privacy)
     *   - Counter incremented each call; throw if over RATE_LIMIT_MAX in window
     *   - TTL = RATE_LIMIT_WINDOW seconds — counter auto-expires
     *
     * Interview: Rate limiting guest users is critical to prevent DoS attacks where
     * a bot submits thousands of form submissions, consuming Apex CPU + DML limits.
     *
     * @param sessionId  Current session identifier (hash before storing)
     */
    public static void enforceRateLimit(String sessionId) {
        String cacheKey = 'ratelimit_' + ExperienceCloudService.buildAlias(sessionId, '');
        PlatformCacheService.useMock = Test.isRunningTest(); // use mock in tests

        Integer count = (Integer) PlatformCacheService.get(cacheKey);
        if (count == null) { count = 0; }
        count++;
        if (count > RATE_LIMIT_MAX) {
            throw new GuestSecurityException(
                'Rate limit exceeded. Please wait before submitting again.');
        }
        PlatformCacheService.put(cacheKey, count, RATE_LIMIT_WINDOW);
    }

    // ─── Apex Managed Sharing for guest-created records ───────────────────────

    /**
     * Creates a sharing record granting the Guest User profile read access
     * to a specific Account for public profile display.
     *
     * Interview: Guest users can only access records shared to them explicitly.
     * Options:
     *   a) Criteria-based Sharing Rule (declarative, always preferred first)
     *   b) Apex Managed Sharing (programmatic, for dynamic share conditions)
     *
     * AccountShare.RowCause = Schema.AccountShare.rowCause.Manual for manual shares.
     * For custom share reasons: define in Setup → Sharing Settings → Share Reason.
     *
     * @param accountId   Account to share with the guest profile
     * @param guestUserId Guest User record Id
     */
    public static void shareAccountWithGuestUser(Id accountId, Id guestUserId) {
        AccountShare share = new AccountShare(
            AccountId                = accountId,
            UserOrGroupId            = guestUserId,
            AccountAccessLevel       = 'Read',
            OpportunityAccessLevel   = 'None',
            CaseAccessLevel          = 'None',
            RowCause                 = Schema.AccountShare.rowCause.Manual
        );
        Database.insert(share, false); // false = partial success; ignore if already exists
    }

    // ─── Exception ────────────────────────────────────────────────────────────

    public class GuestSecurityException extends Exception {}
}
