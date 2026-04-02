#!/usr/bin/env bash
# =============================================================================
# deploy-day-14.sh  —  Security Model: CRUD/FLS, Sharing Keywords, AccountShare
# Day 14 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 14 — Security Model: CRUD/FLS / Sharing / AccountShare ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 1. Deploy Project__c custom object (sharingModel=Private) ───────────────
echo ""
echo "▶ Deploying Project__c custom object…"
sf project deploy start \
    --source-dir "force-app/main/default/objects/Project__c" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Project__c (sharingModel=Private)' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 2. Deploy Apex classes ───────────────────────────────────────────────────
echo ""
echo "▶ Deploying Apex classes…"
for cls in SecurityService AccountSharingService SharingContextDemo SecurityModelTest; do
    sf project deploy start \
        --source-dir "force-app/main/default/classes/${cls}.cls" \
        --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ ${cls}' if r.get('status')==0 else '  ❌ ${cls}: '+r.get('message',''))"
done

# ─── 3. Run Apex tests ────────────────────────────────────────────────────────
echo ""
echo "▶ Running SecurityModelTest…"
sf apex run test \
    --class-names SecurityModelTest \
    --target-org "$ORG_ALIAS" \
    --result-format human \
    --wait 10

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 14 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Apex Classes:                                               ║"
echo "║    • SecurityService        — CRUD/FLS assertion + checks    ║"
echo "║    • AccountSharingService  — grantAccess / revokeAccess     ║"
echo "║    • SharingContextDemo     — with/without/inherited sharing  ║"
echo "║    • SecurityModelTest      — 19 tests                       ║"
echo "║                                                              ║"
echo "║  Custom Object:                                              ║"
echo "║    • Project__c (sharingModel=Private, Status__c picklist)   ║"
echo "║                                                              ║"
echo "║  Security patterns demonstrated:                             ║"
echo "║    • WITH SECURITY_ENFORCED SOQL clause                      ║"
echo "║    • Security.stripInaccessible (graceful FLS)               ║"
echo "║    • AccountShare / Project__Share manual sharing            ║"
echo "║    • Inner without sharing escalation pattern                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
