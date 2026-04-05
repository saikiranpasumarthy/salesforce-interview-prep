/**
 * AuditService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 15 — Audit Trail: SetupAuditTrail, Field History Tracking, Event Monitoring.
 *
 * AUDIT MECHANISMS IN SALESFORCE:
 * ════════════════════════════════
 * 1. Setup Audit Trail (SetupAuditTrail object)
 *    • Tracks ALL admin/setup changes (profile edits, field creation, workflow, etc.)
 *    • Retains last 6 months
 *    • Queryable via SOQL in Apex (read-only)
 *    • Also viewable in Setup → Security → View Setup Audit Trail
 *
 * 2. Field History Tracking (e.g. AccountHistory, OpportunityHistory, <Object>__History)
 *    • Tracks changes to specific fields enabled in Object Manager
 *    • Up to 20 fields per standard object; custom objects same limit
 *    • Retains 18 months (standard) or longer with Field Audit Trail add-on
 *    • SOQL queryable: SELECT Field, OldValue, NewValue, CreatedDate FROM AccountHistory
 *
 * 3. Event Monitoring (EventLogFile object — requires Event Monitoring licence)
 *    • Captures user activity: API calls, logins, report runs, page views, Apex executions
 *    • EventLogFile.EventType distinguishes log category
 *    • Log files are CSV; query EventLogFile, then download the log Body
 *    • Retention: 1 day (default) or 30 days with add-on
 *
 * 4. Shield Platform Encryption + Shield Event Monitoring
 *    • Encryption at rest for fields; Event Monitoring with real-time streaming
 */
