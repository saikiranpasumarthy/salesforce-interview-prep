/**
 * DeploymentVerifierTest
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 20 — Tests for DeploymentVerifier.
 *
 * TESTING APPROACH:
 * ══════════════════
 * All check methods are @TestVisible static — test them directly.
 * The main verify() method aggregates results; test it for end-to-end behavior.
 * Tests assert on the structure of results and on pass/fail logic,
 * not on specific counts (which vary by org state).
 */
@IsTest
private class DeploymentVerifierTest {

    // ─────────────────────────────────────────────────────────────────────────
    // CheckResult & VerificationResult inner types
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void checkResult_passed_isTrue() {
        DeploymentVerifier.CheckResult r =
            new DeploymentVerifier.CheckResult('Test', true, 'All good');
        System.assert(r.passed,       'passed should be true');
        System.assertEquals('Test',   r.checkName,  'checkName');
        System.assertEquals('All good', r.message,  'message');
    }

    @IsTest
    static void checkResult_failed_isFalse() {
        DeploymentVerifier.CheckResult r =
            new DeploymentVerifier.CheckResult('Test', false, 'Something wrong');
        System.assert(!r.passed, 'passed should be false');
    }

    @IsTest
    static void verificationResult_allPassed_resultPassed() {
        DeploymentVerifier.VerificationResult vr =
            new DeploymentVerifier.VerificationResult();
        vr.add(new DeploymentVerifier.CheckResult('A', true, 'ok'));
        vr.add(new DeploymentVerifier.CheckResult('B', true, 'ok'));

        System.assert(vr.passed,          'all passed → overall passed');
        System.assertEquals(2, vr.checks.size(), 'should have 2 checks');
    }

    @IsTest
    static void verificationResult_oneFailure_resultFailed() {
        DeploymentVerifier.VerificationResult vr =
            new DeploymentVerifier.VerificationResult();
        vr.add(new DeploymentVerifier.CheckResult('A', true,  'ok'));
        vr.add(new DeploymentVerifier.CheckResult('B', false, 'nope'));

        System.assert(!vr.passed, 'one failure → overall failed');
    }

    @IsTest
    static void verificationResult_toReport_containsPassedLabel() {
        DeploymentVerifier.VerificationResult vr =
            new DeploymentVerifier.VerificationResult();
        vr.add(new DeploymentVerifier.CheckResult('Check1', true, 'msg'));

        String report = vr.toReport();
        System.assert(report.contains('PASSED'),     'report should say PASSED');
        System.assert(report.contains('[OK]'),        'report should contain [OK]');
        System.assert(report.contains('Check1'),      'report should contain check name');
    }

