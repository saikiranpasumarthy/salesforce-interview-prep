#!/bin/bash
# Day 31 — Agentforce Deep Dive: Autonomous Agents, RAG & Einstein Copilot
# Deploy AgentConversationService, EinsteinCopilotService, AgentforceDeepDiveTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 31: Agentforce Deep Dive Deploy ==="

echo ""
echo "--- Deploying AgentConversationService + EinsteinCopilotService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/AgentConversationService.cls \
  --source-dir force-app/main/default/classes/AgentConversationService.cls-meta.xml \
  --source-dir force-app/main/default/classes/EinsteinCopilotService.cls \
  --source-dir force-app/main/default/classes/EinsteinCopilotService.cls-meta.xml \
  --source-dir force-app/main/default/classes/AgentforceDeepDiveTest.cls \
  --source-dir force-app/main/default/classes/AgentforceDeepDiveTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 31 tests ---"
sf apex run test \
  --class-names AgentforceDeepDiveTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 31 deploy complete ==="
echo ""
echo "Agentforce Deep Dive setup steps:"
echo ""
echo "Autonomous Agent (event-triggered):"
echo "  1. Create Platform Event: Setup > Platform Events > New"
echo "  2. Create trigger on event: trigger CaseEventTrigger on Case_Event__e (after insert)"
echo "  3. Map event fields to AgentConversationService inputs"
echo "  4. Test: publish event via Developer Console or Workbench"
echo ""
echo "RAG setup:"
echo "  1. Setup > Einstein > Prompt Builder > New Flex Template"
echo "  2. Add merge field: {!\$Input.ContextText}"
echo "  3. Prompt: 'Using the context below, answer: {!\$Input.UserQuestion}\n{!\$Input.ContextText}'"
echo "  4. Chain: RetrieveRagContext action → template invocation"
echo ""
echo "Omni-Channel escalation:"
echo "  1. Setup > Omni-Channel > Routing Configurations > New"
echo "  2. Setup > Omni-Channel > Queues > assign routing config"
echo "  3. Map EscalationInput.escalationQueue to queue DeveloperName"
echo "  4. Test: trigger escalateToHuman → verify Case appears in Omni-Channel console"
