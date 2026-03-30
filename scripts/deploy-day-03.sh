#!/bin/bash
# =============================================================================
# deploy-day-03.sh
# Deploys all Day 3 components in dependency order:
#   1. Platform Event (Integration_Error_Log__e) — must exist before trigger compiles
#   2. Custom Object  (Integration_Error_Log__c)  — must exist before trigger compiles
#   3. Apex classes   (IntegrationErrorLogger, Schedulers, AccountFutureService)
#   4. Updated handler (AccountTriggerHandler — adds afterInsert)
#   5. Platform Event subscriber trigger
#   6. Test classes
#
# After deployment, schedule jobs via anonymous Apex:
#   AccountRatingScheduler.scheduleMe();
#   OpportunityRollupScheduler.scheduleMe();
#
# Prerequisites:
#   sf org login web -a <alias>
#   sf config set target-org <alias>
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "============================================"
echo " Day 03 Deployment — @future · Schedulers  "
echo " Platform Events · Async Error Handling     "
echo "============================================"

echo ""
echo "Step 1 of 5 — Deploying Platform Event (Integration_Error_Log__e)..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/objects/Integration_Error_Log__e" \
    --wait 15

echo ""
echo "Step 2 of 5 — Deploying Custom Object (Integration_Error_Log__c)..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/objects/Integration_Error_Log__c" \
    --wait 15

echo ""
echo "Step 3 of 5 — Deploying Apex classes (new + updated)..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes" \
    --wait 30

echo ""
echo "Step 4 of 5 — Deploying triggers (IntegrationErrorLogTrigger + updated AccountTrigger)..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/triggers" \
    --wait 15

echo ""
echo "Step 5 of 5 — Running Day 3 test suites..."
sf apex run test \
    --class-names ScheduledApexTest,IntegrationErrorLoggerTest \
    --result-format human \
    --wait 15

echo ""
echo "============================================"
echo " Deployment complete.                       "
echo "                                            "
echo " Activate scheduled jobs (anonymous Apex):  "
echo "   AccountRatingScheduler.scheduleMe();     "
echo "   OpportunityRollupScheduler.scheduleMe(); "
echo "                                            "
echo " Verify schedule:                           "
echo "   SELECT Id, CronJobDetail.Name,           "
echo "          CronExpression, State             "
echo "   FROM CronTrigger                         "
echo "   WHERE State = 'WAITING'                  "
echo "============================================"
