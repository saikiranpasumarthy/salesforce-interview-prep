/**
 * DeploymentVerifier
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 20 — CI/CD: post-deployment verification Apex class.
 *
 * WHY POST-DEPLOY VERIFICATION?
 * ══════════════════════════════
 * After a deployment completes (especially to production), it is good practice
 * to run a smoke test that:
 *   1. Confirms critical Apex classes compiled and are active
 *   2. Confirms critical triggers are active
 *   3. Verifies platform event / CDC configuration
 *   4. Checks record counts to ensure data integrity
 *
 * This class is designed to be called from:
 *   a) A pipeline step via Anonymous Apex:
 *        sf apex run --file scripts/post-deploy-verify.apex --target-org my-org
 *   b) A post-install script in an Unlocked Package
 *   c) A scheduled job that runs after each deployment window
 *
 * ANONYMOUS APEX INVOCATION (from pipeline):
 * ═══════════════════════════════════════════
 *   sf apex run \
 *     --file scripts/post-deploy-verify.apex \
 *     --target-org production-org
 *
 * The .apex script simply calls:
 *   DeploymentVerifier.VerificationResult r = DeploymentVerifier.verify();
 *   System.debug(r.toReport());
 *   if (!r.passed) { throw new DeploymentVerifier.VerificationException(r.toReport()); }
 */
public with sharing class DeploymentVerifier {

    // ─────────────────────────────────────────────────────────────────────────
    // Result types
    // ─────────────────────────────────────────────────────────────────────────

    public class CheckResult {
        public String  checkName;
        public Boolean passed;
        public String  message;

        public CheckResult(String name, Boolean ok, String msg) {
            checkName = name;
            passed    = ok;
            message   = msg;
        }
    }

    public class VerificationResult {
        public Boolean           passed;
        public List<CheckResult> checks;
        public Datetime          runAt;

        public VerificationResult() {
            checks = new List<CheckResult>();
            passed = true;
            runAt  = Datetime.now();
        }

        public void add(CheckResult c) {
            checks.add(c);
            if (!c.passed) { passed = false; }
        }

        public String toReport() {
            List<String> lines = new List<String>();
            lines.add('=== Deployment Verification Report ===');
            lines.add('Run at: ' + runAt.format('yyyy-MM-dd HH:mm:ss'));
            lines.add('Overall: ' + (passed ? 'PASSED' : 'FAILED'));
            lines.add('');
            for (CheckResult c : checks) {
                String icon = c.passed ? '[OK]' : '[FAIL]';
                lines.add(icon + ' ' + c.checkName + ': ' + c.message);
            }
            return String.join(lines, '\n');
        }
    }

    public class VerificationException extends Exception {}

    // ─────────────────────────────────────────────────────────────────────────
    // Main verification entry point
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs all verification checks and returns a VerificationResult.
     * Does NOT throw — callers decide whether to fail based on result.passed.
     */
    public static VerificationResult verify() {
        VerificationResult result = new VerificationResult();

        result.add(checkApexClassesActive());
        result.add(checkTriggersActive());
        result.add(checkCriticalClassCompilation());
        result.add(checkOrgShape());
        result.add(checkCustomObjects());

        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Individual checks
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Verifies that all Apex classes compiled successfully.
     * Any IsValid=false class means deployment introduced a compile error.
     */
    @TestVisible
    static CheckResult checkApexClassesActive() {
        Integer invalid = [
            SELECT COUNT() FROM ApexClass
            WHERE  Status = 'Active'
            AND    IsValid = false
            AND    NamespacePrefix = null
        ];
        if (invalid > 0) {
            return new CheckResult(
                'Apex Compilation',
                false,
                invalid + ' class(es) have compilation errors — check Setup → Apex Classes'
            );
        }
        Integer total = [
            SELECT COUNT() FROM ApexClass
            WHERE  Status = 'Active' AND NamespacePrefix = null
        ];
        return new CheckResult('Apex Compilation', true,
            total + ' active classes, all compiled successfully');
    }

    /**
     * Verifies that all project triggers are active.
     * An inactive trigger silently skips execution — dangerous in production.
     */
    @TestVisible
    static CheckResult checkTriggersActive() {
        List<ApexTrigger> inactive = [
            SELECT Name, TableEnumOrId FROM ApexTrigger
            WHERE  Status != 'Active' AND NamespacePrefix = null
        ];
        if (!inactive.isEmpty()) {
            List<String> names = new List<String>();
            for (ApexTrigger t : inactive) { names.add(t.Name); }
            return new CheckResult(
                'Trigger Status',
                false,
                'Inactive triggers found: ' + String.join(names, ', ')
            );
        }
        Integer total = [SELECT COUNT() FROM ApexTrigger WHERE Status = 'Active' AND NamespacePrefix = null];
        return new CheckResult('Trigger Status', true, total + ' active triggers');
    }

    /**
     * Spot-checks that specific critical classes exist and are valid.
     * Customize this list for your project's mission-critical classes.
     */
    @TestVisible
    static CheckResult checkCriticalClassCompilation() {
        Set<String> criticalClasses = new Set<String>{
            'PlatformEventService',
            'CdcEventHandler',
            'ExternalApiClient',
            'OrgConfigService'
        };

        List<ApexClass> found = [
            SELECT Name, IsValid FROM ApexClass
            WHERE  Name IN :criticalClasses
            AND    NamespacePrefix = null
        ];

        List<String> missing  = new List<String>(criticalClasses);
        List<String> invalid  = new List<String>();

        for (ApexClass cls : found) {
            missing.remove(cls.Name);
            if (!cls.IsValid) { invalid.add(cls.Name); }
        }

        if (!missing.isEmpty()) {
            return new CheckResult('Critical Classes', false,
                'Missing classes: ' + String.join(missing, ', '));
        }
        if (!invalid.isEmpty()) {
            return new CheckResult('Critical Classes', false,
                'Compilation errors in: ' + String.join(invalid, ', '));
        }
        return new CheckResult('Critical Classes', true,
            String.join(new List<String>(criticalClasses), ', ') + ' — all present and valid');
    }

    /**
     * Verifies the org shape is expected (e.g., not accidentally deploying to wrong env).
     * Returns the org type as informational — does not fail.
     */
    @TestVisible
    static CheckResult checkOrgShape() {
        Organization org = [
            SELECT Name, OrganizationType, IsSandbox, InstanceName
            FROM   Organization LIMIT 1
        ];
        String info = org.Name + ' | ' + org.OrganizationType
            + ' | ' + org.InstanceName
            + (org.IsSandbox ? ' [SANDBOX]' : ' [PRODUCTION]');
        return new CheckResult('Org Shape', true, info);
    }

    /**
     * Verifies that key custom objects are accessible and have records or are empty.
     * Fails if a required object cannot be queried (broken field-level security, etc.).
     */
    @TestVisible
    static CheckResult checkCustomObjects() {
        try {
            Integer projectCount = [SELECT COUNT() FROM Project__c];
            Integer taskCount    = [SELECT COUNT() FROM Project_Task__c];
            return new CheckResult('Custom Objects', true,
                'Project__c: ' + projectCount + ' records, '
                + 'Project_Task__c: ' + taskCount + ' records');
        } catch (QueryException e) {
            return new CheckResult('Custom Objects', false,
                'Cannot query custom objects: ' + e.getMessage());
        }
    }
}
