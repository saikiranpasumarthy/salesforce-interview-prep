#!/bin/bash
# Day 40 — Deploy Advanced Scenarios & Cross-Cloud Architecture
# Usage: ./scripts/deploy-day-40.sh [target-org-alias]

set -e

TARGET_ORG="${1:-}"

echo "=============================================="
echo " Day 40 — Advanced Scenarios Deployment"
echo "=============================================="

if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <target-org-alias>"
  exit 1
fi

echo "Target org: $TARGET_ORG"
echo ""

echo "→ Deploying Apex classes..."
sf project deploy start \
  --source-dir force-app/main/default/classes/AdvancedScenariosService.cls \
  --source-dir force-app/main/default/classes/CrossCloudArchitectureService.cls \
  --source-dir force-app/main/default/classes/AdvancedScenariosTest.cls \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "→ Running Day 40 tests..."
sf apex run test \
  --class-names AdvancedScenariosTest \
  --target-org "$TARGET_ORG" \
  --result-format human \
  --wait 10

echo ""
echo "✅ Day 40 deployment complete."
