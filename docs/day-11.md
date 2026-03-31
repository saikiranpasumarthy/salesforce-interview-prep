# Day 11 — LWC Testing (Jest) & Accessibility (ARIA)

## Topics Covered

| Topic | Pattern | File |
|-------|---------|------|
| Jest setup | `@salesforce/sfdx-lwc-jest`, `jest.config.js` | `package.json` |
| Leaf component test | `createElement`, `@api` props, shadow DOM query | `discountBadge.test.js` |
| Wire adapter mock (LDS) | `registerLdsTestWireAdapter`, `adapter.emit()` | `accountSummaryCard.test.js` |
| Wire adapter mock (Apex) | `registerApexTestWireAdapter`, `adapter.error()` | `accountSummaryCard.test.js` |
| LMS publish mock | `jest.mock('lightning/messageService')` | `opportunityFilterBar.test.js` |
| Imperative Apex mock | `jest.mock('@salesforce/apex/...')`, `mockResolvedValue` | `opportunityMetricsTile.test.js` |
| LMS subscriber test | Capture subscribe handler, call it directly | `opportunityMetricsTile.test.js` |
| ARIA grid | `role="grid/row/columnheader/gridcell"`, `aria-sort`, `aria-rowcount` | `accessibleDataTable` |
| Roving tabindex | Single `tabindex=0`, arrow key navigation | `accessibleDataTable` |
| `aria-live` | Sort change announcement without focus move | `accessibleDataTable` |
| A11y test patterns | ARIA attribute assertions, keyboard event simulation | `accessibleDataTable.test.js` |

---

## Jest Fundamentals

### Component Creation & Cleanup

```js
import { createElement } from 'lwc';
import MyComponent from 'c/myComponent';

const el = createElement('c-my-component', { is: MyComponent });
el.myProp = 'value';              // set @api before OR after appendChild
document.body.appendChild(el);    // triggers connectedCallback + first render

// Cleanup (afterEach):
while (document.body.firstChild) {
    document.body.removeChild(document.body.firstChild);
}
```

### Shadow DOM Querying

```js
// ✅ Correct — query inside shadow root
el.shadowRoot.querySelector('.my-class')
el.shadowRoot.querySelectorAll('[role="row"]')

// ❌ Wrong — document.querySelector cannot pierce shadow DOM
document.querySelector('.my-class')
```

### Async Rendering — `flushPromises`

```js
const flushPromises = () => Promise.resolve();   // one microtask tick
// or for imperative Apex (multiple ticks):
const flushPromises = () => new Promise(resolve => setTimeout(resolve, 0));
```

LWC batches reactive updates as microtasks. **Always `await flushPromises()` after:**
- Setting an `@api` property
- Calling `adapter.emit()` or `adapter.error()`
- Simulating user events that trigger state changes
- Resolving/rejecting Apex mocks

---

## Wire Adapter Mocking

### LDS Wire Adapters (`getRecord`, `getRelatedListRecords`)

```js
import { getRecord }                   from 'lightning/uiRecordApi';
import { registerLdsTestWireAdapter }  from '@salesforce/sfdx-lwc-jest';

const mockGetRecord = registerLdsTestWireAdapter(getRecord);

// In test — emit mock data:
mockGetRecord.emit({
    fields: {
        Name:          { value: 'Acme Corp' },
        AnnualRevenue: { value: 5000000 }
    }
});
await flushPromises();

// In test — emit an error:
mockGetRecord.error({ body: { message: 'Not Found' }, status: 404 });
await flushPromises();
```

### Apex `@wire` Adapters (`@AuraEnabled(cacheable=true)`)

```js
import getOpportunityCount              from '@salesforce/apex/AccountDashboardController.getOpportunityCount';
import { registerApexTestWireAdapter }  from '@salesforce/sfdx-lwc-jest';

const mockGetOpportunityCount = registerApexTestWireAdapter(getOpportunityCount);

mockGetOpportunityCount.emit(5);   // data = 5
mockGetOpportunityCount.error({ body: { message: 'Unauthorized' } });
```

