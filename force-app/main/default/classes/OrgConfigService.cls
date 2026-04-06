/**
 * OrgConfigService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 19 — DevOps: querying org shape, installed packages, and metadata
 * inventory via SOQL against Salesforce system objects.
 *
 * WHY THIS MATTERS FOR DEVOPS:
 * ══════════════════════════════
 * Senior Salesforce developers often need to interrogate the target org
 * programmatically during deployments, validations, or post-install scripts.
 * This class demonstrates:
 *   1. Organization sObject — org edition, namespace, sandbox flag
 *   2. InstalledSubscriberPackage — what packages are installed + version
 *   3. PackageLicense — license counts per package
 *   4. ApexClass SOQL — metadata inventory (all classes, test classes)
 *   5. FlowDefinitionView — active flow inventory
 *
 * SCRATCH ORG CONTEXT:
 * ═════════════════════
 * These queries run in any Salesforce org context, including scratch orgs.
 * They are safe to run in post-install scripts and anonymous Apex during CI/CD.
 *
 * TOOLING API vs SOQL:
 * ═════════════════════
 * Many metadata objects (ApexClass, ApexTrigger, FlowDefinitionView) are
 * queryable via both standard SOQL and the Tooling API REST endpoint.
 * Standard SOQL is simpler and works in Apex. The Tooling API is needed for
 * operations that require execution context or code coverage data:
 *   • /services/data/vXX.0/tooling/query?q=SELECT+...+FROM+ApexClass
 */
