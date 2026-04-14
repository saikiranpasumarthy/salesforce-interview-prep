/**
 * @description storeInventoryTracker — live store inventory panel on Account page.
 *
 * Architecture decisions documented here for interview readiness:
 *
 * WHY WIRE + refreshApex (not imperative):
 *   Inventory is READ-ONLY in this component — the rep updates it via
 *   visitExecutionWizard, not here. Wire is the correct pattern for
 *   read-heavy data bound to a record context. refreshApex on the
 *   Refresh button gives manual control when freshness matters.
 *
 *   CONTRAST with visitExecutionWizard: that component uses imperative
 *   because user actions (stock entry, check-in) trigger state changes
 *   that must be immediately consistent. Here we are only displaying.
 *
 * CLIENT-SIDE FILTERING:
 *   The search/filter is computed in JS as a getter over the full
 *   inventory array — no new Apex call per keystroke. This is correct
 *   because the total product count per store is bounded (typically
 *   100–300 items) and fits in browser memory. A new server call per
 *   keypress would be wasteful and slower than JS filter.
 *
 * STATUS BANDING:
 *   In Stock:    Current_Stock__c >= Minimum_Stock__c
 *   Low Stock:   0 < Current_Stock__c < Minimum_Stock__c
 *   Out of Stock: Current_Stock__c === 0 OR Is_Out_Of_Stock__c === true
 *   This mirrors the Apex flag logic in InventoryService — single source of truth
 *   is the Apex-set Is_Out_Of_Stock__c field; JS classification is for UI only.
 *
 * @author     Saikiran Pasumarthy
 * @project    Consumer Goods Cloud — Retail Execution
 * @apiVersion 62.0
 */

import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex }                         from '@salesforce/apex';

// Wire adapter — @AuraEnabled(cacheable=true) on InventoryService.getStoreInventory
import getStoreInventory from '@salesforce/apex/InventoryService.getStoreInventory';

const DATE_FORMATTER = new Intl.DateTimeFormat('en-US', {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true
});

export default class StoreInventoryTracker extends LightningElement {

    // ── Public API ─────────────────────────────────────────────────────────────
    @api recordId;  // Account Id (Retail Store)

    // ── Tracked State ──────────────────────────────────────────────────────────
    @track searchTerm        = '';
    @track isLoading         = true;
    @track errorMessage      = '';
    @track lastRefreshedTime = null;

    // Wire result ref — stored for refreshApex
    _wiredInventoryResult;

    // ── Wire: Fetch Store Inventory ────────────────────────────────────────────
    @wire(getStoreInventory, { storeId: '$recordId' })
    wiredInventory(result) {
        this._wiredInventoryResult = result;
        this.isLoading             = false;

        if (result.data) {
            this.errorMessage      = '';
            this.lastRefreshedTime = new Date();
        } else if (result.error) {
            this.errorMessage = this._extractError(result.error);
        }
    }

    // ── Getters — Raw Inventory Data ───────────────────────────────────────────
    get _rawInventory() {
        const data = this._wiredInventoryResult?.data;
        if (!data) return [];
        return data.map(item => this._enrichItem(item));
    }

    // ── Getters — Filtered Inventory ───────────────────────────────────────────
    get filteredInventory() {
        const term = (this.searchTerm || '').toLowerCase().trim();
        if (!term) return this._rawInventory;
        return this._rawInventory.filter(item =>
            item.productName.toLowerCase().includes(term) ||
            (item.category || '').toLowerCase().includes(term)
        );
    }

    get hasInventory() {
        return this._rawInventory.length > 0;
    }

    get isFilterEmpty() {
        return this.hasInventory && this.filteredInventory.length === 0;
    }

    // ── Getters — Summary Counts ───────────────────────────────────────────────
    get totalProducts() {
        return this._rawInventory.length;
    }

    get inStockCount() {
        return this._rawInventory.filter(i => i.statusKey === 'IN_STOCK').length;
    }

    get lowStockCount() {
        return this._rawInventory.filter(i => i.statusKey === 'LOW').length;
    }

    get outOfStockCount() {
        return this._rawInventory.filter(i => i.statusKey === 'OOS').length;
    }

    get lastRefreshedLabel() {
        if (!this.lastRefreshedTime) return 'Never';
        return DATE_FORMATTER.format(this.lastRefreshedTime);
    }

    // ── Handlers ──────────────────────────────────────────────────────────────
    handleSearch(event) {
        this.searchTerm = event.target.value;
    }

    async handleRefresh() {
        this.isLoading    = true;
        this.errorMessage = '';
        try {
            await refreshApex(this._wiredInventoryResult);
            this.lastRefreshedTime = new Date();
        } catch (error) {
            this.errorMessage = this._extractError(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ── Private: Enrich item with computed CSS and labels ─────────────────────
    _enrichItem(item) {
        const current = item.currentStock  ?? 0;
        const minimum = item.minimumStock  ?? 0;
        const isOosFlag = item.isOutOfStock ?? false;

        let statusKey;
        if (isOosFlag || current === 0) {
            statusKey = 'OOS';
        } else if (current < minimum) {
            statusKey = 'LOW';
        } else {
            statusKey = 'IN_STOCK';
        }

        const STATUS_META = {
            IN_STOCK: { label: 'In Stock',     rowCss: 'inv-row',          chip: 'status-chip chip-in-stock' },
            LOW:      { label: 'Low Stock',     rowCss: 'inv-row low-row',  chip: 'status-chip chip-low'      },
            OOS:      { label: 'Out of Stock',  rowCss: 'inv-row oos-row',  chip: 'status-chip chip-oos'      }
        };

        const meta = STATUS_META[statusKey];

        return {
            id:                  item.id,
            productName:         item.productName  || 'Unknown Product',
            category:            item.category     || '',
            currentStock:        current,
            minimumStock:        minimum,
            statusKey,
            statusLabel:         meta.label,
            rowCssClass:         meta.rowCss,
            statusChipClass:     meta.chip,
            lastUpdatedFormatted: item.lastUpdated
                ? DATE_FORMATTER.format(new Date(item.lastUpdated))
                : '—'
        };
    }

    // ── Private: Error Extraction ──────────────────────────────────────────────
    _extractError(error) {
        if (error?.body?.message)            return error.body.message;
        if (error?.body?.pageErrors?.length) return error.body.pageErrors[0].message;
        if (error?.message)                  return error.message;
        return 'Failed to load inventory data. Please refresh the page.';
    }
}
