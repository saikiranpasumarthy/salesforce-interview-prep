# Day 31 — Agentforce Deep Dive: Autonomous Agents, RAG, and Einstein Copilot

## Topics Covered

- Autonomous agents (event-triggered, no user in loop)
- Conversation context management across turns
- Human escalation via Omni-Channel (PendingServiceRouting)
- Multi-step orchestration: coordinator action vs LLM-driven chaining
- External API callout actions (`callout=true`)
- Sentiment detection as an escalation trigger
- RAG (Retrieval-Augmented Generation) pattern
- Semantic search with SOSL
- Einstein Copilot configuration introspection (`BotDefinition`, `BotTopic`)
- Account qualification coordinator action

---

## Autonomous Agents

### User-Triggered vs Autonomous

| Attribute | User-Triggered | Autonomous |
|-----------|---------------|-----------|
| Initiator | User message | Platform Event / Record Change / Schedule |
| Loop | User in loop | No user in loop |
| Context | Conversation history | Event payload only |
| Output | Chat response | Chatter post / email / record update |
| Idempotency | Less critical | **Must be idempotent** (events can replay) |

### Trigger Sources

```
Platform Event trigger:
trigger MyEventTrigger on My_Event__e (after insert) {
    // Call @InvocableMethod or enqueue Queueable
    List<AgentConversationService.AutonomousEventInput> inputs = ...;
    AgentConversationService.processAutonomousCaseEvent(inputs);
}

Record-Triggered Flow:
  → Element: Action (Apex Action)
  → Select: Process Autonomous Case Event
  → Map: {!$Record.Id} → Case Id

Scheduled Flow:
  → Runs on schedule → calls Apex Agent Actions
  → Use for periodic autonomous sweeps (e.g. "check SLA breaches every hour")
```

### Autonomous Agent Best Practices

1. **Idempotent** — running twice must produce same result; check before updating
2. **Explicit error handling** — log errors; no user to report to
3. **Structured output** — even if no user sees it, return output for Flow/audit
4. **Post results** — Chatter post / email / record field to create audit trail
5. **Governor limits** — autonomous actions still bound by Apex limits

---

## Conversation Context Management

Agentforce has **no built-in cross-session memory**. Pattern to implement context:

```apex
// Save context to Platform Cache (session-scoped, up to 1 hour)
PlatformCacheService.put('agent_' + sessionId + '_lastAccountId', accountId, 3600);

// Retrieve in next turn
String lastId = (String) PlatformCacheService.get('agent_' + sessionId + '_lastAccountId');
```

### Alternatives

| Storage | TTL | Persistence | Use Case |
|---------|-----|-------------|---------|
| Platform Cache (session) | Hours | No | Short conversations |
| Custom sObject | Permanent | Yes | Audit trail, long-running sessions |
| Platform Cache (org) | Hours | No | Cross-session preferences |
| Named Credentials / External | External | Yes | External session stores |

### $Context Variables in Flow (for agent flows)

```
{!$Context.SessionId}         — unique session identifier
{!$Context.LastBotMessage}    — text of the last agent response
{!$Context.BotName}           — name of the current agent
```

---

## Human Escalation via Omni-Channel

```apex
// 1. Create or reference existing Case
Case c = new Case(Subject = 'Escalation', Origin = 'Einstein Copilot', ...);
insert c;

// 2. Create PendingServiceRouting to trigger Omni-Channel routing
PendingServiceRouting psr = new PendingServiceRouting(
    WorkItemId        = c.Id,
    RoutingType       = 'QueueBased',  // 'Omni' | 'QueueBased' | 'SkillsBased'
    CapacityWeight    = 1,
    IsReadyForRouting = true
);
insert psr;
// → Omni-Channel routes Case to the configured queue/agent
```

### Escalation Trigger Patterns

- **Sentiment detection** — keyword scoring or LLM sentiment analysis
- **Topic Instructions** — "If the user mentions 'cancel' or 'refund', escalate"
- **Action output flag** — action returns `shouldEscalate = true`; Topic Instructions check it
- **Iteration limit** — escalate after N failed resolution attempts
- **Explicit request** — "I want to speak to a human"

