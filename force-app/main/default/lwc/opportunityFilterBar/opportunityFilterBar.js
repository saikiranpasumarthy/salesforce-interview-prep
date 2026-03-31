/**
 * @description opportunityFilterBar — LMS publisher demonstrating cross-component
 *              communication without a shared parent-child relationship.
 *
 *              Communication pattern summary (when to use what):
 *
 *              ┌─────────────────────┬────────────────────────────────────────┐
 *              │ Pattern             │ Use When                               │
 *              ├─────────────────────┼────────────────────────────────────────┤
 *              │ @api + parent tmpl  │ Parent sets child prop (top-down data) │
 *              │ Custom Event        │ Child notifies parent (bottom-up)      │
 *              │ LMS publish/sub     │ Unrelated components on same page      │
 *              │ @wire getRecord/LDS │ Multiple components read same record   │
 *              │ URL / PageReference │ State that should survive navigation   │
 *              └─────────────────────┴────────────────────────────────────────┘
 *
 *              LMS vs legacy pubsub:
 *                pubsub (fireEvent/handleEvent) was a community pattern using a
 *                singleton module. It had no lifecycle awareness — components could
 *                receive events after being destroyed. LMS is platform-native:
 *                  • Automatically scopes to the active page context
 *                  • Subscriptions are tied to component lifecycle (no ghost listeners)
 *                  • Works across LWC, Aura, and Visualforce on the same page
 *                  • Supported in App Builder and record pages without config
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api, wire } from 'lwc';
import { MessageContext, publish }      from 'lightning/messageService';
import OPPORTUNITY_FILTER_CHANNEL      from '@salesforce/messageChannel/OpportunityFilter__c';

const STAGE_OPTIONS = [
    { label: 'All Stages',    value: 'All' },
    { label: 'Prospecting',   value: 'Prospecting' },
    { label: 'Qualification', value: 'Qualification' },
    { label: 'Proposal',      value: 'Proposal' },
    { label: 'Closed Won',    value: 'Closed Won' },
    { label: 'Closed Lost',   value: 'Closed Lost' },
];

export default class OpportunityFilterBar extends LightningElement {

    // ─── @api ─────────────────────────────────────────────────────────────────────
    /**
     * Getter/setter pattern for @api props.
     *
     * Use a setter when you need to:
     *   1. React to a prop change with side effects (publish LMS, call Apex)
     *   2. Validate or transform the incoming value
     *   3. Sync internal state with the new value
     *
     * Plain @api accountId would work for rendering but would not auto-publish
     * an initial filter when the component first receives the accountId.
     */
    _accountId;

    @api
    get accountId() {
        return this._accountId;
    }
    set accountId(value) {
        this._accountId = value;
        // Publish initial filter as soon as accountId is available
        if (value) {
            this.publishFilter();
        }
    }

    // ─── Wire: MessageContext ─────────────────────────────────────────────────────
    /**
     * @wire(MessageContext) provides the message context handle required by
     * publish() and subscribe(). It is NOT a data-returning wire — it returns
     * a context object, not { data, error }. It must always be wired, never
     * instantiated manually.
     *
     * Scoping: MessageContext scopes LMS to the current application context
     * (the active Lightning page). A component on PageA publishing a message
     * does NOT reach subscribers on PageB.
     */
    @wire(MessageContext)
    messageContext;

    // ─── Private state ────────────────────────────────────────────────────────────
    selectedStage  = 'All';
    minAmount      = 0;
    lastPublished  = null;

    // ─── Getters ──────────────────────────────────────────────────────────────────

    get stageOptions() {
        return STAGE_OPTIONS;
    }

    get amountSliderLabel() {
        return `Min Amount: ${this.formatCurrency(this.minAmount)}`;
    }

    // ─── Event handlers ───────────────────────────────────────────────────────────

    handleStageChange(event) {
        this.selectedStage = event.detail.value;
    }

    handleAmountChange(event) {
        this.minAmount = event.detail.value;
    }

    handleApplyFilters() {
        this.publishFilter();
    }

    handleReset() {
        this.selectedStage = 'All';
        this.minAmount     = 0;
        this.publishFilter();
    }

    // ─── LMS publish ─────────────────────────────────────────────────────────────

    /**
     * @description Publishes the current filter state to the LMS channel.
     *
     *              publish(messageContext, channel, message) parameters:
     *                messageContext — from @wire(MessageContext)
     *                channel        — imported via @salesforce/messageChannel/...
     *                message        — plain object matching the channel's field schema
     *
     *              All subscribed components on the page receive this message
     *              simultaneously, regardless of their position in the component tree.
     */
    publishFilter() {
        const message = {
            stageFilter: this.selectedStage,
            minAmount:   this.minAmount,
            accountId:   this._accountId
        };
        publish(this.messageContext, OPPORTUNITY_FILTER_CHANNEL, message);
        this.lastPublished = `Stage: ${this.selectedStage}, Min: ${this.formatCurrency(this.minAmount)}`;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    formatCurrency(value) {
        return new Intl.NumberFormat('en-US', {
            style: 'currency', currency: 'USD', maximumFractionDigits: 0
        }).format(value || 0);
    }
}
