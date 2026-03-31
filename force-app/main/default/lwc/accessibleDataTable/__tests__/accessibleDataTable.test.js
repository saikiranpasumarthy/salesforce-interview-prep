/**
 * @description accessibleDataTable.test.js
 *
 *              Tests demonstrating LWC accessibility testing patterns:
 *              1. ARIA attribute assertions (role, aria-sort, aria-label, tabindex)
 *              2. Roving tabindex — only one focusable cell at a time
 *              3. Keyboard event simulation via dispatchEvent(new KeyboardEvent(...))
 *              4. aria-live region content after sort
 *              5. Empty state rendering
 *
 *              Key testing rules for accessibility:
 *              • Test ARIA attributes on the DOM element, not computed properties
 *              • aria-sort must cycle: none → ascending → descending → ascending
 *              • Only ONE element per grid should have tabindex="0"
 *              • Keyboard events must use bubbles:true to propagate to the grid listener
 *
 *              Why test accessibility in Jest (not just E2E)?
 *                ARIA attribute correctness can be fully verified in jsdom without
 *                a real browser. Keyboard navigation logic lives in JS — unit tests
 *                catch regressions far faster than E2E accessibility scanners.
 *                Use Jest for ARIA correctness; use axe-core / Lighthouse for
 *                contrast ratios and focus visibility (visual properties jsdom can't measure).
 *
 * @author  Saikiran Pasumarthy
 * @date    2026-03-31
 */
import { createElement } from 'lwc';
import AccessibleDataTable from 'c/accessibleDataTable';

// ─── Mock data ─────────────────────────────────────────────────────────────────

const COLUMNS = [
    { label: 'Name',   fieldName: 'name',   sortable: true  },
    { label: 'Stage',  fieldName: 'stage',  sortable: true  },
    { label: 'Amount', fieldName: 'amount', sortable: false }
];

const DATA = [
    { id: '1', name: 'Acme Deal',  stage: 'Prospecting', amount: '$50,000' },
    { id: '2', name: 'Beta Corp',  stage: 'Closed Won',  amount: '$120,000' },
    { id: '3', name: 'Gamma Inc',  stage: 'Proposal',    amount: '$75,000' }
];

// ─── Helpers ───────────────────────────────────────────────────────────────────

const flushPromises = () => new Promise(resolve => setTimeout(resolve, 0));

function createComponent(data = DATA, columns = COLUMNS) {
    const el = createElement('c-accessible-data-table', { is: AccessibleDataTable });
    el.columns = columns;
    el.data    = data;
    document.body.appendChild(el);
    return el;
}

/** Fire a keyboard event on an element, bubbling up to the grid */
function fireKey(el, selector, key) {
    const target = el.shadowRoot.querySelector(selector);
    target?.dispatchEvent(new KeyboardEvent('keydown', {
        key,
        bubbles:    true,
        cancelable: true,
        composed:   false   // stays within shadow boundary
    }));
    return target;
}

// ─── Suite ─────────────────────────────────────────────────────────────────────

