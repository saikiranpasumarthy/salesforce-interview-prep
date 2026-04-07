/**
 * Day 39 — Weak Area Revisit: Lightning Message Service (LMS)
 *
 * Interview Q: "How do components communicate when they have no parent-child
 *               relationship in LWC?"
 *
 * Three cross-component communication options (know all three):
 *
 *  1. CustomEvent + bubbling     — only works up the DOM tree (parent-child)
 *  2. PubSub (legacy pattern)    — singleton JS module; works across DOM but
 *                                  requires manual cleanup; NOT recommended for new code
 *  3. Lightning Message Service  — official Salesforce solution; works across
 *                                  Lightning Web Components, Aura, and Visualforce
 *                                  on the SAME Lightning page
 *
 * LMS key points for interviews:
 *  - MessageChannel is a metadata type deployed via SFDX
 *  - Subscribe in connectedCallback, unsubscribe in disconnectedCallback
 *  - MessageContext wire adapter provides the scope (application vs active tab)
 *  - publish() and subscribe() from 'lightning/messageService'
 *  - APPLICATION_SCOPE = all components on the page; default = active tab only
 */

import { LightningElement, wire, track, api } from 'lwc';
import {
    MessageContext,
    publish,
    subscribe,
    unsubscribe,
    APPLICATION_SCOPE
} from 'lightning/messageService';
import RECORD_SELECTED_CHANNEL from '@salesforce/messageChannel/RecordSelected__c';
import getAccountsUserMode from '@salesforce/apex/WeakAreaRevisitService.getAccountsUserMode';

const PAGE_SIZE = 5;

export default class NotificationPanel extends LightningElement {

    // ── Public API ─────────────────────────────────────────────────────────────
    @api industry = 'Technology';

    // ── Reactive state ─────────────────────────────────────────────────────────
    @track accounts       = [];
    @track selectedRecord = null;
    @track errorMessage   = null;
    @track _currentPage   = 1;

    // ── LMS ───────────────────────────────────────────────────────────────────
    @wire(MessageContext)
    messageContext;               // provided by the LMS framework; do not set manually

    _subscription = null;

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    connectedCallback() {
        this._loadAccounts();
        this._subscribeToChannel();
    }

    disconnectedCallback() {
        // IMPORTANT: always unsubscribe to prevent memory leaks
        // Forgetting this is a common interview mistake
        unsubscribe(this._subscription);
        this._subscription = null;
    }

    // ── LMS: subscribe ────────────────────────────────────────────────────────

    _subscribeToChannel() {
        if (this._subscription) return; // guard against double-subscribe
        this._subscription = subscribe(
            this.messageContext,
            RECORD_SELECTED_CHANNEL,
            (message) => this._handleRecordSelectedMessage(message),
            { scope: APPLICATION_SCOPE }
            // APPLICATION_SCOPE: receive messages from ALL components on the page
            // Omit scope: only receive from same active tab (default)
        );
    }

    _handleRecordSelectedMessage(message) {
        // message shape matches the LightningMessageFields defined in the metadata
        this.selectedRecord = {
            id:         message.recordId,
            name:       message.recordName,
            objectType: message.objectApiName
        };
        this.errorMessage = null;
    }

    // ── LMS: publish ──────────────────────────────────────────────────────────

    handleAccountClick(event) {
        const accountId   = event.currentTarget.dataset.id;
        const accountName = event.currentTarget.dataset.name;

        // Publish to LMS channel — any subscribed component on the page will receive this
        publish(this.messageContext, RECORD_SELECTED_CHANNEL, {
            recordId:      accountId,
            recordName:    accountName,
            objectApiName: 'Account'
        });

        // Also dispatch a CustomEvent for direct parent components
        // (shows knowledge of when to use each mechanism)
        this.dispatchEvent(new CustomEvent('accountselected', {
            detail:   { accountId, accountName },
            bubbles:  true,
            composed: false   // do not cross shadow DOM boundary
        }));
    }

    // ── Data loading ──────────────────────────────────────────────────────────

    _loadAccounts() {
        getAccountsUserMode({ industry: this.industry })
            .then((data) => {
                this.accounts     = data;
                this.errorMessage = null;
                this._currentPage = 1;
            })
            .catch((error) => {
                this.errorMessage = this._extractError(error);
                this.accounts     = [];
            });
    }

    // ── Pagination ────────────────────────────────────────────────────────────

    get pagedAccounts() {
        const start = (this._currentPage - 1) * PAGE_SIZE;
        return this.accounts.slice(start, start + PAGE_SIZE);
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.accounts.length / PAGE_SIZE));
    }

    get hasPreviousPage() { return this._currentPage > 1; }
    get hasNextPage()     { return this._currentPage < this.totalPages; }
    get currentPage()     { return this._currentPage; }

    handlePreviousPage() { if (this.hasPreviousPage) this._currentPage--; }
    handleNextPage()     { if (this.hasNextPage)     this._currentPage++; }

    // ── Error handling ────────────────────────────────────────────────────────

    _extractError(error) {
        if (!error)                              return 'Unknown error';
        if (error.body?.message)                 return error.body.message;
        if (error.body?.pageErrors?.[0]?.message) return error.body.pageErrors[0].message;
        if (error.message)                       return error.message;
        return JSON.stringify(error);
    }

    // ── Computed display ──────────────────────────────────────────────────────

    get hasAccounts()      { return this.accounts.length > 0; }
    get hasSelection()     { return this.selectedRecord !== null; }
    get hasError()         { return this.errorMessage !== null; }

    get selectedRecordLabel() {
        if (!this.selectedRecord) return '';
        return this.selectedRecord.objectType + ': ' + this.selectedRecord.name;
    }
}
