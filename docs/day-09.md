# Day 09 — LWC Communication Patterns: Wire Adapters, Custom Events vs LMS

## Overview

Day 9 completes the communication pattern spectrum — adding Lightning Message Service (LMS) for cross-component communication, imperative Apex calls for dynamically-triggered server calls, `ShowToastEvent` for user feedback, and the `@api` getter/setter pattern for reactive prop side effects. A composition root (`accountDashboard`) demonstrates all patterns working together in a realistic multi-column layout.

---

## Communication Pattern Decision Matrix

```
Which pattern should I use?

Parent → Child (top-down data):
  └── @api property binding in parent template
      <c-child my-prop={value}>

Child → Parent (bottom-up event):
  └── Custom Event: dispatchEvent(new CustomEvent('name', { detail }))
      Parent listens: onname={handler}

Sibling / Unrelated components on same page:
  └── Lightning Message Service (LMS)
      Publisher: publish(messageContext, CHANNEL, message)
      Subscriber: subscribe(messageContext, CHANNEL, handler)

Multiple components reading same record (auto-sync):
  └── @wire(getRecord) via UI API / Lightning Data Service

State that survives navigation:
  └── URL state via NavigationMixin (PageReference.state)
```

---

## Lightning Message Channel

```xml
<!-- OpportunityFilter__c.messageChannel-meta.xml -->
<LightningMessageChannel>
    <masterLabel>Opportunity Filter</masterLabel>
    <isExposed>true</isExposed>
    <lightningMessageFields>
        <fieldName>stageFilter</fieldName>
        <description>Stage picklist value. 'All' = no filter.</description>
    </lightningMessageFields>
    <lightningMessageFields>
        <fieldName>minAmount</fieldName>
    </lightningMessageFields>
    <lightningMessageFields>
        <fieldName>accountId</fieldName>
    </lightningMessageFields>
</LightningMessageChannel>
```

Deploy to org before any LWC that imports it via `@salesforce/messageChannel/OpportunityFilter__c`.

---

## LMS Publisher — opportunityFilterBar

### Wire MessageContext (Required)

```js
import { MessageContext, publish } from 'lightning/messageService';
import CHANNEL from '@salesforce/messageChannel/OpportunityFilter__c';

@wire(MessageContext)
messageContext; // not { data, error } — this is a context handle, not a data wire
```

`@wire(MessageContext)` is unique — it does not return `{ data, error }`. It returns a context handle used by both `publish()` and `subscribe()`. It must always be wired, never instantiated manually.

### Publishing

```js
publish(this.messageContext, CHANNEL, {
    stageFilter: this.selectedStage,
    minAmount:   this.minAmount,
    accountId:   this._accountId
});
```

All components subscribed to `OpportunityFilter__c` on the same page receive this message simultaneously. The message object must match the channel's declared field schema.

### @api Getter/Setter Pattern

```js
_accountId;

@api
get accountId() { return this._accountId; }
set accountId(value) {
    this._accountId = value;
    if (value) this.publishFilter(); // side effect on prop change
}
```

Use getter/setter when setting an `@api` prop must trigger a side effect (publish LMS, call Apex, reset state). A plain `@api accountId` would render correctly but would not fire the initial publish when the accountId first arrives from the record page.

---

## LMS Subscriber — opportunityMetricsTile

### Subscribe / Unsubscribe Lifecycle Pair

```js
connectedCallback() {
    this._subscription = subscribe(
        this.messageContext,
        CHANNEL,
        (message) => this.handleFilterMessage(message),
        { scope: APPLICATION_SCOPE }   // or omit for DEFAULT (same page only)
    );
}

disconnectedCallback() {
    unsubscribe(this._subscription);
    this._subscription = null;
}
```

**Always pair subscribe/unsubscribe.** If `disconnectedCallback` does not call `unsubscribe()`:
- The subscription holds a reference to the component instance
- The instance cannot be garbage collected after DOM removal
- Messages continue firing `handleFilterMessage` on the destroyed instance
- In Lightning Experience (SPA), this accumulates across navigation events as a memory leak

### APPLICATION_SCOPE vs DEFAULT_SCOPE

| Scope | Receives messages from |
|---|---|
| `APPLICATION_SCOPE` | Any component on **any page** in the app (including utility bar) |
| DEFAULT (omit options) | Components on the **same Lightning page** only |

Use DEFAULT scope unless you explicitly need cross-page messaging (e.g., a utility bar component tracking navigation).

---

## Imperative Apex

### When to Use Imperative vs @wire

```js
// @wire — auto-fires, re-fires on reactive prop change, cached
@wire(getOpportunitiesForAccount, { accountId: '$accountId' })
wiredOpps;

// Imperative — full control, fires when YOU decide, no caching
async loadMetrics(stageFilter, minAmount) {
    this.isLoading = true;
    try {
        const result = await getOpportunityMetrics({
            accountId: this.accountId,
            stageFilter,
            minAmount
        });
        this.metrics = result;
    } catch (error) {
        // handle error
    } finally {
        this.isLoading = false;
    }
}
```

