/**
 * @description accountSummaryCard — parent container component demonstrating
 *              the full LWC component lifecycle, @wire with UI API getRecord,
 *              conditional child mounting, and custom event handling.
 *
 *              Lifecycle sequence (first load):
 *              1. constructor()         — instance created, no DOM yet
 *              2. connectedCallback()   — inserted into DOM, no render yet
 *              3. render()              — framework calls this internally
 *              4. renderedCallback()    — DOM fully rendered, can query template
 *
 *              Re-render triggers:
 *              — @api property change (accountId set by parent/record page)
 *              — @wire result arrival (account data loaded)
 *              — reactive state mutation (showOpportunities toggle)
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue }    from 'lightning/uiRecordApi';
import getOpportunityCount             from '@salesforce/apex/AccountDashboardController.getOpportunityCount';

// Schema imports — compile-time field references (fail at build if field is deleted/renamed)
import NAME_FIELD    from '@salesforce/schema/Account.Name';
import TYPE_FIELD    from '@salesforce/schema/Account.Type';
import RATING_FIELD  from '@salesforce/schema/Account.Rating';
import REVENUE_FIELD from '@salesforce/schema/Account.AnnualRevenue';

// All fields fetched in one getRecord call — avoids multiple wire adapters for the same record
const ACCOUNT_FIELDS = [NAME_FIELD, TYPE_FIELD, RATING_FIELD, REVENUE_FIELD];

export default class AccountSummaryCard extends LightningElement {

    // ─── Public API (@api) ────────────────────────────────────────────────────────
    // @api marks a property as publicly settable by a parent component or App Builder.
    // When accountId changes, ALL @wire adapters using '$accountId' re-execute automatically.
    @api accountId;

    // ─── Wire adapters ────────────────────────────────────────────────────────────

    /**
     * getRecord wire — provided by lightning/uiRecordApi (UI API).
     * Advantages over Apex:
     *   • Automatically cached and invalidated by the platform
     *   • No Apex class needed for standard field reads
     *   • Integrates with LDS (Lightning Data Service) — updates reflect everywhere
     * Result shape: { data: Record, error: Error }
     * '$accountId' prefix makes accountId a reactive variable — wire re-fires on change.
     */
    @wire(getRecord, { recordId: '$accountId', fields: ACCOUNT_FIELDS })
    account;

    /**
     * Custom Apex wire — @AuraEnabled(cacheable=true) method.
     * Use when: business logic, complex queries, aggregates, or data not in UI API.
     * cacheable=true is REQUIRED for @wire — non-cacheable methods must be called imperatively.
     */
    @wire(getOpportunityCount, { accountId: '$accountId' })
    opportunityCount;

    // ─── Private reactive state ───────────────────────────────────────────────────
    // Since Spring '20, primitive properties are auto-tracked — no @track needed.
    // @track IS still required when you mutate a property of an object/array IN PLACE
    // without reassignment (e.g. this.items[0].selected = true). Primitives never need it.
    showOpportunities    = false;
    selectedOpportunityId = null;
    renderCount          = 0;

    // ─── Lifecycle hooks ──────────────────────────────────────────────────────────

    constructor() {
        super(); // ALWAYS required — LightningElement base constructor must run
        // ✅ CAN:  set default property values, initialise private variables
        // ❌ CANNOT: access this.template (shadow DOM not created yet)
        // ❌ CANNOT: dispatch events (component not yet in a DOM tree)
        // ❌ CANNOT: call @wire methods imperatively (LWC engine not wired yet)
    }

    connectedCallback() {
        // Fires when component is inserted into the DOM (BEFORE first render).
        // ✅ CAN:  subscribe to LMS MessageChannels (subscribe() here, unsubscribe in disconnectedCallback)
        // ✅ CAN:  add window/document event listeners
        // ✅ CAN:  dispatch custom events (parent component is now in the tree)
        // ❌ CANNOT: access this.template.querySelector (not rendered yet)
        console.log('[accountSummaryCard] connectedCallback — accountId:', this.accountId);
    }

    renderedCallback() {
        // Fires after EVERY render: initial render AND every reactive re-render.
        // ✅ CAN:  call this.template.querySelector / querySelectorAll
        // ✅ CAN:  set CSS custom properties on this.template.host
        // ⚠️  MUST guard state mutations with a counter/flag — unchecked mutation
        //          causes infinite render loop: mutation → re-render → renderedCallback → mutation…
        this.renderCount++;
        if (this.renderCount === 1) {
            // First-render-only initialisation — safe because guarded by renderCount
            const card = this.template.querySelector('.account-card');
            if (card) {
                // Example: stamp a data attribute for E2E test selectors
                card.setAttribute('data-component', 'accountSummaryCard');
            }
        }
    }

    disconnectedCallback() {
        // Fires when component is removed from DOM (e.g. lwc:if becomes false, navigation away).
        // ✅ USE:  unsubscribe from LMS, remove event listeners, cancel timers/intervals
        // In Day 9 we will subscribe to a MessageChannel in connectedCallback
        // and unsubscribe here to prevent memory leaks.
        console.log('[accountSummaryCard] disconnectedCallback — cleaning up');
    }

    // ─── Computed getters ─────────────────────────────────────────────────────────
    // Getters are re-evaluated on every render — they are NOT cached.
    // For expensive computations, derive and store the value in a reactive property instead.

    get accountName() {
        return getFieldValue(this.account?.data, NAME_FIELD) ?? '—';
    }

    get accountType() {
        return getFieldValue(this.account?.data, TYPE_FIELD) ?? '—';
    }

    get accountRating() {
        return getFieldValue(this.account?.data, RATING_FIELD) ?? '—';
    }

    get formattedRevenue() {
        const revenue = getFieldValue(this.account?.data, REVENUE_FIELD);
        if (!revenue) return '$0';
        return new Intl.NumberFormat('en-US', {
            style: 'currency', currency: 'USD', maximumFractionDigits: 0
        }).format(revenue);
    }

    get ratingBadgeClass() {
        const rating = this.accountRating;
        if (rating === 'Hot')  return 'slds-badge slds-badge_inverse';
        if (rating === 'Warm') return 'slds-badge slds-theme_warning';
        return 'slds-badge';
    }

    get opportunityCountLabel() {
        const count = this.opportunityCount?.data ?? 0;
        return `${count} Opportunit${count === 1 ? 'y' : 'ies'}`;
    }

    get cardTitle() {
        const name = this.accountName;
        return name === '—' ? 'Account Summary' : name;
    }

    get isLoading() {
        // Show spinner only while BOTH data and error are absent (initial fetch)
        return !this.account?.data && !this.account?.error;
    }

    get hasError() {
        return !!this.account?.error;
    }

    get errorMessage() {
        return this.account?.error?.body?.message
            ?? 'An unexpected error occurred while loading account data.';
    }

    get toggleButtonLabel() {
        return this.showOpportunities ? 'Hide Opportunities' : 'View Opportunities';
    }

    get toggleButtonIcon() {
        return this.showOpportunities ? 'utility:chevronup' : 'utility:chevrondown';
    }

    // ─── Event handlers ───────────────────────────────────────────────────────────

    handleToggleOpportunities() {
        // Toggling showOpportunities DESTROYS the child when false (lwc:if removes it from DOM)
        // The child's disconnectedCallback fires; its state is lost.
        // Use lwc:if when you want lifecycle cleanup on hide; use CSS hide when state must persist.
        this.showOpportunities = !this.showOpportunities;
    }

    handleOpportunitySelected(event) {
        // Receives custom event bubbled up from c-opportunity-list
        // event.detail carries the payload defined in the child's dispatchEvent call
        this.selectedOpportunityId = event.detail.opportunityId;
    }
}
