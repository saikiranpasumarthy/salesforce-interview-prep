/**
 * @description Base interface for all Selector classes.
 *
 *              The Selector Pattern centralises every SOQL query for a given SObject
 *              into a single class with these guarantees:
 *                1. Consistent, explicitly-listed field sets (no SELECT *)
 *                2. Sharing enforcement declared in one place — not scattered across triggers
 *                3. Mocking surface for unit tests that need to bypass DML setup
 *                4. A single place to add WITH SECURITY_ENFORCED, ORDER BY, and LIMIT clauses
 *
 *              Concrete selectors extend this contract with SObject-specific query methods
 *              (e.g., selectByAccountId, selectOpenCases) while this interface provides
 *              the minimum methods every selector must implement.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public interface ISelector {

    /**
     * @return  The SObjectType this selector is responsible for.
     *          Used by UnitOfWork and ServiceFactory for type-safety checks.
     */
    SObjectType getSObjectType();

    /**
     * @description Fetches records by primary key.
     *              Every selector must implement this — it is the base
     *              building block for all other query methods.
     *
     * @param idSet  Non-null set of record Ids.
     * @return       Records with the selector's default field set populated.
     */
    List<SObject> selectById(Set<Id> idSet);

    /**
     * @description Returns a QueryLocator suitable for use in Batch Apex start().
     *              Accepts an optional WHERE clause fragment to narrow scope.
     *
     * @param whereClause  SQL WHERE clause fragment (without the WHERE keyword);
     *                     pass null or blank string for all records.
     * @return             QueryLocator that can stream large datasets.
     */
    Database.QueryLocator getQueryLocator(String whereClause);
}
