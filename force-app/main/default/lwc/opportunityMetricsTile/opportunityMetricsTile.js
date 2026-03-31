/**
 * @description opportunityMetricsTile — LMS subscriber demonstrating:
 *
 *              1. subscribe() / unsubscribe() — always paired with connectedCallback
 *                 and disconnectedCallback respectively to prevent memory leaks
 *              2. Imperative Apex call — for cacheable=false methods or when you need
 *                 full control over when the call fires (vs. @wire's automatic behavior)
 *              3. refreshApex() — invalidates and re-fetches a @wire result after DML
 *              4. SCOPE_APPLICATION vs SCOPE_DEFAULT for LMS subscription scope
 *              5. ShowToastEvent — platform event for user feedback
 *
 *              Imperative vs @wire decision:
 *              ┌──────────────────────────┬─────────────────┬───────────────────┐
 *              │ Criterion                │ @wire           │ Imperative        │
 *              ├──────────────────────────┼─────────────────┼───────────────────┤
 *              │ cacheable=true only      │ ✅              │ ✅ (both work)    │
 *              │ cacheable=false (DML)    │ ❌              │ ✅ required       │
 *              │ Auto-fires on prop change│ ✅              │ ❌ manual trigger │
 *              │ Controlled timing        │ ❌              │ ✅ call anywhere  │
 *              │ Loading state control    │ Manual          │ Full control      │
 *              │ refreshApex() needed     │ After DML       │ N/A (re-call)     │
 *              └──────────────────────────┴─────────────────┴───────────────────┘
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api, wire }        from 'lwc';
import { MessageContext, subscribe,
         unsubscribe, APPLICATION_SCOPE }     from 'lightning/messageService';
import { ShowToastEvent }                     from 'lightning/platformShowToastEvent';
import OPPORTUNITY_FILTER_CHANNEL             from '@salesforce/messageChannel/OpportunityFilter__c';
import getOpportunityMetrics                  from '@salesforce/apex/AccountDashboardController.getOpportunityMetrics';

const DEFAULT_METRICS = { openCount: 0, totalPipeline: 0, avgDiscount: 0, discountedPipeline: 0 };

export default class OpportunityMetricsTile extends LightningElement {

    @api accountId;

    // ─── Wire: MessageContext ─────────────────────────────────────────────────────
    @wire(MessageContext)
    messageContext;

    // ─── Private state ────────────────────────────────────────────────────────────
    _subscription    = null;
    isLoading        = false;
    metrics          = { ...DEFAULT_METRICS };
    activeFilter     = null;   // last received LMS message
    errorMessage     = null;

    // ─── Lifecycle ────────────────────────────────────────────────────────────────

    connectedCallback() {
        this.subscribeToChannel();
        // Load initial metrics without any filter
        this.loadMetrics(null, null);
    }

    disconnectedCallback() {
        /**
         * ALWAYS unsubscribe in disconnectedCallback.
         * If omitted:
         *   - The subscription holds a reference to this component instance
         *   - The component cannot be garbage-collected even after removal from DOM
         *   - Messages continue to fire handleFilterMessage on the dead instance
         *   - In single-page apps (LEX navigation), this causes memory leaks that
         *     accumulate across navigation events
         */
        this.unsubscribeFromChannel();
    }

    // ─── LMS subscribe/unsubscribe ────────────────────────────────────────────────

    subscribeToChannel() {
        if (this._subscription) return; // already subscribed — guard against double-subscribe

        /**
         * subscribe(messageContext, channel, handler, options)
         *
         * options.scope values:
         *   APPLICATION_SCOPE  — receives messages published from ANY component on
         *                        ANY page in the app (including different tabs in
         *                        utility bars). Broad; use intentionally.
         *   DEFAULT (omit)     — receives messages only from components on the
         *                        SAME Lightning page. Safer default for most use cases.
         *
         * In this example we use APPLICATION_SCOPE to demonstrate the import.
         * For an Account record page scenario, DEFAULT scope is more appropriate
         * since the filter bar and metrics tile are on the same page.
         */
        this._subscription = subscribe(
            this.messageContext,
            OPPORTUNITY_FILTER_CHANNEL,
            (message) => this.handleFilterMessage(message),
            { scope: APPLICATION_SCOPE }
        );
    }

    unsubscribeFromChannel() {
        unsubscribe(this._subscription);
        this._subscription = null;
    }

    // ─── LMS message handler ──────────────────────────────────────────────────────

    handleFilterMessage(message) {
        /**
         * Called whenever opportunityFilterBar (or any component) publishes
         * to OpportunityFilter__c channel. The message object matches the
         * channel's field schema: { stageFilter, minAmount, accountId }.
         *
         * This is an imperative Apex call triggered by an LMS event — demonstrating
         * the most common real-world LMS subscriber pattern:
         *   receive message → call Apex → update component state
         */
        this.activeFilter = message;
        this.loadMetrics(message.stageFilter, message.minAmount);
    }

    // ─── Imperative Apex ──────────────────────────────────────────────────────────

    /**
     * @description Calls getOpportunityMetrics imperatively.
     *
     *              Imperative call pattern:
     *              1. Set isLoading = true (show spinner)
     *              2. Await the Apex promise
     *              3. On success: update state, clear error
     *              4. On error: show toast, set errorMessage
     *              5. Finally: isLoading = false (hide spinner regardless)
     *
     *              Why imperative here instead of @wire?
     *              - getOpportunityMetrics accepts stageFilter + minAmount which
     *                change in response to LMS messages, not @api prop changes.
     *              - @wire would require making these reactive props, coupling the
     *                component to a specific data-flow direction.
     *              - Imperative gives full control: call only when LMS message arrives.
     */
    async loadMetrics(stageFilter, minAmount) {
        if (!this.accountId) return;

        this.isLoading    = true;
        this.errorMessage = null;

        try {
            const result = await getOpportunityMetrics({
                accountId:   this.accountId,
                stageFilter: stageFilter ?? 'All',
                minAmount:   minAmount   ?? 0
            });
            this.metrics = result ?? { ...DEFAULT_METRICS };
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'Failed to load metrics.';
            /**
             * ShowToastEvent — dispatched from LWC to trigger a platform toast.
             * Parameters:
             *   title    — bold heading line
             *   message  — detail text
             *   variant  — 'success' | 'warning' | 'error' | 'info'
             *   mode     — 'dismissable' (default) | 'sticky' | 'pester'
             *
             * Must be dispatched on the component element, not document/window.
             * Bubbles up to the nearest LightningApp or LightningRecordPage.
             */
            this.dispatchEvent(new ShowToastEvent({
                title:   'Error loading metrics',
                message: this.errorMessage,
                variant: 'error',
                mode:    'dismissable'
            }));
        } finally {
            this.isLoading = false;
        }
    }

    // ─── Getters ──────────────────────────────────────────────────────────────────

    get hasActiveFilter() {
        return this.activeFilter &&
               (this.activeFilter.stageFilter !== 'All' || this.activeFilter.minAmount > 0);
    }

    get activeFilterLabel() {
        if (!this.activeFilter) return '';
        const parts = [];
        if (this.activeFilter.stageFilter !== 'All') {
            parts.push(`Stage: ${this.activeFilter.stageFilter}`);
        }
        if (this.activeFilter.minAmount > 0) {
            parts.push(`Min: ${this.formatCurrency(this.activeFilter.minAmount)}`);
        }
        return parts.join(' · ');
    }

    get formattedPipeline() {
        return this.formatCurrency(this.metrics.totalPipeline);
    }

    get formattedDiscountedPipeline() {
        return this.formatCurrency(this.metrics.discountedPipeline);
    }

    get formattedAvgDiscount() {
        const avg = this.metrics.avgDiscount ?? 0;
        return `${avg.toFixed(1)}%`;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    formatCurrency(value) {
        return new Intl.NumberFormat('en-US', {
            style: 'currency', currency: 'USD', maximumFractionDigits: 0
        }).format(value || 0);
    }
}
