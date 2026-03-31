# Day 10 — LWC Advanced: NavigationMixin, Lazy Loading & Virtual Scrolling

## Topics Covered

| Topic | Concept | Component |
|-------|---------|-----------|
| NavigationMixin | `navigate()` + `generateUrl()` | `opportunityDetailPage` |
| PageReference types | recordPage, objectPage, namedPage, webPage | `opportunityDetailPage` |
| URL state | `c__` namespace, bookmarkable filters | `opportunityDetailPage` |
| CurrentPageReference | `@wire` adapter for current page | `opportunityDetailPage` |
| Lazy loading | IntersectionObserver + `lwc:ref` | `lazyLoadContainer` |
| Skeleton placeholder | Shimmer animation, `lwc:if` guard | `lazyLoadContainer` |
| Virtual scrolling | rAF-throttled scroll handler, spacer divs | `virtualList` |

---

## Component 1 — `opportunityDetailPage`

### NavigationMixin Pattern

```js
import { NavigationMixin } from 'lightning/navigation';
export default class MyComp extends NavigationMixin(LightningElement) { }
```

`NavigationMixin` is a **mixin** — it augments the class with two static symbols:

| Symbol | Purpose |
|--------|---------|
| `NavigationMixin.Navigate` | Immediately navigate the browser |
| `NavigationMixin.GenerateUrl` | Return `Promise<string>` without navigating |

### PageReference Anatomy

```js
{
  type:       'standard__recordPage',          // page type constant
  attributes: { recordId, objectApiName, actionName }, // required routing data
  state:      { c__stage: 'Prospecting' }      // URL query params (bookmarkable)
}
```

### PageReference Types

| `type` | Use case | Required `attributes` |
|--------|----------|-----------------------|
| `standard__recordPage` | View/edit/clone a record | `recordId`, `objectApiName`, `actionName` |
| `standard__objectPage` | Object list or New record form | `objectApiName`, `actionName` (`list`/`new`) |
| `standard__namedPage` | Built-in pages (Home, Chatter) | `pageName` |
| `standard__webPage` | External absolute URL | `url` |

### `actionName` Options for `standard__recordPage`

| `actionName` | Effect |
|---|---|
| `'view'` | Opens record detail page |
| `'edit'` | Opens record in edit mode |
| `'clone'` | Opens new record pre-populated from source |

### `attributes` vs `state`

| | `attributes` | `state` |
|--|---|---|
| Purpose | Required routing data | Optional URL query params |
| Survive back-nav? | N/A | ✅ Yes — persisted in URL |
| Namespace required? | No | ✅ Yes — prefix `c__` in LWC |
| Example | `recordId`, `actionName` | `c__stage`, `c__filter` |

### `generateUrl()` Pattern

```js
async getAccountUrl() {
    const url = await this[NavigationMixin.GenerateUrl]({
        type: 'standard__recordPage',
        attributes: { recordId: this.accountId, objectApiName: 'Account', actionName: 'view' }
    });
    return url; // '/lightning/r/Account/001.../view'
}
```

Use `generateUrl()` when you need a URL string for an `<a href>` without triggering navigation.

### `@wire(CurrentPageReference)`

```js
import { CurrentPageReference } from 'lightning/navigation';
@wire(CurrentPageReference) pageRef;
```

- Fires on initial load **and** on every page reference change (e.g. URL state update)
- Read URL state: `this.pageRef?.state?.c__stage`
- Determine current page type: `this.pageRef?.type`
- Useful in utility bar — re-fires when user navigates to another page

---

## Component 2 — `lazyLoadContainer`

### The Problem

LWC renders all `lwc:if=true` subtrees **synchronously** during `connectedCallback`. Heavy child components (with `@wire` calls, complex computed getters, deep DOM trees) add to initial Time-to-Interactive even when they are below the fold.

### IntersectionObserver Pattern

```js
connectedCallback() {
    // 1. Mount sentinel div (already in DOM via lwc:ref="sentinel")
    // 2. Attach observer after first microtask (refs need one render cycle)
    Promise.resolve().then(() => this._attachObserver());
}

_attachObserver() {
    this._observer = new IntersectionObserver(
        (entries) => this._onIntersect(entries),
        { root: null, rootMargin: '100px', threshold: 0 }
    );
    this._observer.observe(this.refs.sentinel);
}

_onIntersect(entries) {
    if (entries[0].isIntersecting) {
        this.isVisible = true;   // → lwc:if unmasks slot → child connectedCallback fires
        this._observer.disconnect(); // observe-once
    }
}

disconnectedCallback() {
    this._observer?.disconnect(); // prevent memory leak
}
```

### `lwc:ref` vs `querySelector`

| | `lwc:ref` | `querySelector` |
|--|---|---|
| Shadow boundary | ✅ Works inside own shadow | ❌ Cannot pierce shadow from parent |
| Available from | After first render cycle | After first render cycle |
| Syntax | `this.refs.myRef` | `this.template.querySelector('.my-class')` |
| Preferred? | ✅ Yes (W24+) | Only for pre-W24 or slot content |

### Skeleton Shimmer

CSS animation using `background-position` creates a "shimmer" effect without JavaScript:

```css
.skeleton {
    background: linear-gradient(90deg, #f3f3f3 25%, #e5e5e5 50%, #f3f3f3 75%);
    background-size: 200% 100%;
    animation: shimmer 1.4s infinite;
}
@keyframes shimmer {
    0%   { background-position: 200% 0; }
    100% { background-position: -200% 0; }
}
```

