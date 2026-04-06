/**
 * @description Event Monitoring service — queries EventLogFile to analyse org usage,
 *              detect security anomalies, and surface Shield threat events.
 *
 *              EVENT MONITORING FUNDAMENTALS:
 *
 *              EventLogFile sObject:
 *                - Available via SOQL and REST API (Data API /query endpoint)
 *                - Each record = one log file for one event type on one day
 *                - LogFile field = Blob (CSV content, Base64 in REST response)
 *                - Standard retention: 1 day; Event Monitoring add-on: 30 days
 *                - Required permissions: "API Enabled" + "View Event Log Files"
 *                - Only queryable via API — not visible in standard Salesforce UI
 *
 *              Key event types (EventLogFile.EventType):
 *                Login            — all login attempts (success + failure)
 *                Logout           — session ends
 *                API              — all REST/SOAP API calls
 *                ApexCallout      — outbound HTTP callouts from Apex
 *                ApexExecution    — Apex class/trigger executions
 *                Report           — report runs
 *                ListViewExport   — data exported from list views
 *                ContentDistribution — file sharing events
 *                BulkApi          — Bulk API job activity
 *                WaveChange       — Analytics/Einstein changes
 *
 *              SHIELD THREAT DETECTION sObjects (add-on required):
 *                CredentialStuffingEventStore — high login failure rate by IP/user
 *                ReportAnomalyEventStore      — abnormal report export volume
 *                SessionHijackingEventStore   — session fingerprint mismatch
 *                ApiAnomalyEventStore         — abnormal API call patterns
 *                These are queryable standard sObjects — NOT platform events.
 *
 *              TRANSACTION SECURITY POLICIES:
 *                Apex-based conditions that evaluate actions in real time:
 *                - Implement TxnSecurity.PolicyCondition interface
 *                - evaluate(TxnSecurity.Event event) → Boolean (true = block)
 *                - Policies defined in Setup → Transaction Security → Policy
 *                - Actions: Block, Notify admin, Log to EventLogFile, End Session
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class EventMonitoringService {

    @TestVisible static final String API_VERSION = '63.0';

    // ─── EventLogFile queries ─────────────────────────────────────────────────

    /**
     * Returns EventLogFile records for a given event type and date.
     * In a standard org (no add-on), logs are retained for 24 hours only.
     * With Event Monitoring add-on: 30-day retention.
     *
     * @param eventType  Value for EventLogFile.EventType (e.g. 'Login', 'API')
     * @param logDate    The date to retrieve log files for
     */
    public static List<EventLogFile> getEventLogFiles(String eventType, Date logDate) {
        DateTime startDt = DateTime.newInstance(logDate,          Time.newInstance(0, 0, 0, 0));
        DateTime endDt   = DateTime.newInstance(logDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        return [
            SELECT Id, EventType, LogDate, LogFileLength, LogFile
            FROM   EventLogFile
            WHERE  EventType = :eventType
              AND  LogDate   >= :startDt
              AND  LogDate   <  :endDt
            ORDER BY LogDate DESC
        ];
    }

    /**
     * Returns a summary of all event types logged on a given date.
     * Useful for discovering which event types are active in this org.
     *
     * @param logDate  Date to summarise
     * @return         Map of EventType → file count
     */
    public static Map<String, Integer> getEventTypeSummary(Date logDate) {
        DateTime startDt = DateTime.newInstance(logDate,          Time.newInstance(0, 0, 0, 0));
        DateTime endDt   = DateTime.newInstance(logDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        Map<String, Integer> summary = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT EventType, COUNT(Id) cnt
            FROM   EventLogFile
            WHERE  LogDate >= :startDt
              AND  LogDate <  :endDt
            GROUP BY EventType
            ORDER BY COUNT(Id) DESC
        ]) {
            summary.put((String) ar.get('EventType'), (Integer) ar.get('cnt'));
        }
        return summary;
    }

    // ─── CSV log parsing ──────────────────────────────────────────────────────

    /**
     * Parses the CSV content from an EventLogFile.LogFile Blob.
     *
     * EventLogFile CSV structure:
     *   Row 0: column headers (comma-separated)
     *   Row 1+: one event per row
     *
     * Limitations of this parser:
     *   - Does not handle quoted fields containing commas (simple CSV split)
     *   - For production use on complex CSVs, use a proper RFC 4180 parser
     *
     * @param logFile  Blob from EventLogFile.LogFile
     * @return         List of maps (column header → cell value) per event row
     */
    public static List<Map<String, String>> parseLogFile(Blob logFile) {
        List<Map<String, String>> events = new List<Map<String, String>>();
        if (logFile == null) { return events; }

        List<String> lines   = logFile.toString().split('\n');
        if (lines.isEmpty()) { return events; }

        List<String> headers = lines[0].replace('\r', '').split(',');

        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i].replace('\r', '');
            if (String.isBlank(line)) { continue; }
            List<String> values       = line.split(',');
            Map<String, String> event = new Map<String, String>();
            for (Integer j = 0; j < headers.size(); j++) {
                event.put(headers[j], j < values.size() ? values[j] : '');
            }
            events.add(event);
        }
        return events;
    }

    // ─── Security analytics ───────────────────────────────────────────────────

    /**
     * Detects high-frequency login events per user — a credential stuffing indicator.
     * Credential stuffing: automated attack using leaked username/password lists.
     *
     * Interview: how to detect in Salesforce:
     *   1. Event Monitoring: query Login EventLogFile, count LOGIN_STATUS != 'LOGIN_NO_ERROR'
     *   2. Shield Threat Detection: CredentialStuffingEventStore (ML-based, more accurate)
     *   3. Transaction Security Policy: block login from unknown IP ranges
     *
     * @param logDate    Date to analyse
     * @param threshold  Flag users with >= this many login events
     * @return           Map of Username → login count (only users >= threshold)
     */
    public static Map<String, Integer> detectHighFrequencyLogins(
            Date logDate, Integer threshold) {
        Map<String, Integer> counts = new Map<String, Integer>();

        for (EventLogFile elf : getEventLogFiles('Login', logDate)) {
            for (Map<String, String> event : parseLogFile(elf.LogFile)) {
                String username = event.get('USERNAME');
                if (String.isBlank(username)) { continue; }
                counts.put(username, (counts.get(username) ?? 0) + 1);
            }
        }

        Map<String, Integer> flagged = new Map<String, Integer>();
        for (String user : counts.keySet()) {
            if (counts.get(user) >= threshold) { flagged.put(user, counts.get(user)); }
        }
        return flagged;
    }

    /**
     * Detects users who exported large amounts of data via reports or list views.
     * Abnormal export volume may indicate data exfiltration.
     *
     * @param logDate    Date to analyse
     * @param threshold  Flag users with >= this many export events
     * @return           Map of Username → export event count
     */
    public static Map<String, Integer> detectLargeDataExports(
            Date logDate, Integer threshold) {
        Map<String, Integer> counts = new Map<String, Integer>();

        for (String eventType : new List<String>{ 'Report', 'ListViewExport' }) {
            for (EventLogFile elf : getEventLogFiles(eventType, logDate)) {
                for (Map<String, String> event : parseLogFile(elf.LogFile)) {
                    String username = event.get('USER_NAME');
                    if (String.isBlank(username)) {
                        username = event.get('USERNAME');
                    }
                    if (String.isBlank(username)) { continue; }
                    counts.put(username, (counts.get(username) ?? 0) + 1);
                }
            }
        }

        Map<String, Integer> flagged = new Map<String, Integer>();
        for (String user : counts.keySet()) {
            if (counts.get(user) >= threshold) { flagged.put(user, counts.get(user)); }
        }
        return flagged;
    }

    /**
     * Queries Shield Threat Detection CredentialStuffingEventStore.
     * Returns empty list gracefully if the object is not available in this org.
     *
     * Requires: Shield Threat Detection add-on.
     * Fields: Username, SourceIp, Score (0–100, higher = more suspicious), EventDate.
     *
     * @param lookbackDays  Number of days back to query
     * @return              Threat event records ordered by Score descending
     */
    public static List<SObject> getCredentialStuffingEvents(Integer lookbackDays) {
        DateTime since = DateTime.now().addDays(-(lookbackDays != null ? lookbackDays : 7));
        try {
            return Database.query(
                'SELECT Username, SourceIp, Score, EventDate '
                + 'FROM CredentialStuffingEventStore '
                + 'WHERE EventDate >= :since '
                + 'ORDER BY Score DESC LIMIT 200'
            );
        } catch (System.QueryException e) {
            // Object not available — org does not have Shield Threat Detection
            return new List<SObject>();
        }
    }

    /**
     * Builds a security summary report for a given date:
     *   - total login events, total export events, event type inventory
     * Useful as input to a monitoring dashboard or daily email alert.
     *
     * @param reportDate  Date to summarise
     * @return            SecuritySummary with aggregated metrics
     */
    public static SecuritySummary buildDailySummary(Date reportDate) {
        SecuritySummary summary = new SecuritySummary();
        summary.reportDate       = reportDate;
        summary.eventTypeCounts  = getEventTypeSummary(reportDate);
        summary.totalEvents      = 0;
        for (Integer cnt : summary.eventTypeCounts.values()) {
            summary.totalEvents += cnt;
        }
        summary.highFrequencyLogins = detectHighFrequencyLogins(reportDate, 10);
        summary.largeDataExports    = detectLargeDataExports(reportDate, 5);
        return summary;
    }

    // ─── Result types ─────────────────────────────────────────────────────────

    public class SecuritySummary {
        public Date                    reportDate;
        public Map<String, Integer>    eventTypeCounts;
        public Integer                 totalEvents;
        public Map<String, Integer>    highFrequencyLogins;
        public Map<String, Integer>    largeDataExports;
    }
}