---

## Multi-Step Orchestration Strategies

### Strategy 1: LLM-Driven (ReAct Pattern)

```
User: "Research Acme and send them an email"
  LLM → calls getAccountSummary(accountId)
  LLM → calls getPipelineSummary(ownerId)
  LLM → calls generateSalesEmail(opportunityId, ...)
  LLM → composes final response
```

- Flexible, LLM decides order
- Risk: LLM may skip steps or call wrong action
- Best for: open-ended exploration

### Strategy 2: Coordinator Action (this pattern)

```apex
// One @InvocableMethod orchestrates deterministic multi-step sequence
@InvocableMethod(label='Qualify and Assign Account')
public static List<Output> qualifyAndAssign(List<Input> inputs) {
    // Step 1: Determine tier
    // Step 2: Update industry
    // Step 3: Create task
    // Returns summary of all steps
}
```

- Deterministic, always executes in order
- LLM calls one action; Apex handles orchestration
- Best for: fixed-sequence workflows

---

## RAG (Retrieval-Augmented Generation)

### Pattern Flow

```
User Question: "What cases does Acme have?"
        ↓
  Retrieve RAG Context Action
    → SOSL search for "Acme" in Cases
    → Returns: "Related Cases: Case 00001: Login issue [Open, High]"
        ↓
  Inject into Prompt Template
    {!$Input.ContextText} = "Related Cases: Case 00001..."
    {!$Input.UserQuestion} = "What cases does Acme have?"
        ↓
  LLM generates grounded response
    "Acme currently has 1 open case: Case 00001 (Login issue, High priority)"
```

### RAG vs Fine-Tuning

| | RAG | Fine-Tuning |
|-|-----|-------------|
| Data freshness | Real-time (queried at runtime) | Stale (baked at training time) |
| Cost | Per-query (token cost) | High upfront training cost |
| Maintenance | No retraining needed | Retrain when data changes |
| Hallucination risk | Low (grounded in retrieved facts) | Higher (relies on memorised patterns) |
| Salesforce recommendation | ✅ Preferred | Rarely used |

### Grounding Sources

```apex
// 1. SOQL (structured, known object)
Account acc = [SELECT Name, Industry FROM Account WHERE Id = :accountId WITH SECURITY_ENFORCED];

// 2. SOSL (full-text, cross-object)
List<List<SObject>> results = Search.query(
    'FIND :userQuery IN ALL FIELDS RETURNING Account(Name), Case(Subject) LIMIT 10'
);

// 3. External API (Named Credential)
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:KnowledgeAPI/search?q=' + userQuery);
```

---

## Semantic Search with SOSL

```apex
// Cross-object search — one query, multiple objects
List<List<SObject>> results = Search.query(
    'FIND :term IN ALL FIELDS '
    + 'RETURNING '
    + 'Account(Id, Name, Industry), '
    + 'Contact(Id, FirstName, LastName, Email), '
    + 'Case(Id, CaseNumber, Subject, Status), '
    + 'Opportunity(Id, Name, StageName) '
    + 'LIMIT 50'
);
// results[0] = Accounts, results[1] = Contacts, etc.
```

### SOSL Search Groups

| Group | Searches |
|-------|---------|
| `IN ALL FIELDS` | All indexed text fields |
| `IN NAME FIELDS` | Name/Title fields only (fastest) |
| `IN EMAIL FIELDS` | Email fields only |
| `IN PHONE FIELDS` | Phone fields only |

---

## Callout Action Pattern

```apex
@InvocableMethod(
    label   = 'Enrich Account from External Data'
    callout = true  // REQUIRED for HTTP callouts
)
public static List<Output> enrichAccountData(List<Input> inputs) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:DataEnrichmentAPI/v1/company?domain=' + domain);
    req.setMethod('GET');
    req.setTimeout(10000); // 10s — agent response budget
    req.setHeader('Accept', 'application/json');
    HttpResponse resp = new Http().send(req);
    // ...
}
```

