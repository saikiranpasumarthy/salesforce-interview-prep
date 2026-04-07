#!/bin/bash
# Day 38 — Deploy Mock Interview Day 2: Clouds + DevOps + Design
# Usage: ./scripts/deploy-day-38.sh [target-org-alias]

set -e

TARGET_ORG="${1:-}"
CLASSES=(
  "MockInterviewCloudsService"
  "MockInterviewDevOpsService"
  "MockInterviewDay2Test"
)

echo "=============================================="
echo " Day 38 — Mock Interview Day 2 Deployment"
echo "=============================================="

if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <target-org-alias>"
  echo "Example: $0 my-scratch-org"
  exit 1
fi

echo ""
echo "Target org : $TARGET_ORG"
echo "Components : ${#CLASSES[@]} Apex classes"
echo ""

# Build source path list
SOURCE_PATHS=""
for cls in "${CLASSES[@]}"; do
  SOURCE_PATHS="$SOURCE_PATHS force-app/main/default/classes/${cls}.cls"
done

echo "→ Deploying Apex classes..."
sf project deploy start \
  --source-dir force-app/main/default/classes/MockInterviewCloudsService.cls \
  --source-dir force-app/main/default/classes/MockInterviewDevOpsService.cls \
  --source-dir force-app/main/default/classes/MockInterviewDay2Test.cls \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "→ Running Day 38 tests..."
sf apex run test \
  --class-names MockInterviewDay2Test \
  --target-org "$TARGET_ORG" \
  --result-format human \
  --wait 10

echo ""
echo "✅ Day 38 deployment complete."
