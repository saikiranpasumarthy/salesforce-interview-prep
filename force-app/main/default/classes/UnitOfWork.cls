/**
 * @description Implementation of the Unit of Work pattern.
 *
 *              Accumulates INSERT, UPDATE, and DELETE operations for multiple SObject
 *              types in memory, then commits them in a single, ordered, atomic transaction.
 *
 *              Key design decisions:
 *
 *              1. Constructor receives an ordered List<SObjectType> — the dependency order.
 *                 Account must precede Opportunity (parent before child for INSERTs).
 *                 DELETE fires in reverse order (child before parent) automatically.
 *
 *              2. Relationship registration eliminates explicit parent-ID management:
 *                 uow.registerNew(opp, Opportunity.AccountId, newAccount);
 *                 After newAccount is inserted, opp.AccountId = newAccount.Id before
 *                 Opportunity INSERT fires. No caller code ever manually sets the FK.
 *
 *              3. Savepoint wraps the entire commitWork() — if any DML fails, ALL
 *                 work is rolled back and the exception is re-thrown. The caller
 *                 decides whether to log/retry.
 *
 *              4. inherited sharing — the sharing context of the calling service is
 *                 inherited. UoW does not impose its own sharing level; it delegates
 *                 that responsibility to the service layer.
 *
 *              Governor limit profile:
 *                - DML statements: 1 per SObjectType with new records +
 *                                  1 per SObjectType with dirty records +
 *                                  1 per SObjectType with deleted records
 *                - DML rows: total records across all operations (bulk-safe — each
 *                            DML call passes the entire list, not one record at a time)
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public inherited sharing class UnitOfWork implements IUnitOfWork {

    // ─── Custom Exception ─────────────────────────────────────────────────────────
    public class UnitOfWorkException extends Exception {}

    // ─── Internal state ───────────────────────────────────────────────────────────

    /** SObject types in dependency order (parent → child). Drives INSERT order. */
    private final List<SObjectType> sObjectTypes;

    /** Records to INSERT, keyed by SObjectType name. Preserves registration order. */
    private final Map<String, List<SObject>> newRecords;

    /** Records to UPDATE, keyed by SObjectType name → Id → SObject (deduplicates). */
    private final Map<String, Map<Id, SObject>> dirtyRecords;

    /** Records to DELETE, keyed by SObjectType name. */
    private final Map<String, List<SObject>> deletedRecords;

    /**
     * Relationship map: child record → { SObjectField → parent record }.
     * Resolved in resolveRelationships() just before each type's INSERT DML.
     */
    private final Map<SObject, Map<SObjectField, SObject>> relationships;

    // ─── Constructor ──────────────────────────────────────────────────────────────

    /**
     * @param sObjectTypes  Ordered list of SObjectTypes defining commit order.
     *                      Parents must appear before their children.
     *                      Example: new List<SObjectType>{
     *                                   Account.SObjectType,
     *                                   Opportunity.SObjectType,
     *                                   Task.SObjectType
     *                               }
     */
    public UnitOfWork(List<SObjectType> sObjectTypes) {
        this.sObjectTypes  = sObjectTypes;
        this.newRecords    = new Map<String, List<SObject>>();
        this.dirtyRecords  = new Map<String, Map<Id, SObject>>();
        this.deletedRecords = new Map<String, List<SObject>>();
        this.relationships = new Map<SObject, Map<SObjectField, SObject>>();

        for (SObjectType t : sObjectTypes) {
            String key = typeKey(t);
            newRecords.put(key,     new List<SObject>());
            dirtyRecords.put(key,   new Map<Id, SObject>());
            deletedRecords.put(key, new List<SObject>());
        }
    }

    // ─── IUnitOfWork implementation ───────────────────────────────────────────────

    public void registerNew(SObject record) {
        assertRegistered(record);
        newRecords.get(recordKey(record)).add(record);
    }

    public void registerNew(SObject record, SObjectField relField, SObject parentRecord) {
        registerNew(record);
        if (!relationships.containsKey(record)) {
            relationships.put(record, new Map<SObjectField, SObject>());
        }
        relationships.get(record).put(relField, parentRecord);
    }

    public void registerDirty(SObject record) {
        assertRegistered(record);
        dirtyRecords.get(recordKey(record)).put(record.Id, record);
    }

    public void registerDeleted(SObject record) {
        assertRegistered(record);
        deletedRecords.get(recordKey(record)).add(record);
    }

    public void commitWork() {
        Savepoint sp = Database.setSavepoint();
        try {
            doInserts();
            doUpdates();
            doDeletes();
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }

    // ─── DML helpers ─────────────────────────────────────────────────────────────

    /**
     * @description Inserts records in SObjectType dependency order.
     *              Resolves parent-child relationships immediately before each
     *              type's INSERT so that parent Ids (set by prior inserts) are
     *              propagated to the child's lookup field.
     */
    private void doInserts() {
        for (SObjectType t : sObjectTypes) {
            List<SObject> toInsert = newRecords.get(typeKey(t));
            if (!toInsert.isEmpty()) {
                resolveRelationships(toInsert);
                insert toInsert; // after this line, every record in toInsert has an Id
            }
        }
    }

    /**
     * @description Updates records in SObjectType dependency order.
     *              Map<Id, SObject> deduplication means the latest-registered state
     *              wins when the same record is registered dirty multiple times.
     */
    private void doUpdates() {
        for (SObjectType t : sObjectTypes) {
            List<SObject> toUpdate = dirtyRecords.get(typeKey(t)).values();
            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }
        }
    }

    /**
     * @description Deletes records in REVERSE SObjectType order (child before parent).
     *              Prevents "ENTITY_IS_DELETED" or "child records exist" errors on
     *              master-detail relationships.
     */
    private void doDeletes() {
        for (Integer i = sObjectTypes.size() - 1; i >= 0; i--) {
            List<SObject> toDelete = deletedRecords.get(typeKey(sObjectTypes[i]));
            if (!toDelete.isEmpty()) {
                delete toDelete;
            }
        }
    }

    /**
     * @description Resolves all registered parent-child relationships for a batch
     *              of records about to be inserted.
     *
     *              Called AFTER the parent type's INSERT (so parent.Id is populated)
     *              and BEFORE the child type's INSERT (so child.relField gets the Id).
     *
     * @param records  Records about to be inserted for one SObjectType.
     */
    private void resolveRelationships(List<SObject> records) {
        for (SObject record : records) {
            Map<SObjectField, SObject> rels = relationships.get(record);
            if (rels == null) continue;
            for (SObjectField field : rels.keySet()) {
                SObject parent = rels.get(field);
                // parent.Id is populated after the parent type's INSERT block
                record.put(field, parent.Id);
            }
        }
    }

    // ─── Guard helpers ────────────────────────────────────────────────────────────

    private void assertRegistered(SObject record) {
        String key = recordKey(record);
        if (!newRecords.containsKey(key)) {
            throw new UnitOfWorkException(
                'SObjectType "' + key + '" was not included in the UnitOfWork constructor. '
                + 'Add it to the ordered List<SObjectType> before registering records of this type.'
            );
        }
    }

    // ─── Key helpers ─────────────────────────────────────────────────────────────

    private static String typeKey(SObjectType t) {
        return t.getDescribe().getName();
    }

    private static String recordKey(SObject record) {
        return record.getSObjectType().getDescribe().getName();
    }
}
