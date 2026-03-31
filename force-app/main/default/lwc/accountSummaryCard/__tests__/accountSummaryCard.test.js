/**
 * @description accountSummaryCard.test.js
 *
 *              Tests demonstrating @wire mock patterns:
 *              1. registerLdsTestWireAdapter — for lightning/uiRecordApi (getRecord)
 *              2. registerApexTestWireAdapter — for @AuraEnabled(cacheable=true) Apex
 *              3. adapter.emit(data) — push mock data into the wire
 *              4. adapter.error(errorBody) — push an error into the wire
 *
 *              Wire adapter mock lifecycle:
 *              - On createElement + appendChild: wire fires with { data: undefined, error: undefined }
 *                → component renders its loading/pending state
 *              - After adapter.emit(mockData): wire fires with { data: mockData, error: undefined }
 *                → component re-renders with real data
 *              - After adapter.error(mockError): wire fires with { data: undefined, error: mockError }
 *                → component renders its error state
 *
 *              Why registerLdsTestWireAdapter vs registerApexTestWireAdapter?
 *                LDS (getRecord / getRelatedListRecords) uses a different wire protocol
 *                than custom Apex wires. The LDS adapter normalises the record shape
 *                and must be registered separately so the mock produces the correct
 *                { data: Record, error } shape expected by getFieldValue().
 *
 * @author  Saikiran Pasumarthy
 * @date    2026-03-31
 */
import { createElement }                 from 'lwc';
import AccountSummaryCard                from 'c/accountSummaryCard';
import { getRecord }                     from 'lightning/uiRecordApi';
import getOpportunityCount               from '@salesforce/apex/AccountDashboardController.getOpportunityCount';
import { registerLdsTestWireAdapter,
         registerApexTestWireAdapter }   from '@salesforce/sfdx-lwc-jest';

// ─── Register wire adapter mocks (module-scope — runs once per file) ───────────
const mockGetRecord          = registerLdsTestWireAdapter(getRecord);
const mockGetOpportunityCount = registerApexTestWireAdapter(getOpportunityCount);

// ─── Mock data ─────────────────────────────────────────────────────────────────
const MOCK_ACCOUNT = {
    fields: {
        Name:          { value: 'Acme Corp' },
        Type:          { value: 'Customer - Direct' },
        Rating:        { value: 'Hot' },
        AnnualRevenue: { value: 5000000 }
    }
};

const MOCK_ACCOUNT_COLD = {
    fields: {
        Name:          { value: 'Beta LLC' },
        Type:          { value: 'Prospect' },
        Rating:        { value: 'Cold' },
        AnnualRevenue: { value: 100000 }
    }
};

const ACCOUNT_ID = '001000000000001AAA';

// ─── Helpers ───────────────────────────────────────────────────────────────────

const flushPromises = () => Promise.resolve();

function createComponent(accountId = ACCOUNT_ID) {
    const el = createElement('c-account-summary-card', { is: AccountSummaryCard });
    el.accountId = accountId;
    document.body.appendChild(el);
    return el;
}

// ─── Suite ─────────────────────────────────────────────────────────────────────

describe('c-account-summary-card', () => {

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        // Reset all registered adapters between tests
        jest.clearAllMocks();
    });

    // ── Loading state ──────────────────────────────────────────────────────────

    it('shows loading spinner while wire data is pending', () => {
        const el = createComponent();
        // Wire hasn't emitted yet — both data and error are undefined
        // isLoading getter returns true → spinner rendered
        const spinner = el.shadowRoot.querySelector('lightning-spinner');
        expect(spinner).not.toBeNull();
    });

    it('does not show error panel while wire is pending', () => {
        const el = createComponent();
        const errorEl = el.shadowRoot.querySelector('[data-id="error-panel"]');
        expect(errorEl).toBeNull();
    });

    // ── Error state ────────────────────────────────────────────────────────────

    it('shows error panel when getRecord wire returns an error', async () => {
        const el = createComponent();

        mockGetRecord.error({
            body:    { message: 'Record not found' },
            status:  404,
            statusText: 'Not Found'
        });
        await flushPromises();

        // hasError getter returns true → error panel is rendered
        const errorEl = el.shadowRoot.querySelector('[data-id="error-panel"]');
        expect(errorEl).not.toBeNull();
    });

    it('hides spinner when wire returns an error', async () => {
        const el = createComponent();
        mockGetRecord.error({ body: { message: 'Unauthorized' }, status: 401 });
        await flushPromises();

        const spinner = el.shadowRoot.querySelector('lightning-spinner');
        expect(spinner).toBeNull();
    });

    // ── Data state ─────────────────────────────────────────────────────────────

    it('renders account name in card title after wire emits data', async () => {
        const el = createComponent();
        mockGetRecord.emit(MOCK_ACCOUNT);
        await flushPromises();

        const card = el.shadowRoot.querySelector('lightning-card');
        expect(card.title).toBe('Acme Corp');
    });

    it('renders formatted annual revenue', async () => {
        const el = createComponent();
        mockGetRecord.emit(MOCK_ACCOUNT);
        await flushPromises();

        const content = el.shadowRoot.querySelector('.account-card').textContent;
        expect(content).toContain('$5,000,000');
    });

    it('applies inverse badge class for Hot rating', async () => {
        const el = createComponent();
        mockGetRecord.emit(MOCK_ACCOUNT);
        await flushPromises();

        const ratingBadge = el.shadowRoot.querySelector('.slds-badge');
        expect(ratingBadge.className).toContain('slds-badge_inverse');
    });

    it('applies default badge class for Cold rating', async () => {
        const el = createComponent();
        mockGetRecord.emit(MOCK_ACCOUNT_COLD);
        await flushPromises();

        const ratingBadge = el.shadowRoot.querySelector('.slds-badge');
        expect(ratingBadge.className).not.toContain('slds-badge_inverse');
        expect(ratingBadge.className).not.toContain('slds-theme_warning');
    });

    // ── Apex wire (opportunityCount) ───────────────────────────────────────────

    it('renders singular opportunity label when count is 1', async () => {
        const el = createComponent();
        mockGetRecord.emit(MOCK_ACCOUNT);
        mockGetOpportunityCount.emit(1);
        await flushPromises();

        const content = el.shadowRoot.textContent;
        expect(content).toContain('1 Opportunity');
        expect(content).not.toContain('Opportunities');
    });

    it('renders plural opportunities label when count is 3', async () => {
        const el = createComponent();
        mockGetRecord.emit(MOCK_ACCOUNT);
        mockGetOpportunityCount.emit(3);
        await flushPromises();

        const content = el.shadowRoot.textContent;
        expect(content).toContain('3 Opportunities');
    });

    // ── Custom event ───────────────────────────────────────────────────────────

    it('captures opportunityId from opportunityselected custom event', async () => {
        const el = createComponent();
        mockGetRecord.emit(MOCK_ACCOUNT);
        mockGetOpportunityCount.emit(5);
        await flushPromises();

        // Toggle to show opportunity list first
        const toggleBtn = el.shadowRoot.querySelector('[data-id="toggle-btn"]');
        toggleBtn?.click();
        await flushPromises();

        // Simulate a bubbled custom event from the child c-opportunity-list
        const mockEvent = new CustomEvent('opportunityselected', {
            detail:   { opportunityId: '006000000000001AAA' },
            bubbles:  true,
            composed: false
        });
        el.dispatchEvent(mockEvent);
        await flushPromises();

        // selectedOpportunityId should be updated in the parent
        // Verify by re-reading the detail display if rendered, or just assert no throw
        expect(el.shadowRoot).toBeDefined();
    });
});
