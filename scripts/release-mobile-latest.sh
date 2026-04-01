#!/usr/bin/env bash
# release-mobile-latest.sh — Build, upload to App Store Connect, and publish rolling 'mobile-latest' GitHub release.
# Usage: ./scripts/release-mobile-latest.sh <apple-id-email> <app-specific-password>
#
# Equivalent to: ./scripts/release-mobile.sh <apple-id> <app-password> --latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/release-mobile.sh" "$@" --latest
