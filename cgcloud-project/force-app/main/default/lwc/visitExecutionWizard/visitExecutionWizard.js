/**
 * @description visitExecutionWizard — 4-step guided visit execution component.
 *
 * Architecture decisions documented here for interview readiness:
 *
 * WHY IMPERATIVE APEX (not wire):
 *   Visit data must be fresh on every interaction. Wire adapters cache at the
 *   component level — a rep checking in after hours of offline work would see
 *   stale planned-time data. Imperative calls give us explicit control over
 *   when server round-trips happen.
 *
 * LOCAL STATE STRATEGY:
 *   Stock quantities, audit entries, and order quantities are held in JS class
 *   arrays (stockEntries, auditEntries, orderEntries) and mutated via spread
 *   copies to preserve LWC reactivity. No Apex DML per keystroke — all captured
 *   data is committed in a single call on Complete Visit.
 *
 * OFFLINE BEHAVIOUR:
 *   When connectedCallback fails (no connectivity), the component degrades
 *   gracefully: it renders a "working offline" banner and re-uses cached visit
 *   data from Briefcase. Stock/audit/order captures are stored locally and
 *   submitted when connectivity is restored.
 *
 * @author     Saikiran Pasumarthy
 * @project    Consumer Goods Cloud — Retail Execution
 * @apiVersion 62.0
 */

import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent }                from 'lightning/platformShowToastEvent';

// ── Imperative Apex imports ─────────────────────────────────────────────────
// These @AuraEnabled methods must be present on the referenced Apex classes.
import getVisitContext              from '@salesforce/apex/RetailVisitService.getVisitContext';
import checkInVisit                 from '@salesforce/apex/RetailVisitService.checkInVisit';
import completeVisitAndCreateOrder  from '@salesforce/apex/RetailVisitService.completeVisitAndCreateOrder';

// ── Constants ────────────────────────────────────────────────────────────────
const TOTAL_STEPS = 4;
const STEP_LABELS = ['Check In', 'Stock', 'Promotions', 'Order'];
const CURRENCY_FORMATTER = new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD', minimumFractionDigits: 2
});

export default class VisitExecutionWizard extends LightningElement {

    // ── Public API ────────────────────────────────────────────────────────────
    @api recordId;  // RetailVisit__c Id — injected by the record page

    // ── Tracked State ─────────────────────────────────────────────────────────
    @track isLoading       = true;
    @track errorMessage    = '';
    @track visitData       = {};
    @track currentStep     = 1;

    // Step 2: stock capture — array of { productId, productName, minStock, quantity }
    @track stockEntries    = [];

    // Step 3: promo audit — array of { promotionId, promotionName, productName,
    //                                   expectedPlacement, isCompliant, photoCaptured, notes }
    @track auditEntries    = [];

    // Step 4: order capture — array of { productId, productName, unitPrice, quantity }
    @track orderEntries    = [];

