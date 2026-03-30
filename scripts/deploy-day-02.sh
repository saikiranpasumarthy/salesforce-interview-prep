#!/bin/bash
# =============================================================================
# deploy-day-02.sh
# Deploys all Day 2 components: custom Account field, Batch Apex classes,
# Queueable class, and test class.
#
# Deploy Order:
#   1. Custom field (Total_Closed_Won_Revenue__c) — must exist before Apex compiles
#   2. Apex classes — AccountRatingBatch, OpportunityRollupBatch, AccountSyncQueueable
#   3. Test class — AsyncApexTest
#
# Also redeployes AccountService.cls (applyRatingFromRevenue promoted to public)
#
# Prerequisites:
#   sf org login web -a <alias>
#   sf config set target-org <alias>
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=========================================="
echo " Day 02 Deployment — Async Apex           "
echo " Batch + Stateful + Queueable             "
echo "=========================================="

echo ""
echo "Step 1 of 3 — Deploying custom Account field..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/objects/Account" \
    --wait 10

echo ""
echo "Step 2 of 3 — Deploying updated AccountService + new async Apex classes..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes" \
    --wait 30

echo ""
echo "Step 3 of 3 — Running async Apex test suite..."
sf apex run test \
    --class-names AsyncApexTest \
    --result-format human \
    --wait 10

echo ""
echo "=========================================="
echo " Deployment complete.                     "
echo "                                          "
echo " Launch batch manually (anonymous Apex):  "
echo "   Database.executeBatch(                 "
echo "     new AccountRatingBatch(),            "
echo "     AccountRatingBatch.DEFAULT_SCOPE     "
echo "   );                                     "
echo "=========================================="
