# Day 08 — LWC Architecture: Lifecycle, Shadow DOM & Wire Adapters

## Overview

Day 8 builds three interconnected LWC components that demonstrate the core architectural concepts tested in every Senior / Architect interview: the full component lifecycle, Shadow DOM CSS encapsulation, `@wire` with both UI API and custom Apex, conditional rendering with `lwc:if`, and child-to-parent event communication.

---

## Component Hierarchy

```
accountSummaryCard  (parent — record page component)
  │  @wire(getRecord)        — UI API, no Apex needed for standard fields
  │  @wire(getOpportunityCount) — custom Apex cacheable method
  │
  └── c-opportunity-list     (child — mounted/unmounted via lwc:if)
        │  @wire(getOpportunitiesForAccount) — Apex wrapper for Opportunity data
        │  Client-side filter (text + stage pills)
        │  dispatchEvent('opportunityselected', { bubbles: true, composed: false })
        │
        └── c-discount-badge (leaf — pure presentational)
              @api discountPercent
              @api finalPrice
              Computed CSS class badge (none / low / medium / high)
```

---

## Component Lifecycle Deep Dive

### Sequence on First Render

```
constructor()
  ↓  (no DOM, no this.template, no events)
connectedCallback()
  ↓  (in DOM, not rendered — subscribe LMS here)
[Framework calls render() internally]
  ↓
renderedCallback()
  ↓  (DOM available — this.template.querySelector works here)
[User navigates away / lwc:if becomes false]
  ↓
disconnectedCallback()
  ↓  (remove listeners, unsubscribe LMS — ALWAYS pair with connectedCallback)
```

### Constructor Rules

```js
constructor() {
    super(); // ALWAYS first — non-negotiable
    // ✅ CAN: initialise private properties, set defaults
    // ❌ CANNOT: access this.template
    // ❌ CANNOT: dispatch events (not in DOM yet)
}
```

### connectedCallback Rules

```js
connectedCallback() {
    // ✅ CAN: subscribe to LMS MessageChannel
    // ✅ CAN: add document/window event listeners
    // ✅ CAN: dispatch events (component is now in DOM tree)
    // ❌ CANNOT: this.template.querySelector (not rendered yet)
}
```

### renderedCallback Rules

```js
renderedCallback() {
    // Fires after EVERY render — not just the first.
    // ✅ CAN: this.template.querySelector / querySelectorAll
    // ✅ CAN: set CSS custom properties on this.template.host
    // ⚠️  MUST guard mutations with a flag/counter to prevent infinite loops:
    this.renderCount++;
    if (this.renderCount === 1) {
        // First-render-only logic here
    }
}
```

### disconnectedCallback Rules

```js
disconnectedCallback() {
    // Fires when component leaves the DOM (lwc:if=false, navigation, destroy)
    // ✅ MUST: unsubscribe LMS, remove event listeners, cancel timers
    // Missing this = memory leak + ghost event handlers firing after removal
}
```

### lwc:if vs CSS hide — Critical Distinction

| Approach | Component state | disconnectedCallback | Memory |
|---|---|---|---|
| `lwc:if={show}` becomes false | **DESTROYED** | Fires ✅ | Released |
| `class={hideClass}` / `display:none` | **ALIVE** | Does NOT fire | Held |

Use `lwc:if` when lifecycle cleanup is needed (LMS subscriptions, timers).
Use CSS hiding when the component must preserve internal state across show/hide cycles.

---

## @wire Deep Dive

### UI API — getRecord

```js
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import NAME_FIELD from '@salesforce/schema/Account.Name';

@wire(getRecord, { recordId: '$accountId', fields: [NAME_FIELD] })
account;

get accountName() {
    return getFieldValue(this.account?.data, NAME_FIELD);
}
```

**Why UI API over Apex for standard fields?**
- Auto-cached and auto-invalidated by Lightning Data Service (LDS)
- No Apex class required
- Updates reflect across ALL components on the page using the same record
- Respects FLS automatically

**`$` reactive prefix:**
- `'$accountId'` re-fires the wire whenever `this.accountId` changes
- `'accountId'` (no `$`) treats the value as a static string literal — the wire fires once at mount and never again

### Custom Apex Wire

```js
import getOpportunityCount from '@salesforce/apex/AccountDashboardController.getOpportunityCount';

@wire(getOpportunityCount, { accountId: '$accountId' })
opportunityCount;
```

**`cacheable=true` is mandatory for `@wire`:**
- Non-cacheable methods (DML, callouts) must be called imperatively
- Cached results are stored per `(userId, methodName, params)` — same user + same params returns the cached result without a server round-trip
- Invalidate the cache with `refreshApex(this.opportunityCount)` after a DML operation

### Wire Result Shape

```js
// Always destructure with both data and error guards
get value() {
    if (this.wiredResult?.data) { /* happy path */ }
    if (this.wiredResult?.error) { /* error path */ }
    // Both can be null during initial loading
}
```

---

## Shadow DOM CSS Encapsulation

### What Shadow DOM Means for CSS

