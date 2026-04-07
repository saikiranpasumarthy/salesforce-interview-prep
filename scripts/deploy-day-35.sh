#!/bin/bash
# Day 35 — Industry Clouds Overview, OmniStudio Basics, FlexCards
set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 35: Industry Clouds & OmniStudio Deploy ==="

sf project deploy start \
  --source-dir force-app/main/default/classes/OmniStudioService.cls \
  --source-dir force-app/main/default/classes/OmniStudioService.cls-meta.xml \
  --source-dir force-app/main/default/classes/IndustryCloudService.cls \
  --source-dir force-app/main/default/classes/IndustryCloudService.cls-meta.xml \
  --source-dir force-app/main/default/classes/IndustryCloudTest.cls \
  --source-dir force-app/main/default/classes/IndustryCloudTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 35 tests ---"
sf apex run test \
  --class-names IndustryCloudTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 35 deploy complete ==="
echo ""
echo "OmniStudio setup steps:"
echo ""
echo "1. Install OmniStudio managed package:"
echo "   AppExchange > OmniStudio (formerly Vlocity OmniStudio)"
echo "   Or enable via: Setup > OmniStudio Settings > Enable OmniStudio"
echo ""
echo "2. Integration Procedure:"
echo "   OmniStudio > Integration Procedures > New"
echo "   - Type: Account, Name: GetFinancialSummary"
echo "   - Key format: Account_GetFinancialSummary"
echo "   - Add elements: DataRaptor Extract, HTTP Action, Set Values"
echo ""
echo "3. DataRaptor:"
echo "   OmniStudio > DataRaptors > New"
echo "   - Name: AccountExtract, Type: TurboExtract"
echo "   - Object: Account, fields, filters"
echo ""
echo "4. FlexCard:"
echo "   OmniStudio > FlexCards > New"
echo "   - Data source: Integration Procedure > Account_GetFinancialSummary"
echo "   - Add elements: Text, Field, Conditional block, Action button"
echo ""
echo "5. FSC setup (requires Financial Services Cloud licence):"
echo "   Setup > Industries > Financial Services Cloud > Enable"
echo "   - Household RecordType: IndustriesHousehold (Account)"
echo "   - Individual RecordType: IndustriesIndividual (Contact)"
echo "   - FinancialAccount__c auto-provisioned"
echo "   - RecordAlert__c auto-provisioned"
echo ""
echo "6. Health Cloud setup (requires Health Cloud licence):"
echo "   Setup > Industries > Health Cloud > Enable"
echo "   - CareProgram, CareProgramEnrollee, CarePlanActivity auto-provisioned"
echo ""
echo "Callout testing (OmniStudio IP):"
echo "  OmniStudioService.useMock = true"
echo "  OmniStudioService.mockIpResult = new Map<String, Object>{ 'success' => true };"
echo "  OR just run: IndustryCloudTest — all tests mock OmniStudio/FSC/Health Cloud"
