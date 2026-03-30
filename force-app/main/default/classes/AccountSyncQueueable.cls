/**
 * @description Queueable job that syncs Account records to an external CRM via REST.
 *              Demonstrates the chaining pattern for processing datasets larger than
 *              a single Queueable execution can handle efficiently.
 *
 *              Chaining pattern:
 *                Job 1 processes Ids[0..99]   → enqueues Job 2
 *                Job 2 processes Ids[100..199] → enqueues Job 3
 *                ...until pendingAccountIds is empty.
 *
 *              Why Queueable over @future for this scenario:
 *                - @future cannot accept SObject lists or complex types — only primitives
 *                - @future does not chain — you cannot fire a follow-up @future from a @future
 *                - Queueable gives you JobId for monitoring, chaining, and error correlation
 *                - Database.AllowsCallouts works cleanly on Queueable; @future supports it
 *                  but has no chaining mechanism for continued processing
 *
 *              Callout setup:
 *                Uses Named Credential "ExternalCRM" for auth (covered Day 16).
 *                Endpoint pattern: callout:<NamedCredential>/<path>
 *
 *              Chaining guard:
 *                Test.isRunningTest() prevents chaining in test context — Salesforce
 *                allows only one level of Queueable chaining in tests. For production
 *                depth control, add a Custom Metadata max-depth config.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-29
 */
public with sharing class AccountSyncQueueable implements Queueable, Database.AllowsCallouts {

    // Callout chunk size — 100 keeps each HTTP body small and avoids 12MB heap ceiling
    @TestVisible private static final Integer CHUNK_SIZE = 100;

    @TestVisible private List<Id>  pendingAccountIds;
    @TestVisible private Integer   totalProcessed;

    // ─── Constructors ─────────────────────────────────────────────────────────

    /** Entry point — call this from triggers, batch finish(), or anonymous Apex */
    public AccountSyncQueueable(List<Id> accountIds) {
        this(accountIds, 0);
    }

    /** Internal chaining constructor — carries running processed count for telemetry */
    @TestVisible
    private AccountSyncQueueable(List<Id> accountIds, Integer totalProcessed) {
        this.pendingAccountIds = accountIds;
        this.totalProcessed    = totalProcessed;
    }

    // ─── Queueable Interface ──────────────────────────────────────────────────

    public void execute(QueueableContext ctx) {
        if (pendingAccountIds == null || pendingAccountIds.isEmpty()) { return; }

        // Partition current chunk vs remainder
        Integer chunkEnd   = Math.min(CHUNK_SIZE, pendingAccountIds.size());
        List<Id> chunk     = new List<Id>();
        List<Id> remaining = new List<Id>();

        for (Integer i = 0; i < pendingAccountIds.size(); i++) {
            if (i < chunkEnd) {
                chunk.add(pendingAccountIds[i]);
            } else {
                remaining.add(pendingAccountIds[i]);
            }
        }

        Integer successCount = calloutSyncChunk(chunk);
        Integer newTotal     = totalProcessed + successCount;

        System.debug(LoggingLevel.INFO,
            'AccountSyncQueueable | JobId: ' + ctx.getJobId()
            + ' | Chunk: '     + chunk.size()
            + ' | Success: '   + successCount
            + ' | TotalSoFar: ' + newTotal
            + ' | Remaining: '  + remaining.size()
        );

        // Chain next job — guard against test context (1-level chain limit in tests)
        if (!remaining.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AccountSyncQueueable(remaining, newTotal));
        }
    }

    // ─── Private: HTTP Callout ────────────────────────────────────────────────

    /**
     * @description Queries accounts for the given IDs and POSTs them to the external
     *              CRM endpoint. Returns count of successfully synced records.
     *              Named Credential handles auth headers — no credentials in code.
     */
    @TestVisible
    private Integer calloutSyncChunk(List<Id> accountIds) {
        // Single SOQL per chunk — not in a loop
        List<Account> accounts = [
            SELECT Id, Name, Phone, BillingStreet, BillingCity,
                   BillingState, BillingPostalCode, BillingCountry, AnnualRevenue, Rating
            FROM   Account
            WHERE  Id IN :accountIds
        ];

        if (accounts.isEmpty()) { return 0; }

        // Serialize payload
        List<Map<String, Object>> payload = new List<Map<String, Object>>();
        for (Account acc : accounts) {
            payload.add(new Map<String, Object>{
                'sfId'          => acc.Id,
                'name'          => acc.Name,
                'phone'         => acc.Phone,
                'annualRevenue' => acc.AnnualRevenue,
                'rating'        => acc.Rating,
                'billingCity'   => acc.BillingCity,
                'billingState'  => acc.BillingState,
                'billingCountry'=> acc.BillingCountry
            });
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:ExternalCRM/api/v1/accounts/bulk-sync');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() == 200 || res.getStatusCode() == 202) {
            return accounts.size();
        }

        System.debug(LoggingLevel.ERROR,
            'AccountSyncQueueable callout failed. '
            + 'HTTP: ' + res.getStatusCode()
            + ' | Body: ' + res.getBody()
        );
        return 0;
    }
}
