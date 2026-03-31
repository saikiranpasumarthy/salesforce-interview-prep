/**
 * @description opportunityList — child component demonstrating:
 *
 *              • @wire with custom cacheable Apex method and reactive '$accountId' prop
 *              • @track usage — when it IS and IS NOT required after Spring '20
 *              • Client-side filter/search without re-querying the server
 *              • for:each + key — correct pattern and common pitfalls
 *              • Custom event dispatch — bubbles vs composed flags explained
 *              • disconnectedCallback for MessageChannel cleanup (stubbed for Day 9)
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
import { LightningElement, api, wire, track } from 'lwc';
import getOpportunitiesForAccount from '@salesforce/apex/AccountDashboardController.getOpportunitiesForAccount';

// All supported stage values — drives the filter pill UI
const ALL_STAGES = ['All', 'Prospecting', 'Qualification', 'Proposal', 'Closed Won', 'Closed Lost'];

export default class OpportunityList extends LightningElement {

    // ─── Public API ───────────────────────────────────────────────────────────────
    @api accountId;

    // ─── Wire ─────────────────────────────────────────────────────────────────────
    /**
     * @wire with a custom Apex controller method.
     *
     * '$accountId' (dollar-sign prefix) makes this a reactive prop:
     *   — the wire re-fires automatically whenever this.accountId changes
     *   — without $, the value is treated as a static string literal
     *
     * cacheable=true requirement:
     *   — @wire ONLY works with @AuraEnabled(cacheable=true) Apex methods
     *   — non-cacheable methods must be called imperatively (in connectedCallback, etc.)
     *
     * Result shape: { data: <return type of Apex method>, error: { body, status } }
     */
    @wire(getOpportunitiesForAccount, { accountId: '$accountId' })
    wiredOpportunities;

    // ─── Reactive state ───────────────────────────────────────────────────────────

    // filterText is a String (primitive) — auto-tracked since Spring '20, no @track needed.
    filterText = '';

    /**
     * @track IS required here because we reassign activeStage (primitive — OK without @track),
     * but it IS needed when a property holds an Object or Array and you mutate it IN PLACE:
     *   this.stageFilters[0].isActive = true;  ← deep mutation — needs @track
     * Assigning a new array reference is fine without @track:
     *   this.stageFilters = [...newList];       ← reassignment — auto-tracked
     *
     * Best practice: prefer reassignment over in-place mutation to stay @track-free.
     */
    activeStage = 'All';

    // ─── Lifecycle ────────────────────────────────────────────────────────────────

    connectedCallback() {
        // Day 9 preview: subscribe to LMS MessageChannel here
        // this._subscription = subscribe(messageContext, OPPORTUNITY_SELECTED_CHANNEL, ...);
        console.log('[opportunityList] connectedCallback — accountId:', this.accountId);
    }

    disconnectedCallback() {
        // Day 9 preview: unsubscribe to prevent memory leak and ghost listeners
        // if (this._subscription) unsubscribe(this._subscription);
        console.log('[opportunityList] disconnectedCallback — cleaning up subscriptions');
    }

    // ─── Getters ──────────────────────────────────────────────────────────────────

    get isLoading() {
        return !this.wiredOpportunities?.data && !this.wiredOpportunities?.error;
    }

    get hasError() {
        return !!this.wiredOpportunities?.error;
    }

    get errorMessage() {
        return this.wiredOpportunities?.error?.body?.message
            ?? 'Failed to load opportunities.';
    }

    /**
     * Derived list — filter applied client-side so no additional wire call fires.
     * This is intentional: the full dataset is loaded once; the UI updates instantly.
     * For very large datasets (> 1000 records), push filtering to the server instead.
     */
    get filteredOpportunities() {
        const raw = this.wiredOpportunities?.data ?? [];
        return raw
            .filter(opp =>
                (this.activeStage === 'All' || opp.stageName === this.activeStage)
                && (!this.filterText
                    || opp.name.toLowerCase().includes(this.filterText.toLowerCase()))
            );
    }

    get hasResults() {
        return this.filteredOpportunities.length > 0;
    }

    get recordCountLabel() {
        const n = this.filteredOpportunities.length;
        return `${n} opportunit${n === 1 ? 'y' : 'ies'}`;
    }

    /**
     * Stage filter pill data — re-computed on every render.
     * Demonstrates the common pattern of deriving display state from raw data + UI state.
     */
    get stageFilters() {
        return ALL_STAGES.map(stage => ({
            value: stage,
            label: stage,
            pillClass: stage === this.activeStage
                ? 'stage-pill stage-pill--active'
                : 'stage-pill'
        }));
    }

    // ─── Event handlers ───────────────────────────────────────────────────────────

    handleFilterChange(event) {
        this.filterText = event.target.value;
    }

    handleStageFilter(event) {
        this.activeStage = event.currentTarget.dataset.stage;
    }

    handleOpportunityClick(event) {
        const oppId = event.currentTarget.dataset.id;

        /**
         * Custom Event dispatch — key options:
         *
         *   bubbles: true  — event propagates up through the DOM tree inside the shadow root.
         *                    Without bubbles, the parent can only listen with addEventListener
         *                    directly on the child element, not on a containing div.
         *
         *   composed: false — event does NOT cross the shadow root boundary automatically.
         *                     The parent (accountSummaryCard) catches it because c-opportunity-list
         *                     is directly in accountSummaryCard's template.
         *                     composed: true would allow the event to propagate past shadow roots
         *                     (e.g. up to the page-level document) — almost never needed for
         *                     component-to-component communication.
         *
         * Naming convention: event name = lowercase string matching the template attribute
         *   onopportunityselected → 'opportunityselected'
         */
        this.dispatchEvent(new CustomEvent('opportunityselected', {
            detail: { opportunityId: oppId },
            bubbles:  true,
            composed: false
        }));
    }
}
