/**
 * @description orderCaptureDashboard — order history panel for Area Managers.
 *
 * Architecture decisions documented here for interview readiness:
 *
 * WHY IMPERATIVE (not wire):
 *   Data changes based on user-selected date range (7/30/90 days).
 *   Wire adapters cache results and cannot take reactive filter parameters
 *   without using @wire with reactive properties — which still won't handle
 *   the UI-driven filter change correctly without a full re-render cycle.
 *   Imperative call per filter change is simpler and gives explicit loading
 *   state control.
 *
 * MODAL STATE:
 *   Line-item drill-down managed with isModalOpen boolean + selectedOrder
 *   object. No child component — modal rendered inline with lwc:if to avoid
 *   the overhead of a separate component boundary for this use case.
 *
 * SUMMARY TILES:
 *   Computed as getters over the orders array. No additional Apex call
 *   for summary metrics — derived from the same data set already loaded.
 *
 * COLOR CODING:
 *   ERP Sync Status chips:
 *     Synced  → green  (.chip-synced)
 *     Pending → amber  (.chip-pending)
 *     Failed  → red    (.chip-failed)
 *   Driven by computed syncChipClass getter per order row.
 *
 * @author     Saikiran Pasumarthy
 * @project    Consumer Goods Cloud — Retail Execution
 * @apiVersion 62.0
 */

import { LightningElement, api, track } from 'lwc';

// Imperative Apex — @AuraEnabled on OrderCaptureService.getOrderHistory
import getOrderHistory   from '@salesforce/apex/OrderCaptureService.getOrderHistory';
// Imperative Apex — @AuraEnabled on OrderCaptureService.getOrderLineItems
import getOrderLineItems from '@salesforce/apex/OrderCaptureService.getOrderLineItems';

const CURRENCY_FMT = new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD', minimumFractionDigits: 2
});

const DATE_FMT = new Intl.DateTimeFormat('en-US', {
    month: 'short', day: 'numeric', year: 'numeric'
});

const FILTER_OPTIONS = [
    { label: '7 days',  value: 7  },
    { label: '30 days', value: 30 },
    { label: '90 days', value: 90 }
];

const SYNC_CHIP_MAP = {
    'Synced':  'sync-chip chip-synced',
    'Pending': 'sync-chip chip-pending',
    'Failed':  'sync-chip chip-failed'
};

export default class OrderCaptureDashboard extends LightningElement {

    // ── Public API ─────────────────────────────────────────────────────────────
    @api recordId;  // Account Id (Retail Store)

    // ── Tracked State ──────────────────────────────────────────────────────────
    @track isLoading         = true;
    @track isLineItemLoading = false;
    @track errorMessage      = '';
    @track selectedDays      = 30;
    @track _rawOrders        = [];
    @track isModalOpen       = false;
    @track selectedOrder     = null;
    @track selectedOrderLineItems = [];

    // ── Filter Options with computed CSS ──────────────────────────────────────
    get filterOptions() {
        return FILTER_OPTIONS.map(opt => ({
            ...opt,
            cssClass: 'filter-btn' + (opt.value === this.selectedDays ? ' active' : '')
        }));
    }

    // ── Getters — Orders ──────────────────────────────────────────────────────
    get orders() {
        return this._rawOrders.map(o => this._enrichOrder(o));
    }

    get hasOrders() { return this._rawOrders.length > 0; }

    get orderCountLabel() {
        const n = this._rawOrders.length;
        return `${n} order${n !== 1 ? 's' : ''}`;
    }

    // ── Getters — Summary Tiles ────────────────────────────────────────────────
    get summary() {
        const total  = this._rawOrders.length;
        const value  = this._rawOrders.reduce((s, o) => s + (o.totalAmount || 0), 0);
        const pending = this._rawOrders.filter(o => o.erpSyncStatus === 'Pending').length;
        const failed  = this._rawOrders.filter(o => o.erpSyncStatus === 'Failed').length;
        return {
            totalOrders:       total,
            totalValueFormatted: CURRENCY_FMT.format(value),
            pendingSync:       pending,
            failedSync:        failed
        };
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    connectedCallback() {
        this._loadOrders();
    }

    // ── Filter Change Handler ─────────────────────────────────────────────────
    handleFilterChange(event) {
        const newDays = parseInt(event.target.dataset.value, 10);
        if (newDays === this.selectedDays) return;
        this.selectedDays = newDays;
        this._loadOrders();
    }

    // ── Order Row Click: open modal ────────────────────────────────────────────
    async handleOrderRowClick(event) {
        const orderId = event.currentTarget.dataset.id;
        const raw     = this._rawOrders.find(o => o.id === orderId);
        if (!raw) return;

        this.selectedOrder          = this._enrichOrder(raw);
        this.isModalOpen            = true;
        this.selectedOrderLineItems = [];
        this.isLineItemLoading      = true;

        try {
            const lineItems = await getOrderLineItems({ orderId });
            this.selectedOrderLineItems = (lineItems || []).map(li => ({
                id:                 li.id,
                productName:        li.productName,
                quantity:           li.quantity,
                unitPrice:          li.unitPrice,
                totalPrice:         li.totalPrice,
                unitPriceFormatted: CURRENCY_FMT.format(li.unitPrice  || 0),
                totalPriceFormatted: CURRENCY_FMT.format(li.totalPrice || 0)
            }));
        } catch (error) {
            // Non-fatal — show empty line items, don't close modal
            this.selectedOrderLineItems = [];
        } finally {
            this.isLineItemLoading = false;
        }
    }

    // ── Modal Close ───────────────────────────────────────────────────────────
    handleCloseModal()          { this.isModalOpen = false; }
    handleModalBackdropClick()  { this.isModalOpen = false; }

    // Prevent clicks inside the modal panel from closing it
    stopPropagation(event) { event.stopPropagation(); }

    // ── Private: Load Orders ──────────────────────────────────────────────────
    async _loadOrders() {
        this.isLoading    = true;
        this.errorMessage = '';
        try {
            const result = await getOrderHistory({
                storeId: this.recordId,
                days:    this.selectedDays
            });
            this._rawOrders = result || [];
        } catch (error) {
            this.errorMessage = this._extractError(error);
            this._rawOrders   = [];
        } finally {
            this.isLoading = false;
        }
    }

    // ── Private: Enrich Order for Display ────────────────────────────────────
    _enrichOrder(o) {
        const syncStatus = o.erpSyncStatus || 'Pending';
        return {
            id:                   o.id,
            orderNumber:          o.orderNumber,
            visitDateFormatted:   o.visitDate ? DATE_FMT.format(new Date(o.visitDate)) : '—',
            repName:              o.repName   || '—',
            totalAmount:          o.totalAmount || 0,
            totalAmountFormatted: CURRENCY_FMT.format(o.totalAmount || 0),
            status:               o.status    || '—',
            erpSyncStatus:        syncStatus,
            syncChipClass:        SYNC_CHIP_MAP[syncStatus] || 'sync-chip chip-pending',
            erpSyncMessage:       o.erpSyncMessage || '',
            hasSyncError:         syncStatus === 'Failed' && !!o.erpSyncMessage
        };
    }

    // ── Private: Error Extraction ─────────────────────────────────────────────
    _extractError(error) {
        if (error?.body?.message)            return error.body.message;
        if (error?.body?.pageErrors?.length) return error.body.pageErrors[0].message;
        if (error?.message)                  return error.message;
        return 'Failed to load order data. Please try again.';
    }
}
