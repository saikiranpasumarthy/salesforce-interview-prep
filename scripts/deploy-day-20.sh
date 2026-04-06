#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-day-20.sh
# Day 20 — CI/CD: Azure DevOps pipelines, delta deployments, post-deploy verify
# Deploys: DeploymentVerifier, DeploymentVerifierTest
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET_ORG="${1:-}"
if [[ -z "$TARGET_ORG" ]]; then
  echo "Usage: $0 <org-alias>"
  exit 1
fi

echo "==> Deploying Day 20 — CI/CD artifacts to org: $TARGET_ORG"

sf project deploy start \
  --source-dir force-app/main/default/classes/DeploymentVerifier.cls \
  --source-dir force-app/main/default/classes/DeploymentVerifier.cls-meta.xml \
  --source-dir force-app/main/default/classes/DeploymentVerifierTest.cls \
  --source-dir force-app/main/default/classes/DeploymentVerifierTest.cls-meta.xml \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "==> Running Day 20 Apex tests..."
sf apex run test \
  --class-names DeploymentVerifierTest \
  --target-org "$TARGET_ORG" \
  --wait 10 \
  --result-format human

echo ""
echo "==> Running post-deploy verification..."
sf apex run \
  --file scripts/post-deploy-verify.apex \
  --target-org "$TARGET_ORG"

echo ""
echo "==> Day 20 deployment complete."
echo ""
echo "    Pipeline YAML files (Azure DevOps — no deployment needed):"
echo "      .azure-pipelines/ci-validate.yml    — PR validation pipeline"
echo "      .azure-pipelines/cd-deploy.yml      — CD: QA → Staging → Production"
echo "      .azure-pipelines/package-release.yml — Unlocked Package release"
