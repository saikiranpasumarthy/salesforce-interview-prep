# Day 37 — Mock Interview Day 1: Apex + LWC + Triggers

## Interview Format Tips

- **Think aloud** — interviewers want to follow your reasoning, not just the answer
- **STAR method** for experience questions: Situation, Task, Action, Result
- **Clarify before coding**: "Should this handle bulk operations? Any specific governor limit concerns?"
- **State trade-offs** upfront: "I could also use Batch here, but Queueable is simpler for this scale"
- **Write tests as you code** — mentioning test strategy shows seniority

---

## APEX INTERVIEW Q&A

### Q1: "Explain bulkification. Show me a non-bulkified trigger and fix it."

**Bad (SOQL in loop):**
```apex
trigger ContactTrigger on Contact (before insert) {
    for (Contact c : Trigger.new) {
        List<Contact> dupes = [SELECT Id FROM Contact WHERE Email = :c.Email]; // ❌ SOQL in loop
        if (!dupes.isEmpty()) c.addError('Duplicate email');
    }
}
```

**Good (single SOQL, set-based):**
```apex
trigger ContactTrigger on Contact (before insert) {
    new ContactTriggerHandler().run(); // One trigger → one handler
}

// Handler:
Set<String> emails = new Set<String>();
for (Contact c : Trigger.new) {
    if (c.Email != null) emails.add(c.Email.toLowerCase());
}
Map<String, Id> existing = new Map<String, Id>();
for (Contact c : [SELECT Id, Email FROM Contact WHERE Email IN :emails]) {
    existing.put(c.Email.toLowerCase(), c.Id);
}
for (Contact c : Trigger.new) {
    if (c.Email != null && existing.containsKey(c.Email.toLowerCase())) {
        c.addError('Duplicate email detected.');
    }
}
```

---

### Q2: "When would you use @future vs Queueable vs Batch Apex?"

| Pattern | Use When | Limitations |
|---------|----------|-------------|
| `@future` | Simple async, fire-and-forget, callouts | Primitives only as params; no chaining |
| `Queueable` | Need objects as params, chaining, or state | 1 child per parent in production |
| `Batch` | > 2,000 records, scheduled processing | Start/Execute/Finish overhead |
| `Scheduled` | Recurring execution (cron) | Calls Batch or Queueable inside |

**Decision logic:**
```
Scheduled? → Schedulable
> 2000 records? → Batch
Need chaining or complex state? → Queueable
Simple callout / small async? → @future (or Queueable preferred)
```

---

### Q3: "What is SOQL injection and how do you prevent it?"

**Vulnerable:**
```apex
String name = ApexPages.currentPage().getParameters().get('name');
String soql = 'SELECT Id FROM Account WHERE Name = \'' + name + '\'';
// Malicious input: ' OR Name != '' — returns ALL accounts
```

**Prevention — bind variables (best):**
```apex
String name = ApexPages.currentPage().getParameters().get('name');
List<Account> accs = [SELECT Id FROM Account WHERE Name = :name]; // ✅ bind var
```

**Prevention — String.escapeSingleQuotes (when bind not possible):**
```apex
String safe = String.escapeSingleQuotes(name);
String soql = 'SELECT Id FROM Account WHERE Name = \'' + safe + '\'';
```

**Prevention — Database.queryWithBinds:**
```apex
Map<String, Object> bindMap = new Map<String, Object>{ 'val_Name' => name };
List<SObject> results = Database.queryWithBinds(soql, bindMap, AccessLevel.USER_MODE);
```

---

### Q4: "What's the difference between `Database.insert()` and `insert`?"

| | `insert list` | `Database.insert(list, false)` |
|--|--------------|-------------------------------|
| Error handling | Throws exception on first error | Returns `SaveResult[]` per record |
| All-or-nothing | Yes — all fail if one fails | No — partial success possible |
| Use case | Data that must all succeed together | Bulk operations where partial is OK |

```apex
List<Database.SaveResult> results = Database.insert(accounts, false); // allOrNone=false
for (Database.SaveResult sr : results) {
    if (!sr.isSuccess()) {
        System.debug('Failed: ' + sr.getErrors()[0].getMessage());
    }
}
```

---

### Q5: "Explain the Salesforce order of execution"

```
1.  System validation (required fields, field length)
2.  Before-save flows (Record-Triggered)
3.  Before triggers
4.  Validation rules
5.  Duplicate rules
6.  Record saved to DB (not committed)
7.  After triggers
8.  Assignment rules
9.  Auto-response rules
10. Workflow rules (field updates → re-run triggers)
11. Process Builder (legacy)
12. Escalation rules
13. After-save flows (Record-Triggered)
14. Roll-up summary fields recalculated
15. Criteria-based sharing evaluated
16. COMMIT to database
17. Post-commit: @future, email alerts, outbound messages
```

