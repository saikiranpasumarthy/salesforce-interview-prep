# Day 17 — SOAP Callouts, Outbound Messaging & Callouts from Async Apex

## Overview

Day 17 covers three related integration topics: consuming SOAP services from Apex, receiving Salesforce Outbound Messages, and the async callout patterns needed to work around the DML-callout ordering restriction.

---

## SOAP Callouts

### SOAP vs REST

| | SOAP | REST |
|---|---|---|
| Contract | WSDL (mandatory) | OpenAPI (optional) |
| Format | XML only | JSON, XML, others |
| Security | WS-Security built-in | Bearer token / Basic Auth in headers |
| Standards | WS-ReliableMessaging, WS-Atomic | None built-in |
| Tooling | WSDL2Apex auto-generates stubs | Manual Apex or `HttpRequest` |
| Use case | Enterprise/legacy, ERP, banking | Modern SaaS APIs |

### WSDL2Apex (preferred when WSDL is available)

**Process:**
1. Setup → Apex Classes → Generate from WSDL
2. Upload the WSDL file
3. Salesforce generates:
   - Type classes (DTOs for request/response elements)
   - A stub class (e.g. `AccountServiceStub`)
   - An async stub (for Apex Continuation)

**Usage:**
```apex
AccountServiceStub stub = new AccountServiceStub();
stub.endpoint_x = 'callout:My_Named_Credential';  // override endpoint via NC
stub.timeout_x  = 30000;

AccountService.GetAccountRequest req = new AccountService.GetAccountRequest();
req.accountId = '001000000000001';

AccountService.GetAccountResponse resp = stub.getAccount(req);
System.debug(resp.account.Name);
```

**Limitations:**
- Large/complex WSDLs (>1MB) may fail to generate
- WS-Security (`wsse:UsernameToken`, signing) is not generated — manual envelopes needed
- Generated stubs use `WebServiceCallout.invoke()` internally

### Manual SOAP Envelope (when WSDL2Apex isn't viable)

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:My_Named_Credential/services/AccountService');
req.setMethod('POST');
req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
req.setHeader('SOAPAction', '"getAccount"');   // SOAP 1.1 requires quoted value
req.setTimeout(30000);
req.setBody(soapEnvelope);

HttpResponse resp = new Http().send(req);
```

**SOAP 1.1 Envelope structure:**
```xml
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:tns="http://example.com/AccountService">
  <soap:Header/>
  <soap:Body>
    <tns:getAccount>
      <accountId>001000000000001</accountId>
    </tns:getAccount>
  </soap:Body>
</soap:Envelope>
```

### WS-Security UsernameToken

```xml
<soap:Header>
  <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/...">
    <wsse:UsernameToken>
      <wsse:Username>svcUser</wsse:Username>
      <wsse:Password>secret</wsse:Password>
    </wsse:UsernameToken>
  </wsse:Security>
</soap:Header>
```

Use `SoapApiService.buildEnvelopeWithSecurity()` to build this programmatically.

### SOAP Fault handling

SOAP faults are returned as **HTTP 500** with a `<soap:Fault>` element in the body:

```xml
<soap:Body>
  <soap:Fault>
    <faultcode>soap:Client</faultcode>
    <faultstring>Invalid account Id</faultstring>
    <detail>...</detail>
  </soap:Fault>
</soap:Body>
```

Always check for `<soap:Fault>` even when the HTTP status is 200 (some servers return 200 with faults).

### DOM Parsing with `Dom.Document`

```apex
Dom.Document doc  = new Dom.Document();
doc.load(xmlBody);

Dom.XmlNode root  = doc.getRootElement();  // soap:Envelope
Dom.XmlNode body  = root.getChildElement('Body', 'http://schemas.xmlsoap.org/soap/envelope/');
Dom.XmlNode resp  = body.getChildElement('getAccountResponse', 'http://example.com/ns');

for (Dom.XmlNode child : resp.getChildElements()) {
    System.debug(child.getName() + ' = ' + child.getText());
}
```

**Namespace note:** `getChildElement(name, namespace)` — pass `null` for namespace when elements are in the default namespace inside SOAP 1.1 (Fault children are often not namespace-qualified).

---

## Outbound Messaging

### What it is

A declarative feature where Salesforce pushes data to an external endpoint when a record changes:

```
Record changes → Workflow Rule / Flow fires
              → Salesforce POSTs XML/SOAP to your endpoint
              → Your endpoint processes + returns ACK
              → Salesforce marks delivery complete
              → If no ACK: retries for up to 24 hours
