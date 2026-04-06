#!/bin/bash
# Day 26 — Service Cloud: Case Management, Entitlements & Milestones
# Deploy CaseManagementService, EntitlementService, ServiceCloudTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 26: Service Cloud Deploy ==="

echo ""
echo "--- Deploying CaseManagementService + EntitlementService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/CaseManagementService.cls \
  --source-dir force-app/main/default/classes/CaseManagementService.cls-meta.xml \
  --source-dir force-app/main/default/classes/EntitlementService.cls \
  --source-dir force-app/main/default/classes/EntitlementService.cls-meta.xml \
  --source-dir force-app/main/default/classes/ServiceCloudTest.cls \
  --source-dir force-app/main/default/classes/ServiceCloudTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 26 tests ---"
sf apex run test \
  --class-names ServiceCloudTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 26 deploy complete ==="
echo ""
echo "Manual setup steps for full SLA testing:"
echo "  1. Setup > Entitlements > Entitlement Processes > New"
echo "     - Add MilestoneType: 'First Response' (2 BH), 'Resolution' (8 BH)"
echo "  2. Setup > Entitlements > Milestones > New MilestoneType records"
echo "  3. Create Entitlement record linked to Account + SlaProcess"
echo "  4. Set Case.EntitlementId → CaseMilestones auto-created"
echo "  5. Verify: SELECT Id, IsViolated, TargetDate FROM CaseMilestone WHERE CaseId = :id"
