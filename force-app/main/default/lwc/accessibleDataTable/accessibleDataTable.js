/**
 * @description accessibleDataTable — ARIA grid with roving tabindex, column
 *              sorting, keyboard navigation, and live-region announcements.
 *
 *              WCAG requirements met:
 *                1.3.1  Info and Relationships — table semantics via ARIA grid roles
 *                2.1.1  Keyboard             — all functionality via keyboard
 *                2.4.3  Focus Order           — logical DOM order; roving tabindex
 *                4.1.2  Name, Role, Value     — aria-sort, aria-label, aria-rowcount
 *
 *              Roving tabindex algorithm:
 *                _focusRow and _focusCol track the currently "active" cell.
 *                _buildRows() stamps tabIndex=0 on the active cell, -1 on all others.
 *                Moving focus: update _focusRow/_focusCol → _buildRows() → re-render
 *                → browser shifts tab stop → call focusActiveCell() to move DOM focus.
 *
 *              Sort state machine per column:
 *                'none' → 'ascending' → 'descending' → 'ascending' (cycle)
 *
 *              Interview concepts:
 *                - @api getter/setter for columns/data triggers rebuild on change
 *                - Pure computed derivation: rows array rebuilt from _data + sort state
 *                - No direct DOM manipulation (no querySelector in sort/keyboard logic)
 *                  except the single focusActiveCell() call after tabindex update
 *
 * @author  Saikiran Pasumarthy
 * @date    2026-03-31
 */
import { LightningElement, api, track } from 'lwc';

const SORT_CYCLE = { none: 'ascending', ascending: 'descending', descending: 'ascending' };
const SORT_ICONS = { none: 'utility:arrowdown', ascending: 'utility:arrowup', descending: 'utility:arrowdown' };

export default class AccessibleDataTable extends LightningElement {

    // ─── @api ─────────────────────────────────────────────────────────────────

    @api gridLabel   = 'Data Table';
    @api emptyMessage = 'No records found.';

    @api
    get columns() { return this._columns; }
    set columns(value) {
        this._columns  = Array.isArray(value) ? value : [];
        this._sortState = {};
        this._columns.forEach(c => { this._sortState[c.fieldName] = 'none'; });
        this._rebuild();
    }

    @api
    get data() { return this._data; }
    set data(value) {
        this._data = Array.isArray(value) ? value : [];
        this._rebuild();
    }

    // ─── Private state ────────────────────────────────────────────────────────

    _columns   = [];
    _data      = [];
    _sortState = {};   // { fieldName: 'none'|'ascending'|'descending' }
    _sortField = null; // currently sorted column
    _focusRow  = 0;    // 0 = header row, 1..n = data rows
    _focusCol  = 0;    // 0-based column index

