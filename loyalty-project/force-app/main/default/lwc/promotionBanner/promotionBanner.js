/**
 * @description promotionBanner LWC — Active promotions carousel for Experience Cloud.
 *
 *              Data strategy:
 *                • getActiveMemberPromotions wired on init (read-heavy, periodic refresh)
 *                • setInterval auto-refreshes every 5 minutes
 *                • disconnectedCallback clears the interval to prevent memory leaks
 *                • Manual refresh button triggers refreshApex
 *
 *              Mobile:
 *                • Horizontal scroll track — CSS scroll-snap for mobile swipe
 *                • Arrow buttons for desktop navigation
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getActiveMemberPromotions
    from '@salesforce/apex/PromotionEngineService.getActiveMemberPromotions';

const REFRESH_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes
const SCROLL_AMOUNT_PX    = 320;            // pixels per arrow click

export default class PromotionBanner extends LightningElement {

    @api memberId;

    @track promotions    = [];
    @track isLoading     = true;
    @track hasError      = false;
    @track lastRefreshed = null;

    _wiredPromotionsResult = null;
    _refreshInterval       = null;

    // ── Wire ──────────────────────────────────────────────────────────────────

    @wire(getActiveMemberPromotions, { memberId: '$memberId' })
    wiredPromotions(result) {
        this._wiredPromotionsResult = result;
        this.isLoading = false;

        if (result.data !== undefined) {
            if (result.error) {
                this.hasError   = true;
                this.promotions = [];
            } else {
                this.hasError      = false;
                this.promotions    = result.data || [];
                this.lastRefreshed = new Date();
            }
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    connectedCallback() {
        // Auto-refresh every 5 minutes
        this._refreshInterval = setInterval(() => {
            this._refreshData();
        }, REFRESH_INTERVAL_MS);
    }

    disconnectedCallback() {
        // CRITICAL: clear interval to prevent memory leak when component unmounts
        if (this._refreshInterval) {
            clearInterval(this._refreshInterval);
            this._refreshInterval = null;
        }
    }

    // ── Computed properties ───────────────────────────────────────────────────

    get hasPromotions() {
        return !this.isLoading && !this.hasError && this.promotions.length > 0;
    }

    get showEmptyState() {
        return !this.isLoading && !this.hasError && this.promotions.length === 0;
    }

    get lastRefreshedLabel() {
        if (!this.lastRefreshed) return 'just now';
        const diffMs   = Date.now() - this.lastRefreshed.getTime();
        const diffMins = Math.floor(diffMs / 60000);
        if (diffMins < 1)   return 'just now';
        if (diffMins === 1) return '1 min ago';
        if (diffMins < 60)  return `${diffMins} mins ago`;
        return 'over an hour ago';
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleManualRefresh() {
        this._refreshData();
    }

    handleScrollLeft() {
        const track = this.template.querySelector('[data-track]');
        if (track) {
            track.scrollBy({ left: -SCROLL_AMOUNT_PX, behavior: 'smooth' });
        }
    }

    handleScrollRight() {
        const track = this.template.querySelector('[data-track]');
        if (track) {
            track.scrollBy({ left: SCROLL_AMOUNT_PX, behavior: 'smooth' });
        }
    }

    // ── Template helpers ──────────────────────────────────────────────────────

    getTierBadgeCss(eligibleTier) {
        const tierMap = {
            'All Tiers' : 'promo-tier-badge promo-tier-badge--all',
            'Silver'    : 'promo-tier-badge promo-tier-badge--silver',
            'Gold'      : 'promo-tier-badge promo-tier-badge--gold',
            'Platinum'  : 'promo-tier-badge promo-tier-badge--platinum'
        };
        return tierMap[eligibleTier] || 'promo-tier-badge';
    }

    formatDate(dateString) {
        if (!dateString) return '';
        return new Intl.DateTimeFormat('en-US', {
            month: 'short', day: 'numeric', year: 'numeric'
        }).format(new Date(dateString));
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    _refreshData() {
        if (this._wiredPromotionsResult) {
            this.isLoading = true;
            refreshApex(this._wiredPromotionsResult)
                .then(() => {
                    this.lastRefreshed = new Date();
                    this.isLoading = false;
                })
                .catch(() => {
                    this.isLoading = false;
                });
        }
    }
}
