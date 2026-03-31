/**
 * @description discountBadge.test.js
 *
 *              Tests for the simplest LWC unit — a pure leaf component with
 *              no @wire, no events, no side effects. Only @api props → rendered HTML.
 *
 *              Key Jest patterns demonstrated:
 *              1. createElement() + document.body.appendChild()
 *              2. Setting @api properties before and after mount
 *              3. Querying shadow DOM via element.shadowRoot.querySelector()
 *              4. afterEach cleanup — remove component from body between tests
 *              5. Promise.resolve() — flush LWC rendering microtask queue
 *
 *              Why Promise.resolve() after setting @api props?
 *                LWC batches reactive updates and processes them asynchronously
 *                via microtasks. Setting an @api prop does NOT synchronously
 *                re-render the template — you must await a microtask tick
 *                before asserting the new DOM state.
 *
 * @author  Saikiran Pasumarthy
 * @date    2026-03-31
 */
import { createElement } from 'lwc';
import DiscountBadge     from 'c/discountBadge';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Flush all pending LWC render microtasks */
const flushPromises = () => Promise.resolve();

/** Mount a discountBadge with optional prop overrides */
function createComponent(props = {}) {
    const element = createElement('c-discount-badge', { is: DiscountBadge });
    Object.assign(element, { discountPercent: 0, finalPrice: 0, ...props });
    document.body.appendChild(element);
    return element;
}

// ─── Suite ────────────────────────────────────────────────────────────────────

describe('c-discount-badge', () => {

    afterEach(() => {
        /**
         * Remove every child from document.body after each test.
         * Prevents component state from leaking between tests.
         * LWC calls disconnectedCallback() when removed from DOM — any
         * cleanup (observer.disconnect, unsubscribe) runs automatically.
         */
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    // ── Label tests ────────────────────────────────────────────────────────────

    it('renders "No discount" label when discountPercent is 0', () => {
        const el = createComponent({ discountPercent: 0 });
        const span = el.shadowRoot.querySelector('span');
        expect(span.textContent).toBe('No discount');
    });

    it('renders percentage label when discountPercent is positive', async () => {
        const el = createComponent({ discountPercent: 0 });

        // Set @api prop AFTER mount — must await a microtask for re-render
        el.discountPercent = 10;
        await flushPromises();

        const span = el.shadowRoot.querySelector('span');
        expect(span.textContent).toBe('10% off');
    });

    it('renders "No discount" when discountPercent is negative', async () => {
        const el = createComponent({ discountPercent: -5 });
        await flushPromises();
        const span = el.shadowRoot.querySelector('span');
        expect(span.textContent).toBe('No discount');
    });

    // ── CSS class tests ────────────────────────────────────────────────────────

    it('applies --none class modifier when discountPercent is 0', () => {
        const el = createComponent({ discountPercent: 0 });
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('discount-badge--none');
    });

    it('applies --low class modifier when discountPercent is between 1 and 9', async () => {
        const el = createComponent({ discountPercent: 5 });
        await flushPromises();
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('discount-badge--low');
        expect(span.className).not.toContain('discount-badge--medium');
    });

    it('applies --medium class modifier when discountPercent is between 10 and 14', async () => {
        const el = createComponent({ discountPercent: 12 });
        await flushPromises();
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('discount-badge--medium');
    });

    it('applies --high class modifier when discountPercent is 15 or above', async () => {
        const el = createComponent({ discountPercent: 15 });
        await flushPromises();
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('discount-badge--high');
    });

    // ── Accessibility tests ────────────────────────────────────────────────────

    it('sets aria-label reflecting the badge label', async () => {
        const el = createComponent({ discountPercent: 10 });
        await flushPromises();
        const span = el.shadowRoot.querySelector('span');
        expect(span.getAttribute('aria-label')).toBe('Discount: 10% off');
    });

    it('sets role="status" on the span for screen-reader announcements', () => {
        const el = createComponent({ discountPercent: 0 });
        const span = el.shadowRoot.querySelector('span');
        expect(span.getAttribute('role')).toBe('status');
    });

    it('sets title tooltip including final price when discount is applied', async () => {
        const el = createComponent({ discountPercent: 10, finalPrice: 90000 });
        await flushPromises();
        const span = el.shadowRoot.querySelector('span');
        expect(span.getAttribute('title')).toContain('10%');
        expect(span.getAttribute('title')).toContain('$90,000');
    });
});
