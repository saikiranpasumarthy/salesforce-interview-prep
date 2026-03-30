/**
 * @description @future service for Account record enrichment via external callout.
 *              Demonstrates the canonical @future(callout=true) pattern: enabling
 *              HTTP callouts from a trigger execution context where synchronous
 *              callouts are prohibited by the platform.
 *
 *              Why @future is needed here:
 *                Triggers run in a synchronous DML transaction. The platform prohibits
 *                callouts from within an open DML transaction to prevent uncommitted
 *                data from being visible to external systems. @future defers the callout
 *                to a separate async transaction where no DML transaction is open.
 *
 *              @future limitations (why Queueable replaced it for most use cases):
 *                - Parameters: only primitives and collections of primitives (Set<Id> ✓)
 *                - No chaining: cannot call another @future from within a @future
 *                - No JobId: no AsyncApexJob record created — cannot monitor or cancel
 *                - No complex types: cannot pass SObjects, Maps, or custom types
 *                - Max 50 @future calls per transaction; max 250,000/day per org
 *
 *              Named Credential 'SicCodeService' handles authentication (set up Day 16).
 *              Errors are published via IntegrationErrorLogger → Integration_Error_Log__e.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class AccountFutureService {

    private static final String ENDPOINT_BASE = 'callout:SicCodeService/api/v1/sic-lookup';

    /**
     * @description Asynchronously enriches newly inserted Accounts with SIC codes
     *              looked up from an external data provider by Industry value.
     *              Called from AccountTriggerHandler.afterInsert — only for accounts
     *              where Industry is populated.
     *
     *              @future parameter constraint: Set<Id> is a Set of primitive Ids —
     *              this satisfies the platform requirement. SObjects are NOT allowed.
     *
     * @param accountIds  IDs of newly inserted Accounts to enrich
     */
    @future(callout=true)
    public static void enrichWithSicCode(Set<Id> accountIds) {
        // Fresh SOQL in @future transaction — Trigger.new is not available here
        List<Account> accounts = [
            SELECT Id, Industry
            FROM   Account
            WHERE  Id IN :accountIds
              AND  Industry != null
        ];
        if (accounts.isEmpty()) { return; }

        List<Account> toUpdate = new List<Account>();

        for (Account acc : accounts) {
            String sicCode = fetchSicCodeForIndustry(acc.Industry);
            if (String.isNotBlank(sicCode)) {
                toUpdate.add(new Account(Id = acc.Id, Sic = sicCode));
            }
        }

        if (toUpdate.isEmpty()) { return; }

        List<Database.SaveResult> results = Database.update(toUpdate, false);
        IntegrationErrorLogger.logSaveResults(
            results,
            'AccountFutureService.enrichWithSicCode'
        );
    }

    // ─── Private: Callout Logic ───────────────────────────────────────────────

    /**
     * @description Performs a GET callout to the SIC code service for a given industry.
     *              Returns the SIC code string or null on failure.
     *              Named Credential handles OAuth/Basic auth headers — no credentials here.
     */
    @TestVisible
    private static String fetchSicCodeForIndustry(String industry) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            ENDPOINT_BASE + '?industry=' + EncodingUtil.urlEncode(industry, 'UTF-8')
        );
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(10000);

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException ex) {
            IntegrationErrorLogger.logException(
                'AccountFutureService.fetchSicCodeForIndustry',
                ex,
                null
            );
            return null;
        }

        if (res.getStatusCode() != 200) {
            IntegrationErrorLogger.log(
                'AccountFutureService.fetchSicCodeForIndustry',
                'HTTP ' + res.getStatusCode() + ' | ' + res.getBody(),
                String.valueOf(res.getStatusCode()),
                null
            );
            return null;
        }

        Map<String, Object> body =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) body.get('sicCode');
    }
}