```

### Key characteristics

| Property | Value |
|---|---|
| Protocol | SOAP over HTTP |
| Trigger | Workflow Rule or Flow |
| Delivery guarantee | At-least-once (may duplicate) |
| Retry period | 24 hours |
| Max fields per message | 25 |
| Includes session token | Yes (`<SessionId>`) — for API callbacks |
| Order guaranteed | No |

### Outbound Message envelope (sent by Salesforce)

```xml
<soapenv:Body>
  <notifications xmlns="http://soap.sforce.com/2005/09/outbound">
    <OrganizationId>00D000000000001</OrganizationId>
    <SessionId>your-session-token</SessionId>
    <EnterpriseUrl>https://na1.salesforce.com/services/Soap/c/62.0</EnterpriseUrl>
    <Notification>
      <Id>04l000000000001</Id>
      <sObject xsi:type="sf:Account"
               xmlns:sf="urn:sobject.enterprise.soap.sforce.com">
        <sf:Id>001000000000001</sf:Id>
        <sf:Name>Acme Corp</sf:Name>
      </sObject>
    </Notification>
  </notifications>
</soapenv:Body>
```

### Required ACK response

```xml
<soapenv:Body>
  <notificationsResponse xmlns="http://soap.sforce.com/2005/09/outbound">
    <Ack>true</Ack>   <!-- false triggers retry -->
  </notificationsResponse>
</soapenv:Body>
```

Return `<Ack>false</Ack>` to trigger a retry (e.g. when your downstream system is unavailable). Return HTTP 200 even for `Ack=false`.

### Idempotency

Outbound Messages can be delivered **more than once**. Use the `<Notification><Id>` as a deduplication key:

```apex
// Idempotency check before processing
if (isAlreadyProcessed(notification.notificationId)) { return ackTrue(); }
markProcessed(notification.notificationId);
processRecord(notification);
return ackTrue();
```

### @RestResource endpoint implementation

```apex
@RestResource(urlMapping='/outbound-message/account')
global class OutboundMessageHandler {
    @HttpPost
    global static void handle() {
        String body = RestContext.request.requestBody.toString();
        ParsedNotification n = parseNotification(body);
        processAccountUpdate(n);
        RestContext.response.responseBody = Blob.valueOf(buildAckResponse(true));
        RestContext.response.addHeader('Content-Type', 'text/xml; charset=UTF-8');
    }
}
```

The endpoint is accessible at `https://your-org.salesforce.com/services/apexrest/outbound-message/account`. Register this URL in the Outbound Message configuration.

---

## Callouts from Async Apex

### The core constraint

```apex
insert account;                     // DML
ExternalApiClient.post('/sync', x); // ← CalloutException: uncommitted work pending
```

Callouts cannot follow DML in the same transaction. Solutions:

### Pattern 1 — `@future(callout=true)`

```apex
@future(callout=true)
public static void syncAsync(Id accountId) {
    Account acc = [SELECT Id, Name FROM Account WHERE Id = :accountId];
    ExternalApiClient.post('/accounts', acc);
}
```

**Rules:**
- Method must be `static void`
- Parameters: only primitives or primitive collections — no SObjects, no custom types
- Max 50 `@future` calls per transaction
- Cannot chain from another `@future`
- Order of execution is not guaranteed

### Pattern 2 — Queueable + `Database.AllowsCallouts`

```apex
public class SyncJob implements Queueable, Database.AllowsCallouts {
    private List<Id> ids;
    public SyncJob(List<Id> ids) { this.ids = ids; }

    public void execute(QueueableContext ctx) {
        // Callout FIRST
        String result = ExternalApiClient.post('/bulk-sync', ids);
        // DML AFTER
        update buildStatusRecords(result);
        // Chain for remaining records
        if (moreRemain) { System.enqueueJob(new SyncJob(nextBatch)); }
    }
}
Id jobId = System.enqueueJob(new SyncJob(accountIds));
```

**Advantages over @future:**
- Accepts complex types (SObjects, custom classes) in constructor
- Can chain (max depth 50)
- Monitorable in Setup → Apex Jobs

### Pattern 3 — Batch + `Database.AllowsCallouts`

```apex
public class SyncBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return Database.getQueryLocator([SELECT Id FROM Account WHERE Sync_Status__c = 'Pending']);
    }
    public void execute(Database.BatchableContext ctx, List<Account> scope) {
        // Callouts ONLY in execute() — NOT in start() or finish()
        for (Account acc : scope) {
            ExternalApiClient.post('/accounts', acc);
        }
        // DML after callouts in same execute()
    }
    public void finish(Database.BatchableContext ctx) {
        // Callouts in finish() require enqueuing a Queueable:
        System.enqueueJob(new NotifyWebhookJob());
    }
}
Database.executeBatch(new SyncBatch(), 5); // small batch size for callout-heavy batches
```

**Rules:**
- `Database.AllowsCallouts` enables callouts in `execute()` only
- Callouts in `start()` or `finish()` throw `CalloutException`
- For finish()-time callouts: enqueue a `Queueable` from `finish()`
- Keep batch size small (1–10) when making per-record callouts

### Comparison

