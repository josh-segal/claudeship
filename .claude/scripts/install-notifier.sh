#!/bin/bash
#
# install-notifier.sh — Builds and installs ClaudeNotifier as a persistent daemon
#
# Run once after cloning (and after any changes to ClaudeNotifier.swift).
# Requires: swiftc, Claude.app in /Applications
#

set -e

APP="/Applications/ClaudeNotifier.app"
SWIFT_SRC="$(dirname "$0")/../tools/ClaudeNotifier.swift"
PLIST="$HOME/Library/LaunchAgents/com.claudeship.notifier.plist"
LABEL="com.claudeship.notifier"
DOMAIN="gui/$(id -u)"

echo "Building ClaudeNotifier.app..."

# ── App bundle structure ──────────────────────────────────────────────────────
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

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
    <string>12.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# ── Claude icon ───────────────────────────────────────────────────────────────
if [ -f "/Applications/Claude.app/Contents/Resources/electron.icns" ]; then
  cp "/Applications/Claude.app/Contents/Resources/electron.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "Claude icon copied."
else
  echo "Warning: Claude.app not found, skipping icon."
fi

# ── Compile ───────────────────────────────────────────────────────────────────
swiftc -swift-version 5 "$SWIFT_SRC" -o "$APP/Contents/MacOS/ClaudeNotifier"
echo "Compiled."

# ── Sign ──────────────────────────────────────────────────────────────────────
codesign --force --deep --sign - "$APP"
echo "Signed."

# ── LaunchAgent plist ─────────────────────────────────────────────────────────
echo "Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/ClaudeNotifier</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/claude-notifier.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-notifier.log</string>
</dict>
</plist>
EOF

# ── Load / reload daemon ──────────────────────────────────────────────────────
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "LaunchAgent loaded."

# Give it a moment to bind the socket
sleep 1

if [ -S /tmp/claude-notifier.sock ]; then
  echo "Daemon is running. Socket ready at /tmp/claude-notifier.sock"
else
  echo "Warning: socket not yet present. Check /tmp/claude-notifier.log"
fi

echo ""
echo "Done. If this is a first install, go to:"
echo "  System Settings > Notifications > Claude Notifier"
echo "and set the style to Banners or Alerts."
