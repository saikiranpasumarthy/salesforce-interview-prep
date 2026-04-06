#!/bin/bash
# Day 25 — Security Architecture, Shield & Event Monitoring
# Deploy ShieldEncryptionService, EventMonitoringService, SecurityArchitectureTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 25: Security Architecture Deploy ==="

echo ""
echo "--- Deploying ShieldEncryptionService + EventMonitoringService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/ShieldEncryptionService.cls \
  --source-dir force-app/main/default/classes/ShieldEncryptionService.cls-meta.xml \
  --source-dir force-app/main/default/classes/EventMonitoringService.cls \
  --source-dir force-app/main/default/classes/EventMonitoringService.cls-meta.xml \
  --source-dir force-app/main/default/classes/SecurityArchitectureTest.cls \
  --source-dir force-app/main/default/classes/SecurityArchitectureTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 25 tests ---"
sf apex run test \
  --class-names SecurityArchitectureTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 25 deploy complete ==="
echo ""
echo "Manual verification steps:"
echo "  1. Setup > Security > Health Check — review org baseline score"
echo "  2. Setup > Event Monitoring — allocate retention if add-on available"
echo "  3. Developer Console > Query Editor:"
echo "     SELECT Id, EventType, LogDate FROM EventLogFile ORDER BY LogDate DESC LIMIT 10"
echo "  4. Shield (if licensed): Setup > Platform Encryption > Encryption Policy"
