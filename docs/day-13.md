# Day 13 — Flows: Screen Flows, Subflows & LWC Flow Screen Components

## Topics Covered

| Topic | Pattern | Asset |
|-------|---------|-------|
| Screen Flow (3-step wizard) | Screens, choices, display text, navigation | `Account_Onboarding_Wizard` |
| Subflow call | Auto-launched flow invoked from screen flow | `Validate_Account_Data` |
| Dynamic visibility | Field-level `visibilityRule` and error screens | `Account_Onboarding_Wizard` |
| Custom LWC flow component | `lightning__FlowScreen`, `availableActions`, `@api validate()` | `flowProgressIndicator` |
| Flow navigation events | `FlowNavigationNextEvent`, `FlowNavigationBackEvent`, `FlowNavigationFinishEvent` | `flowProgressIndicator.js` |
| `FlowAttributeChangeEvent` | Notify Flow of output variable change | `flowProgressIndicator.js` |
| Server-side validation | `@InvocableMethod` format/quality checks | `FlowActionValidateAccount` |
| `Flow.Interview` testing | Subflow integration test via Apex | `FlowScreenTest` |

---

## Screen Flow Architecture

### `processType` Values

| `processType` | Display Name | Trigger |
|---|---|---|
| `Flow` | Screen Flow | Quick Action, record page, App Builder, URL |
| `AutoLaunchedFlow` | Auto-Launched Flow | Apex, subflow, REST API, scheduled, record trigger |
| `Workflow` | Legacy Process Builder | Deprecated |

### Screen Element Breakdown

```xml
<screens>
    <name>Account_Details_Screen</name>
    <allowBack>false</allowBack>     ← hides Back button (first screen)
    <allowFinish>false</allowFinish> ← hides Finish; must complete all steps
    <allowPause>false</allowPause>   ← prevents mid-flow persistence to DB
    <nextOrFinishButtonLabel>Next</nextOrFinishButtonLabel>
    <backButtonLabel>Back</backButtonLabel>
    <fields>
        <!-- InputField: text, number, currency, date inputs -->
        <!-- DropdownBox: picklist backed by <choices> -->
        <!-- DisplayText: rich HTML, merge fields {!variable} -->
        <!-- ComponentInstance: custom LWC (requires lightning__FlowScreen target) -->
    </fields>
</screens>
```

### `<fields><fieldType>` Options

| `fieldType` | Renders | Notes |
|---|---|---|
| `InputField` | Text/Number/Currency/Date input | `isRequired`, `dataType`, `defaultValue` |
| `DropdownBox` | Picklist dropdown | Backed by `<choiceReferences>` |
| `RadioButtons` | Radio button group | Same choice backing as DropdownBox |
| `MultiSelectCheckboxes` | Multi-select | Returns `List<String>` |
| `DisplayText` | Read-only rich text | `{!variable}` merge syntax |
| `ComponentInstance` | Custom LWC | `extensionName`, `inputParameters` |

### `<choices>` vs Picklist Choice Sets

```xml
<!-- Inline choice: defined in the flow XML itself -->
<choices>
    <name>Choice_Industry_Tech</name>
    <choiceText>Technology</choiceText>
    <dataType>String</dataType>
    <value><stringValue>Technology</stringValue></value>
</choices>
```

**Picklist Choice Set** (not shown in XML here — configured in Flow Builder):
- Reads values dynamically from an sObject's picklist field
- Automatically stays in sync when field values change
- Use for standard/custom picklist fields; use inline choices for static options

---

## Subflow Pattern

### When to Use Subflows

- **Reuse**: same validation logic needed in multiple flows
- **Maintainability**: complex logic extracted into a focused, named unit
- **Testing**: subflows can be tested via `Flow.Interview` independently

### Subflow XML

