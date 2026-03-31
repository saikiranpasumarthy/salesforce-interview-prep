/**
 * @description accountDashboard — composition root demonstrating how LMS enables
 *              sibling component communication in a multi-column layout.
 *
 *              This component is intentionally thin — its only job is to:
 *                1. Accept accountId from the record page / App Builder
 *                2. Propagate it to all child components
 *
 *              Communication flow on this page:
 *
 *              ┌─────────────────────────────────────────────────────────────────┐
 *              │                     accountDashboard                           │
 *              │  (passes accountId via @api to all children)                   │
 *              │                                                                │
 *              │  ┌────────────────────┐    ┌──────────────────────────────┐   │
 *              │  │ opportunityFilterBar│    │ opportunityMetricsTile       │   │
 *              │  │ [PUBLISHER]         │    │ [SUBSCRIBER]                 │   │
 *              │  │                    │    │ subscribe(OpportunityFilter)  │   │
 *              │  │ publish(            │    │ → imperative Apex call       │   │
 *              │  │  OpportunityFilter) │    │ → updates metrics display    │   │
 *              │  └────────────────────┘    └──────────────────────────────┘   │
 *              │                  │  LMS channel  ↑                            │
 *              │                  └───────────────┘                            │
 *              │                                                                │
 *              │  ┌────────────────────┐    ┌──────────────────────────────┐   │
 *              │  │ accountSummaryCard  │    │ opportunityList               │   │
 *              │  │ @wire getRecord     │    │ @wire Apex (Day 8)           │   │
 *              │  │ → c-opportunity-list│    │ → c-discount-badge           │   │
 *              │  └────────────────────┘    └──────────────────────────────┘   │
 *              └─────────────────────────────────────────────────────────────────┘
 *
 *              refreshApex() pattern (noted here for reference):
 *              After a DML operation in a child component, the @wire cache for
 *              getRecord and getOpportunitiesForAccount becomes stale. The pattern:
 *                1. Store the wire result: @wire(...) wiredResult; (not destructured)
 *                2. After DML: import { refreshApex } from 'lightning/uiRecordApi'
 *                3. Call: await refreshApex(this.wiredResult);
 *              This triggers a fresh server call and updates all components sharing
 *              the same LDS cache key (recordId + fields).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
import { LightningElement, api } from 'lwc';

export default class AccountDashboard extends LightningElement {
    @api accountId;
}