**Use imperative when:**
- The Apex method is `cacheable=false` (DML, callouts)
- Call timing is driven by an event (LMS message, button click) not a prop change
- You need full loading/error state control
- The method parameters are not tied to `@api` props

### refreshApex() — Invalidating the Wire Cache After DML

```js
import { refreshApex } from 'lightning/uiRecordApi';

// Store the full wire result (not destructured)
@wire(getOpportunitiesForAccount, { accountId: '$accountId' })
wiredOpps;

// After a DML operation:
async handleSaveClick() {
    await saveRecord({ ... }); // DML
    await refreshApex(this.wiredOpps); // invalidate + re-fetch
}
```

`refreshApex()` forces a re-fetch of the wired data, bypassing the LDS cache. It requires the wire result to be stored as a whole (`this.wiredOpps`) rather than destructured (`{ data: opps, error }`) because `refreshApex` needs the full wire result object.

---

## ShowToastEvent

```js
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

this.dispatchEvent(new ShowToastEvent({
    title:   'Error loading metrics',
    message: 'Unexpected error occurred.',
    variant: 'error',    // 'success' | 'warning' | 'error' | 'info'
    mode:    'dismissable' // 'dismissable' | 'sticky' | 'pester'
}));
```

`ShowToastEvent` bubbles up to the nearest `LightningApp` or `LightningRecordPage`. It cannot be used in Experience Cloud components that run outside a Lightning context — use platform events or a custom notification component instead.

---

## Component Architecture (Days 8 + 9 Combined)

```
accountDashboard  (composition root)
  │
  ├── opportunityFilterBar        [LMS PUBLISHER]
  │     @api getter/setter → publish on accountId arrival
  │     handleApplyFilters → publish(OpportunityFilter__c)
  │
  ├── accountSummaryCard          [Day 8 — @wire UI API]
  │     → c-opportunity-list → c-discount-badge
  │
  ├── opportunityMetricsTile      [LMS SUBSCRIBER + Imperative Apex]
  │     subscribe(OpportunityFilter__c) in connectedCallback
  │     unsubscribe() in disconnectedCallback
  │     handleFilterMessage → loadMetrics() [async imperative]
  │     ShowToastEvent on error
  │
  └── opportunityList             [Day 8 — @wire Apex, custom events]
        → c-discount-badge
```

`opportunityFilterBar` and `opportunityMetricsTile` have no parent-child relationship — they sit in separate columns in `accountDashboard`. LMS is the only wire between them.

---

## Test Coverage

| Class | Methods | What Is Tested |
|---|---|---|
| `AccountDashboardControllerDay9Test` | 5 | No filter (open only), stage filter, min amount filter, null accountId, discount fields populated |

LWC LMS testing with Jest's `@salesforce/messageChannel` mock is covered in Day 11.

---

## Interview Talking Points

### "What is Lightning Message Service and when do you use it?"
LMS is the platform-native cross-component communication mechanism for LWC. Use it when two components have no parent-child relationship — e.g., a filter bar in one region and a data table in another region of the same Lightning page. LMS replaced the legacy community pubsub pattern and Aura application events. It's lifecycle-aware (subscriptions scoped to the component), page-scoped (DEFAULT scope), and works across LWC and Aura on the same page.

### "What's the difference between APPLICATION_SCOPE and DEFAULT scope in LMS?"
DEFAULT scope (the default when no options are passed) subscribes to messages published by components on the same Lightning page only. APPLICATION_SCOPE receives messages from components on any page in the application, including utility bar items. Use DEFAULT unless you explicitly need cross-page messaging.

### "Why is unsubscribing from LMS in disconnectedCallback critical?"
Without `unsubscribe()`, the LMS subscription holds a reference to the component instance, preventing garbage collection. In Lightning Experience (a single-page app), navigating away from a page removes the component from DOM but the ghost subscription continues to receive and process messages on the destroyed instance. This is a memory leak that compounds with each navigation event.

### "When do you use imperative Apex instead of @wire?"
Use imperative when: (1) the method is `cacheable=false` (DML, callouts — @wire requires cacheable=true), (2) call timing is controlled by user actions or events (not reactive prop changes), (3) you need full loading/error state control, (4) you want to avoid auto-firing the method on every reactive prop change. Use `async/await` with `try/catch/finally` — `finally` ensures the loading spinner always clears even on error.

### "What is refreshApex() and when do you call it?"
`refreshApex(wiredResult)` invalidates the LDS cache for a specific wired result and triggers a fresh server call. Call it after DML that changes data your wire depends on. The wire result must be stored as a whole object reference (not destructured) — `refreshApex` needs the internal wire metadata that destructuring discards.

### "What is the @api getter/setter pattern and when is it needed?"
Use `get`/`set` instead of a plain `@api` property when setting the property must trigger a side effect: publishing an LMS message, calling Apex, resetting derived state, or validating the value. A plain `@api` only triggers re-renders — it cannot execute code. The setter runs synchronously when the parent sets the property, making it the right place for initialization logic that depends on an external value arriving.