```xml
<subflows>
    <name>Subflow_Validate_Account</name>
    <flowName>Validate_Account_Data</flowName>   ← API name of the subflow
    <inputAssignments>
        <name>accountName</name>                  ← subflow's isInput=true variable
        <value><elementReference>AccountName_Input</elementReference></value>
    </inputAssignments>
    <outputAssignments>
        <assignToReference>isDuplicate</assignToReference>  ← caller's variable
        <name>isDuplicate</name>                            ← subflow's isOutput=true variable
    </outputAssignments>
</subflows>
```

### Subflow Constraints

- The subflow must be **Active** — you cannot call a Draft or Inactive flow
- The subflow runs **synchronously** in the same transaction as the parent
- Each governor limit (SOQL, DML rows) is shared across the parent and all subflows
- The parent flow **waits** for the subflow to complete before continuing

---

## LWC Flow Screen Components

### Requirements

1. `js-meta.xml` must declare `<target>lightning__FlowScreen</target>`
2. `isExposed: true` — required to appear in the Flow Builder palette
3. `targetConfig` with `role="inputOnly"` — props settable by the Flow canvas

### `availableActions` (Platform-Injected)

```js
@api availableActions = [];  // injected by Flow runtime
// Possible values: 'NEXT', 'BACK', 'FINISH', 'PAUSE'

get canGoNext()   { return this.availableActions.includes('NEXT'); }
get canGoBack()   { return this.availableActions.includes('BACK'); }
get canFinish()   { return this.availableActions.includes('FINISH'); }
```

### Navigation Events

```js
import {
    FlowNavigationNextEvent,
    FlowNavigationBackEvent,
    FlowNavigationFinishEvent,
    FlowAttributeChangeEvent
} from 'lightning/flowSupport';

// Advance to next screen
this.dispatchEvent(new FlowNavigationNextEvent());

// Go back to previous screen
this.dispatchEvent(new FlowNavigationBackEvent());

// Finish the flow
this.dispatchEvent(new FlowNavigationFinishEvent());

// Notify flow of output variable change
this.dispatchEvent(new FlowAttributeChangeEvent('selectedId', newValue));
```

### `@api validate()` — Client-Side Validation

```js
@api validate() {
    const isFormValid = this._checkAllRequiredFields();
    if (!isFormValid) {
        return {
            isValid: false,
            errorMessage: 'Please fill in all required fields.'
        };
    }
    return { isValid: true };
}
```

The Flow runtime calls `validate()` **before** executing the connector out of the screen. Return `{ isValid: false }` to block navigation and display the error message inline.

### `FlowAttributeChangeEvent` — Output Variables

```js
// In js-meta.xml, declare an output prop:
// <property name="selectedAccountId" type="String" role="outputOnly" .../>

// When the user selects an account in the LWC:
handleAccountSelect(event) {
    this._selectedId = event.detail.recordId;
    // Notify the Flow runtime so it updates its variable store
    this.dispatchEvent(
        new FlowAttributeChangeEvent('selectedAccountId', this._selectedId)
    );
}
```

**Without `FlowAttributeChangeEvent`:** The Flow's output variable assignment remains stale — the Flow reads the `@api` prop value as it was when the screen rendered, not the updated value after user interaction.

---

## Flow Error Handling Patterns

### Pattern 1: Fault Path + Error Screen (this day)

```
DML Element ──fault──► Assignment (capture $Flow.FaultMessage)
                              │
                              ▼
                        Error Screen (DisplayText showing error)
                              │
                              ▼
                           [Finish]
```

### Pattern 2: `$Flow.FaultMessage` Merge Field

```xml
<fields>
    <name>Error_Text</name>
    <fieldText><![CDATA[<p>Error: {!flowErrorMessage}</p>]]></fieldText>
    <fieldType>DisplayText</fieldType>
</fields>
```

### Pattern 3: Custom Validation via Invocable Apex

```
Screen → Apex Action (validate) → Decision (isValid?)
                                     ├── false → Error Screen (show errorMessage)
                                     └── true  → Next Screen
```

### Pattern 4: `@api validate()` on LWC (client-side)

