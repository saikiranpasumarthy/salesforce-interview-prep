/**
 * @description Hand-rolled mock implementation of IUnitOfWork.
 *
 *              Purpose: enable pure unit tests of Service classes without any DML.
 *
 *              Instead of inserting/updating/deleting records, this mock records
 *              what the service *asked* it to do. Tests then assert on those
 *              captured interactions — verifying service logic without an org connection.
 *
 *              Why hand-rolled instead of StubProvider?
 *                StubProvider generates the stub instance via Test.createStub() but
 *                requires the implementing class to live in a test context. A hand-rolled
 *                mock is a plain Apex class that can be instantiated anywhere, makes
 *                assertion helpers first-class (countNewOf, wasCommitted, hasRelationship),
 *                and is easier to understand at a glance in an interview setting.
 *
 *              Usage:
 *                MockUnitOfWork mock = new MockUnitOfWork();
 *                MyService svc = new MyService(mock, ...);
 *                svc.doWork(input);
 *
 *                System.assertEquals(1, mock.countNewOf(Account.SObjectType));
 *                System.assert(mock.wasCommitted());
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public class MockUnitOfWork implements IUnitOfWork {

    // ─── Captured calls ───────────────────────────────────────────────────────────

    /** All records passed to registerNew(), in registration order. */
    public List<SObject>   newRecords      = new List<SObject>();

    /** All records passed to registerDirty(). */
    public List<SObject>   dirtyRecords    = new List<SObject>();

    /** All records passed to registerDeleted(). */
    public List<SObject>   deletedRecords  = new List<SObject>();

    /**
     * Relationship registrations from registerNew(record, field, parent).
     * Each entry is a 3-element list: [child SObject, SObjectField, parent SObject].
     */
    public List<List<Object>> relationships = new List<List<Object>>();

    /** Number of times commitWork() was invoked. */
    public Integer commitCount = 0;

    // ─── Test configuration ───────────────────────────────────────────────────────

    /**
     * Set to true before the test action to simulate a commit failure.
     * Causes commitWork() to throw a UnitOfWork.UnitOfWorkException,
     * letting service error-handling paths be tested without real DML failures.
     */
    public Boolean shouldThrowOnCommit = false;

    // ─── IUnitOfWork implementation ───────────────────────────────────────────────

    public void registerNew(SObject record) {
        newRecords.add(record);
    }

    public void registerNew(SObject record, SObjectField relField, SObject parentRecord) {
        newRecords.add(record);
        relationships.add(new List<Object>{ record, relField, parentRecord });
    }

    public void registerDirty(SObject record) {
        dirtyRecords.add(record);
    }

    public void registerDeleted(SObject record) {
        deletedRecords.add(record);
    }

    public void commitWork() {
        if (shouldThrowOnCommit) {
            throw new UnitOfWork.UnitOfWorkException('Simulated commit failure from MockUnitOfWork');
        }
        commitCount++;
    }

    // ─── Assertion helpers ────────────────────────────────────────────────────────

    /**
     * @return  Number of records registered as new for the given SObjectType.
     *          Example: mock.countNewOf(Account.SObjectType) == 1
     */
    public Integer countNewOf(SObjectType sObjType) {
        Integer count = 0;
        for (SObject r : newRecords) {
            if (r.getSObjectType() == sObjType) count++;
        }
        return count;
    }

    /**
     * @return  Number of records registered as dirty for the given SObjectType.
     */
    public Integer countDirtyOf(SObjectType sObjType) {
        Integer count = 0;
        for (SObject r : dirtyRecords) {
            if (r.getSObjectType() == sObjType) count++;
        }
        return count;
    }

    /**
     * @return  True if commitWork() was called at least once.
     */
    public Boolean wasCommitted() {
        return commitCount > 0;
    }

    /**
     * @description Checks whether a specific parent-child relationship was registered.
     *
     * @param childRecord  The child SObject passed to registerNew(child, field, parent).
     * @param relField     The SObjectField (e.g. Opportunity.AccountId).
     * @return             True if the relationship was registered for this child + field.
     */
    public Boolean hasRelationship(SObject childRecord, SObjectField relField) {
        for (List<Object> rel : relationships) {
            if (rel[0] == childRecord && rel[1] == relField) {
                return true;
            }
        }
        return false;
    }

    /**
     * @return  The parent SObject registered for a given child + field combination,
     *          or null if not found.
     */
    public SObject getRelationshipParent(SObject childRecord, SObjectField relField) {
        for (List<Object> rel : relationships) {
            if (rel[0] == childRecord && rel[1] == relField) {
                return (SObject) rel[2];
            }
        }
        return null;
    }

    /**
     * @return  All newly registered SObjects of the given type.
     */
    public List<SObject> getNewOf(SObjectType sObjType) {
        List<SObject> result = new List<SObject>();
        for (SObject r : newRecords) {
            if (r.getSObjectType() == sObjType) result.add(r);
        }
        return result;
    }
}
