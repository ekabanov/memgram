#!/usr/bin/env bash
# release-mobile.sh — Build and upload MemgramMobile to App Store Connect.
# Usage: ./scripts/release-mobile.sh <apple-id-email> <app-specific-password> [--latest]
#
# Prerequisites:
#   1. iOS Distribution certificate installed in Keychain
#   2. xcodegen installed (brew install xcodegen)
#   3. Valid App Store provisioning profile (or Automatic signing with correct team)
#   4. gh CLI installed and authenticated (brew install gh && gh auth login)  [only for --latest]
#
# App-specific password: generate at appleid.apple.com → App-Specific Passwords
# --latest: also publish a rolling Memgram-mobile-latest.ipa to the fixed GitHub tag 'mobile-latest'

set -euo pipefail

PUBLISH_LATEST=false
POSITIONAL=()
for arg in "$@"; do
    if [[ "$arg" == "--latest" ]]; then
        PUBLISH_LATEST=true
    else
        POSITIONAL+=("$arg")
    fi
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

APPLE_ID="${1:-}"
APP_PASSWORD="${2:-}"
TEAM_ID="6N57Z7GY37"
VERSION=$(awk '/MemgramMobile:/,0' project.yml | grep 'MARKETING_VERSION' | head -1 | sed 's/.*: *"//' | tr -d '"')
BUILD_DIR="build-mobile"
ARCHIVE_PATH="$BUILD_DIR/MemgramMobile.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
IPA_PATH="$EXPORT_PATH/Memgram.ipa"

if [[ -z "$APPLE_ID" || -z "$APP_PASSWORD" ]]; then
    echo "Usage: $0 <apple-id> <app-specific-password>"
    echo "  e.g. $0 you@example.com xxxx-xxxx-xxxx-xxxx"
    exit 1
fi

echo "🔧  Regenerating project..."
xcodegen generate

echo "📦  Archiving MemgramMobile (Release)..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild archive \
    -project Memgram.xcodeproj \
    -scheme MemgramMobile \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=iOS" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID"

echo "📤  Exporting for App Store Connect..."
cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

echo ""
echo "✅  Build v${VERSION} uploaded to App Store Connect."
echo "    Next: open App Store Connect → TestFlight or submit for review."
echo ""

if $PUBLISH_LATEST; then
    LATEST_PATH="$BUILD_DIR/Memgram-mobile-latest.ipa"
    cp "$IPA_PATH" "$LATEST_PATH"
    echo "🚀  Publishing rolling mobile-latest..."
    gh release delete mobile-latest --yes 2>/dev/null || true
    gh release create mobile-latest "$LATEST_PATH" \
        --title "Memgram Mobile Latest" \
        --notes "Latest mobile build (v${VERSION})" \
        --prerelease
    echo "✅  Latest mobile release updated: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/mobile-latest/Memgram-mobile-latest.ipa"
else
    echo "Next: create GitHub release with:"
    echo "  gh release create mobile-v${VERSION} '$IPA_PATH' --title 'Memgram Mobile ${VERSION}' --generate-notes"
fi
