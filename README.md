# Salesforce Interview Prep — Saikiran Pasumarthy

Senior Salesforce Developer | 9+ Years | Architect-Track Preparation
**Target:** Senior Developer / Tech Lead / Architect roles

---

## 🗺 Study Progress

| Day | Topics | Phase | Status | Files |
|-----|--------|-------|--------|-------|
| 1 | Apex Triggers, Trigger Frameworks, Governor Limits | Phase 1 | ✅ Done | [Day 1 →](docs/day-01.md) |
| 2 | Async Apex: Batch & Queueable, Chaining & Chunking, Stateful Batch | Phase 1 | ⬜ Pending | — |
| 3 | Async Apex: Future & Scheduled, Platform Events intro, Async Error Handling | Phase 1 | ⬜ Pending | — |
| 4 | SOQL & SOSL Mastery, Query Optimization, Big Objects & External Objects | Phase 1 | ⬜ Pending | — |
| 5 | Apex Design Patterns I, Separation of Concerns, Factory & Strategy | Phase 1 | ⬜ Pending | — |
| 6 | Apex Design Patterns II, Selector Layer, Unit of Work Pattern | Phase 1 | ⬜ Pending | — |
| 7 | Apex Testing Deep Dive, TestDataFactory, Mocking & Stubs | Phase 1 | ⬜ Pending | — |
| 8 | LWC Architecture, Component Lifecycle, Shadow DOM & Rendering | Phase 1 | ⬜ Pending | — |
| 9 | LWC Communication Patterns, Wire Adapters, Custom Events vs PubSub | Phase 1 | ⬜ Pending | — |
| 10 | LWC Advanced, Navigation & Page Reference, LWC Performance | Phase 1 | ⬜ Pending | — |
| 11 | LWC Testing (Jest), LWC with Apex, LWC Accessibility | Phase 1 | ⬜ Pending | — |
| 12 | Flows: Record-Triggered & Auto, Flow Best Practices, Flow vs Apex | Phase 1 | ⬜ Pending | — |
| 13 | Flows: Screen Flows & Subflows, Dynamic Forms, Flow Error Handling | Phase 1 | ⬜ Pending | — |
| 14 | Security Model Deep Dive, Sharing Rules, OWD, Apex Sharing | Phase 1 | ⬜ Pending | — |
| 15 | Admin: Object Model & Validation, Reports & Dashboards, Audit Trail | Phase 1 | ⬜ Pending | — |
| 16 | REST API Integrations, Named Credentials & Auth, External Services | Phase 2 | ⬜ Pending | — |
| 17 | SOAP & Callout Patterns, Outbound Messaging, Callouts from Async | Phase 2 | ⬜ Pending | — |
| 18 | Platform Events Deep Dive, CDC, Pub/Sub API | Phase 2 | ⬜ Pending | — |
| 19 | DevOps: sf CLI & Scratch Orgs, Unlocked Packages, Manifest Deployments | Phase 2 | ⬜ Pending | — |
| 20 | CI/CD with Azure DevOps, Delta Deployments, Automated Test Execution | Phase 2 | ⬜ Pending | — |
| 21 | Metadata API & Tooling API, SFDX Project Structure, Environment Strategy | Phase 2 | ⬜ Pending | — |
| 22 | Separation of Concerns (Architecture), fflib Enterprise Patterns, DI | Phase 2 | ⬜ Pending | — |
| 23 | Multi-Org Architecture, Connected Apps, Org Strategy & Tenancy | Phase 2 | ⬜ Pending | — |
| 24 | Performance Tuning & Scalability, Large Data Volumes, Skinny Tables | Phase 2 | ⬜ Pending | — |
| 25 | Security Architecture, OAuth Flows, Shield & Event Monitoring | Phase 2 | ⬜ Pending | — |
| 26 | Service Cloud Deep Dive, Case Management, Entitlements & Milestones | Phase 3 | ⬜ Pending | — |
| 27 | Field Service Lightning, Work Orders & Scheduling, Mobile LWC for FSL | Phase 3 | ⬜ Pending | — |
| 28 | Experience Cloud, CMS & Personalization, Guest User Security | Phase 3 | ⬜ Pending | — |
| 29 | Sales Cloud & CPQ (Conga), Quote-to-Cash Lifecycle, Pricing & Approvals | Phase 3 | ⬜ Pending | — |
| 30 | Agentforce Architecture, Agent Actions & Topics, Prompt Templates | Phase 3 | ⬜ Pending | — |
| 31 | Agentforce Deep Dive, Custom Actions via Apex, Einstein Copilot | Phase 3 | ⬜ Pending | — |
| 32 | Data Cloud Architecture, Data Streams & Ingestion, Unified Profiles | Phase 3 | ⬜ Pending | — |
| 33 | Data Cloud Segmentation, Real-Time CDP, Data Cloud + Apex | Phase 3 | ⬜ Pending | — |
| 34 | Einstein Features & AI in Apex, Prediction Builder, AI-Powered Flows | Phase 3 | ⬜ Pending | — |
| 35 | Industry Clouds Overview, OmniStudio Basics, FlexCards | Phase 3 | ⬜ Pending | — |
| 36 | End-to-End System Design, Multi-Cloud Architecture, Full Solution | Phase 3 | ⬜ Pending | — |
| 37 | Mock Interview Day 1 — Apex + LWC + Triggers | Phase 3 | ⬜ Pending | — |
| 38 | Mock Interview Day 2 — Clouds + DevOps + Design | Phase 3 | ⬜ Pending | — |
| 39 | Weak Area Revisit (based on Mock Interview gaps) | Phase 3 | ⬜ Pending | — |
| 40 | Advanced Scenarios, Cross-Cloud Architecture, Offer Negotiation Prep | Phase 3 | ⬜ Pending | — |
| 41 | Jitterbit Deep Dive | Final | ⬜ Pending | — |

---

## 📁 Repository Structure

```
salesforce-interview-prep/
├── README.md                          ← Master index (updated after each day)
├── docs/                              ← Interview notebook — one .md per day
├── force-app/
│   └── main/
│       └── default/
│           ├── classes/               ← Apex: service, handler, domain, selector, test
│           ├── triggers/              ← One trigger per object (routing only)
│           ├── lwc/                   ← LWC components
│           ├── objects/               ← Custom fields, metadata
│           └── customMetadata/        ← Custom Metadata records
└── scripts/                           ← Deploy scripts per day
```

---

## 🚀 Deploy All

```bash
sf project deploy start --source-dir force-app
```

## 🔧 Tech Stack

Apex · LWC · Service Cloud · FSL · Experience Cloud · CPQ (Conga) · Agentforce · Data Cloud
REST APIs · Azure DevOps · sf CLI · Oracle Fusion · SAP · Epicor
