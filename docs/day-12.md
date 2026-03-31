# Day 12 — Flows: Record-Triggered, Auto-Launched & Invocable Apex

## Topics Covered

| Topic | Pattern | Asset |
|-------|---------|-------|
| Before-Save Record-Triggered Flow | Entry conditions, Decision, Assignment | `Account_Rating_Update` |
| After-Save Record-Triggered Flow | Fault paths, Record Create, formula vars | `Opportunity_Won_Tasks` |
| Auto-Launched Flow | Input/output variables, Apex action call | `Account_Score_Calculator` |
| Invocable Apex — input/output | `@InvocableMethod`, `@InvocableVariable`, bulk-safe | `FlowActionCalculateScore` |
| Invocable Apex — void return | Custom Notification, fallback Task | `FlowActionSendNotification` |
| Flow testing via DML | Before/After save trigger via insert/update | `FlowActionTest` |
| Flow testing via direct call | `List<Request>` → static method → `List<Result>` | `FlowActionTest` |

---

## Flow vs Apex Decision Matrix

| Criterion | Flow (Declarative) | Apex (Programmatic) |
|-----------|-------------------|---------------------|
| Simple field updates | ✅ Preferred | Overkill |
| Create/update related records | ✅ After-Save Flow | ✅ Trigger |
| Complex queries (joins, aggregates) | ❌ Limited | ✅ Required |
| Branching logic (if/else) | ✅ Decision element | ✅ if/switch |
| Looping over collections | ✅ Loop element (no SOQL in loop!) | ✅ for loop |
| Calling external APIs | ✅ External Services (HTTP callout) | ✅ HttpRequest |
| Calling Platform Events | ✅ Create PE record element | ✅ EventBus.publish |
| Unit-testable in isolation | ❌ Requires DML or Flow.Interview | ✅ Direct Apex call |
| Admin-configurable without deployment | ✅ Flow Builder | ❌ Requires developer |
| Governor limit transparency | ❌ Harder to reason about | ✅ Explicit SOQL/DML |
| Bulk-safe by default | ❌ Must design explicitly | ❌ Must design explicitly |

**Salesforce Guidance:** Prefer declarative (Flow) for simple automation. Use Apex when logic requires complex queries, external callouts, or fine-grained error handling that Flow's fault paths cannot express.

---

## Record-Triggered Flow Architecture

### Before Save vs After Save

```
Record DML (INSERT/UPDATE/DELETE)
        │
        ├─► Before-Save Flows  ← Modifies $Record fields in memory (no extra DML)
        │        └─ FAST: no DML statements consumed
        │        └─ CANNOT: create related records, send emails, call Apex
        │        └─ USE FOR: field defaulting, validation, data normalisation
        │
        ├─► Before-Save Triggers (Apex)
        │
        ├─► [Database commit]
        │
        ├─► After-Save Flows   ← Can create/update related records, call Apex
        │        └─ HAS $Record.Id  (record is committed)
        │        └─ CONSUMES: DML statements (like a trigger)
        │        └─ USE FOR: related record creation, notifications, Platform Events
        │
        └─► After-Save Triggers (Apex)
```

### Entry Conditions (IsChanged filter)

```xml
<filters>
    <field>StageName</field>
    <operator>EqualTo</operator>
    <value><stringValue>Closed Won</stringValue></value>
</filters>
<filters>
    <field>StageName</field>
    <operator>IsChanged</operator>
    <value><booleanValue>true</booleanValue></value>
</filters>
```

**Why `IsChanged` matters:**
Without it, the flow fires on every save of a Closed Won opportunity (e.g., editing the Description) and creates duplicate Tasks on each edit. `IsChanged` + `EqualTo 'Closed Won'` = "fires only on the exact moment StageName transitions to Closed Won."

### `$Record` vs `$Record__Prior`

| Variable | Available | Value |
|----------|-----------|-------|
| `$Record` | Before Save + After Save | Current field values (post-change) |
| `$Record__Prior` | Before Save + After Save (Update only) | Field values BEFORE this save |

Use `$Record__Prior.StageName` to detect what the stage was before the current save — the same as `Trigger.old` in Apex.

### Fault Paths (Best Practice)

```xml
<recordCreates>
    <name>Create_Contract_Task</name>
    <faultConnector>
        <targetReference>Log_Error</targetReference>   ← REQUIRED on every DML element
    </faultConnector>
    ...
</recordCreates>
```

