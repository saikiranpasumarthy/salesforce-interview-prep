#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# create-scratch-org.sh
# Day 19 — Complete scratch org setup script
#
# Usage:
#   ./scripts/create-scratch-org.sh <alias> [--full]
#
# Options:
#   --full   Use scratch-def-full.json (Service Cloud, Communities, etc.)
#            Default uses config/project-scratch-def.json
#
# What this script does:
#   1. Create a new scratch org (30-day default expiry)
#   2. Push all source metadata
#   3. Assign the default permission set (if present)
#   4. Import seed data (if config/data/ exists)
#   5. Run all Apex tests
#   6. Open the org in a browser
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ALIAS="${1:-}"
FULL_FLAG="${2:-}"

if [[ -z "$ALIAS" ]]; then
  echo "Usage: $0 <scratch-org-alias> [--full]"
  exit 1
fi

if [[ "$FULL_FLAG" == "--full" ]]; then
  SCRATCH_DEF="config/scratch-def-full.json"
  echo "==> Using full feature scratch definition"
else
  SCRATCH_DEF="config/project-scratch-def.json"
  echo "==> Using standard scratch definition"
fi

echo ""
echo "════════════════════════════════════════════"
echo " Creating scratch org: $ALIAS"
echo " Definition:           $SCRATCH_DEF"
echo "════════════════════════════════════════════"
echo ""

# ── Step 1: Create scratch org ────────────────────────────────────────────
echo "─── [1/5] Creating scratch org..."
sf org create scratch \
  --definition-file "$SCRATCH_DEF" \
  --alias "$ALIAS" \
  --duration-days 30 \
  --set-default \
  --wait 10

# ── Step 2: Push source ───────────────────────────────────────────────────
echo ""
echo "─── [2/5] Pushing source metadata..."
sf project deploy start \
  --source-dir force-app \
  --target-org "$ALIAS" \
  --wait 20

# ── Step 3: Assign permission sets ───────────────────────────────────────
echo ""
echo "─── [3/5] Assigning permission sets..."
# Assign any permission sets that exist in the project
PERM_SETS=$(find force-app -name "*.permissionset-meta.xml" -exec basename {} .permissionset-meta.xml \; 2>/dev/null || true)
if [[ -n "$PERM_SETS" ]]; then
  while IFS= read -r ps; do
    echo "    Assigning: $ps"
    sf org assign permset --name "$ps" --target-org "$ALIAS" 2>/dev/null || \
      echo "    [WARN] Could not assign: $ps (may not apply to this org)"
  done <<< "$PERM_SETS"
else
  echo "    No permission sets found — skipping"
fi

# ── Step 4: Import seed data ──────────────────────────────────────────────
echo ""
echo "─── [4/5] Importing seed data..."
if [[ -d "config/data" ]]; then
  DATA_PLANS=$(find config/data -name "*-plan.json" 2>/dev/null || true)
  if [[ -n "$DATA_PLANS" ]]; then
    while IFS= read -r plan; do
      echo "    Importing plan: $plan"
      sf data import tree --plan "$plan" --target-org "$ALIAS"
    done <<< "$DATA_PLANS"
  else
    echo "    No data plans found in config/data/ — skipping"
  fi
else
  echo "    config/data/ not found — skipping"
fi

# ── Step 5: Run Apex tests ─────────────────────────────────────────────────
echo ""
echo "─── [5/5] Running Apex tests..."
sf apex run test \
  --target-org "$ALIAS" \
  --wait 30 \
  --result-format human \
  --output-dir test-results/ \
  --code-coverage \
  --detailed-coverage

echo ""
echo "════════════════════════════════════════════"
echo " Scratch org setup complete!"
echo " Alias:   $ALIAS"
echo " Command: sf org open --target-org $ALIAS"
echo "════════════════════════════════════════════"
