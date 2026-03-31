#!/usr/bin/env bash
# =============================================================================
# deploy-day-11.sh  —  LWC Jest Testing & Accessibility
# Day 11 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 11 — LWC Testing (Jest) & Accessibility (ARIA)         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── 1. Run Jest tests ────────────────────────────────────────────────────────
echo "▶ Running LWC Jest test suite…"
npm run test:unit:coverage 2>&1 | tail -40
echo ""

# ─── 2. Validate org connection ──────────────────────────────────────────────
echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 3. Deploy accessibleDataTable LWC ───────────────────────────────────────
echo ""
echo "▶ Deploying new LWC component…"
sf project deploy start \
    --source-dir "force-app/main/default/lwc/accessibleDataTable" \
    --target-org "$ORG_ALIAS" \
    --ignore-conflicts \
    --json | python3 -c "
import sys, json
r = json.load(sys.stdin)
if r.get('status') == 0:
    print('    ✅ accessibleDataTable deployed successfully')
else:
    print('    ❌ Deploy failed:', r.get('message','unknown'))
    sys.exit(1)
"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 11 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Test files:                                                 ║"
echo "║    • discountBadge/__tests__        — leaf component tests   ║"
echo "║    • accountSummaryCard/__tests__   — LDS + Apex wire mocks  ║"
echo "║    • opportunityFilterBar/__tests__ — LMS publish spy        ║"
echo "║    • opportunityMetricsTile/__tests__— imperative Apex mock  ║"
echo "║    • accessibleDataTable/__tests__  — ARIA + keyboard nav    ║"
echo "║                                                              ║"
echo "║  Key concepts:                                               ║"
echo "║    • registerLdsTestWireAdapter / registerApexTestWireAdapter║"
echo "║    • adapter.emit() / adapter.error()                        ║"
echo "║    • jest.mock for imperative Apex & LMS                     ║"
echo "║    • Roving tabindex; aria-sort; aria-live                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
