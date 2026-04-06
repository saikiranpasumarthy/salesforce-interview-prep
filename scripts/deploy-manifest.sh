#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-manifest.sh
# Day 19 — Manifest-based (package.xml) deployment
#
# Usage:
#   Deploy everything:
#     ./scripts/deploy-manifest.sh <target-org>
#
#   Validate only (dry run — no changes deployed):
#     ./scripts/deploy-manifest.sh <target-org> --validate
#
#   Deploy with test level:
#     ./scripts/deploy-manifest.sh <target-org> --tests RunLocalTests
#
# Manifest: manifest/package.xml
#
# NOTE: Manifest deployments are the MDAPI-style approach.
#   For source-format deployments use: sf project deploy start --source-dir
#   For delta deployments: use sfdx-git-delta to generate a delta manifest
#     npx sfdx-git-delta --from <prev-tag> --to HEAD --output delta/
#     sf project deploy start --manifest delta/package/package.xml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET_ORG="${1:-}"
MODE="${2:-deploy}"
TEST_LEVEL="${3:-RunLocalTests}"

if [[ -z "$TARGET_ORG" ]]; then
  echo "Usage: $0 <org-alias> [--validate] [RunLocalTests|RunAllTestsInOrg|RunSpecifiedTests]"
  exit 1
fi

if [[ "$MODE" == "--validate" ]]; then
  echo "==> Validating manifest deployment (dry run) against: $TARGET_ORG"
  DEPLOY_FLAGS="--dry-run"
else
  echo "==> Deploying manifest to: $TARGET_ORG"
  DEPLOY_FLAGS=""
fi

echo "    Manifest:   manifest/package.xml"
echo "    Test level: $TEST_LEVEL"
echo ""

sf project deploy start \
  --manifest manifest/package.xml \
  --target-org "$TARGET_ORG" \
  --test-level "$TEST_LEVEL" \
  --wait 30 \
  $DEPLOY_FLAGS

echo ""
echo "==> Deployment complete."
