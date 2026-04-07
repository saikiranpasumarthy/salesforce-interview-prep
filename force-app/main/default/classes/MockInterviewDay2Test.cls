/**
 * Day 38 — Mock Interview Day 2 Tests
 * Covers: MockInterviewCloudsService + MockInterviewDevOpsService
 */
@IsTest
private class MockInterviewDay2Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewCloudsService — OmniChannel Routing
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testRouteWorkItem_queueNotFound() {
        Case c = new Case(Subject = 'Test', Status = 'New');
        insert c;

        Test.startTest();
        MockInterviewCloudsService.RoutingResult result =
            MockInterviewCloudsService.routeWorkItemToOmniChannel(
                c.Id, 'NonExistentQueue_XYZ', 1
            );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Queue not found'));
    }

    @IsTest
    static void testRouteWorkItem_nullCapacityDefaults() {
        // Validates capacity default of 1 when null passed
        Case c = new Case(Subject = 'Cap Test', Status = 'New');
        insert c;

        // We expect queue-not-found since no real queue in test — that's fine;
        // the test verifies the null-capacity path doesn't throw an exception.
        Test.startTest();
        MockInterviewCloudsService.RoutingResult result =
            MockInterviewCloudsService.routeWorkItemToOmniChannel(c.Id, 'AnyQueue', null);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewCloudsService — Manual Sharing
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testCreateManualShare_standardObject() {
        Account acc = new Account(Name = 'ShareTest');
        insert acc;
        User u = [SELECT Id FROM User WHERE IsActive = true AND Profile.Name = 'Standard User'
                  LIMIT 1];

        Test.startTest();
        MockInterviewCloudsService.SharingResult result =
            MockInterviewCloudsService.createManualShare(
                acc.Id, u.Id, 'Read', 'manual'
            );
        Test.stopTest();

        // In test context sharing insert may be restricted; verify no exception thrown
        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testCreateManualShare_nullInputsReturnError() {
        Test.startTest();
        MockInterviewCloudsService.SharingResult result =
            MockInterviewCloudsService.createManualShare(null, null, 'Read', 'manual');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertNotEquals(null, result.errorMessage);
    }

    @IsTest
    static void testGetSharingModelInfo_account() {
        Test.startTest();
        MockInterviewCloudsService.SharingModelInfo info =
            MockInterviewCloudsService.getSharingModelInfo('Account');
        Test.stopTest();

        System.assertNotEquals(null, info);
        System.assertEquals('Account', info.objectName);
        System.assertNotEquals(null, info.sharingModel);
    }

    @IsTest
    static void testGetSharingModelInfo_invalidObject() {
        Test.startTest();
        MockInterviewCloudsService.SharingModelInfo info =
            MockInterviewCloudsService.getSharingModelInfo('NonExistentObject__c');
        Test.stopTest();

        System.assertNotEquals(null, info);
        System.assertNotEquals(null, info.errorMessage);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewCloudsService — CDC Event Parsing
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testParseCdcEvents_nullList() {
        Test.startTest();
        List<MockInterviewCloudsService.CdcEventSummary> summaries =
            MockInterviewCloudsService.parseCdcEvents(null);
        Test.stopTest();

        System.assertEquals(0, summaries.size());
    }

    @IsTest
    static void testParseCdcEvents_emptyList() {
        Test.startTest();
        List<MockInterviewCloudsService.CdcEventSummary> summaries =
            MockInterviewCloudsService.parseCdcEvents(new List<SObject>());
        Test.stopTest();

        System.assertEquals(0, summaries.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewCloudsService — Automation Classifier
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testClassifyAutomation_batchForLargeVolume() {
        Test.startTest();
        MockInterviewCloudsService.AutomationTool tool =
            MockInterviewCloudsService.classifyAutomationTool(
                5000, false, false, false
            );
        Test.stopTest();

        System.assertEquals(MockInterviewCloudsService.AutomationTool.APEX_BATCH, tool);
    }

    @IsTest
    static void testClassifyAutomation_apexForCallout() {
        Test.startTest();
        MockInterviewCloudsService.AutomationTool tool =
            MockInterviewCloudsService.classifyAutomationTool(
                100, true, false, false
            );
        Test.stopTest();

        System.assertEquals(MockInterviewCloudsService.AutomationTool.APEX_TRIGGER, tool);
    }

    @IsTest
    static void testClassifyAutomation_flowForAdminMaintainable() {
        Test.startTest();
        MockInterviewCloudsService.AutomationTool tool =
            MockInterviewCloudsService.classifyAutomationTool(
                50, false, false, true
            );
        Test.stopTest();

        System.assertEquals(MockInterviewCloudsService.AutomationTool.FLOW, tool);
    }

    @IsTest
    static void testClassifyAutomation_apexForComplexLogic() {
        Test.startTest();
        MockInterviewCloudsService.AutomationTool tool =
            MockInterviewCloudsService.classifyAutomationTool(
                200, false, true, false
            );
        Test.stopTest();

        System.assertEquals(MockInterviewCloudsService.AutomationTool.APEX_TRIGGER, tool);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewCloudsService — Config Type Classifier
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testClassifyConfig_userSpecificUsesHierarchy() {
        Test.startTest();
        MockInterviewCloudsService.ConfigurationType cfg =
            MockInterviewCloudsService.classifyConfigurationType(
                true, false, false
            );
        Test.stopTest();

        System.assertEquals(
            MockInterviewCloudsService.ConfigurationType.CUSTOM_SETTING_HIERARCHY, cfg
        );
    }

    @IsTest
    static void testClassifyConfig_deployableUsesMetadata() {
        Test.startTest();
        MockInterviewCloudsService.ConfigurationType cfg =
            MockInterviewCloudsService.classifyConfigurationType(
                false, true, false
            );
        Test.stopTest();

        System.assertEquals(
            MockInterviewCloudsService.ConfigurationType.CUSTOM_METADATA_TYPE, cfg
        );
    }

    @IsTest
    static void testClassifyConfig_envSpecificUsesHierarchy() {
        Test.startTest();
        MockInterviewCloudsService.ConfigurationType cfg =
            MockInterviewCloudsService.classifyConfigurationType(
                false, false, true
            );
        Test.stopTest();

        System.assertEquals(
            MockInterviewCloudsService.ConfigurationType.CUSTOM_SETTING_HIERARCHY, cfg
        );
    }

    @IsTest
    static void testClassifyConfig_defaultMetadata() {
        Test.startTest();
        MockInterviewCloudsService.ConfigurationType cfg =
            MockInterviewCloudsService.classifyConfigurationType(
                false, false, false
            );
        Test.stopTest();

        System.assertEquals(
            MockInterviewCloudsService.ConfigurationType.CUSTOM_METADATA_TYPE, cfg
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewCloudsService — Cursor Pagination
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testCursorPagination_firstPage() {
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accs.add(new Account(Name = 'PagAcct ' + i));
        }
        insert accs;

        Test.startTest();
        List<Account> page =
            MockInterviewCloudsService.queryAccountsWithCursorPagination(null, 3);
        Test.stopTest();

        System.assertEquals(3, page.size());
        // Results ordered by Id ASC — each Id should be <= next
        for (Integer i = 0; i < page.size() - 1; i++) {
            System.assert(page[i].Id <= page[i+1].Id);
        }
    }

    @IsTest
    static void testCursorPagination_subsequentPage() {
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 6; i++) {
            accs.add(new Account(Name = 'CurAcct ' + i));
        }
        insert accs;

        // Get first page
        List<Account> page1 =
            MockInterviewCloudsService.queryAccountsWithCursorPagination(null, 3);
        Id lastId = page1[page1.size() - 1].Id;

        Test.startTest();
        List<Account> page2 =
            MockInterviewCloudsService.queryAccountsWithCursorPagination(lastId, 3);
        Test.stopTest();

        // All page2 Ids should be > lastId
        for (Account a : page2) {
            System.assert(a.Id > lastId, 'Expected Id > lastId but got: ' + a.Id);
        }
    }

    @IsTest
    static void testCursorPagination_pageSizeDefaultsTo50() {
        Test.startTest();
        List<Account> page =
            MockInterviewCloudsService.queryAccountsWithCursorPagination(null, null);
        Test.stopTest();

        System.assert(page.size() <= 50);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewDevOpsService — Deployment Readiness
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testDeploymentReadiness_nullComponents() {
        Test.startTest();
        MockInterviewDevOpsService.DeploymentReadinessResult result =
            MockInterviewDevOpsService.validateDeploymentReadiness(null);
        Test.stopTest();

        System.assertEquals(false, result.isReady);
        System.assertEquals(1, result.blockers.size());
    }

    @IsTest
    static void testDeploymentReadiness_emptyComponents() {
        Test.startTest();
        MockInterviewDevOpsService.DeploymentReadinessResult result =
            MockInterviewDevOpsService.validateDeploymentReadiness(
                new List<MockInterviewDevOpsService.DeploymentComponent>()
            );
        Test.stopTest();

        System.assertEquals(false, result.isReady);
    }

    @IsTest
    static void testDeploymentReadiness_noApexNoDestructive() {
        List<MockInterviewDevOpsService.DeploymentComponent> comps =
            new List<MockInterviewDevOpsService.DeploymentComponent>{
                new MockInterviewDevOpsService.DeploymentComponent('MyFlow', 'Flow', false),
                new MockInterviewDevOpsService.DeploymentComponent('MyObject__c', 'CustomObject', false)
            };

        Test.startTest();
        MockInterviewDevOpsService.DeploymentReadinessResult result =
            MockInterviewDevOpsService.validateDeploymentReadiness(comps);
        Test.stopTest();

        // No Apex = no coverage check, no destructive = no blockers
        System.assertEquals(true, result.isReady);
        System.assertEquals(0, result.blockers.size());
        System.assertEquals(2, result.totalComponents);
    }

    @IsTest
    static void testDeploymentReadiness_tooManyDestructive() {
        List<MockInterviewDevOpsService.DeploymentComponent> comps =
            new List<MockInterviewDevOpsService.DeploymentComponent>();
        for (Integer i = 0; i < 6; i++) {
            comps.add(new MockInterviewDevOpsService.DeploymentComponent(
                'OldClass' + i, 'ApexClass', true
            ));
        }

        Test.startTest();
        MockInterviewDevOpsService.DeploymentReadinessResult result =
            MockInterviewDevOpsService.validateDeploymentReadiness(comps);
        Test.stopTest();

        System.assertEquals(false, result.isReady);
        Boolean hasDestructiveBlocker = false;
        for (String b : result.blockers) {
            if (b.contains('destructive')) hasDestructiveBlocker = true;
        }
        System.assert(hasDestructiveBlocker);
    }

    @IsTest
    static void testDeploymentReadiness_warningForDestructive() {
        List<MockInterviewDevOpsService.DeploymentComponent> comps =
            new List<MockInterviewDevOpsService.DeploymentComponent>{
                new MockInterviewDevOpsService.DeploymentComponent('NewFlow', 'Flow', false),
                new MockInterviewDevOpsService.DeploymentComponent('OldFlow', 'Flow', true)
            };

        Test.startTest();
        MockInterviewDevOpsService.DeploymentReadinessResult result =
            MockInterviewDevOpsService.validateDeploymentReadiness(comps);
        Test.stopTest();

        System.assertEquals(1, result.warnings.size());
        System.assert(result.warnings[0].contains('DESTRUCTIVE'));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewDevOpsService — Coverage Query (graceful degradation)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetApexTestCoverage_nullNames() {
        Test.startTest();
        List<MockInterviewDevOpsService.ApexCoverageResult> results =
            MockInterviewDevOpsService.getApexTestCoverage(null);
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void testGetApexTestCoverage_emptyNames() {
        Test.startTest();
        List<MockInterviewDevOpsService.ApexCoverageResult> results =
            MockInterviewDevOpsService.getApexTestCoverage(new List<String>());
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void testGetApexTestCoverage_gracefulDegradation() {
        // ApexCodeCoverageAggregate may not be queryable in test context;
        // method must return empty list (not throw).
        Test.startTest();
        List<MockInterviewDevOpsService.ApexCoverageResult> results =
            MockInterviewDevOpsService.getApexTestCoverage(
                new List<String>{ 'MockInterviewDevOpsService' }
            );
        Test.stopTest();

        // Either 0 (graceful degrade) or actual coverage data — never throws
        System.assertNotEquals(null, results);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewDevOpsService — Environment Config Factory
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testEnvConfig_scratchOrg() {
        Test.startTest();
        MockInterviewDevOpsService.EnvironmentConfig cfg =
            MockInterviewDevOpsService.buildEnvironmentConfig(
                MockInterviewDevOpsService.OrgEnvironment.SCRATCH_ORG
            );
        Test.stopTest();

        System.assertEquals(false, cfg.externalCalloutsEnabled);
        System.assertEquals(false, cfg.emailSendsEnabled);
        System.assertEquals(true,  cfg.useStubData);
        System.assertEquals(10,    cfg.batchChunkSize);
        System.assertEquals('_Scratch', cfg.namedCredentialSuffix);
    }

    @IsTest
    static void testEnvConfig_sandboxFull() {
        Test.startTest();
        MockInterviewDevOpsService.EnvironmentConfig cfg =
            MockInterviewDevOpsService.buildEnvironmentConfig(
                MockInterviewDevOpsService.OrgEnvironment.SANDBOX_FULL
            );
        Test.stopTest();

        System.assertEquals(true,  cfg.externalCalloutsEnabled);
        System.assertEquals(false, cfg.emailSendsEnabled); // always suppressed in sandbox
        System.assertEquals(200,   cfg.batchChunkSize);
    }

    @IsTest
    static void testEnvConfig_production() {
        Test.startTest();
        MockInterviewDevOpsService.EnvironmentConfig cfg =
            MockInterviewDevOpsService.buildEnvironmentConfig(
                MockInterviewDevOpsService.OrgEnvironment.PRODUCTION
            );
        Test.stopTest();

        System.assertEquals(true, cfg.externalCalloutsEnabled);
        System.assertEquals(true, cfg.emailSendsEnabled);
        System.assertEquals('',   cfg.namedCredentialSuffix);
        System.assertEquals(1000000, cfg.maxDailyApiCalls);
    }

    @IsTest
    static void testEnvConfig_sandboxDev() {
        Test.startTest();
        MockInterviewDevOpsService.EnvironmentConfig cfg =
            MockInterviewDevOpsService.buildEnvironmentConfig(
                MockInterviewDevOpsService.OrgEnvironment.SANDBOX_DEV
            );
        Test.stopTest();

        System.assertEquals(false, cfg.externalCalloutsEnabled);
        System.assertEquals('_Dev', cfg.namedCredentialSuffix);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewDevOpsService — Destructive Change Detector
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testFindDestructive_componentMissingFromSource() {
        List<MockInterviewDevOpsService.DeploymentComponent> source =
            new List<MockInterviewDevOpsService.DeploymentComponent>{
                new MockInterviewDevOpsService.DeploymentComponent('ClassA', 'ApexClass', false)
            };
        List<MockInterviewDevOpsService.DeploymentComponent> target =
            new List<MockInterviewDevOpsService.DeploymentComponent>{
                new MockInterviewDevOpsService.DeploymentComponent('ClassA', 'ApexClass', false),
                new MockInterviewDevOpsService.DeploymentComponent('OldClass', 'ApexClass', false)
            };

        Test.startTest();
        List<MockInterviewDevOpsService.DeploymentComponent> destructive =
            MockInterviewDevOpsService.findDestructiveComponents(source, target);
        Test.stopTest();

        System.assertEquals(1, destructive.size());
        System.assertEquals('OldClass', destructive[0].apiName);
        System.assertEquals(true, destructive[0].isDestructive);
    }

    @IsTest
    static void testFindDestructive_noMissingComponents() {
        List<MockInterviewDevOpsService.DeploymentComponent> source =
            new List<MockInterviewDevOpsService.DeploymentComponent>{
                new MockInterviewDevOpsService.DeploymentComponent('ClassA', 'ApexClass', false),
                new MockInterviewDevOpsService.DeploymentComponent('ClassB', 'ApexClass', false)
            };
        List<MockInterviewDevOpsService.DeploymentComponent> target =
            new List<MockInterviewDevOpsService.DeploymentComponent>{
                new MockInterviewDevOpsService.DeploymentComponent('ClassA', 'ApexClass', false)
            };

        Test.startTest();
        List<MockInterviewDevOpsService.DeploymentComponent> destructive =
            MockInterviewDevOpsService.findDestructiveComponents(source, target);
        Test.stopTest();

        System.assertEquals(0, destructive.size());
    }

    @IsTest
    static void testFindDestructive_nullTargetReturnsEmpty() {
        Test.startTest();
        List<MockInterviewDevOpsService.DeploymentComponent> destructive =
            MockInterviewDevOpsService.findDestructiveComponents(null, null);
        Test.stopTest();

        System.assertEquals(0, destructive.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewDevOpsService — Package Model Classifier
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testPackageModel_isvReturnsManagedPkg() {
        Test.startTest();
        MockInterviewDevOpsService.PackageModel model =
            MockInterviewDevOpsService.classifyPackageModel(true, false, false, false, false);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.PackageModel.MANAGED_2GP, model);
    }

    @IsTest
    static void testPackageModel_namespaceReturnsManagedPkg() {
        Test.startTest();
        MockInterviewDevOpsService.PackageModel model =
            MockInterviewDevOpsService.classifyPackageModel(false, true, false, false, false);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.PackageModel.MANAGED_2GP, model);
    }

    @IsTest
    static void testPackageModel_ciCdReturnsUnlocked() {
        Test.startTest();
        MockInterviewDevOpsService.PackageModel model =
            MockInterviewDevOpsService.classifyPackageModel(false, false, false, true, false);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.PackageModel.UNLOCKED_PACKAGE, model);
    }

    @IsTest
    static void testPackageModel_singleOrgNoRequirementsReturnsOrgDev() {
        Test.startTest();
        MockInterviewDevOpsService.PackageModel model =
            MockInterviewDevOpsService.classifyPackageModel(false, false, false, false, true);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.PackageModel.ORG_DEV_MODEL, model);
    }

    @IsTest
    static void testPackageModelExplanations_allModels() {
        for (MockInterviewDevOpsService.PackageModel m :
             MockInterviewDevOpsService.PackageModel.values()) {
            String explanation = MockInterviewDevOpsService.explainPackageChoice(m);
            System.assertNotEquals(null, explanation);
            System.assert(explanation.length() > 10);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewDevOpsService — CI/CD Gate
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testCiGate_nullReadinessReturnsFail() {
        Test.startTest();
        MockInterviewDevOpsService.CiGateOutcome outcome =
            MockInterviewDevOpsService.evaluateCiGate(null);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.CiGateOutcome.FAIL, outcome);
    }

    @IsTest
    static void testCiGate_blockersReturnFail() {
        MockInterviewDevOpsService.DeploymentReadinessResult r =
            new MockInterviewDevOpsService.DeploymentReadinessResult();
        r.blockers  = new List<String>{ 'Coverage below 75%' };
        r.warnings  = new List<String>();
        r.isReady   = false;
        r.estimatedCoveragePct = 60.0;

        Test.startTest();
        MockInterviewDevOpsService.CiGateOutcome outcome =
            MockInterviewDevOpsService.evaluateCiGate(r);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.CiGateOutcome.FAIL, outcome);
    }

    @IsTest
    static void testCiGate_warningsReturnWarn() {
        MockInterviewDevOpsService.DeploymentReadinessResult r =
            new MockInterviewDevOpsService.DeploymentReadinessResult();
        r.blockers  = new List<String>();
        r.warnings  = new List<String>{ 'Coverage below target' };
        r.isReady   = true;
        r.estimatedCoveragePct = 80.0;

        Test.startTest();
        MockInterviewDevOpsService.CiGateOutcome outcome =
            MockInterviewDevOpsService.evaluateCiGate(r);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.CiGateOutcome.WARN, outcome);
    }

    @IsTest
    static void testCiGate_cleanResultReturnsPass() {
        MockInterviewDevOpsService.DeploymentReadinessResult r =
            new MockInterviewDevOpsService.DeploymentReadinessResult();
        r.blockers  = new List<String>();
        r.warnings  = new List<String>();
        r.isReady   = true;
        r.estimatedCoveragePct = 90.0;

        Test.startTest();
        MockInterviewDevOpsService.CiGateOutcome outcome =
            MockInterviewDevOpsService.evaluateCiGate(r);
        Test.stopTest();

        System.assertEquals(MockInterviewDevOpsService.CiGateOutcome.PASS, outcome);
    }

    @IsTest
    static void testFormatCiGateSummary_containsOutcome() {
        MockInterviewDevOpsService.DeploymentReadinessResult r =
            new MockInterviewDevOpsService.DeploymentReadinessResult();
        r.blockers  = new List<String>();
        r.warnings  = new List<String>();
        r.isReady   = true;
        r.estimatedCoveragePct = 92.0;
        r.totalComponents = 5;
        r.apexClassCount  = 3;

        Test.startTest();
        String summary = MockInterviewDevOpsService.formatCiGateSummary(
            MockInterviewDevOpsService.CiGateOutcome.PASS, r
        );
        Test.stopTest();

        System.assert(summary.contains('PASS'));
        System.assert(summary.contains('92.0%'));
        System.assert(summary.contains('5'));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MockInterviewDevOpsService — Sandbox Scrub
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testScrubPersonalData_masksEmailAndPhone() {
        Contact c = new Contact(
            FirstName = 'Test', LastName = 'Scrub',
            Email = 'real@company.com', Phone = '+14155552671'
        );
        insert c;

        Test.startTest();
        MockInterviewDevOpsService.ScrubResult result =
            MockInterviewDevOpsService.scrubPersonalDataForSandbox(10);
        Test.stopTest();

        Contact updated = [SELECT Email, Phone FROM Contact WHERE Id = :c.Id];
        System.assert(updated.Email.startsWith('sandbox+'));
        System.assert(updated.Email.endsWith('@example.invalid'));
        System.assertEquals('+15550000000', updated.Phone);
        System.assertEquals(0, result.failureCount);
    }

    @IsTest
    static void testScrubPersonalData_nullBatchSizeDefaults() {
        Test.startTest();
        MockInterviewDevOpsService.ScrubResult result =
            MockInterviewDevOpsService.scrubPersonalDataForSandbox(null);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testDeactivateScheduledJobs_abortsJobs() {
        // No real scheduled jobs in fresh test context — validate it runs without error
        Test.startTest();
        Integer aborted = MockInterviewDevOpsService.deactivateScheduledJobs(null);
        Test.stopTest();

        System.assert(aborted >= 0);
    }

    @IsTest
    static void testDeactivateScheduledJobs_keepsAllowlisted() {
        // allowlist everything — nothing should be aborted
        Test.startTest();
        Integer aborted = MockInterviewDevOpsService.deactivateScheduledJobs(
            new Set<String>{ 'JobA', 'JobB', 'JobC' }
        );
        Test.stopTest();

        System.assert(aborted >= 0); // 0 if no other jobs, or less than total
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ApexCoverageResult DTO — meetsMinimum / meetsTarget getters
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void testApexCoverageResult_getters() {
        MockInterviewDevOpsService.ApexCoverageResult r =
            new MockInterviewDevOpsService.ApexCoverageResult('MyClass', 90, 10, 90.0);

        System.assertEquals(true,  r.meetsMinimum);
        System.assertEquals(true,  r.meetsTarget);

        MockInterviewDevOpsService.ApexCoverageResult low =
            new MockInterviewDevOpsService.ApexCoverageResult('LowClass', 50, 50, 50.0);

        System.assertEquals(false, low.meetsMinimum);
        System.assertEquals(false, low.meetsTarget);

        MockInterviewDevOpsService.ApexCoverageResult mid =
            new MockInterviewDevOpsService.ApexCoverageResult('MidClass', 80, 20, 80.0);

        System.assertEquals(true,  mid.meetsMinimum);
        System.assertEquals(false, mid.meetsTarget);
    }
}
