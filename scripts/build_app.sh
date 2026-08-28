#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

./scripts/generate_credentials.sh

echo "Building release binary..."
swift build -c release

APP_DIR="build/ClaudeQuota.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp .build/release/ClaudeQuota "$APP_DIR/Contents/MacOS/ClaudeQuota"

cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeQuota</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.quota.widget</string>
    <key>CFBundleName</key>
    <string>ClaudeQuota</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

BUNDLE_ID="com.claude.quota.widget"

# Ad-hoc sign with a fixed identity-only designated requirement (no cert chain, no cdhash).
# Without this, every rebuild produces an unsigned/differently-hashed binary that macOS
# Keychain treats as a brand-new app, re-prompting for "Always Allow" on every launch even
# though it's the same app. Pinning the requirement to just the bundle identifier makes the
# Keychain ACL survive rebuilds — the tradeoff is that any locally ad-hoc-signed binary
# claiming this same identifier would also pass, which is an acceptable risk for a personal
# dev machine but would not be for distributing this app to other people.
codesign --force --sign - \
    --identifier "$BUNDLE_ID" \
    -r='designated => identifier "'"$BUNDLE_ID"'"' \
    "$APP_DIR"

echo "Application built at: $DIR/build/ClaudeQuota.app"
echo "To install to /Applications:"
echo "  cp -r build/ClaudeQuota.app /Applications/"
echo "To run now:"
echo "  open build/ClaudeQuota.app"

