/**
 * Day 37 — Mock Interview LWC: accountSearchCard
 *
 * Demonstrates every LWC pattern asked in senior developer interviews:
 *
 *  @api          — public property (maxRecords, pageSize)
 *  @track        — NOT needed for primitives in modern LWC (reactive by default)
 *  @wire         — declarative Apex call for initial data load
 *  Imperative    — user-driven search that cannot use @wire
 *  Debounce      — 300ms delay prevents firing search on every keystroke
 *  Custom event  — 'accountselected' bubbles to parent component
 *  Lifecycle     — connectedCallback for init, disconnectedCallback for cleanup
 *  Error handling — structured error state, never silent failures
 *  Pagination    — client-side page slicing from full dataset
 *  Getters       — derived state from reactive properties (no separate tracking vars)
 */
import { LightningElement, api, wire, track } from 'lwc';
import getRecentAccounts from '@salesforce/apex/MockInterviewApexService.getRecentAccounts';
import searchAccounts    from '@salesforce/apex/MockInterviewApexService.searchAccounts';

const DEBOUNCE_DELAY = 300; // ms — industry standard for search inputs
const RATING_CLASSES = {
    Hot:  'slds-theme_success',
    Warm: 'slds-theme_warning',
    Cold: 'slds-theme_shade'
};

export default class AccountSearchCard extends LightningElement {

    // ─── @api: public properties (set by parent component or App Builder) ───
    @api maxRecords = 50;   // total records to load
    @api pageSize   = 10;   // records per page

    // ─── Private reactive state ─────────────────────────────────────────────
    // In modern LWC, primitive properties are reactive without @track.
    // @track is only needed for deep mutation of objects/arrays.
    searchTerm   = '';
    currentPage  = 1;
    isLoading    = false;
    errorMessage = null;

    // Full dataset from @wire or imperative search
    @track _allAccounts = [];

    // Timer reference for debounce cleanup
    _debounceTimer = null;

    // ─── Lifecycle hooks ─────────────────────────────────────────────────────

    connectedCallback() {
        // Called when component is inserted into the DOM
        // Good place for: addEventListener, initialising services, reading cookies
        console.log('[accountSearchCard] connectedCallback — maxRecords:', this.maxRecords);
    }

    disconnectedCallback() {
        // Called when component is removed from the DOM
        // Essential: clear timers to prevent memory leaks
        if (this._debounceTimer) {
            clearTimeout(this._debounceTimer);
        }
    }

    // ─── @wire: declarative Apex call ────────────────────────────────────────
    // @wire calls the Apex method reactively whenever its parameters change.
    // cacheable=true methods can be used with @wire.
    // The result is automatically refreshed when the cache is invalidated.

    @wire(getRecentAccounts, { maxRecords: '$maxRecords' })
    wiredAccounts({ data, error }) {
        if (data) {
            this._allAccounts = this._enrichAccounts(data);
            this.errorMessage = null;
        } else if (error) {
            this.errorMessage = this._extractError(error);
            this._allAccounts = [];
        }
    }

    // ─── Event handlers ──────────────────────────────────────────────────────

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.currentPage = 1; // reset to page 1 on new search

        // Debounce: cancel previous timer, start fresh
        clearTimeout(this._debounceTimer);
        this._debounceTimer = setTimeout(() => {
            this._executeSearch();
        }, DEBOUNCE_DELAY);
    }

    handleAccountClick(event) {
        const accountId   = event.currentTarget.dataset.id;
        const accountName = event.currentTarget.dataset.name;

        // Custom event — fires on this component, bubbles to parent
        // Parent listens: <c-account-search-card onaccountselected={handleSelected}>
        this.dispatchEvent(new CustomEvent('accountselected', {
            detail:  { accountId, accountName },
            bubbles: true,    // propagates up the DOM tree
            composed: false   // stops at Shadow DOM boundary (best practice for LWC)
        }));
    }

    previousPage() {
        if (this.currentPage > 1) this.currentPage--;
    }

    nextPage() {
        if (this.currentPage < this.totalPages) this.currentPage++;
    }

    clearError() {
        this.errorMessage = null;
    }

    // ─── Imperative Apex call ─────────────────────────────────────────────────
    // Use imperative calls when: triggered by user action, needs try/catch,
    // must refresh after a DML operation, or cannot use @wire.

    async _executeSearch() {
        this.isLoading = true;
        this.errorMessage = null;
        try {
            const results = await searchAccounts({
                searchTerm: this.searchTerm,
                maxRecords: this.maxRecords
            });
            this._allAccounts = this._enrichAccounts(results);
        } catch (error) {
            this.errorMessage = this._extractError(error);
            this._allAccounts = [];
        } finally {
            this.isLoading = false; // always runs — like Java finally block
        }
    }

    // ─── Getters: derived / computed state ───────────────────────────────────
    // Getters are re-evaluated whenever their dependencies change.
    // Preferred over @track arrays of derived values.

    get accounts() {
        // Client-side pagination slice
        const start = (this.currentPage - 1) * this.pageSize;
        return this._allAccounts.slice(start, start + this.pageSize);
    }

    get totalCount()   { return this._allAccounts.length; }
    get displayCount() { return this.accounts.length; }
    get hasAccounts()  { return !this.isLoading && this._allAccounts.length > 0; }
    get hasError()     { return !!this.errorMessage; }
    get isEmpty()      {
        return !this.isLoading && !this.hasError && this._allAccounts.length === 0;
    }

    // Pagination getters
    get totalPages()  { return Math.max(1, Math.ceil(this.totalCount / this.pageSize)); }
    get isFirstPage() { return this.currentPage === 1; }
    get isLastPage()  { return this.currentPage >= this.totalPages; }
    get showPagination() { return this.totalCount > this.pageSize; }

    // ─── Private helpers ─────────────────────────────────────────────────────

    _enrichAccounts(rawAccounts) {
        return rawAccounts.map(acc => ({
            ...acc,
            iconName:    acc.NumberOfEmployees > 500 ? 'standard:account' : 'standard:person_account',
            ratingClass: RATING_CLASSES[acc.Rating] || 'slds-theme_shade'
        }));
    }

    /**
     * Extract a human-readable message from an Apex/LWC error.
     * LWC errors come as: { body: { message: '...' } } or { message: '...' }
     */
    _extractError(error) {
        if (!error) return 'An unknown error occurred';
        if (error.body?.message)       return error.body.message;
        if (error.body?.pageErrors?.[0]?.message) return error.body.pageErrors[0].message;
        if (error.message)             return error.message;
        return JSON.stringify(error);
    }
}
