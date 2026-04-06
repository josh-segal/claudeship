#!/bin/bash
set -e
cd "$HOME/.claude"
swiftc tools/ClaudeNotifier.swift -o tools/ClaudeNotifier -framework Cocoa
cp tools/ClaudeNotifier /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
codesign --force --sign - /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
launchctl unload ~/Library/LaunchAgents/com.claudeship.notifier.plist
launchctl load ~/Library/LaunchAgents/com.claudeship.notifier.plist
echo "ClaudeNotifier rebuilt and reloaded."
