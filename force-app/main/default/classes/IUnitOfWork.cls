/**
 * @description Interface for the Unit of Work pattern.
 *
 *              Unit of Work accumulates DML operations in memory across multiple
 *              SObject types and commits them in a single ordered transaction.
 *              This interface decouples service classes from the concrete UnitOfWork
 *              implementation, enabling clean unit testing via mock injection.
 *
 *              The three registration methods map to the three DML categories:
 *                registerNew()     → INSERT (after resolving parent-child relationships)
 *                registerDirty()   → UPDATE
 *                registerDeleted() → DELETE (in reverse dependency order)
 *
 *              Relationship registration is the most powerful feature:
 *                uow.registerNew(opp, Opportunity.AccountId, parentAccount);
 *              tells the UoW "set opp.AccountId = parentAccount.Id after parentAccount is inserted"
 *              — eliminating the need for callers to manage parent IDs manually.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public interface IUnitOfWork {

    /**
     * @description Registers a new record for insertion.
     *              The record must not yet have an Id.
     *              DML executes in the order defined by the SObjectType list
     *              passed to the UnitOfWork constructor.
     *
     * @param record  SObject to insert.
     */
    void registerNew(SObject record);

    /**
     * @description Registers a new record for insertion and declares a
     *              parent-child relationship to be resolved after the parent
     *              record is inserted.
     *
     *              Example:
     *                uow.registerNew(opp, Opportunity.AccountId, newAccount);
     *              → After newAccount is inserted, opp.AccountId = newAccount.Id
     *
     * @param record       Child SObject to insert.
     * @param relField     The lookup/master-detail field on the child.
     * @param parentRecord The parent SObject (must also be registered via registerNew).
     */
    void registerNew(SObject record, SObjectField relField, SObject parentRecord);

    /**
     * @description Registers an existing record for update.
     *              The record must have a populated Id.
     *              If the same record is registered multiple times, the last
     *              registered state wins (Map<Id, SObject> deduplifies by Id).
     *
     * @param record  SObject to update.
     */
    void registerDirty(SObject record);

    /**
     * @description Registers an existing record for deletion.
     *              Delete DML fires in reverse SObjectType order (child before parent).
     *
     * @param record  SObject to delete (must have a populated Id).
     */
    void registerDeleted(SObject record);

    /**
     * @description Commits all registered work in a single transaction.
     *
     *              Order of operations:
     *                1. INSERT — in SObjectType dependency order; relationships resolved
     *                            between each type's batch
     *                2. UPDATE — in SObjectType order
     *                3. DELETE — in reverse SObjectType order (child before parent)
     *
     *              A Savepoint is set before the first DML operation. If any DML fails,
     *              the entire transaction is rolled back to the savepoint and the
     *              exception is re-thrown to the caller.
     */
    void commitWork();
}
