#!/usr/bin/env bash
# =============================================================================
# deploy-day-13.sh  —  Screen Flows, Subflows & LWC Flow Components
# Day 13 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 13 — Screen Flows, Subflows & LWC Flow Components      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 1. Deploy LWC flow screen component ─────────────────────────────────────
echo ""
echo "▶ Deploying flowProgressIndicator LWC…"
sf project deploy start \
    --source-dir "force-app/main/default/lwc/flowProgressIndicator" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ flowProgressIndicator' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 2. Deploy Apex classes ───────────────────────────────────────────────────
echo ""
echo "▶ Deploying Apex classes…"
for cls in FlowActionValidateAccount FlowScreenTest; do
    sf project deploy start \
        --source-dir "force-app/main/default/classes/${cls}.cls" \
        --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ ${cls}' if r.get('status')==0 else '  ❌ ${cls}: '+r.get('message',''))"
done

# ─── 3. Deploy subflow first (wizard depends on it) ──────────────────────────
echo ""
echo "▶ Deploying subflow (Validate_Account_Data)…"
sf project deploy start \
    --source-dir "force-app/main/default/flows/Validate_Account_Data.flow-meta.xml" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Validate_Account_Data' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 4. Deploy wizard screen flow ────────────────────────────────────────────
echo ""
echo "▶ Deploying Account_Onboarding_Wizard screen flow…"
sf project deploy start \
    --source-dir "force-app/main/default/flows/Account_Onboarding_Wizard.flow-meta.xml" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Account_Onboarding_Wizard' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 5. Run Apex tests ────────────────────────────────────────────────────────
echo ""
echo "▶ Running FlowScreenTest…"
sf apex run test \
    --class-names FlowScreenTest \
    --target-org "$ORG_ALIAS" \
    --result-format human \
    --wait 5

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 13 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Flows:                                                      ║"
echo "║    • Validate_Account_Data   — Auto-Launched subflow         ║"
echo "║    • Account_Onboarding_Wizard — 3-step Screen Flow          ║"
echo "║                                                              ║"
echo "║  LWC: flowProgressIndicator (lightning__FlowScreen target)   ║"
echo "║  Apex: FlowActionValidateAccount + FlowScreenTest (15 tests) ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