**Without a fault path:** an unhandled DML error rolls back the entire transaction including the triggering record save. The user sees a generic "internal error" with no context.

**With a fault path:** route to a fault handler that creates an error Task, logs to a Custom Object, or sends an email alert. `$Flow.FaultMessage` contains the error text.

### Formula Resources (Date arithmetic)

```xml
<formulas>
    <name>ContractDueDate</name>
    <dataType>Date</dataType>
    <expression>TODAY() + 2</expression>
</formulas>
```

Flow cannot perform inline date arithmetic in Assignment elements — use Formula resources to compute derived values like `TODAY() + N`.

---

## Auto-Launched Flow

### When to Use

- Invoked from Apex: `Flow.Interview.Account_Score_Calculator i = new Flow.Interview.Account_Score_Calculator(inputs); i.start(); Object result = i.getVariableValue('calculatedScore');`
- Invoked from a Subflow element in another Flow
- Invoked from REST API: `POST /services/data/v62.0/actions/custom/flow/Account_Score_Calculator`
- Invoked from a Scheduled Flow (with scheduled path)

### Input/Output Variables

```xml
<variables>
    <name>accountId</name>
    <dataType>String</dataType>
    <isInput>true</isInput>    <!-- settable by caller -->
    <isOutput>false</isOutput>
</variables>

<variables>
    <name>calculatedScore</name>
    <dataType>Number</dataType>
    <isInput>false</isInput>
    <isOutput>true</isOutput>  <!-- readable by caller after flow completes -->
</variables>
```

---

## `@InvocableMethod` Rules

```apex
@InvocableMethod(
    label       = 'Calculate Account Score'   // shown in Flow Builder (required)
    description = 'Computes score...'          // tooltip (optional)
    category    = 'Account'                    // groups in action search palette
)
public static List<Result> calculateScores(List<Request> requests) {
    // bulk-safe: process all requests in ONE SOQL
}
```

### Key Rules (interview checklist)

| Rule | Detail |
|------|--------|
| One per class | Only ONE `@InvocableMethod` allowed per Apex class |
| Static | Must be `public static` or `global static` |
| Parameter | Must be `List<T>` — platform passes all records at once |
| Return type | `void`, `List<T>`, or `List<List<T>>` |
| Inner class fields | Must use `@InvocableVariable` to be visible in Flow Builder |
| Cannot call from | `@future`, Batch `execute()`, `Queueable`, another `@InvocableMethod` |
| Bulk safety | Must collect all Ids → ONE SOQL → map results (same pattern as trigger handlers) |

### `@InvocableVariable` Options

```apex
@InvocableVariable(
    label       = 'Account Id'          // shown in Flow Builder mapping panel
    description = 'Salesforce Id...'    // tooltip
    required    = true                  // Flow Builder enforces mapping
)
public Id accountId;
```

### Bulk-Safe Pattern

```apex
// ❌ Non-bulk (100-record flow = 100 SOQL = governor limit failure)
for (Request req : requests) {
    Account acc = [SELECT Id FROM Account WHERE Id = :req.accountId];
    ...
}

// ✅ Bulk-safe (100-record flow = 1 SOQL)
Set<Id> ids = new Set<Id>();
for (Request req : requests) { ids.add(req.accountId); }
Map<Id, Account> accountMap = new Map<Id, Account>([
    SELECT Id, Name, AnnualRevenue FROM Account WHERE Id IN :ids
]);
for (Request req : requests) {
    Account acc = accountMap.get(req.accountId);
    results.add(computeResult(acc));
}
```

---

## Testing Flows

### Testing Record-Triggered Flows (via DML)

```apex
@IsTest
static void accountRatingFlow_hotOnHighRevenue() {
    // Insert triggers the Before-Save flow synchronously
    Account acc = new Account(Name = 'Test', AnnualRevenue = 5_000_000);
    Test.startTest();
    insert acc;
    Test.stopTest();

    // Flow has already run — query to assert field was set
    Account updated = [SELECT Rating FROM Account WHERE Id = :acc.Id];
    System.assertEquals('Hot', updated.Rating);
}
```

**Note:** `Test.startTest()` / `Test.stopTest()` resets governor limits and flushes async operations. Place the DML trigger inside `startTest/stopTest` to ensure the flow runs in its own execution context.

