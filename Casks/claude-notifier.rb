cask "claude-notifier" do
  version "0.0.4"
  sha256 "a62f143149957e72df031971217523a33abc5ca4ef29ca1cb362a4922f6911a1"

  url "https://github.com/josh-segal/claudeship/releases/download/v#{version}/ClaudeNotifier.zip"
  name "Claude Notifier"
  desc "Menubar daemon for Claude Code notifications"
  homepage "https://github.com/josh-segal/claudeship"

  depends_on macos: ">= :monterey"

  app "ClaudeNotifier.app"

  postflight do
    plist_path = "#{Dir.home}/Library/LaunchAgents/com.claudeship.notifier.plist"
    app_path = "/Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier"

    plist_content = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>com.claudeship.notifier</string>
          <key>ProgramArguments</key>
          <array>
              <string>#{app_path}</string>
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
    XML

    File.write(plist_path, plist_content)
    system_command "/bin/launchctl", args: ["load", plist_path]
  end

  uninstall launchctl: "com.claudeship.notifier",
            quit:      "com.claudeship.notifier"

  caveats <<~EOS
    Claude Notifier is running as a background daemon.

    Logs: tail -f /tmp/claude-notifier.log

    First install? Grant notification permissions:
      System Settings > Notifications > Claude Notifier
  EOS
end
