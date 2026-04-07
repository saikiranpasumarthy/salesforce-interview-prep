#!/bin/bash
# Day 32 — Data Cloud Architecture, Data Streams & Ingestion, Unified Profiles
# Deploy DataCloudIngestionService, DataCloudProfileService, DataCloudTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 32: Data Cloud Architecture Deploy ==="

echo ""
echo "--- Deploying DataCloudIngestionService + DataCloudProfileService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/DataCloudIngestionService.cls \
  --source-dir force-app/main/default/classes/DataCloudIngestionService.cls-meta.xml \
  --source-dir force-app/main/default/classes/DataCloudProfileService.cls \
  --source-dir force-app/main/default/classes/DataCloudProfileService.cls-meta.xml \
  --source-dir force-app/main/default/classes/DataCloudTest.cls \
  --source-dir force-app/main/default/classes/DataCloudTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 32 tests ---"
sf apex run test \
  --class-names DataCloudTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 32 deploy complete ==="
echo ""
echo "Data Cloud setup steps (requires Data Cloud license):"
echo ""
echo "1. Streaming Ingestion:"
echo "   - Data Cloud Setup > Ingestion API > New Source"
echo "   - Name: CRM_Source  (DeveloperName used in Apex)"
echo "   - Upload JSON schema for Account__dlm"
echo "   - Create Named Credential: DataCloud_Org"
echo "     URL: https://{tenant}.c360a.salesforce.com"
echo "     Auth: OAuth 2.0 (Data Cloud Connected App)"
echo ""
echo "2. CRM Connector:"
echo "   - Data Cloud Setup > Salesforce CRM > Connect"
echo "   - Select objects: Account, Contact, Lead, Opportunity"
echo "   - Configure field mappings to DMOs"
echo ""
echo "3. Identity Resolution:"
echo "   - Data Cloud > Identity Resolution > New Ruleset"
echo "   - Add match rule: ContactPointEmail__dlm.EmailAddress__c (exact)"
echo "   - Add reconciliation rule: Most Recent Value"
echo "   - Run ruleset"
echo ""
echo "4. Calculated Insight:"
echo "   - Data Cloud > Calculated Insights > New"
echo "   - SQL: SELECT UnifiedIndividualId__c, SUM(GrandTotalAmount__c) AS TotalLifetimeValue__c"
echo "     FROM SalesOrder__dlm GROUP BY UnifiedIndividualId__c"
echo "   - Name: LifetimeValue"
echo "   - Schedule: Daily"
echo ""
echo "5. Segment:"
echo "   - Data Cloud > Segments > New"
echo "   - Filter: LifetimeValue__dlm.TotalLifetimeValue__c > 10000"
echo "   - Schedule: Hourly refresh"
echo "   - Activate to Marketing Cloud"