**Rules:**
- `callout=true` on `@InvocableMethod` is mandatory
- Named Credential handles authentication — never hardcode credentials
- Set timeout — agents have a response time SLA (~30s typical)
- Count against callout limit (100/transaction)
- Cannot use in Batch `execute()` or `@future`

---

## Sentiment Detection

### Keyword Scoring (Apex — fast, no LLM needed)

```apex
Set<String> negKeywords = new Set<String>{
    'frustrated', 'angry', 'cancel', 'refund', 'escalate', 'manager'
};
Integer score = 0;
for (String kw : negKeywords) {
    if (text.toLowerCase().contains(kw)) { score++; }
}
Boolean shouldEscalate = score >= 2;
```

### LLM-Based (accurate, adds latency)

```
Prompt: "Classify the sentiment of the following customer message as:
         Positive, Neutral, Negative, or Very Negative.
         Also indicate if human escalation is recommended (yes/no).
         Message: {!$Input.MessageText}"
```

**Rule of thumb**: use keyword scoring for latency-sensitive paths; use LLM sentiment for nuanced escalation decisions where latency budget allows.

---

## BotDefinition / BotTopic (Copilot Metadata Objects)

```apex
// Query active agents
List<BotDefinition> agents = [
    SELECT Id, DeveloperName, MasterLabel, Status, Type
    FROM   BotDefinition
    WHERE  Status = 'Active'
];

// Query topics for an agent
List<BotTopic> topics = [
    SELECT Id, DeveloperName, MasterLabel, Description
    FROM   BotTopic
    WHERE  BotDefinitionId = :agentId
];
```

**BotDefinition.Type values:**
- `'EinsteinGPTCopilot'` — Einstein Copilot
- `'EinsteinBot'`        — legacy Einstein Bot (pre-Agentforce)
- `'Agentforce'`         — autonomous agent

---

## Testing Agent Actions

### Pattern: Mock all non-CRM dependencies

```apex
// 1. HTTP callouts: HttpCalloutMock
Test.setMock(HttpCalloutMock.class, new MyMock(200, '{"result":"ok"}'));

// 2. Platform Cache: @TestVisible useMock flag
PlatformCacheService.useMock = true; // auto-set via Test.isRunningTest()

// 3. SOSL: Test.setFixedSearchResults()
Test.setFixedSearchResults(new List<Id>{ accountId, caseId });

// 4. LLM calls: useMock flag on PromptTemplateService
PromptTemplateService.useMock = true;
PromptTemplateService.mockLlmResponse = 'Mocked response';

// 5. ConnectApi (BotDefinition): graceful degradation via Database.query + try/catch
```

### What to Assert in Agent Action Tests

- `isSuccess = true/false` for each path
- Actual DML side effects (Case created, Task created, field updated)
- Chatter posts for autonomous actions
- `errorMessage` content on failure paths
- Confirmation message text on success paths
- Bulk safety: invoke with 2+ inputs, assert all results returned

---

## Interview Tips

1. **Autonomous agent idempotency** — events can replay on failure; always check before DML.

2. **Coordinator vs ReAct** — interviewers ask "how do you build a multi-step agent workflow?" Answer: coordinator for deterministic sequences, separate actions + Topic Instructions for LLM-driven chains.

3. **RAG > fine-tuning for CRM** — always say RAG in Salesforce context. Real-time, no retraining, lower cost, grounded.

4. **`callout=true` on `@InvocableMethod`** — easy to forget; causes runtime exception without it.

5. **Context management** — "Agentforce has no built-in memory" is a common interview point. Answer: Platform Cache (session) for short conversations, custom sObject for persistence.

6. **SOSL vs SOQL in agent actions** — SOSL for "find anything related to X" (cross-object, full-text); SOQL for "get specific record by Id or known criteria."

7. **Escalation trigger** — know all four: sentiment, Topic Instructions, action output flag, explicit user request.

8. **PendingServiceRouting** — the Apex API to route a work item to Omni-Channel. `WorkItemId` is the Case/MessagingSession Id; `RoutingType` is 'QueueBased' for queue routing.
