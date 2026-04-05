/**
 * @description SecurityService — CRUD/FLS enforcement and safe data access patterns.
 *
 *              SALESFORCE SECURITY LAYERS (interview framework):
 *              ══════════════════════════════════════════════════
 *              Layer 1 — OBJECT LEVEL (CRUD)
 *                Read (isAccessible), Create (isCreateable), Edit (isUpdateable),
 *                Delete (isDeletable). Controlled by Profile + Permission Sets.
 *
 *              Layer 2 — FIELD LEVEL (FLS)
 *                isAccessible (read), isUpdateable (edit), isCreateable (create).
 *                Controlled by Profile + Permission Sets per field.
 *
 *              Layer 3 — RECORD LEVEL (Sharing)
 *                OWD → Sharing Rules → Manual Share → Apex Managed Share → Role Hierarchy.
 *                'with sharing' enforces record-level access in SOQL/DML.
 *
 *              THREE WAYS TO ENFORCE CRUD/FLS IN APEX:
 *              ═════════════════════════════════════════
 *              1. Schema.describe()   — manual; verbose; full control over error messages
 *              2. WITH SECURITY_ENFORCED — SOQL clause; throws QueryException for FLS violations
 *              3. Security.stripInaccessible() — strips inaccessible fields; no exception
 *
 *              WHEN DOES APEX BYPASS SECURITY BY DEFAULT?
 *              ═══════════════════════════════════════════
 *              Apex runs in "system context" by default — CRUD, FLS, and sharing rules
 *              are NOT enforced unless explicitly requested. This means:
 *                - A query in Apex can read fields the running user cannot see in UI
 *                - DML in Apex can update fields the running user cannot edit in UI
 *                - 'with sharing' only enforces record-level access (sharing model),
 *                  NOT CRUD/FLS — CRUD/FLS must be checked manually or via stripInaccessible
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
public with sharing class SecurityService {

    // ─── Custom exceptions ────────────────────────────────────────────────────

    public class CrudException  extends Exception {}
    public class FlsException   extends Exception {}

    // ─── CRUD checks ──────────────────────────────────────────────────────────

    /**
     * @description Asserts the running user has READ access on the given sObject.
     *              Throws CrudException (subtype of Exception) if not.
     *
     *              Why throw an exception rather than return false?
     *              Callers in service layer should not silently swallow access denials.
     *              Throwing lets the controller/UI show a meaningful error to the user.
     *
     * @param objType  Schema.SObjectType (e.g., Schema.Account.SObjectType)
     */
    public static void assertReadAccess(Schema.SObjectType objType) {
        if (!objType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            throw new CrudException(
                'You do not have read access on ' + objType.getDescribe(SObjectDescribeOptions.DEFERRED).getLabel()
            );
        }
    }

    public static void assertCreateAccess(Schema.SObjectType objType) {
        if (!objType.getDescribe(SObjectDescribeOptions.DEFERRED).isCreateable()) {
            throw new CrudException(
                'You do not have create access on ' + objType.getDescribe(SObjectDescribeOptions.DEFERRED).getLabel()
            );
        }
    }

    public static void assertUpdateAccess(Schema.SObjectType objType) {
        if (!objType.getDescribe(SObjectDescribeOptions.DEFERRED).isUpdateable()) {
            throw new CrudException(
                'You do not have edit access on ' + objType.getDescribe(SObjectDescribeOptions.DEFERRED).getLabel()
            );
        }
    }

    public static void assertDeleteAccess(Schema.SObjectType objType) {
        if (!objType.getDescribe(SObjectDescribeOptions.DEFERRED).isDeletable()) {
            throw new CrudException(
                'You do not have delete access on ' + objType.getDescribe(SObjectDescribeOptions.DEFERRED).getLabel()
            );
        }
    }

    // ─── FLS checks ───────────────────────────────────────────────────────────

    /**
     * @description Returns the subset of field names the running user can READ.
     *
     *              Use case: build a dynamic SOQL query that only includes fields
     *              the user has FLS read access to. Avoids SOQL exceptions while
     *              preserving as much data as possible.
     *
     * @param objType    Schema.SObjectType to check
     * @param fieldNames Candidate field API names to check
     * @return           Only the field names that are readable
     */
    public static List<String> getReadableFields(
        Schema.SObjectType objType,
        List<String> fieldNames
    ) {
        Map<String, Schema.SObjectField> fieldMap =
            objType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();

        List<String> readable = new List<String>();
        for (String fieldName : fieldNames) {
            Schema.SObjectField fld = fieldMap.get(fieldName.toLowerCase());
            if (fld != null && fld.getDescribe().isAccessible()) {
                readable.add(fieldName);
            }
        }
        return readable;
    }

    /**
     * @description Returns the subset of field names the running user can EDIT.
     */
    public static List<String> getEditableFields(
        Schema.SObjectType objType,
        List<String> fieldNames
    ) {
        Map<String, Schema.SObjectField> fieldMap =
            objType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();

        List<String> editable = new List<String>();
        for (String fieldName : fieldNames) {
            Schema.SObjectField fld = fieldMap.get(fieldName.toLowerCase());
            if (fld != null && fld.getDescribe().isUpdateable()) {
                editable.add(fieldName);
            }
        }
        return editable;
    }

    /**
     * @description Asserts the running user can read a specific field.
     *              Throws FlsException if not.
     */
    public static void assertFieldReadable(Schema.SObjectField field) {
        if (!field.getDescribe().isAccessible()) {
            throw new FlsException(
                'You do not have read access on field: ' + field.getDescribe().getLabel()
            );
        }
    }

    /**
     * @description Asserts the running user can edit a specific field.
     */
    public static void assertFieldEditable(Schema.SObjectField field) {
        if (!field.getDescribe().isUpdateable()) {
            throw new FlsException(
                'You do not have edit access on field: ' + field.getDescribe().getLabel()
            );
        }
    }

    // ─── WITH SECURITY_ENFORCED pattern ────────────────────────────────────────

    /**
     * @description Queries Accounts using WITH SECURITY_ENFORCED.
     *
     *              WITH SECURITY_ENFORCED (introduced Winter '20):
     *              ═════════════════════════════════════════════════
     *              • Automatically checks FLS for every field in SELECT and WHERE
     *              • Throws System.QueryException if the user lacks access to any field
     *              • Easier than manual Schema checks but less flexible:
     *                - Cannot partially succeed (all-or-nothing)
     *                - Cannot customise the error message
     *                - Does NOT check CRUD (object-level) — only FLS
     *
     *              Use when: you want fail-fast FLS enforcement with minimal code.
     *              Avoid when: you need partial field access or custom error handling.
     *
     * @param ids  Account Ids to query
     * @return     Accounts with security-enforced field access
     * @throws     System.QueryException if user lacks FLS on Name, Type, or AnnualRevenue
     */
    public static List<Account> queryAccountsSecure(Set<Id> ids) {
        // WITH SECURITY_ENFORCED checks FLS on all queried fields
        // Throws QueryException on first FLS violation found
        return [
            SELECT Id, Name, Type, AnnualRevenue, Rating, OwnerId
            FROM   Account
            WHERE  Id IN :ids
            WITH   SECURITY_ENFORCED
        ];
    }

    // ─── Security.stripInaccessible pattern ────────────────────────────────────

    /**
     * @description Strips fields the running user cannot READ from query results.
     *
     *              Security.stripInaccessible (introduced Winter '20):
     *              ════════════════════════════════════════════════════
     *              • Removes inaccessible fields from SObject records (does NOT throw)
     *              • Returns SObjectAccessDecision with:
     *                - getRecords()       — scrubbed record list (same type as input)
     *                - getRemovedFields() — Map<sObjectType, Set<String>> of removed fields
     *              • AccessType options:
     *                READABLE   — for read operations (strips fields user can't see)
     *                CREATABLE  — for insert operations (strips non-creatable fields)
     *                UPDATABLE  — for update operations (strips non-updateable fields)
     *                UPSERTABLE — for upsert operations
     *
     *              When to use stripInaccessible vs WITH SECURITY_ENFORCED:
     *              • stripInaccessible — graceful degradation; shows available fields
     *              • WITH SECURITY_ENFORCED — fail-fast; all fields must be accessible
     *
     * @param records  Records queried without enforcement
     * @return         SObjectAccessDecision with scrubbed records + removed field report
     */
    public static SObjectAccessDecision stripInaccessibleFields(
        List<SObject> records,
        AccessType accessType
    ) {
        return Security.stripInaccessible(accessType, records);
    }

    /**
     * @description Query Accounts and strip any fields the user cannot read.
     *              Never throws — returns whatever the user can see.
     *
     * @param ids  Account Ids to query
     * @return     Accounts with inaccessible fields silently removed
     */
    public static List<Account> queryAccountsStripped(Set<Id> ids) {
        // Query without enforcement first (system context has full access to fields)
        List<Account> rawResults = [
            SELECT Id, Name, Type, AnnualRevenue, Rating, Phone, OwnerId
            FROM   Account
            WHERE  Id IN :ids
        ];

        // Strip fields the running user cannot read — no exception thrown
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.READABLE,
            rawResults
        );

        // Log which fields were stripped (useful for debugging FLS mismatches)
        Map<String, Set<String>> removed = decision.getRemovedFields();
        if (!removed.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                '[SecurityService] Fields stripped due to FLS: ' + JSON.serialize(removed));
        }

        return (List<Account>) decision.getRecords();
    }

    // ─── Combined check helper ────────────────────────────────────────────────

    /**
     * @description Checks whether the running user has both CRUD and FLS access
     *              for a create operation on the given fields.
     *
     * @param objType    Object to check
     * @param fieldNames Field API names to validate for createability
     * @return           ValidationResult with isValid flag and list of violations
     */
    public static ValidationResult checkCreateAccess(
        Schema.SObjectType objType,
        List<String> fieldNames
    ) {
        ValidationResult result = new ValidationResult();
        Schema.DescribeSObjectResult objDescribe =
            objType.getDescribe(SObjectDescribeOptions.DEFERRED);

        // CRUD check
        if (!objDescribe.isCreateable()) {
            result.violations.add('No CREATE permission on ' + objDescribe.getLabel());
        }

        // FLS check on each field
        Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();
        for (String fieldName : fieldNames) {
            Schema.SObjectField fld = fieldMap.get(fieldName.toLowerCase());
            if (fld == null) {
                result.violations.add('Unknown field: ' + fieldName);
            } else if (!fld.getDescribe().isCreateable()) {
                result.violations.add('No CREATE FLS on field: ' + fld.getDescribe().getLabel());
            }
        }

        result.isValid = result.violations.isEmpty();
        return result;
    }

    // ─── Inner types ──────────────────────────────────────────────────────────

    public class ValidationResult {
        public Boolean      isValid    = true;
        public List<String> violations = new List<String>();
    }
}