```js
@api validate() {
    // Runs before the Flow advances — no server round-trip
    return this._emailIsValid()
        ? { isValid: true }
        : { isValid: false, errorMessage: 'Enter a valid email address.' };
}
```

---

## `Flow.Interview` — Testing Auto-Launched Flows

```apex
// Test pattern for subflows / auto-launched flows
Map<String, Object> inputs = new Map<String, Object>{
    'accountName' => 'Existing Account'
};
Flow.Interview flowInterview = Flow.Interview.createInterview(
    'Validate_Account_Data',  // Flow API name (underscores, not spaces)
    inputs                    // Map of isInput=true variable names → values
);

Test.startTest();
flowInterview.start();
Test.stopTest();

// Read isOutput=true variables
Boolean isDuplicate = (Boolean) flowInterview.getVariableValue('isDuplicate');
```

**Requirements:** Flow must be **Active** in the org. Draft/Inactive flows throw an exception.

**Limitation:** Cannot test Screen Flows this way — `Flow.Interview` cannot interact with screen elements (buttons, inputs). Screen flows with user interaction require manual testing or UI automation.

---

## Interview Questions — Day 13

**Q: What is the difference between `allowFinish=true` and a connector out of a screen?**

`allowFinish=true` shows the Finish button, which terminates the flow interview (runs no further elements). A connector routes to the next element in the flow. On the last screen you set `allowFinish=true` AND the connector routes to record-creation elements — clicking "Next/Finish" triggers the connector, not the Finish button. Use `allowFinish` with no connector to create a true terminal screen (confirmation).

**Q: How does a subflow receive and return data from/to the parent flow?**

Input data: parent uses `<inputAssignments>` in the `<subflows>` element to map parent variable values to the subflow's `isInput=true` variables. Return data: after the subflow finishes, parent uses `<outputAssignments>` to copy the subflow's `isOutput=true` variables into parent variables. The mapping happens at the subflow element — there is no automatic variable sharing.

**Q: When does `FlowAttributeChangeEvent` need to be dispatched vs just updating an `@api` property?**

The Flow runtime reads `@api` output properties only once when the screen's connector fires. If the user changes a value in the LWC component after the screen renders, the Flow's variable store is not updated automatically. `FlowAttributeChangeEvent` tells the Flow runtime "read this property now" — it triggers an immediate sync of the named `@api` property to the Flow variable. Without it, the Flow sees a stale value.

**Q: What are the governor limit implications of calling a subflow that queries records?**

Subflows run in the same transaction as the parent flow. SOQL queries executed in the subflow count against the parent transaction's 100-query limit. If a screen flow loops and calls a subflow that queries on each iteration, you can easily hit governor limits. Design subflows to be bulk-aware: collect all needed data in one Get Records element rather than one per loop iteration.

---

## Files Created (Day 13)

```
force-app/main/default/
├── flows/
│   ├── Account_Onboarding_Wizard.flow-meta.xml   4-screen wizard; subflow call;
│   │                                              choices; ComponentInstance; fault paths
│   └── Validate_Account_Data.flow-meta.xml        Auto-Launched subflow; Get Records;
│                                                  isDuplicate output; fault safe default
├── lwc/flowProgressIndicator/
│   ├── flowProgressIndicator.html                 Step circles with connectors + labels
│   ├── flowProgressIndicator.js                   availableActions; navigation events;
│   │                                              FlowAttributeChangeEvent; @api validate()
│   ├── flowProgressIndicator.css                  Step circle states + connector lines
│   └── flowProgressIndicator.js-meta.xml          lightning__FlowScreen; role=inputOnly props
└── classes/
    ├── FlowActionValidateAccount.cls              @InvocableMethod format validation (5 rules)
    ├── FlowActionValidateAccount.cls-meta.xml
    ├── FlowScreenTest.cls                         15 tests: validation rules; bulk alignment;
    │                                              Flow.Interview subflow; DML chain
    └── FlowScreenTest.cls-meta.xml
scripts/deploy-day-13.sh
docs/day-13.md
```