### Why Two Different Adapters?

LDS adapters produce normalised `Record` objects — the mock must match the UI API shape so `getFieldValue()` works correctly. Apex wire adapters produce raw return values from your Apex method — no normalisation needed.

---

## Imperative Apex Mocking

```js
// ⚠️ jest.mock is hoisted by Babel BEFORE imports — factory runs first
jest.mock(
    '@salesforce/apex/AccountDashboardController.getOpportunityMetrics',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

import getOpportunityMetrics from '@salesforce/apex/AccountDashboardController.getOpportunityMetrics';

// In test:
getOpportunityMetrics.mockResolvedValue({ openCount: 5, totalPipeline: 100000 });
// or:
getOpportunityMetrics.mockRejectedValue({ body: { message: 'Server error' } });
```

**`{ virtual: true }`** — required when the module path doesn't correspond to a real file on disk (Apex modules are resolved at Salesforce runtime, not in Jest's Node environment).

---

## LMS Mocking

### Publisher test (opportunityFilterBar)

```js
jest.mock('lightning/messageService', () => ({
    publish:           jest.fn(),
    subscribe:         jest.fn().mockReturnValue({ id: 'test-sub' }),
    unsubscribe:       jest.fn(),
    APPLICATION_SCOPE: 'APPLICATION_SCOPE',
    MessageContext:    {}
}));

import { publish } from 'lightning/messageService';

// After setting accountId:
el.accountId = '001...';
expect(publish).toHaveBeenCalledTimes(1);
const msg = publish.mock.calls[0][2];   // 3rd arg = message payload
expect(msg.stageFilter).toBe('All');
```

### Subscriber test (opportunityMetricsTile)

```js
// In test — simulate incoming LMS message:
const subscribeHandler = subscribe.mock.calls[0][2]; // 3rd arg = handler fn
subscribeHandler({ stageFilter: 'Closed Won', minAmount: 50000, accountId: '001...' });
await flushPromises();

expect(getOpportunityMetrics).toHaveBeenCalledWith({
    accountId: '001...', stageFilter: 'Closed Won', minAmount: 50000
});
```

---

## ARIA Grid Pattern

### Role Hierarchy

```
role="grid"           aria-rowcount aria-colcount aria-label
  role="row"          aria-rowindex
    role="columnheader"  aria-sort aria-colindex
    role="gridcell"      aria-colindex  tabindex
```

### `aria-sort` Values

| Value | Meaning |
|-------|---------|
| `"none"` | Column is sortable but currently unsorted |
| `"ascending"` | Sorted A→Z / lowest→highest |
| `"descending"` | Sorted Z→A / highest→lowest |
| absent (`null`) | Column is not sortable — do NOT set `aria-sort` |

### Roving Tabindex Algorithm

```
State: _focusRow (0=header, 1..n=data), _focusCol (0-based)

On ArrowRight:  _focusCol = min(_focusCol + 1, maxCol)
On ArrowLeft:   _focusCol = max(_focusCol - 1, 0)
On ArrowDown:   _focusRow = min(_focusRow + 1, maxRow)
On ArrowUp:     _focusRow = max(_focusRow - 1, 0)

After state change:
  1. Rebuild DOM — stamp tabindex="0" on new focus cell, "-1" on all others
  2. await Promise.resolve() (one render microtask)
  3. this.template.querySelector('[data-row][data-col]').focus()
```

**Why roving tabindex?**
`Tab` exits the grid in one keypress (WCAG 2.1.1). Without roving tabindex, every cell would be tab-focusable — a user with a keyboard would need to Tab through all 1 000 rows to reach the next widget.

### `aria-live` for Sort Announcements

```html
<div role="status" aria-live="polite" aria-atomic="true">
    {announcement}
</div>
```