**Key interview trick:** Workflow field updates re-run the before/after triggers (step 10 → 3 → 7). This causes recursion. Use a static Boolean flag to prevent infinite loops.

---

### Q6: "How do you handle recursive triggers?"

**Option A: Static Boolean (simple):**
```apex
public class RecursionGuard {
    private static Set<Id> processed = new Set<Id>();
    public static Boolean isFirstTime(Id recId) {
        if (processed.contains(recId)) return false;
        processed.add(recId);
        return true;
    }
}
// In trigger handler:
Set<Id> toProcess = new Set<Id>();
for (Account a : Trigger.new) {
    if (RecursionGuard.isFirstTime(a.Id)) toProcess.add(a.Id);
}
```

**Option B: Loop count in TriggerHandlerBase (more nuanced):**
```apex
// Allows exactly N executions per handler per transaction
private Boolean checkLoopCount() {
    Integer count = loopCountMap.get(name) ?? 0;
    loopCountMap.put(name, count + 1);
    return (count + 1) <= maxLoopCount; // maxLoopCount = 1 by default
}
```

---

### Q7: "Show me the Trigger Handler Framework pattern."

```apex
// 1. One trigger per object — NO logic here
trigger AccountTrigger on Account (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new AccountTriggerHandler().run();
}

// 2. Handler extends base class, overrides only what it needs
public class AccountTriggerHandler extends TriggerHandlerBase {
    override protected void beforeInsert() {
        AccountService.setDefaults(Trigger.new);
    }
    override protected void afterInsert() {
        AccountService.createOnboardingTasks(Trigger.new);
    }
}

// 3. Bypass in data migration scripts
TriggerHandlerBase.bypass('AccountTriggerHandler');
insert massDataList;
TriggerHandlerBase.clearBypass('AccountTriggerHandler');
```

---

### Q8: "How do you test a method that makes an HTTP callout?"

```apex
// 1. Implement HttpCalloutMock
public class MyMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
        HttpResponse resp = new HttpResponse();
        resp.setStatusCode(200);
        resp.setBody('{"status":"ok"}');
        return resp;
    }
}

// 2. Set mock in test — must be before Test.startTest()
@IsTest
static void myCalloutTest() {
    Test.setMock(HttpCalloutMock.class, new MyMock());
    Test.startTest();
    MyService.doCallout();
    Test.stopTest();
    // Assert on results
}
```

---

### Q9: "Explain `Database.SaveResult` vs exceptions"

```apex
// allOrNone = true (default) → exception on any failure
try {
    insert accounts; // throws DmlException if ANY record fails
} catch (DmlException e) {
    for (Integer i = 0; i < e.getNumDml(); i++) {
        System.debug(e.getDmlMessage(i) + ' at index ' + e.getDmlIndex(i));
    }
}

// allOrNone = false → inspect results per record
List<Database.SaveResult> results = Database.insert(accounts, false);
for (Integer i = 0; i < results.size(); i++) {
    if (!results[i].isSuccess()) {
        errorLog.add(accounts[i].Id + ': ' + results[i].getErrors()[0].getMessage());
    }
}
```

---

## LWC INTERVIEW Q&A

### Q1: "Explain the LWC component lifecycle"

```
constructor()       → runs first; DOM not ready; no child components yet
connectedCallback() → component inserted in DOM; child components NOT ready yet
renderedCallback()  → after every render; child components accessible here
disconnectedCallback() → component removed from DOM; clean up timers/listeners
errorCallback(error, stack) → catches errors from child components
```

**Key interview tip:** Never do DOM manipulation in `constructor()`. Use `connectedCallback()` for setup and `renderedCallback()` for accessing `this.template.querySelector()`.

---

### Q2: "What's the difference between @wire and imperative calls?"

| | `@wire` | Imperative (`await apex()`) |
|--|---------|------------------------------|
| When called | Automatically, when params change | Explicitly, in a handler or lifecycle |
| Caching | Automatic (cacheable=true required) | Manual (`refreshApex()`) |
| Error handling | `wiredResult.error` | `try/catch` |
| Use for | Initial data load, reactive to record Id | User actions, after DML, conditional logic |

```javascript
// @wire — declarative, reactive
@wire(getAccounts, { recordId: '$recordId' })
wiredAccounts({ data, error }) { ... }

// Imperative — explicit control
async handleSearch() {
    try {
        this.accounts = await searchAccounts({ term: this.searchTerm });
    } catch (e) {
        this.error = e.body?.message;
    }
}
```

---

### Q3: "How do components communicate?"

```
Parent → Child:    @api property  or  call @api method
Child → Parent:    CustomEvent (dispatchEvent)
Sibling → Sibling: CustomEvent with bubbles:true, or pubsub/LMS

// Child dispatches:
this.dispatchEvent(new CustomEvent('accountselected', {
    detail: { accountId: this.selectedId },
    bubbles: true,
    composed: false  // stops at Shadow DOM boundary
}));

// Parent listens (HTML):
<c-child onaccountselected={handleAccountSelected}></c-child>
```