describe('c-accessible-data-table', () => {

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    // ── Structure ──────────────────────────────────────────────────────────────

    it('renders a grid with role="grid"', () => {
        const el = createComponent();
        const grid = el.shadowRoot.querySelector('[role="grid"]');
        expect(grid).not.toBeNull();
    });

    it('renders the correct number of data rows', () => {
        const el = createComponent();
        const rows = el.shadowRoot.querySelectorAll('[role="row"]');
        // header row + 3 data rows = 4
        expect(rows.length).toBe(4);
    });

    it('renders the correct number of column headers', () => {
        const el = createComponent();
        const headers = el.shadowRoot.querySelectorAll('[role="columnheader"]');
        expect(headers.length).toBe(COLUMNS.length);
    });

    it('sets aria-rowcount to total rows including header', () => {
        const el = createComponent();
        const grid = el.shadowRoot.querySelector('[role="grid"]');
        expect(grid.getAttribute('aria-rowcount')).toBe('4'); // 3 data + 1 header
    });

    it('sets aria-colcount to number of columns', () => {
        const el = createComponent();
        const grid = el.shadowRoot.querySelector('[role="grid"]');
        expect(grid.getAttribute('aria-colcount')).toBe('3');
    });

    it('renders column header labels', () => {
        const el = createComponent();
        const headers = el.shadowRoot.querySelectorAll('[role="columnheader"] .col-label');
        const labels  = Array.from(headers).map(h => h.textContent);
        expect(labels).toEqual(['Name', 'Stage', 'Amount']);
    });

    // ── aria-sort ──────────────────────────────────────────────────────────────

    it('sets aria-sort="none" on sortable columns initially', () => {
        const el = createComponent();
        const headers = el.shadowRoot.querySelectorAll('[role="columnheader"]');
        // Name (index 0) — sortable
        expect(headers[0].getAttribute('aria-sort')).toBe('none');
        // Stage (index 1) — sortable
        expect(headers[1].getAttribute('aria-sort')).toBe('none');
    });

    it('does not set aria-sort on non-sortable columns', () => {
        const el = createComponent();
        const headers = el.shadowRoot.querySelectorAll('[role="columnheader"]');
        // Amount (index 2) — not sortable → aria-sort must be absent (null)
        expect(headers[2].getAttribute('aria-sort')).toBeNull();
    });

    it('cycles aria-sort from none → ascending on first click', async () => {
        const el = createComponent();
        const nameHeader = el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]');
        nameHeader.click();
        await flushPromises();

        const updated = el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]');
        expect(updated.getAttribute('aria-sort')).toBe('ascending');
    });

    it('cycles aria-sort from ascending → descending on second click', async () => {
        const el = createComponent();
        const header = el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]');
        header.click();
        await flushPromises();

        const header2 = el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]');
        header2.click();
        await flushPromises();

        const header3 = el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]');
        expect(header3.getAttribute('aria-sort')).toBe('descending');
    });

    it('resets other columns to aria-sort="none" when a different column is sorted', async () => {
        const el = createComponent();

        // Sort Name column first
        el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]').click();
        await flushPromises();

        // Then sort Stage column
        el.shadowRoot.querySelector('[role="columnheader"][data-col="1"]').click();
        await flushPromises();

        const nameHeader  = el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]');
        const stageHeader = el.shadowRoot.querySelector('[role="columnheader"][data-col="1"]');
        expect(nameHeader.getAttribute('aria-sort')).toBe('none');
        expect(stageHeader.getAttribute('aria-sort')).toBe('ascending');
    });

    // ── aria-live announcement ─────────────────────────────────────────────────

    it('updates aria-live region with sort announcement after column click', async () => {
        const el = createComponent();
        el.shadowRoot.querySelector('[role="columnheader"][data-col="0"]').click();
        await flushPromises();

        const announce = el.shadowRoot.querySelector('[data-id="announce"]');
        expect(announce.textContent).toContain('Name');
        expect(announce.textContent).toContain('ascending');
    });

    // ── Roving tabindex ────────────────────────────────────────────────────────

    it('gives tabindex="0" only to the first header cell initially', () => {
        const el = createComponent();
        const allFocusable = el.shadowRoot.querySelectorAll(
            '[role="columnheader"], [role="gridcell"]'
        );
        const withZero = Array.from(allFocusable).filter(
            c => c.getAttribute('tabindex') === '0'
        );
        expect(withZero.length).toBe(1);
        expect(withZero[0].getAttribute('data-row')).toBe('0');
        expect(withZero[0].getAttribute('data-col')).toBe('0');
    });

    it('moves tabindex="0" to the next header cell on ArrowRight', async () => {
        const el = createComponent();

        fireKey(el, '[role="grid"]', 'ArrowRight');
        await flushPromises();

        const focusedCell = el.shadowRoot.querySelector('[tabindex="0"]');
        expect(focusedCell.getAttribute('data-row')).toBe('0');
        expect(focusedCell.getAttribute('data-col')).toBe('1');
    });

    it('moves tabindex="0" down one row on ArrowDown', async () => {
        const el = createComponent();

        fireKey(el, '[role="grid"]', 'ArrowDown');
        await flushPromises();

        const focusedCell = el.shadowRoot.querySelector('[tabindex="0"]');
        expect(focusedCell.getAttribute('data-row')).toBe('1');
        expect(focusedCell.getAttribute('data-col')).toBe('0');
    });

    it('does not move focus above header row on ArrowUp from header', async () => {
        const el = createComponent();

        fireKey(el, '[role="grid"]', 'ArrowUp');
        await flushPromises();

        // Focus should still be on row 0
        const focusedCell = el.shadowRoot.querySelector('[tabindex="0"]');
        expect(focusedCell.getAttribute('data-row')).toBe('0');
    });

    it('does not move focus past last column on ArrowRight from last column', async () => {
        const el = createComponent();

        // Move to last column
        fireKey(el, '[role="grid"]', 'ArrowRight');
        await flushPromises();
        fireKey(el, '[role="grid"]', 'ArrowRight');
        await flushPromises();
        // One more — should clamp at max
        fireKey(el, '[role="grid"]', 'ArrowRight');
        await flushPromises();

        const focusedCell = el.shadowRoot.querySelector('[tabindex="0"]');
        expect(focusedCell.getAttribute('data-col')).toBe('2'); // last column (0-based)
    });

    it('ensures only one cell has tabindex="0" after navigation', async () => {
        const el = createComponent();

        fireKey(el, '[role="grid"]', 'ArrowDown');
        await flushPromises();
        fireKey(el, '[role="grid"]', 'ArrowRight');
        await flushPromises();

        const allCells = el.shadowRoot.querySelectorAll(
            '[role="columnheader"], [role="gridcell"]'
        );
        const zeroTabCells = Array.from(allCells).filter(
            c => c.getAttribute('tabindex') === '0'
        );
        expect(zeroTabCells.length).toBe(1);
    });

    // ── Empty state ────────────────────────────────────────────────────────────

    it('renders empty state message when data is empty', () => {
        const el = createComponent([]);
        const emptyCell = el.shadowRoot.querySelector('.empty-cell');
        expect(emptyCell).not.toBeNull();
        expect(emptyCell.textContent).toBe('No records found.');
    });

    it('renders no data rows when data is empty', () => {
        const el = createComponent([]);
        const cells = el.shadowRoot.querySelectorAll('.grid-cell');
        expect(cells.length).toBe(0);
    });
});