---

## Component 3 — `virtualList`

### The Problem

Rendering 10 000 `<div>` rows is O(n) DOM operations. The browser must layout, paint, and composite every node even if 9 900 are off-screen. Memory consumption grows linearly with row count.

### Virtual Scrolling Algorithm

```
totalHeight  = items.length * itemHeight        ← drives native scroll bar
startIndex   = Math.floor(scrollTop / itemHeight)
endIndex     = startIndex + visibleCount + BUFFER
topPad       = startIndex * itemHeight          ← spacer above visible rows
bottomPad    = (items.length - endIndex) * itemHeight ← spacer below
DOM rows     = items.slice(startIndex, endIndex) ← constant ≈ visibleCount + 2*BUFFER
```

### requestAnimationFrame Throttle

```js
handleScroll(event) {
    if (this._rafPending) return;     // skip if a frame is already queued
    this._rafPending = true;
    requestAnimationFrame(() => {
        this._rafPending = false;
        this._update(event.target.scrollTop);
    });
}
```

`requestAnimationFrame` coalesces rapid scroll events into one paint cycle (~16ms at 60fps), preventing layout thrashing from dozens of re-renders per scroll gesture.

### Performance Characteristics

| Metric | Without virtualisation | With virtualisation |
|--------|----------------------|-------------------|
| DOM nodes | O(n) — grows with dataset | O(1) — constant ≈ visibleCount |
| Memory | O(n) | O(1) |
| Initial paint | Slow for large n | Fast (same as small dataset) |
| Scroll smoothness | Degrades at >500 rows | Smooth at any n |

---

## Interview Questions — Day 10

### NavigationMixin

**Q: What is the difference between `navigate()` and `generateUrl()`?**

`navigate()` immediately changes the browser location. `generateUrl()` returns a `Promise<string>` with the URL without navigating — use it to bind `<a href>` elements or for analytics pre-fetching.

**Q: What is the `c__` prefix in URL state?**

URL state keys must be namespaced with `c__` (or your package namespace prefix) to avoid collisions with Salesforce platform-reserved URL parameters like `recordId`, `objectApiName`. Without the prefix, platform routing may strip or misinterpret your parameters.

**Q: When does `@wire(CurrentPageReference)` re-fire?**

On initial component load, and whenever the page reference changes — including when another component calls `navigate()` with updated `state` on the same page. This makes it suitable for reactive filter panels where URL state is the source of truth.

**Q: How do you pre-populate fields on a New record modal?**

Use `standard__objectPage` with `actionName: 'new'` and pass `defaultFieldValues` in `state`:
```js
state: { defaultFieldValues: 'AccountId=001...', navigationLocation: 'LOOKUP' }
```
For complex values, encode with `encodeDefaultFieldValues` from `lightning/pageReferenceUtils`.

### Lazy Loading

**Q: Why use IntersectionObserver instead of `setTimeout` for lazy loading?**

`setTimeout(0)` defers to the next event loop tick but renders regardless of visibility — a component in a hidden tab or below the fold still fires all `@wire` calls. `IntersectionObserver` fires only when the element actually enters the viewport, preventing unnecessary Apex round-trips and background processing.

**Q: Why must the observer be attached via `Promise.resolve().then(...)` in `connectedCallback`?**

`lwc:ref` references are populated after the first render cycle. `connectedCallback` fires before the component's template renders, so `this.refs.sentinel` is `undefined` at that moment. Deferring via `Promise.resolve()` schedules the attachment after the initial render microtask.

**Q: How do you prevent memory leaks from IntersectionObserver?**

Call `observer.disconnect()` in `disconnectedCallback`. Failing to disconnect keeps the observer alive, holding references to DOM elements and callbacks even after the component is removed from the page.

### Virtual Scrolling

**Q: Why keep a BUFFER of extra rows above and below the visible window?**

Without a buffer, fast scrolling reveals blank rows while the JavaScript calculates and renders the next window. A 3-row buffer above and below gives the browser a head start — by the time the user scrolls into the buffer zone, the real rows are already rendered.

**Q: What is the trade-off of uniform vs dynamic item heights in virtual lists?**

Uniform height enables O(1) position calculation (`startIndex = scrollTop / itemHeight`). Dynamic heights require measuring each rendered item and building a cumulative offset lookup table — more accurate but adds a `ResizeObserver` per row and O(n) measurement on data change.

---

## Files Created (Day 10)

```
force-app/main/default/lwc/
├── opportunityDetailPage/
│   ├── opportunityDetailPage.html         NavigationMixin button grid
│   ├── opportunityDetailPage.js           All 6 navigation methods + CurrentPageReference
│   ├── opportunityDetailPage.css          Monospace page-ref display
│   └── opportunityDetailPage.js-meta.xml  RecordPage + AppPage targets
├── lazyLoadContainer/
│   ├── lazyLoadContainer.html             Skeleton + slot reveal via lwc:if
│   ├── lazyLoadContainer.js               IntersectionObserver, lwc:ref, forceLoad @api
│   ├── lazyLoadContainer.css              Shimmer skeleton animation
│   └── lazyLoadContainer.js-meta.xml
└── virtualList/
    ├── virtualList.html                   Spacers + for:each visible slice
    ├── virtualList.js                     rAF-throttled scroll, _update() window calc
    ├── virtualList.css                    Scroll container + default row styles
    └── virtualList.js-meta.xml
scripts/deploy-day-10.sh
```
