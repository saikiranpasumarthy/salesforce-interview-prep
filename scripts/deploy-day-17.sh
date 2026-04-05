#!/usr/bin/env bash
# =============================================================================
# deploy-day-17.sh  —  SOAP Callouts, Outbound Messaging & Async Callout Patterns
# Day 17 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 17 — SOAP Callouts, Outbound Messaging & Async         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 1. Deploy Account custom fields ─────────────────────────────────────────
echo ""
echo "▶ Deploying Account custom fields (Sync_Status__c, Sync_Error__c)…"
sf project deploy start \
    --source-dir "force-app/main/default/objects/Account/fields/Sync_Status__c.field-meta.xml" \
    --source-dir "force-app/main/default/objects/Account/fields/Sync_Error__c.field-meta.xml" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Account fields' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 2. Deploy Apex classes ───────────────────────────────────────────────────
echo ""
echo "▶ Deploying Apex classes…"
for cls in SoapApiService AsyncCalloutService OutboundMessageHandler CalloutAsyncTest; do
    sf project deploy start \
        --source-dir "force-app/main/default/classes/${cls}.cls" \
        --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ ${cls}' if r.get('status')==0 else '  ❌ ${cls}: '+r.get('message',''))"
done

# ─── 3. Run Apex tests ────────────────────────────────────────────────────────
echo ""
echo "▶ Running CalloutAsyncTest…"
sf apex run test \
    --class-names CalloutAsyncTest \
    --target-org "$ORG_ALIAS" \
    --result-format human \
    --wait 10

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 17 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Account fields: Sync_Status__c (picklist) · Sync_Error__c  ║"
echo "║                                                              ║"
echo "║  Apex Classes:                                               ║"
echo "║    • SoapApiService        — envelope build + DOM parse      ║"
echo "║    • AsyncCalloutService   — @future / Queueable / Batch     ║"
echo "║    • OutboundMessageHandler — REST endpoint for SOAP OM      ║"
echo "║    • CalloutAsyncTest      — 18 tests                        ║"
echo "║                                                              ║"
echo "║  Patterns covered:                                           ║"
echo "║    Raw SOAP envelope · WS-Security · Dom.Document parsing    ║"
echo "║    @future(callout=true) · Queueable+AllowsCallouts          ║"
echo "║    Batch+AllowsCallouts · Queueable-from-finish()            ║"
echo "║    Outbound Message ACK response · idempotency key           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