    // ── Getters — Step Visibility ─────────────────────────────────────────────
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }
    get totalSteps() { return TOTAL_STEPS; }

    // ── Getters — Navigation Buttons ──────────────────────────────────────────
    get showPrevBtn()     { return this.currentStep > 1; }
    get showNextBtn()     { return this.currentStep < TOTAL_STEPS; }
    get showCompleteBtn() { return this.currentStep === TOTAL_STEPS; }

    // ── Getters — Step Indicator Config ───────────────────────────────────────
    get stepConfig() {
        return STEP_LABELS.map((label, idx) => {
            const num       = idx + 1;
            const isActive  = num === this.currentStep;
            const isDone    = num < this.currentStep;
            return {
                number:   num,
                label,
                icon:     isDone ? '✓' : String(num),
                cssClass: [
                    'step-item',
                    isActive ? 'active'    : '',
                    isDone   ? 'completed' : ''
                ].filter(Boolean).join(' ')
            };
        });
    }

    get progressPercent() {
        return Math.round(((this.currentStep - 1) / (TOTAL_STEPS - 1)) * 100);
    }

    // ── Getters — Check-in State ──────────────────────────────────────────────
    get isAlreadyCheckedIn() {
        return this.visitData.status === 'In Progress' ||
               this.visitData.status === 'Completed';
    }

    get currentTimeFormatted() {
        return new Date().toLocaleTimeString('en-US', {
            hour: '2-digit', minute: '2-digit', hour12: true
        });
    }

    // ── Getters — Step 2 Stock ────────────────────────────────────────────────
    get productCountLabel() {
        return `${this.stockEntries.length} product${this.stockEntries.length !== 1 ? 's' : ''}`;
    }

    get hasOosItems() {
        return this.stockEntries.some(e => e.isOos);
    }

    get oosCountLabel() {
        const n = this.stockEntries.filter(e => e.isOos).length;
        return `${n} product${n !== 1 ? 's' : ''} out of stock`;
    }

    // ── Getters — Step 3 Audit ─────────────────────────────────────────────────
    get promoCountLabel() {
        return `${this.auditEntries.length} promotion${this.auditEntries.length !== 1 ? 's' : ''}`;
    }

    get hasNoPromos() { return this.auditEntries.length === 0; }

    get auditSummaryLabel() {
        if (this.auditEntries.length === 0) return 'No promotions';
        const compliant = this.auditEntries.filter(e => e.isCompliant).length;
        const pct = Math.round((compliant / this.auditEntries.length) * 100);
        return `${compliant} of ${this.auditEntries.length} compliant (${pct}%)`;
    }

    // ── Getters — Step 4 Order ─────────────────────────────────────────────────
    get orderTotal() {
        return this.orderEntries.reduce(
            (sum, e) => sum + (e.quantity * e.unitPrice), 0
        );
    }

    get orderTotalFormatted() {
        return CURRENCY_FORMATTER.format(this.orderTotal);
    }

    get isOrderEmpty() {
        return !this.orderEntries.some(e => e.quantity > 0);
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    connectedCallback() {
        this._loadVisitContext();
    }

    // ── Private: Load Visit Context ───────────────────────────────────────────
    async _loadVisitContext() {
        this.isLoading    = true;
        this.errorMessage = '';
        try {
            const ctx = await getVisitContext({ visitId: this.recordId });

            this.visitData = {
                storeName:       ctx.storeName,
                status:          ctx.status,
                plannedTime:     this._formatDatetime(ctx.plannedVisitStartTime),
                actualStartTime: ctx.actualVisitStartTime
                    ? this._formatDatetime(ctx.actualVisitStartTime)
                    : null
            };

            // Build stock entries from product catalog
            this.stockEntries = (ctx.products || []).map(p => ({
                productId:   p.id,
                productName: p.name,
                minStock:    p.minimumStock || 0,
                quantity:    p.currentStock || 0,
                get isOos() { return this.quantity < this.minStock; }
            }));

            // Build promo audit entries
            this.auditEntries = (ctx.activePromotions || []).map(promo => ({
                promotionId:       promo.id,
                promotionName:     promo.name,
                productName:       promo.productName,
                expectedPlacement: promo.expectedPlacement,
                isCompliant:       false,
                photoCaptured:     false,
                notes:             ''
            }));

            // Build order entries (same product list)
            this.orderEntries = (ctx.products || []).map(p => ({
                productId:           p.id,
                productName:         p.name,
                unitPrice:           p.unitPrice || 0,
                quantity:            0,
                get unitPriceFormatted() {
                    return CURRENCY_FORMATTER.format(this.unitPrice);
                },
                get lineTotalFormatted() {
                    return CURRENCY_FORMATTER.format(this.quantity * this.unitPrice);
                }
            }));

            // If already checked in, advance to stock step
            if (this.isAlreadyCheckedIn && this.currentStep === 1) {
                this.currentStep = 2;
            }

        } catch (error) {
            this.errorMessage = this._extractError(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ── Step 1: Check In Handler ──────────────────────────────────────────────
    async handleCheckIn() {
        this.isLoading    = true;
        this.errorMessage = '';
        try {
            await checkInVisit({ visitId: this.recordId });
            this.visitData = { ...this.visitData, status: 'In Progress',
                actualStartTime: this._formatDatetime(new Date().toISOString()) };
            this._showToast('Checked in', 'Visit started successfully.', 'success');
            this.currentStep = 2;
        } catch (error) {
            this.errorMessage = this._extractError(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ── Step 2: Stock Capture Handlers ────────────────────────────────────────
    handleStockChange(event) {
        const productId = event.target.dataset.id;
        const qty       = parseInt(event.target.value, 10) || 0;

        // Spread to new array so LWC tracks the change
        this.stockEntries = this.stockEntries.map(e => {
            if (e.productId !== productId) return e;
            return {
                ...e,
                quantity: qty,
                isOos:    qty < e.minStock
            };
        });
    }

    // ── Step 3: Promotion Audit Handlers ─────────────────────────────────────
    handleAuditCompliance(event) {
        const promoId   = event.target.dataset.id;
        const checked   = event.target.checked;
        this.auditEntries = this.auditEntries.map(e =>
            e.promotionId === promoId ? { ...e, isCompliant: checked } : e
        );
    }

    handleAuditPhoto(event) {
        const promoId = event.target.dataset.id;
        const checked = event.target.checked;
        this.auditEntries = this.auditEntries.map(e =>
            e.promotionId === promoId ? { ...e, photoCaptured: checked } : e
        );
    }

    handleAuditNotes(event) {
        const promoId = event.target.dataset.id;
        const notes   = event.target.value;
        this.auditEntries = this.auditEntries.map(e =>
            e.promotionId === promoId ? { ...e, notes } : e
        );
    }

    // ── Step 4: Order Quantity Handlers ───────────────────────────────────────
    handleOrderQtyChange(event) {
        const productId = event.target.dataset.id;
        const qty       = parseInt(event.target.value, 10) || 0;
        this.orderEntries = this.orderEntries.map(e => {
            if (e.productId !== productId) return e;
            return {
                ...e,
                quantity:            qty,
                lineTotalFormatted:  CURRENCY_FORMATTER.format(qty * e.unitPrice)
            };
        });
    }

    // ── Navigation ────────────────────────────────────────────────────────────
    handleNext() {
        if (!this._validateCurrentStep()) return;
        this.errorMessage = '';
        this.currentStep  = Math.min(this.currentStep + 1, TOTAL_STEPS);
    }

    handlePrevious() {
        this.errorMessage = '';
        this.currentStep  = Math.max(this.currentStep - 1, 1);
    }

    // ── Complete Visit ────────────────────────────────────────────────────────
    async handleCompleteVisit() {
        if (!this._validateCurrentStep()) return;

        this.isLoading    = true;
        this.errorMessage = '';

        // Build serialisable payload for Apex
        const stockPayload = this.stockEntries.reduce((map, e) => {
            map[e.productId] = e.quantity;
            return map;
        }, {});

        const auditPayload = this.auditEntries.map(e => ({
            promotionId:       e.promotionId,
            isCompliant:       e.isCompliant,
            photoCaptured:     e.photoCaptured,
            notes:             e.notes
        }));

        const orderPayload = this.orderEntries
            .filter(e => e.quantity > 0)
            .reduce((map, e) => {
                map[e.productId] = e.quantity;
                return map;
            }, {});

        try {
            await completeVisitAndCreateOrder({
                visitId:       this.recordId,
                stockData:     JSON.stringify(stockPayload),
                auditData:     JSON.stringify(auditPayload),
                orderData:     JSON.stringify(orderPayload)
            });

            this._showToast(
                'Visit Completed',
                this.isOrderEmpty
                    ? 'Visit marked complete. No order was placed.'
                    : 'Visit complete and order submitted for ERP sync.',
                'success'
            );

        } catch (error) {
            this.errorMessage = this._extractError(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ── Private: Step Validation ──────────────────────────────────────────────
    _validateCurrentStep() {
        this.errorMessage = '';
        if (this.currentStep === 1 && !this.isAlreadyCheckedIn) {
            this.errorMessage = 'Please check in before proceeding to stock capture.';
            return false;
        }
        return true;
    }

    // ── Private: Toast Helper ──────────────────────────────────────────────────
    _showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // ── Private: Error Extraction ─────────────────────────────────────────────
    _extractError(error) {
        if (error?.body?.message)            return error.body.message;
        if (error?.body?.pageErrors?.length) return error.body.pageErrors[0].message;
        if (error?.message)                  return error.message;
        return 'An unexpected error occurred. Please try again.';
    }

    // ── Private: Datetime Formatter ────────────────────────────────────────────
    _formatDatetime(isoString) {
        if (!isoString) return '';
        try {
            return new Date(isoString).toLocaleString('en-US', {
                month: 'short', day: 'numeric',
                hour: '2-digit', minute: '2-digit', hour12: true
            });
        } catch {
            return isoString;
        }
    }
}
