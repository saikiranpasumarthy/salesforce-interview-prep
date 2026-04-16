/**
 * @description pointsRedemptionWizard LWC — 4-step points redemption modal.
 *
 *              State machine:
 *                Step 1: reward type selection (cards)
 *                Step 2: points input with live discount preview
 *                Step 3: summary + terms checkbox + confirm
 *                Step 4: success — voucher code display
 *
 *              Patterns:
 *                • currentStep integer drives all conditional rendering
 *                • pointsToRedeem reactive — drives discount preview in real-time
 *                • Confirm button disabled during processing (double-submit prevention)
 *                • stopPropagation on modal container prevents backdrop click close
 *                • Fires 'redemptionsuccess' event to parent on step 4 close
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import processRedemption from '@salesforce/apex/RedemptionService.processRedemption';

const TOTAL_STEPS = 4;
const POINTS_TO_DOLLAR_RATE = 0.01; // 100 pts = $1
const DEFAULT_MIN_POINTS     = 500;

const REWARD_LABELS = {
    DiscountVoucher    : 'Discount Voucher',
    FreeProductVoucher : 'Free Product Voucher',
    PartnerReward      : 'Partner Reward'
};

const STEP_LABELS = ['Reward Type', 'Amount', 'Confirm', 'Done'];

export default class PointsRedemptionWizard extends LightningElement {

    @api memberId;
    @api pointsBalance   = 0;
    @api currentTier     = 'Silver';

    @track currentStep         = 1;
    @track selectedRewardType  = null;
    @track pointsToRedeem      = DEFAULT_MIN_POINTS;
    @track termsAccepted       = false;
    @track isProcessing        = false;
    @track hasStep2Error       = false;
    @track step2ErrorMessage   = '';
    @track hasSubmitError      = false;
    @track submitErrorMessage  = '';

    // Step 4 result data
    @track generatedVoucherCode  = '';
    @track generatedExpiryDate   = null;
    @track generatedDiscountValue = 0;

    minRedemptionPoints = DEFAULT_MIN_POINTS;

    // ── Computed: step indicators ─────────────────────────────────────────────

    get steps() {
        return STEP_LABELS.map((label, idx) => {
            const num = idx + 1;
            let cssClass = 'step-item';
            if (num === this.currentStep) cssClass += ' step-item--active';
            else if (num < this.currentStep) cssClass += ' step-item--complete';
            return { number: num, label, cssClass };
        });
    }

    // ── Computed: step booleans ───────────────────────────────────────────────

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }

    // ── Computed: button labels & states ─────────────────────────────────────

    get primaryButtonLabel() {
        if (this.currentStep === 3) return this.isProcessing ? 'Processing…' : 'Confirm';
        return 'Next';
    }

    get isPrimaryDisabled() {
        if (this.isStep1) return !this.selectedRewardType;
        if (this.isStep2) return this.hasStep2Error || this.pointsToRedeem < this.minRedemptionPoints;
        if (this.isStep3) return !this.termsAccepted || this.isProcessing;
        return false;
    }

    get showBackButton() {
        return this.currentStep === 2 || this.currentStep === 3;
    }

    // ── Computed: tier eligibility ────────────────────────────────────────────

    get isNotGoldOrPlatinum() {
        return this.currentTier !== 'Gold' && this.currentTier !== 'Platinum';
    }

    get isNotPlatinum() {
        return this.currentTier !== 'Platinum';
    }

    // ── Computed: points & preview ────────────────────────────────────────────

    get formattedBalance() {
        return new Intl.NumberFormat('en-US').format(this.pointsBalance || 0);
    }

    get maxRedeemablePoints() {
        return Math.floor((this.pointsBalance || 0) / 100) * 100;
    }

    get discountValue() {
        return (this.pointsToRedeem || 0) * POINTS_TO_DOLLAR_RATE;
    }

    get formattedDiscountValue() {
        const val = this.isStep4 ? this.generatedDiscountValue : this.discountValue;
        return val.toFixed(2);
    }

    get formattedPointsToRedeem() {
        return new Intl.NumberFormat('en-US').format(this.pointsToRedeem || 0);
    }

    get remainingBalance() {
        return (this.pointsBalance || 0) - (this.pointsToRedeem || 0);
    }

    get formattedRemainingBalance() {
        return new Intl.NumberFormat('en-US').format(Math.max(0, this.remainingBalance));
    }

    get remainingBalanceCss() {
        return this.remainingBalance < 0
            ? 'preview-value preview-value--negative'
            : 'preview-value';
    }

    get selectedRewardLabel() {
        return REWARD_LABELS[this.selectedRewardType] || '';
    }

    get formattedExpiryDate() {
        if (!this.generatedExpiryDate) return '';
        return new Intl.DateTimeFormat('en-US', {
            month: 'long', day: 'numeric', year: 'numeric'
        }).format(new Date(this.generatedExpiryDate));
    }

    // ── Reward card CSS helpers ───────────────────────────────────────────────

    getRewardCardCss(type) {
        return `reward-card slds-button ${this.selectedRewardType === type ? 'reward-card--selected' : ''}`;
    }

    getRewardCardCssGold(type) {
        const disabled = this.isNotGoldOrPlatinum ? ' reward-card--disabled' : '';
        const selected = this.selectedRewardType === type ? ' reward-card--selected' : '';
        return `reward-card slds-button${disabled}${selected}`;
    }

    getRewardCardCssPlatinum(type) {
        const disabled = this.isNotPlatinum ? ' reward-card--disabled' : '';
        const selected = this.selectedRewardType === type ? ' reward-card--selected' : '';
        return `reward-card slds-button${disabled}${selected}`;
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleRewardTypeSelect(event) {
        this.selectedRewardType = event.currentTarget.dataset.type;
    }

    handlePointsChange(event) {
        const val = parseInt(event.detail.value, 10);
        this.pointsToRedeem = isNaN(val) ? this.minRedemptionPoints : val;
        this._validateStep2();
    }

    handleTermsChange(event) {
        this.termsAccepted = event.target.checked;
    }

    handlePrimaryAction() {
        if (this.isStep1 && this.selectedRewardType) {
            this.currentStep = 2;
        } else if (this.isStep2) {
            if (this._validateStep2()) {
                this.currentStep = 3;
            }
        } else if (this.isStep3) {
            this._submitRedemption();
        }
    }

    handleBack() {
        if (this.currentStep > 1) {
            this.currentStep--;
            this.hasSubmitError = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handleSuccessClose() {
        this.dispatchEvent(new CustomEvent('redemptionsuccess'));
    }

    handleBackdropClick() {
        if (!this.isStep4) {
            this.handleClose();
        }
    }

    handleCopyVoucherCode() {
        if (navigator.clipboard && this.generatedVoucherCode) {
            navigator.clipboard.writeText(this.generatedVoucherCode)
                .then(() => {
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Copied!',
                        message: 'Voucher code copied to clipboard.',
                        variant: 'success'
                    }));
                })
                .catch(() => {});
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    _validateStep2() {
        const pts = this.pointsToRedeem || 0;

        if (pts < this.minRedemptionPoints) {
            this.hasStep2Error    = true;
            this.step2ErrorMessage = `Minimum redemption is ${this.minRedemptionPoints} points.`;
            return false;
        }
        if (pts > (this.pointsBalance || 0)) {
            this.hasStep2Error    = true;
            this.step2ErrorMessage = `Cannot exceed your current balance of ${this.formattedBalance} points.`;
            return false;
        }
        if (pts % 100 !== 0) {
            this.hasStep2Error    = true;
            this.step2ErrorMessage = 'Points must be redeemed in multiples of 100.';
            return false;
        }

        this.hasStep2Error    = false;
        this.step2ErrorMessage = '';
        return true;
    }

    async _submitRedemption() {
        this.isProcessing     = true;
        this.hasSubmitError   = false;
        this.submitErrorMessage = '';

        try {
            const result = await processRedemption({
                memberId      : this.memberId,
                pointsToRedeem: this.pointsToRedeem,
                rewardType    : this.selectedRewardType,
                rewardValue   : this.discountValue
            });

            if (result.isSuccess) {
                this.generatedVoucherCode   = result.redemptionCode;
                this.generatedExpiryDate    = result.expiryDate;
                this.generatedDiscountValue = result.discountValue;
                this.currentStep = 4;
            } else {
                this.hasSubmitError    = true;
                this.submitErrorMessage = result.errorMessage
                    || 'Redemption failed. Please try again.';
            }
        } catch (error) {
            this.hasSubmitError    = true;
            this.submitErrorMessage = error?.body?.message
                || error?.message
                || 'An unexpected error occurred. Please try again.';
        } finally {
            this.isProcessing = false;
        }
    }
}
