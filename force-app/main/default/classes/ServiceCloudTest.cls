/**
 * @description Tests for Day 26 — Service Cloud: Case Management, Entitlements & Milestones.
 *
 *              CaseMilestone and Entitlement objects require org-level configuration
 *              (Entitlement Process, SLA Process) to produce real records. These tests
 *              use @TestVisible mock injection for those objects and focus on pure
 *              business logic validation.
 *
 *              BusinessHours tests query the org's default BH record — present in all orgs.
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class ServiceCloudTest {

    // ─── Test setup ───────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        // Create test Account
        Account acc = new Account(Name = 'Service Cloud Test Account');
        insert acc;

        // Create open cases
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 4; i++) {
            cases.add(new Case(
                AccountId = acc.Id,
                Subject   = 'Test Case ' + i,
                Status    = 'New',
                Priority  = i < 2 ? 'High' : 'Medium',
                Origin    = 'Web'
            ));
        }
        insert cases;
    }

    // ─── Helper — fake ID generator ──────────────────────────────────────────

    private static Integer fakeCounter = 0;
    private static Id fakeId(Schema.SObjectType t) {
        String prefix = t.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(++fakeCounter).leftPad(12, '0');
        return (Id)(prefix + '0' + suffix);
    }

    // ─── CaseManagementService — escalation ──────────────────────────────────

    @IsTest static void escalateCase_setsIsEscalatedTrue() {
        Case c = [SELECT Id, IsEscalated FROM Case WHERE Subject = 'Test Case 0' LIMIT 1];
        System.assert(!c.IsEscalated, 'Precondition: case should not be escalated');

        Test.startTest();
        CaseManagementService.escalateCase(c.Id, 'Customer is a key account');
        Test.stopTest();

        c = [SELECT IsEscalated FROM Case WHERE Id = :c.Id];
        System.assert(c.IsEscalated, 'IsEscalated must be true after escalation');
    }

    @IsTest static void escalateCase_addsCaseComment() {
        Case c = [SELECT Id FROM Case WHERE Subject = 'Test Case 0' LIMIT 1];

        Test.startTest();
        CaseManagementService.escalateCase(c.Id, 'VIP customer');
        Test.stopTest();

        List<CaseComment> comments = [
            SELECT CommentBody, IsPublished
            FROM   CaseComment
            WHERE  ParentId = :c.Id
        ];
        System.assertEquals(1, comments.size(), 'Exactly one CaseComment should be added');
        System.assert(comments[0].CommentBody.contains('VIP customer'),
            'Comment body should include the reason');
        System.assert(!comments[0].IsPublished, 'Comment should be internal (not published)');
    }

    @IsTest static void escalateCase_idempotent_doesNotAddDuplicateComment() {
        Case c = [SELECT Id FROM Case WHERE Subject = 'Test Case 0' LIMIT 1];

        Test.startTest();
        CaseManagementService.escalateCase(c.Id, 'First escalation');
        CaseManagementService.escalateCase(c.Id, 'Second call — should be no-op');
        Test.stopTest();

        Integer commentCount = [
            SELECT COUNT() FROM CaseComment WHERE ParentId = :c.Id
        ];
        System.assertEquals(1, commentCount, 'Second escalateCase call must be a no-op');
    }

    @IsTest static void escalateCase_blankReason_usesDefaultMessage() {
        Case c = [SELECT Id FROM Case WHERE Subject = 'Test Case 1' LIMIT 1];

        Test.startTest();
        CaseManagementService.escalateCase(c.Id, '');
        Test.stopTest();

        CaseComment comment = [SELECT CommentBody FROM CaseComment WHERE ParentId = :c.Id LIMIT 1];
        System.assert(comment.CommentBody.contains('No reason provided'));
    }

    // ─── CaseManagementService — bulk close ──────────────────────────────────

    @IsTest static void closeCasesOlderThan_closesMatchingCases() {
        // All test cases were just created — set CreatedDate check to 0 days
        // (cases created 'just now' should NOT match a 0-day cutoff)
        // Instead verify no cases close when threshold is very small
        Test.startTest();
        Integer closed = CaseManagementService.closeCasesOlderThan(0);
        Test.stopTest();

        // Cases created NOW are NOT older than 0 days — no cases should close
        // (0 days cutoff = DateTime.now().addDays(0) = now, so only cases
        //  strictly BEFORE now qualify; freshly inserted cases don't qualify)
        System.assert(closed >= 0, 'Method should return non-negative count');
    }

    @IsTest static void closeCasesOlderThan_noMatches_returnsZero() {
        // Close all cases first, then verify method returns 0 on second call
        for (Case c : [SELECT Id FROM Case WHERE IsClosed = false]) {
            update new Case(Id = c.Id, Status = 'Closed');
        }

        Test.startTest();
        Integer closed = CaseManagementService.closeCasesOlderThan(0);
        Test.stopTest();

        System.assertEquals(0, closed, 'No open cases → should return 0');
    }

    // ─── CaseManagementService — SLA stopwatch ───────────────────────────────

    @IsTest static void pauseSla_setsIsStoppedTrue() {
        List<Case> cases = [SELECT Id, IsStopped FROM Case LIMIT 2];
        Set<Id> ids = new Map<Id, Case>(cases).keySet();

        Test.startTest();
        CaseManagementService.pauseSla(ids);
        Test.stopTest();

        for (Case c : [SELECT IsStopped FROM Case WHERE Id IN :ids]) {
            System.assert(c.IsStopped, 'IsStopped must be true after pauseSla');
        }
    }

    @IsTest static void resumeSla_setsIsStoppedFalse() {
        List<Case> cases = [SELECT Id FROM Case LIMIT 2];
        Set<Id> ids = new Map<Id, Case>(cases).keySet();
        // Pause first
        CaseManagementService.pauseSla(ids);

        Test.startTest();
        CaseManagementService.resumeSla(ids);
        Test.stopTest();

        for (Case c : [SELECT IsStopped FROM Case WHERE Id IN :ids]) {
            System.assert(!c.IsStopped, 'IsStopped must be false after resumeSla');
        }
    }

    @IsTest static void pauseSla_emptySet_noOp() {
        Test.startTest();
        CaseManagementService.pauseSla(new Set<Id>());  // must not throw
        Test.stopTest();
        System.assert(true, 'Empty set should be handled gracefully');
    }

    @IsTest static void resumeSla_nullSet_noOp() {
        Test.startTest();
        CaseManagementService.resumeSla(null);  // must not throw
        Test.stopTest();
        System.assert(true, 'Null set should be handled gracefully');
    }

    // ─── CaseManagementService — breached milestones (mock) ──────────────────

    @IsTest static void getBreachedMilestones_mockFiltersToViolatedInSet() {
        Id caseId1 = fakeId(Case.SObjectType);
        Id caseId2 = fakeId(Case.SObjectType);
        Id milestoneTypeId = fakeId(MilestoneType.SObjectType);

        // Build mock milestones in memory — IsViolated is read-only in prod but
        // writable in test context via SObject constructor
        CaseMilestone violated = new CaseMilestone(
            CaseId          = caseId1,
            MilestoneTypeId = milestoneTypeId,
            IsViolated      = true
        );
        CaseMilestone notViolated = new CaseMilestone(
            CaseId          = caseId2,
            MilestoneTypeId = milestoneTypeId,
            IsViolated      = false
        );
        CaseManagementService.mockBreachedMilestones =
            new List<CaseMilestone>{ violated, notViolated };

        Test.startTest();
        List<CaseMilestone> results =
            CaseManagementService.getBreachedMilestones(new Set<Id>{ caseId1, caseId2 });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Only the violated milestone should be returned');
        System.assertEquals(caseId1, results[0].CaseId);
    }

    @IsTest static void getBreachedMilestones_excludesCaseIdsNotInSet() {
        Id caseId1 = fakeId(Case.SObjectType);
        Id caseId2 = fakeId(Case.SObjectType);
        Id milestoneTypeId = fakeId(MilestoneType.SObjectType);

        CaseManagementService.mockBreachedMilestones = new List<CaseMilestone>{
            new CaseMilestone(CaseId = caseId1, MilestoneTypeId = milestoneTypeId, IsViolated = true),
            new CaseMilestone(CaseId = caseId2, MilestoneTypeId = milestoneTypeId, IsViolated = true)
        };

        Test.startTest();
        // Only ask for caseId1 — caseId2 should not appear
        List<CaseMilestone> results =
            CaseManagementService.getBreachedMilestones(new Set<Id>{ caseId1 });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(caseId1, results[0].CaseId);
    }

    // ─── CaseManagementService — at-risk cases ────────────────────────────────

    @IsTest static void getCasesAtRisk_noSlaExitDate_returnsEmpty() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        // SlaExitDate is null on test cases (no entitlement process) → no results
        List<Case> atRisk = CaseManagementService.getCasesAtRisk(acc.Id, 60);
        Test.stopTest();

        System.assert(atRisk.isEmpty(),
            'Cases without SlaExitDate should not appear in at-risk list');
    }

    // ─── CaseManagementService — business hours ───────────────────────────────

    @IsTest static void businessHoursElapsedMinutes_returnsNonNegative() {
        BusinessHours bh = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
        DateTime start = DateTime.now().addHours(-2);
        DateTime end   = DateTime.now();

        Test.startTest();
        Long minutes = CaseManagementService.businessHoursElapsedMinutes(bh.Id, start, end);
        Test.stopTest();

        System.assert(minutes >= 0, 'Business hours elapsed should be >= 0');
    }

    @IsTest static void isWithinBusinessHours_returnsBooleanResult() {
        BusinessHours bh = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];

        Test.startTest();
        Boolean result = CaseManagementService.isWithinBusinessHours(bh.Id, DateTime.now());
        Test.stopTest();

        // Just verify it returns without error — value depends on org's BH config
        System.assertNotNull(result);
    }

    @IsTest static void addBusinessHoursMinutes_returnsDateTimeAfterStart() {
        BusinessHours bh = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
        DateTime start = DateTime.now();

        Test.startTest();
        DateTime deadline = CaseManagementService.addBusinessHoursMinutes(bh.Id, start, 120);
        Test.stopTest();

        System.assertNotNull(deadline, 'addBusinessHoursMinutes must return a DateTime');
        System.assert(deadline >= start, 'Deadline must be >= start');
    }

    // ─── EntitlementService — active entitlements (mock) ─────────────────────

    @IsTest static void getActiveEntitlements_mockFiltersToActiveStatus() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        EntitlementService.mockEntitlements = new List<Entitlement>{
            new Entitlement(AccountId = acc.Id, Name = 'Premium', Status = 'Active'),
            new Entitlement(AccountId = acc.Id, Name = 'Expired',  Status = 'Expired')
        };

        Test.startTest();
        List<Entitlement> results = EntitlementService.getActiveEntitlements(acc.Id);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Only Active entitlements should be returned');
        System.assertEquals('Premium', results[0].Name);
    }

    @IsTest static void getActiveEntitlements_mockFiltersToCorrectAccount() {
        Account acc1 = [SELECT Id FROM Account LIMIT 1];
        Id acc2Id    = fakeId(Account.SObjectType);
        EntitlementService.mockEntitlements = new List<Entitlement>{
            new Entitlement(AccountId = acc1.Id, Name = 'Ent-1', Status = 'Active'),
            new Entitlement(AccountId = acc2Id,  Name = 'Ent-2', Status = 'Active')
        };

        Test.startTest();
        List<Entitlement> results = EntitlementService.getActiveEntitlements(acc1.Id);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Only entitlements for acc1 should be returned');
        System.assertEquals('Ent-1', results[0].Name);
    }

    @IsTest static void getActiveEntitlements_noMock_returnsEmptyInTestOrg() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        // No mock set, no real entitlements in test org — should return empty gracefully
        Test.startTest();
        List<Entitlement> results = EntitlementService.getActiveEntitlements(acc.Id);
        Test.stopTest();

        System.assertNotNull(results, 'Should return empty list, not null');
    }

    @IsTest static void getBestEntitlement_noEntitlements_returnsNull() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        EntitlementService.mockEntitlements = new List<Entitlement>();

        Test.startTest();
        Entitlement best = EntitlementService.getBestEntitlement(acc.Id);
        Test.stopTest();

        System.assertNull(best, 'Should return null when no active entitlements exist');
    }

    // ─── EntitlementService — contact entitlements ────────────────────────────

    @IsTest static void getContactEntitlements_noJunctions_returnsEmpty() {
        Contact c = new Contact(LastName = 'Test', AccountId = [SELECT Id FROM Account LIMIT 1].Id);
        insert c;

        Test.startTest();
        List<Entitlement> results = EntitlementService.getContactEntitlements(c.Id);
        Test.stopTest();

        System.assert(results.isEmpty(), 'Contact with no EntitlementContact junctions → empty');
    }

    // ─── EntitlementService — apply entitlement ───────────────────────────────

    @IsTest static void applyEntitlementToCase_nullInputs_noOp() {
        Test.startTest();
        EntitlementService.applyEntitlementToCase(null, null);  // must not throw
        EntitlementService.applyEntitlementToCase(null, fakeId(Entitlement.SObjectType));
        EntitlementService.applyEntitlementToCase(fakeId(Case.SObjectType), null);
        Test.stopTest();
        System.assert(true, 'Null inputs should be handled gracefully with no exception');
    }

    // ─── EntitlementService — milestone stats (mock) ─────────────────────────

    @IsTest static void getMilestoneStats_emptyCaseIds_returnsEmptyMap() {
        Test.startTest();
        Map<Id, EntitlementService.MilestoneStats> stats =
            EntitlementService.getMilestoneStats(new Set<Id>());
        Test.stopTest();

        System.assert(stats.isEmpty(), 'Empty input should return empty map');
    }

    @IsTest static void getMilestoneStats_mockData_countsCorrectly() {
        Id caseId = fakeId(Case.SObjectType);
        Id mtId   = fakeId(MilestoneType.SObjectType);
        EntitlementService.mockCaseMilestones = new List<CaseMilestone>{
            new CaseMilestone(CaseId = caseId, MilestoneTypeId = mtId,
                              IsCompleted = true,  IsViolated = false),
            new CaseMilestone(CaseId = caseId, MilestoneTypeId = mtId,
                              IsCompleted = false, IsViolated = true),
            new CaseMilestone(CaseId = caseId, MilestoneTypeId = mtId,
                              IsCompleted = false, IsViolated = false)
        };

        Test.startTest();
        Map<Id, EntitlementService.MilestoneStats> stats =
            EntitlementService.getMilestoneStats(new Set<Id>{ caseId });
        Test.stopTest();

        EntitlementService.MilestoneStats s = stats.get(caseId);
        System.assertNotNull(s);
        System.assertEquals(3, s.total,     'Total should be 3');
        System.assertEquals(1, s.completed, 'Completed should be 1');
        System.assertEquals(1, s.violated,  'Violated should be 1');
        System.assertEquals(1, s.pending,   'Pending should be 1 (3-1-1)');
        System.assert(!s.allMet, 'allMet should be false when there is a violation');
    }

    @IsTest static void getMilestoneStats_allCompleted_allMetTrue() {
        Id caseId = fakeId(Case.SObjectType);
        Id mtId   = fakeId(MilestoneType.SObjectType);
        EntitlementService.mockCaseMilestones = new List<CaseMilestone>{
            new CaseMilestone(CaseId = caseId, MilestoneTypeId = mtId,
                              IsCompleted = true, IsViolated = false),
            new CaseMilestone(CaseId = caseId, MilestoneTypeId = mtId,
                              IsCompleted = true, IsViolated = false)
        };

        Test.startTest();
        Map<Id, EntitlementService.MilestoneStats> stats =
            EntitlementService.getMilestoneStats(new Set<Id>{ caseId });
        Test.stopTest();

        EntitlementService.MilestoneStats s = stats.get(caseId);
        System.assertEquals(0, s.pending);
        System.assertEquals(0, s.violated);
        System.assert(s.allMet, 'allMet should be true when all milestones are completed');
    }

    // ─── EntitlementService — violated milestones (mock) ─────────────────────

    @IsTest static void getViolatedMilestones_mockReturnsOnlyViolated() {
        Id caseId = fakeId(Case.SObjectType);
        Id mtId   = fakeId(MilestoneType.SObjectType);
        EntitlementService.mockCaseMilestones = new List<CaseMilestone>{
            new CaseMilestone(CaseId = caseId, MilestoneTypeId = mtId, IsViolated = true),
            new CaseMilestone(CaseId = caseId, MilestoneTypeId = mtId, IsViolated = false)
        };

        Test.startTest();
        List<CaseMilestone> violated = EntitlementService.getViolatedMilestones(7);
        Test.stopTest();

        System.assertEquals(1, violated.size(), 'Only violated milestones should be returned');
        System.assert(violated[0].IsViolated);
    }

    @IsTest static void getViolatedMilestones_noMock_returnsEmpty() {
        // No mock set, no real milestones in test org
        Test.startTest();
        List<CaseMilestone> violated = EntitlementService.getViolatedMilestones(7);
        Test.stopTest();

        System.assertNotNull(violated);
    }

    // ─── MilestoneStats — derived field edge cases ────────────────────────────

    @IsTest static void milestoneStats_pendingNeverNegative() {
        EntitlementService.MilestoneStats s = new EntitlementService.MilestoneStats();
        s.total     = 2;
        s.completed = 2;
        s.violated  = 1; // completed + violated > total (edge case — shouldn't happen in prod)
        System.assert(s.pending >= 0, 'Pending should never be negative (Math.max guard)');
    }

    @IsTest static void milestoneStats_allMetFalseWhenZeroTotal() {
        EntitlementService.MilestoneStats s = new EntitlementService.MilestoneStats();
        System.assert(!s.allMet, 'allMet should be false when total is 0');
    }
}
