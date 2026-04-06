#!/bin/bash
# Day 30 — Agentforce Architecture, Agent Actions & Topics, Prompt Templates
# Deploy AgentforceService, PromptTemplateService, AgentforceTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 30: Agentforce Architecture Deploy ==="

echo ""
echo "--- Deploying AgentforceService + PromptTemplateService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/AgentforceService.cls \
  --source-dir force-app/main/default/classes/AgentforceService.cls-meta.xml \
  --source-dir force-app/main/default/classes/PromptTemplateService.cls \
  --source-dir force-app/main/default/classes/PromptTemplateService.cls-meta.xml \
  --source-dir force-app/main/default/classes/AgentforceTest.cls \
  --source-dir force-app/main/default/classes/AgentforceTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 30 tests ---"
sf apex run test \
  --class-names AgentforceTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 30 deploy complete ==="
echo ""
echo "Agentforce setup steps:"
echo "  1. Setup > Einstein > Einstein Generative AI > Enable"
echo "  2. Setup > Einstein > Prompt Builder > New > create a Flex template"
echo "     - Add merge field: {!\$Input.AccountName}"
echo "     - Publish the template"
echo "  3. Setup > Agents > Einstein Copilot > Open in Agent Builder"
echo "  4. Topics > New Topic:"
echo "     - Name: Account Research"
echo "     - Description: Use when user asks about a customer, account, or company"
echo "     - Instructions: Always return structured data. Use Get Account Summary action."
echo "  5. Add Actions to Topic:"
echo "     - New Action > Apex Action > AgentforceService.getAccountSummary"
echo "     - New Action > Apex Action > AgentforceService.createCase"
echo "  6. Activate the Topic"
echo "  7. Test: Open Copilot > type 'What can you tell me about Acme Corp?'"
echo "  8. Audit log: Setup > Einstein > Generative AI Audit Log"
