#!/usr/bin/env bash
# release-latest.sh — Build, notarize, package, and publish Memgram as the rolling 'latest' release.
# Usage: ./scripts/release-latest.sh <apple-id-email> <app-specific-password>
#
# Equivalent to: ./scripts/release.sh <apple-id> <app-password> --latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/release.sh" "$@" --latest
