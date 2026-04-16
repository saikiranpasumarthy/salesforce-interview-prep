/**
 * @description memberDashboard LWC — Experience Cloud member home page.
 *
 *              Data strategy:
 *                • getMemberSummary called imperatively on connectedCallback
 *                  (not wire — balance changes after redemption must be fresh)
 *                • refreshData() called after redemption wizard closes successfully
 *                • Skeleton loading state shown during all async operations
 *
 *              Computed properties:
 *                • tierBadgeCssClass, heroCssClass — derived from currentTier
 *                • formattedPointsBalance — Intl.NumberFormat for locale-aware display
 *                • showTierProgress — false for Platinum (already at top tier)
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMemberSummary from '@salesforce/apex/LoyaltyMemberService.getMemberSummary';

const TIER_COLORS = {
    Silver   : '#C0C0C0',
    Gold     : '#FFD700',
    Platinum : '#E5E4E2',
    Bronze   : '#CD7F32'
};

const TIER_ICONS = {
    Silver   : '⚪',
    Gold     : '⭐',
    Platinum : '💎',
    Bronze   : '🔶'
};

const CHANNEL_ICONS = {
    Online  : 'utility:world',
    InStore : 'utility:store',
    App     : 'utility:phone_portrait',
    Referral: 'utility:people',
    System  : 'utility:settings'
};

export default class MemberDashboard extends LightningElement {

    @api memberId;

    @track memberData      = null;
    @track isLoading       = false;
    @track hasError        = false;
    @track errorMessage    = '';
    @track showTransactions      = false;
    @track showRedemptionWizard  = false;

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    connectedCallback() {
        this._loadMemberData();
    }

    // ── Data loading ──────────────────────────────────────────────────────────

    async _loadMemberData() {
        if (!this.memberId) {
            this.hasError    = true;
            this.errorMessage = 'Member ID is not configured for this component.';
            return;
        }

        this.isLoading = true;
        this.hasError  = false;

        try {
            const data = await getMemberSummary({ memberId: this.memberId });
            this.memberData = data;
        } catch (error) {
            this.hasError    = true;
            this.errorMessage = error?.body?.message
                || error?.message
                || 'Unable to load member data. Please try again.';
            this._showToast('Error', this.errorMessage, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Computed properties ───────────────────────────────────────────────────

    get isLoaded() {
        return !this.isLoading && !this.hasError && this.memberData != null;
    }

    get heroCssClass() {
        const tier = this.memberData?.currentTier?.toLowerCase() || 'silver';
        return `hero-section hero-section--${tier} slds-p-around_large`;
    }

    get tierBadgeCssClass() {
        const tier = this.memberData?.currentTier?.toLowerCase() || 'silver';
        return `tier-badge tier-badge--${tier}`;
    }

    get tierIcon() {
        return TIER_ICONS[this.memberData?.currentTier] || '⚪';
    }

    get formattedPointsBalance() {
        const balance = this.memberData?.pointsBalance || 0;
        return new Intl.NumberFormat('en-US').format(balance);
    }

    get formattedBonusPoints() {
        const bonus = this.memberData?.bonusPoints || 0;
        return new Intl.NumberFormat('en-US').format(bonus);
    }

    get hasBonusPoints() {
        return (this.memberData?.bonusPoints || 0) > 0;
    }

    get showTierProgress() {
        return this.memberData?.currentTier !== 'Platinum'
            && this.memberData?.nextTierName != null;
    }

    get formattedPointsToNextTier() {
        const pts = this.memberData?.pointsToNextTier || 0;
        return new Intl.NumberFormat('en-US').format(pts);
    }

    get hasActiveVouchers() {
        return this.memberData?.activeVouchers?.length > 0;
    }

    get hasTransactions() {
        return this.memberData?.recentTransactions?.length > 0;
    }

    get transactionToggleLabel() {
        return this.showTransactions ? 'Hide History' : 'View History';
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleRetry() {
        this._loadMemberData();
    }

    handleToggleTransactions() {
        this.showTransactions = !this.showTransactions;
    }

    handleOpenRedemptionWizard() {
        this.showRedemptionWizard = true;
    }

    handleWizardClose() {
        this.showRedemptionWizard = false;
    }

    handleRedemptionSuccess() {
        this.showRedemptionWizard = false;
        this._showToast(
            'Redemption Successful',
            'Your voucher has been generated and emailed to you.',
            'success'
        );
        // Refresh balance — data is stale after redemption
        this._loadMemberData();
    }

    handleCopyCode(event) {
        const code = event.currentTarget.dataset.code;
        if (navigator.clipboard) {
            navigator.clipboard.writeText(code)
                .then(() => this._showToast('Copied!', 'Voucher code copied to clipboard.', 'success'))
                .catch(() => this._showToast('Error', 'Could not copy code.', 'error'));
        }
    }

    // ── Template helper methods ───────────────────────────────────────────────

    getChannelIcon(channel) {
        return CHANNEL_ICONS[channel] || 'utility:record';
    }

    getPointsCss(transactionType) {
        return transactionType === 'Earn' || transactionType === 'Referral'
            ? 'txn-points txn-points--earn'
            : 'txn-points txn-points--redeem';
    }

    formatPoints(totalPoints, transactionType) {
        const abs = Math.abs(totalPoints || 0);
        const formatted = new Intl.NumberFormat('en-US').format(abs);
        const prefix = (transactionType === 'Earn' || transactionType === 'Referral')
            ? '+' : '-';
        return `${prefix}${formatted} pts`;
    }

    formatDate(dateString) {
        if (!dateString) return '';
        return new Intl.DateTimeFormat('en-US', {
            month: 'short', day: 'numeric', year: 'numeric'
        }).format(new Date(dateString));
    }

    getVoucherStatusCss(status) {
        const statusMap = {
            Active    : 'voucher-status voucher-status--active',
            Generated : 'voucher-status voucher-status--active',
            Expired   : 'voucher-status voucher-status--expired',
            Redeemed  : 'voucher-status voucher-status--redeemed'
        };
        return statusMap[status] || 'voucher-status';
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    _showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
