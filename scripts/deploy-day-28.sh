#!/bin/bash
# Day 28 — Experience Cloud, CMS & Guest User Security
# Deploy ExperienceCloudService, GuestUserSecurityService, ExperienceCloudTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 28: Experience Cloud Deploy ==="

echo ""
echo "--- Deploying ExperienceCloudService + GuestUserSecurityService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/ExperienceCloudService.cls \
  --source-dir force-app/main/default/classes/ExperienceCloudService.cls-meta.xml \
  --source-dir force-app/main/default/classes/GuestUserSecurityService.cls \
  --source-dir force-app/main/default/classes/GuestUserSecurityService.cls-meta.xml \
  --source-dir force-app/main/default/classes/ExperienceCloudTest.cls \
  --source-dir force-app/main/default/classes/ExperienceCloudTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 28 tests ---"
sf apex run test \
  --class-names ExperienceCloudTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 28 deploy complete ==="
echo ""
echo "Experience Cloud setup steps:"
echo "  1. Setup > Digital Experiences > All Sites > New"
echo "     - Choose template (Customer Service, Partner Central, etc.)"
echo "  2. Assign Customer Community / Partner Community license to users"
echo "  3. Setup > Guest User Profile > review permissions (remove View All Users)"
echo "  4. Setup > Sharing Settings > add Criteria-Based Sharing Rules for guest"
echo "  5. Test guest access: open site in incognito window"
echo "  6. Test: Network.getNetworkId() returns site Id from within Experience Cloud"