    @IsTest
    static void verificationResult_toReport_failedShowsFailLabel() {
        DeploymentVerifier.VerificationResult vr =
            new DeploymentVerifier.VerificationResult();
        vr.add(new DeploymentVerifier.CheckResult('BadCheck', false, 'error details'));

        String report = vr.toReport();
        System.assert(report.contains('FAILED'),      'report should say FAILED');
        System.assert(report.contains('[FAIL]'),      'report should contain [FAIL]');
        System.assert(report.contains('error details'), 'report should contain message');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // checkApexClassesActive
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void checkApexClassesActive_passesInHealthyOrg() {
        // In a healthy org, all active classes should be valid
        // This test verifies the check runs without exception and returns a result
        Test.startTest();
        DeploymentVerifier.CheckResult result =
            DeploymentVerifier.checkApexClassesActive();
        Test.stopTest();

        System.assertNotEquals(null, result,          'result should not be null');
        System.assertNotEquals(null, result.message,  'message should be set');
        // In a valid org, this should pass
        System.assert(result.passed,
            'Apex classes should all be valid in this org: ' + result.message);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // checkTriggersActive
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void checkTriggersActive_passesInHealthyOrg() {
        Test.startTest();
        DeploymentVerifier.CheckResult result =
            DeploymentVerifier.checkTriggersActive();
        Test.stopTest();

        System.assertNotEquals(null, result, 'result should not be null');
        System.assert(result.passed,
            'All triggers should be active: ' + result.message);
    }

    @IsTest
    static void checkTriggersActive_messageIncludesTriggerCount() {
        DeploymentVerifier.CheckResult result =
            DeploymentVerifier.checkTriggersActive();
        // Message either says "N active triggers" or lists inactive ones
        System.assert(
            result.message.contains('trigger') || result.message.contains('Trigger'),
            'Message should mention triggers: ' + result.message
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // checkCriticalClassCompilation
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void checkCriticalClasses_passesWhenAllPresent() {
        // PlatformEventService, CdcEventHandler, ExternalApiClient, OrgConfigService
        // are all deployed as part of this project — they should be found
        Test.startTest();
        DeploymentVerifier.CheckResult result =
            DeploymentVerifier.checkCriticalClassCompilation();
        Test.stopTest();

        System.assertNotEquals(null, result, 'result should not be null');
        System.assert(result.passed,
            'Critical classes should all be present: ' + result.message);
    }

    @IsTest
    static void checkCriticalClasses_messageListsCheckedClasses() {
        DeploymentVerifier.CheckResult result =
            DeploymentVerifier.checkCriticalClassCompilation();

        System.assert(result.message.contains('PlatformEventService'),
            'Message should mention PlatformEventService');
        System.assert(result.message.contains('OrgConfigService'),
            'Message should mention OrgConfigService');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // checkOrgShape
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void checkOrgShape_alwaysPasses() {
        Test.startTest();
        DeploymentVerifier.CheckResult result =
            DeploymentVerifier.checkOrgShape();
        Test.stopTest();

        System.assert(result.passed, 'checkOrgShape should always pass (informational)');
        System.assertNotEquals(null, result.message, 'message should contain org info');
    }

    @IsTest
    static void checkOrgShape_messageContainsSandboxOrProductionLabel() {
        DeploymentVerifier.CheckResult result = DeploymentVerifier.checkOrgShape();
        System.assert(
            result.message.contains('[SANDBOX]') || result.message.contains('[PRODUCTION]'),
            'Message should contain environment label: ' + result.message
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // checkCustomObjects
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void checkCustomObjects_passesWhenObjectsExist() {
        // Project__c and Project_Task__c are deployed as part of this project
        Test.startTest();
        DeploymentVerifier.CheckResult result =
            DeploymentVerifier.checkCustomObjects();
        Test.stopTest();

        System.assert(result.passed,
            'Custom objects should be queryable: ' + result.message);
        System.assert(result.message.contains('Project__c'),
            'Message should mention Project__c');
    }

    @IsTest
    static void checkCustomObjects_messageIncludesRecordCounts() {
        DeploymentVerifier.CheckResult result = DeploymentVerifier.checkCustomObjects();
        System.assert(result.message.contains('records'),
            'Message should include record counts: ' + result.message);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // verify() — end-to-end
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void verify_returnsResultWithAllChecks() {
        Test.startTest();
        DeploymentVerifier.VerificationResult result = DeploymentVerifier.verify();
        Test.stopTest();

        System.assertNotEquals(null, result,          'result should not be null');
        System.assertNotEquals(null, result.checks,   'checks should not be null');
        System.assert(result.checks.size() >= 5,
            'Should run at least 5 checks, got: ' + result.checks.size());
    }

    @IsTest
    static void verify_inHealthyOrg_passes() {
        DeploymentVerifier.VerificationResult result = DeploymentVerifier.verify();
        // In a healthy org with all project classes deployed, all checks should pass
        System.assert(result.passed,
            'Verification should pass in a healthy org.\nReport:\n' + result.toReport());
    }

    @IsTest
    static void verify_runAtIsSetToNow() {
        DeploymentVerifier.VerificationResult result = DeploymentVerifier.verify();
        System.assertNotEquals(null, result.runAt, 'runAt should be set');
        // runAt should be within the last minute
        Long diffMs = Datetime.now().getTime() - result.runAt.getTime();
        System.assert(diffMs < 60000,
            'runAt should be within 60 seconds of now');
    }

    @IsTest
    static void verify_toReport_containsAllCheckNames() {
        DeploymentVerifier.VerificationResult result = DeploymentVerifier.verify();
        String report = result.toReport();

        System.assert(report.contains('Apex Compilation'),    'Report has Apex Compilation');
        System.assert(report.contains('Trigger Status'),      'Report has Trigger Status');
        System.assert(report.contains('Critical Classes'),    'Report has Critical Classes');
        System.assert(report.contains('Org Shape'),           'Report has Org Shape');
        System.assert(report.contains('Custom Objects'),      'Report has Custom Objects');
    }
}
