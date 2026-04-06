#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
swiftc "$SCRIPT_DIR/ClaudeNotifier.swift" -o "$SCRIPT_DIR/ClaudeNotifier" -framework Cocoa
cp "$SCRIPT_DIR/ClaudeNotifier" /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
codesign --force --sign - /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
launchctl unload ~/Library/LaunchAgents/com.claudeship.notifier.plist
launchctl load ~/Library/LaunchAgents/com.claudeship.notifier.plist
echo "ClaudeNotifier rebuilt and reloaded."
