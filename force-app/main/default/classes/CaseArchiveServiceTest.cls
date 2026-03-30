/**
 * @description Tests for CaseArchiveService and Big Object patterns.
 *
 *              Big Object testing notes:
 *                - Database.insertImmediate() works in test context and the inserted
 *                  records ARE visible to subsequent queries in the same test method.
 *                - Unlike standard objects, Big Object test data does NOT require
 *                  SeeAllData=true — insertImmediate writes to the test-scoped context.
 *                - COUNT() aggregate queries on Big Objects work in test context.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
@IsTest
private class CaseArchiveServiceTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // mapCasesToArchives (private, tested via @TestVisible)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void mapCasesToArchives_correctlyMapsAllFields() {
        Account acc = TestDataFactory.createAccount(true);
        Case c = new Case(
            AccountId = acc.Id,
            Subject   = 'Test Archive Case',
            Status    = 'Closed',
            Priority  = 'High',
            OwnerId   = UserInfo.getUserId()
        );
        insert c;
        c = [SELECT Id, Subject, Status, Priority, AccountId, OwnerId, ClosedDate
             FROM Case WHERE Id = :c.Id];

        Test.startTest();
        List<Case_Archive__b> archives =
            CaseArchiveService.mapCasesToArchives(new List<Case>{ c });
        Test.stopTest();

        System.assertEquals(1, archives.size(), 'Should produce one archive record per Case');
        System.assertEquals(c.Id,        archives[0].Case_Id__c,    'Case_Id__c should match Case.Id');
        System.assertEquals(acc.Id,      archives[0].Account_Id__c, 'Account_Id__c should match Case.AccountId');
        System.assertEquals('Test Archive Case', archives[0].Subject__c);
        System.assertEquals('Closed',    archives[0].Status__c);
        System.assertEquals('High',      archives[0].Priority__c);
    }

    @IsTest
    static void mapCasesToArchives_longSubjectTruncatedAt255() {
        Account acc = TestDataFactory.createAccount(true);
        Case c = new Case(
            AccountId = acc.Id,
            Subject   = 'X'.repeat(300),
            Status    = 'Closed',
            OwnerId   = UserInfo.getUserId()
        );
        insert c;
        c = [SELECT Id, Subject, Status, Priority, AccountId, OwnerId, ClosedDate
             FROM Case WHERE Id = :c.Id];

        Test.startTest();
        List<Case_Archive__b> archives =
            CaseArchiveService.mapCasesToArchives(new List<Case>{ c });
        Test.stopTest();

        System.assert(archives[0].Subject__c.length() <= 255,
            'Subject longer than 255 chars should be truncated by abbreviate()');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // archiveClosedCases
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void archiveClosedCases_closedOldCases_insertsToBigObject() {
        Account acc = TestDataFactory.createAccount(true);
        Case oldClosed = new Case(
            AccountId = acc.Id,
            Subject   = 'Old Case',
            Status    = 'Closed',
            OwnerId   = UserInfo.getUserId()
        );
        insert oldClosed;

        Test.startTest();
        // daysOld=0 archives all closed cases (closed right now still qualifies)
        Integer count = CaseArchiveService.archiveClosedCases(0, 50);
        Test.stopTest();

        System.assert(count >= 1, 'At least one Case should be successfully archived');
    }

    @IsTest
    static void archiveClosedCases_openCases_notArchived() {
        Account acc = TestDataFactory.createAccount(true);
        insert new Case(AccountId=acc.Id, Subject='Open Case',
                        Status='New', OwnerId=UserInfo.getUserId());

        Test.startTest();
        Integer count = CaseArchiveService.archiveClosedCases(0, 50);
        Test.stopTest();

        // Open cases should not be in the archive query (IsClosed = false excluded)
        // Count may be 0 if no closed cases exist in the test org context
        System.assertEquals(0, count,
            'Open cases must not be archived — IsClosed=false excludes them from query');
    }

    @IsTest
    static void archiveClosedCases_casesWithoutAccount_excluded() {
        // Cases without AccountId cannot be archived — Big Object requires Account_Id__c
        Case caseNoAccount = new Case(
            Subject = 'No Account',
            Status  = 'Closed',
            OwnerId = UserInfo.getUserId()
        );
        insert caseNoAccount;

        Test.startTest();
        Integer count = CaseArchiveService.archiveClosedCases(0, 50);
        Test.stopTest();

        // Should be 0 — no closed cases WITH an AccountId exist in this test
        // (the case above has no AccountId so is filtered out by AND AccountId != null)
        System.assertEquals(0, count,
            'Cases without AccountId must not be archived — violates index field requirement');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // getArchivedCasesForAccount
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getArchivedCasesForAccount_returnsInsertedArchives() {
        String fakeAccountId = '001000000000001AAA';
        DateTime archiveDate = DateTime.now().addDays(-10);

        // Insert directly to Big Object — bypasses Case lifecycle
        List<Case_Archive__b> toInsert = new List<Case_Archive__b>{
            new Case_Archive__b(
                Case_Id__c     = '500000000000001AAA',
                Account_Id__c  = fakeAccountId,
                Subject__c     = 'Archived Case 1',
                Status__c      = 'Closed',
                Priority__c    = 'Medium',
                Owner_Id__c    = UserInfo.getUserId(),
                Closed_Date__c = archiveDate
            )
        };
        Database.insertImmediate(toInsert);

        Test.startTest();
        List<Case_Archive__b> results =
            CaseArchiveService.getArchivedCasesForAccount(
                fakeAccountId,
                archiveDate.addDays(-1)  // fromDate just before archive date
            );
        Test.stopTest();

        System.assert(results.size() >= 1,
            'Should retrieve the archive record inserted via insertImmediate');
        System.assertEquals('Archived Case 1', results[0].Subject__c,
            'Subject should match the inserted Big Object record');
    }

    @IsTest
    static void getArchivedCasesForAccount_blankAccountId_returnsEmpty() {
        Test.startTest();
        List<Case_Archive__b> results =
            CaseArchiveService.getArchivedCasesForAccount('', DateTime.now());
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'Blank accountId should return empty list without querying Big Object');
    }

    @IsTest
    static void countArchivedCasesForAccount_returnsCorrectCount() {
        String fakeAccountId = '001000000000002AAA';
        List<Case_Archive__b> toInsert = new List<Case_Archive__b>{
            new Case_Archive__b(Case_Id__c='500000000000002AAA', Account_Id__c=fakeAccountId,
                                Closed_Date__c=DateTime.now(), Status__c='Closed'),
            new Case_Archive__b(Case_Id__c='500000000000003AAA', Account_Id__c=fakeAccountId,
                                Closed_Date__c=DateTime.now().addDays(-1), Status__c='Closed')
        };
        Database.insertImmediate(toInsert);

        Test.startTest();
        Integer count = CaseArchiveService.countArchivedCasesForAccount(fakeAccountId);
        Test.stopTest();

        System.assertEquals(2, count,
            'COUNT aggregate on Big Object should return 2 for the 2 inserted archives');
    }
}
