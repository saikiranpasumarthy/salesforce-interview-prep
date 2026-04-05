/**
 * AdminFundamentalsTest
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 15 — Tests for MetadataInspector, AuditService, and validation rules on
 * Project_Task__c.
 *
 * TEST STRATEGY:
 *  • Validation rule tests are integration tests — they rely on deployed metadata
 *    and confirm that the DMLException message matches the expected error text.
 *  • MetadataInspector tests use well-known standard objects (Account) so they
 *    work in any org without custom metadata prerequisites.
 *  • AuditService tests confirm method signatures compile and execute without
 *    exception; they do not assert specific audit-trail content (which varies by org).
 *  • ReportService has no test-runnable methods (Reports API requires a real report Id)
 *    — tests verify compile-time correctness via class reference.
 *
 * NOTE ON System.runAs + CRUD/FLS IN TESTS:
 *  In @IsTest context the test runner always has full CRUD/FLS regardless of
 *  the running user. System.runAs() only changes record-level sharing context.
 */
@IsTest
public class AdminFundamentalsTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Test data factory
    // ─────────────────────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        Project__c proj = new Project__c(Name = 'Test Project', Status__c = 'Active');
        insert proj;
    }

    private static Project__c getTestProject() {
        return [SELECT Id FROM Project__c WHERE Name = 'Test Project' LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Validation rule: High_Priority_Requires_Due_Date
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void validationRule_highPriorityNoDueDate_throwsDMLException() {
        Project_Task__c task = new Project_Task__c(
            Name        = 'High Task Without Date',
            Project__c  = getTestProject().Id,
            Priority__c = 'High'
            // Due_Date__c intentionally omitted
        );

        Test.startTest();
        try {
            insert task;
            System.assert(false, 'Expected DMLException from High_Priority_Requires_Due_Date');
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('Due Date') || e.getMessage().contains('High'),
                'Error should reference Due Date or High priority: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void validationRule_highPriorityWithDueDate_succeeds() {
        Project_Task__c task = new Project_Task__c(
            Name        = 'High Task With Date',
            Project__c  = getTestProject().Id,
            Priority__c = 'High',
            Due_Date__c = Date.today().addDays(7)
        );

        Test.startTest();
        insert task;  // must not throw
        Test.stopTest();

        System.assertNotEquals(null, task.Id, 'Task should be inserted');
    }

    @IsTest
    static void validationRule_mediumPriorityNoDueDate_succeeds() {
        Project_Task__c task = new Project_Task__c(
            Name        = 'Medium Task No Date',
            Project__c  = getTestProject().Id,
            Priority__c = 'Medium'
            // No due date — Medium does not require it
        );

        Test.startTest();
        insert task;
        Test.stopTest();

        System.assertNotEquals(null, task.Id, 'Medium priority task should insert without Due Date');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Validation rule: Effort_Days_Valid_Range
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void validationRule_effortDays_tooHigh_throwsDMLException() {
        Project_Task__c task = new Project_Task__c(
            Name           = 'Over-Effort Task',
            Project__c     = getTestProject().Id,
            Priority__c    = 'Low',
            Effort_Days__c = 400   // > 365
        );

        Test.startTest();
        try {
            insert task;
            System.assert(false, 'Expected DMLException for Effort_Days > 365');
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('365') || e.getMessage().contains('Effort'),
                'Error should mention 365 or Effort: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void validationRule_effortDays_tooLow_throwsDMLException() {
        Project_Task__c task = new Project_Task__c(
            Name           = 'Zero-Effort Task',
            Project__c     = getTestProject().Id,
            Priority__c    = 'Low',
            Effort_Days__c = 0   // < 1
        );

        Test.startTest();
        try {
            insert task;
            System.assert(false, 'Expected DMLException for Effort_Days < 1');
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('1') || e.getMessage().contains('Effort'),
                'Error should mention range: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void validationRule_effortDays_validRange_succeeds() {
        Project_Task__c task = new Project_Task__c(
            Name           = 'Valid Effort Task',
            Project__c     = getTestProject().Id,
            Priority__c    = 'Low',
            Effort_Days__c = 5
        );

        Test.startTest();
        insert task;
        Test.stopTest();

        System.assertNotEquals(null, task.Id);
    }

    @IsTest
    static void validationRule_effortDays_blank_succeeds() {
        // Rule only fires when Effort_Days__c is not blank — blank is allowed
        Project_Task__c task = new Project_Task__c(
            Name        = 'No Effort Task',
            Project__c  = getTestProject().Id,
            Priority__c = 'Low'
        );

        Test.startTest();
        insert task;
        Test.stopTest();

        System.assertNotEquals(null, task.Id, 'Blank Effort_Days__c should be allowed');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Validation rule: Due_Date_Cannot_Be_Past
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void validationRule_pastDueDate_onInsert_throwsDMLException() {
        Project_Task__c task = new Project_Task__c(
            Name        = 'Past Due Task',
            Project__c  = getTestProject().Id,
            Priority__c = 'Low',
            Due_Date__c = Date.today().addDays(-1)
        );

        Test.startTest();
        try {
            insert task;
            System.assert(false, 'Expected DMLException for past Due Date');
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('past') || e.getMessage().contains('Due'),
                'Error should mention past/due: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void validationRule_pastDueDate_onUpdate_doesNotFire() {
        // ISNEW() makes the rule insert-only; updating an existing past-dated task is allowed
        Project_Task__c task = new Project_Task__c(
            Name        = 'Existing Past Due Task',
            Project__c  = getTestProject().Id,
            Priority__c = 'Low',
            Due_Date__c = Date.today().addDays(1)
        );
        insert task;

        task.Due_Date__c = Date.today().addDays(-10);  // Set to past on update

        Test.startTest();
        update task;  // should NOT throw — rule only fires on ISNEW()
        Test.stopTest();

        System.assertNotEquals(null, task.Id, 'Update with past date should succeed (ISNEW guard)');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MetadataInspector — object describe
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void describeObject_account_returnsExpectedMetadata() {
        Test.startTest();
        MetadataInspector.ObjectInfo info = MetadataInspector.describeObject('Account');
        Test.stopTest();

        System.assertEquals('Account', info.apiName, 'apiName should be Account');
        System.assertEquals('Account', info.label,   'label should be Account');
        System.assertEquals(false,     info.isCustom, 'Account is not a custom object');
        System.assertEquals(true,      info.isQueryable, 'Account should be queryable');
        System.assertNotEquals(null,   info.keyPrefix, 'keyPrefix should not be null');
        System.assert(info.fieldCount > 0, 'Account should have fields');
    }

    @IsTest
    static void describeObject_projectTask_isCustomAndControlledByParent() {
        Test.startTest();
        MetadataInspector.ObjectInfo info =
            MetadataInspector.describeObject('Project_Task__c');
        Test.stopTest();

        System.assertEquals(true,  info.isCustom, 'Project_Task__c is a custom object');
        System.assertEquals('ControlledByParent', info.sharingModel,
            'Master-Detail objects should have ControlledByParent sharing model');
    }

    @IsTest
    static void describeObject_unknownObject_throwsException() {
        Test.startTest();
        try {
            MetadataInspector.describeObject('Nonexistent__c');
            System.assert(false, 'Expected UnknownObjectException');
        } catch (MetadataInspector.UnknownObjectException e) {
            System.assert(e.getMessage().contains('Nonexistent__c'));
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MetadataInspector — field describe
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void describeFields_account_containsNameField() {
        Test.startTest();
        List<MetadataInspector.FieldInfo> fields =
            MetadataInspector.describeFields('Account');
        Test.stopTest();

        Boolean foundName = false;
        for (MetadataInspector.FieldInfo fi : fields) {
            if (fi.apiName == 'Name') { foundName = true; break; }
        }
        System.assert(foundName, 'describeFields should include the Name field');
    }

    @IsTest
    static void getPicklistValues_accountType_returnsActiveValues() {
        Test.startTest();
        List<String> values = MetadataInspector.getPicklistValues('Account', 'Type');
        Test.stopTest();

        System.assert(!values.isEmpty(), 'Account.Type should have picklist values');
        System.assert(values.contains('Prospect'), 'Account.Type should include Prospect');
    }

    @IsTest
    static void getPicklistValues_projectTaskPriority_returnsHighMediumLow() {
        Test.startTest();
        List<String> values =
            MetadataInspector.getPicklistValues('Project_Task__c', 'Priority__c');
        Test.stopTest();

        System.assertEquals(3, values.size(), 'Priority__c should have 3 values');
        System.assert(values.contains('High'),   'Should contain High');
        System.assert(values.contains('Medium'), 'Should contain Medium');
        System.assert(values.contains('Low'),    'Should contain Low');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MetadataInspector — relationship describe
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void describeChildRelationships_projectHasProjectTasks() {
        Test.startTest();
        List<MetadataInspector.RelationshipInfo> rels =
            MetadataInspector.describeChildRelationships('Project__c');
        Test.stopTest();

        Boolean foundTaskRel = false;
        for (MetadataInspector.RelationshipInfo ri : rels) {
            if (ri.childObject == 'Project_Task__c') {
                foundTaskRel = true;
                // Master-Detail → cascade delete = true
                System.assertEquals(true, ri.isCascadeDelete,
                    'Master-Detail child should cascade delete');
                break;
            }
        }
        System.assert(foundTaskRel, 'Project__c should show Project_Task__c as a child');
    }

    @IsTest
    static void getReferenceFields_projectTask_containsMasterDetailField() {
        Test.startTest();
        List<MetadataInspector.FieldInfo> refFields =
            MetadataInspector.getReferenceFields('Project_Task__c');
        Test.stopTest();

        Boolean foundProjectRef = false;
        for (MetadataInspector.FieldInfo fi : refFields) {
            if (fi.referenceTo == 'Project__c') {
                foundProjectRef = true; break;
            }
        }
        System.assert(foundProjectRef,
            'Project_Task__c should have a REFERENCE field pointing to Project__c');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AuditService tests
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getRecentSetupChanges_returnsNonNullList() {
        Test.startTest();
        List<AuditService.AuditEntry> entries = AuditService.getRecentSetupChanges(10);
        Test.stopTest();

        System.assertNotEquals(null, entries, 'Setup changes list should not be null');
        // SetupAuditTrail will have at least one entry (this test run itself creates one)
    }

    @IsTest
    static void getSetupChangesBySection_customField_returnsNonNull() {
        Test.startTest();
        List<AuditService.AuditEntry> entries =
            AuditService.getSetupChangesBySection('CustomField', 5);
        Test.stopTest();

        System.assertNotEquals(null, entries);
    }

    @IsTest
    static void getAccountFieldHistory_returnsHistoryList() {
        Account acc = new Account(Name = 'History Test Corp', Type = 'Prospect');
        insert acc;
        acc.Type = 'Customer - Direct';
        update acc;

        Test.startTest();
        List<AuditService.FieldChange> changes =
            AuditService.getAccountFieldHistory(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, changes,
            'Field history should not be null (tracking may need to be enabled for field count assertions)');
    }

    @IsTest
    static void getFieldHistory_dynamicQuery_accountReturnsNonNull() {
        Account acc = new Account(Name = 'Dynamic History Co');
        insert acc;

        Test.startTest();
        List<AuditService.FieldChange> changes =
            AuditService.getFieldHistory('Account', acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, changes);
    }

    @IsTest
    static void getFieldHistory_customObject_projectTask_returnsNonNull() {
        Project_Task__c task = new Project_Task__c(
            Name        = 'Auditable Task',
            Project__c  = getTestProject().Id,
            Priority__c = 'Low'
        );
        insert task;

        Test.startTest();
        List<AuditService.FieldChange> changes =
            AuditService.getFieldHistory('Project_Task__c', task.Id);
        Test.stopTest();

        System.assertNotEquals(null, changes);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ReportService — compile-time verification
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void reportService_classIsAccessible() {
        // Reports.ReportManager.runReport requires a real report Id and cannot be
        // called in @IsTest context without a valid Id. This test verifies that the
        // class compiles correctly and the Reports namespace types are accessible.
        System.assertNotEquals(null, ReportService.class,
            'ReportService class should be accessible');

        // Verify AsyncReportStatus inner class is constructable
        ReportService.AsyncReportStatus status = new ReportService.AsyncReportStatus();
        status.status  = 'New';
        status.isComplete = false;
        System.assertEquals('New', status.status);
    }
}