public with sharing class AuditService {

    // ─────────────────────────────────────────────────────────────────────────
    // Setup Audit Trail
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns the most recent setup/admin changes from the Setup Audit Trail.
     * Useful for compliance reporting, change-management audits, and incident response.
     *
     * SECTIONS (common values):
     *   'CustomField', 'ValidationRule', 'WorkflowRule', 'ApexClass',
     *   'UserManagement', 'ProfilesAndPermsets', 'SecurityAndSharing'
     */
    public static List<AuditEntry> getRecentSetupChanges(Integer limitCount) {
        List<SetupAuditTrail> trail = [
            SELECT Action, Section, Display, CreatedDate, CreatedBy.Name, CreatedBy.Username
            FROM   SetupAuditTrail
            ORDER  BY CreatedDate DESC
            LIMIT  :limitCount
        ];

        List<AuditEntry> entries = new List<AuditEntry>();
        for (SetupAuditTrail t : trail) {
            AuditEntry e   = new AuditEntry();
            e.action       = t.Action;
            e.section      = t.Section;
            e.description  = t.Display;        // human-readable change description
            e.changedAt    = t.CreatedDate;
            e.changedBy    = t.CreatedBy.Name;
            e.changedByUsername = t.CreatedBy.Username;
            entries.add(e);
        }
        return entries;
    }

    /**
     * Returns setup changes filtered to a specific section.
     * E.g. section='CustomField' shows all field create/edit/delete events.
     */
    public static List<AuditEntry> getSetupChangesBySection(String section, Integer limitCount) {
        List<SetupAuditTrail> trail = [
            SELECT Action, Section, Display, CreatedDate, CreatedBy.Name
            FROM   SetupAuditTrail
            WHERE  Section = :section
            ORDER  BY CreatedDate DESC
            LIMIT  :limitCount
        ];

        List<AuditEntry> entries = new List<AuditEntry>();
        for (SetupAuditTrail t : trail) {
            AuditEntry e  = new AuditEntry();
            e.action      = t.Action;
            e.section     = t.Section;
            e.description = t.Display;
            e.changedAt   = t.CreatedDate;
            e.changedBy   = t.CreatedBy.Name;
            entries.add(e);
        }
        return entries;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Field History Tracking — standard objects
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns field history for a single Account record.
     *
     * FIELD HISTORY NOTES:
     *  • 'created' appears as Field when the record is first inserted (pseudo-entry)
     *  • OldValue / NewValue are polymorphic: cast to the actual field type as needed
     *  • Relationship fields store the Id, not the Name
     */
    public static List<FieldChange> getAccountFieldHistory(Id accountId) {
        List<AccountHistory> history = [
            SELECT Field, OldValue, NewValue, CreatedDate,
                   CreatedBy.Name, CreatedBy.Username
            FROM   AccountHistory
            WHERE  AccountId = :accountId
            AND    Field     != 'created'   -- exclude the synthetic insert entry
            ORDER  BY CreatedDate DESC
            LIMIT  200
        ];

        List<FieldChange> changes = new List<FieldChange>();
        for (AccountHistory h : history) {
            FieldChange fc   = new FieldChange();
            fc.fieldName     = h.Field;
            fc.oldValue      = h.OldValue  != null ? String.valueOf(h.OldValue)  : null;
            fc.newValue      = h.NewValue  != null ? String.valueOf(h.NewValue)  : null;
            fc.changedAt     = h.CreatedDate;
            fc.changedBy     = h.CreatedBy.Name;
            changes.add(fc);
        }
        return changes;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Field History Tracking — generic (any history-enabled object)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns field history for any history-enabled SObject using dynamic SOQL.
     *
     * Naming convention:
     *   Standard objects:  AccountHistory, ContactHistory, OpportunityHistory, …
     *   Custom objects:    Project__History  (replace __c with __History)
     *   Custom objects:    Project_Task__History
     *
     * @param objectApiName  e.g. 'Account', 'Project__c', 'Project_Task__c'
     * @param recordId       Id of the record to get history for
     */
    public static List<FieldChange> getFieldHistory(String objectApiName, Id recordId) {
        String historyObject;
        String parentField;

        if (objectApiName.endsWith('__c')) {
            // Custom object: Project__c → Project__History; Project_Task__c → Project_Task__History
            historyObject = objectApiName.replace('__c', '__History');
            parentField   = 'ParentId';
        } else {
            // Standard object: Account → AccountHistory; parentField = AccountId
            historyObject = objectApiName + 'History';
            parentField   = objectApiName + 'Id';
        }

        String soql = 'SELECT ' + parentField + ', Field, OldValue, NewValue, '
                    + 'CreatedDate, CreatedById '
                    + 'FROM '  + historyObject  + ' '
                    + 'WHERE ' + parentField    + ' = :recordId '
                    + 'ORDER BY CreatedDate DESC LIMIT 200';

        List<SObject> rawHistory = Database.query(soql);

        List<FieldChange> changes = new List<FieldChange>();
        for (SObject h : rawHistory) {
            FieldChange fc  = new FieldChange();
            fc.fieldName    = (String)   h.get('Field');
            Object ov       = h.get('OldValue');
            Object nv       = h.get('NewValue');
            fc.oldValue     = ov != null ? String.valueOf(ov) : null;
            fc.newValue     = nv != null ? String.valueOf(nv) : null;
            fc.changedAt    = (Datetime) h.get('CreatedDate');
            changes.add(fc);
        }
        return changes;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Event Monitoring summary (EventLogFile — requires licence)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns event log file metadata for a given event type and date.
     * Actual log content is in EventLogFile.LogFile (Blob) and must be downloaded
     * separately (the file can be MBs and cannot be read entirely in heap).
     *
     * Common EventType values:
     *   'ApexExecution', 'ApexCallout', 'API', 'Login', 'ReportExport',
     *   'VisualforceRequest', 'LightningPageView', 'BulkApi'
     *
     * NOTE: Querying EventLogFile requires the "View Event Log Files" permission
     * and the Event Monitoring add-on. This method will return an empty list in
     * orgs without the licence.
     */
    public static List<EventLogSummary> getEventLogFiles(String eventType, Date logDate) {
        List<EventLogFile> logFiles = [
            SELECT EventType, LogDate, LogFileLength, LogFileName,
                   CreatedDate, Sequence
            FROM   EventLogFile
            WHERE  EventType = :eventType
            AND    LogDate   = :logDate
            ORDER  BY CreatedDate DESC
        ];

        List<EventLogSummary> summaries = new List<EventLogSummary>();
        for (EventLogFile lf : logFiles) {
            EventLogSummary s    = new EventLogSummary();
            s.eventType          = lf.EventType;
            s.logDate            = lf.LogDate;
            s.fileSizeBytes      = lf.LogFileLength;
            s.fileName           = lf.LogFileName;
            s.sequence           = lf.Sequence;
            summaries.add(s);
        }
        return summaries;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner result classes
    // ─────────────────────────────────────────────────────────────────────────

    public class AuditEntry {
        public String   action;
        public String   section;
        public String   description;
        public Datetime changedAt;
        public String   changedBy;
        public String   changedByUsername;
    }

    public class FieldChange {
        public String   fieldName;
        public String   oldValue;
        public String   newValue;
        public Datetime changedAt;
        public String   changedBy;
    }

    public class EventLogSummary {
        public String  eventType;
        public Date    logDate;
        public Long    fileSizeBytes;
        public String  fileName;
        public Integer sequence;
    }
}
