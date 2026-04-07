/**
 * Day 38 — Mock Interview Day 2: Clouds + DevOps + Design
 *
 * Production patterns for common Cloud-focused interview coding challenges:
 *
 *  1. Omni-Channel routing    — PendingServiceRouting with queue resolution
 *  2. Manual Sharing          — dynamic {Object}Share creation
 *  3. Sharing model info      — OWD introspection via describe
 *  4. Change Data Capture     — CDC event header parsing
 *  5. Automation classifier   — Flow vs Apex vs Batch decision logic
 *  6. Config type classifier  — Custom Metadata vs Custom Settings decision
 *  7. Large Data Volume guard — chunked query with OFFSET safety check
 */
public with sharing class MockInterviewCloudsService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. OMNI-CHANNEL — PendingServiceRouting
    //
    // Interview Q: "How do you programmatically route a work item in Omni-Channel?"
    //
    // PendingServiceRouting (PSR) is the Apex API for Omni-Channel routing.
    // Insert a PSR record → Omni-Channel engine assigns the item to an available agent.
    //
    // RoutingType options:
    //   'QueueBased'  — route to any available agent in the queue
    //   'SkillsBased' — route to agent with matching skills (requires setup)
    // ═══════════════════════════════════════════════════════════════════════════

    public static RoutingResult routeWorkItemToOmniChannel(
        Id workItemId, String queueDevName, Integer capacityWeight
    ) {
        if (workItemId == null) {
            return new RoutingResult(null, false, 'workItemId is required');
        }
        if (String.isBlank(queueDevName)) {
            return new RoutingResult(null, false, 'queueDevName is required');
        }
        try {
            List<Group> queues = [
                SELECT Id FROM Group
                WHERE  DeveloperName = :queueDevName
                AND    Type = 'Queue'
                LIMIT  1
            ];
            if (queues.isEmpty()) {
                return new RoutingResult(null, false, 'Queue not found: ' + queueDevName);
            }
            PendingServiceRouting psr = new PendingServiceRouting(
                WorkItemId        = workItemId,
                RoutingType       = 'QueueBased',
                CapacityWeight    = capacityWeight != null ? capacityWeight : 1,
                IsReadyForRouting = true
            );
            insert psr;
            return new RoutingResult(psr.Id, true, null);
        } catch (Exception e) {
            return new RoutingResult(null, false, e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. MANUAL SHARING — dynamic {Object}Share insertion
    //
    // Interview Q: "How do you implement Apex-managed sharing?"
    //
    // Rules:
    //  - Only works on objects with OWD = Private or Public Read Only
    //  - Share object is named {SObjectName}Share (e.g. AccountShare, Case__Share)
    //  - AccessLevel: 'Read' | 'Edit' | 'All' (All = Full Access on custom objects)
    //  - RowCause: 'Manual' for ad-hoc; custom Apex sharing reason for programmatic
    //  - To use custom sharing reason: Setup → Object → Apex Sharing Reasons → New
    // ═══════════════════════════════════════════════════════════════════════════

    public static SharingResult createManualShare(
        Id recordId, Id userOrGroupId, String accessLevel, String rowCause
    ) {
        if (recordId == null)     return new SharingResult(null, false, 'recordId is required');
        if (userOrGroupId == null) return new SharingResult(null, false, 'userOrGroupId is required');

        Set<String> validAccess = new Set<String>{ 'Read', 'Edit', 'All' };
        if (!validAccess.contains(accessLevel)) {
            return new SharingResult(null, false, 'accessLevel must be Read, Edit, or All');
        }

        try {
            String objectName  = recordId.getSObjectType().getDescribe().getName();
            // Standard objects: AccountShare, CaseShare, etc.
            // Custom objects:   MyObject__Share  (note double underscore before Share)
            String shareObject = objectName.endsWith('__c')
                ? objectName.removeEnd('__c') + '__Share'
                : objectName + 'Share';

            SObject shareRecord = Schema.getGlobalDescribe().get(shareObject)?.newSObject();
            if (shareRecord == null) {
                return new SharingResult(null, false, 'Share object not found: ' + shareObject);
            }

            // Standard object share field is {ObjectName}Id; custom is ParentId
            String idField = objectName.endsWith('__c') ? 'ParentId' : objectName + 'Id';
            shareRecord.put(idField,         recordId);
            shareRecord.put('UserOrGroupId', userOrGroupId);
            shareRecord.put('AccessLevel',   accessLevel);
            shareRecord.put('RowCause',      String.isNotBlank(rowCause) ? rowCause : 'Manual');
            insert shareRecord;
            return new SharingResult((Id) shareRecord.get('Id'), true, null);
        } catch (Exception e) {
            return new SharingResult(null, false, e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. SHARING MODEL INTROSPECTION
    //
    // Interview Q: "Explain OWD, Role Hierarchy, and Sharing Rules."
    //
    // OWD (Org-Wide Default): the baseline — Private / Public Read Only / Public Read Write
    // Role Hierarchy: opens access UP the hierarchy from OWD
    // Sharing Rules: extend access horizontally (criteria-based or ownership-based)
    // Manual Sharing: one-off record-level grants
    // Apex Sharing: programmatic, uses {Object}Share object
    // ═══════════════════════════════════════════════════════════════════════════

    public static SharingModelInfo getSharingModelInfo(Schema.SObjectType sobjType) {
        if (sobjType == null) return null;
        Schema.DescribeSObjectResult d = sobjType.getDescribe();
        return new SharingModelInfo(
            d.getName(),
            String.valueOf(d.getSharingModel()),  // e.g. 'Private', 'Read', 'ReadWrite'
            d.isCreateable(),
            d.isUpdateable(),
            d.isDeletable(),
            d.isQueryable()
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. CHANGE DATA CAPTURE — event header parsing
    //
    // Interview Q: "What is Change Data Capture and how do you use it in Apex?"
    //
    // CDC streams change events from the event bus. Each event has a
    // ChangeEventHeader compound field with:
    //   changeType    — CREATE | UPDATE | DELETE | UNDELETE
    //   entityName    — API name of the changed object
    //   recordIds     — list of affected record Ids
    //   changedFields — only for UPDATE events; list of modified field names
    //
    // Subscribe via: Platform Event Trigger or CometD (external consumers)
    // ═══════════════════════════════════════════════════════════════════════════

    public static List<CdcEventSummary> parseCdcEvents(List<SObject> cdcEvents) {
        List<CdcEventSummary> summaries = new List<CdcEventSummary>();
        if (cdcEvents == null) return summaries;
        for (SObject evt : cdcEvents) {
            try {
                Object headerObj = evt.get('ChangeEventHeader');
                if (!(headerObj instanceof Map<String, Object>)) continue;
                Map<String, Object> h = (Map<String, Object>) headerObj;

                summaries.add(new CdcEventSummary(
                    (String)       h.get('changeType'),
                    (String)       h.get('entityName'),
                    (List<Object>) h.get('recordIds'),
                    (List<Object>) h.get('changedFields')
                ));
            } catch (Exception e) {
                // Not a CDC event or malformed header — skip
            }
        }
        return summaries;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. AUTOMATION TOOL SELECTION
    //
    // Interview Q: "When do you use Flow vs Apex trigger vs Process Builder?"
    //
    // Decision priority (most to least preferred for NEW automation):
    //   Flow (if admin-maintainable, no callout, < 2000 records)
    //   Apex Trigger (complex logic, callouts, performance-critical)
    //   Batch Apex (> 2000 records, scheduled large-scale)
    //   Process Builder — LEGACY, migrate to Flow
    // ═══════════════════════════════════════════════════════════════════════════

    public enum AutomationTool { FLOW, APEX_TRIGGER, APEX_BATCH, PROCESS_BUILDER_LEGACY }

    public static AutomationTool classifyAutomationTool(
        Boolean requiresComplexLogic,
        Boolean requiresCallout,
        Boolean requiresBulkProcessing,
        Boolean isAdminMaintainable,
        Integer recordCount
    ) {
        if (recordCount != null && recordCount > 2000) return AutomationTool.APEX_BATCH;
        if (requiresCallout || requiresComplexLogic)   return AutomationTool.APEX_TRIGGER;
        if (isAdminMaintainable != null && isAdminMaintainable) return AutomationTool.FLOW;
        return AutomationTool.FLOW;
    }

    public static String explainAutomationChoice(AutomationTool tool) {
        Map<AutomationTool, String> explanations = new Map<AutomationTool, String>{
            AutomationTool.FLOW =>
                'Flow: declarative, admin-maintainable, no callouts. '
                + 'Preferred for new automation. Screen Flows for UI, '
                + 'Record-Triggered Flows replace most Workflow Rules.',
            AutomationTool.APEX_TRIGGER =>
                'Apex Trigger: complex business logic, HTTP callouts, '
                + 'recursion control, performance-critical bulkification. '
                + 'Use TriggerHandlerBase framework.',
            AutomationTool.APEX_BATCH =>
                'Batch Apex: > 2000 records, scheduled processing, '
                + 'large-scale DML or callouts. Implements Database.Batchable.',
            AutomationTool.PROCESS_BUILDER_LEGACY =>
                'Process Builder is legacy — plan migration to Flow. '
                + 'Do not build new automation in Process Builder.'
        };
        return explanations.get(tool);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. CUSTOM METADATA vs CUSTOM SETTINGS
    //
    // Interview Q: "When would you use Custom Metadata vs Custom Settings?"
    //
    // Custom Metadata Type:
    //   + Deployable via change set / SFDX — travels with code
    //   + Packageable in managed packages
    //   + No DML governor limits (read via SOQL, no DML count)
    //   - No user/profile hierarchy
    //   - Cannot be updated at runtime without DML (use Metadata API or SFDX)
    //
    // Custom Setting (Hierarchy):
    //   + User → Profile → Org override chain
    //   + Fast access via .getInstance() — no SOQL query
    //   - NOT deployable via standard SFDX deploy (use force:source:deploy workaround)
    //   - Counts against DML limits when updated
    // ═══════════════════════════════════════════════════════════════════════════

    public enum ConfigurationType {
        CUSTOM_METADATA_TYPE,
        CUSTOM_SETTING_HIERARCHY,
        CUSTOM_SETTING_LIST
    }

    public static ConfigurationType classifyConfigurationType(
        Boolean needsDeploymentWithCode,
        Boolean isEnvironmentSpecific,
        Boolean isUserOrProfileSpecific
    ) {
        if (isUserOrProfileSpecific)     return ConfigurationType.CUSTOM_SETTING_HIERARCHY;
        if (needsDeploymentWithCode)     return ConfigurationType.CUSTOM_METADATA_TYPE;
        if (isEnvironmentSpecific)       return ConfigurationType.CUSTOM_SETTING_HIERARCHY;
        return ConfigurationType.CUSTOM_METADATA_TYPE;
    }

    public static String explainConfigChoice(ConfigurationType type) {
        Map<ConfigurationType, String> explanations = new Map<ConfigurationType, String>{
            ConfigurationType.CUSTOM_METADATA_TYPE =>
                'Custom Metadata: deployable, packageable, no DML limits. '
                + 'Use for config that travels with code (endpoint URLs, thresholds, feature flags).',
            ConfigurationType.CUSTOM_SETTING_HIERARCHY =>
                'Hierarchy Custom Setting: org/profile/user override via getInstance(). '
                + 'Use for user-specific or environment-specific config. '
                + 'Deploy records separately from metadata.',
            ConfigurationType.CUSTOM_SETTING_LIST =>
                'List Custom Setting: named key-value store. '
                + 'Use for lookup tables or feature flags without hierarchy needs.'
        };
        return explanations.get(type);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. LARGE DATA VOLUME — safe chunked query
    //
    // Interview Q: "How do you handle queries on tables with millions of records?"
    //
    // Techniques:
    //   - Index filters (Id, CreatedDate, ExternalId__c) in WHERE clause
    //   - LIMIT + OFFSET for pagination (max OFFSET = 2000 — use lastId cursor instead)
    //   - LastModifiedDate >= :checkpoint for incremental processing
    //   - Skinny tables (contact Support) for high-frequency read objects
    //   - Batch Apex for large-scale processing
    //   - Avoid SELECT * — specify only needed fields
    // ═══════════════════════════════════════════════════════════════════════════

    public static List<Account> queryAccountsWithCursorPagination(
        Id lastId, Integer pageSize
    ) {
        // Cursor-based pagination — avoids OFFSET limit of 2000
        // lastId = null → first page; otherwise continue from last seen Id
        Integer lim = (pageSize != null && pageSize > 0) ? Math.min(pageSize, 200) : 200;

        if (lastId == null) {
            return [
                SELECT Id, Name, AnnualRevenue, LastModifiedDate
                FROM   Account
                ORDER  BY Id ASC
                LIMIT  :lim
            ];
        } else {
            return [
                SELECT Id, Name, AnnualRevenue, LastModifiedDate
                FROM   Account
                WHERE  Id > :lastId     // cursor — always indexed
                ORDER  BY Id ASC
                LIMIT  :lim
            ];
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class RoutingResult {
        public Id      psrId;
        public Boolean isSuccess;
        public String  error;
        public RoutingResult(Id id, Boolean s, String e) {
            psrId = id; isSuccess = s; error = e;
        }
    }

    public class SharingResult {
        public Id      shareId;
        public Boolean isSuccess;
        public String  error;
        public SharingResult(Id id, Boolean s, String e) {
            shareId = id; isSuccess = s; error = e;
        }
    }

    public class SharingModelInfo {
        public String  objectName;
        public String  owdSharingModel;  // e.g. 'Private', 'Read', 'ReadWrite'
        public Boolean isCreateable;
        public Boolean isUpdateable;
        public Boolean isDeletable;
        public Boolean isQueryable;

        public SharingModelInfo(String n, String owd, Boolean c, Boolean u, Boolean d, Boolean q) {
            objectName = n; owdSharingModel = owd;
            isCreateable = c; isUpdateable = u; isDeletable = d; isQueryable = q;
        }
    }

    public class CdcEventSummary {
        public String       changeType;
        public String       entityName;
        public List<Object> recordIds;
        public List<Object> changedFields;
        public Boolean isCreate  { get { return 'CREATE'.equals(changeType); } }
        public Boolean isUpdate  { get { return 'UPDATE'.equals(changeType); } }
        public Boolean isDelete  { get { return 'DELETE'.equals(changeType); } }

        public CdcEventSummary(String ct, String en, List<Object> rids, List<Object> cf) {
            changeType = ct; entityName = en; recordIds = rids; changedFields = cf;
        }
    }
}
