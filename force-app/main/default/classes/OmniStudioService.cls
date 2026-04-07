/**
 * Day 35 — OmniStudio Basics: Integration Procedures, DataRaptors, FlexCards
 *
 * OmniStudio components and their Apex integration patterns:
 *
 *  Integration Procedure (IP)
 *    - Serverside orchestration: calls DataRaptors, REST endpoints, Apex
 *    - Invoked from: OmniScript, FlexCard, Apex, REST API
 *    - Key format: {TypeName}_{ProcedureName}  e.g. "Account_GetFinancialSummary"
 *    - Uses Callable interface → no compile-time dependency on omnistudio package
 *
 *  DataRaptor
 *    - Extract: SOQL → JSON output (replaces SOQL in OmniScript / FlexCard)
 *    - Load:    JSON input → DML (replaces Apex DML in OmniScript)
 *    - Turbo Extract: optimised read-only extract with caching
 *    - Transform: reshape/filter JSON data
 *
 *  FlexCard Data Sources (5 types):
 *    1. DataRaptor Extract     — declarative SOQL → JSON
 *    2. Integration Procedure  — orchestrated multi-source data
 *    3. SOQL                   — direct SOQL on FlexCard designer
 *    4. Apex Remote            — @RemoteAction or @AuraEnabled method
 *    5. REST/APEX REST         — external API via Named Credential
 *
 * All OmniStudio calls use the Callable interface — compiles without
 * requiring the omnistudio managed package at deploy time.
 */
