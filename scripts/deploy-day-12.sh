#!/usr/bin/env bash
# =============================================================================
# deploy-day-12.sh  —  Flows: Record-Triggered, Auto-Launched & Invocable Apex
# Day 12 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 12 — Flows & Invocable Apex                            ║"
echo "║  Record-Triggered · Auto-Launched · Flow vs Apex            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── 1. Validate org connection ──────────────────────────────────────────────
echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 2. Deploy custom fields first (flows depend on them) ─────────────────────
echo ""
echo "▶ Deploying custom fields…"
sf project deploy start \
    --source-dir "force-app/main/default/objects/Account/fields/Account_Score__c.field-meta.xml" \
    --source-dir "force-app/main/default/objects/Account/fields/Account_Tier__c.field-meta.xml" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Fields deployed' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 3. Deploy Invocable Apex ─────────────────────────────────────────────────
echo ""
echo "▶ Deploying Invocable Apex classes…"
for cls in FlowActionCalculateScore FlowActionSendNotification FlowActionTest; do
    sf project deploy start \
        --source-dir "force-app/main/default/classes/${cls}.cls" \
        --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ ${cls}' if r.get('status')==0 else '  ❌ ${cls}: '+r.get('message',''))"
done

# ─── 4. Deploy Flows ──────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying Flows…"
for flow in Account_Rating_Update Opportunity_Won_Tasks Account_Score_Calculator; do
    sf project deploy start \
        --source-dir "force-app/main/default/flows/${flow}.flow-meta.xml" \
        --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ ${flow}' if r.get('status')==0 else '  ❌ ${flow}: '+r.get('message',''))"
done

# ─── 5. Run Apex tests ────────────────────────────────────────────────────────
echo ""
echo "▶ Running FlowActionTest…"
sf apex run test \
    --class-names FlowActionTest \
    --target-org "$ORG_ALIAS" \
    --result-format human \
    --wait 5

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 12 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Flows deployed:                                             ║"
echo "║    • Account_Rating_Update    — Before Save, entry condition ║"
echo "║    • Opportunity_Won_Tasks    — After Save, fault paths      ║"
echo "║    • Account_Score_Calculator — Auto-Launched, Apex action   ║"
echo "║                                                              ║"
echo "║  Invocable Apex:                                             ║"
echo "║    • FlowActionCalculateScore — bulk-safe, input/output vars ║"
echo "║    • FlowActionSendNotification — void return, Custom Notif  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