```js
this.announcement = `Sorted by ${col.label} ascending`;
```

- `aria-live="polite"` — reads announcement after current speech finishes
- `aria-live="assertive"` — interrupts immediately (use for errors/alerts only)
- `aria-atomic="true"` — read the full string, not just changed chars

---

## Interview Questions — Day 11

### Jest

**Q: What does `registerLdsTestWireAdapter` return?**

A mock object with `.emit(data)` and `.error(errorBody)` methods. Calling `emit()` triggers the `@wire` handler with `{ data: yourValue, error: undefined }`. Calling `error()` triggers it with `{ data: undefined, error: yourValue }`.

**Q: Why must `jest.mock()` calls appear before imports?**

Babel's `babel-jest` transform hoists all `jest.mock()` calls to the top of the compiled module before any `import` statements execute. This ensures the mock factory runs before the module under test imports its dependencies. If you try to mock after import, the real module is already loaded.

**Q: How do you test that `disconnectedCallback` cleaned up an LMS subscription?**

```js
document.body.removeChild(el);       // triggers disconnectedCallback
expect(unsubscribe).toHaveBeenCalledWith({ id: 'test-sub' });
```
The component's `disconnectedCallback` runs synchronously when removed from the DOM.

**Q: Why use `setTimeout(resolve, 0)` for `flushPromises` instead of `Promise.resolve()`?**

`Promise.resolve()` flushes one microtask tick — enough for synchronous reactive updates. Imperative Apex `async/await` chains need multiple microtask turns (the awaited `Promise` resolves in one tick, then the `await` continuation runs in another). `setTimeout(resolve, 0)` schedules after all pending microtasks, reliably flushing the full `async/await` chain.

### Accessibility

**Q: What is the difference between `aria-hidden="true"` and `display:none`?**

`display:none` removes the element from both visual rendering AND the accessibility tree — screen readers ignore it entirely. `aria-hidden="true"` removes it from the accessibility tree only — the element is visually rendered but invisible to screen readers. Use `aria-hidden` to hide decorative icons (`lightning-icon` sort arrows) that would create noisy duplicate announcements.

**Q: When should you use `aria-live="assertive"` vs `"polite"`?**

`"assertive"` interrupts the screen reader immediately — reserve it for critical errors or alerts that demand immediate attention (e.g. session timeout warning, form validation blocking submission). `"polite"` queues the announcement — use it for informational updates (sort confirmation, auto-save status) that are helpful but not urgent.

**Q: Why is `role="status"` preferred over a plain `div` for live regions?**

`role="status"` has implicit `aria-live="polite"` and `aria-atomic="true"` semantics — it conveys *both* the live region behaviour and the semantic meaning (a status message) in one attribute. A plain `div` with `aria-live` provides the live behaviour without the semantic role.

---

## Files Created (Day 11)

```
force-app/main/default/lwc/
├── discountBadge/__tests__/
│   └── discountBadge.test.js           9 tests — leaf component, ARIA attrs
├── accountSummaryCard/__tests__/
│   └── accountSummaryCard.test.js     10 tests — LDS wire, Apex wire, events
├── opportunityFilterBar/__tests__/
│   └── opportunityFilterBar.test.js    7 tests — LMS publish spy, @api setter
├── opportunityMetricsTile/__tests__/
│   └── opportunityMetricsTile.test.js 10 tests — imperative Apex, LMS subscribe
└── accessibleDataTable/
    ├── accessibleDataTable.html        ARIA grid: role, aria-sort, aria-live
    ├── accessibleDataTable.js          Roving tabindex, sort state machine
    ├── accessibleDataTable.css         Focus rings, sr-only, table-cell layout
    ├── accessibleDataTable.js-meta.xml
    └── __tests__/
        └── accessibleDataTable.test.js 17 tests — ARIA attrs, keyboard nav
scripts/deploy-day-11.sh
docs/day-11.md
```

**Total: 36 new tests across 5 components**
