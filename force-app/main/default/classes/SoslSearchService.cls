/**
 * @description SOSL (Salesforce Object Search Language) pattern library.
 *              Demonstrates when and how to use SOSL over SOQL, across-object
 *              searches, search group targeting, RETURNING with WHERE filters,
 *              and dynamic SOSL via Search.query().
 *
 *              SOSL vs SOQL decision rule:
 *                Use SOSL when:
 *                  - Searching text across multiple objects simultaneously
 *                  - The search field is a text/textarea indexed by the search engine
 *                  - You don't know which object holds the data
 *                  - OR conditions across multiple fields (SOQL OR is non-selective)
 *
 *                Use SOQL when:
 *                  - You know the object and the exact field to filter
 *                  - You need aggregate functions, GROUP BY, relationship queries
 *                  - You need FOR UPDATE, OFFSET, date functions
 *                  - The filter is on an indexed field with a selective value
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class SoslSearchService {

    // SOSL result limits:
    //   - Max 2,000 total records returned per SOSL query
    //   - Default per-object limit: 200 records (configurable via LIMIT in RETURNING)
    //   - Max objects in RETURNING clause: 25 (Spring '25)
    private static final Integer DEFAULT_LIMIT_PER_OBJECT = 50;

    // ─── Multi-Object Search ──────────────────────────────────────────────────

    /**
     * @description Global search across Account, Contact, and Case in one SOSL query.
     *              Equivalent to the Salesforce global search bar behaviour.
     *
     *              Search term handling:
     *                - Trailing wildcard (*) enables prefix matching — 'Acme*' matches
     *                  'Acme Inc', 'Acme Corp'. Without *, exact token match only.
     *                - Phrase search: wrap in double quotes '"Acme Corporation"' for
     *                  exact phrase (not tokenized).
     *                - String.escapeSingleQuotes() is NOT sufficient for SOSL injection
     *                  prevention — also strip SOSL operators: ? * { } ( ) ^ ~ : \ " '
     *
     * @param rawSearchTerm  User-supplied search string
     * @return Map of object name → matching SObject records
     */
    public static Map<String, List<SObject>> globalSearch(String rawSearchTerm) {
        String safeSearchTerm = sanitizeSoslTerm(rawSearchTerm) + '*';

        List<List<SObject>> results = [
            FIND :safeSearchTerm IN ALL FIELDS
            RETURNING
                Account(Id, Name, Rating, Industry, AnnualRevenue
                        ORDER BY Name
                        LIMIT  :DEFAULT_LIMIT_PER_OBJECT),
                Contact(Id, FirstName, LastName, Email, Phone, AccountId
                        ORDER BY LastName
                        LIMIT  :DEFAULT_LIMIT_PER_OBJECT),
                Case(Id, Subject, Status, Priority, AccountId
                     ORDER BY CreatedDate DESC
                     LIMIT  :DEFAULT_LIMIT_PER_OBJECT)
        ];

        return new Map<String, List<SObject>>{
            'Account' => results[0],
            'Contact' => results[1],
            'Case'    => results[2]
        };
    }

    /**
     * @description NAME FIELDS search group — searches only Name, First Name,
     *              Last Name fields. More selective than ALL FIELDS, returns
     *              higher-precision results for Account/Contact name lookups.
     *
     *              Search groups:
     *                ALL FIELDS    — all searchable text/textarea/email/phone fields
     *                NAME FIELDS   — Name, FirstName, LastName only
     *                EMAIL FIELDS  — Email fields only
     *                PHONE FIELDS  — Phone fields only
     *
     * @param searchTerm  Account name fragment to search
     * @return Matching Accounts by name
     */
    public static List<Account> searchAccountsByName(String searchTerm) {
        String safeTerm = sanitizeSoslTerm(searchTerm) + '*';
        List<List<SObject>> results = [
            FIND :safeTerm IN NAME FIELDS
            RETURNING Account(
                Id, Name, Rating, AnnualRevenue, Industry, Type
                ORDER BY Name
                LIMIT  100
            )
        ];
        return (List<Account>) results[0];
    }

    /**
     * @description Email-targeted SOSL search. Only searches Email-type fields
     *              across all returned objects. Useful for support ticket lookups
     *              where the user provides their email address.
     *
     * @param email  Full or partial email address to search
     * @return Matching Contacts and Leads by email
     */
    public static Map<String, List<SObject>> searchByEmail(String email) {
        String safeTerm = sanitizeSoslTerm(email);
        List<List<SObject>> results = [
            FIND :safeTerm IN EMAIL FIELDS
            RETURNING
                Contact(Id, FirstName, LastName, Email, AccountId, Account.Name LIMIT 25),
                Lead(Id, FirstName, LastName, Email, Company, Status LIMIT 25)
        ];
        return new Map<String, List<SObject>>{
            'Contact' => results[0],
            'Lead'    => results[1]
        };
    }

    /**
     * @description RETURNING clause with scoped WHERE filter. Searches across all
     *              fields but restricts results to open Cases for a specific Account.
     *              Combines SOSL's cross-field search power with SOQL-like record
     *              filtering in the RETURNING clause.
     *
     * @param searchTerm  Text to search in Case fields
     * @param accountId   Scope results to Cases linked to this Account
     * @return Open Cases for the specified Account matching the search term
     */
    public static List<Case> searchOpenCasesForAccount(String searchTerm, Id accountId) {
        String safeTerm = sanitizeSoslTerm(searchTerm) + '*';
        List<List<SObject>> results = [
            FIND :safeTerm IN ALL FIELDS
            RETURNING Case(
                Id, Subject, Status, Priority, Description, CreatedDate
                WHERE AccountId = :accountId
                  AND IsClosed  = false
                ORDER BY CreatedDate DESC
                LIMIT  25
            )
        ];
        return (List<Case>) results[0];
    }

    // ─── Dynamic SOSL ─────────────────────────────────────────────────────────

    /**
     * @description Dynamic SOSL using Search.query(). Allows the RETURNING object
     *              list to be determined at runtime — useful for configurable search
     *              components where admins choose which objects to include.
     *
     *              Search.query() returns List<List<SObject>> exactly like static SOSL.
     *              Object order in the result mirrors the RETURNING clause order.
     *
     *              Injection risk: objectNames must be validated against an allowlist
     *              before inclusion in the query string. Never accept raw user input
     *              as an object API name in dynamic SOSL.
     *
     * @param searchTerm    Text to search
     * @param objectNames   API names of objects to include in search (allowlisted)
     * @return Raw List<List<SObject>> — caller responsible for casting by object order
     */
    public static List<List<SObject>> dynamicMultiObjectSearch(
        String searchTerm,
        List<String> objectNames
    ) {
        // Allowlist — prevents injection via fabricated object API names
        Set<String> allowedObjects = new Set<String>{
            'Account', 'Contact', 'Case', 'Lead', 'Opportunity'
        };

        List<String> safeObjects = new List<String>();
        for (String obj : objectNames) {
            if (allowedObjects.contains(obj)) {
                safeObjects.add(obj + '(Id, Name LIMIT 20)');
            }
        }
        if (safeObjects.isEmpty()) { return new List<List<SObject>>(); }

        String safeTerm  = sanitizeSoslTerm(searchTerm) + '*';
        String soslQuery =
            'FIND \'' + safeTerm + '\' IN ALL FIELDS ' +
            'RETURNING ' + String.join(safeObjects, ', ');

        return Search.query(soslQuery);
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    /**
     * @description Sanitizes a user-supplied search term for safe SOSL use.
     *              Removes SOSL reserved operators that could alter query semantics.
     *              Reference: https://developer.salesforce.com/docs/atlas.en-us.soql_sosl.meta/soql_sosl/sforce_api_calls_sosl_find.htm
     *
     * @param rawTerm  Unsanitized user input
     * @return Safe search term with SOSL operators removed
     */
    @TestVisible
    private static String sanitizeSoslTerm(String rawTerm) {
        if (String.isBlank(rawTerm)) { return ''; }
        // Remove SOSL special characters: ? & | ! { } [ ] ( ) ^ ~ * : \ " ' + -
        return rawTerm.replaceAll('[?&|!{}\\[\\]()^~*:\\\\"\'\\+\\-]', '').trim();
    }
}