    @track columns  = [];  // enriched column descriptors for template
    @track rows     = [];  // enriched row descriptors for template
    @track announcement = '';

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        this._rebuild();
    }

    // ─── Public rebuild ───────────────────────────────────────────────────────

    _rebuild() {
        this._buildColumns();
        this._buildRows();
    }

    // ─── Column builder ───────────────────────────────────────────────────────

    _buildColumns() {
        this.columns = this._columns.map((col, i) => ({
            ...col,
            colIndex:        i + 1,          // aria-colindex is 1-based
            colZeroIndex:    i,              // data-col attribute (0-based for JS)
            ariaSortValue:   col.sortable ? (this._sortState[col.fieldName] ?? 'none') : undefined,
            sortIconName:    col.sortable ? SORT_ICONS[this._sortState[col.fieldName] ?? 'none'] : undefined,
            headerClass:     this._headerClass(col, i),
            headerTabIndex:  (this._focusRow === 0 && this._focusCol === i) ? '0' : '-1'
        }));
    }

    _headerClass(col, i) {
        let cls = 'grid-header-cell';
        if (col.sortable) cls += ' sortable';
        if (this._sortField === col.fieldName) cls += ' sorted';
        if (this._focusRow === 0 && this._focusCol === i) cls += ' focused';
        return cls;
    }

    // ─── Row builder ──────────────────────────────────────────────────────────

    _buildRows() {
        let data = [...this._data];

        // Apply sort
        if (this._sortField) {
            const dir = this._sortState[this._sortField];
            data.sort((a, b) => {
                const av = a[this._sortField] ?? '';
                const bv = b[this._sortField] ?? '';
                const cmp = String(av).localeCompare(String(bv), undefined, { numeric: true });
                return dir === 'descending' ? -cmp : cmp;
            });
        }

        this.rows = data.map((record, rowIdx) => ({
            _key:        record.id ?? record.Id ?? String(rowIdx),
            rowZeroIndex: rowIdx + 1,          // 0 = header row; data rows start at 1
            ariaRowIndex: rowIdx + 2,          // aria-rowindex is 1-based; header = 1
            rowClass:    rowIdx % 2 === 0 ? 'grid-row grid-row--even' : 'grid-row grid-row--odd',
            cells:       this._columns.map((col, colIdx) => ({
                key:         `${rowIdx}-${colIdx}`,
                value:       record[col.fieldName] ?? '',
                colIndex:    colIdx + 1,
                colZeroIndex: colIdx,
                tabIndex:    (this._focusRow === rowIdx + 1 && this._focusCol === colIdx) ? '0' : '-1'
            }))
        }));
    }

    // ─── Computed getters ──────────────────────────────────────────────────────

    get columnCount() { return this._columns.length; }

    get ariaRowCount() {
        // +1 for header row
        return this._data.length + 1;
    }

    get isEmpty() { return this._data.length === 0; }

    // ─── Header click / keyboard ───────────────────────────────────────────────

    handleHeaderClick(event) {
        const colIdx = Number(event.currentTarget.dataset.col);
        const col    = this._columns[colIdx];
        if (!col?.sortable) return;
        this._applySort(col.fieldName);
        this._focusRow = 0;
        this._focusCol = colIdx;
        this._rebuild();
    }

    handleHeaderKeyDown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            const colIdx = Number(event.currentTarget.dataset.col);
            const col    = this._columns[colIdx];
            if (col?.sortable) this._applySort(col.fieldName);
            this._rebuild();
        }
    }

    _applySort(fieldName) {
        const current = this._sortState[fieldName] ?? 'none';
        const next    = SORT_CYCLE[current];
        // Reset all other columns to 'none'
        Object.keys(this._sortState).forEach(k => { this._sortState[k] = 'none'; });
        this._sortState[fieldName] = next;
        this._sortField = fieldName;

        const col = this._columns.find(c => c.fieldName === fieldName);
        this.announcement = `Sorted by ${col?.label ?? fieldName} ${next}`;
    }

    // ─── Grid keyboard navigation (roving tabindex) ────────────────────────────

    /**
     * Handles arrow key navigation on the grid container.
     *
     * Why listen on the grid container instead of each cell?
     *   Event delegation: one listener catches keydown from all focusable
     *   descendants. Avoids attaching N handlers for N cells.
     *
     * Navigation model:
     *   Row 0   = header row
     *   Row 1..n = data rows (matching this.rows array, 1-indexed)
     *   Col 0..m-1 = column index
     */
    handleKeyDown(event) {
        const { key } = event;
        if (!['ArrowRight','ArrowLeft','ArrowDown','ArrowUp','Home','End'].includes(key)) return;

        event.preventDefault(); // block page scroll

        const maxRow = this.rows.length; // 0=header, 1..maxRow=data rows
        const maxCol = this._columns.length - 1;

        let row = this._focusRow;
        let col = this._focusCol;

        switch (key) {
            case 'ArrowRight': col = Math.min(col + 1, maxCol); break;
            case 'ArrowLeft':  col = Math.max(col - 1, 0);      break;
            case 'ArrowDown':  row = Math.min(row + 1, maxRow); break;
            case 'ArrowUp':    row = Math.max(row - 1, 0);      break;
            case 'Home':       col = 0;                          break;
            case 'End':        col = maxCol;                     break;
            default: break;
        }

        if (row === this._focusRow && col === this._focusCol) return; // no change

        this._focusRow = row;
        this._focusCol = col;
        this._rebuild();

        // After re-render, move DOM focus to the newly active cell
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => this._focusActiveCell());
    }

    /**
     * Moves DOM focus to the cell matching _focusRow / _focusCol.
     * Called after re-render so the tabindex="0" element is in the DOM.
     *
     * Note: this.template.querySelector is used here because we need
     * imperative focus control. This is one of the legitimate cases for
     * querySelector — we cannot use a declarative binding to call .focus().
     */
    _focusActiveCell() {
        const selector = `[data-row="${this._focusRow}"][data-col="${this._focusCol}"]`;
        const cell = this.template.querySelector(selector);
        cell?.focus();
    }
}