---

### Q4: "@track vs @api vs reactive properties"

```javascript
// In modern LWC (API 39+):
// Primitive properties are ALWAYS reactive — no @track needed
searchTerm = '';      // reactive — re-renders when changed
isLoading  = false;   // reactive

// @track only needed for deep mutation of objects/arrays
@track accountData = { name: '', contacts: [] };
this.accountData.name = 'New'; // WITHOUT @track, this won't re-render in older API

// @api = public — set by parent component or App Builder
@api recordId;        // parent sets this
@api maxRecords = 10; // with default value

// NEVER mutate @api inside the child component — read-only contract
```

---

### Q5: "What is the Shadow DOM in LWC?"

- LWC uses **synthetic Shadow DOM** (or native in newer API versions)
- Styles in a component's CSS do NOT bleed into child components
- You cannot use `document.querySelector()` — use `this.template.querySelector()` instead
- `composed: false` on CustomEvent stops it at the Shadow boundary (default, recommended)
- `composed: true` lets it cross Shadow boundaries (use only when necessary)

---

### Q6: "What is a slot in LWC?"

```html
<!-- Child: myCard.html -->
<template>
    <lightning-card>
        <slot name="header">Default Header</slot>  <!-- named slot -->
        <slot></slot>                               <!-- default slot -->
    </lightning-card>
</template>

<!-- Parent: uses the slot -->
<c-my-card>
    <span slot="header">Custom Title</span>         <!-- fills named slot -->
    <p>This goes into the default slot</p>
</c-my-card>
```

Slots enable **compositional** component design — the child defines where, the parent defines what.

---

## Common Trick Questions

| Question | Pitfall | Correct Answer |
|----------|---------|----------------|
| "Can you DML inside a for loop?" | "No never" | Technically yes, but it consumes 1 DML statement per iteration — will hit 150 limit. Always collect and DML once. |
| "Can @future call another @future?" | "Yes" | No — you cannot invoke a `@future` from another `@future`. Use Queueable chaining instead. |
| "Can you use @wire with a non-cacheable method?" | "No" | Correct — `@wire` requires `@AuraEnabled(cacheable=true)`. |
| "Does `insert` in a test commit to DB?" | "Yes" | Yes — test DML is real and visible within the test transaction (rolled back after). |
| "What happens when you call `update` on a record in an after-trigger?" | "Infinite loop" | It fires triggers again — prevent with RecursionGuard or `TriggerHandlerBase.maxLoopCount`. |
| "Can a before-trigger make a callout?" | "Yes" | No — callouts are not allowed in before triggers (synchronous context). Use `@future(callout=true)` from an after-trigger. |

---

## Red Flags to Avoid

1. **SOQL / DML inside a loop** — immediate red flag for any senior role
2. **Trigger with business logic** — "One trigger, one handler"
3. `System.debug()` used for error handling — use proper logging
4. **Hardcoded Ids** — always use Labels, Custom Settings, or Custom Metadata
5. `without sharing` by default — start with `with sharing`, justify deviations
6. **`@future` when you need to pass objects** — use Queueable
7. **No test for governor limit edge cases** — shows lack of production experience
8. **`try { ... } catch(Exception e) {}` (swallowing exceptions)** — always log or rethrow

---

## Interview Tips

1. **"One trigger per object"** — always say this. Interviewers listen for it.

2. **Naming convention for handlers** — `{Object}TriggerHandler extends TriggerHandlerBase` — shows you've worked with a real framework.

3. **LWC lifecycle order** — `constructor → connectedCallback → render → renderedCallback`. Know this cold.

4. **Order of execution — two key facts**: (1) Workflow field updates re-trigger before/after triggers. (2) `@future` runs AFTER the DB commit (post-commit).

5. **`@wire` vs imperative trade-off** — `@wire` for read-on-load (automatic, cached), imperative for user-driven actions (controlled, can follow DML).

6. **SOQL injection prevention** — always prefer bind variables (`:varName`) over `String.escapeSingleQuotes()`. Bind vars are immune to injection by design.

7. **`Database.insert(list, false)` for bulk** — partial success is usually correct for integration batch jobs. All-or-nothing is correct for tightly related records.

8. **Shadow DOM boundary** — `composed: false` keeps events encapsulated. Only use `composed: true` when the event must cross component boundaries (e.g. Lightning Message Service is the alternative).

9. **RecursionGuard vs maxLoopCount** — Set-based guard is simpler but binary (once). Loop count allows exactly N passes (useful when workflow legitimately fires a trigger twice).

10. **Async pattern exam question**: "You need to call an external REST API for 5,000 Accounts nightly. What do you use?" → Schedulable calls Batch Apex (chunk 200), each batch makes callout with circuit breaker.
