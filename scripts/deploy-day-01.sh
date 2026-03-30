#!/bin/bash
# =============================================================================
# deploy-day-01.sh
# Deploys all Day 1 components: Custom Metadata Type, CMDT records,
# Apex classes, and trigger.
#
# Prerequisites:
#   - sf CLI authenticated: sf org login web -a <alias>
#   - Default org set:      sf config set target-org <alias>
#
# Usage:
#   chmod +x scripts/deploy-day-01.sh
#   ./scripts/deploy-day-01.sh
# =============================================================================

set -e  # exit immediately on any command failure

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=========================================="
echo " Day 01 Deployment — Apex Triggers +     "
echo " Trigger Framework + Custom Metadata      "
echo "=========================================="

echo ""
echo "Step 1 of 4 — Deploying Custom Metadata Type (Account_Rating_Config__mdt)..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/objects/Account_Rating_Config__mdt" \
    --wait 10

echo ""
echo "Step 2 of 4 — Deploying Custom Metadata Records (Hot / Warm / Cold)..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/customMetadata" \
    --wait 10

echo ""
echo "Step 3 of 4 — Deploying Apex Classes..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes" \
    --wait 30

echo ""
echo "Step 4 of 4 — Deploying Apex Trigger..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/triggers" \
    --wait 10

echo ""
echo "=========================================="
echo " Deployment complete.                     "
echo "                                          "
echo " Run tests:                               "
echo "   sf apex run test \\                    "
echo "     --class-names AccountServiceTest \\  "
echo "     --result-format human                "
echo "=========================================="
