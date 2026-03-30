#!/bin/bash
# =============================================================================
# deploy-day-07.sh
# Deploys all Day 7 components: MockUnitOfWork, MockSelector, ApexMockFramework,
# TestDataBuilder, AccountHealthService, and TestingPatternsTest.
#
# Note: MockUnitOfWork, MockSelector, TestDataBuilder, and ApexMockFramework
# are production Apex classes (not @IsTest) so they deploy as normal classes.
# This allows them to be used across test classes in the org.
#
# Prerequisites:
#   Days 1–6 must be deployed first (selectors, UoW, onboarding service, CMDT).
#   sf org login web -a <alias>
#   sf config set target-org <alias>
# =============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/force-app"

echo "=============================================="
echo " Day 07 Deployment — Apex Testing Deep Dive   "
echo " Mocks · StubProvider · TestDataBuilder       "
echo "=============================================="

echo ""
echo "Step 1 of 2 — Deploying all Day 7 Apex classes..."
sf project deploy start \
    --source-dir "$SOURCE_DIR/main/default/classes" \
    --wait 30

echo ""
echo "Step 2 of 2 — Running Day 7 test suite..."
sf apex run test \
    --class-names TestingPatternsTest \
    --result-format human \
    --wait 15

echo ""
echo "=============================================="
echo " Deployment complete.                         "
echo "                                              "
echo " Run full suite to confirm no regressions:    "
echo "   sf apex run test --result-format human     "
echo "       --class-names AccountServiceTest       "
echo "       --class-names AsyncApexTest            "
echo "       --class-names DesignPatternTest        "
echo "       --class-names SelectorUoWTest          "
echo "       --class-names TestingPatternsTest      "
echo "       --wait 30                              "
echo "=============================================="
