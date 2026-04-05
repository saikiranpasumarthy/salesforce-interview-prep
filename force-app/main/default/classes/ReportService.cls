/**
 * ReportService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 15 — Analytics API: running reports from Apex (Reports namespace).
 *
 * KEY CLASSES (Reports namespace):
 *  Reports.ReportManager          — entry point; runReport / runAsyncReport
 *  Reports.ReportResults          — returned by synchronous run; contains fact map + metadata
 *  Reports.ReportMetadata         — report structure: columns, filters, groupings
 *  Reports.ReportFactWithDetails  — tabular/detail fact (cast from ReportFact); has getRows()
 *  Reports.ReportFactWithSummaries— summary/matrix fact; has getAggregates()
 *  Reports.ReportDetailRow        — one data row; getDataCells() → List<ReportDataCell>
 *  Reports.ReportDataCell         — one cell; getValue() → Object (String/Decimal/Date/…)
 *  Reports.SummaryValue           — one aggregate cell in a summary fact
 *  Reports.ReportFilter           — runtime filter override; setColumn/Operator/Value
 *  Reports.ReportInstance         — handle for async run; getId() / getStatus() / getReportResults()
 *
 * FACT MAP KEY FORMAT:
 *  Tabular report   → 'T!T'             (one row group, grand total)
 *  Summary report   → '<group>!T'       (group key + grand total suffix)
 *  Matrix report    → '<row>!<col>'     (row group key + column group key)
 *  Grand total row  → always ends with '!T'
 *
 * GOVERNOR LIMITS:
 *  • synchronous runReport: counts toward CPU & heap; max ~2000 rows returned
 *  • asynchronous runAsyncReport: runs in a background thread; use for large reports
 *  • No Apex DML can be called in the same transaction as runReport
 */
public with sharing class ReportService {

    // ─────────────────────────────────────────────────────────────────────────
    // Synchronous runs
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs a tabular or summary report and returns the grand-total aggregate values.
     * Aggregate order matches the report's summary column order.
     *
     * @param reportId  Id of the report (can be 15 or 18 chars)
     * @return          String representations of grand-total summary cells
     */
    public static List<String> getGrandTotalAggregates(Id reportId) {
        // includeDetails=false → summary-only; faster; no row-level data
        Reports.ReportResults results = Reports.ReportManager.runReport(reportId, false);
        Reports.ReportFactWithSummaries grandTotal =
            (Reports.ReportFactWithSummaries) results.getFactMap().get('T!T');

        List<String> values = new List<String>();
        for (Reports.SummaryValue sv : grandTotal.getAggregates()) {
            Object v = sv.getValue();
            values.add(v != null ? String.valueOf(v) : null);
        }
        return values;
    }

    /**
     * Runs a tabular report with row-level detail and returns each row as an
     * ordered list of string cell values.
     *
     * @param reportId  Tabular report Id
     * @return          Rows — each row is a List<String> in column order
     */
    public static List<List<String>> getDetailRows(Id reportId) {
        // includeDetails=true → returns row data (increases heap usage)
        Reports.ReportResults results = Reports.ReportManager.runReport(reportId, true);

        Reports.ReportFactWithDetails fact =
            (Reports.ReportFactWithDetails) results.getFactMap().get('T!T');

        List<List<String>> rows = new List<List<String>>();
        for (Reports.ReportDetailRow row : fact.getRows()) {
            List<String> rowValues = new List<String>();
            for (Reports.ReportDataCell cell : row.getDataCells()) {
                Object v = cell.getValue();
                rowValues.add(v != null ? String.valueOf(v) : null);
            }
            rows.add(rowValues);
        }
        return rows;
    }

    /**
     * Returns the column API names (detail columns) for a report in order.
     * Useful for mapping getDetailRows() indices to field names.
     */
    public static List<String> getColumnNames(Id reportId) {
        Reports.ReportResults results = Reports.ReportManager.runReport(reportId, false);
        return results.getReportMetadata().getDetailColumns();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Runtime filter override
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs a report with an additional runtime filter.
     * The filter is appended to any filters already saved on the report.
     *
     * Common operator strings: 'equals', 'notEqual', 'lessThan', 'greaterThan',
     *   'lessOrEqual', 'greaterOrEqual', 'contains', 'notContain', 'startsWith'
     *
     * @param reportId  Report to run
     * @param column    Column API name to filter on (e.g. 'ACCOUNT_TYPE')
     * @param operator  Filter operator string
     * @param value     Filter value string
     */
    public static Reports.ReportResults runWithFilter(
            Id reportId, String column, String operator, String value) {

        // First run retrieves current metadata; we then add a filter and re-run
        Reports.ReportResults initial  = Reports.ReportManager.runReport(reportId, false);
        Reports.ReportMetadata metadata = initial.getReportMetadata();

        Reports.ReportFilter rf = new Reports.ReportFilter();
        rf.setColumn(column);
        rf.setOperator(operator);
        rf.setValue(value);
        metadata.getReportFilters().add(rf);

        return Reports.ReportManager.runReport(reportId, metadata, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Asynchronous runs
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Submits a report for asynchronous execution (runs in a background thread).
     * Returns the instance Id — poll getAsyncStatus() to check completion.
     *
     * Use for:
     *  • Reports with >2000 rows (async has no row limit)
     *  • Avoiding CPU / heap limits in the current transaction
     */
    public static String runAsync(Id reportId) {
        Reports.ReportInstance instance =
            Reports.ReportManager.runAsyncReport(reportId, false);
        return instance.getId();
    }

    /**
     * Polls the status of a previously submitted async report run.
     *
     * Status values returned by getStatus():
     *   'New'      — submitted but not yet started
     *   'Running'  — actively executing
     *   'Success'  — complete; getReportResults() is populated
     *   'Error'    — failed; check getErrorCode()
     */
    public static AsyncReportStatus getAsyncStatus(Id reportId, String instanceId) {
        Reports.ReportInstance instance =
            Reports.ReportManager.getReportInstance(reportId, instanceId);

        AsyncReportStatus s  = new AsyncReportStatus();
        s.instanceId         = instance.getId();
        s.status             = instance.getStatus();
        s.completionDate     = instance.getCompletionDate();
        s.isComplete         = s.status == 'Success';
        if (s.isComplete) {
            // Only populated when status='Success'
            s.grandTotalAggregates = extractGrandTotal(instance.getReportResults());
        }
        return s;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static List<String> extractGrandTotal(Reports.ReportResults results) {
        if (results == null || results.getFactMap() == null) {
            return new List<String>();
        }
        Reports.ReportFact fact = results.getFactMap().get('T!T');
        if (fact == null || !(fact instanceof Reports.ReportFactWithSummaries)) {
            return new List<String>();
        }
        List<String> values = new List<String>();
        for (Reports.SummaryValue sv :
                ((Reports.ReportFactWithSummaries) fact).getAggregates()) {
            Object v = sv.getValue();
            values.add(v != null ? String.valueOf(v) : null);
        }
        return values;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner result class
    // ─────────────────────────────────────────────────────────────────────────

    public class AsyncReportStatus {
        public String       instanceId;
        public String       status;              // New | Running | Success | Error
        public Datetime     completionDate;
        public Boolean      isComplete;
        public List<String> grandTotalAggregates;
    }
}