### Testing Auto-Launched Flows via `Flow.Interview`

```apex
@IsTest
static void scoreCalculatorFlow_setsFieldOnAccount() {
    Account acc = new Account(Name = 'Flow Test', AnnualRevenue = 5_000_000);
    insert acc;

    Map<String, Object> inputs = new Map<String, Object>{
        'accountId' => acc.Id
    };
    Flow.Interview flow = Flow.Interview.createInterview(
        'Account_Score_Calculator', inputs
    );

    Test.startTest();
    flow.start();
    Test.stopTest();

    Integer score = (Integer) flow.getVariableValue('calculatedScore');
    System.assertNotEquals(null, score, 'calculatedScore output should be populated');
}
```

**When to use `Flow.Interview`:** Integration tests that verify the full Flow execution path — variable mapping, routing decisions, DML actions. Use for smoke tests post-deployment, not as the primary unit test approach (slow, requires active Flow in org).

---

## Interview Questions — Day 12

**Q: What is the execution order for Record-Triggered Flows relative to Apex Triggers?**

Full order: Validation Rules → Before Triggers → Before-Save Flows → [commit] → After Triggers → After-Save Flows → Assignment Rules → Auto-Response Rules → Workflow Rules → Processes → Escalation Rules.

Key point: **Before-Save Flows run AFTER Before Triggers** (both modify the record in memory before commit). **After-Save Flows run AFTER After Triggers**.

**Q: Why can't a Before-Save Flow create a Task?**

Before-Save Flows run before the record is committed to the database — the triggering record's Id doesn't exist yet. Creating a related record (like a Task with `WhatId`) would require a valid record Id. Additionally, Before-Save Flows are not allowed to perform DML operations — they can only modify `$Record` field values in memory.

**Q: How does Flow bulkification work for Invocable Apex?**

When 200 records trigger a flow that calls an Invocable Apex action, the platform collects all 200 invocations into a single `List<Request>` and calls the static method ONCE. If the Apex method performs SOQL inside a loop over `requests`, it will hit the 101-SOQL governor limit. The correct pattern is to collect all Ids into a `Set<Id>`, execute one SOQL with `WHERE Id IN :ids`, build a Map, then iterate over requests using the Map.

**Q: What is the difference between `isInput` and `isOutput` on a Flow variable?**

`isInput=true` means the variable can be set by the caller when invoking the flow (passed in). `isOutput=true` means the caller can read the variable's value after the flow completes. A variable can be both (`isInput=true, isOutput=true`), making it bidirectional. A variable with neither cannot be accessed externally — it's local to the flow.

**Q: When would you choose an After-Save Flow over an Apex Trigger for creating related records?**

Choose After-Save Flow when: (1) the logic is simple (no complex queries, no apex-only features), (2) it needs to be admin-configurable, (3) you want it visible in Flow Builder for future admin maintenance. Choose Apex Trigger when: (1) the creation logic depends on complex queries or aggregates, (2) you need fine-grained error handling with custom exception types, (3) the DML involves relationships that are hard to express in Flow, (4) the logic needs to be unit-tested in full isolation without DML.

---

## Files Created (Day 12)

```
force-app/main/default/
├── flows/
│   ├── Account_Rating_Update.flow-meta.xml      Before-Save; entry condition; 3-tier decision
│   ├── Opportunity_Won_Tasks.flow-meta.xml       After-Save; fault paths; formula date vars
│   └── Account_Score_Calculator.flow-meta.xml   Auto-Launched; input/output vars; Apex action
├── classes/
│   ├── FlowActionCalculateScore.cls             @InvocableMethod; bulk-safe; List<Request/Result>
│   ├── FlowActionCalculateScore.cls-meta.xml
│   ├── FlowActionSendNotification.cls           @InvocableMethod; void return; Custom Notification
│   ├── FlowActionSendNotification.cls-meta.xml
│   ├── FlowActionTest.cls                       17 tests; DML-triggered flow tests; direct call
│   └── FlowActionTest.cls-meta.xml
└── objects/Account/fields/
    ├── Account_Score__c.field-meta.xml          Number(5,0) — computed engagement score
    └── Account_Tier__c.field-meta.xml           Text(20) — Bronze/Silver/Gold/Platinum
scripts/deploy-day-12.sh
docs/day-12.md
```
