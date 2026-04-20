# PwC Senior Associate — FSL + Agentforce + Lightning
## JD-Specific Interview Preparation Pack

**Role:** Senior Associate — Salesforce (FSL, Agentforce, Lightning)
**Company:** PwC India — Bangalore
**Prepared for:** Saikiran Pasumarthy | April 2026

---

## SECTION 1 — JD BREAKDOWN

### 1.1 Must-Have Skills (Eliminators)
If you cannot speak confidently to these, you will not pass the technical screen.

| # | Skill | What They're Testing |
|---|-------|---------------------|
| 1 | **Field Service Lightning (FSL)** — end-to-end configuration | Work Orders, Service Appointments, Scheduling Policies, Optimization, mobile briefcase |
| 2 | **LWC — Production-grade components** | Wire adapter, @api/@track, lifecycle hooks, LMS, mobile-responsive |
| 3 | **Apex — Complex business logic** | Bulkification, Queueable/Batch/Future, governor limits, DML in loops detection |
| 4 | **Agentforce / Einstein AI** | Topics, Actions, @InvocableMethod, difference from Einstein Bots |
| 5 | **Service Cloud** | Entitlements, Milestones, Omni-Channel routing, Case management |
| 6 | **Integration patterns** | REST/SOAP, Platform Events, CDC, idempotency, Queueable callout pattern |
| 7 | **Deployments** | sf CLI, scratch orgs, package development, delta deployment, CI/CD pipeline basics |

### 1.2 Differentiator Skills
These separate Senior Associate candidates from Associate-level. Demonstrate at least 3.

| # | Skill | How to Demonstrate |
|---|-------|-------------------|
| 1 | FSL **built from scratch** — not just configured | "At Concord Global, I designed the resource model, territory hierarchy, and scheduling policy before a single Service Appointment was created" |
| 2 | **Agentforce production experience** or deep conceptual architecture | Topic/Action hierarchy, how the reasoning engine selects actions, guardrails |
| 3 | **Performance-aware LWC** — virtual list, lazy loading, wire caching strategy | Quote concrete metrics: "Reduced dashboard load from 4.2s to 1.1s by switching to imperative Apex with client-side caching" |
| 4 | **Architecture decisions with trade-offs** | Platform Events vs CDC, Scheduled vs Triggered Optimization, Enhanced Scheduling vs Standard |
| 5 | **Client-side delivery mindset** | "The stakeholder needed this, so we balanced flexibility vs maintainability by…" |
| 6 | CI/CD with **FSL-specific metadata** in pipelines | Scheduling policies, service territories are difficult to deploy — explain your strategy |

### 1.3 PwC-Specific Interview Style

**What PwC looks for in Senior Associate interviews:**

1. **Structured answers (STAR + Client Context)** — PwC interviewers are trained to probe for consulting behaviors. Every technical answer should include a "client problem" framing, not just "I used Apex."

2. **"Why" before "How"** — PwC values consultants who explain the business driver before the technical solution. Lead with: "The client needed X, which drove us to choose Y over Z because…"

3. **Quantified impact** — Revenue saved, hours automated, percentage reduction in field ops costs. PwC's clients measure ROI. So should you.

4. **Risk awareness** — Mention what could go wrong and how you mitigated it. Shows senior-level thinking.

5. **Cross-cloud thinking** — PwC implementations rarely stop at one cloud. Mention integrations, data flows across Sales/Service/FSL/Agentforce.

6. **Humility + ownership split** — Own your decisions, acknowledge team contributions. "I designed the scheduling policy; the team validated with the dispatcher before we published."

**Typical PwC Interview Structure (60–90 min):**
- 10 min: Walk me through your background
- 25 min: Deep technical Q&A (expect follow-up probes)
- 20 min: Scenario/situational questions
- 10 min: Architecture discussion (whiteboard or verbal)
- 10 min: Your questions + culture/career fit
- 5 min: Close

**Red flags PwC screens for:**
- Vague answers ("I've worked with FSL") — always get specific
- No client framing — sounds like an internal IT developer, not a consultant
- Cannot explain trade-offs — shows shallow knowledge
- Overselling ("I built everything") — experienced interviewers probe immediately
- No questions at the end — signals low engagement

---

## SECTION 2 — CORE TECHNICAL Q&As

---

### 2.1 Apex (8 Questions)

---

**Q1. A trigger on WorkOrder fires and creates Service Appointments. The org has 500 work orders bulk-inserted via Data Loader. Walk me through how you ensure your trigger is governor-limit safe.**

**Answer:**
Bulkification starts at the trigger entry point. I write the trigger as a single-line delegator to a handler class — `new WorkOrderTriggerHandler().run()` — so logic never lives in the trigger file itself.

Inside the handler, I collect all Work Order IDs from `Trigger.new` into a Set, then perform one SOQL query to fetch related data. I never query inside a for loop. For the Service Appointment creation, I build a `List<ServiceAppointment>` inside the loop and call `insert saList` once after.

For 500 records, I also verify I'm not hitting the 150 DML statements limit. If each Work Order spawns 3 Service Appointments, that's one bulk insert of 1,500 records — one DML statement.

If the Work Order logic requires async processing (e.g., calling an optimization API), I enqueue a single Queueable job with the list of IDs, not one Queueable per record.

Governor limits I specifically track in bulk scenarios: 100 SOQL queries, 150 DML statements, 10 MB heap, 50,000 total SOQL rows.

---

**Q2. Explain the difference between Queueable, Future, and Batch Apex. When would you use each in a FSL context?**

**Answer:**
- **Future (@future):** Runs async, no chaining, no state, no monitoring. Use for simple one-off callouts from trigger context — e.g., notifying an external system when a Service Appointment status changes. Limitation: cannot be called from Batch.

- **Queueable:** Chainable, can hold object references (not just primitives), can be monitored via AsyncApexJob. Use in FSL when you need to call an optimization API after scheduling — you can chain jobs (fetch → transform → post). Also the standard pattern for making HTTP callouts with complex payloads.

- **Batch (Database.Batchable):** Designed for large data volumes. Runs in chunks (default 200 records). Use in FSL for nightly operations — e.g., closing overdue Service Appointments, bulk-reassigning territories after a resource deactivation. Combine with `Database.Stateful` when you need to accumulate results across batches for a finish-method summary email.

In FSL specifically: I use Queueable for real-time callouts triggered by Work Order creation, and Batch for bulk cleanup jobs run on a schedule.

---

**Q3. You have a service method that deducts loyalty points, creates a voucher, and updates the member balance. Three separate DML operations. How do you ensure atomicity?**

**Answer:**
Using a Savepoint. Before the first DML, I call `Database.setSavepoint()` and store the reference. All three DML operations run inside a try block. If any step throws a DmlException or custom exception, I call `Database.rollback(sp)` in the catch block, which reverts all DML to the savepoint — none of the three operations will have persisted.

Key nuance: Savepoints are scoped to the current transaction. If the method is called from a future or Queueable context, the savepoint works within that async transaction. However, if you call a method in a different transaction (chained Queueable), the savepoint from the parent doesn't carry over.

I also expose a typed result object from the method — not just a boolean — so callers can distinguish between "validation failed" (no rollback needed) and "partial DML failure" (rollback executed). This pattern also makes unit testing clean.

---

**Q4. What is the WITH SECURITY_ENFORCED clause and when would you use it over manual FLS checks?**

**Answer:**
`WITH SECURITY_ENFORCED` is appended to a SOQL query and tells the platform to throw a `QueryException` at runtime if the running user lacks read access to any field or object referenced in the query. It's declarative FLS enforcement — no manual `Schema.describeSObjects()` calls.

Use it in: Service classes running `with sharing` where you want a clean, readable FLS check without boilerplate describe calls. Good for Experience Cloud components where guest or community users access the data — you want a hard stop if their profile doesn't have access.

Limitation: It only covers the query's SELECT and WHERE clauses. It doesn't enforce FLS on fields you later write. For writes, you still need manual stripInaccessible or SecurityDecision API.

I typically use `WITH SECURITY_ENFORCED` for reads in utility services and manual stripInaccessible for mutation operations where partial field access is valid.

---

**Q5. How do you prevent recursive trigger execution in Salesforce? Show a pattern.**

**Answer:**
I use a static Boolean flag in a separate trigger context class:

```apex
public class TriggerContext {
    public static Boolean isExecuting = false;
}
```

In the trigger handler's entry point:
```apex
if (TriggerContext.isExecuting) return;
TriggerContext.isExecuting = true;
try {
    // logic
} finally {
    TriggerContext.isExecuting = false;
}
```

The `finally` block ensures the flag resets even if an exception is thrown, preventing the flag from being permanently stuck true for that transaction.

For more granular control (e.g., allowing a second execution for update triggers after insert side effects), I use a counter instead of a boolean: `public static Integer executionCount = 0;` and check `if (executionCount >= 1) return;`.

In FSL specifically, Work Order updates can trigger Service Appointment updates which re-fire Work Order triggers. This pattern is essential in that chain.

---

**Q6. Explain `with sharing` vs `without sharing` vs `inherited sharing`. When does each apply?**

**Answer:**
- **`with sharing`:** Enforces the running user's record-level sharing rules (OWD, role hierarchy, sharing rules, manual sharing). The user cannot access records they don't have sharing access to. Use for all user-facing service classes, LWC Apex controllers.

- **`without sharing`:** Ignores sharing rules entirely. Runs as if the code has system-level access. Use only for internal system processes — batch jobs, integration receivers, scheduled jobs — where there is no "user" context and the code intentionally needs to access all records.

- **`inherited sharing`:** The class adopts the sharing mode of its caller. If called from a `with sharing` class, it runs with sharing. If called from `without sharing`, it runs without. Use for utility/helper classes that should behave correctly regardless of context. This is the safest default for reusable library classes.

In PwC implementations, the pattern I follow: all LWC Apex controllers are `with sharing`, utility service classes are `inherited sharing`, batch/integration classes are `without sharing`.

---

**Q7. A client reports that a Scheduled Apex job is intermittently failing with "System.LimitException: Too many SOQL queries: 101". The job has run cleanly for 3 months. What's your investigation approach?**

**Answer:**
Intermittent limit exceptions after a stable period suggest data volume growth, not a code change. My investigation steps:

1. Pull the `AsyncApexJob` record for the failing executions — note the batch scope size and which batches failed (start/end vs middle batches).

2. Check if a new flow, process builder, or trigger was deployed in the last 3 months that fires on the same object. Each of those consumes SOQL queries within the same transaction, eroding the budget.

3. Examine the failing batch's data — is it a specific set of records (e.g., accounts with hundreds of child records) that triggers hidden SOQL via a formula field or cross-object lookup evaluation?

4. Add SOQL query count logging: `System.debug(Limits.getQueries() + '/' + Limits.getLimitQueries());` at key points in the execute() method.

5. If the trigger/flow interaction is confirmed, either: (a) rework the batch to exclude the objects being touched by the conflicting automation, (b) reduce the batch scope size so fewer records per execute, or (c) refactor to avoid the conflicting SOQL path.

Reducing scope size is the fastest short-term fix. The right long-term fix is eliminating the hidden SOQL source.

---

**Q8. How would you implement an idempotent REST API endpoint in Apex that receives field service job completion events from a third-party mobile app?**

**Answer:**
```apex
@RestResource(urlMapping='/fieldservice/complete/*')
global with sharing class JobCompletionReceiver {

    @HttpPost
    global static void handleCompletion() {
        RestRequest req = RestContext.request;
        Map<String, Object> body = (Map<String, Object>)
            JSON.deserializeUntyped(req.requestBody.toString());

        String externalJobId = (String) body.get('externalJobId');

        // Idempotency check — external ID unique constraint
        List<WorkOrder> existing = [
            SELECT Id FROM WorkOrder
            WHERE External_Job_Id__c = :externalJobId LIMIT 1
        ];
        if (!existing.isEmpty()) {
            RestContext.response.statusCode = 200;
            RestContext.response.responseBody = Blob.valueOf(
                JSON.serialize(new Map<String, String>{
                    'status' => 'already_processed',
                    'workOrderId' => existing[0].Id
                })
            );
            return;
        }

        // Process the completion
        // ...
    }
}
```

The external ID field has a `Unique` constraint at the field level, providing a database-layer safety net even if two concurrent requests pass the application-level check simultaneously. The endpoint returns 200 with `already_processed` for duplicates — not 4xx — because the caller's retry logic should treat it as success.

