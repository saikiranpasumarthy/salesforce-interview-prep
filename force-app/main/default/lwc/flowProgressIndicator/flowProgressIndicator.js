/**
 * @description flowProgressIndicator — Custom LWC component for Screen Flows.
 *
 *              Demonstrates all key Screen Flow LWC integration patterns:
 *
 *              1. lightning__FlowScreen target (js-meta.xml)
 *                 Marks this component as embeddable in Screen Flow screens.
 *                 The Flow Builder shows it in the component palette for screens.
 *
 *              2. @api availableActions (injected by Flow runtime)
 *                 The Flow runtime injects an array of strings listing which
 *                 navigation actions are available on the current screen:
 *                 ['NEXT'] | ['BACK', 'NEXT'] | ['BACK', 'FINISH'] etc.
 *                 Use to conditionally render custom navigation buttons or
 *                 disable buttons that are not available.
 *
 *              3. FlowNavigationNextEvent / FlowNavigationBackEvent / FlowNavigationFinishEvent
 *                 Import from 'lightning/flowSupport'. Dispatch on the component
 *                 to trigger navigation programmatically (e.g., after async validation).
 *
 *              4. FlowAttributeChangeEvent
 *                 Import from 'lightning/flowSupport'. Dispatch to notify the Flow
 *                 runtime that an @api output variable has changed. Required for
 *                 output variables defined in targetConfig with role="outputOnly"
 *                 or "inputOutput" — the Flow does not poll @api props.
 *
 *              5. @api validate()
 *                 The Flow runtime calls validate() BEFORE advancing to the next
 *                 screen. Return { isValid: true } to allow navigation.
 *                 Return { isValid: false, errorMessage: '...' } to block it.
 *                 Use for client-side validation that Flow's required=true cannot express
 *                 (e.g., "at least one checkbox checked", regex format validation).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api } from 'lwc';
import {
    FlowNavigationNextEvent,
    FlowNavigationBackEvent,
    FlowNavigationFinishEvent,
    FlowAttributeChangeEvent
} from 'lightning/flowSupport';

export const AVAILABLE_ACTIONS = {
    NEXT:   'NEXT',
    BACK:   'BACK',
    FINISH: 'FINISH',
    PAUSE:  'PAUSE'
};

export default class FlowProgressIndicator extends LightningElement {

    // ─── @api props injected by the Flow canvas ───────────────────────────────

    /**
     * @api availableActions — injected by the Flow runtime.
     * Contains strings from AVAILABLE_ACTIONS for the current screen.
     * Example: ['BACK', 'NEXT'] on screen 2.
     *          ['BACK', 'FINISH'] on last screen.
     * Never set this from outside the Flow runtime — it is a platform-managed prop.
     */
    @api availableActions = [];

    /** @api currentStep — 1-based index of the active step (set by Flow canvas) */
    @api currentStep = 1;

    /** @api totalSteps — total number of steps in the wizard */
    @api totalSteps = 3;

    /**
     * @api stepLabels — comma-separated step labels.
     * Example: "Account,Contact,Opportunity"
     * Parsed into an array in the `steps` getter.
     */
    @api stepLabels = '';

    // ─── Getters ──────────────────────────────────────────────────────────────

    get steps() {
        const labels = (this.stepLabels ?? '').split(',').map(l => l.trim());
        const count  = Number(this.totalSteps) || 3;
        const active = Number(this.currentStep) || 1;

        return Array.from({ length: count }, (_, i) => {
            const stepNum     = i + 1;
            const isCompleted = stepNum < active;
            const isActive    = stepNum === active;

            return {
                index:          i,
                number:         stepNum,
                label:          labels[i] ?? `Step ${stepNum}`,
                isCompleted,
                isActive,
                showConnector:  stepNum < count,
                containerClass: 'step-container',
                circleClass:    this._circleClass(isCompleted, isActive),
                connectorClass: isCompleted ? 'connector connector--completed' : 'connector',
                labelClass:     isActive    ? 'step-label step-label--active'
                              : isCompleted ? 'step-label step-label--completed'
                              : 'step-label'
            };
        });
    }

    get progressLabel() {
        return `Step ${this.currentStep} of ${this.totalSteps}`;
    }

    get canGoBack() {
        return this.availableActions.includes(AVAILABLE_ACTIONS.BACK);
    }

    get canGoNext() {
        return this.availableActions.includes(AVAILABLE_ACTIONS.NEXT);
    }

    get canFinish() {
        return this.availableActions.includes(AVAILABLE_ACTIONS.FINISH);
    }

    // ─── Flow navigation event dispatchers ────────────────────────────────────

    /**
     * Dispatch FlowNavigationNextEvent to advance the Flow to the next screen.
     * The Flow runtime handles the transition — no router needed in LWC.
     *
     * Use case: custom Next button, or programmatic advance after async validation.
     */
    handleNext() {
        if (this.canGoNext) {
            this.dispatchEvent(new FlowNavigationNextEvent());
        }
    }

    handleBack() {
        if (this.canGoBack) {
            this.dispatchEvent(new FlowNavigationBackEvent());
        }
    }

    handleFinish() {
        if (this.canFinish) {
            this.dispatchEvent(new FlowNavigationFinishEvent());
        }
    }

    /**
     * @api validate() — called by Flow BEFORE advancing to the next screen.
     *
     *   Return { isValid: true }                          → allow navigation
     *   Return { isValid: false, errorMessage: 'text' }   → block + show error
     *
     * Use for validation that Flow's required=true cannot express:
     *   - "at least 2 items selected from a multi-select"
     *   - "regex format (e.g., postal code)"
     *   - "cross-field dependency (field B required when field A = X)"
     *
     * This component is a progress indicator — it always passes validation.
     * In a real component (e.g., a custom file upload or map picker), you would
     * check internal component state before returning isValid.
     */
    @api validate() {
        // Progress indicator has no user input — always valid
        return { isValid: true };
    }

    /**
     * Example: how to report an output variable change back to the Flow.
     *
     * If this component had an output variable (e.g., selectedItemId),
     * call FlowAttributeChangeEvent when the value changes so the Flow
     * runtime updates its variable store before the user navigates.
     *
     * @param {string} attributeName - matches the @api property name
     * @param {*}      value         - new value
     */
    _notifyFlowAttributeChange(attributeName, value) {
        this.dispatchEvent(new FlowAttributeChangeEvent(attributeName, value));
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    _circleClass(isCompleted, isActive) {
        if (isCompleted) return 'step-circle step-circle--completed';
        if (isActive)    return 'step-circle step-circle--active';
        return 'step-circle step-circle--upcoming';
    }
}
