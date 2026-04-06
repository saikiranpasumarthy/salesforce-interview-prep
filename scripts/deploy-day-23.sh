#!/bin/bash
# Day 23 — Multi-Org Architecture, Connected Apps & Org Strategy
# Deploy cross-org bridge and topology routing classes + CMDT

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 23: Multi-Org Architecture Deploy ==="

echo ""
echo "--- Deploying Org_Routing_Config__mdt Custom Metadata Type ---"
sf project deploy start \
  --source-dir force-app/main/default/objects/Org_Routing_Config__mdt \
  $ALIAS_FLAG

echo ""
echo "--- Deploying OrgBridgeService, OrgTopologyService, MultiOrgArchitectureTest ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/OrgBridgeService.cls \
  --source-dir force-app/main/default/classes/OrgBridgeService.cls-meta.xml \
  --source-dir force-app/main/default/classes/OrgTopologyService.cls \
  --source-dir force-app/main/default/classes/OrgTopologyService.cls-meta.xml \
  --source-dir force-app/main/default/classes/MultiOrgArchitectureTest.cls \
  --source-dir force-app/main/default/classes/MultiOrgArchitectureTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 23 tests ---"
sf apex run test \
  --class-names MultiOrgArchitectureTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 23 deploy complete ==="
echo ""
echo "Manual post-deploy steps:"
echo "  1. Setup > Named Credentials > New (External Credential type)"
echo "  2. Create Named Credential per spoke org (callout:<NC_Name>)"
echo "  3. Insert Org_Routing_Config__mdt records for each spoke"
echo "  4. Test: OrgTopologyService.syncToTargetOrg('Account', records)"
