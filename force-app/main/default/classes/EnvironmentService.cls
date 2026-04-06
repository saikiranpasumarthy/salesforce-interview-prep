/**
 * EnvironmentService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 21 — Environment Strategy: detecting and differentiating org types,
 * implementing environment-aware behavior, and managing org-specific config.
 *
 * ENVIRONMENT STRATEGY OVERVIEW:
 * ════════════════════════════════
 * A mature Salesforce org strategy typically has:
 *
 *   Developer Scratch Orgs  →  Integration Sandbox  →  QA/UAT Sandbox
 *          ↓                                                  ↓
 *   Feature branch testing                          Regression + UAT
 *          ↓                                                  ↓
 *   CI Pipeline validates                      Staging Sandbox (Full/Partial copy)
 *                                                             ↓
 *                                              Production  ←  Release candidate
 *
 * SANDBOX TYPES:
 * ══════════════
 * Developer       — free, ~200MB data, 10 per prod org, no data copy
 * Developer Pro   — ~1GB data, limited count, no data copy
 * Partial Copy    — 5GB, subset of production data (sampling rules)
 * Full            — 1:1 production copy, 30-day refresh, most expensive
 *
 * DETECTING ENVIRONMENT IN APEX:
 * ═══════════════════════════════
 * Use the Organization sObject — no custom metadata needed.
 * Combine IsSandbox, OrganizationType, and domain URL for accurate detection.
 */
