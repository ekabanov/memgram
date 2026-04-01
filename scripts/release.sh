#!/usr/bin/env bash
# release.sh — Build, notarize, and package Memgram for direct distribution.
# Usage: ./scripts/release.sh <apple-id-email> <app-specific-password> [--latest]
#
# Prerequisites:
#   1. Developer ID Application certificate installed in Keychain
#   2. xcodegen installed (brew install xcodegen)
#   3. create-dmg installed (brew install create-dmg)
#   4. gh CLI installed and authenticated (brew install gh && gh auth login)  [only for --latest]
#
# App-specific password: generate at appleid.apple.com → App-Specific Passwords
# --latest: also publish a rolling Memgram-latest.dmg to the fixed GitHub tag 'latest'

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
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | sed 's/.*: *"//' | tr -d '"')
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/Memgram.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Memgram.app"
DMG_PATH="$BUILD_DIR/Memgram-${VERSION}.dmg"

if [[ -z "$APPLE_ID" || -z "$APP_PASSWORD" ]]; then
    echo "Usage: $0 <apple-id> <app-specific-password>"
    echo "  e.g. $0 you@example.com xxxx-xxxx-xxxx-xxxx"
    exit 1
fi

echo "🔧  Regenerating project..."
xcodegen generate

echo "📦  Archiving (Release)..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild archive \
    -project Memgram.xcodeproj \
    -scheme Memgram \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID"

echo "📤  Exporting with Developer ID..."
cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

echo "🔒  Notarizing..."
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/Memgram-notarize.zip"
xcrun notarytool submit "$BUILD_DIR/Memgram-notarize.zip" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait
rm "$BUILD_DIR/Memgram-notarize.zip"

echo "📎  Stapling..."
xcrun stapler staple "$APP_PATH"

echo "💿  Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
create-dmg \
    --volname "Memgram" \
    --volicon "Memgram/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Memgram.app" 175 190 \
    --hide-extension "Memgram.app" \
    --app-drop-link 425 190 \
    "$DMG_PATH" \
    "$DMG_STAGING" || {
        # Fallback: plain zip if create-dmg not installed or icon missing
        echo "⚠️  create-dmg failed, falling back to zip"
        ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/Memgram-${VERSION}.zip"
        DMG_PATH="$BUILD_DIR/Memgram-${VERSION}.zip"
    }

echo ""
echo "✅  Release artifact: $DMG_PATH"
echo ""

if $PUBLISH_LATEST; then
    LATEST_EXT="${DMG_PATH##*.}"
    LATEST_PATH="$BUILD_DIR/Memgram-latest.$LATEST_EXT"
    cp "$DMG_PATH" "$LATEST_PATH"
    echo "🚀  Publishing rolling latest..."
    gh release delete latest --yes 2>/dev/null || true
    gh release create latest "$LATEST_PATH" \
        --title "Memgram Latest" \
        --notes "Latest build (v${VERSION})" \
        --prerelease
    echo "✅  Latest release updated: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/latest/Memgram-latest.$LATEST_EXT"
else
    echo "Next: create GitHub release with:"
    echo "  gh release create v${VERSION} '$DMG_PATH' --title 'Memgram ${VERSION}' --generate-notes"
fi
