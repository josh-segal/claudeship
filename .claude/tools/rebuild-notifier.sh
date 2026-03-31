#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
swiftc .claude/tools/ClaudeNotifier.swift -o .claude/tools/ClaudeNotifier -framework Cocoa
cp .claude/tools/ClaudeNotifier /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
codesign --force --sign - /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
launchctl unload ~/Library/LaunchAgents/com.claudeship.notifier.plist
launchctl load ~/Library/LaunchAgents/com.claudeship.notifier.plist
echo "ClaudeNotifier rebuilt and reloaded."
