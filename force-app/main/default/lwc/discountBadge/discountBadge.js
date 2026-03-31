/**
 * @description discountBadge — Purely presentational leaf component.
 *
 *              Receives discount percentage and final price as @api props,
 *              renders a colour-coded badge with tooltip. No side effects.
 *
 *              Rendering model notes:
 *                - Template expressions {{ }} are re-evaluated on EVERY render.
 *                - Getters (computed properties) are also re-evaluated on every render.
 *                - Heavy computations (sorting large arrays, expensive string ops) should
 *                  be cached in a reactive property and updated only when inputs change,
 *                  NOT performed in a getter that fires 20x per second.
 *                - For primitives like this badge, getters are perfectly fine.
 *
 *              Shadow DOM rendering flow for this component:
 *                1. Parent passes discount-percent and final-price as attributes
 *                2. LWC converts kebab-case attributes to camelCase @api props
 *                3. Component renders — badgeClass / badgeLabel getters execute
 *                4. Shadow DOM updates ONLY the changed nodes (virtual DOM diffing)
 *                5. No lifecycle callbacks fire on prop-only updates after initial mount
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api } from 'lwc';

export default class DiscountBadge extends LightningElement {

    /**
     * @api props: publicly settable by any parent component.
     *
     * Rules:
     *   1. Never mutate an @api property from inside the component.
     *      @api is a one-way data binding — parent → child.
     *      If the child needs to communicate back, dispatch a custom event.
     *   2. @api properties are undefined on first render before the parent sets them.
     *      Always guard against null/undefined in getters.
     *   3. Setting an @api property from the component's own JS throws a warning.
     */
    @api discountPercent = 0;  // default 0 so badge renders even if parent omits it
    @api finalPrice       = 0;

    // ─── Getters ──────────────────────────────────────────────────────────────────

    /**
     * Computed CSS class string — re-evaluated on every render.
     * Returns a single string with all applicable class names separated by spaces.
     * LWC does NOT support object/array class bindings like Vue/React —
     * the class attribute must be a plain string.
     */
    get badgeClass() {
        const pct = this.discountPercent ?? 0;
        if (pct >= 15) return 'discount-badge discount-badge--high';
        if (pct >= 10) return 'discount-badge discount-badge--medium';
        if (pct > 0)   return 'discount-badge discount-badge--low';
        return 'discount-badge discount-badge--none';
    }

    get badgeLabel() {
        const pct = this.discountPercent ?? 0;
        if (pct <= 0) return 'No discount';
        return `${pct}% off`;
    }

    get formattedFinalPrice() {
        const price = this.finalPrice ?? 0;
        return new Intl.NumberFormat('en-US', {
            style: 'currency', currency: 'USD', maximumFractionDigits: 0
        }).format(price);
    }

    get tooltipText() {
        if (!this.discountPercent || this.discountPercent <= 0) return 'No discount applied';
        return `${this.discountPercent}% discount applied. Final: ${this.formattedFinalPrice}`;
    }

    get ariaLabel() {
        return `Discount: ${this.badgeLabel}`;
    }
}
