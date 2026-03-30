#!/bin/bash
# =============================================================================
# deploy-day-06.sh
# Deploys all Day 6 components: Selector Pattern, Unit of Work Pattern,
# and the AccountOnboardingService integration.
#
# Deploy Order:
#   1. Selector interfaces + concrete implementations
#   2. UnitOfWork interface + implementation
#   3. AccountOnboardingService (depends on selectors + UoW)
#   4. Test class
#
# All Day 5 components (Opportunity custom fields, CMDT) must be deployed
# before this script as OpportunitiesSelector references Discount_Percent__c
# and Final_Price__c.
#
# Prerequisites:
#   sf org login web -a <alias>
#   sf config set target-org <alias>
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=============================================="
echo " Day 06 Deployment — Apex Design Patterns II  "
echo " Selector Layer · Unit of Work Pattern        "
echo "=============================================="

echo ""
echo "Step 1 of 2 — Deploying all Day 6 Apex classes..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes" \
    --wait 30

echo ""
echo "Step 2 of 2 — Running Day 6 test suite..."
sf apex run test \
    --class-names SelectorUoWTest \
    --result-format human \
    --wait 15

echo ""
echo "=============================================="
echo " Deployment complete.                         "
echo "                                              "
echo " Verify via SOQL:                             "
echo "   sf data query \\                           "
echo "     --query \"SELECT Id, Name, Rating,       "
echo "               AnnualRevenue                 "
echo "               FROM Account LIMIT 5\"        "
echo "=============================================="
