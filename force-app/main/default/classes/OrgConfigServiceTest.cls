/**
 * OrgConfigServiceTest
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 19 — Tests for OrgConfigService.
 *
 * TESTING STRATEGY:
 * ══════════════════
 * These tests query live org metadata (Organization, ApexClass, ApexTrigger,
 * FlowDefinitionView). No test data setup is needed — the org itself provides
 * the data. This is the correct approach for metadata-introspection services.
 *
 * SYSTEM OBJECTS USED:
 * ═════════════════════
 * • Organization    — always has exactly 1 row, always accessible
 * • ApexClass       — at minimum the classes in this project will be found
 * • ApexTrigger     — at minimum the triggers in this project
 * • FlowDefinitionView — may be empty in a fresh scratch org (no flows deployed)
 * • InstalledSubscriberPackage — may be empty (no packages installed)
 * • PackageLicense  — may be empty (no packages installed)
 *
 * NOTE: Tests assert structure and non-null values, NOT specific counts,
 * because the org state changes as more days are deployed.
 */
@IsTest
private class OrgConfigServiceTest {

    // ─────────────────────────────────────────────────────────────────────────
    // OrgShape
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getOrgShape_returnsNonNullShape() {
        Test.startTest();
        OrgConfigService.OrgShape shape = OrgConfigService.getOrgShape();
        Test.stopTest();

        System.assertNotEquals(null, shape,         'OrgShape should not be null');
        System.assertNotEquals(null, shape.orgId,   'orgId should be populated');
        System.assertNotEquals(null, shape.name,    'org name should be populated');
        System.assertNotEquals(null, shape.orgType, 'orgType should be populated');
        System.assertNotEquals(null, shape.isSandbox, 'isSandbox should be set');
    }

    @IsTest
    static void getOrgShape_orgIdIsValidId() {
        OrgConfigService.OrgShape shape = OrgConfigService.getOrgShape();
        // Org IDs are 18-char strings starting with '00D'
        System.assert(shape.orgId.startsWith('00D'),
            'Org ID should start with 00D, got: ' + shape.orgId);
    }

    @IsTest
    static void getOrgShape_toString_containsOrgId() {
        OrgConfigService.OrgShape shape = OrgConfigService.getOrgShape();
        String str = shape.toString();
        System.assert(str.contains(shape.orgId),
            'toString() should contain orgId');
        System.assert(str.contains(shape.orgType),
            'toString() should contain orgType');
    }

