#!/bin/bash
# Day 29 — Sales Cloud & CPQ
# Deploy QuoteService, CpqPricingService, SalesCloudTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 29: Sales Cloud & CPQ Deploy ==="

echo ""
echo "--- Deploying QuoteService + CpqPricingService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/QuoteService.cls \
  --source-dir force-app/main/default/classes/QuoteService.cls-meta.xml \
  --source-dir force-app/main/default/classes/CpqPricingService.cls \
  --source-dir force-app/main/default/classes/CpqPricingService.cls-meta.xml \
  --source-dir force-app/main/default/classes/SalesCloudTest.cls \
  --source-dir force-app/main/default/classes/SalesCloudTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 29 tests ---"
sf apex run test \
  --class-names SalesCloudTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 29 deploy complete ==="
echo ""
echo "CPQ setup steps (if SBQQ package installed):"
echo "  1. Setup > Installed Packages > Salesforce CPQ (verify SBQQ namespace)"
echo "  2. CPQ Setup > Pricing > enable 'Price Waterfall' logging for debugging"
echo "  3. Create Discount Schedule: App Launcher > Discount Schedules > New"
echo "     - Add tiers: 1-9 qty = 0%, 10-49 = 5%, 50+ = 10%"
echo "  4. Link Schedule to Product: Product > Discount Schedule lookup"
echo "  5. Create a CPQ Quote: Opportunity > New Quote (CPQ UI)"
echo "  6. Click 'Calculate' to trigger SBQQ.QuoteAPI.calculate()"
echo "  7. Test bundle: create parent product + ProductOptions"
echo "  8. Activate an Order to generate Contract + Subscriptions"