| | `@future` | Queueable | Batch |
|---|---|---|---|
| Complex params | No (primitives only) | Yes | Via SOQL |
| Chaining | No | Yes (50 deep) | No |
| Ordering guarantee | No | No | No |
| DML before callout | Separate tx | Separate tx | Separate tx |
| Callout in finish | N/A | N/A | Enqueue Queueable |
| UI monitoring | No | Yes | Yes |
| Max callouts/tx | 100 | 100 | 100 |

---

## Testing Async Callouts

```apex
@IsTest
static void testFutureCallout() {
    // 1. Set mock BEFORE startTest
    Test.setMock(HttpCalloutMock.class, new CalloutMocks.SingleResponse(200, body));

    Test.startTest();
    // 2. Enqueue the async job
    AsyncCalloutService.syncAccountFuture(acc.Id);
    Test.stopTest();  // ← drains @future / Queueable queue synchronously

    // 3. Assert on side effects after stopTest
    Account updated = [SELECT Sync_Status__c FROM Account WHERE Id = :acc.Id];
    System.assertEquals('Synced', updated.Sync_Status__c);
}
```

**All three async types** (@future, Queueable, Batch) execute synchronously within `Test.startTest()/stopTest()`.

---

## Interview Q&A

**Q: What is the difference between WSDL2Apex and manual SOAP callouts?**
> WSDL2Apex generates type-safe stub classes from a WSDL, abstracting the XML building and parsing. It's faster to implement but has limitations: large WSDLs can fail to generate, and WS-Security is not supported. Manual SOAP gives full control — build the XML string, set the `SOAPAction` header, and parse the DOM response — required when WSDL2Apex is insufficient.

**Q: Why do Apex callouts fail after DML in the same transaction?**
> Salesforce uses a two-phase commit: if a callout succeeds but the transaction rolls back, the external system has already processed the request — causing data inconsistency. To prevent this, the platform disallows callouts after uncommitted DML. The solution is to separate DML and callouts via `@future(callout=true)`, Queueable with `Database.AllowsCallouts`, or by putting callouts before DML within the same execution context.

**Q: Can you make callouts in Batch `finish()`?**
> No — `Database.AllowsCallouts` only enables callouts in `execute()`. To make callouts after batch completion, enqueue a Queueable from `finish()`: `System.enqueueJob(new NotifyJob())`.

**Q: What is the difference between `@future` and Queueable for callouts?**
> `@future` accepts only primitive parameters, cannot chain, and cannot be monitored in the UI. Queueable accepts any serialisable type in its constructor, can chain up to 50 levels, supports dependency injection, and appears in Setup → Apex Jobs. For production integrations, Queueable is always preferable.

**Q: What is Outbound Messaging and how does it differ from a Platform Event?**
> Outbound Messaging is a declarative feature triggered by Workflow Rules or Flows that POSTs a SOAP XML message to an external endpoint. The delivery is guaranteed-at-least-once (retries for 24 hours) and includes a session token for callbacks. Platform Events are pub/sub within Salesforce and are consumed by subscribers (Apex triggers, Flows, external CDC consumers via Pub/Sub API). Platform Events are more scalable and support real-time streaming; Outbound Messaging is simpler for push-to-external scenarios.

**Q: How do you make Outbound Message delivery idempotent?**
> Each notification has a unique `<Notification><Id>`. Store processed notification Ids in a custom object (or Platform Cache for short windows). Before processing, check if the Id was already handled and skip if so. Return `<Ack>true</Ack>` in either case to prevent Salesforce from re-sending.

**Q: What does returning `<Ack>false</Ack>` do?**
> It tells Salesforce that delivery failed and to retry. The platform retries for up to 24 hours with increasing intervals. Use this when your downstream system is temporarily unavailable. Return `Ack=false` with HTTP 200 — a non-200 HTTP status is also treated as a retry trigger but can cause logging noise.

---

## Files Created

| File | Purpose |
|---|---|
| `classes/SoapApiService.cls` | `buildEnvelope`, `buildEnvelopeWithSecurity` (WS-Security), `sendSoapRequest`, `parseSoapResponse` (DOM), `extractElement`, `SoapFaultException` |
| `classes/AsyncCalloutService.cls` | `@future(callout=true)`, `SyncAccountsJob` (Queueable+AllowsCallouts, sliced chaining), `SyncAccountBatch` (Batch+AllowsCallouts, finish→Queueable), `NotifyWebhookJob` |
| `classes/OutboundMessageHandler.cls` | `@RestResource` SOAP handler, `parseNotification` (Dom.Document), `buildAckResponse`, idempotency scaffold |
| `classes/CalloutAsyncTest.cls` | 18 tests — SOAP build/parse/fault, async callout DML side effects, ACK response format |
| `objects/Account/fields/Sync_Status__c.field-meta.xml` | Picklist: Pending / Synced / Failed / Error |
| `objects/Account/fields/Sync_Error__c.field-meta.xml` | Text 255 for error messages |