---

### 2.2 LWC (8 Questions)

---

**Q1. What is the difference between `@track`, `@api`, and reactive properties in LWC? Has anything changed about `@track` in recent API versions?**

**Answer:**
- **`@api`:** Exposes a property as a public attribute, settable by a parent component or from the metadata (xml config). Creates a one-way data binding from parent to child.
- **`@track`:** In older API versions (before Spring '20), it was required to make nested object/array mutations reactive. Without it, changing `this.obj.name` would not trigger a re-render.
- **Current behavior (API 39+ / Spring '20+):** All component properties are reactive by default. Object and array mutations are automatically tracked. `@track` is no longer needed for basic reactivity.

The only remaining use case for explicit `@track` today is to force deep observation of a specific property when you want to be explicit in code — but it's largely redundant.

A common senior-level nuance: directly replacing the object reference (`this.obj = { ...this.obj, name: 'new' }`) always triggers a re-render. Mutating a nested property (`this.obj.name = 'new'`) is reactive since Spring '20 but replacing the reference is the safer, more explicit pattern.

---

**Q2. Explain the LWC component lifecycle. In what order do the hooks fire for a parent-child component tree?**

**Answer:**
For a parent with two child components:

1. `constructor()` — parent (DOM node created, no child content yet)
2. `connectedCallback()` — parent (added to DOM)
3. `constructor()` — child 1, child 2 (in DOM order)
4. `connectedCallback()` — child 1, child 2
5. `renderedCallback()` — child 1, child 2 (children fully rendered first)
6. `renderedCallback()` — parent (last to complete rendering)

Key rules:
- `constructor()`: Never access child elements here. `this.template.querySelector` returns null.
- `connectedCallback()`: Safe to start data fetching. DOM not yet rendered.
- `renderedCallback()`: Safe to access the rendered DOM. Fires after every re-render, so guard imperative DOM operations with a flag (`if (this._initialized) return`).
- `disconnectedCallback()`: Clean up subscriptions, clear intervals, unsubscribe from LMS.
- `errorCallback(error, stack)`: Catches errors from child components — use it to render a graceful error state.

---

**Q3. How does the Lightning Message Service (LMS) work? When would you use it over a custom event?**

**Answer:**
LMS enables communication between components that don't share a parent-child relationship — across DOM trees, between LWC and Aura components, or between components in different regions of a Lightning App Page.

**How it works:**
1. Define a `MessageChannel` (messageChannel metadata file).
2. Publisher: imports `publish` and `MessageContext`, calls `publish(this.messageContext, CHANNEL, payload)`.
3. Subscriber: imports `subscribe`, `unsubscribe`, `MessageContext`, calls `subscribe()` in `connectedCallback()` and `unsubscribe()` in `disconnectedCallback()`.

**When to use LMS vs custom events:**
- **Custom event (bubbling):** When the communication is between a child and its ancestor in the same component tree. Simpler, no metadata required.
- **LMS:** When components are siblings on a page with no common ancestor, or when communicating across Aura/LWC boundaries, or when you need to publish from a utility class rather than a component.

In FSL dashboards, I used LMS to let a "Dispatcher Map" component broadcast the selected territory, and a "Service Resource List" component subscribe — they had no parent-child relationship in the App Page layout.

---

**Q4. A manager reports that a promotionBanner LWC is causing memory leaks in Experience Cloud. What would you check?**

**Answer:**
The most common LWC memory leaks stem from:

1. **`setInterval` / `setTimeout` not cleared in `disconnectedCallback()`:** If the component starts an interval in `connectedCallback()` but doesn't clear it when the component unmounts, the callback keeps firing and holds a reference to the component instance. Fix: store the interval ID in `this._intervalId` and call `clearInterval(this._intervalId)` in `disconnectedCallback()`.

2. **LMS subscriptions not unsubscribed:** If the component subscribes to a message channel but doesn't call `unsubscribe()` in `disconnectedCallback()`, the subscription — and the component reference — stays in memory.

3. **Event listeners added via `addEventListener` on the window or document:** These are not auto-cleaned by the LWC framework. Must be explicitly removed.

4. **Wire result objects held in `@track` properties:** These hold the full wire result including metadata. If the component stores large datasets and the reference isn't cleared on unmount, the GC can't collect them.

In the `promotionBanner` component I built, the `setInterval` auto-refresh fires every 5 minutes. The `disconnectedCallback()` explicitly clears the interval — this is the exact pattern to cite.

---

**Q5. How do you communicate from a child LWC back to its parent? Describe the event pattern with code.**

**Answer:**
Child components dispatch custom events that bubble up to the parent. The child dispatches, the parent listens with an `on<eventname>` handler.

**Child component:**
```javascript
// In child JS
handleSelect(event) {
    const selectedId = event.currentTarget.dataset.id;
    this.dispatchEvent(new CustomEvent('resourceselect', {
        detail: { resourceId: selectedId },
        bubbles: true,   // propagates up the DOM
        composed: false  // stays within the shadow DOM boundary
    }));
}
```

**Parent template:**
```html
<c-service-resource-list onresourceselect={handleResourceSelect}></c-service-resource-list>
```

**Parent JS:**
```javascript
handleResourceSelect(event) {
    const resourceId = event.detail.resourceId;
    // Update parent state
}
```

Key notes: `bubbles: true` allows the event to propagate through ancestor components. `composed: true` allows it to cross shadow DOM boundaries. For most LWC-to-LWC communication within the same tree, `composed: false` is correct — you don't want events leaking into the global DOM.

---

**Q6. What is the difference between `wire` (declarative) and imperative Apex calls in LWC? When do you choose each?**

**Answer:**
- **Wire (declarative):** The framework calls the Apex method automatically when the component loads and whenever reactive properties used as parameters change. Results are cached. Re-calls happen automatically on parameter change. Best for read-heavy data that should refresh when inputs change — e.g., loading member tier data when `memberId` changes.

- **Imperative:** You call the Apex method yourself using `import ... from '@salesforce/apex/...'` and call it inside a function. No automatic caching. Full control over when the call fires. Best for: user-triggered actions (form submit, button click), conditional fetching, when you need to handle the promise chain explicitly (loading states, error handling UI).

Wire limitation: You can't use `refreshApex()` on an imperatively-called Apex result. `refreshApex()` only works on wire results. If you need manual refresh with wire, you store `this._wiredResult = result` in the wire handler and pass that to `refreshApex()`.

In the `promotionBanner` component: wire used for initial load and periodic refresh via `refreshApex`. In `memberDashboard`: imperative call in `connectedCallback()` because the loading state needs explicit management.

---

**Q7. How would you build an FSL mobile-optimized Service Appointment card component in LWC? What considerations apply?**

**Answer:**
Key considerations for FSL mobile LWC:

1. **Offline-first data access:** On the FSL mobile app, components run inside the Briefcase context. Query data must be pre-synced to the mobile device. LWC components in FSL mobile cannot make live Apex callouts unless the device is online. Design components to read from cached wire data.

2. **Screen real estate:** Mobile cards should use `slds-card` or a custom compact layout — no wide data tables. Show priority fields: appointment window, address, Work Type, Status. Secondary info behind an expandable section.

3. **Touch targets:** Buttons must be at least 44×44px. Use `slds-button` for FSL action buttons (Start, Complete, On My Way).

4. **Offline actions:** For offline completion flows, use FSL Mobile Extensions API — the component can queue actions that sync when connectivity is restored. This is done via `lightning/mobileCapabilities` and the FSL Mobile SDK.

5. **Status transitions:** Dispatch a `lightning__recordEditForm` or a custom event to trigger the Work Order status update. Guard against double-tap submissions with a `_submitting` flag.

6. **Responsive CSS:** Use CSS Grid with `@media (max-width: 480px)` breakpoints to collapse multi-column layouts to single-column.

---

**Q8. What is the Shadow DOM in LWC and why does it matter for CSS styling?**

**Answer:**
LWC uses the Shadow DOM to encapsulate component markup and styles. Each component's CSS is scoped to its own shadow tree — styles defined in `componentA.css` do not leak into child component `componentB` or into the global page.

This means:
- **You cannot style child component internals from the parent.** A parent cannot write `.child-class { color: red; }` and have it affect a child component's internal elements.
- **Global SLDS classes work** because they're injected into the document-level stylesheet, which all shadow roots inherit via CSS custom properties (CSS variables).
- **For theming across components:** Use CSS custom properties (variables). The parent defines `--brand-color: #0070d2;` and the child consumes `color: var(--brand-color)`.
- **For styling slotted content:** Content passed via `<slot>` is styled by the component that owns the content (the light DOM), not the host component.

In Experience Cloud, the Salesforce Shadow DOM is "synthetic" (not native browser Shadow DOM) for backward compatibility, which means some CSS selectors behave differently. `:host` and `:host-context()` work, but deep selectors like `>>>` do not.

---

### 2.3 Field Service Lightning — Priority Section (12 Questions)

---

**Q1. Explain the FSL object model. What are the core standard objects and how do they relate?**

**Answer:**
The FSL object model has four primary layers:

**Work layer:**
- **WorkOrder:** The unit of work. Contains the customer problem, required skills, estimated duration, priority.
- **WorkOrderLineItem:** Sub-tasks within a Work Order. Each can map to a separate Service Appointment.

**Scheduling layer:**
- **ServiceAppointment:** The scheduled instance of work. Has Subject, Arrival Window (ArrivalWindowStartTime, ArrivalWindowEndTime), SchedStartTime, SchedEndTime, Duration, Status, and the parent WorkOrder/WorkOrderLineItem reference.
- **AssignedResource:** Junction object linking a ServiceAppointment to a ServiceResource. One ServiceAppointment can have multiple AssignedResources (crew jobs).

**Resource layer:**
- **ServiceResource:** Represents a technician or crew. Has IsActive, ResourceType (Technician, Crew, Capacity). Links to a User record for authentication.
- **ServiceResourceSkill:** Links a ServiceResource to a Skill with a proficiency level and date range. Used for skill-based appointment matching.
- **ServiceTerritory:** Geographic or organizational region. ServiceResources are members of territories via ServiceTerritoryMember.
- **ServiceTerritoryMember:** Links a resource to a territory with a role (Primary, Relocation) and working hours.

**Supporting objects:**
- **Skill:** Master data — the types of skills (e.g., HVAC Certified, Electrical).
- **WorkType:** Template for work — default duration, required skills, auto-generated Work Order Line Items.
- **OperatingHours:** Business hours for territories and resources.

---

**Q2. What is a Scheduling Policy in FSL and what are its key components?**

**Answer:**
A Scheduling Policy is a named set of rules that governs how FSL scores and selects service resources for appointments. It's the brain of the optimization process.

**Components of a Scheduling Policy:**
1. **Work Rules:** Conditions that filter out ineligible appointments or resources. Examples: "Only schedule within business hours", "Skill required", "Resource must be in service territory", "Respect preferred resource". Work Rules are either *hard* (violation = excluded from consideration) or *soft* (violation = point deduction in score).

2. **Service Objectives:** Point-based scoring criteria that rank eligible resources. Examples: "Minimize travel time" (+50 points for 0–5 min travel), "Maximize utilization" (+30 for fully booked resources), "Customer first choice" (+100 if the technician is the preferred resource).

3. **Operating Hours:** The policy can reference a specific set of operating hours, determining when scheduling is allowed to occur.

4. **Scheduling Mode:** Defines behavior for the "Schedule" button — Automatic, Override, or User-Defined time.

When a dispatcher clicks "Schedule" on a Service Appointment, FSL evaluates all available resources against the Work Rules (hard filter), then scores remaining candidates against Service Objectives, and assigns the highest scorer.

In my FSL build at Concord Global, I created a custom Scheduling Policy with three Service Objectives: minimize travel distance (highest weight), skill proficiency level match, and availability window fit.

---

**Q3. What is the difference between Appointment Booking, Enhanced Scheduling, and FSL Optimization? When would you use each?**

**Answer:**

| Feature | Appointment Booking | Enhanced Scheduling | FSL Optimization |
|---------|---------------------|--------------------|-----------------------|
| **Who triggers it** | Customer (self-service) | Dispatcher or automation | Background batch or on-demand |
| **Input** | Customer's preferred time slots | Single appointment | All unscheduled appointments in a territory |
| **Output** | Available time slots shown to customer | Best available resource assigned | Fully optimized schedule for all resources |
| **Performance** | Real-time | Near real-time | Runs as async job |
| **License required** | FSL Scheduling + Appointment Booking | FSL Scheduling | FSL Optimization |
| **Use case** | Field service + customer portal bookings | Dispatcher console | Nightly re-optimization of technician routes |

**When to use:**
- **Appointment Booking:** When customers self-schedule via Experience Cloud or a third-party portal. The API returns available time windows respecting the scheduling policy.
- **Enhanced Scheduling:** When a CSR or dispatcher is creating an appointment and needs a smart resource suggestion without triggering full optimization.
- **Optimization:** When you want to minimize total travel time across 50+ technicians in a region — typically run overnight or triggered after a large batch of new appointments comes in.

---

**Q4. A Service Appointment is created but not being auto-scheduled. What would you check?**

**Answer:**
Systematic check list:

1. **Scheduling Policy:** Is there an active Scheduling Policy set on the service territory? Without it, FSL has no rules to evaluate.

2. **Service Territory:** Is the Work Order/Service Appointment associated with a Service Territory? Check the `ServiceTerritoryId` on the Work Order and `ServiceTerritoryId` on the ServiceAppointment.

3. **Service Resources:** Are there active ServiceResources that are members of the Service Territory? Check ServiceTerritoryMember records — are they active, in the correct territory, and within the relevant operating hours?

4. **Skills:** Does the ServiceAppointment require skills (via WorkType → Required Skills)? Do the available resources have those skills via ServiceResourceSkill?

5. **Operating Hours:** Is the appointment's requested time window within the territory's OperatingHours?

6. **Work Rules:** Is there a hard Work Rule being violated? Navigate to the Scheduling Policy → Work Rules tab and look for hard rules that might eliminate all resources.

7. **Optimization Settings:** If using auto-scheduling via the Optimization engine, is the optimization job running? Is the territory included in the optimization territory?

8. **Debug logs / FSL Scheduler logs:** Enable FSL Scheduler debug logs from Setup → Field Service → Scheduler Logs. These show exactly why each resource was eliminated.

---

**Q5. How does the FSL mobile app work offline? What data is available and what isn't?**

**Answer:**
FSL mobile uses a **Briefcase** mechanism for offline data access. Before going offline, the mobile app syncs a predefined set of records to the device's local SQLite database.

**What's in the Briefcase (configurable):**
- Assigned Service Appointments (today's and future)
- Related Work Orders and Work Order Line Items
- Service Resources (technician's own record)
- Products (for parts/inventory lookup)
- Knowledge articles (linked to Work Types)
- Custom objects added by the FSL admin via Briefcase configuration

**What's NOT available offline:**
- Records not in the Briefcase scope (e.g., unassigned appointments, accounts not linked to current appointments)
- Apex callouts (network-dependent)
- Flow interviews that call Apex
- Reports and dashboards

**Offline actions:**
When a technician performs an action offline (update appointment status, complete a Work Order checklist, capture a signature), the changes are queued in the device's local store. When connectivity is restored, FSL syncs changes back to Salesforce using conflict resolution rules.

**Conflict resolution:** Last-write-wins by default, but the admin can configure conflict handlers. If a dispatcher updated the same appointment while the technician was offline, FSL will flag the conflict.

For custom LWC components in FSL mobile, you use the `lightning/mobileCapabilities` module and design components to gracefully degrade when offline — read from cached wire data, queue mutations for sync.

---

**Q6. A client wants to assign Work Orders to technicians based on skill level (e.g., only "Expert"-rated electricians for high-voltage jobs). How do you implement this in FSL?**

**Answer:**
This is implemented through the **Skills** framework in FSL:

**Step 1: Define Skill records** — Create Skill records for each technical capability: "Electrical", "HVAC", "Plumbing".

**Step 2: Create skill proficiency tiers** — FSL supports skill levels via the `ServiceResourceSkill.SkillLevel` picklist. Configure values: Beginner (1), Intermediate (5), Expert (10).

**Step 3: Assign skills to resources** — Create `ServiceResourceSkill` records linking each `ServiceResource` to the relevant `Skill` with the appropriate `SkillLevel` and effective date range.

**Step 4: Define Required Skills on Work Types** — On the `WorkType` for "High-Voltage Electrical", add a Required Skill: Skill = "Electrical", Minimum Skill Level = 10 (Expert).

**Step 5: Configure the Scheduling Policy Work Rule** — Add the "Match Skills" Work Rule to the Scheduling Policy. Set it as a **hard** rule so that any resource without the required skill at the required level is automatically excluded from scheduling.

**Step 6: Validation** — When a Work Order is created with the "High-Voltage Electrical" Work Type, the skill requirement propagates to the Service Appointment. The scheduler will only offer Expert-level electricians.

---

**Q7. How would you expose FSL appointment availability to an external customer portal (e.g., a React website)?**

**Answer:**
FSL provides the **Appointment Booking** REST API for this use case. The external portal calls Salesforce APIs to get available slots and book appointments.

**Flow:**
1. **Fetch available time slots:** External system calls the FSL `getAvailableTimeSlots` Appointment Booking API endpoint, passing: Work Type, Service Territory, appointment window, scheduling policy, and any preference parameters (preferred resource, preferred time of day).

2. **Display slots to customer:** The portal renders the returned time windows.

3. **Book the appointment:** Customer selects a slot. Portal calls the booking API with the chosen slot, which creates the `ServiceAppointment` and assigns the resource.

**Authentication:** The external portal authenticates via Connected App using OAuth 2.0 (JWT Bearer flow for server-to-server, or Auth Code flow for user-facing).

**Custom Apex wrapper approach (if more control needed):** Instead of calling FSL APIs directly, expose a custom `@RestResource` Apex endpoint that internally calls `FSL.AppointmentBookingService.getSlots()` with the scheduling policy name and returns a simplified JSON payload to the portal.

I used this wrapper approach at a client — the external system was a legacy ASP.NET portal that couldn't handle FSL's full API response schema. The Apex wrapper translated and simplified the payload.

---

**Q8. What is an Optimization Request in FSL? How do you trigger and monitor it programmatically?**

**Answer:**
An Optimization Request is a job submitted to the FSL Optimization Engine to reschedule all unscheduled (and optionally scheduled) Service Appointments in a territory, minimizing total travel time and maximizing policy compliance.

**Object:** `FSL__Optimization_Request__c` (custom object installed with FSL managed package).

**Triggering programmatically:**
```apex
FSL__Optimization_Request__c optRequest = new FSL__Optimization_Request__c();
optRequest.FSL__Optimization_Type__c = 'Group';
optRequest.FSL__Territory__c = territory.Id;
optRequest.FSL__Scheduling_Policy__c = policy.Id;
optRequest.FSL__From_Date__c = Date.today();
optRequest.FSL__To_Date__c = Date.today().addDays(7);
optRequest.FSL__Include_All_Appointments__c = false; // only unscheduled
insert optRequest;
```

**Monitoring:** The `FSL__Optimization_Request__c` record's `FSL__Status__c` field transitions through: `New` → `In Progress` → `Completed` / `Failed`. You can poll this via a scheduled Apex job or set up a Platform Event trigger to notify when optimization completes.

**Post-optimization:** When optimization completes, the Service Appointments' `SchedStartTime`, `SchedEndTime`, and `AssignedResource` records are updated. A dispatcher can review the proposed schedule before publishing it.

---

**Q9. A dispatcher reports that FSL is creating Service Appointments with overlapping schedules for the same technician. What do you investigate?**

**Answer:**
Overlapping appointments indicate the scheduling engine isn't enforcing availability correctly. Investigation:

1. **Check the Scheduling Policy Work Rules:** Is the "Match Working Hours" rule present and set as hard? Is the "Exclude Lunch" or "Avoid Overtime" rule active? Overlap can happen if availability work rules are missing or set to soft.

2. **ServiceTerritoryMember Operating Hours:** Does the technician's ServiceTerritoryMember record have the correct `OperatingHoursId`? If null or set to 24/7, the scheduler won't see gaps.

3. **Absence records (ResourceAbsence):** Are there `ResourceAbsence` records for the overlapping period? If not, the scheduler doesn't know the technician is unavailable.

4. **Manual scheduling override:** If a dispatcher used "Drag and Drop" scheduling in the Gantt, it bypasses the Scheduling Policy. Check the `ServiceAppointment.IsAnonymous` flag and the dispatch log.

5. **Concurrent optimization runs:** If two optimization jobs ran simultaneously, they could have each assigned the same technician to different appointments without seeing each other's in-progress assignments. This is a known edge case — use the FSL optimization locking mechanism.

6. **Crew scheduling:** If `AssignedResource` has multiple records per appointment (crew), verify that crew-level capacity isn't being double-counted.

---

**Q10. How do you deploy FSL configuration (Scheduling Policies, Service Territories) to a new org via CI/CD?**

**Answer:**
FSL configuration deployment is more complex than standard metadata because much of it lives in data records (not metadata XML).

**What can be deployed as metadata:**
- FSL permission set assignments
- Custom fields on FSL objects
- Flows and Process Builders that automate FSL actions
- Custom LWC components for FSL mobile
- Custom reports/dashboards for FSL

**What must be deployed as data (scripts/tooling):**
- `ServiceTerritory` records
- `Skill` records
- `WorkType` records
- `OperatingHours` records
- `FSL__Scheduling_Policy__c` records (and their child Work Rules, Service Objectives)
- `FSL__Service_Goal__c` records

**Approach for CI/CD:**
1. Export FSL configuration data from the source org using the `sfdataloader` or `sf data export` commands into JSON/CSV.
2. Version-control these seed data files in the repo.
3. In the deployment pipeline, run `sf data import` as a post-deploy step to upsert the configuration records using external IDs.
4. For scheduling policies, I create a custom `External_ID__c` field on `FSL__Scheduling_Policy__c` for idempotent upsert.
5. Validate in a CI scratch org using a pre-populated dataset before promoting to staging.

This is a critical topic in PwC FSL implementations — the lack of standard metadata support for FSL config records is a common project pain point.

---

**Q11. Explain the difference between "Scheduled" and "Dispatched" and "In Progress" Service Appointment statuses. What triggers each?**

**Answer:**
FSL uses a configurable status lifecycle, but the standard progression is:

| Status | Meaning | Typical Trigger |
|--------|---------|----------------|
| **None / Unscheduled** | SA created, no resource assigned | SA record creation |
| **Scheduled** | Resource assigned, time slot confirmed | Dispatcher schedules or optimization assigns |
| **Dispatched** | Technician notified — appointment pushed to mobile | "Dispatch" action clicked, or auto-dispatch rule |
| **In Progress** | Technician has started work on-site | Technician taps "Start" in FSL mobile app |
| **Completed** | Work done | Technician taps "Complete" in FSL mobile app |
| **Cannot Complete** | Technician arrived but couldn't finish (access denied, part missing) | Technician action in mobile app |

**Dispatch vs Schedule distinction:** A "Scheduled" appointment exists in the system but the technician hasn't been notified. "Dispatched" means the appointment was pushed to the technician's mobile device. This distinction matters for last-minute reassignments — you can reschedule a "Scheduled" appointment without the technician knowing, but rescheduling a "Dispatched" appointment requires notifying them.

**Automation options:** Auto-dispatch rules in FSL can automatically move appointments from "Scheduled" to "Dispatched" when the appointment window opens, eliminating the manual dispatcher step.

---

**Q12. A large enterprise client wants real-time updates when a technician's location changes (GPS). How do you architect this in FSL?**

**Answer:**
FSL has a built-in geolocation tracking mechanism, but for real-time enterprise-grade tracking:

**Standard FSL Approach:**
- Enable "Location Tracking" on the FSL Settings. The mobile app periodically sends `ServiceResource.Latitude/Longitude` updates.
- The Gantt map in the dispatcher console refreshes to show technician positions.
- Limitation: The polling interval is configurable but not true real-time (typically 30–60 seconds).

**Real-time architecture for enterprise requirements:**
1. **FSL Mobile SDK + Platform Events:** Configure the mobile app to emit a Platform Event (`Technician_Location__e`) every 15 seconds with the technician's GPS coordinates. A custom Process or Apex trigger on the platform event updates a `Technician_GPS__c` custom object.

2. **Streaming API (CometD/SSE):** The dispatcher console's LWC component subscribes to the `Technician_Location__e` Platform Event via the Streaming API and updates the map marker in real time.

3. **Experience Cloud map component:** Use `lightning-map` or a custom Mapbox/Google Maps integration. The LWC subscribes to the streaming channel and re-renders pins as events arrive.

4. **ETA calculation:** As technicians move, trigger a Queueable Apex job to recalculate ETAs for upcoming appointments using the Google Maps Distance Matrix API.

This architecture was relevant at a client with 200 field technicians — the standard FSL polling was too slow for their SLA dashboard requirements.

---

### 2.4 Service Cloud & Agentforce (8 Questions)

---

**Q1. How does Omni-Channel work in Salesforce? What is the difference between routing models?**

**Answer:**
Omni-Channel routes work items (Cases, Leads, custom objects) to agents based on capacity, skills, and priority.

**Routing Models:**

1. **Queue-Based Routing:** Items are placed in a queue. Omni-Channel pulls from the queue and assigns to the next available agent with capacity. Simple, no skill matching.

2. **Skills-Based Routing:** Items are tagged with required skills. Omni-Channel matches items to agents who have those skills. Skills are defined on Agent Work records and ServiceChannel configurations.

3. **External Routing:** Third-party telephony/messaging systems (Genesys, Five9) integrate with Omni-Channel. The external system makes routing decisions; Omni-Channel manages the agent presence state. Uses `connect/omniChannel` REST API.

**Key objects:** `AgentWork` (assigned item), `UserServicePresence` (agent availability), `ServiceChannel` (channel config), `RoutingConfiguration` (capacity and priority rules).

**Supervisor features:** Omni Supervisor tab shows real-time queue depth, agent capacity utilization, and allows supervisors to reassign work items.

---

**Q2. What are Entitlements and Milestones? How do you configure SLA enforcement?**

**Answer:**
- **Entitlements:** Contractual service agreements. They define what a customer is entitled to — e.g., "Gold Support: 4-hour response time, 24/7 availability." An Entitlement is linked to an Account, Asset, or Contact.

- **Milestones:** Specific steps within an Entitlement that must be completed within time limits. E.g., "First Response: 1 hour", "Resolution: 8 hours."

- **Entitlement Process:** A template that defines the ordered set of Milestones for a service tier. When a Case is created and matched to an Entitlement, the Entitlement Process kicks in — Milestones are created on the Case with calculated due dates.

**SLA violation workflow:**
1. A Milestone's `TargetDate` passes without completion → the Milestone's `IsViolated` flag becomes true.
2. Milestone triggers can fire Process Builder/Flow actions: escalate the Case, notify a supervisor, change Case priority.
3. Warning criteria can fire 30 minutes before the deadline.

**In an FSL context:** Entitlements integrate with Work Orders. A Work Order can inherit an Entitlement from its parent Case, ensuring that field service SLAs (e.g., "on-site within 4 hours") are tracked through Milestones.

---

**Q3. What is Agentforce? How is it different from Einstein Bots?**

**Answer:**
**Einstein Bots (legacy):** Rule-based or NLU-powered chatbots. They follow decision-tree or intent-classification logic. Good for structured FAQs, simple deflection flows. Limited reasoning capability — they match user input to predefined intents.

**Agentforce (current generation):** A reasoning engine powered by LLMs (Claude from Anthropic). Instead of following a decision tree, Agentforce interprets the user's goal, selects from a library of Actions, executes them in sequence, and generates natural language responses. It can handle multi-step, ambiguous requests.

**Key architectural differences:**

| Dimension | Einstein Bots | Agentforce |
|-----------|--------------|------------|
| Logic model | Rule-based / intent classification | LLM reasoning engine |
| Customization unit | Dialog flows | Topics + Actions |
| Apex integration | Apex-invocable actions in flows | `@InvocableMethod` Actions |
| Context window | Limited to conversation slot variables | Full conversation context + retrieval |
| Data grounding | Manual variable mapping | Retrieval-augmented (Data Cloud, Knowledge) |

**Topics:** Classify the user's intent category — e.g., "Check Order Status", "Request Field Service".
**Actions:** Specific capabilities the agent can invoke — e.g., "Get Order Details" (calls Apex), "Create Work Order" (calls Flow).

---

**Q4. How do you create a custom Agentforce Action that creates a Work Order from a customer chat?**

**Answer:**
Custom Agentforce Actions are created via `@InvocableMethod` in Apex or via Flow.

**Apex approach:**
```apex
public class CreateWorkOrderAction {

    public class ActionInput {
        @InvocableVariable(label='Account Id' required=true)
        public String accountId;

        @InvocableVariable(label='Work Type Name' required=true)
        public String workTypeName;

        @InvocableVariable(label='Problem Description' required=true)
        public String description;
    }

    public class ActionOutput {
        @InvocableVariable(label='Work Order Id')
        public String workOrderId;

        @InvocableVariable(label='Status Message')
        public String statusMessage;
    }

    @InvocableMethod(
        label='Create Work Order'
        description='Creates a new Work Order for field service dispatch'
        category='Field Service'
    )
    public static List<ActionOutput> createWorkOrder(List<ActionInput> inputs) {
        List<ActionOutput> results = new List<ActionOutput>();
        for (ActionInput input : inputs) {
            WorkOrder wo = new WorkOrder(
                AccountId = input.accountId,
                Description = input.description,
                Status = 'New'
            );
            insert wo;
            ActionOutput out = new ActionOutput();
            out.workOrderId = wo.Id;
            out.statusMessage = 'Work order created successfully.';
            results.add(out);
        }
        return results;
    }
}
```

**In Agentforce Setup:**
1. Navigate to Agent Actions → New Action → Type: Apex.
2. Select the `CreateWorkOrderAction` method.
3. Map input/output variables.
4. Add the Action to a Topic (e.g., "Field Service Requests").
5. The agent's reasoning engine will invoke this action when it determines the customer wants to create a service request.

---

**Q5. What are Agentforce Topics and how do they control what the agent can do?**

**Answer:**
Topics are the intent-classification layer in Agentforce. Each Topic defines:

1. **Scope:** A natural language description of what the topic covers. The LLM reasoning engine uses this to determine which Topic applies to the current conversation turn.

2. **Instructions:** Guidance for how the agent should behave within this topic — tone, constraints, escalation conditions.

3. **Actions:** The set of Apex, Flow, or Prompt Template actions that are available when this topic is active.

**Example:**
- Topic: "Service Appointment Management"
- Scope description: "Handle requests to check, reschedule, or cancel field service appointments"
- Instructions: "Always confirm the appointment details before any modification. If the appointment is within 2 hours, escalate to a human agent."
- Actions: GetAppointmentDetails, RescheduleAppointment, CancelAppointment, TransferToHuman

**Guardrails:** Topics act as guardrails. The agent can only invoke Actions associated with its active Topic. This prevents the agent from, say, running a billing action during a field service conversation.

**Multi-topic:** An agent can have multiple Topics. The reasoning engine selects the appropriate Topic based on the user's message, then applies that Topic's instructions and actions for subsequent turns.

---

**Q6. How does Agentforce ground its responses with real Salesforce data?**

**Answer:**
Agentforce uses retrieval-augmented generation (RAG) to ground responses in real data rather than relying solely on the LLM's training knowledge.

**Grounding mechanisms:**

1. **Salesforce Actions (Apex/Flow):** The agent invokes an action to fetch live data — e.g., "Get Account Balance" → returns current balance from a SOQL query → agent incorporates that value in its response. This is the primary grounding mechanism for transactional data.

2. **Knowledge Articles:** Agentforce can search Knowledge via a built-in retrieval action. When a customer asks a technical question, the agent queries the org's Knowledge base and synthesizes a response from matching articles.

3. **Data Cloud (Unified Profile):** If the org uses Data Cloud, Agentforce can retrieve a unified customer profile — combining CRM data, engagement data, and external sources — to personalize responses.

4. **Prompt Templates:** Admins create Prompt Templates that inject dynamic Salesforce field values (via merge fields) into the LLM prompt, ensuring the model sees live CRM data as context.

**What grounding prevents:** Hallucination. Without grounding, the LLM might fabricate appointment details, account balances, or policy information. Grounded actions return authoritative data that the LLM presents verbatim.

---

**Q7. A customer service agent using Agentforce reports that the AI is giving incorrect refund policy answers. How do you investigate and fix this?**

**Answer:**
Incorrect policy answers typically mean the grounding source is wrong, outdated, or missing. Investigation steps:

1. **Identify the grounding source:** Is the agent pulling from Knowledge Articles, a Prompt Template, or relying on the base LLM? Navigate to the Topic configuration and check which Actions are available for refund-related intents.

2. **Check Knowledge Article content:** If Knowledge is the source, search for the refund policy article. Is it published and indexed? Is it up to date? Is it tagged with the correct data categories for retrieval?

3. **Review Prompt Template:** If a Prompt Template is used, check the system prompt and context injection. Is the refund policy explicitly stated? Are merge fields pulling the correct policy fields?

4. **Agentforce Testing:** Use the Agentforce testing panel in Setup to run test conversations. Review the agent's reasoning trace — which action did it invoke? What data did it retrieve? What did it pass to the LLM?

5. **Einstein Trust Layer audit:** Check audit logs for the conversation. The Trust Layer logs prompt content and responses — you can see exactly what the LLM was given and what it generated.

**Fix:** Update the Knowledge Article or Prompt Template with correct policy language. If the LLM is over-riding grounded data with its training knowledge, add an explicit instruction to the Topic: "Only use information from retrieved Knowledge Articles for policy questions. Do not generate policy details from memory."

---

**Q8. How does Service Cloud Voice integrate with Agentforce?**

**Answer:**
Service Cloud Voice brings telephony into the Salesforce agent console, and Agentforce augments it with real-time AI assistance.

**Architecture:**
- **Service Cloud Voice:** Telephony partner (Amazon Connect, Genesys, etc.) is integrated via Open CTI or a native voice connector. Phone calls appear as `VoiceCall` records. Real-time transcription generates a running transcript.

- **Agentforce Real-Time:** During a live call, Agentforce processes the transcript in near-real-time. It surfaces:
  - **Next Best Action:** Suggested responses based on what the customer is saying.
  - **Automatic Knowledge:** Relevant Knowledge Articles surfaced mid-call.
  - **After-Call Summary:** Auto-generated case summary and action items from the call transcript.

- **Einstein Conversation Insights:** Post-call, identifies keywords, compliance flags, and sentiment trends across all calls.

**Agentforce in voice vs chat:** In voice, Agentforce assists the human agent (it doesn't replace them on phone). In chat/messaging, Agentforce can be fully autonomous (self-service bot) or assist the human agent.

---

### 2.5 Integrations (6 Questions)

---

**Q1. Why can't you make HTTP callouts from a trigger? What's the correct pattern?**

**Answer:**
Salesforce prohibits HTTP callouts directly from synchronous trigger context because triggers run within a database transaction. An HTTP callout could take seconds or minutes to respond, holding the database transaction open and blocking row locks — this would severely degrade performance and risk hitting the 120-second transaction limit.

**Correct pattern — Queueable Apex:**
```apex
// In the trigger handler
Set<Id> woIds = new Map<Id, WorkOrder>(Trigger.new).keySet();
System.enqueueJob(new ExternalSystemNotifier(woIds));
```

```apex
public class ExternalSystemNotifier implements Queueable, Database.AllowsCallouts {
    private Set<Id> workOrderIds;

    public ExternalSystemNotifier(Set<Id> ids) {
        this.workOrderIds = ids;
    }

    public void execute(QueueableContext ctx) {
        List<WorkOrder> orders = [SELECT Id, Status, AccountId
            FROM WorkOrder WHERE Id IN :workOrderIds];
        // Build HTTP request and call external system
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:ExternalSystem/workorders');
        req.setMethod('POST');
        req.setBody(JSON.serialize(orders));
        new Http().send(req);
    }
}
```

The `Database.AllowsCallouts` interface marker tells Salesforce this Queueable is authorized to make HTTP callouts. The `callout:` prefix references a Named Credential, avoiding hard-coded endpoints and credentials.

---

**Q2. What is the difference between Platform Events and Change Data Capture (CDC)? When do you use each?**

**Answer:**

| Dimension | Platform Events | Change Data Capture (CDC) |
|-----------|----------------|--------------------------|
| **What fires it** | `EventBus.publish()` in Apex, Flow, or external API | Automatic — any DML on configured objects |
| **Who controls it** | Developer (you publish explicitly) | Platform (automatic) |
| **Payload** | Custom fields defined on the event | Full diff of changed fields + header metadata |
| **Retention** | 72 hours | 3 days (up to 72 hours configurable) |
| **Use case** | Application-to-application messaging, workflow triggers | External system data sync, real-time replication |
| **Ordering guarantee** | Replay ID-based ordering | ReplayId-based, includes sequence headers |

**When to use Platform Events:**
- Triggering actions when a specific business event occurs (e.g., "Order Shipped Event" → notify FSL to create a Work Order).
- Decoupling components in an event-driven architecture.
- Sending notifications from Batch Apex without risking DML limits.

**When to use CDC:**
- Syncing Salesforce data changes to an external data warehouse (Snowflake, BigQuery) in near-real-time.
- Replicating Account/Contact changes to a downstream CRM.
- Building audit trails — CDC provides exact field-level diffs.

---

**Q3. How do you implement retry logic for failed callouts in Salesforce?**

**Answer:**
Salesforce doesn't have a built-in retry mechanism for Queueable callouts — you implement it explicitly.

**Pattern:**
```apex
public class RetryableCallout implements Queueable, Database.AllowsCallouts {

    private String payload;
    private Integer retryCount;
    private static final Integer MAX_RETRIES = 3;

    public RetryableCallout(String payload, Integer retryCount) {
        this.payload = payload;
        this.retryCount = retryCount;
    }

    public void execute(QueueableContext ctx) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:TargetSystem/endpoint');
            req.setMethod('POST');
            req.setBody(payload);
            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() >= 500 && retryCount < MAX_RETRIES) {
                // Server error — schedule retry with exponential backoff
                System.enqueueJob(new RetryableCallout(payload, retryCount + 1));
            } else if (res.getStatusCode() >= 400) {
                // Client error — do not retry, log failure
                logFailure(payload, res.getBody());
            }
        } catch (CalloutException e) {
            if (retryCount < MAX_RETRIES) {
                System.enqueueJob(new RetryableCallout(payload, retryCount + 1));
            } else {
                logFailure(payload, e.getMessage());
            }
        }
    }
}
```

**Key design decisions:**
- Retry on 5xx (server errors) and network timeouts, not on 4xx (client errors — retrying won't fix a bad payload).
- Exponential backoff: delay between retries increases (though Queueable doesn't support built-in delay — use Scheduled Apex for delays).
- Dead letter queue: after max retries, write a `Failed_Callout__c` record for ops team review.
- Idempotency key: include a unique ID in the payload so the receiving system can de-duplicate retried calls.

---

**Q4. A client's external ERP sends order data to Salesforce every 5 minutes via REST. How do you design the receiver endpoint for reliability?**

**Answer:**
A reliable inbound REST receiver needs: idempotency, input validation, async processing, and error response standards.

**Design:**
```apex
@RestResource(urlMapping='/erp/order/*')
global with sharing class ERPOrderReceiver {

    @HttpPost
    global static void receiveOrder() {
        RestResponse res = RestContext.response;
        try {
            // 1. Parse and validate
            Map<String, Object> body = (Map<String, Object>)
                JSON.deserializeUntyped(RestContext.request.requestBody.toString());
            String erpOrderId = (String) body.get('erpOrderId');
            if (String.isBlank(erpOrderId)) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error":"erpOrderId required"}');
                return;
            }

            // 2. Idempotency check
            List<Order> existing = [SELECT Id FROM Order
                WHERE ERP_Order_Id__c = :erpOrderId LIMIT 1];
            if (!existing.isEmpty()) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf(
                    '{"status":"duplicate","salesforceId":"' + existing[0].Id + '"}');
                return;
            }

            // 3. Enqueue for async processing (never DML in REST receiver directly)
            System.enqueueJob(new OrderProcessingJob(body));

            res.statusCode = 202; // Accepted, processing async
            res.responseBody = Blob.valueOf('{"status":"accepted"}');

        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error":"internal_error"}');
        }
    }
}
```

Key pattern: respond with **202 Accepted** immediately and process asynchronously. The ERP doesn't wait for Salesforce to finish processing — it just gets confirmation that the message was received. This prevents timeout issues when the ERP has a 5-second response timeout but Salesforce processing takes longer.

---

**Q5. What is a Named Credential and why should you use it instead of hardcoding endpoints?**

**Answer:**
A Named Credential is a Salesforce configuration record that stores an external endpoint URL and authentication parameters. When you reference it in Apex as `callout:NamedCredentialName`, Salesforce handles the authentication handshake transparently — the Apex code never sees the credentials.

**Benefits over hardcoding:**
1. **Security:** No credentials in Apex code or custom settings. Credentials are stored in Salesforce's encrypted credential store, not version-controlled with your code.
2. **Environment portability:** Named Credentials are separate per-org. In dev, `callout:PaymentGateway` points to a sandbox URL. In production, it points to the live URL. No code changes needed during deployment.
3. **Auth protocol support:** Named Credentials support OAuth 2.0 (including token refresh), Basic auth, JWT, and Custom header auth — configured declaratively, not coded.
4. **CORS and Remote Site Settings:** Named Credentials automatically allowlist their endpoints — no manual Remote Site Settings entry required.

In FSL integrations (e.g., calling a Google Maps API for ETA calculations), I always use Named Credentials. The endpoint and API key never appear in Apex.

---

**Q6. A client uses Azure Service Bus as their enterprise message broker. How would you integrate Salesforce with it?**

**Answer:**
Azure Service Bus integration can be achieved in two directions:

**Salesforce → Azure Service Bus (outbound):**
Use Queueable Apex with an HTTP callout to the Azure Service Bus REST API. Azure Service Bus exposes a REST endpoint (`https://{namespace}.servicebus.windows.net/{queue}/messages`) that accepts POST requests with a SAS token in the Authorization header.

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:AzureServiceBus/fieldservice-events/messages');
req.setMethod('POST');
req.setHeader('Authorization', sasToken);
req.setHeader('Content-Type', 'application/json');
req.setBody(JSON.serialize(eventPayload));
new Http().send(req);
```

The Named Credential handles the SAS token generation — use a Custom Auth Provider that generates the SAS signature.

**Azure Service Bus → Salesforce (inbound):**
Azure Service Bus doesn't push natively to Salesforce. Options:
1. **Azure Function as bridge:** An Azure Function subscribes to the Service Bus topic, transforms the message, and calls the Salesforce REST/Connected App API to create records or publish Platform Events.
2. **MuleSoft / Jitterbit:** Integration platform subscribes to Service Bus and maps to Salesforce objects. This is the enterprise-standard approach at PwC — MuleSoft has a native Azure Service Bus connector.
3. **Azure Logic Apps:** Low-code Azure workflow tool with a Salesforce connector. Subscribes to Service Bus trigger, inserts Salesforce records.

At Concord Global, I used Jitterbit for a similar integration — Azure Service Bus → Jitterbit → Salesforce Platform Events → FSL Work Order creation.

---

### 2.6 Architecture (6 Questions)

---

**Q1. A client needs a multi-cloud Salesforce architecture supporting Sales, Service, FSL, and Experience Cloud. How do you approach the data model design?**

**Answer:**
Multi-cloud architecture design follows a "shared spine" approach — core objects that all clouds share, with cloud-specific extensions.

**Shared spine objects:**
- Account (shared across all clouds — the customer)
- Contact (related to Account)
- Case (bridges Service Cloud and FSL — Work Orders are often created from Cases)
- Asset (tracks installed products — required for FSL warranty/break-fix scenarios)

**Cloud-specific extensions:**
- Sales Cloud: Opportunity, Quote, Product Catalog
- Service Cloud: Entitlement, Entitlement Process, Case Milestone, Knowledge
- FSL: WorkOrder, ServiceAppointment, ServiceResource, ServiceTerritory
- Experience Cloud: Community user (Contact-linked portal user), self-service Case creation, Appointment Booking portal

**Key design decisions:**
1. **Case → Work Order relationship:** Service Cloud creates Cases; FSL creates Work Orders from Cases. The `WorkOrder.CaseId` lookup maintains the linkage. Entitlements flow from Case to Work Order for SLA tracking.
2. **Account → Asset → Work Order:** For a product break/fix scenario, the Work Order references the Asset being repaired. Asset is the "what" we're servicing.
3. **Experience Cloud permissions:** Community users (portal users) should access only their own Cases, Work Orders, and Appointment Bookings. Use Sharing Sets and Guest User profiles for proper record visibility.
4. **Data governance:** Define master vs slave for Account/Contact — if Salesforce is not the MDM, establish the sync source and use External IDs for idempotent upserts.

---

**Q2. How do you choose between Flow and Apex for automation? What's your decision framework?**

**Answer:**
My decision framework has three tiers:

**Tier 1 — Use Flow:**
- Business logic that non-technical admins need to maintain going forward
- Triggered record automation (Record-Triggered Flow replaced Process Builder)
- Approval processes with human decision steps
- Screen flows for guided user experiences
- Logic that can be expressed without complex loops, collection manipulation, or governor limit awareness
- Agentforce Actions (Flow is a first-class Action type)

**Tier 2 — Use Apex:**
- Bulk data operations requiring collection manipulation (Apex handles bulk inherently; Flow loops on large datasets hit limits)
- Complex algorithms: scoring, ranking, multi-condition branching with 10+ paths
- HTTP callouts from triggers (Queueable Apex)
- Operations requiring Savepoint/rollback atomicity
- When you need fine-grained governor limit control
- Integration receivers (REST endpoints)

**Tier 3 — Avoid (anti-patterns):**
- Never put business logic in a Workflow Rule (deprecated) if you can use Flow
- Never use Process Builder for new builds (Salesforce is retiring it)
- Never use Flow for complex data transformation that processes 10,000+ records in a loop — use Batch Apex

**PwC context:** At PwC, admins often own post-deployment maintenance. Default to Flow unless a hard technical boundary forces Apex — this reduces the client's long-term dependency on developers for routine logic changes.

---

**Q3. A client asks: "Should we use Platform Events or CDC for real-time data sync to our data warehouse?" Walk me through your recommendation.**

**Answer:**
My recommendation depends on four factors:

**Factor 1 — Control vs. Automation:**
- Platform Events: You control exactly what events are published and when. Good if not every record change should trigger a sync (e.g., only "Case Closed" events, not every status update).
- CDC: Automatic. Every DML change on configured objects fires an event. Good for comprehensive replication with no missed changes.

**Factor 2 — Payload needs:**
- Platform Events: You define the payload. You can enrich it — include calculated fields, related record data, business context.
- CDC: Fixed schema — field-level delta + header metadata. You get exactly what changed, nothing more.

**Factor 3 — Volume:**
- Both have Salesforce event delivery limits. At high volume (millions of records/day), CDC can generate enormous event volume. Platform Events are more surgical.

**Factor 4 — Infrastructure:**
- Both use CometD streaming protocol. If the data warehouse team prefers polling, use a REST query endpoint instead.

**My recommendation:** For a data warehouse sync where completeness is paramount and the DW team manages the consumer — **use CDC**. It's lower maintenance, zero developer code on the publish side, and guarantees no missed changes.

For selective event-driven workflows where business context matters (e.g., "notify ERP only when Work Order moves to Completed, include the technician's name and parts used") — **use Platform Events** and publish from an Apex trigger or Flow.

---

**Q4. What is Salesforce's governor limit architecture and why does it exist?**

**Answer:**
Governor limits are per-transaction resource caps enforced by the Salesforce multi-tenant runtime. They exist because Salesforce runs thousands of customer orgs on shared infrastructure — a single poorly-written transaction that executes 50,000 SOQL queries or consumes 100 MB of heap would starve other tenants' operations.

**Key limits (per synchronous transaction):**
- 100 SOQL queries
- 50,000 total SOQL rows returned
- 150 DML statements
- 10,000 DML rows
- 10 MB heap size
- 10 HTTP callouts (synchronous — not allowed in triggers)
- 60,000 CPU milliseconds

**Architectural implications:**
1. **Bulkification is mandatory** — never query or DML inside a loop. Collect IDs, query once, process in memory, DML once.
2. **Async processing for heavy operations** — Batch Apex runs in its own transaction per batch. Queueable runs in its own transaction. This "resets" the governor limit budget.
3. **Design for trigger context** — Always write trigger handlers that assume 200 records in `Trigger.new` (Data Loader default batch size). If your handler can't process 200 records within limits, it's not production-ready.
4. **Platform Events as a "valve"** — Publishing a Platform Event from Batch Apex is a safe way to trigger follow-on processing in a separate transaction without chaining async jobs beyond what's allowed.

---

**Q5. How would you design a high-availability integration between Salesforce and an SAP ERP system for a field service parts inventory scenario?**

**Answer:**
High-availability integration design principles for FSL-SAP:

**Architecture:**
```
FSL (Parts Request) → Platform Event → MuleSoft/Jitterbit → SAP RFC/BAPI
SAP (Parts Availability) → MuleSoft/Jitterbit → Salesforce REST API → WorkOrder Parts
```

**Key design decisions:**

1. **Event-driven, not polling:** FSL publishes a `Parts_Request__e` Platform Event when a Work Order requires parts. The integration platform subscribes, queries SAP, and updates Salesforce asynchronously. No polling loop required.

2. **Idempotency at every boundary:** Parts requests include an `idempotency_key` (Work Order ID + Line Item ID). SAP rejects duplicate requests. Salesforce update endpoint uses `upsert` on an External ID.

3. **Circuit breaker pattern:** If SAP is unavailable, the integration platform queues the event and retries with exponential backoff (15s, 30s, 60s, max 10 retries). If all retries exhaust, a `Dead_Letter__c` record is created in Salesforce and ops are alerted via PagerDuty.

4. **Compensation events:** If parts are allocated in SAP but the Salesforce update fails, SAP receives a `Parts_Deallocate__e` event to release inventory — preventing a phantom reservation.

5. **Monitoring:** Both sides log correlation IDs. MuleSoft publishes metrics to Anypoint Monitoring. Salesforce has a custom `Integration_Log__c` object for audit.

---

**Q6. A client's org has 50+ installed managed packages. How do you approach performance optimization for page load times?**

**Answer:**
Heavy managed package presence creates governor limit pressure and DOM bloat. Performance optimization approach:

**Audit phase:**
1. Use the Salesforce Event Monitoring API to identify slow page loads — which page transitions exceed 3 seconds?
2. Use Chrome DevTools network tab (or Salesforce Inspector) to identify which Apex calls dominate load time.
3. Review the Lightning Page in the App Builder — count components per region.

**Quick wins:**
1. **Lazy-load non-critical components** — Use `lwc:if` to defer rendering of below-the-fold components until user interaction or scroll.
2. **Remove unused managed package components from Lightning Pages** — Often 20–30% of page components are installed by packages but never used.
3. **Replace synchronous wire calls with imperative + loading states** — Show a skeleton loader immediately, fetch data asynchronously.

**Architecture fixes:**
1. **Consolidate SOQL at the Apex controller level** — One Apex method returns a wrapper object with all page data instead of 5 separate components each making their own SOQL call.
2. **Client-side caching** — For relatively static data (tier definitions, configuration metadata), cache in `sessionStorage` via a utility LWC module. Skip the Apex roundtrip on repeat visits.
3. **Platform Cache** — Cache frequently-read Apex results in the Org Cache or Session Cache. Reduces SOQL per request.

In a client engagement with 60+ packages, we reduced the main Service Console page load from 6.8s to 2.4s by removing 12 unused components and consolidating 8 Apex wire calls into 2.

---

### 2.7 CI/CD (4 Questions)

---

**Q1. Walk me through a Salesforce CI/CD pipeline using Azure DevOps.**

**Answer:**
Pipeline structure for a Salesforce project using org-based development:

```yaml
# azure-pipelines.yml (simplified)
trigger:
  branches:
    include: [ 'develop', 'release/*' ]

stages:
  - stage: Validate
    jobs:
      - job: StaticAnalysis
        steps:
          - script: npm install -g @salesforce/sfdx-scanner
          - script: sf scanner run --target force-app --severity-threshold 3
            displayName: 'Salesforce Code Scanner'

      - job: DeployToScratch
        steps:
          - script: sf org create scratch --definition-file config/project-scratch-def.json
          - script: sf project deploy start --source-dir force-app
          - script: sf apex run test --synchronous --result-format human

  - stage: DeployDevelop
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/develop'))
    jobs:
      - job: Deploy
        steps:
          - script: sf project deploy start --target-org DeveloperSandbox
          - script: sf apex run test --target-org DeveloperSandbox

  - stage: DeployRelease
    condition: startsWith(variables['Build.SourceBranch'], 'refs/heads/release/')
    jobs:
      - job: Deploy
        steps:
          - script: sf project deploy start --target-org StagingSandbox --test-level RunLocalTests
```

**Key points:** Static analysis before any deployment. Scratch orgs for isolated feature testing. Progressive promotion: develop → Developer sandbox → Staging → Production. `RunLocalTests` required for production deployments.

---

**Q2. What is delta deployment in Salesforce CI/CD and how do you implement it?**

**Answer:**
Delta deployment means deploying only the metadata components that changed between two commits, rather than the full `force-app` directory. This dramatically reduces deployment time and test execution time.

**Tool: `sfdx-git-delta` (sgd):**
```bash
# Install
npm install sfdx-git-delta --global

# Generate delta package between HEAD and the last deployed commit
sgd --to HEAD --from abc123def --repo . --output delta

# Deploy only changed components
sf project deploy start --manifest delta/package/package.xml \
  --post-destructive-changes delta/destructiveChanges/destructiveChanges.xml \
  --target-org TargetOrg
```

**How it works:** `sfdx-git-delta` diffs the git history between two SHA references and generates a `package.xml` listing only changed components. It also generates `destructiveChanges.xml` for deleted components.

**FSL-specific challenge:** Scheduling Policies and Service Territories are data records, not metadata. They don't appear in git diffs. You maintain separate data migration scripts that run as a post-deploy step, idempotently upserting these records using External IDs.

---

**Q3. How do you handle test class execution in a CI/CD pipeline without running all tests every time?**

**Answer:**
Running all 500+ test classes on every commit is impractical — it can take 30+ minutes. Strategies for efficient test execution:

**1. Test level selection in the pipeline:**
- **Feature branch → Scratch org:** Run only tests related to changed Apex classes using `--test-level RunSpecifiedTests`. Use `sgd` to identify changed class names and map to their test class counterparts.
- **Develop branch merge:** Run `RunLocalTests` — all tests in the org, excluding managed package tests.
- **Production deployment:** `RunAllTestsInOrg` is required by Salesforce if you deploy more than 10 components. Use `RunLocalTests` to stay within 75% coverage requirement without managed package test overhead.

**2. Test class naming convention:** `[ClassName]Test` or `[ClassName]Tests` — makes it easy to script "run test for changed class."

**3. Test result gating:** Pipeline stage fails if: (a) any test fails, (b) org-wide code coverage drops below 75%. Azure DevOps can parse the JUnit-format test results published by `sf apex run test --result-format junit`.

**4. Code coverage tracking:** Publish coverage report as a pipeline artifact. Track coverage trend across builds to catch coverage regressions early.

---

**Q4. A deployment to production fails because a test class in a managed package is failing. How do you resolve this?**

**Answer:**
Managed package test failures during production deployment are a common FSL/Service Cloud scenario because FSL's managed package includes test classes that run against your org's data and configuration.

**Immediate resolution options:**

1. **Use `RunLocalTests` instead of `RunAllTestsInOrg`:** `RunLocalTests` excludes managed package tests. For most deployments, this is acceptable and still meets the 75% code coverage requirement. Switch the pipeline's deploy command to `--test-level RunLocalTests`.

2. **Check the failure reason:** Sometimes managed package tests fail because your org customizations violate an assumption in the package's test setup. Common causes:
   - A required custom field the package test expects doesn't exist (org-specific configuration).
   - A validation rule on a standard object causes the package's test data insert to fail.
   - A trigger on a standard object that the package's test doesn't expect.

3. **Contact the ISV:** If the managed package test is genuinely broken (not caused by your org), open a case with the vendor (Salesforce if it's FSL). Document the failing test, the error message, and the org ID.

4. **Suppress via org preference:** Some packages allow disabling their test classes in Settings. FSL does not, but some third-party packages do.

The safest long-term resolution: ensure your CI validation pipeline uses the same test level as production — if you validate with `RunLocalTests`, you won't be surprised by managed package failures in prod.

---

## SECTION 3 — SCENARIO QUESTIONS

---

**Scenario 1 — FSL Scheduling Performance**

*"A telecom client's FSL dispatcher console takes 12+ seconds to load and dispatchers are complaining. They have 800 technicians across 15 territories, 3,000 daily appointments. What do you do?"*

**Weak answer:** "I would optimize the SOQL queries and reduce the number of components on the page."

**Strong answer:**
I approach this in three phases: diagnose, quick win, architectural fix.

**Diagnose:** Enable Event Monitoring to capture LightningPageView events. Pull the average page load time by territory — is it all territories or specific ones? Use Chrome DevTools to identify which network requests dominate. In my experience with large FSL orgs, the Gantt view is usually the bottleneck — it's loading all 3,000 appointments up front.

**Quick win (same sprint):**
- Reduce the Gantt's default date range from 7 days to 1 day in FSL Settings. This reduces the initial appointment payload by 85%.
- Enable "Lazy Loading" for the dispatcher Gantt — load resources for visible territories only, not all 800 technicians.
- Cap the "Max Appointments Loaded" setting in FSL Dispatch Console settings.

**Architectural fix (next sprint):**
- Segment territories — dispatchers should only see their assigned territories' resources. If each dispatcher manages 1–2 territories, they're loading 50–100 resources, not 800.
- Create custom Dispatcher Profiles that filter the visible resource pool.
- For appointment data, implement a custom Apex endpoint that returns pre-aggregated daily summaries for the map view, with drill-down fetching on demand.

Impact: In a similar engagement, these changes reduced the console load from 14s to under 3s.

---

**Scenario 2 — Agentforce Incorrect Escalation**

*"A client deployed Agentforce for service chat. Customers are complaining that the AI is not escalating to human agents when they're upset. What do you investigate?"*

**Weak answer:** "Check the escalation flow and make sure the intent is configured."

**Strong answer:**
Escalation failures in Agentforce are typically a Topic instruction problem or a sentiment detection gap.

**Investigation:**
1. Pull chat transcripts where customers expressed frustration but were not escalated. Look for keywords and emotional cues the AI missed.
2. Review the Topic instructions for the relevant service Topic. Is there an explicit escalation instruction? e.g., "If the customer uses negative language, asks for a manager, or repeats the same complaint more than twice, invoke the TransferToAgent action."
3. Check if the `TransferToAgent` action is properly configured and connected to the Omni-Channel routing queue.
4. Review the Einstein Trust Layer audit logs — what was the exact prompt the LLM received? Was sentiment context included?

**Fix options:**
- Add explicit escalation triggers in Topic instructions: "Escalate if sentiment score is negative AND the customer has asked the same question more than once."
- Add a sentiment-checking action (Apex-based) that the agent invokes periodically to assess customer tone.
- Configure a hard rule: after 5 conversation turns without resolution, auto-escalate.
- Use the "Escalation Threshold" setting in the Service Cloud Agentforce configuration.

**Root cause pattern I've seen:** The default Topic instructions are too optimistic — they only escalate on explicit "speak to human" requests. Real customers express frustration indirectly. The fix is to enrich the escalation instruction with emotional signal patterns.

---

**Scenario 3 — Integration Data Mismatch**

*"The client's Salesforce Work Order status shows 'Completed' but their ERP still shows the job as 'In Progress' an hour later. The integration team says they haven't changed anything. What do you investigate?"*

**Weak answer:** "Check the integration logs to see if the event was published."

**Strong answer:**
I investigate at three layers: Salesforce (publisher), integration platform (transport), ERP (subscriber).

**Salesforce layer:**
1. Check if the Platform Event or outbound message was published. Query `AsyncApexJob` for recent failures. Check if the Work Order update triggered the expected automation (Flow/Trigger → publish event).
2. Look at the Work Order record's `LastModifiedDate` — confirm it was actually updated at the time the ERP discrepancy started.
3. Check if there's a `Failed_Event_Delivery__e` or retry queue for the event.

**Integration platform (MuleSoft/Jitterbit):**
1. Review the integration flow's execution logs for that time window. Did the flow execute? Did it receive the event?
2. Check for errors: HTTP 5xx from ERP, connection timeout, schema mismatch on a field.
3. Check if the integration platform's subscription to the Salesforce channel lapsed. Streaming API subscriptions expire after 40 hours of inactivity — if the integration server restarted and didn't re-subscribe, it would have missed events.

**ERP layer:**
1. Check ERP transaction logs for incoming updates. Did the call arrive but fail ERP-side validation?

**The "nothing changed" trap:** Integration teams say nothing changed, but deployments happen. Check: did the ERP endpoint URL change? Did a Named Credential secret rotate? Did a Salesforce permission set change that removed the integration user's access?

In a previous engagement, the root cause was an expired Named Credential OAuth token that nobody renewed after the quarterly secret rotation. Salesforce kept publishing events but the callout was silently failing with a 401.

---

**Scenario 4 — Work Order Flooding**

*"After a system update, your client's FSL org is receiving 5,000 Work Order creation requests simultaneously from an IoT system. Salesforce is timing out. What do you do?"*

**Weak answer:** "Use a Batch job to process them asynchronously."

**Strong answer:**
This is a classic spike ingestion problem. The IoT system is hitting the Salesforce REST API directly, and the synchronous transaction processing can't keep up.

**Immediate stabilization:**
1. If the IoT system supports retry, coordinate a temporary pause while we implement buffering.
2. Switch the IoT system to publish to an intermediate queue (Azure Service Bus, AWS SQS) rather than calling Salesforce directly.

**Architecture fix:**
Introduce a message broker as a buffer layer:
```
IoT System → Azure Service Bus Queue → Azure Function (batching) → Salesforce Bulk API
```

Azure Service Bus absorbs spikes. An Azure Function reads from the queue in batches of 200 and uses the Salesforce Bulk API v2 to insert Work Orders. Bulk API is designed for exactly this — it processes records asynchronously and returns a job ID. No timeouts.

**Salesforce-only alternative (if external queue is not possible):**
Use a Platform Event as a buffer. The IoT system publishes `Work_Order_Request__e` events (Platform Events have a 250,000 event/day limit on Enterprise Edition). A Platform Event trigger creates Work Orders. This offloads the creation to Salesforce's event bus rather than synchronous REST.

**Flood control:** Add an `Apex_Job_Queue_Depth__c` check — if the async queue depth exceeds a threshold, publish a `System_Alert__e` to notify ops rather than silently dropping requests.

---

**Scenario 5 — Security Review Finding**

*"During a PwC security review, the auditor flags that a senior developer's code runs 'without sharing' everywhere. How do you respond?"*

**Weak answer:** "I'll change all the classes to 'with sharing'."

**Strong answer:**
Blanket `without sharing` is a legitimate finding, but the fix isn't blanket `with sharing` either — that would break batch jobs, integration receivers, and system processes.

My response to the auditor:

**First, categorize the code:**
1. User-facing classes (LWC controllers, screen flows, REST endpoints called by users) → these must be `with sharing`. Any `without sharing` here is a real security finding.
2. System-process classes (Batch Apex, Scheduled Apex, integration receivers, trigger handlers for automation) → `without sharing` is appropriate. These processes run as a system user, not an individual user. Forcing `with sharing` would break scheduled batch jobs that need to see all records.
3. Reusable utility classes → should be `inherited sharing` so they adopt the sharing context of their caller.

**Action:**
- Audit each class against these categories.
- Prioritize fixing user-facing classes: switch to `with sharing`.
- Document the system-process classes with `@SuppressWarnings('PMD.ApexSharingViolations')` and an explicit comment explaining why `without sharing` is intentional.
- Add a PMD rule to the CI pipeline: any new class marked `without sharing` that lives in the LWC controllers or REST endpoint package paths fails the build.

**Communicate to the auditor:** We'll fix the genuine violations (user-facing) immediately. The system-process classes are architecturally correct — here's the documentation. This is a nuanced finding, not a blanket security failure.

---

**Scenario 6 — FSL Implementation from Scratch**

*"A new client needs FSL implemented. They have 300 field technicians across 5 states. Walk me through your implementation approach."*

**Weak answer:** "I'd set up Work Orders, assign technicians, and configure scheduling."

**Strong answer:**
I break FSL implementation into six workstreams, run in parallel during a 12–16 week engagement:

**Workstream 1 — Foundation (Weeks 1–2):**
- Map technician org structure to Service Territory hierarchy (state-level territories → district sub-territories).
- Define ServiceResource types: individual technicians + crew entities for team jobs.
- Configure OperatingHours per region (time zones, holidays differ by state).

**Workstream 2 — Work Model (Weeks 2–4):**
- Define WorkTypes for each job category (Installation, Repair, Inspection). Each WorkType has estimated duration, required skills, auto-generated checklist items.
- Define Skill taxonomy (50+ skills across 5 disciplines). Map to ServiceResourceSkill records for all 300 technicians — typically imported via Data Loader.

**Workstream 3 — Scheduling Policy (Weeks 3–5):**
- Design Scheduling Policy for each territory type. Balance travel time minimization vs. SLA priority vs. skill availability.
- Configure Work Rules (hard): skill match, territory match, working hours compliance.
- Configure Service Objectives (soft, scored): minimize travel, maximize technician continuity per customer, honor appointment time windows.

**Workstream 4 — Mobile (Weeks 4–7):**
- Configure Briefcase: which objects/fields sync to device. Balance data freshness vs. sync performance.
- Build custom LWC components for FSL mobile: job checklist, signature capture, parts lookup.
- Offline testing: simulate field conditions (airplane mode during sync).

**Workstream 5 — Integration (Weeks 3–8):**
- Integrate with client's SAP for parts inventory.
- Integrate with customer portal for Appointment Booking.
- ERP sync for Work Order completion/billing.

**Workstream 6 — Cutover (Weeks 10–16):**
- Historical data migration: existing work orders, technician records.
- Dispatcher training — Gantt, scheduling console.
- Technician training — FSL mobile app.
- Hypercare: 2 weeks of on-site support post go-live.

At Concord Global, I led the FSL build across a 200-technician deployment. The biggest lesson: invest heavily in the Scheduling Policy design upfront — retrofitting it after go-live with hundreds of live appointments is extremely disruptive.

---

**Scenario 7 — LWC Performance Problem**

*"A client's memberDashboard LWC is causing Experience Cloud pages to crash on mobile devices. The component shows loyalty points, tier status, and recent transactions. What do you diagnose?"*

**Weak answer:** "I'd check the browser console for errors and reduce the number of API calls."

**Strong answer:**
Mobile crashes in LWC point to one of three causes: memory overload, infinite re-render loop, or unhandled promise rejection crashing the component tree.

**Diagnosis:**

1. **Open Chrome DevTools → Mobile emulation.** Reproduce the crash. Check the Console tab for errors before the crash. Look for: `Maximum call stack size exceeded` (infinite re-render), `Cannot read properties of undefined` (null pointer), or heap memory warnings.

2. **Check the wire calls:** If the component has 3+ wire adapters and each returns 100+ records, the mobile heap fills fast. Query the transactions endpoint — how many records are returned? If it's the full history (500 records), that's the problem.

3. **Check for infinite re-render:** Does the component have a `renderedCallback()` that sets a tracked property unconditionally? That causes an infinite loop: render → set property → render → repeat.

4. **Check `setInterval` or subscriptions:** A `setInterval` that fires every 10 seconds and triggers an Apex call can accumulate pending promises on slow mobile connections, overwhelming the runtime.

**Fixes:**
- **Paginate transactions:** Return only the last 10 transactions. Add a "View all" link.
- **Guard `renderedCallback()`:** Add `if (this._initialized) return; this._initialized = true;` at the top.
- **Debounce wire inputs:** If `memberId` changes rapidly, debounce the wire re-call.
- **Lazy-load sections:** Show tier status immediately (lightweight), defer transaction history until user taps an expand button.

---

**Scenario 8 — Production Hotfix Under Pressure**

*"It's 10 PM. A client calls: points redemption is broken in production. Customers are getting errors. The VP of Customer Experience is on the call. How do you handle this?"*

**Weak answer:** "I'd check the error logs and fix the bug."

**Strong answer:**
I separate the communication stream from the technical stream immediately.

**First 5 minutes — Communication:**
"Thank you for the call. I'm pulling logs now. I'll update you every 10 minutes with status. First question: has anything changed in the last 6 hours — any deployment, maintenance window, or data import?"

This buys me time and focuses the VP on information-gathering rather than pressure escalation.

**Technical investigation (parallel):**
1. Pull Apex debug logs for the error time window. Look for the exact exception: what class, what line, what error message?
2. Check Setup → Apex Jobs for any failed batch or scheduled job that might have corrupted redemption state.
3. Check if a recent deployment is in the window — `Setup Audit Trail` shows deployments.
4. Check if the Voucher__c custom object has any new validation rules deployed that would reject the voucher insert.

**If the fix is clear and low-risk (e.g., a validation rule rejecting valid data):**
- Deactivate the validation rule immediately. Validate that redemptions succeed.
- Root-cause the validation rule logic. Fix and re-deploy properly in a maintenance window.

**If the fix is complex (code change required):**
- Deploy to a developer sandbox first. Run the test class. Time-box the fix to 30 minutes.
- If not solved in 30 minutes, implement a feature flag: a custom setting `Redemption_Disabled__c` that shows a graceful maintenance message instead of a hard error. Buys time for a proper fix without customer-facing crashes.

**Closing the call:** "We've restored service. Here's what happened, here's what we've fixed tonight, and here's the permanent fix timeline. I'll send you a written incident report by 9 AM."

PwC clients expect this communication cadence. The technical fix is half the job — stakeholder management during an incident is the other half.

---

## SECTION 4 — HOW TO SOUND LIKE A PwC SENIOR ASSOCIATE

### 4.1 Answer Structure (STAR + Client Context)

PwC interviewers respond to structured, client-framing answers. Use this template for every behavioral and technical scenario question:

**PwC STAR-C Framework:**

> **Situation (Client Context):** "At [client type], they had [business problem]. This was costing them [quantified pain] or preventing them from [strategic goal]."
>
> **Task:** "My role was to [specific responsibility]. I was accountable for [outcome], while [team member] owned [adjacent area]."
>
> **Action:** "I [specific technical decision]. I chose this approach over [alternative] because [trade-off reasoning]."
>
> **Result:** "This [quantified outcome — time/cost/efficiency/risk reduction]."
>
> **Client Connect:** "The client's [exec/stakeholder] specifically called out [impact or satisfaction point] during the engagement closeout."

**Example (FSL Scheduling Policy):**

> "A telecom client in the Midwest was losing $2M annually in truck-roll costs because their dispatchers were manually assigning appointments without skill matching — sending general technicians to fiber splice jobs that required certification. My role was to design the FSL Scheduling Policy from scratch. I had to decide between a single company-wide policy vs. territory-specific policies. I chose territory-specific because their rural territories had limited certified resources and needed a different skill-weight hierarchy than urban territories. After implementation, the truck-roll mismatch rate dropped from 18% to 3%, saving approximately $1.4M in the first year. The VP of Field Operations mentioned it by name in the executive business review."

---

### 4.2 Language That Signals PwC Senior Associate Level

**Use these phrases:**
- "The client's business driver was..." (shows you understand why, not just what)
- "We evaluated [Option A] vs. [Option B] and chose [X] because..." (shows architectural thinking)
- "The risk we identified was [X], which we mitigated by [Y]" (shows senior awareness)
- "To ensure the client could maintain this after we rolled off..." (shows consulting mindset — sustainability)
- "We benchmarked this against the Salesforce-recommended pattern for [scenario]..." (shows standards awareness)
- "The trade-off was [technical benefit] vs. [business simplicity]..." (shows balance)
- "Post go-live, we tracked [metric] to validate that the implementation achieved the business case" (shows accountability)
- "I worked with the client's Salesforce admin to document [X] so the team could own it long-term" (shows knowledge transfer)

**Avoid these phrases:**
- "I just used [feature]" — too thin, no context
- "It was pretty straightforward" — dismissive, misses the learning
- "I don't know exactly, but I think..." — undermines confidence (either know it or say "let me walk you through what I do know")
- "That's not something I've done" — without pivoting to adjacent experience
- "The client wanted X so we did X" — no critical thinking shown

---

### 4.3 Mapping Saikiran's Experience to PwC Talking Points

| PwC Will Ask About | Map to Your Experience |
|--------------------|----------------------|
| FSL from scratch | Concord Global IT Services — full FSL implementation: resource model, territory hierarchy, scheduling policy, mobile config |
| Complex Apex patterns | Loyalty Cloud: Savepoint atomicity, FOR UPDATE race condition prevention, dual-layer idempotency in REST receiver |
| LWC at scale | promotionBanner: wire + refreshApex, auto-refresh interval with memory-safe disconnectedCallback; pointsRedemptionWizard: 4-step modal, double-submit prevention |
| Integration architecture | ECommerceIntegrationService: idempotent REST receiver, Queueable callout pattern |
| Batch processing | LoyaltyTransactionBatch: Database.Stateful, 200-record scope, compensating transactions for expiry |
| CI/CD | sf CLI, scratch org deployments, FSL configuration data migration scripts |
| Cross-cloud architecture | Loyalty Cloud: tied LoyaltyProgramMember → LoyaltyLedger → Voucher → ECommerce integration — multi-object, multi-service |
| Agentforce | Conceptual depth — Topics/Actions/@InvocableMethod, reasoning engine, Einstein Trust Layer, grounding via Knowledge + Data Cloud |
| CG Cloud | RetailVisit execution, territory management, mobile offline patterns |
| Team/stakeholder management | Use Concord Global examples: working with dispatchers on scheduling policy validation, client training |

---

### 4.4 Handling Questions You Can't Fully Answer

**Never say "I don't know" and stop.**

Template:
> "I haven't built [X] directly, but let me tell you what I do know, and then flag what I'd want to confirm. From my [adjacent experience], the pattern would be [reasoning]. The part I'd want to validate is [specific gap]. In an engagement, I'd [how you'd bridge the gap — read docs, pair with a specialist, prototype in a scratch org]."

**Example (if asked about Data Cloud):**
> "I haven't worked with Data Cloud in production, but I've researched the architecture for Agentforce grounding. Data Cloud unifies customer profiles across sources into a Unified Individual record. Agentforce can query the Unified Profile at inference time to personalize responses. The part I'd want hands-on time with is the Identity Resolution configuration — how the system decides two records from different sources are the same customer. In an engagement, I'd partner with a Data Cloud architect during that phase while I own the Salesforce CRM and FSL configuration layers."

---

## SECTION 5 — COMMON MISTAKES AND REJECTION POINTS

### 5.1 Technical Disqualifiers

| Mistake | Why It's a Red Flag | How to Fix |
|---------|--------------------|---------  |
| Cannot explain bulkification | Shows trigger code isn't production-grade | Memorize the 3-rule pattern: no SOQL in loop, no DML in loop, no callouts in trigger |
| "I configure FSL, I haven't coded it" | Senior Associate role requires Apex + LWC, not just clicks | Own your code contributions. If you used declarative tools, explain why and what the trade-off was |
| Cannot differentiate Scheduled vs Triggered Optimization | Core FSL interview discriminator | Review Scenarios 2–3 in Section 2.3 above |
| Confuses Platform Events with Streaming API | Common terminology confusion | Platform Events are the event type; Streaming API (CometD) is the delivery protocol |
| Says "@track is required for reactivity" | Outdated — shows you haven't kept up since Spring '20 | Review Section 2.2 Q1 |
| Cannot explain `inherited sharing` | Shows shallow Apex security knowledge | Review Section 2.1 Q6 |
| No answer for CI/CD pipeline structure | PwC uses CI/CD on all projects | Memorize the Azure DevOps pipeline structure in Section 2.7 Q1 |

### 5.2 Behavioral Disqualifiers

| Mistake | Why It's a Red Flag |
|---------|---------------------|
| Answering "what did you do" without "why" | PwC wants consultants who understand business drivers, not just executors |
| Claiming sole ownership of large features | Experienced interviewers probe — you'll contradict yourself. Own your piece; acknowledge the team's |
| No examples of stakeholder management | Senior Associates manage client relationships. Pure technical answers signal associate-level |
| Talking only about technical outcomes | "We reduced query time by 50%" without "which allowed dispatchers to assign 20% more appointments per day" |
| Not having questions prepared | Signals low interest and insufficient research about PwC |
| Defensive responses to follow-up probes | When an interviewer probes deeper, they're testing depth — not catching you out. Lean in, not away |

### 5.3 FSL-Specific Red Flags

- Cannot name the FSL core objects (WorkOrder, ServiceAppointment, ServiceResource, ServiceTerritory, AssignedResource)
- Cannot explain the Scheduling Policy + Work Rules + Service Objectives hierarchy
- Does not know FSL mobile briefcase and offline behavior
- Cannot differentiate Enhanced Scheduling from full Optimization
- Does not know FSL configuration cannot be deployed as metadata (data records)
- Claims FSL and Service Cloud are "basically the same"

### 5.4 Agentforce-Specific Red Flags

- Calls it "an AI chatbot" — shows surface-level understanding
- Cannot explain Topics vs Actions architecture
- Does not know `@InvocableMethod` is how Apex integrates with Agentforce Actions
- Cannot explain the Einstein Trust Layer or why it matters for enterprise customers
- Confuses Agentforce with Einstein Bots or Einstein GPT

---

## SECTION 6 — RAPID REVISION BULLETS

### 6.1 FSL — 20 Bullets

1. Work Order → ServiceAppointment → AssignedResource is the core scheduling chain
2. ServiceResource has types: Technician, Crew, Capacity
3. ServiceTerritoryMember links a resource to a territory (Primary vs Relocation role)
4. Scheduling Policy = Work Rules (filter) + Service Objectives (score)
5. Work Rules: hard = eliminates resource; soft = deducts points
6. Service Objectives: scored 0–100; highest total wins the appointment
7. Appointment Booking = customer self-scheduling via API; returns time slot windows
8. Enhanced Scheduling = dispatcher-triggered, single appointment, near real-time
9. Optimization = background job, all appointments in territory, minimizes travel
10. FSL mobile uses Briefcase — pre-synced records for offline access
11. Offline actions queue locally; sync when connectivity restored; conflict = last-write-wins default
12. ResourceAbsence blocks a technician's availability in the scheduler
13. WorkType = template: default duration, required skills, checklist items
14. SkillLevel on ServiceResourceSkill (1–10 scale); WorkType sets minimum level
15. FSL Scheduling Policies, Territories, Skills are DATA records — not deployable metadata
16. For CI/CD: export FSL config as CSV/JSON seed data; upsert via External ID post-deploy
17. Optimization Request object: `FSL__Optimization_Request__c` — insert to trigger, poll `Status__c`
18. Service Appointment statuses: None → Scheduled → Dispatched → In Progress → Completed / Cannot Complete
19. Gantt performance: reduce default date range, limit visible territory resources, lazy-load
20. FSL Scheduler Logs: enable in Setup → Field Service → debug why appointments aren't scheduling

### 6.2 Agentforce — 10 Bullets

1. Agentforce = LLM reasoning engine (Claude by Anthropic) + Topics + Actions; not a decision tree
2. Topics = intent classification + scope + instructions + action set
3. Actions = Apex (@InvocableMethod), Flow, Prompt Template, or external API
4. @InvocableMethod must return `List<OutputClass>` and accept `List<InputClass>`
5. Grounding sources: Apex Actions (live data), Knowledge Articles, Data Cloud (Unified Profile), Prompt Templates
6. Einstein Trust Layer: encrypts prompts, masks PII, logs all LLM interactions for audit
7. Einstein Trust Layer = zero data retention with Anthropic (Salesforce's contractual guarantee)
8. Topics act as guardrails — agent can only invoke Actions in the active Topic
9. Agentforce vs Einstein Bots: LLM vs NLU/decision tree; multi-step reasoning vs intent matching
10. Testing: Agentforce testing panel in Setup shows reasoning trace + action invocations

### 6.3 LWC — 10 Bullets

1. Component lifecycle order (parent → child): constructor → connectedCallback → [child hooks] → renderedCallback (children first, parent last)
2. @api = public property (parent → child binding); @track = deprecated for basic reactivity (auto since Spring '20)
3. All properties are reactive since Spring '20; object mutation detected; replacing reference is safest
4. Wire = framework-managed, cached, reactive to parameter changes; use for read-heavy data
5. Imperative = developer-controlled; use for user-triggered actions, conditional fetching, loading state management
6. refreshApex() only works on wire results; requires storing `this._wiredResult = result` in wire handler
7. LMS = cross-DOM communication; MessageChannel metadata; subscribe in connectedCallback, unsubscribe in disconnectedCallback
8. Shadow DOM: CSS scoped per component; use CSS custom properties (variables) for cross-component theming
9. Memory leaks: clearInterval in disconnectedCallback; unsubscribe LMS; remove window event listeners
10. Custom events: `dispatchEvent(new CustomEvent('name', { detail: payload, bubbles: true }))` in child; `on[name]` handler in parent

### 6.4 Apex — 10 Bullets

1. Bulkification rules: no SOQL in loop, no DML in loop, no callout in trigger context
2. Key governor limits: 100 SOQL, 50K rows, 150 DML, 10K DML rows, 10 MB heap, 60K CPU ms
3. Savepoint = `Database.setSavepoint()` + `Database.rollback(sp)` in catch — transaction-scoped atomicity
4. `with sharing` = enforce record-level sharing; `without sharing` = bypass sharing; `inherited sharing` = adopt caller's context
5. Queueable: chainable, object references allowed, monitorable — use for async callouts and chained jobs
6. Batch: large volume, chunked in execute(), use Database.Stateful for cross-batch state accumulation
7. Future: simple async, no chaining, primitives only, cannot call from Batch
8. FOR UPDATE = row-level pessimistic lock; prevents concurrent updates; waits up to 10 seconds; use for inventory/counter scenarios
9. WITH SECURITY_ENFORCED = declarative FLS check on SOQL SELECT/WHERE; throws QueryException on access violation
10. Recursive trigger prevention: static Boolean flag + finally block reset; counter pattern for controlled re-entry

### 6.5 Saikiran's Experience — 10 Bullets

1. 9+ years Salesforce development; FSC, Service Cloud, Admin, Platform Developer I certified
2. FSL from scratch at Concord Global IT Services: resource model, territory hierarchy, scheduling policy, mobile offline config
3. Loyalty Cloud Retail Rewards Platform: LoyaltyProgramMember, LoyaltyLedger, PromotionEngineService (FOR UPDATE lock), RedemptionService (Savepoint atomicity)
4. CG Cloud Retail Execution: RetailVisit management, territory-based access, offline mobile patterns
5. Integration expertise: ECommerceIntegrationService (idempotent REST receiver), Jitterbit for Azure Service Bus → Salesforce
6. LWC production components: promotionBanner (wire + auto-refresh + memory-safe interval), pointsRedemptionWizard (4-step modal, double-submit prevention)
7. Batch Apex: LoyaltyTransactionBatch with Database.Stateful, 200-record scope, compensating transactions for point expiry
8. CI/CD: sf CLI, scratch orgs, FSL configuration data migration scripts, delta deployment strategy
9. Architect-track goal: designing solutions, mentoring junior developers, leading technical workstreams
10. Strength in cross-cloud architecture: connected multiple clouds (Sales, Service, FSL, Experience, Loyalty) with consistent data models and integration patterns

### 6.6 Questions to Ask PwC Interviewer — 5 Questions

1. **"What does the FSL project portfolio look like in the Bangalore delivery center — are you working primarily with Indian clients, or supporting global engagements? And which industries are most active?"**
   *(Shows strategic interest; helps you understand team structure and project variety)*

2. **"How is Agentforce adoption looking across PwC's client base? Are you seeing enterprise clients adopt it for field service use cases specifically, or is it primarily in service cloud/contact center scenarios so far?"**
   *(Shows you've done your research; signals genuine Agentforce interest beyond buzzword level)*

3. **"For a Senior Associate joining the FSL practice, what does the first 90 days typically look like — is there a bench period for certifications and internal onboarding, or do you typically go straight onto an active engagement?"**
   *(Practical question; shows you're thinking about how to add value quickly)*

4. **"What's PwC's approach to technical career tracks? Is there a clear path from Senior Associate to Manager for someone who wants to stay technical rather than moving purely into project management?"**
   *(Signals architect-track ambition; relevant given your 9-year background)*

5. **"Is there a specific gap in the team's current capabilities — a cloud or feature area where you'd particularly like to build depth — where my background could contribute most in the near term?"**
   *(Turns the conversation to mutual fit; shows confidence and collaborative mindset)*

---

*Prepared by Claude — Anthropic AI | April 2026*
*For: Saikiran Pasumarthy | PwC Senior Associate — FSL + Agentforce + Lightning (Bangalore)*