public with sharing class OmniStudioService {

    // ─── Constants ───────────────────────────────────────────────────────────
    private static final String OMNISTUDIO_NS   = 'omnistudio';
    private static final String IP_SERVICE_CLS  = 'IntegrationProcedureService';
    private static final String DR_SERVICE_CLS  = 'DRProcessService';

    /**
     * IP key format: {TypeName}_{ProcedureName}
     * e.g. "Account_GetFinancialSummary", "Opportunity_CalculateDiscount"
     * Sub-type suffix is optional: "Account_GetDetails_OSB" (OmniScript Batch)
     */
    public static final String KEY_SEPARATOR = '_';

    // ─── Test injection hooks ─────────────────────────────────────────────────
    @TestVisible static Boolean            useMock      = false;
    @TestVisible static Map<String,Object> mockIpResult = null;
    @TestVisible static Map<String,Object> mockDrResult = null;

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION PROCEDURE — Callable interface
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Call an OmniStudio Integration Procedure from Apex.
     *
     * Pattern: omnistudio.IntegrationProcedureService implements Callable.
     * Using Type.forName + Callable avoids a compile-time dependency on the
     * omnistudio package — the code deploys to orgs without OmniStudio too.
     *
     * @param procedureKey   IP key in "{Type}_{Name}" format
     * @param inputMap       Input parameters map
     * @return               Output map from the IP; contains "error" key on failure
     */
    public static Map<String, Object> callIntegrationProcedure(
        String procedureKey, Map<String, Object> inputMap
    ) {
        if (useMock) {
            return mockIpResult != null ? mockIpResult : new Map<String, Object>();
        }
        if (String.isBlank(procedureKey)) {
            return new Map<String, Object>{ 'error' => 'procedureKey is required' };
        }
        try {
            Type ipType = Type.forName(OMNISTUDIO_NS, IP_SERVICE_CLS);
            if (ipType == null) {
                return new Map<String, Object>{
                    'error' => 'OmniStudio package not installed in this org'
                };
            }
            Object ipInstance = ipType.newInstance();
            if (!(ipInstance instanceof Callable)) {
                return new Map<String, Object>{
                    'error' => 'IntegrationProcedureService does not implement Callable'
                };
            }
            // Callable.call(action, args) — action = procedureKey
            // args map: 'input', 'options', 'output' keys
            Map<String, Object> args = new Map<String, Object>{
                'input'   => inputMap != null ? inputMap : new Map<String, Object>(),
                'options' => new Map<String, Object>{ 'useContinuation' => false },
                'output'  => new Map<String, Object>()
            };
            Object result = ((Callable) ipInstance).call(procedureKey, args);
            return result instanceof Map<String, Object>
                ? (Map<String, Object>) result
                : new Map<String, Object>{ 'result' => result };
        } catch (Exception e) {
            return new Map<String, Object>{ 'error' => e.getMessage() };
        }
    }

    /**
     * Build a standard IP key from type and name components.
     * e.g. buildIpKey('Account', 'GetFinancialSummary') → 'Account_GetFinancialSummary'
     */
    public static String buildIpKey(String typeName, String procedureName) {
        if (String.isBlank(typeName) || String.isBlank(procedureName)) return null;
        return typeName.trim() + KEY_SEPARATOR + procedureName.trim();
    }

    /**
     * Parse a boolean success flag from an IP output map.
     * IP output convention: top-level 'success' Boolean, or absence of 'error'.
     */
    public static Boolean isIpSuccess(Map<String, Object> output) {
        if (output == null) return false;
        if (output.containsKey('error') && output.get('error') != null) return false;
        if (output.containsKey('success')) {
            return Boolean.valueOf(String.valueOf(output.get('success')));
        }
        return true;
    }

    /**
     * Extract a nested value from an IP output using dot-notation path.
     * e.g. getNestedValue(output, 'Account.FinancialSummary.balance')
     */
    public static Object getNestedValue(Map<String, Object> data, String dotPath) {
        if (data == null || String.isBlank(dotPath)) return null;
        List<String> parts = dotPath.split('\\.');
        Object current = data;
        for (String part : parts) {
            if (!(current instanceof Map<String, Object>)) return null;
            current = ((Map<String, Object>) current).get(part);
            if (current == null) return null;
        }
        return current;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DATARAPTOR — Callable interface
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Execute a DataRaptor Extract or Turbo Extract from Apex.
     *
     * DataRaptor type determines the operation:
     *  - 'Extract'       — SOQL → JSON output
     *  - 'TurboExtract'  — optimised read-only SOQL → JSON (cached)
     *  - 'Load'          — JSON → DML (insert/update/upsert/delete)
     *  - 'Transform'     — reshape JSON data
     *
     * @param drName    DataRaptor interface name (Setup API name)
     * @param drType    'Extract', 'TurboExtract', 'Load', or 'Transform'
     * @param inputMap  Input parameters
     */
    public static Map<String, Object> callDataRaptor(
        String drName, String drType, Map<String, Object> inputMap
    ) {
        if (useMock) {
            return mockDrResult != null ? mockDrResult : new Map<String, Object>();
        }
        if (String.isBlank(drName) || String.isBlank(drType)) {
            return new Map<String, Object>{ 'error' => 'drName and drType are required' };
        }
        try {
            Type drType_ = Type.forName(OMNISTUDIO_NS, DR_SERVICE_CLS);
            if (drType_ == null) {
                return new Map<String, Object>{
                    'error' => 'OmniStudio package not installed in this org'
                };
            }
            Object drInstance = drType_.newInstance();
            if (!(drInstance instanceof Callable)) {
                return new Map<String, Object>{ 'error' => 'DRProcessService not Callable' };
            }
            Map<String, Object> args = new Map<String, Object>{
                'input'   => inputMap != null ? inputMap : new Map<String, Object>(),
                'options' => new Map<String, Object>{ 'drName' => drName, 'drType' => drType }
            };
            Object result = ((Callable) drInstance).call(drName, args);
            return result instanceof Map<String, Object>
                ? (Map<String, Object>) result
                : new Map<String, Object>{ 'result' => result };
        } catch (Exception e) {
            return new Map<String, Object>{ 'error' => e.getMessage() };
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FLEXCARD — Apex Remote data source
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Apex Remote method callable from a FlexCard "Apex Remote" data source.
     * The method must be @AuraEnabled for FlexCard to invoke it.
     * Returns a structured payload that FlexCard can bind to card elements.
     *
     * @param recordId  The context record Id (passed by FlexCard automatically)
     * @param params    Additional parameters from FlexCard configuration
     */
    @AuraEnabled(cacheable=true)
    public static FlexCardData getFlexCardData(Id recordId, Map<String, Object> params) {
        FlexCardData data = new FlexCardData();
        if (recordId == null) {
            data.error = 'recordId is required';
            return data;
        }
        try {
            // Determine context object type from recordId prefix
            Schema.SObjectType sobjectType = recordId.getSObjectType();
            String objectName = sobjectType.getDescribe().getName();
            data.recordId   = recordId;
            data.objectName = objectName;

            // Call an IP to fetch enriched data for the FlexCard
            String ipKey = buildIpKey(objectName, 'GetFlexCardData');
            Map<String, Object> ipInput = new Map<String, Object>{
                'recordId' => String.valueOf(recordId)
            };
            if (params != null) ipInput.putAll(params);
            Map<String, Object> ipOutput = callIntegrationProcedure(ipKey, ipInput);
            data.payload  = ipOutput;
            data.isSuccess = isIpSuccess(ipOutput);
        } catch (Exception e) {
            data.error = e.getMessage();
        }
        return data;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OMNISCRIPT UTILITY — Input/Output normalisation
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Flatten a nested OmniScript JSON payload into a single-level map.
     * OmniScript steps wrap their output in step-name keys:
     *   { "Step1": { "field1": "val1" }, "Step2": { "field2": "val2" } }
     * → { "field1": "val1", "field2": "val2" }
     */
    public static Map<String, Object> flattenOmniScriptPayload(Map<String, Object> payload) {
        Map<String, Object> flat = new Map<String, Object>();
        if (payload == null) return flat;
        for (String key : payload.keySet()) {
            Object val = payload.get(key);
            if (val instanceof Map<String, Object>) {
                // Nested step block — merge into flat map
                Map<String, Object> nested = (Map<String, Object>) val;
                for (String nestedKey : nested.keySet()) {
                    flat.put(nestedKey, nested.get(nestedKey));
                }
            } else {
                flat.put(key, val);
            }
        }
        return flat;
    }

    /**
     * Build a standard OmniScript/IP error response map.
     * Convention: { "error": "message", "success": false }
     */
    public static Map<String, Object> buildErrorResponse(String message) {
        return new Map<String, Object>{
            'error'   => message,
            'success' => false
        };
    }

    /**
     * Build a standard OmniScript/IP success response map.
     * Convention: { "success": true, ...data }
     */
    public static Map<String, Object> buildSuccessResponse(Map<String, Object> data) {
        Map<String, Object> resp = new Map<String, Object>{ 'success' => true };
        if (data != null) resp.putAll(data);
        return resp;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class FlexCardData {
        @AuraEnabled public Id                  recordId;
        @AuraEnabled public String              objectName;
        @AuraEnabled public Map<String, Object> payload;
        @AuraEnabled public Boolean             isSuccess = false;
        @AuraEnabled public String              error;
    }
}
