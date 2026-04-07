#!/bin/bash
# Day 39 — Deploy Weak Area Revisit
# Usage: ./scripts/deploy-day-39.sh [target-org-alias]

set -e

TARGET_ORG="${1:-}"

echo "=============================================="
echo " Day 39 — Weak Area Revisit Deployment"
echo "=============================================="

if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <target-org-alias>"
  exit 1
fi

echo "Target org: $TARGET_ORG"
echo ""

echo "→ Deploying Apex classes..."
sf project deploy start \
  --source-dir force-app/main/default/classes/WeakAreaRevisitService.cls \
  --source-dir force-app/main/default/classes/WeakAreaRevisitTest.cls \
  --target-org "$TARGET_ORG" \
  --wait 10

echo "→ Deploying Message Channel..."
sf project deploy start \
  --source-dir "force-app/main/default/messageChannels/RecordSelected__c.messageChannel-meta.xml" \
  --target-org "$TARGET_ORG" \
  --wait 10

echo "→ Deploying LWC..."
sf project deploy start \
  --source-dir force-app/main/default/lwc/notificationPanel \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "→ Running Day 39 tests..."
sf apex run test \
  --class-names WeakAreaRevisitTest \
  --target-org "$TARGET_ORG" \
  --result-format human \
  --wait 10

echo ""
echo "✅ Day 39 deployment complete."
