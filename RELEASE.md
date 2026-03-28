# Releasing Memgram

## Prerequisites

- Paid Apple Developer account
- **Developer ID Application** certificate installed in Keychain
  - Xcode → Settings → Accounts → select account → Manage Certificates → **+** → Developer ID Application
- `create-dmg` for a polished DMG (optional — falls back to zip):
  ```bash
  brew install create-dmg
  ```
- An **app-specific password** for notarization:
  - appleid.apple.com → Sign-In and Security → App-Specific Passwords → Generate

## Release Steps

### 1. Bump version

In `project.yml`, update:
```yaml
MARKETING_VERSION: "0.x.0"
CURRENT_PROJECT_VERSION: "N"
```

Then regenerate the project:
```bash
xcodegen generate
```

### 2. Run the release script

```bash
./scripts/release.sh your@apple.id xxxx-xxxx-xxxx-xxxx
```

The script will:
1. Regenerate the Xcode project
2. Archive (Release configuration)
3. Export signed with Developer ID Application
4. Notarize with Apple
5. Staple the notarization ticket
6. Create a DMG (or zip fallback)

Output: `build/Memgram-<version>.dmg`

### 3. Create the GitHub release

```bash
gh release create v0.1.0 build/Memgram-0.1.0.dmg \
  --title "Memgram 0.1.0" \
  --notes "Release notes here."
```

Or use `--generate-notes` to auto-generate from commit messages.

## Team IDs

| Certificate | Team ID |
|-------------|---------|
| Apple Development | B8G987H9G7 |
| Developer ID Application | 6N57Z7GY37 |

The release script uses `6N57Z7GY37` (Developer ID).

## Troubleshooting

**"No profiles for 'com.memgram.app' were found"** — The Developer ID Application **provisioning profile** is missing. Go to [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles), create a **Developer ID** profile for `com.memgram.app`, download and double-click to install. Then in Xcode: Settings → Accounts → your team → Download Manual Profiles.

**"No signing certificate found"** — Make sure the Developer ID Application certificate is installed and the team ID in `project.yml` matches.

**Notarization rejected** — Check `xcrun notarytool log <submission-id>` for details. Common causes: missing Hardened Runtime, unsigned frameworks, or entitlement issues.

**Stapler fails** — Notarization may still be in progress. Wait a minute and retry: `xcrun stapler staple build/export/Memgram.app`
