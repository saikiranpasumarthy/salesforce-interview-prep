#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-day-22.sh
# Day 22 — Separation of Concerns, fflib Enterprise Patterns, DI
# Deploys: interfaces, concrete layers, Application factory, tests
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET_ORG="${1:-}"
if [[ -z "$TARGET_ORG" ]]; then
  echo "Usage: $0 <org-alias>"
  exit 1
fi

echo "==> Deploying Day 22 — SoC Architecture to org: $TARGET_ORG"

sf project deploy start \
  --source-dir force-app/main/default/classes/IAccountSelector.cls \
  --source-dir force-app/main/default/classes/IAccountSelector.cls-meta.xml \
  --source-dir force-app/main/default/classes/IAccountDomain.cls \
  --source-dir force-app/main/default/classes/IAccountDomain.cls-meta.xml \
  --source-dir force-app/main/default/classes/IUnitOfWork.cls \
  --source-dir force-app/main/default/classes/IUnitOfWork.cls-meta.xml \
  --source-dir force-app/main/default/classes/AccountSelector.cls \
  --source-dir force-app/main/default/classes/AccountSelector.cls-meta.xml \
  --source-dir force-app/main/default/classes/AccountDomain.cls \
  --source-dir force-app/main/default/classes/AccountDomain.cls-meta.xml \
  --source-dir force-app/main/default/classes/UnitOfWork.cls \
  --source-dir force-app/main/default/classes/UnitOfWork.cls-meta.xml \
  --source-dir force-app/main/default/classes/Application.cls \
  --source-dir force-app/main/default/classes/Application.cls-meta.xml \
  --source-dir force-app/main/default/classes/AccountService.cls \
  --source-dir force-app/main/default/classes/AccountService.cls-meta.xml \
  --source-dir force-app/main/default/classes/SoCArchitectureTest.cls \
  --source-dir force-app/main/default/classes/SoCArchitectureTest.cls-meta.xml \
  --target-org "$TARGET_ORG" \
  --wait 15

echo ""
echo "==> Running Day 22 Apex tests..."
sf apex run test \
  --class-names SoCArchitectureTest \
  --target-org "$TARGET_ORG" \
  --wait 20 \
  --result-format human \
  --code-coverage

echo ""
echo "==> Day 22 deployment complete."
