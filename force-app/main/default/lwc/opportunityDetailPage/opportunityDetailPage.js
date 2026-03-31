/**
 * @description opportunityDetailPage — comprehensive NavigationMixin demonstration.
 *
 *              NavigationMixin adds navigate() and generateUrl() to a component class
 *              by extending with the mixin pattern:
 *                export default class Foo extends NavigationMixin(LightningElement) {}
 *
 *              PageReference anatomy:
 *              {
 *                type:       'standard__recordPage',  ← page type constant
 *                attributes: { recordId, objectApiName, actionName }, ← page-type-specific
 *                state:      { c__stage: 'Prospecting' } ← URL query params (bookmarkable)
 *              }
 *
 *              state vs attributes:
 *                attributes — required routing data (record Id, object name, action)
 *                state      — optional URL query parameters; survive back-navigation;
 *                             must be namespaced with 'c__' prefix to avoid collisions
 *
 *              generateUrl() vs navigate():
 *                navigate(pageRef)      — immediately navigates the browser
 *                generateUrl(pageRef)   — returns a Promise<string> with the URL
 *                                         without navigating; use for <a href> binding
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin }              from 'lightning/navigation';
import { CurrentPageReference }        from 'lightning/navigation';

export default class OpportunityDetailPage extends NavigationMixin(LightningElement) {

    @api accountId;
    @api opportunityId;

    // ─── CurrentPageReference @wire ───────────────────────────────────────────────
    /**
     * @wire(CurrentPageReference) gives access to the page's current PageReference object.
     * Use cases:
     *   1. Read URL state params (c__stage, c__filter, etc.) set by another component
     *   2. Determine which page type the component is running on
     *   3. Detect navigation events (re-fires when page changes in utility bar)
     *
     * The wire fires on initial load AND whenever the page reference changes
     * (e.g., when URL state is updated via navigate() with the same page type).
     */
    @wire(CurrentPageReference)
    pageRef;

    // ─── Getters ──────────────────────────────────────────────────────────────────

    get currentPageRefJson() {
        return this.pageRef
            ? JSON.stringify(this.pageRef, null, 2)
            : 'Loading page reference…';
    }

    /**
     * Reads URL state parameters from the current page reference.
     * State keys must be namespaced with 'c__' in LWC to avoid conflicts
     * with standard Salesforce URL parameters.
     */
    get urlState() {
        return this.pageRef?.state ?? {};
    }

    // ─── Navigation methods ───────────────────────────────────────────────────────

    /**
     * Navigate to a standard record page — the most common navigation action.
     *
     * actionName options for standard__recordPage:
     *   'view'  — opens the record detail page (default)
     *   'edit'  — opens the record in edit mode (inline edit or full edit page)
     *   'clone' — opens a new record pre-populated with the source record's fields
     */
    navigateToAccount() {
        if (!this.accountId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId:      this.accountId,
                objectApiName: 'Account',
                actionName:    'view'
            }
        });
    }

    /**
     * Navigate to a new record creation page with default field values pre-populated.
     * defaultFieldValues are encoded as a URL-safe string — use encodeDefaultFieldValues
     * from lightning/pageReferenceUtils for complex values.
     *
     * panelOnDestroyCallback: optional callback when the new record modal is closed.
     * navigationLocation: 'LOOKUP' opens as a modal; 'NO_OVERRIDE' opens the full page.
     */
    navigateToNewOpportunity() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Opportunity',
                actionName:    'new'
            },
            state: {
                // Pre-populate AccountId on the new Opportunity form
                defaultFieldValues: this.accountId
                    ? `AccountId=${this.accountId}`
                    : undefined,
                navigationLocation: 'LOOKUP'
            }
        });
    }

    /**
     * Navigate to the Opportunity list view (object home page).
     */
    navigateToOpportunityList() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Opportunity',
                actionName:    'list'
            },
            state: {
                // filterName targets a specific list view by developer name
                filterName: 'Recent'
            }
        });
    }

    /**
     * Navigate to a named page — built-in Lightning pages.
     * pageName options: 'home', 'chatter', 'today', 'dataAssessment', 'filePreview'
     */
    navigateToHome() {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: {
                pageName: 'home'
            }
        });
    }

    /**
     * Navigate to an external URL.
     * url: must be absolute (https://). Relative paths are not supported.
     * isRedirect: true opens in the same tab; false (default) opens in a new tab.
     */
    navigateToExternalUrl() {
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: 'https://help.salesforce.com'
            }
        });
    }

    /**
     * Update URL state without navigating away.
     * This pushes a new history entry — the back button returns to the previous state.
     * Use for bookmarkable filter/sort state that should survive page refresh.
     *
     * State keys prefixed with 'c__' are namespaced to this component's package.
     * Without the prefix, they may conflict with platform-reserved URL parameters.
     */
    setUrlState() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId:      this.accountId ?? '001000000000001AAA',
                objectApiName: 'Account',
                actionName:    'view'
            },
            state: {
                c__stage:  'Prospecting',
                c__filter: 'open'
            }
        });
    }

    /**
     * generateUrl() — returns a Promise<string> without navigating.
     * Use for binding a URL to an <a href> element or for analytics tracking.
     *
     * Not triggered by a button in the template — included as a reference implementation.
     */
    async getAccountUrl() {
        if (!this.accountId) return null;
        const url = await this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: {
                recordId:      this.accountId,
                objectApiName: 'Account',
                actionName:    'view'
            }
        });
        return url; // e.g. '/lightning/r/Account/001.../view'
    }
}