public with sharing class EnvironmentService {

    // ─────────────────────────────────────────────────────────────────────────
    // Environment enum and type
    // ─────────────────────────────────────────────────────────────────────────

    public enum OrgEnvironment {
        SCRATCH,
        DEVELOPER_SANDBOX,
        PARTIAL_SANDBOX,
        FULL_SANDBOX,
        PRODUCTION
    }

    public class EnvironmentInfo {
        public OrgEnvironment environment;
        public String  orgId;
        public String  orgName;
        public String  orgType;
        public Boolean isSandbox;
        public Boolean isScratch;
        public Boolean isProduction;
        public String  domainUrl;
        public String  instanceName;
        public String  namespace;

        public Boolean isLowerEnvironment() {
            return environment == OrgEnvironment.SCRATCH
                || environment == OrgEnvironment.DEVELOPER_SANDBOX;
        }

        public Boolean allowsDestructiveOperations() {
            // Only allow destructive ops in non-production environments
            return environment != OrgEnvironment.PRODUCTION;
        }

        public override String toString() {
            return 'EnvironmentInfo['
                + environment.name() + ' | '
                + orgName + ' | '
                + instanceName + ']';
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Detection
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Detects the current org's environment type.
     *
     * Detection logic:
     *  1. Scratch orgs: OrganizationType = 'Developer Edition' AND IsSandbox = false
     *     AND domain contains '.scratch.' or TrialExpirationDate is set
     *     Note: Scratch orgs are technically Developer Edition orgs with a trial date
     *  2. Sandboxes: IsSandbox = true
     *     - Full: OrganizationType = 'Enterprise Edition' (most common for Full Copy)
     *     - Developer: OrganizationType = 'Developer Edition'
     *     - Partial: cannot be distinguished from Developer by type alone — use Custom Metadata
     *  3. Production: IsSandbox = false and no trial date
     */
    public static EnvironmentInfo detect() {
        Organization org = [
            SELECT  Id, Name, OrganizationType, IsSandbox,
                    TrialExpirationDate, InstanceName, NamespacePrefix
            FROM    Organization
            LIMIT   1
        ];

        EnvironmentInfo info  = new EnvironmentInfo();
        info.orgId            = org.Id;
        info.orgName          = org.Name;
        info.orgType          = org.OrganizationType;
        info.isSandbox        = org.IsSandbox;
        info.instanceName     = org.InstanceName;
        info.namespace        = org.NamespacePrefix;
        info.domainUrl        = URL.getOrgDomainUrl().toExternalForm();

        if (!org.IsSandbox && org.TrialExpirationDate != null) {
            info.isScratch    = true;
            info.isProduction = false;
            info.environment  = OrgEnvironment.SCRATCH;
        } else if (org.IsSandbox) {
            info.isScratch    = false;
            info.isProduction = false;
            // Distinguish Full sandbox by type — Full Copy is typically Enterprise
            // Developer/Partial are typically Developer Edition
            if (org.OrganizationType == 'Enterprise Edition'
                    || org.OrganizationType == 'Unlimited Edition') {
                info.environment = OrgEnvironment.FULL_SANDBOX;
            } else {
                // Default developer sandbox — Partial Copy cannot be distinguished
                // without Custom Metadata; treat as Developer
                info.environment = OrgEnvironment.DEVELOPER_SANDBOX;
            }
        } else {
            info.isScratch    = false;
            info.isProduction = true;
            info.environment  = OrgEnvironment.PRODUCTION;
        }

        return info;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Environment-aware configuration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns the correct API endpoint URL for the current environment.
     * Uses Custom Metadata Type (Environment_Config__mdt) to store per-env config.
     *
     * CUSTOM METADATA APPROACH (recommended pattern):
     * ══════════════════════════════════════════════════
     * Deploy different Environment_Config__mdt records for each environment.
     * The DeveloperName matches the org's InstanceName or a known label.
     * This avoids hardcoded endpoints and is deployable via package.xml.
     *
     * If no matching record found, falls back to a sensible default.
     */
    public static String getExternalApiEndpoint() {
        EnvironmentInfo env = detect();

        // Look up endpoint from Custom Metadata by environment type
        List<Environment_Config__mdt> configs = [
            SELECT  MasterLabel, Api_Endpoint__c, Is_Active__c
            FROM    Environment_Config__mdt
            WHERE   Environment_Type__c = :env.environment.name()
            AND     Is_Active__c        = true
            LIMIT   1
        ];

        if (!configs.isEmpty() && String.isNotBlank(configs[0].Api_Endpoint__c)) {
            return configs[0].Api_Endpoint__c;
        }

        // Fallback defaults by environment
        switch on env.environment {
            when SCRATCH, DEVELOPER_SANDBOX {
                return 'https://api.sandbox.example.com/v1';
            }
            when FULL_SANDBOX, PARTIAL_SANDBOX {
                return 'https://api.staging.example.com/v1';
            }
            when PRODUCTION {
                return 'https://api.example.com/v1';
            }
            when else {
                return 'https://api.example.com/v1';
            }
        }
    }

    /**
     * Guards against accidental destructive DML in production.
     * Call this before any mass-delete or mass-update in utility scripts.
     */
    public static void assertNotProduction(String operationName) {
        EnvironmentInfo env = detect();
        if (env.isProduction) {
            throw new EnvironmentGuardException(
                'Operation "' + operationName + '" is not allowed in production. '
                + 'Detected: ' + env.toString()
            );
        }
    }

    /**
     * Returns a configuration string appropriate for the current environment.
     * Pattern: Custom Metadata drives behavior rather than if/else hardcoding.
     */
    public static Map<String, String> getEnvironmentConfig() {
        EnvironmentInfo env = detect();
        Map<String, String> config = new Map<String, String>();

        config.put('ENVIRONMENT',    env.environment.name());
        config.put('ORG_ID',         env.orgId);
        config.put('ORG_NAME',       env.orgName);
        config.put('INSTANCE',       env.instanceName);
        config.put('IS_SANDBOX',     String.valueOf(env.isSandbox));
        config.put('IS_PRODUCTION',  String.valueOf(env.isProduction));
        config.put('DOMAIN_URL',     env.domainUrl);

        // Load any Custom Metadata overrides
        for (Environment_Config__mdt cfg : [
            SELECT MasterLabel, Config_Key__c, Config_Value__c
            FROM   Environment_Config__mdt
            WHERE  Environment_Type__c = :env.environment.name()
            AND    Is_Active__c = true
        ]) {
            if (String.isNotBlank(cfg.Config_Key__c)) {
                config.put(cfg.Config_Key__c, cfg.Config_Value__c);
            }
        }
        return config;
    }

    public class EnvironmentGuardException extends Exception {}
}
