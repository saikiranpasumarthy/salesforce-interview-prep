#!/bin/bash
# =============================================================================
# deploy-day-05.sh
# Deploys all Day 5 components: Strategy Pattern, Factory Pattern,
# Separation of Concerns, and the Opportunity pricing pipeline.
#
# Deploy Order:
#   1. Custom Metadata Type (Discount_Strategy_Config__mdt) + fields
#   2. Opportunity custom fields (Discount_Percent__c, Final_Price__c)
#   3. Custom Metadata records (Existing Business, New Business, Partner)
#   4. Apex classes (interface + strategies + factory + domain + service + handler)
#   5. Test class
#
# Prerequisites:
#   sf org login web -a <alias>
#   sf config set target-org <alias>
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=============================================="
echo " Day 05 Deployment — Apex Design Patterns     "
echo " Strategy · Factory · Separation of Concerns  "
echo "=============================================="

echo ""
echo "Step 1 of 5 — Deploying Discount_Strategy_Config__mdt CMDT object..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/objects/Discount_Strategy_Config__mdt" \
    --wait 15

echo ""
echo "Step 2 of 5 — Deploying Opportunity custom fields..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/objects/Opportunity" \
    --wait 15

echo ""
echo "Step 3 of 5 — Deploying CMDT records..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/customMetadata" \
    --wait 15

echo ""
echo "Step 4 of 5 — Deploying Apex classes and trigger..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes" \
    --source-dir "$SOURCE_DIR/main/default/triggers" \
    --wait 30

echo ""
echo "Step 5 of 5 — Running Day 5 test suite..."
sf apex run test \
    --class-names DesignPatternTest \
    --result-format human \
    --wait 15

echo ""
echo "=============================================="
echo " Deployment complete.                         "
echo "                                              "
echo " Verify pricing in org:                       "
echo "   sf data query \\                           "
echo "     --query \"SELECT Name, Amount,           "
echo "              Discount_Percent__c,            "
echo "              Final_Price__c                  "
echo "              FROM Opportunity                "
echo "              LIMIT 5\"                       "
echo "=============================================="
