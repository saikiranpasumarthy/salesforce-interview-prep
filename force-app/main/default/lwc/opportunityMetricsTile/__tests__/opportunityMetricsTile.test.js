/**
 * @description opportunityMetricsTile.test.js
 *
 *              Tests demonstrating imperative Apex + LMS subscriber patterns:
 *              1. jest.mock for imperative Apex — mockResolvedValue / mockRejectedValue
 *              2. LMS subscribe/unsubscribe lifecycle assertions
 *              3. Simulating an incoming LMS message by calling the captured handler
 *              4. ShowToastEvent interception via addEventListener
 *              5. isLoading spinner toggling during async Apex call
 *
 *              Imperative Apex mock pattern:
 *                jest.mock('@salesforce/apex/...', () => ({ default: jest.fn() }), { virtual: true })
 *                Then in tests: getOpportunityMetrics.mockResolvedValue(data)
 *                               getOpportunityMetrics.mockRejectedValue(error)
 *
 *              LMS subscriber test strategy:
 *                subscribe() is mocked — the component calls subscribe(ctx, channel, handler).
 *                Capture the handler via subscribe.mock.calls[0][2].
 *                Call handler(mockMessage) to simulate an incoming LMS message.
 *                Assert that Apex was called with the message parameters.
 *
 * @author  Saikiran Pasumarthy
 * @date    2026-03-31
 */

/**
 * IMPORTANT: jest.mock calls are HOISTED before imports by Babel's
 * babel-jest transform. The factory function runs BEFORE any import
 * statement in the file. This is why we can reference the mocked module
 * in imports below even though jest.mock appears after them visually.
 */
