/**
 * Day 38 — Mock Interview Day 2: DevOps + Deployment Patterns
 *
 * Production patterns for DevOps-focused interview coding challenges:
 *
 *  1. Deployment readiness check  — coverage gap, destructive changes guard
 *  2. Apex code coverage query    — ApexCodeCoverageAggregate introspection
 *  3. Environment config factory  — scratch / sandboxDev / sandboxFull / prod
 *  4. Destructive change detector — diff source vs target component sets
 *  5. SFDX packaging helper       — unlocked package version metadata classifier
 *  6. CI/CD gate logic            — pass / warn / fail decision with threshold
 *  7. Sandbox refresh helper      — post-refresh data scrubbing pattern
 */
public with sharing class MockInterviewDevOpsService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1 & 4. DEPLOYMENT READINESS — coverage gap + destructive change guard
    //
    // Interview Q: "What checks do you perform before deploying to production?"
    //
    // Required Apex test coverage: 75 % org-wide (Salesforce minimum)
    // Best practice target: 85 %+ for healthy codebases
    // Destructive changes (deletion of classes/triggers) require extra review —
    // they can break Flow references, integrations, and managed package bindings.
    // ═══════════════════════════════════════════════════════════════════════════

    public static final Decimal MINIMUM_COVERAGE_PCT = 75.0;
    public static final Decimal TARGET_COVERAGE_PCT  = 85.0;

    public static DeploymentReadinessResult validateDeploymentReadiness(
        List<DeploymentComponent> components
    ) {
        DeploymentReadinessResult result = new DeploymentReadinessResult();
        result.isReady       = true;
        result.warnings      = new List<String>();
        result.blockers      = new List<String>();
        result.totalComponents = (components != null) ? components.size() : 0;

        if (components == null || components.isEmpty()) {
            result.isReady = false;
            result.blockers.add('No components provided for deployment validation');
            return result;
        }

        // Count Apex types
        List<String> apexClassNames = new List<String>();
        Integer triggerCount = 0;
        Integer destructiveCount = 0;

        for (DeploymentComponent comp : components) {
            if ('ApexClass'.equalsIgnoreCase(comp.componentType) && !comp.isDestructive) {
                apexClassNames.add(comp.apiName);
            }
            if ('ApexTrigger'.equalsIgnoreCase(comp.componentType)) {
                triggerCount++;
            }
            if (comp.isDestructive) {
                destructiveCount++;
                result.warnings.add('DESTRUCTIVE: ' + comp.componentType + ' → ' + comp.apiName
                    + ' will be deleted. Verify no Flow/Integration dependencies.');
            }
        }
        result.apexClassCount   = apexClassNames.size();
        result.triggerCount     = triggerCount;
        result.destructiveCount = destructiveCount;

        // Check coverage for Apex classes in this deployment
        if (!apexClassNames.isEmpty()) {
            List<ApexCoverageResult> coverageResults = getApexTestCoverage(apexClassNames);
            Decimal avgCoverage = averageCoverage(coverageResults);
            result.estimatedCoveragePct = avgCoverage;

            if (avgCoverage < MINIMUM_COVERAGE_PCT) {
                result.isReady = false;
                result.blockers.add(
                    'Average Apex coverage ' + avgCoverage.setScale(1)
                    + '% is below the 75% minimum required for production deploy.'
                );
            } else if (avgCoverage < TARGET_COVERAGE_PCT) {
                result.warnings.add(
                    'Coverage ' + avgCoverage.setScale(1)
                    + '% meets minimum but is below the 85% target. '
                    + 'Consider adding tests before deploying.'
                );
            }
            result.coverageResults = coverageResults;
        }

        // Block deployment if too many destructive changes without explicit override
        if (destructiveCount > 5) {
            result.isReady = false;
            result.blockers.add(
                destructiveCount + ' destructive changes detected. '
                + 'Manual review required — large-scale deletion may break dependencies.'
            );
        }

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. APEX TEST COVERAGE QUERY
    //
    // Interview Q: "How do you query Apex code coverage programmatically?"
    //
    // ApexCodeCoverageAggregate: summary view — one row per class.
    //   NumLinesCovered   = lines touched by ANY test class
    //   NumLinesUncovered = lines never executed
    //
    // ApexCodeCoverage: detail view — one row per (Apex class × Test class).
    //
    // Both sObjects are Tooling API objects — available in Tooling API SOQL only.
    // In Apex unit tests / anonymous Apex, use try/catch for graceful degradation.
    // ═══════════════════════════════════════════════════════════════════════════

    public static List<ApexCoverageResult> getApexTestCoverage(List<String> classNames) {
        List<ApexCoverageResult> results = new List<ApexCoverageResult>();
        if (classNames == null || classNames.isEmpty()) return results;

        try {
            // ApexCodeCoverageAggregate is a Tooling API object — may not be queryable
            // in all execution contexts. Gracefully degrade if unavailable.
            List<SObject> rows = Database.query(
                'SELECT ApexClassOrTriggerId, ApexClassOrTrigger.Name, '
                + 'NumLinesCovered, NumLinesUncovered '
                + 'FROM ApexCodeCoverageAggregate '
                + 'WHERE ApexClassOrTrigger.Name IN :classNames'
            );
            for (SObject row : rows) {
                Integer covered   = (Integer) row.get('NumLinesCovered');
                Integer uncovered = (Integer) row.get('NumLinesUncovered');
                Integer total     = (covered != null ? covered : 0)
                                  + (uncovered != null ? uncovered : 0);
                Decimal pct       = total > 0
                    ? (Decimal) covered / total * 100
                    : 0;
                SObject nameRef = row.getSObject('ApexClassOrTrigger');
                results.add(new ApexCoverageResult(
                    (String) nameRef?.get('Name'),
                    covered   != null ? covered   : 0,
                    uncovered != null ? uncovered : 0,
                    pct.setScale(1)
                ));
            }
        } catch (Exception e) {
            // Tooling API objects not available in this execution context
            // Return empty — caller treats missing coverage as a warning, not a blocker
        }
        return results;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. ENVIRONMENT CONFIG FACTORY
    //
    // Interview Q: "How do you manage environment-specific configuration across
    //               scratch org → sandbox → UAT → production?"
    //
    // Pattern: Custom Metadata Type holds config; Apex factory resolves correct record.
    //   - Scratch orgs:   mock/stub data, no email sends, relaxed limits
    //   - Dev sandboxes:  real (but minimal) data, no external calls
    //   - Full sandboxes: production-like, some external services live
    //   - Production:     all governors at max, all external services live
    //
    // Never hard-code environment-specific endpoints — use Custom Metadata or
    // Named Credentials so values are deployable and auditable.
    // ═══════════════════════════════════════════════════════════════════════════

    public enum OrgEnvironment {
        SCRATCH_ORG,
        SANDBOX_DEV,
        SANDBOX_FULL,
        PRODUCTION
    }

    public static EnvironmentConfig buildEnvironmentConfig(OrgEnvironment env) {
        EnvironmentConfig cfg = new EnvironmentConfig();
        cfg.environment = env;

        switch on env {
            when SCRATCH_ORG {
                cfg.externalCalloutsEnabled  = false;
                cfg.emailSendsEnabled        = false;
                cfg.batchChunkSize           = 10;   // small for fast unit test iteration
                cfg.useStubData              = true;
                cfg.maxDailyApiCalls         = 15000;
                cfg.namedCredentialSuffix    = '_Scratch';
                cfg.description              = 'Scratch org: stubs only, no callouts, no emails.';
            }
            when SANDBOX_DEV {
                cfg.externalCalloutsEnabled  = false;
                cfg.emailSendsEnabled        = false;
                cfg.batchChunkSize           = 50;
                cfg.useStubData              = false;
                cfg.maxDailyApiCalls         = 15000;
                cfg.namedCredentialSuffix    = '_Dev';
                cfg.description              = 'Dev sandbox: real data, external calls disabled.';
            }
            when SANDBOX_FULL {
                cfg.externalCalloutsEnabled  = true;
                cfg.emailSendsEnabled        = false; // never email from sandbox unless explicit
                cfg.batchChunkSize           = 200;
                cfg.useStubData              = false;
                cfg.maxDailyApiCalls         = 100000;
                cfg.namedCredentialSuffix    = '_UAT';
                cfg.description              = 'Full sandbox: callouts live, emails suppressed.';
            }
            when PRODUCTION {
                cfg.externalCalloutsEnabled  = true;
                cfg.emailSendsEnabled        = true;
                cfg.batchChunkSize           = 200;
                cfg.useStubData              = false;
                cfg.maxDailyApiCalls         = 1000000;
                cfg.namedCredentialSuffix    = '';     // no suffix — base Named Credential
                cfg.description              = 'Production: all governors enforced.';
            }
        }
        return cfg;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. DESTRUCTIVE CHANGE DETECTOR
    //
    // Interview Q: "How do you detect components that exist in the target org
    //               but not in the source package being deployed?"
    //
    // Destructive changes must be in destructiveChanges.xml (pre) or
    // destructiveChangesPost.xml. If not listed, Salesforce will NOT delete them.
    // ═══════════════════════════════════════════════════════════════════════════

    public static List<DeploymentComponent> findDestructiveComponents(
        List<DeploymentComponent> sourceComponents,
        List<DeploymentComponent> targetComponents
    ) {
        List<DeploymentComponent> destructive = new List<DeploymentComponent>();
        if (targetComponents == null) return destructive;

        // Build a lookup set of "type:apiName" from source
        Set<String> sourceKeys = new Set<String>();
        if (sourceComponents != null) {
            for (DeploymentComponent src : sourceComponents) {
                sourceKeys.add(src.componentType.toLowerCase() + ':' + src.apiName.toLowerCase());
            }
        }

        for (DeploymentComponent tgt : targetComponents) {
            String key = tgt.componentType.toLowerCase() + ':' + tgt.apiName.toLowerCase();
            if (!sourceKeys.contains(key)) {
                DeploymentComponent dc = new DeploymentComponent();
                dc.apiName       = tgt.apiName;
                dc.componentType = tgt.componentType;
                dc.isDestructive = true;
                destructive.add(dc);
            }
        }
        return destructive;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. SFDX / UNLOCKED PACKAGE CLASSIFIER
    //
    // Interview Q: "When do you use unlocked packages vs org development model?"
    //
    // Unlocked Package  → independent versioning, dependency management, CI/CD friendly
    // 2GP Managed Pkg   → ISV / AppExchange, namespace, subscriber upgrades
    // Org Dev Model     → simple orgs, no package discipline needed, scratch org scripts
    //
    // Classifier helps architects make the right call for a given component type.
    // ═══════════════════════════════════════════════════════════════════════════

    public enum PackageModel {
        UNLOCKED_PACKAGE,
        MANAGED_2GP,
        ORG_DEV_MODEL
    }

    public static PackageModel classifyPackageModel(
        Boolean isIsv,
        Boolean requiresNamespace,
        Boolean multipleSubscribers,
        Boolean ciCdRequired,
        Boolean singleOrg
    ) {
        if (isIsv || requiresNamespace || multipleSubscribers) return PackageModel.MANAGED_2GP;
        if (ciCdRequired || !singleOrg)                        return PackageModel.UNLOCKED_PACKAGE;
        return PackageModel.ORG_DEV_MODEL;
    }

    public static String explainPackageChoice(PackageModel model) {
        Map<PackageModel, String> explanations = new Map<PackageModel, String>{
            PackageModel.UNLOCKED_PACKAGE =>
                'Unlocked Package: version-controlled, CI/CD deployable, '
                + 'dependency graph enforced. Use for modular org development '
                + 'across multiple sandboxes/scratch orgs.',
            PackageModel.MANAGED_2GP =>
                '2nd-Gen Managed Package: namespace, subscriber upgrade path, '
                + 'AppExchange listable. Required for ISV products. '
                + 'Adds compile-time namespace constraints.',
            PackageModel.ORG_DEV_MODEL =>
                'Org Development Model: no packaging overhead. '
                + 'Suitable for single-org, admin-owned customisations. '
                + 'Use scratch org scripts for environment parity.'
        };
        return explanations.get(model);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. CI/CD GATE LOGIC
    //
    // Interview Q: "How do you implement a deployment gate in a CI/CD pipeline?"
    //
    // Three outcomes:
    //   PASS  — coverage ≥ target, no blockers, no destructive
    //   WARN  — coverage ≥ minimum but below target, OR minor destructive changes
    //   FAIL  — coverage < minimum, OR critical blockers, OR > 5 destructive
    // ═══════════════════════════════════════════════════════════════════════════

    public enum CiGateOutcome { PASS, WARN, FAIL }

    public static CiGateOutcome evaluateCiGate(DeploymentReadinessResult readiness) {
        if (readiness == null) return CiGateOutcome.FAIL;
        if (!readiness.blockers.isEmpty()) return CiGateOutcome.FAIL;
        if (readiness.estimatedCoveragePct != null
            && readiness.estimatedCoveragePct < MINIMUM_COVERAGE_PCT) {
            return CiGateOutcome.FAIL;
        }
        if (!readiness.warnings.isEmpty()
            || (readiness.estimatedCoveragePct != null
                && readiness.estimatedCoveragePct < TARGET_COVERAGE_PCT)) {
            return CiGateOutcome.WARN;
        }
        return CiGateOutcome.PASS;
    }

    public static String formatCiGateSummary(
        CiGateOutcome outcome, DeploymentReadinessResult readiness
    ) {
        String icon = outcome == CiGateOutcome.PASS ? '✅'
                    : outcome == CiGateOutcome.WARN ? '⚠️'
                    : '❌';
        String lines = icon + ' CI Gate: ' + outcome.name() + '\n';
        if (readiness != null) {
            lines += '  Components : ' + readiness.totalComponents + '\n';
            lines += '  Apex Classes: ' + readiness.apexClassCount + '\n';
            lines += '  Coverage   : '
                + (readiness.estimatedCoveragePct != null
                    ? readiness.estimatedCoveragePct.setScale(1) + '%'
                    : 'N/A') + '\n';
            for (String b : readiness.blockers)  lines += '  BLOCKER: ' + b + '\n';
            for (String w : readiness.warnings)  lines += '  WARNING: ' + w + '\n';
        }
        return lines;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. SANDBOX REFRESH HELPER — post-refresh data scrubbing
    //
    // Interview Q: "What do you do immediately after a full sandbox refresh?"
    //
    // After a full sandbox copy:
    //   1. Disable email deliverability (Setup → Email → Deliverability → No Access)
    //   2. Scrub or mask PII (email addresses, phone numbers, SSNs)
    //   3. Reset integration credentials (Named Credentials, Auth Providers)
    //   4. Disable scheduled jobs that should NOT run in sandbox
    //   5. Update Custom Settings / Custom Metadata for sandbox endpoints
    //
    // Apex can automate steps 2 and 4 via a post-copy script on the Sandbox class.
    // ═══════════════════════════════════════════════════════════════════════════

    public static ScrubResult scrubPersonalDataForSandbox(Integer batchSize) {
        ScrubResult result = new ScrubResult();
        Integer lim = (batchSize != null && batchSize > 0) ? Math.min(batchSize, 200) : 200;
        try {
            List<Contact> contacts = [
                SELECT Id, Email, Phone, MobilePhone
                FROM   Contact
                WHERE  Email != null
                LIMIT  :lim
            ];
            for (Contact c : contacts) {
                // Replace real email with a deterministic sandbox-safe address
                if (String.isNotBlank(c.Email)) {
                    c.Email = 'sandbox+' + c.Id + '@example.invalid';
                }
                if (String.isNotBlank(c.Phone)) {
                    c.Phone = '+15550000000';
                }
                if (String.isNotBlank(c.MobilePhone)) {
                    c.MobilePhone = '+15550000001';
                }
            }
            Database.SaveResult[] srs = Database.update(contacts, false);
            for (Database.SaveResult sr : srs) {
                if (sr.isSuccess()) result.successCount++;
                else                result.failureCount++;
            }
            result.isComplete = (contacts.size() < lim); // no more pages
        } catch (Exception e) {
            result.errorMessage = e.getMessage();
        }
        return result;
    }

    public static Integer deactivateScheduledJobs(Set<String> jobNamesToKeep) {
        List<CronTrigger> jobs = [
            SELECT Id, CronJobDetail.Name, State
            FROM   CronTrigger
            WHERE  State IN ('WAITING', 'ACQUIRED', 'EXECUTING')
        ];
        List<Id> toAbort = new List<Id>();
        for (CronTrigger ct : jobs) {
            String name = ct.CronJobDetail.Name;
            if (jobNamesToKeep == null || !jobNamesToKeep.contains(name)) {
                toAbort.add(ct.Id);
            }
        }
        for (Id jobId : toAbort) {
            try { System.abortJob(jobId); } catch (Exception e) { /* best-effort */ }
        }
        return toAbort.size();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Private helpers
    // ═══════════════════════════════════════════════════════════════════════════

    private static Decimal averageCoverage(List<ApexCoverageResult> results) {
        if (results == null || results.isEmpty()) return 0;
        Decimal total = 0;
        for (ApexCoverageResult r : results) total += r.coveragePct;
        return total / results.size();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class DeploymentComponent {
        public String  apiName;
        public String  componentType;  // ApexClass, ApexTrigger, CustomObject, Flow, etc.
        public Boolean isDestructive;
        public DeploymentComponent() { isDestructive = false; }
        public DeploymentComponent(String n, String t, Boolean d) {
            apiName = n; componentType = t; isDestructive = d;
        }
    }

    public class ApexCoverageResult {
        public String  className;
        public Integer linesCovered;
        public Integer linesUncovered;
        public Decimal coveragePct;
        public Boolean meetsMinimum { get { return coveragePct >= MINIMUM_COVERAGE_PCT; } }
        public Boolean meetsTarget  { get { return coveragePct >= TARGET_COVERAGE_PCT;  } }

        public ApexCoverageResult(String n, Integer covered, Integer uncovered, Decimal pct) {
            className = n; linesCovered = covered; linesUncovered = uncovered; coveragePct = pct;
        }
    }

    public class DeploymentReadinessResult {
        public Boolean              isReady;
        public List<String>         warnings;
        public List<String>         blockers;
        public Integer              totalComponents;
        public Integer              apexClassCount;
        public Integer              triggerCount;
        public Integer              destructiveCount;
        public Decimal              estimatedCoveragePct;
        public List<ApexCoverageResult> coverageResults;
    }

    public class EnvironmentConfig {
        public OrgEnvironment environment;
        public Boolean  externalCalloutsEnabled;
        public Boolean  emailSendsEnabled;
        public Integer  batchChunkSize;
        public Boolean  useStubData;
        public Integer  maxDailyApiCalls;
        public String   namedCredentialSuffix;
        public String   description;
    }

    public class ScrubResult {
        public Integer successCount = 0;
        public Integer failureCount = 0;
        public Boolean isComplete   = false;
        public String  errorMessage;
    }
}
