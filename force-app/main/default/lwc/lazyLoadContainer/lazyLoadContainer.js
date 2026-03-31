/**
 * @description lazyLoadContainer — deferred rendering via IntersectionObserver.
 *
 *              Core pattern:
 *              1. Mount a lightweight sentinel div (no heavy child DOM).
 *              2. Attach IntersectionObserver to the sentinel in connectedCallback.
 *              3. When isIntersecting === true, set isVisible = true → lwc:if
 *                 unmasks the slot, which triggers child connectedCallback + @wire calls.
 *              4. Disconnect the observer immediately after first reveal (observe once).
 *
 *              Why connectedCallback, not renderedCallback?
 *                connectedCallback fires once when added to DOM — correct place to
 *                attach observers / subscriptions. renderedCallback fires after
 *                every re-render (including child renders) — would re-attach the
 *                observer on each update.
 *
 *              IntersectionObserver vs setTimeout(0):
 *                IntersectionObserver — native browser API; fires only when element
 *                  enters the viewport; battery and CPU friendly.
 *                setTimeout(0)        — defers to next event loop tick; renders even
 *                  when the component is off-screen (e.g. hidden tab). Use only as
 *                  a polyfill fallback.
 *
 *              @api forceLoad — parent can call forceLoad = true to bypass lazy
 *                behaviour (e.g. when screen-reader mode is active or for tests).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api, track } from 'lwc';

/** Pixels before the element enters viewport to start loading (positive = early) */
const ROOT_MARGIN = '100px';

export default class LazyLoadContainer extends LightningElement {

    /** @api threshold — fraction of sentinel that must be visible (0–1) */
    @api threshold = 0;

    /** @api forceLoad — set true to skip IntersectionObserver and render immediately */
    @api
    get forceLoad() { return this._forceLoad; }
    set forceLoad(value) {
        this._forceLoad = value;
        if (value) {
            this._reveal();
        }
    }

    /** @api label — optional accessible label for the skeleton placeholder */
    @api label = 'Loading content…';

    // ─── Internal state ───────────────────────────────────────────────────────────

    @track isVisible  = false;
    @track isWaiting  = true;

    _forceLoad        = false;
    _observer         = null;

    // ─── Lifecycle ────────────────────────────────────────────────────────────────

    connectedCallback() {
        if (this._forceLoad) {
            // Skip observer — reveal synchronously
            this._reveal();
            return;
        }

        if (typeof IntersectionObserver === 'undefined') {
            // SSR / jsdom / test environment — fall back to immediate reveal
            this._revealAfterTick();
            return;
        }

        // Defer observer creation to after first render so lwc:ref is available
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => this._attachObserver());
    }

    disconnectedCallback() {
        this._detachObserver();
    }

    // ─── Observer management ──────────────────────────────────────────────────────

    /**
     * Attaches IntersectionObserver to the sentinel element.
     * Uses lwc:ref="sentinel" to access the host div without querySelector
     * (querySelector cannot pierce shadow DOM boundaries from parent components).
     */
    _attachObserver() {
        const sentinel = this.refs?.sentinel;
        if (!sentinel) {
            // refs not ready — fall back
            this._revealAfterTick();
            return;
        }

        this._observer = new IntersectionObserver(
            (entries) => this._onIntersect(entries),
            {
                root:       null,              // viewport
                rootMargin: ROOT_MARGIN,       // pre-load 100px before visible
                threshold:  this.threshold
            }
        );
        this._observer.observe(sentinel);
    }

    _detachObserver() {
        if (this._observer) {
            this._observer.disconnect();
            this._observer = null;
        }
    }

    /**
     * IntersectionObserver callback.
     * Fires once when the sentinel enters the viewport; reveals slot content
     * and immediately disconnects the observer (observe-once pattern).
     *
     * @param {IntersectionObserverEntry[]} entries
     */
    _onIntersect(entries) {
        const entry = entries[0];
        if (entry && entry.isIntersecting) {
            this._reveal();
        }
    }

    // ─── Reveal helpers ───────────────────────────────────────────────────────────

    _reveal() {
        this.isVisible = true;
        this.isWaiting = false;
        this._detachObserver();
    }

    /**
     * Fallback: defer to next microtask tick.
     * Used in environments without IntersectionObserver (Jest / jsdom).
     */
    _revealAfterTick() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => this._reveal());
    }
}
