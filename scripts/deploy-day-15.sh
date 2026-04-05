#!/usr/bin/env bash
# =============================================================================
# deploy-day-15.sh  —  Admin Fundamentals: Object Model, Validation Rules,
#                      Reports API & Audit Trail
# Day 15 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 15 — Object Model / Validation / Reports / Audit Trail ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 1. Deploy Project__c parent (must exist before Project_Task__c) ─────────
echo ""
echo "▶ Deploying Project__c (parent object — needed by master-detail)…"
sf project deploy start \
    --source-dir "force-app/main/default/objects/Project__c" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Project__c' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 2. Deploy Project_Task__c (child object with fields + validation rules) ─
echo ""
echo "▶ Deploying Project_Task__c (master-detail child + validation rules)…"
sf project deploy start \
    --source-dir "force-app/main/default/objects/Project_Task__c" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Project_Task__c + validation rules' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 3. Deploy Apex classes ───────────────────────────────────────────────────
echo ""
echo "▶ Deploying Apex classes…"
for cls in MetadataInspector ReportService AuditService AdminFundamentalsTest; do
    sf project deploy start \
        --source-dir "force-app/main/default/classes/${cls}.cls" \
        --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ ${cls}' if r.get('status')==0 else '  ❌ ${cls}: '+r.get('message',''))"
done

# ─── 4. Run Apex tests ────────────────────────────────────────────────────────
echo ""
echo "▶ Running AdminFundamentalsTest…"
sf apex run test \
    --class-names AdminFundamentalsTest \
    --target-org "$ORG_ALIAS" \
    --result-format human \
    --wait 10

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 15 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Custom Object:                                              ║"
echo "║    • Project_Task__c (Master-Detail → Project__c)            ║"
echo "║      Fields: Priority__c, Due_Date__c, Effort_Days__c,       ║"
echo "║              Is_Blocked__c, Completion_Pct__c                ║"
echo "║      Validation Rules (3):                                   ║"
echo "║        – High_Priority_Requires_Due_Date                     ║"
echo "║        – Effort_Days_Valid_Range (1-365)                     ║"
echo "║        – Due_Date_Cannot_Be_Past (ISNEW guard)               ║"
echo "║                                                              ║"
echo "║  Apex Classes:                                               ║"
echo "║    • MetadataInspector  — Schema.describe + picklist + rels  ║"
echo "║    • ReportService      — Analytics API (sync + async)       ║"
echo "║    • AuditService       — SetupAuditTrail + FieldHistory     ║"
echo "║    • AdminFundamentalsTest — 22 tests                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
