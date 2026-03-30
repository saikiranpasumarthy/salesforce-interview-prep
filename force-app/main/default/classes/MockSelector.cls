/**
 * @description Hand-rolled mock implementation of ISelector.
 *
 *              Purpose: enable pure unit tests of Service classes that use ISelector
 *              without issuing any SOQL queries or requiring database records.
 *
 *              Tests inject a pre-built list of SObjects as the return value for
 *              selectById(). The service under test calls selectById() and receives
 *              the injected data — completely bypassing the database.
 *
 *              Governor limit benefit:
 *                A test using MockSelector fires 0 SOQL queries in the service path.
 *                This allows asserting Limits.getQueries() == 0 inside startTest/stopTest,
 *                proving the service does not issue unexpected queries.
 *
 *              Limitations:
 *                - Only stubs selectById() and getQueryLocator() from ISelector.
 *                - Domain-specific methods (selectByAccountId, etc.) are on concrete
 *                  selectors and require either subclassing or a dedicated mock.
 *                - getQueryLocator() returns null — do not use in Batch Apex contexts.
 *
 *              Usage:
 *                List<Account> fakeAccounts = new List<Account>{
 *                    new Account(Id = ffId, Name = 'Mock Corp', AnnualRevenue = 500000)
 *                };
 *                MockSelector mockSel = new MockSelector(Account.SObjectType, fakeAccounts);
 *                MyService svc = new MyService(mockSel, mockUow);
 *                svc.process(idSet);
 *                System.assertEquals(1, mockSel.selectByIdCallCount);
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public class MockSelector implements ISelector {

    private final SObjectType       sObjType;
    private final List<SObject>     stubbedRecords;

    /** Number of times selectById() was called — for interaction verification. */
    public Integer selectByIdCallCount = 0;

    /**
     * @param sObjType       The SObjectType this mock represents.
     * @param stubbedRecords Records to return when selectById() is called.
     *                       Build these with fake Ids using MockIdGenerator.
     */
    public MockSelector(SObjectType sObjType, List<SObject> stubbedRecords) {
        this.sObjType       = sObjType;
        this.stubbedRecords = stubbedRecords != null
                              ? stubbedRecords
                              : new List<SObject>();
    }

    // ─── ISelector implementation ─────────────────────────────────────────────────

    public SObjectType getSObjectType() {
        return sObjType;
    }

    /**
     * @description Returns the pre-loaded stub records regardless of the idSet.
     *              Tests inject records whose Ids match the expected call pattern.
     *              The idSet itself is not filtered — all stubbedRecords are returned.
     */
    public List<SObject> selectById(Set<Id> idSet) {
        selectByIdCallCount++;
        return stubbedRecords;
    }

    /**
     * @description Not supported in mock context.
     *              getQueryLocator() is used only in Batch Apex start() — Batch
     *              tests should use the real selector with @TestSetup data.
     */
    public Database.QueryLocator getQueryLocator(String whereClause) {
        return null;
    }

    // ─── Helper ───────────────────────────────────────────────────────────────────

    /**
     * @description Generates a fake Id for a given SObjectType, usable in
     *              in-memory SObject construction without a DML insert.
     *
     *              Format: '001' + 15-char padded index (standard Salesforce Id length).
     *              The prefix is derived from SObjectType.getDescribe().getKeyPrefix().
     *
     * @param sObjType  The SObjectType to generate an Id for.
     * @param index     Unique index to differentiate multiple fake Ids (1-based).
     * @return          An 18-character fake Salesforce Id string cast to Id.
     */
    public static Id fakeId(SObjectType sObjType, Integer index) {
        String prefix = sObjType.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(index).leftPad(15, '0');
        return (Id)(prefix + suffix);
    }
}
