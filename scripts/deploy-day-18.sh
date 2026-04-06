#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-day-18.sh
# Day 18 — Platform Events & CDC
# Deploys: Integration_Event__e, PlatformEventService, CdcEventHandler,
#          both triggers, and PlatformEventTest
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET_ORG="${1:-}"
if [[ -z "$TARGET_ORG" ]]; then
  echo "Usage: $0 <org-alias>"
  exit 1
fi

echo "==> Deploying Day 18 — Platform Events & CDC to org: $TARGET_ORG"

sf project deploy start \
  --source-dir force-app/main/default/objects/Integration_Event__e \
  --source-dir force-app/main/default/classes/PlatformEventService.cls \
  --source-dir force-app/main/default/classes/PlatformEventService.cls-meta.xml \
  --source-dir force-app/main/default/classes/CdcEventHandler.cls \
  --source-dir force-app/main/default/classes/CdcEventHandler.cls-meta.xml \
  --source-dir force-app/main/default/triggers/IntegrationEventTrigger.trigger \
  --source-dir force-app/main/default/triggers/IntegrationEventTrigger.trigger-meta.xml \
  --source-dir force-app/main/default/triggers/AccountChangeTrigger.trigger \
  --source-dir force-app/main/default/triggers/AccountChangeTrigger.trigger-meta.xml \
  --source-dir force-app/main/default/classes/PlatformEventTest.cls \
  --source-dir force-app/main/default/classes/PlatformEventTest.cls-meta.xml \
  --target-org "$TARGET_ORG" \
  --wait 10

echo ""
echo "==> Running Day 18 Apex tests..."
sf apex run test \
  --class-names PlatformEventTest \
  --target-org "$TARGET_ORG" \
  --wait 10 \
  --result-format human

echo ""
echo "==> Day 18 deployment complete."
echo ""
echo "    NOTE: CDC tests (cdcTrigger_*) require Account CDC enabled in the org:"
echo "    Setup → Integrations → Change Data Capture → select Account"
