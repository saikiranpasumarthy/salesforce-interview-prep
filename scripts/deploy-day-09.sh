#!/bin/bash
# =============================================================================
# deploy-day-09.sh
# Deploys Day 9 components: LMS channel, new LWC components, updated Apex controller.
#
# Deploy Order:
#   1. Message Channel (must deploy before LWC that imports it)
#   2. Updated AccountDashboardController (new getOpportunityMetrics method)
#   3. New LWC bundles
#   4. Test class
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=============================================="
echo " Day 09 Deployment — LWC Communication        "
echo " LMS · Wire Adapters · Imperative Apex        "
echo "=============================================="

echo ""
echo "Step 1 of 4 — Deploying Lightning Message Channel..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/messageChannels" \
    --wait 15

echo ""
echo "Step 2 of 4 — Deploying updated Apex controller..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes/AccountDashboardController.cls" \
    --source-dir "$SOURCE_DIR/main/default/classes/AccountDashboardController.cls-meta.xml" \
    --wait 15

echo ""
echo "Step 3 of 4 — Deploying LWC bundles..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/lwc" \
    --wait 30

echo ""
echo "Step 4 of 4 — Running Day 9 test suite..."
sf apex run test \
    --class-names AccountDashboardControllerDay9Test \
    --result-format human \
    --wait 15

echo ""
echo "=============================================="
echo " Deployment complete.                         "
echo "                                              "
echo " Add to a record page in App Builder:         "
echo "   Drag 'Account Dashboard' onto a 2-col page "
echo "   Both filter bar and metrics tile will auto- "
echo "   connect via the LMS channel.               "
echo "=============================================="
