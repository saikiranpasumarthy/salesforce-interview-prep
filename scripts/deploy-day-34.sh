#!/bin/bash
# Day 34 — Einstein Features & AI in Apex, Prediction Builder, AI-Powered Flows
set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 34: Einstein Features & AI in Apex Deploy ==="

sf project deploy start \
  --source-dir force-app/main/default/classes/EinsteinPredictionService.cls \
  --source-dir force-app/main/default/classes/EinsteinPredictionService.cls-meta.xml \
  --source-dir force-app/main/default/classes/EinsteinFlowService.cls \
  --source-dir force-app/main/default/classes/EinsteinFlowService.cls-meta.xml \
  --source-dir force-app/main/default/classes/EinsteinAITest.cls \
  --source-dir force-app/main/default/classes/EinsteinAITest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 34 tests ---"
sf apex run test \
  --class-names EinsteinAITest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 34 deploy complete ==="
echo ""
echo "Einstein setup steps (requires Einstein licences):"
echo ""
echo "1. Prediction Builder:"
echo "   Setup > Einstein > Prediction Builder > New Prediction"
echo "   - Object: Account"
echo "   - Predict: custom field Churn_Risk__c (Boolean)"
echo "   - Score field: Churn_Risk_Score__c (auto-created, Decimal 0-100)"
echo "   - Schedule: Daily refresh at off-peak hours"
echo ""
echo "2. Einstein Opportunity Scoring:"
echo "   Setup > Einstein > Opportunity Scoring > Enable"
echo "   - Automatically provisions OpportunityScore sObject"
echo "   - Score + ScoreCategory + Trend visible on Opportunity record"
echo ""
echo "3. Einstein Lead Scoring:"
echo "   Setup > Einstein > Lead Scoring > Enable"
echo "   - Automatically provisions LeadScore sObject"
echo ""
echo "4. Einstein Language Named Credential:"
echo "   Setup > Named Credentials > New"
echo "   - Name: Einstein_Language"
echo "   - URL: https://api.einstein.ai"
echo "   - Auth: OAuth 2.0 JWT Bearer (private key + connected app)"
echo ""
echo "5. Next Best Action Strategy:"
echo "   Setup > Next Best Action > Strategies > New"
echo "   - Name: Account_NBA_Strategy"
echo "   - Object: Account"
echo "   - Build in Flow Builder: Load > Filter > Boost > Limit"
echo ""
echo "6. Flow Actions in use (EinsteinFlowService):"
echo "   - 'Predict Churn Risk'     — reads Prediction Builder field"
echo "   - 'Get Einstein Lead Score' — reads LeadScore object"
echo "   - 'Classify Email Intent'  — callout=true, Einstein Language API"
echo "   - 'Get Next Best Actions'  — ConnectApi.Recommendations"
echo "   - 'Analyse Sentiment'      — callout=true, Einstein Language API"
