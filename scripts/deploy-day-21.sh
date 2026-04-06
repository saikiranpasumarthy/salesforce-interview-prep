#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-day-21.sh
# Day 21 — Metadata API, Tooling API, SFDX Project Structure, Environment Strategy
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET_ORG="${1:-}"
if [[ -z "$TARGET_ORG" ]]; then
  echo "Usage: $0 <org-alias>"
  exit 1
fi

echo "==> Deploying Day 21 — Metadata/Tooling API artifacts to org: $TARGET_ORG"

sf project deploy start \
  --source-dir force-app/main/default/objects/Environment_Config__mdt \
  --source-dir force-app/main/default/classes/MetadataApiService.cls \
  --source-dir force-app/main/default/classes/MetadataApiService.cls-meta.xml \
  --source-dir force-app/main/default/classes/EnvironmentService.cls \
  --source-dir force-app/main/default/classes/EnvironmentService.cls-meta.xml \
  --source-dir force-app/main/default/classes/MetadataApiServiceTest.cls \
  --source-dir force-app/main/default/classes/MetadataApiServiceTest.cls-meta.xml \
  --target-org "$TARGET_ORG" \
  --wait 15

echo ""
echo "==> Running Day 21 Apex tests..."
sf apex run test \
  --class-names MetadataApiServiceTest \
  --target-org "$TARGET_ORG" \
  --wait 15 \
  --result-format human

echo ""
echo "==> Day 21 deployment complete."
echo ""
echo "    NOTE: MetadataApiService callout tests require Remote Site Settings:"
echo "    Setup → Security → Remote Site Settings → Add your org domain URL"
echo "    OR use a Named Credential 'Salesforce_Org_Self' pointing to your org."