```
┌─ accountSummaryCard shadow root ─────────────────────────┐
│  .account-card { border-left: 4px solid blue; }          │
│                                                           │
│  ┌─ opportunityList shadow root ──────────────────────┐  │
│  │  .account-card { color: red; }  ← different rule!  │  │
│  └────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

Both `.account-card` rules exist simultaneously without conflict. The browser enforces the boundary — this is not a naming convention.

### `:host` Selector

```css
:host {
    display: block; /* LWC components default to inline */
}
```

`:host` targets the custom element tag itself (`<c-account-summary-card>`). Use it to control how the component participates in its parent's layout without the parent needing to know the component's internal structure.

### CSS Custom Properties Cross Shadow Boundaries

```css
/* In parent or global theme */
:root { --brand-color: #0176d3; }

/* In child component — this WORKS even across shadow roots */
.account-card { border-color: var(--brand-color, #0176d3); }
```

CSS Custom Properties (`--token-name`) are the **intentional holes** in Shadow DOM encapsulation. They enable theming without breaking encapsulation. The `var(token, fallback)` pattern ensures the component renders correctly even when the token is not set.

---

## @api, @track, and Reactivity

### @api — Public Properties

```js
@api accountId; // settable by parent, reactive to parent changes
```

Rules:
1. **Never mutate `@api` from inside the component** — it is a one-way downward binding
2. `@api` props are `undefined` before the parent sets them — always null-guard in getters
3. HTML attribute names are **kebab-case** → JS property names are **camelCase**:
   `discount-percent` in HTML → `discountPercent` in JS (`@api discountPercent`)

### @track — When It Is (and Isn't) Required

Since Spring '20:
- **Primitives** (`String`, `Number`, `Boolean`, `null`) — auto-tracked, no `@track` needed
- **Object/Array reassignment** (`this.items = [...newList]`) — auto-tracked, no `@track` needed
- **Object/Array in-place mutation** (`this.items[0].selected = true`) — **requires `@track`**

Best practice: prefer reassignment (`this.items = this.items.map(...)`) over in-place mutation to stay `@track`-free.

---

## Custom Events

### Dispatch Pattern

```js
this.dispatchEvent(new CustomEvent('opportunityselected', {
    detail: { opportunityId: oppId }, // payload — any serialisable value
    bubbles:  true,  // propagates up through the DOM inside the shadow root
    composed: false  // does NOT cross shadow root boundaries automatically
}));
```

### bubbles vs composed

| Flag | Meaning |
|---|---|
| `bubbles: false` (default) | Event handled only at the dispatching element |
| `bubbles: true` | Event propagates up through the same shadow root |
| `composed: false` (default) | Event stops at the shadow root boundary |
| `composed: true` | Event crosses shadow root boundaries (rarely needed) |

For parent-child communication, `bubbles: true, composed: false` is the standard pattern. The parent listens with `onopportunityselected` in its template.

---

## Apex Controller Design

### cacheable=true Restrictions

```apex
@AuraEnabled(cacheable=true) // ← required for @wire
public static Integer getOpportunityCount(Id accountId) {
    // ✅ SOQL allowed
    // ❌ NO DML, NO callouts, NO setSavepoint
}
```

### Wrapper Pattern

```apex
public class OpportunityWrapper {
    @AuraEnabled public String  id;
    @AuraEnabled public Decimal discountPercent;
    @AuraEnabled public Decimal finalPrice;
    // ...
}
```

LWC cannot traverse SObject relationships directly from raw SOQL results (e.g., `opp.Account.Name` is not available in the wire result). Wrappers flatten the data structure, include computed/formatted fields, and ensure LWC receives exactly what it needs without additional JS-side transformation.

---

## Test Coverage

| Test Class | Methods | What Is Tested |
|---|---|---|
| `AccountDashboardControllerTest` | 7 | Open opp count, null guards, empty account, wrapper field mapping, discount percent stamped, close date formatting, ordered results |

LWC component testing with Jest is covered in Day 11.

---

## Interview Talking Points

### "Walk me through the LWC component lifecycle."
`constructor()` — instance created, no DOM; `connectedCallback()` — inserted into DOM, not rendered; `renderedCallback()` — fires after every render, DOM available, must guard mutations; `disconnectedCallback()` — fires when removed from DOM, unsubscribe/cleanup here.

### "What is Shadow DOM and how does it affect CSS?"
Shadow DOM creates a scoped subtree per component. CSS inside a component's stylesheet matches only elements within that component's shadow root — it cannot leak out, and parent CSS cannot reach in. The only intentional holes are CSS Custom Properties (`var(--token)`) which cross shadow boundaries for theming.

### "What's the difference between `@wire` with UI API and with Apex?"
UI API (`getRecord`, `getRelatedListRecords`) is cached by Lightning Data Service — updates to a record are reflected across all components using it simultaneously, with no Apex code. Apex `@wire` requires `cacheable=true`, adds server-side business logic capability, but the cache is keyed per `(userId, method, params)` and requires `refreshApex()` to invalidate after DML.

### "When does `@track` still matter in LWC?"
Only when you mutate an Object or Array **in place** without reassignment: `this.items[0].flag = true`. For all primitives and for Object/Array reassignment, auto-tracking handles reactivity since Spring '20. Best practice is to always reassign rather than mutate in place, which eliminates the need for `@track` entirely.

### "What's the difference between `lwc:if` and hiding with CSS?"
`lwc:if={false}` **destroys** the component — `disconnectedCallback()` fires, DOM is removed, state is lost. CSS hiding keeps the component alive in the DOM tree — no lifecycle callbacks fire, state is preserved. Use `lwc:if` when cleanup is needed (LMS, timers). Use CSS when state must survive hide/show cycles.

### "Explain `bubbles` and `composed` on a CustomEvent."
`bubbles: true` allows the event to propagate up through the DOM within the same shadow root. `composed: true` allows it to cross shadow root boundaries. For standard parent-child communication, `bubbles: true, composed: false` is sufficient and is the most common pattern. `composed: true` is rarely needed and can cause unexpected event handling in deeply nested component trees.
