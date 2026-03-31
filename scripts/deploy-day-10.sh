#!/usr/bin/env bash
# =============================================================================
# deploy-day-10.sh  —  LWC Advanced: NavigationMixin, Lazy Loading, Virtual List
# Day 10 of the 41-Day Salesforce Interview Prep System
# =============================================================================
set -euo pipefail

ORG_ALIAS="${1:-dev}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 10 — LWC Advanced Patterns                             ║"
echo "║  NavigationMixin · Lazy Loading · Virtual Scrolling         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── 1. Validate org connection ──────────────────────────────────────────────
echo "▶ Validating org connection: $ORG_ALIAS"
sf org display --target-org "$ORG_ALIAS" --json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('  Connected:', d['result']['username'])"

# ─── 2. Deploy LWC components ────────────────────────────────────────────────
echo ""
echo "▶ Deploying LWC components (Day 10)…"

LWC_COMPONENTS=(
    "force-app/main/default/lwc/opportunityDetailPage"
    "force-app/main/default/lwc/lazyLoadContainer"
    "force-app/main/default/lwc/virtualList"
)

for component in "${LWC_COMPONENTS[@]}"; do
    echo "  ↳ $component"
    sf project deploy start \
        --source-dir "$component" \
        --target-org "$ORG_ALIAS" \
        --ignore-conflicts \
        --json | python3 -c "
import sys, json
r = json.load(sys.stdin)
if r.get('status') == 0:
    print('    ✅ Deployed successfully')
else:
    print('    ❌ Deploy failed:', r.get('message','unknown'))
    sys.exit(1)
"
done

# ─── 3. Verify deploy ────────────────────────────────────────────────────────
echo ""
echo "▶ Verifying deployed components…"
sf project deploy report --target-org "$ORG_ALIAS" 2>/dev/null || true

# ─── 4. Open component in org ────────────────────────────────────────────────
echo ""
echo "▶ Opening org to verify components…"
sf org open --target-org "$ORG_ALIAS" --path "/lightning/setup/LightningComponentBundles/home"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Day 10 deploy complete ✅                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Components deployed:                                        ║"
echo "║    • opportunityDetailPage — NavigationMixin showcase        ║"
echo "║    • lazyLoadContainer     — IntersectionObserver lazy load  ║"
echo "║    • virtualList           — rAF-throttled virtual scroll    ║"
echo "║                                                              ║"
echo "║  Key concepts covered:                                       ║"
echo "║    • NavigationMixin.Navigate() + GenerateUrl()              ║"
echo "║    • PageReference types: recordPage / objectPage /          ║"
echo "║      namedPage / webPage                                     ║"
echo "║    • URL state (c__ namespace) + CurrentPageReference @wire  ║"
echo "║    • IntersectionObserver + lwc:ref for deferred render      ║"
echo "║    • Virtual scrolling: startIndex / spacer / rAF pattern    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
