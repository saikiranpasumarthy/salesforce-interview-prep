#!/bin/bash
# Day 36 — End-to-End System Design, Multi-Cloud Architecture, Full Solution
set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 36: System Design & Multi-Cloud Architecture Deploy ==="

sf project deploy start \
  --source-dir force-app/main/default/classes/SystemDesignService.cls \
  --source-dir force-app/main/default/classes/SystemDesignService.cls-meta.xml \
  --source-dir force-app/main/default/classes/MultiCloudOrchestrator.cls \
  --source-dir force-app/main/default/classes/MultiCloudOrchestrator.cls-meta.xml \
  --source-dir force-app/main/default/classes/SystemDesignTest.cls \
  --source-dir force-app/main/default/classes/SystemDesignTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 36 tests ---"
sf apex run test \
  --class-names SystemDesignTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 36 deploy complete ==="
echo ""
echo "Optional setup for full pattern coverage:"
echo ""
echo "1. CrossCloudEvent__e Platform Event:"
echo "   Setup > Platform Events > New"
echo "   - Label: CrossCloud Event, API Name: CrossCloudEvent__e"
echo "   - Fields: EventType__c (Text 255), SourceRecordId__c (Text 18),"
echo "             Payload__c (Long Text), CorrelationId__c (Text 36)"
echo ""
echo "2. IdempotencyKey__c Custom Object:"
echo "   Setup > Object Manager > New Custom Object"
echo "   - Label: Idempotency Key, API Name: IdempotencyKey__c"
echo "   - Fields: Key__c (Text 255, Unique, External Id), ProcessedAt__c (DateTime)"
echo "   - Add Index on Key__c for fast deduplication queries"
echo ""
echo "3. DeadLetterMessage__c Custom Object:"
echo "   Setup > Object Manager > New Custom Object"
echo "   - Label: Dead Letter Message, API Name: DeadLetterMessage__c"
echo "   - Fields: MessageId__c (Text 255), Payload__c (Long Text Area),"
echo "             ErrorMessage__c (Text 1000), AttemptCount__c (Number),"
echo "             Status__c (Picklist: Pending|Reprocessing|Resolved|Abandoned)"
echo ""
echo "4. Circuit Breaker in Production:"
echo "   Store state in Platform Cache (session partition) for persistence:"
echo "   Cache.SessionPartition partition = Cache.Session.getPartition('circuitbreaker');"
echo "   partition.put('PaymentGateway', stateJson, 3600);"
echo ""
echo "5. Retry Queue (DLQ-based backoff):"
echo "   Create Scheduled Apex that runs every 15 minutes:"
echo "   - Query DeadLetterMessage__c WHERE Status='Pending'"
echo "   - Attempt reprocessing based on AttemptCount"
echo "   - Exponential delay enforced via ScheduledDispatchTime comparison"
