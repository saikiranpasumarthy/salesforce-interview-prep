#!/bin/bash
# Day 37 — Mock Interview Day 1: Apex + LWC + Triggers
set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 37: Mock Interview Day 1 Deploy ==="

sf project deploy start \
  --source-dir force-app/main/default/classes/MockInterviewApexService.cls \
  --source-dir force-app/main/default/classes/MockInterviewApexService.cls-meta.xml \
  --source-dir force-app/main/default/classes/MockInterviewTest.cls \
  --source-dir force-app/main/default/classes/MockInterviewTest.cls-meta.xml \
  --source-dir force-app/main/default/lwc/accountSearchCard \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 37 tests ---"
sf apex run test \
  --class-names MockInterviewTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 37 deploy complete ==="
echo ""
echo "Note: writeRollupsToAccount requires two custom fields on Account:"
echo "  Total_Won_Opps__c   (Number)"
echo "  Total_Won_Amount__c (Currency)"
echo ""
echo "LWC accountSearchCard can be added to any Record Page or App Page via"
echo "Lightning App Builder. Configure maxRecords and pageSize in the properties panel."
echo ""
echo "Mock interview self-assessment checklist:"
echo "  [ ] Can you explain bulkification without notes? (< 60 seconds)"
echo "  [ ] Can you write a trigger handler framework from memory?"
echo "  [ ] Can you explain LWC lifecycle in order?"
echo "  [ ] Can you distinguish @wire vs imperative in 2 sentences?"
echo "  [ ] Can you name the 5 non-retryable HTTP codes?"
echo "  [ ] Can you recite the order of execution (at least 10 of 17 steps)?"
