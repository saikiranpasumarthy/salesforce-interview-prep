#!/bin/bash
# Day 24 — Performance Tuning & Large Data Volumes
# Deploy LdvQueryService, PlatformCacheService, PerformanceTuningTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 24: Performance Tuning & LDV Deploy ==="

echo ""
echo "--- Deploying LdvQueryService + PlatformCacheService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/LdvQueryService.cls \
  --source-dir force-app/main/default/classes/LdvQueryService.cls-meta.xml \
  --source-dir force-app/main/default/classes/PlatformCacheService.cls \
  --source-dir force-app/main/default/classes/PlatformCacheService.cls-meta.xml \
  --source-dir force-app/main/default/classes/PerformanceTuningTest.cls \
  --source-dir force-app/main/default/classes/PerformanceTuningTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 24 tests ---"
sf apex run test \
  --class-names PerformanceTuningTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 24 deploy complete ==="
echo ""
echo "Performance verification steps:"
echo "  1. Developer Console → Query Editor → Enter large SOQL → Query Plan"
echo "     Look for 'Index' vs 'TableScan' as leading operation"
echo "  2. Setup → Platform Cache → Allocate cache to 'OrgCache' partition"
echo "     (required for real Cache.Org calls; tests use useMock=true)"
echo "  3. For Skinny Tables: raise Salesforce Support case with object + field list"
