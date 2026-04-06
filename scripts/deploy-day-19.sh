#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-day-19.sh
# Day 19 — DevOps: sf CLI, Scratch Orgs, Unlocked Packages, Manifest Deployments
# Deploys: OrgConfigService, OrgConfigServiceTest
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET_ORG="${1:-}"
if [[ -z "$TARGET_ORG" ]]; then
  echo "Usage: $0 <org-alias>"
  exit 1
fi

echo "==> Deploying Day 19 — DevOps artifacts to org: $TARGET_ORG"

sf project deploy start \
  --source-dir force-app/main/default/classes/OrgConfigService.cls \
  --source-dir force-app/main/default/classes/OrgConfigService.cls-meta.xml \
  --source-dir force-app/main/default/classes/OrgConfigServiceTest.cls \
  --source-dir force-app/main/default/classes/OrgConfigServiceTest.cls-meta.xml \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "==> Running Day 19 Apex tests..."
sf apex run test \
  --class-names OrgConfigServiceTest \
  --target-org "$TARGET_ORG" \
  --wait 10 \
  --result-format human

echo ""
echo "==> Day 19 deployment complete."
echo ""
echo "    Other Day 19 artifacts (no deployment needed — reference material):"
echo "      sfdx-project.json          — unlocked package configuration"
echo "      config/project-scratch-def.json  — standard scratch definition"
echo "      config/scratch-def-full.json     — full-feature scratch definition"
echo "      manifest/package.xml             — full deployment manifest"
echo "      scripts/create-scratch-org.sh    — scratch org setup script"
echo "      scripts/package-version-create.sh — unlocked package version workflow"
echo "      scripts/deploy-manifest.sh       — manifest-based deployment"
