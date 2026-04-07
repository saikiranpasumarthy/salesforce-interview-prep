#!/bin/bash
# Day 33 — Data Cloud Segmentation, Real-Time CDP & Data Cloud + Apex
set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 33: Data Cloud Segmentation & Real-Time CDP Deploy ==="

sf project deploy start \
  --source-dir force-app/main/default/classes/DataCloudSegmentService.cls \
  --source-dir force-app/main/default/classes/DataCloudSegmentService.cls-meta.xml \
  --source-dir force-app/main/default/classes/DataCloudPersonalisationService.cls \
  --source-dir force-app/main/default/classes/DataCloudPersonalisationService.cls-meta.xml \
  --source-dir force-app/main/default/classes/DataCloudAdvancedTest.cls \
  --source-dir force-app/main/default/classes/DataCloudAdvancedTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 33 tests ---"
sf apex run test \
  --class-names DataCloudAdvancedTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 33 deploy complete ==="
echo ""
echo "Data Cloud setup steps (requires Data Cloud license):"
echo ""
echo "1. Waterfall Segmentation:"
echo "   Data Cloud > Segments > New (x4 for Platinum/Gold/Silver/General)"
echo "   Priority 1 - Platinum: LifetimeValue__dlm.TotalLifetimeValue__c >= 50000"
echo "   Priority 2 - Gold:     LifetimeValue__dlm.TotalLifetimeValue__c >= 10000"
echo "   Priority 3 - Silver:   LifetimeValue__dlm.TotalLifetimeValue__c >= 1000"
echo "   Priority 4 - General:  all profiles (no filter)"
echo ""
echo "2. Suppression Segment:"
echo "   Data Cloud > Segments > New > Type: Suppression"
echo "   Filter: Individual__dlm.OptOutEmail__c = true"
echo ""
echo "3. Activation (Marketing Cloud):"
echo "   Data Cloud > Activations > New"
echo "   Target: Marketing Cloud > select Subscriber List"
echo "   Segment: High Value Customers"
echo "   Add suppression: Opted Out segment"
echo ""
echo "4. Data Action (webhook to CRM):"
echo "   Data Cloud > Data Actions > New"
echo "   Trigger: Segment Entry (High Value Customers)"
echo "   Target: Salesforce Connected Org"
echo "   Action: Invoke Flow or POST to custom REST endpoint"
echo ""
echo "5. Streaming Insight:"
echo "   Data Cloud > Calculated Insights > New"
echo "   Compute: Streaming"
echo "   SQL: SELECT UnifiedIndividualId__c, SUM(EngagementScore__c) AS Score__c"
echo "        FROM Engagement__dlm GROUP BY UnifiedIndividualId__c"
