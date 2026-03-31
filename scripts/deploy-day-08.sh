#!/bin/bash
# =============================================================================
# deploy-day-08.sh
# Deploys all Day 8 components: LWC components + AccountDashboardController.
#
# Deploy Order:
#   1. Apex controller (AccountDashboardController) — LWC depends on it
#   2. LWC bundles (accountSummaryCard, opportunityList, discountBadge)
#   3. Apex test
#
# Prerequisites:
#   Days 1–7 deployed (Opportunity custom fields, CMDT, TestDataBuilder, etc.)
#   sf org login web -a <alias>
#   sf config set target-org <alias>
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=============================================="
echo " Day 08 Deployment — LWC Architecture         "
echo " Lifecycle · Shadow DOM · Wire · Events       "
echo "=============================================="

echo ""
echo "Step 1 of 3 — Deploying Apex controller..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes/AccountDashboardController.cls" \
    --source-dir "$SOURCE_DIR/main/default/classes/AccountDashboardController.cls-meta.xml" \
    --wait 15

echo ""
echo "Step 2 of 3 — Deploying LWC bundles..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/lwc" \
    --wait 20

echo ""
echo "Step 3 of 3 — Running Apex tests..."
sf apex run test \
    --class-names AccountDashboardControllerTest \
    --result-format human \
    --wait 15

echo ""
echo "=============================================="
echo " Deployment complete.                         "
echo "                                              "
echo " Assign to a record page in App Builder:      "
echo "   Setup → App Builder → Account Record Page  "
echo "   → Drag 'Account Summary Card' onto page    "
echo "=============================================="
