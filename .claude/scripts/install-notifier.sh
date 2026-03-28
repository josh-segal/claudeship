#!/bin/bash
#
# install-notifier.sh — Builds and installs ClaudeNotifier.app
#
# Run once after cloning to set up native macOS notifications with the Claude icon.
# Requires: swiftc, Claude.app in /Applications
#

set -e

APP="/Applications/ClaudeNotifier.app"
SWIFT_SRC="$(dirname "$0")/../tools/ClaudeNotifier.swift"

echo "Building ClaudeNotifier.app..."

# Create bundle structure
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Write Info.plist
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeNotifier</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudeship.notifier</string>
    <key>CFBundleName</key>
    <string>Claude Notifier</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.14</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Copy Claude icon
if [ -f "/Applications/Claude.app/Contents/Resources/electron.icns" ]; then
  cp "/Applications/Claude.app/Contents/Resources/electron.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "Claude icon copied."
else
  echo "Warning: Claude.app not found, skipping icon."
fi

# Compile Swift binary
swiftc "$SWIFT_SRC" -o "$APP/Contents/MacOS/ClaudeNotifier"
echo "Compiled."

# Ad-hoc sign
codesign --force --deep --sign - "$APP"
echo "Signed."

# Launch once to register with Notification Center
echo "Launching to register with Notification Center..."
open "$APP"
sleep 2

echo ""
echo "Done. Go to System Settings > Notifications > Claude Notifier and enable notifications."
