/**
 * @description virtualList — virtual scrolling for large datasets.
 *
 *              Architecture:
 *              ┌─────────────────────────────────────────────┐
 *              │  scroll-container  (fixed height, overflow-y:scroll)  │
 *              │  ┌───────────────────────────────────────────┐        │
 *              │  │  topSpacer  (startIndex * itemHeight px)  │        │
 *              │  │  [row startIndex]                         │        │
 *              │  │  [row startIndex+1]  ← only VISIBLE_COUNT│        │
 *              │  │  …                    rows in DOM         │        │
 *              │  │  [row endIndex-1]                         │        │
 *              │  │  bottomSpacer  (remaining * itemHeight)   │        │
 *              │  └───────────────────────────────────────────┘        │
 *              └─────────────────────────────────────────────┘
 *
 *              Key calculations:
 *                startIndex  = Math.floor(scrollTop / itemHeight)
 *                endIndex    = min(startIndex + visibleCount + BUFFER, items.length)
 *                topPad      = startIndex * itemHeight  (px)
 *                bottomPad   = (items.length - endIndex) * itemHeight  (px)
 *                totalHeight = items.length * itemHeight  (px) — drives scroll bar
 *
 *              Performance characteristics:
 *                DOM nodes   = constant ≈ visibleCount + 2*BUFFER (independent of n)
 *                Scroll evt  = throttled via requestAnimationFrame; no debounce lag
 *                Re-renders  = only when startIndex changes (no render on same window)
 *
 *              @api items        Full dataset array (never sliced before passing in)
 *              @api itemHeight   Row height in pixels (must be uniform; dynamic heights
 *                                require an estimated height + dynamic measurement pass)
 *              @api containerHeight  Viewport height in pixels (default 400)
 *              @api labelField   Property name for the main label (default 'Name')
 *              @api subLabelField  Property name for sub-label (default 'StageName')
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api, track } from 'lwc';

/** Extra rows to render above/below visible area (reduces blank flash on fast scroll) */
const BUFFER = 3;

export default class VirtualList extends LightningElement {

    @api labelField    = 'Name';
    @api subLabelField = 'StageName';
    @api containerHeight = 400;

    @api
    get itemHeight() { return this._itemHeight; }
    set itemHeight(value) {
        this._itemHeight = Number(value) || 40;
        this._recalculate();
    }

    @api
    get items() { return this._items; }
    set items(value) {
        this._items = Array.isArray(value) ? value : [];
        this._recalculate();
    }

    // ─── Internal state ───────────────────────────────────────────────────────────

    @track visibleItems    = [];
    @track topSpacerStyle  = '';
    @track bottomSpacerStyle = '';
    @track containerStyle  = '';
    @track rowStyle        = '';

    _items        = [];
    _itemHeight   = 40;
    _startIndex   = 0;
    _rafPending   = false;

    // ─── Lifecycle ────────────────────────────────────────────────────────────────

    connectedCallback() {
        this._recalculate();
    }

    // ─── Scroll handler ───────────────────────────────────────────────────────────

    /**
     * Throttled via requestAnimationFrame.
     * requestAnimationFrame coalesces multiple rapid scroll events into one
     * paint cycle — prevents excessive re-renders on fast trackpad swipes.
     */
    handleScroll(event) {
        if (this._rafPending) return;
        this._rafPending = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            this._rafPending = false;
            const scrollTop = event.target.scrollTop;
            this._update(scrollTop);
        });
    }

    handleSlotChange() {
        // reserved for future named-slot row template support
    }

    // ─── Virtual window calculation ───────────────────────────────────────────────

    _recalculate() {
        const scrollContainer = this.refs?.scrollContainer;
        const scrollTop = scrollContainer ? scrollContainer.scrollTop : 0;

        // Container style: fixed height + scrollable
        this.containerStyle   = `height:${this.containerHeight}px; overflow-y:auto; position:relative;`;
        // Row style: fixed height for uniform measurement
        this.rowStyle         = `height:${this._itemHeight}px; overflow:hidden; box-sizing:border-box;`;

        this._update(scrollTop);
    }

    /**
     * Core virtual window update.
     * @param {number} scrollTop — current scroll position in pixels
     */
    _update(scrollTop) {
        const total       = this._items.length;
        const visibleCount = Math.ceil(this.containerHeight / this._itemHeight);

        const rawStart  = Math.floor(scrollTop / this._itemHeight);
        const start     = Math.max(0, rawStart - BUFFER);
        const end       = Math.min(total, rawStart + visibleCount + BUFFER);

        // Skip re-render if window hasn't moved
        if (start === this._startIndex && this.visibleItems.length === end - start) {
            return;
        }

        this._startIndex = start;

        // Slice the visible window and add virtual metadata
        this.visibleItems = this._items.slice(start, end).map((item, i) => ({
            ...item,
            _index:      start + i,
            _virtualKey: (item.id ?? item.Id ?? String(start + i)),
            _useDefault: true,
            label:       item[this.labelField]    ?? String(start + i),
            subLabel:    item[this.subLabelField] ?? ''
        }));

        // Spacers maintain correct total scroll height
        const topPx    = start * this._itemHeight;
        const bottomPx = Math.max(0, (total - end) * this._itemHeight);

        this.topSpacerStyle    = `height:${topPx}px;`;
        this.bottomSpacerStyle = `height:${bottomPx}px;`;
    }
}