public with sharing class OrgConfigService {

    // ─────────────────────────────────────────────────────────────────────────
    // Inner types
    // ─────────────────────────────────────────────────────────────────────────

    public class OrgShape {
        public String  orgId;
        public String  name;
        public String  instanceName;
        public String  orgType;          // 'Developer', 'Enterprise', 'Sandbox', etc.
        public String  namespace;        // blank if no namespace registered
        public Boolean isSandbox;
        public Boolean isTrialOrg;
        public String  podName;
        public String  countryCode;
        public Datetime trialExpirationDate;

        public override String toString() {
            return 'OrgShape[' + orgId + ' | ' + name + ' | ' + orgType
                + (isSandbox ? ' | SANDBOX' : '') + ']';
        }
    }

    public class InstalledPackage {
        public String  packageId;        // 033... SubscriberPackage ID
        public String  packageName;
        public String  namespace;
        public String  versionId;        // 04t... version ID
        public String  versionName;
        public String  versionNumber;    // e.g. '1.5.0.4'
        public Boolean isManaged;
        public Date    installDate;
    }

    public class PackageLicenseInfo {
        public String  packageName;
        public String  namespace;
        public Integer allowedLicenses;  // -1 = unlimited
        public Integer usedLicenses;
        public Integer expirationDate;   // Unix timestamp, may be null

        public Integer availableLicenses() {
            if (allowedLicenses == null || allowedLicenses == -1) { return -1; }
            return allowedLicenses - (usedLicenses != null ? usedLicenses : 0);
        }
    }

    public class ApexInventory {
        public Integer totalClasses;
        public Integer testClasses;
        public Integer triggers;
        public List<String> testClassNames;
        public List<String> triggerNames;
    }

    public class FlowInventory {
        public Integer totalActiveFlows;
        public Map<String, Integer> countByType;   // e.g. 'AutoLaunchedFlow' → 3
        public List<String> activeFlowApiNames;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Org shape
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns basic information about the current org.
     * The Organization sObject always has exactly one row.
     */
    public static OrgShape getOrgShape() {
        Organization org = [
            SELECT  Id, Name, InstanceName, OrganizationType,
                    NamespacePrefix, IsSandbox, TrialExpirationDate,
                    Country, DefaultLocaleSidKey, LanguageLocaleKey
            FROM    Organization
            LIMIT   1
        ];

        OrgShape shape   = new OrgShape();
        shape.orgId      = org.Id;
        shape.name       = org.Name;
        shape.instanceName = org.InstanceName;
        shape.orgType    = org.OrganizationType;
        shape.namespace  = org.NamespacePrefix;
        shape.isSandbox  = org.IsSandbox;
        shape.isTrialOrg = org.TrialExpirationDate != null;
        shape.trialExpirationDate = org.TrialExpirationDate;
        shape.countryCode = org.Country;
        return shape;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Installed packages
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns all installed managed and unlocked packages.
     *
     * InstalledSubscriberPackage is a virtual read-only sObject — it reflects
     * what is installed in the org, equivalent to Setup → Installed Packages.
     *
     * NOTE: InstalledSubscriberPackage is NOT available in all API contexts.
     * If it throws an exception (e.g., in a scratch org with no packages),
     * the caller receives an empty list.
     */
    public static List<InstalledPackage> getInstalledPackages() {
        List<InstalledPackage> result = new List<InstalledPackage>();
        try {
            List<InstalledSubscriberPackage> records = [
                SELECT  Id,
                        SubscriberPackage.Id,
                        SubscriberPackage.Name,
                        SubscriberPackage.NamespacePrefix,
                        SubscriberPackageVersion.Id,
                        SubscriberPackageVersion.Name,
                        SubscriberPackageVersion.MajorVersion,
                        SubscriberPackageVersion.MinorVersion,
                        SubscriberPackageVersion.PatchVersion,
                        SubscriberPackageVersion.BuildNumber
                FROM    InstalledSubscriberPackage
                ORDER BY SubscriberPackage.Name
            ];

            for (InstalledSubscriberPackage r : records) {
                InstalledPackage pkg  = new InstalledPackage();
                pkg.packageId        = r.SubscriberPackage.Id;
                pkg.packageName      = r.SubscriberPackage.Name;
                pkg.namespace        = r.SubscriberPackage.NamespacePrefix;
                pkg.versionId        = r.SubscriberPackageVersion.Id;
                pkg.versionName      = r.SubscriberPackageVersion.Name;
                pkg.versionNumber    =
                    r.SubscriberPackageVersion.MajorVersion + '.'
                    + r.SubscriberPackageVersion.MinorVersion + '.'
                    + r.SubscriberPackageVersion.PatchVersion + '.'
                    + r.SubscriberPackageVersion.BuildNumber;
                pkg.isManaged        = String.isNotBlank(pkg.namespace);
                result.add(pkg);
            }
        } catch (QueryException e) {
            System.debug(LoggingLevel.WARN,
                'InstalledSubscriberPackage not available: ' + e.getMessage());
        }
        return result;
    }

    /**
     * Returns packages matching a specific namespace prefix.
     */
    public static List<InstalledPackage> getPackagesByNamespace(String namespace) {
        List<InstalledPackage> all = getInstalledPackages();
        List<InstalledPackage> filtered = new List<InstalledPackage>();
        for (InstalledPackage pkg : all) {
            if (namespace.equalsIgnoreCase(pkg.namespace)) {
                filtered.add(pkg);
            }
        }
        return filtered;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Package licenses
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns license usage for all installed packages.
     * PackageLicense is available in any org where packages are installed.
     */
    public static List<PackageLicenseInfo> getPackageLicenses() {
        List<PackageLicenseInfo> result = new List<PackageLicenseInfo>();
        try {
            for (PackageLicense lic : [
                SELECT  NamespacePrefix, AllowedLicenses, UsedLicenses, Status
                FROM    PackageLicense
                ORDER BY NamespacePrefix
            ]) {
                PackageLicenseInfo info  = new PackageLicenseInfo();
                info.namespace           = lic.NamespacePrefix;
                info.packageName         = lic.NamespacePrefix; // best available without join
                info.allowedLicenses     = lic.AllowedLicenses;
                info.usedLicenses        = lic.UsedLicenses;
                result.add(info);
            }
        } catch (QueryException e) {
            System.debug(LoggingLevel.WARN,
                'PackageLicense query failed: ' + e.getMessage());
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Apex inventory
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns a summary of all Apex classes and triggers deployed in the org.
     *
     * ApexClass is queryable via standard SOQL. Key fields:
     *   Name          — class name
     *   Status        — 'Active' | 'Inactive' (Inactive = compile error)
     *   IsValid       — true if compiled successfully
     *   ApiVersion    — API version the class was saved at
     *   LengthWithoutComments — line count proxy for complexity
     */
    public static ApexInventory getApexInventory() {
        ApexInventory inv = new ApexInventory();
        inv.testClassNames = new List<String>();
        inv.triggerNames   = new List<String>();

        List<ApexClass> classes = [
            SELECT Name, Status, IsValid, ApiVersion, NamespacePrefix
            FROM   ApexClass
            WHERE  Status = 'Active'
            AND    NamespacePrefix = null
            ORDER BY Name
        ];

        inv.totalClasses = classes.size();
        inv.testClasses  = 0;

        for (ApexClass cls : classes) {
            // Heuristic: test classes typically have 'Test' in the name
            // In production, use SymbolTable or Tooling API for @isTest detection
            if (cls.Name.containsIgnoreCase('Test')) {
                inv.testClasses++;
                inv.testClassNames.add(cls.Name);
            }
        }

        List<ApexTrigger> triggers = [
            SELECT Name, Status, TableEnumOrId
            FROM   ApexTrigger
            WHERE  Status = 'Active'
            AND    NamespacePrefix = null
            ORDER BY Name
        ];

        inv.triggers = triggers.size();
        for (ApexTrigger t : triggers) {
            inv.triggerNames.add(t.Name + ' [' + t.TableEnumOrId + ']');
        }

        return inv;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Flow inventory
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns active flow inventory grouped by process type.
     *
     * FlowDefinitionView is a read-only virtual sObject (API v47+).
     * It shows the latest active version of each flow definition.
     *
     * Key processType values:
     *   AutoLaunchedFlow    — Record-Triggered / Auto-Launched flows
     *   Flow                — Screen Flows
     *   Workflow            — Legacy Workflow Rules (converted to flows)
     *   CustomEvent         — Platform Event-triggered flows
     *   InvocableProcess    — Process Builder (deprecated)
     */
    public static FlowInventory getFlowInventory() {
        FlowInventory inv     = new FlowInventory();
        inv.countByType       = new Map<String, Integer>();
        inv.activeFlowApiNames = new List<String>();

        List<FlowDefinitionView> flows = [
            SELECT  ApiName, Label, ProcessType, TriggerType,
                    IsActive, LatestVersionId
            FROM    FlowDefinitionView
            WHERE   IsActive = true
            ORDER BY ProcessType, ApiName
        ];

        inv.totalActiveFlows = flows.size();
        for (FlowDefinitionView f : flows) {
            inv.activeFlowApiNames.add(f.ApiName);
            Integer cnt = inv.countByType.get(f.ProcessType);
            inv.countByType.put(f.ProcessType, cnt == null ? 1 : cnt + 1);
        }
        return inv;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Org readiness check (useful in post-install / pre-deploy scripts)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Performs a quick org readiness check and returns a summary string.
     * Useful as a smoke-test step in deployment pipelines.
     *
     * Checks:
     *   1. Org type and sandbox status
     *   2. Active Apex class count and any compilation failures
     *   3. Installed package count
     */
    public static String runReadinessCheck() {
        List<String> lines = new List<String>();

        OrgShape shape = getOrgShape();
        lines.add('Org: ' + shape.name + ' (' + shape.orgType + ')'
            + (shape.isSandbox ? ' [SANDBOX]' : ' [PRODUCTION]'));
        lines.add('Instance: ' + shape.instanceName);
        lines.add('Namespace: ' + (String.isBlank(shape.namespace) ? '<none>' : shape.namespace));

        // Check for inactive (failed) Apex classes
        Integer invalidClasses = [
            SELECT COUNT() FROM ApexClass
            WHERE  Status = 'Active' AND IsValid = false
            AND    NamespacePrefix = null
        ];
        if (invalidClasses > 0) {
            lines.add('WARNING: ' + invalidClasses + ' Apex class(es) failed compilation');
        } else {
            lines.add('Apex: All classes valid');
        }

        List<InstalledPackage> pkgs = getInstalledPackages();
        lines.add('Installed packages: ' + pkgs.size());

        return String.join(lines, '\n');
    }
}
