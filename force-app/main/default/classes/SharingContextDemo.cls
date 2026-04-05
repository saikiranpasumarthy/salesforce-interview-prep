/**
 * @description SharingContextDemo — with sharing / without sharing / inherited sharing
 *              patterns with detailed annotations.
 *
 *              THE THREE SHARING KEYWORDS:
 *              ════════════════════════════
 *
 *              with sharing
 *              ─────────────
 *              • Enforces the running user's record-level access (OWD + sharing rules)
 *              • SOQL returns only records the user can see
 *              • DML throws exception on records the user cannot access
 *              • Does NOT enforce CRUD or FLS — those require manual checks
 *              • Use for: all code called from user-initiated actions (controllers, services)
 *
 *              without sharing
 *              ────────────────
 *              • Bypasses record-level sharing — runs in system context
 *              • SOQL returns ALL records regardless of user access
 *              • Use for: background jobs, admin utilities, system integrations
 *              • DANGER: if called from a 'with sharing' class, sharing is NOT inherited —
 *                the inner 'without sharing' context bypasses sharing regardless of caller
 *
 *              inherited sharing
 *              ──────────────────
 *              • Runs in the sharing context of the CALLER
 *              • If called from 'with sharing' → enforces sharing
 *              • If called from 'without sharing' → bypasses sharing
 *              • If called from no-keyword context → platform decides (usually system)
 *              • Use for: utility/helper classes that should adapt to their caller's context
 *              • Default for @AuraEnabled methods and Flow actions (as of Spring '20)
 *
 *              NO KEYWORD (legacy / implicit)
 *              ────────────────────────────────
 *              • Behaves like 'without sharing' in most contexts
 *              • Platform may apply 'with sharing' for top-level controller methods
 *              • AVOID: unpredictable; use explicit keywords always
 *
 *              SHARING INHERITANCE CHAIN EXAMPLE:
 *              ════════════════════════════════════
 *              Controller (with sharing)
 *                └─► Service (with sharing)  → enforces sharing ✅
 *                    └─► Selector (with sharing) → enforces sharing ✅
 *
 *              Controller (with sharing)
 *                └─► AdminUtil (without sharing) → BYPASSES sharing ⚠️
 *                    └─► Selector (inherited sharing) → BYPASSES (inherits without sharing)
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
public with sharing class SharingContextDemo {

    // ─── with sharing (default — user sees their data only) ───────────────────

    /**
     * @description Returns Accounts visible to the running user.
     *              'with sharing' on the class ensures SOQL respects OWD + sharing rules.
     *
     *              Interview: what does 'with sharing' actually enforce?
     *              RECORD-LEVEL only. CRUD/FLS are NOT enforced by 'with sharing'.
     *              A user with no FLS on AnnualRevenue can still read it in Apex
     *              even with 'with sharing' declared — FLS must be checked separately.
     */
    public static List<Account> getMyAccounts(Set<Id> ids) {
        return [
            SELECT Id, Name, AnnualRevenue
            FROM   Account
            WHERE  Id IN :ids
        ];
        // Returns empty list (not exception) if user has no sharing access to a record
    }

    // ─── without sharing (system context — all data visible) ──────────────────

    /**
     * @description AdminEscalation inner class runs without sharing.
     *
     *              Why an inner class instead of a separate top-level class?
     *              Keeps the pattern contained and makes the intent explicit:
     *              the outer class (with sharing) delegates ONLY specific operations
     *              to the inner class (without sharing) when elevated access is needed.
     *
     *              Common use cases for without sharing:
     *              • Audit log writes (must write regardless of user access)
     *              • Scheduled batch jobs (no user context)
     *              • System integrations (all records must be visible)
     *              • Security enforcement code itself (must see all records to validate)
     */
    public without sharing class AdminEscalation {

        /**
         * @description Returns ALL Accounts regardless of the running user's sharing access.
         *              This is an elevated access operation — use only for admin/system tasks.
         */
        public List<Account> getAllAccounts(Set<Id> ids) {
            return [
                SELECT Id, Name, AnnualRevenue, OwnerId
                FROM   Account
                WHERE  Id IN :ids
            ];
        }

        /**
         * @description Writes an audit log record regardless of the user's sharing access.
         *              Audit records must always be created even if the user's OWD
         *              prevents them from creating records they "own".
         */
        public void writeAuditLog(Id recordId, String action, String details) {
            // In a real implementation: insert a custom audit log sObject
            // Demonstrated as a debug log here for simplicity
            System.debug(LoggingLevel.INFO,
                '[AUDIT] Record=' + recordId + ' Action=' + action + ' Details=' + details);
        }
    }

    // ─── inherited sharing (adapts to caller's context) ───────────────────────

    /**
     * @description SharingAdaptiveHelper runs in the sharing context of its caller.
     *
     *              When called from SharingContextDemo (with sharing):
     *                → SOQL enforces sharing rules (user sees only their data)
     *              When called from AdminEscalation (without sharing):
     *                → SOQL bypasses sharing rules (sees all data)
     *
     *              This is the recommended pattern for utility/helper classes that
     *              are designed to work in both contexts. The Selector pattern from
     *              Day 6 used 'with sharing' — the stricter choice for a multi-tenant
     *              data access layer. For a generic helper, 'inherited sharing' is safer.
     */
    public inherited sharing class SharingAdaptiveHelper {

        public List<Account> queryAccounts(Set<Id> ids) {
            // Runs with or without sharing depending on the caller
            return [
                SELECT Id, Name
                FROM   Account
                WHERE  Id IN :ids
            ];
        }

        public Integer countAccounts(String industry) {
            return [
                SELECT COUNT()
                FROM   Account
                WHERE  Industry = :industry
            ];
        }
    }

    // ─── Database.query with dynamic sharing context ──────────────────────────

    /**
     * @description Demonstrates dynamic SOQL — sharing context is still determined
     *              by the class keyword, not by whether SOQL is static or dynamic.
     *
     *              Common misconception: "Database.query bypasses sharing rules."
     *              FACT: Database.query respects the class's sharing keyword.
     *              In a 'with sharing' class, Database.query ALSO enforces sharing.
     */
    public static List<SObject> dynamicQuery(String soql) {
        // 'with sharing' on this class applies to Database.query too
        return Database.query(soql); // NOPMD — intentional dynamic SOQL for demo
    }

    // ─── Public method exposing admin escalation ───────────────────────────────

    /**
     * @description Pattern: a 'with sharing' outer method delegates a specific
     *              privileged operation to 'without sharing' inner class.
     *
     *              This is a deliberate, narrow escalation — NOT a security bypass.
     *              The caller still runs 'with sharing' for everything else.
     *
     *              Contrast with: calling AdminEscalation everywhere (bad pattern)
     *              which would silently bypass sharing for all operations.
     */
    public static List<Account> getAccountsWithElevatedAccess(Set<Id> ids) {
        return new AdminEscalation().getAllAccounts(ids);
    }

    /**
     * @description Runs a privileged audit write without exposing general without-sharing access.
     */
    public static void logAuditEvent(Id recordId, String action, String details) {
        new AdminEscalation().writeAuditLog(recordId, action, details);
    }
}
