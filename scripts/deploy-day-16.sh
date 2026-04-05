#!/usr/bin/env bash
# =============================================================================
# deploy-day-16.sh  —  REST API Integrations, Named Credentials & Auth
# Day 16 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 16 — REST API Integrations, Named Credentials & Auth   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 1. Deploy Named Credentials ─────────────────────────────────────────────
echo ""
echo "▶ Deploying Named Credentials…"
echo "  NOTE: Demo_OAuth_API references Auth Provider 'Demo_OAuth_Provider'."
echo "  Deploy Demo_External_API (NoAuthentication) only in a clean org."
sf project deploy start \
    --source-dir "force-app/main/default/namedCredentials/Demo_External_API.namedCredential-meta.xml" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ Demo_External_API' if r.get('status')==0 else '  ❌ '+r.get('message',''))"

# ─── 2. Deploy Apex classes ───────────────────────────────────────────────────
echo ""
echo "▶ Deploying Apex classes…"
for cls in ExternalApiClient JwtTokenService CalloutMocks RestIntegrationTest; do
    sf project deploy start \
        --source-dir "force-app/main/default/classes/${cls}.cls" \
        --target-org "$ORG_ALIAS" --ignore-conflicts --json | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✅ ${cls}' if r.get('status')==0 else '  ❌ ${cls}: '+r.get('message',''))"
done

# ─── 3. Run Apex tests ────────────────────────────────────────────────────────
echo ""
echo "▶ Running RestIntegrationTest…"
sf apex run test \
    --class-names RestIntegrationTest \
    --target-org "$ORG_ALIAS" \
    --result-format human \
    --wait 10

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 16 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Named Credentials:                                          ║"
echo "║    • Demo_External_API  — NoAuthentication (manual Bearer)  ║"
echo "║    • Demo_OAuth_API     — OAuth 2.0 (reference only)        ║"
echo "║                                                              ║"
echo "║  Apex Classes:                                               ║"
echo "║    • ExternalApiClient  — GET/POST/PATCH/DELETE + retry      ║"
echo "║    • JwtTokenService    — JWT Bearer + Client Credentials    ║"
echo "║    • CalloutMocks       — Single/MultiEndpoint/Sequential    ║"
echo "║    • RestIntegrationTest — 20 tests                          ║"
echo "║                                                              ║"
echo "║  Patterns covered:                                           ║"
echo "║    callout:NC_Name/path • JSON.deserialize typed+untyped     ║"
echo "║    retry 429/5xx • Auth.JWT+JWS signing • isTokenExpiring    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
