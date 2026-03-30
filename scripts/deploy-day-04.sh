#!/bin/bash
# =============================================================================
# deploy-day-04.sh
# Deploys all Day 4 components: Big Object, SOQL/SOSL services, and tests.
#
# Deploy Order:
#   1. Case_Archive__b Big Object — must exist before CaseArchiveService compiles
#   2. Apex classes (SoqlQueryService, SoslSearchService, CaseArchiveService)
#   3. Test classes
#
# Note: External Objects require Salesforce Connect license + Named Credentials.
#       External Object metadata is not included here — configure in Setup UI.
#       See docs/day-04.md for External Object architecture overview.
#
# Prerequisites:
#   sf org login web -a <alias>
#   sf config set target-org <alias>
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=========================================="
echo " Day 04 Deployment — SOQL & SOSL Mastery "
echo " Big Objects · Query Optimization         "
echo "=========================================="

echo ""
echo "Step 1 of 3 — Deploying Big Object (Case_Archive__b)..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/objects/Case_Archive__b" \
    --wait 15

echo ""
echo "Step 2 of 3 — Deploying Apex service classes..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes" \
    --wait 30

echo ""
echo "Step 3 of 3 — Running Day 4 test suites..."
sf apex run test \
    --class-names SoqlSoslTest,CaseArchiveServiceTest \
    --result-format human \
    --wait 15

echo ""
echo "=========================================="
echo " Deployment complete.                     "
echo "                                          "
echo " Verify Big Object in org:                "
echo "   sf data query \\                       "
echo "     --query \"SELECT Case_Id__c,         "
echo "              Account_Id__c,              "
echo "              Closed_Date__c              "
echo "              FROM Case_Archive__b        "
echo "              WHERE Account_Id__c != null "
echo "              LIMIT 5\"                   "
echo "=========================================="
