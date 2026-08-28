#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

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

echo "Application built at: $DIR/build/ClaudeQuota.app"
echo "To install to /Applications:"
echo "  cp -r build/ClaudeQuota.app /Applications/"
echo "To run now:"
echo "  open build/ClaudeQuota.app"