    @IsTest
    static void getOrgShape_trialOrgFlag_matchesTrialExpirationDate() {
        OrgConfigService.OrgShape shape = OrgConfigService.getOrgShape();
        if (shape.trialExpirationDate != null) {
            System.assert(shape.isTrialOrg, 'isTrialOrg should be true when trialExpirationDate is set');
        } else {
            System.assert(!shape.isTrialOrg, 'isTrialOrg should be false when no trialExpirationDate');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Installed packages
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getInstalledPackages_returnsListNotNull() {
        Test.startTest();
        List<OrgConfigService.InstalledPackage> pkgs =
            OrgConfigService.getInstalledPackages();
        Test.stopTest();

        System.assertNotEquals(null, pkgs,
            'getInstalledPackages() should never return null');
    }

    @IsTest
    static void getInstalledPackages_eachHasRequiredFields() {
        List<OrgConfigService.InstalledPackage> pkgs =
            OrgConfigService.getInstalledPackages();

        for (OrgConfigService.InstalledPackage pkg : pkgs) {
            System.assertNotEquals(null, pkg.packageId,
                'packageId should be set for: ' + pkg.packageName);
            System.assertNotEquals(null, pkg.versionNumber,
                'versionNumber should be set for: ' + pkg.packageName);
            // isManaged should match whether namespace is present
            System.assertEquals(
                String.isNotBlank(pkg.namespace), pkg.isManaged,
                'isManaged should match namespace presence for: ' + pkg.packageName);
        }
    }

    @IsTest
    static void getPackagesByNamespace_emptyNamespace_returnsSubset() {
        // Any installed packages with 'sfdc' or well-known namespaces
        // This test verifies the filter logic, not a specific package
        List<OrgConfigService.InstalledPackage> all =
            OrgConfigService.getInstalledPackages();

        // Filter for a namespace that definitely does not exist
        List<OrgConfigService.InstalledPackage> filtered =
            OrgConfigService.getPackagesByNamespace('DEFINITELYNOTANAMESPACE12345');

        System.assert(filtered.isEmpty(),
            'Filtering for a non-existent namespace should return empty list');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Package licenses
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getPackageLicenses_returnsListNotNull() {
        Test.startTest();
        List<OrgConfigService.PackageLicenseInfo> licenses =
            OrgConfigService.getPackageLicenses();
        Test.stopTest();

        System.assertNotEquals(null, licenses,
            'getPackageLicenses() should never return null');
    }

    @IsTest
    static void packageLicenseInfo_availableLicenses_unlimitedReturnsMinusOne() {
        OrgConfigService.PackageLicenseInfo info =
            new OrgConfigService.PackageLicenseInfo();
        info.allowedLicenses = -1;
        info.usedLicenses    = 50;

        System.assertEquals(-1, info.availableLicenses(),
            'availableLicenses() should return -1 for unlimited');
    }

    @IsTest
    static void packageLicenseInfo_availableLicenses_computesDifference() {
        OrgConfigService.PackageLicenseInfo info =
            new OrgConfigService.PackageLicenseInfo();
        info.allowedLicenses = 100;
        info.usedLicenses    = 30;

        System.assertEquals(70, info.availableLicenses(),
            '100 allowed - 30 used = 70 available');
    }

    @IsTest
    static void packageLicenseInfo_availableLicenses_nullUsed_treatsAsZero() {
        OrgConfigService.PackageLicenseInfo info =
            new OrgConfigService.PackageLicenseInfo();
        info.allowedLicenses = 50;
        info.usedLicenses    = null;

        System.assertEquals(50, info.availableLicenses(),
            'Null usedLicenses should be treated as 0');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Apex inventory
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getApexInventory_returnsNonNullInventory() {
        Test.startTest();
        OrgConfigService.ApexInventory inv = OrgConfigService.getApexInventory();
        Test.stopTest();

        System.assertNotEquals(null, inv,                    'inventory not null');
        System.assertNotEquals(null, inv.testClassNames,     'testClassNames not null');
        System.assertNotEquals(null, inv.triggerNames,       'triggerNames not null');
        System.assert(inv.totalClasses >= 0,                 'totalClasses >= 0');
        System.assert(inv.testClasses >= 0,                  'testClasses >= 0');
        System.assert(inv.triggers >= 0,                     'triggers >= 0');
    }

    @IsTest
    static void getApexInventory_thisTestClassIsCountedAsTest() {
        OrgConfigService.ApexInventory inv = OrgConfigService.getApexInventory();

        // This class contains 'Test' in its name — should be counted
        System.assert(inv.testClassNames.size() > 0,
            'At minimum OrgConfigServiceTest should appear in testClassNames');

        Boolean foundSelf = false;
        for (String name : inv.testClassNames) {
            if (name == 'OrgConfigServiceTest') { foundSelf = true; break; }
        }
        System.assert(foundSelf,
            'OrgConfigServiceTest should appear in testClassNames list');
    }

    @IsTest
    static void getApexInventory_testClassesCountLessThanOrEqualTotal() {
        OrgConfigService.ApexInventory inv = OrgConfigService.getApexInventory();
        System.assert(inv.testClasses <= inv.totalClasses,
            'Test class count should be <= total class count');
    }

    @IsTest
    static void getApexInventory_triggersCountMatchesTriggerNames() {
        OrgConfigService.ApexInventory inv = OrgConfigService.getApexInventory();
        System.assertEquals(inv.triggers, inv.triggerNames.size(),
            'triggers count should match triggerNames list size');
    }

    @IsTest
    static void getApexInventory_triggersIncludeProjectTriggers() {
        OrgConfigService.ApexInventory inv = OrgConfigService.getApexInventory();

        // This project has AccountTrigger — verify it appears
        Boolean foundAccountTrigger = false;
        for (String t : inv.triggerNames) {
            if (t.startsWith('AccountTrigger')) { foundAccountTrigger = true; break; }
        }
        System.assert(foundAccountTrigger,
            'AccountTrigger should appear in triggerNames');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Flow inventory
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void getFlowInventory_returnsNonNullInventory() {
        Test.startTest();
        OrgConfigService.FlowInventory inv = OrgConfigService.getFlowInventory();
        Test.stopTest();

        System.assertNotEquals(null, inv,                      'inventory not null');
        System.assertNotEquals(null, inv.countByType,          'countByType not null');
        System.assertNotEquals(null, inv.activeFlowApiNames,   'activeFlowApiNames not null');
        System.assert(inv.totalActiveFlows >= 0,               'totalActiveFlows >= 0');
    }

    @IsTest
    static void getFlowInventory_countByTypeMatchesTotal() {
        OrgConfigService.FlowInventory inv = OrgConfigService.getFlowInventory();

        Integer sumByType = 0;
        for (Integer cnt : inv.countByType.values()) {
            sumByType += cnt;
        }
        System.assertEquals(inv.totalActiveFlows, sumByType,
            'Sum of countByType entries should equal totalActiveFlows');
    }

    @IsTest
    static void getFlowInventory_activeFlowApiNamesMatchTotal() {
        OrgConfigService.FlowInventory inv = OrgConfigService.getFlowInventory();
        System.assertEquals(inv.totalActiveFlows, inv.activeFlowApiNames.size(),
            'activeFlowApiNames size should equal totalActiveFlows');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Readiness check
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void runReadinessCheck_returnsNonBlankString() {
        Test.startTest();
        String report = OrgConfigService.runReadinessCheck();
        Test.stopTest();

        System.assert(String.isNotBlank(report),
            'runReadinessCheck() should return a non-blank string');
    }

    @IsTest
    static void runReadinessCheck_containsOrgInfo() {
        String report = OrgConfigService.runReadinessCheck();

        // Report should contain instance name and org type
        OrgConfigService.OrgShape shape = OrgConfigService.getOrgShape();
        System.assert(report.contains(shape.instanceName),
            'Report should contain instance name');
    }

    @IsTest
    static void runReadinessCheck_containsSandboxOrProductionLabel() {
        String report = OrgConfigService.runReadinessCheck();
        System.assert(
            report.contains('[SANDBOX]') || report.contains('[PRODUCTION]'),
            'Report should contain org environment label');
    }
}
