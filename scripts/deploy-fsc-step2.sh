#!/bin/bash
# Step 2 — Deploy FSC + OmniStudio Wealth Management: Apex Layer
# Usage: ./scripts/deploy-fsc-step2.sh <target-org-alias>

set -e

TARGET_ORG="${1:-}"

echo "=============================================="
echo " FSC Step 2 — Apex Layer Deployment"
echo "=============================================="

if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <target-org-alias>"
  exit 1
fi

echo "Target org: $TARGET_ORG"
echo ""

echo "→ Deploying custom objects and fields..."
sf project deploy start \
  --source-dir fsc-project/force-app/main/default/objects \
  --target-org "$TARGET_ORG" \
  --wait 15

echo ""
echo "→ Deploying Apex classes (framework first)..."
sf project deploy start \
  --source-dir fsc-project/force-app/main/default/classes/TriggerHandler.cls \
  --source-dir fsc-project/force-app/main/default/classes/TriggerHandler.cls-meta.xml \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "→ Deploying service classes..."
sf project deploy start \
  --source-dir fsc-project/force-app/main/default/classes/FinancialAccountService.cls \
  --source-dir fsc-project/force-app/main/default/classes/FinancialAccountTriggerHandler.cls \
  --source-dir fsc-project/force-app/main/default/classes/CreditScoreService.cls \
  --source-dir fsc-project/force-app/main/default/classes/KycValidationService.cls \
  --source-dir fsc-project/force-app/main/default/classes/LoanEligibilityService.cls \
  --source-dir fsc-project/force-app/main/default/classes/LoanEligibilityQueueable.cls \
  --source-dir fsc-project/force-app/main/default/classes/LoanApplicationTriggerHandler.cls \
  --source-dir fsc-project/force-app/main/default/classes/WealthManagementCallable.cls \
  --target-org "$TARGET_ORG" \
  --wait 15

echo ""
echo "→ Deploying triggers..."
sf project deploy start \
  --source-dir fsc-project/force-app/main/default/triggers/FinancialAccountTrigger.trigger \
  --source-dir fsc-project/force-app/main/default/triggers/LoanApplicationTrigger.trigger \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "→ Deploying test classes..."
sf project deploy start \
  --source-dir fsc-project/force-app/main/default/classes/CreditScoreMock.cls \
  --source-dir fsc-project/force-app/main/default/classes/FinancialAccountServiceTest.cls \
  --source-dir fsc-project/force-app/main/default/classes/LoanEligibilityServiceTest.cls \
  --source-dir fsc-project/force-app/main/default/classes/WealthManagementCallableTest.cls \
  --target-org "$TARGET_ORG" \
  --wait 15

echo ""
echo "→ Running Apex tests..."
sf apex run test \
  --class-names FinancialAccountServiceTest \
  --class-names LoanEligibilityServiceTest \
  --class-names WealthManagementCallableTest \
  --target-org "$TARGET_ORG" \
  --result-format human \
  --wait 20

echo ""
echo "✅ Step 2 — Apex Layer deployment complete."
echo ""
echo "Classes deployed:"
echo "  TriggerHandler (abstract base)"
echo "  FinancialAccountTriggerHandler, FinancialAccountService"
echo "  LoanApplicationTriggerHandler, LoanEligibilityService, LoanEligibilityQueueable"
echo "  CreditScoreService, KycValidationService"
echo "  WealthManagementCallable (Callable interface)"
echo ""
echo "Triggers deployed:"
echo "  FinancialAccountTrigger, LoanApplicationTrigger"
echo ""
echo "Test coverage targets:"
echo "  FinancialAccountService      → 90%+ (18 tests)"
echo "  LoanEligibilityService       → 90%+ (16 tests)"
echo "  WealthManagementCallable     → 85%+ (16 tests)"