jest.mock(
    '@salesforce/apex/AccountDashboardController.getOpportunityMetrics',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock('lightning/messageService', () => ({
    publish:           jest.fn(),
    subscribe:         jest.fn().mockReturnValue({ id: 'test-sub' }),
    unsubscribe:       jest.fn(),
    APPLICATION_SCOPE: 'APPLICATION_SCOPE',
    MessageContext:    {}
}), { virtual: false });

jest.mock('lightning/platformShowToastEvent', () => ({
    ShowToastEvent: jest.fn().mockImplementation((params) => ({
        ...params, type: 'toast'
    }))
}), { virtual: false });

import { createElement }           from 'lwc';
import OpportunityMetricsTile      from 'c/opportunityMetricsTile';
import getOpportunityMetrics       from '@salesforce/apex/AccountDashboardController.getOpportunityMetrics';
import { subscribe, unsubscribe }  from 'lightning/messageService';

// ─── Mock data ─────────────────────────────────────────────────────────────────

const MOCK_METRICS = {
    openCount:          5,
    totalPipeline:      750000,
    avgDiscount:        8.5,
    discountedPipeline: 686250
};

const ACCOUNT_ID = '001000000000001AAA';

// ─── Helpers ───────────────────────────────────────────────────────────────────

/** Flush all pending microtasks and macrotasks */
const flushPromises = () => new Promise(resolve => setTimeout(resolve, 0));

function createComponent(accountId = ACCOUNT_ID) {
    const el = createElement('c-opportunity-metrics-tile', { is: OpportunityMetricsTile });
    el.accountId = accountId;
    // Default: resolve immediately so isLoading tests are clear
    getOpportunityMetrics.mockResolvedValue(MOCK_METRICS);
    document.body.appendChild(el);
    return el;
}

/** Get the subscribe handler captured during connectedCallback */
function getCapturedSubscribeHandler() {
    // subscribe(messageContext, channel, handler, options) — handler is 3rd arg
    return subscribe.mock.calls[0]?.[2];
}

// ─── Suite ─────────────────────────────────────────────────────────────────────

describe('c-opportunity-metrics-tile', () => {

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // ── LMS lifecycle ──────────────────────────────────────────────────────────

    it('subscribes to the LMS channel in connectedCallback', () => {
        createComponent();
        expect(subscribe).toHaveBeenCalledTimes(1);
    });

    it('unsubscribes from the LMS channel in disconnectedCallback', async () => {
        const el = createComponent();
        await flushPromises();

        document.body.removeChild(el);

        expect(unsubscribe).toHaveBeenCalledTimes(1);
        expect(unsubscribe).toHaveBeenCalledWith({ id: 'test-sub' });
    });

    it('subscribes with APPLICATION_SCOPE', () => {
        createComponent();
        const options = subscribe.mock.calls[0][3]; // 4th arg
        expect(options.scope).toBe('APPLICATION_SCOPE');
    });

    // ── Initial metrics load ───────────────────────────────────────────────────

    it('calls getOpportunityMetrics with no filter on mount', async () => {
        createComponent();
        await flushPromises();

        expect(getOpportunityMetrics).toHaveBeenCalledWith({
            accountId:   ACCOUNT_ID,
            stageFilter: 'All',
            minAmount:   0
        });
    });

    it('renders openCount after successful metrics load', async () => {
        const el = createComponent();
        await flushPromises();

        const metricValues = el.shadowRoot.querySelectorAll('.metric-value');
        const openCountEl  = Array.from(metricValues).find(
            (v) => v.closest('.metric-tile')?.querySelector('.metric-label')?.textContent === 'Open Opportunities'
        );
        expect(openCountEl?.textContent).toBe('5');
    });

    // ── LMS message handling ───────────────────────────────────────────────────

    it('calls getOpportunityMetrics with filter params from LMS message', async () => {
        createComponent();
        await flushPromises();
        getOpportunityMetrics.mockClear();

        // Simulate incoming LMS message by calling the captured handler
        const handler = getCapturedSubscribeHandler();
        handler({
            stageFilter: 'Closed Won',
            minAmount:   50000,
            accountId:   ACCOUNT_ID
        });
        await flushPromises();

        expect(getOpportunityMetrics).toHaveBeenCalledWith({
            accountId:   ACCOUNT_ID,
            stageFilter: 'Closed Won',
            minAmount:   50000
        });
    });

    it('shows active filter badge when non-default filter received', async () => {
        const el = createComponent();
        await flushPromises();

        const handler = getCapturedSubscribeHandler();
        handler({ stageFilter: 'Prospecting', minAmount: 0, accountId: ACCOUNT_ID });
        await flushPromises();

        const badge = el.shadowRoot.querySelector('.filter-badge');
        expect(badge).not.toBeNull();
        expect(badge.textContent).toContain('Prospecting');
    });

    // ── Error handling ─────────────────────────────────────────────────────────

    it('shows error message panel when getOpportunityMetrics rejects', async () => {
        getOpportunityMetrics.mockRejectedValue({
            body: { message: 'Insufficient permissions' }
        });
        const el = createComponent();
        await flushPromises();

        const errorEl = el.shadowRoot.querySelector('[role="alert"]');
        expect(errorEl).not.toBeNull();
        expect(errorEl.textContent).toContain('Insufficient permissions');
    });

    it('dispatches ShowToastEvent with error variant when Apex rejects', async () => {
        getOpportunityMetrics.mockRejectedValue({
            body: { message: 'Server error' }
        });
        const el = createComponent();

        const toastHandler = jest.fn();
        el.addEventListener('lightning__showtoast', toastHandler);

        await flushPromises();

        // ShowToastEvent fires dispatchEvent internally; verify the constructor was called
        const { ShowToastEvent } = await import('lightning/platformShowToastEvent');
        expect(ShowToastEvent).toHaveBeenCalledWith(
            expect.objectContaining({ variant: 'error' })
        );
    });

    // ── Loading spinner ────────────────────────────────────────────────────────

    it('hides spinner after successful metrics load', async () => {
        const el = createComponent();
        await flushPromises();

        const spinner = el.shadowRoot.querySelector('lightning-spinner');
        expect(spinner).toBeNull();
    });

    it('hides spinner even when Apex rejects (finally block)', async () => {
        getOpportunityMetrics.mockRejectedValue({ body: { message: 'Error' } });
        const el = createComponent();
        await flushPromises();

        const spinner = el.shadowRoot.querySelector('lightning-spinner');
        expect(spinner).toBeNull();
    });
});
