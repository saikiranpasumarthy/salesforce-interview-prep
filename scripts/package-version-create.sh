#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# package-version-create.sh
# Day 19 — Unlocked Package version creation + installation
#
# Usage:
#   Create a beta version (no install key):
#     ./scripts/package-version-create.sh
#
#   Create a released version (with install key):
#     ./scripts/package-version-create.sh --release --key "MyInstallKey123"
#
#   Install the latest version into a target org:
#     ./scripts/package-version-create.sh --install <version-alias-or-04t-id> <target-org>
#
# Prerequisites:
#   • Package must be registered:
#       sf package create --name "salesforce-interview-prep" \
#         --package-type Unlocked --no-namespace --target-dev-hub <hub>
#   • Update sfdx-project.json packageAliases with the returned 0Ho ID
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MODE="${1:-create}"
DEV_HUB="${DEV_HUB:-}"  # set via env or pass --target-dev-hub inline

# ── Create a new package version ──────────────────────────────────────────
create_version() {
  local RELEASE_FLAG="${1:-}"
  local INSTALL_KEY="${2:-}"

  if [[ -z "$DEV_HUB" ]]; then
    echo "ERROR: Set DEV_HUB env var to your Dev Hub alias."
    echo "  export DEV_HUB=my-dev-hub"
    exit 1
  fi

  echo "==> Creating package version..."
  echo "    Package: salesforce-interview-prep"
  echo "    Release: ${RELEASE_FLAG:-beta}"

  local CMD="sf package version create \
    --package salesforce-interview-prep \
    --definition-file config/project-scratch-def.json \
    --target-dev-hub $DEV_HUB \
    --code-coverage \
    --wait 30"

  if [[ "$RELEASE_FLAG" == "--release" ]]; then
    CMD="$CMD --release"
  fi

  if [[ -n "$INSTALL_KEY" ]]; then
    CMD="$CMD --installation-key $INSTALL_KEY"
  else
    CMD="$CMD --installation-key-bypass"
  fi

  eval "$CMD"

  echo ""
  echo "==> Version created. List all versions:"
  echo "    sf package version list --package salesforce-interview-prep --target-dev-hub $DEV_HUB"
}

# ── Install a package version ──────────────────────────────────────────────
install_version() {
  local VERSION_ID="${1:-}"
  local TARGET_ORG="${2:-}"

  if [[ -z "$VERSION_ID" || -z "$TARGET_ORG" ]]; then
    echo "Usage: $0 --install <04t-version-id-or-alias> <target-org>"
    exit 1
  fi

  echo "==> Installing package version: $VERSION_ID into org: $TARGET_ORG"

  sf package install \
    --package "$VERSION_ID" \
    --target-org "$TARGET_ORG" \
    --wait 10 \
    --publish-wait 10 \
    --security-type AllUsers \
    --upgrade-type DeprecateOnly

  echo ""
  echo "==> Installation complete."
  echo "    Verify: sf package installed list --target-org $TARGET_ORG"
}

# ── Promote a beta version to released ────────────────────────────────────
promote_version() {
  local VERSION_ID="${1:-}"

  if [[ -z "$VERSION_ID" ]]; then
    echo "Usage: $0 --promote <04t-version-id>"
    exit 1
  fi

  echo "==> Promoting version $VERSION_ID to released..."
  echo "    WARNING: Released versions cannot be deleted."
  echo "    Press Ctrl+C within 5 seconds to cancel..."
  sleep 5

  sf package version promote \
    --package "$VERSION_ID" \
    --target-dev-hub "$DEV_HUB"

  echo "==> Version promoted."
}

# ── Route based on mode ────────────────────────────────────────────────────
case "$MODE" in
  "--release") create_version "--release" "${2:-}" ;;
  "--install") install_version "${2:-}" "${3:-}" ;;
  "--promote") promote_version "${2:-}" ;;
  "create"|"--create"|*)
    create_version "" ""
    ;;
esac
