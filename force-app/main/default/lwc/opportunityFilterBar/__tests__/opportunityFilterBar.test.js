/**
 * @description opportunityFilterBar.test.js
 *
 *              Tests demonstrating Lightning Message Service (LMS) mock patterns:
 *              1. jest.mock('lightning/messageService') — replace publish/subscribe
 *                 with jest.fn() spies so we can assert call arguments
 *              2. @api setter side effect — verify publish fires when accountId arrives
 *              3. Simulating UI interactions (change events on child components)
 *
 *              Why mock lightning/messageService entirely?
 *                The LMS runtime requires a full Lightning page context that doesn't
 *                exist in Jest (jsdom). Mocking the module replaces the real publish()
 *                with a jest.fn() spy — the component calls the real code path, but
 *                the spy records every call and its arguments for assertions.
 *
 *              @api getter/setter pattern:
 *                When a parent sets accountId, the setter runs synchronously.
 *                Tests verify that publishFilter() (which calls publish()) is called
 *                as a direct consequence of the setter — no await needed.
 *
 * @author  Saikiran Pasumarthy
 * @date    2026-03-31
 */
import { createElement } from 'lwc';
import OpportunityFilterBar from 'c/opportunityFilterBar';

/**
 * Mock the entire lightning/messageService module.
 *
 * jest.mock() is hoisted to the top of the module by Babel before any imports.
 * The factory function returns the mock object. We capture `publish` as a spy
 * so tests can call publish.mock.calls to inspect arguments.
 *
 * MessageContext: the @wire(MessageContext) adapter must receive a value —
 * we provide an empty object so the wire resolves without errors.
 */
jest.mock('lightning/messageService', () => {
    const mockPublish   = jest.fn();
    const mockSubscribe = jest.fn().mockReturnValue({ id: 'test-sub-handle' });
    const mockUnsubscribe = jest.fn();
    return {
        publish:           mockPublish,
        subscribe:         mockSubscribe,
        unsubscribe:       mockUnsubscribe,
        APPLICATION_SCOPE: 'APPLICATION_SCOPE',
        MessageContext:    {}
    };
}, { virtual: false });

// Import AFTER mock so the spy reference is stable
import { publish } from 'lightning/messageService';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const flushPromises = () => Promise.resolve();

function createComponent(accountId) {
    const el = createElement('c-opportunity-filter-bar', { is: OpportunityFilterBar });
    if (accountId) el.accountId = accountId;
    document.body.appendChild(el);
    return el;
}

/** Fire a custom change event on a child lightning component */
function fireChangeEvent(el, selector, value) {
    const input = el.shadowRoot.querySelector(selector);
    input.dispatchEvent(new CustomEvent('change', {
        detail:  { value },
        bubbles: true
    }));
}

// ─── Suite ────────────────────────────────────────────────────────────────────

describe('c-opportunity-filter-bar', () => {

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        publish.mockClear();
    });

    // ── @api setter ────────────────────────────────────────────────────────────

    it('does NOT publish when mounted without accountId', () => {
        createComponent(); // no accountId
        expect(publish).not.toHaveBeenCalled();
    });

    it('publishes immediately when accountId setter receives a value', () => {
        /**
         * The setter: set accountId(value) { this._accountId = value; if (value) this.publishFilter(); }
         * Setting el.accountId before appendChild still calls the setter,
         * but the component isn't wired yet. Setting AFTER appendChild calls
         * the setter with a live messageContext.
         */
        const el = createElement('c-opportunity-filter-bar', { is: OpportunityFilterBar });
        document.body.appendChild(el);

        // Set accountId after mount — setter fires with live messageContext
        el.accountId = '001000000000001AAA';

        expect(publish).toHaveBeenCalledTimes(1);
    });

    it('publishes with stageFilter: All by default', () => {
        const el = createElement('c-opportunity-filter-bar', { is: OpportunityFilterBar });
        document.body.appendChild(el);
        el.accountId = '001000000000001AAA';

        const message = publish.mock.calls[0][2]; // 3rd arg is the message payload
        expect(message.stageFilter).toBe('All');
    });

    it('publishes with minAmount: 0 by default', () => {
        const el = createElement('c-opportunity-filter-bar', { is: OpportunityFilterBar });
        document.body.appendChild(el);
        el.accountId = '001000000000001AAA';

        const message = publish.mock.calls[0][2];
        expect(message.minAmount).toBe(0);
    });

    // ── Apply filters ──────────────────────────────────────────────────────────

    it('publishes updated stageFilter when Apply Filters is clicked', async () => {
        const el = createComponent('001000000000001AAA');
        publish.mockClear(); // clear the initial setter publish

        // Simulate stage change
        fireChangeEvent(el, 'lightning-combobox', 'Closed Won');
        await flushPromises();

        // Click Apply Filters button
        const applyBtn = el.shadowRoot.querySelector('[data-id="apply-btn"]');
        applyBtn?.click();
        await flushPromises();

        expect(publish).toHaveBeenCalledTimes(1);
        const message = publish.mock.calls[0][2];
        expect(message.stageFilter).toBe('Closed Won');
    });

    it('publishes updated minAmount when Apply Filters is clicked', async () => {
        const el = createComponent('001000000000001AAA');
        publish.mockClear();

        fireChangeEvent(el, 'lightning-input', 50000);
        await flushPromises();

        const applyBtn = el.shadowRoot.querySelector('[data-id="apply-btn"]');
        applyBtn?.click();
        await flushPromises();

        const message = publish.mock.calls[0][2];
        expect(message.minAmount).toBe(50000);
    });

    // ── Reset ──────────────────────────────────────────────────────────────────

    it('resets stage and amount to defaults and publishes on Reset', async () => {
        const el = createComponent('001000000000001AAA');
        publish.mockClear();

        // Set a non-default stage first
        fireChangeEvent(el, 'lightning-combobox', 'Closed Won');
        await flushPromises();

        const resetBtn = el.shadowRoot.querySelector('[data-id="reset-btn"]');
        resetBtn?.click();
        await flushPromises();

        expect(publish).toHaveBeenCalledTimes(1);
        const message = publish.mock.calls[0][2];
        expect(message.stageFilter).toBe('All');
        expect(message.minAmount).toBe(0);
    });

    // ── Message channel ────────────────────────────────────────────────────────

    it('passes the accountId in the published message payload', () => {
        const el = createElement('c-opportunity-filter-bar', { is: OpportunityFilterBar });
        document.body.appendChild(el);
        el.accountId = '001000000000099AAA';

        const message = publish.mock.calls[0][2];
        expect(message.accountId).toBe('001000000000099AAA');
    });
});
