import Cocoa
import Carbon

let args = CommandLine.arguments

// ── check-focus mode ──────────────────────────────────────────────────────────
if args.count > 1 && args[1] == "check-focus" {
    let target = args.count > 2 ? args[2].lowercased() : ""
    let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() ?? ""
    exit(frontmost == target ? 0 : 1)
}

// ── daemon mode ───────────────────────────────────────────────────────────────
guard args.count > 1 && args[1] == "--daemon" else {
    fputs("Usage: ClaudeNotifier --daemon | check-focus <app>\n", stderr)
    exit(1)
}

// ── NSButton closure helper ───────────────────────────────────────────────────
private var _actionKey = 0
extension NSButton {
    func onAction(_ block: @escaping () -> Void) {
        objc_setAssociatedObject(self, &_actionKey, block, .OBJC_ASSOCIATION_RETAIN)
        target = self
        action = #selector(NSButton._runBlock)
    }
    @objc fileprivate func _runBlock() {
        (objc_getAssociatedObject(self, &_actionKey) as? () -> Void)?()
    }
}

// ── Clickable row view ────────────────────────────────────────────────────────
class ClickableRow: NSView {
    var clickAction: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard clickAction != nil else { return }
        wantsLayer = true
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = .clear
    }

    override func mouseDown(with event: NSEvent) {
        clickAction?()
    }
}

// ── Panel content view ────────────────────────────────────────────────────────
class PanelContentView: NSView {
    struct InputRow {
        var requestId: String
        var question: String
        var options: [String]
        var sessionName: String
    }

    struct Row {
        var cwd: String
        var displayName: String
        var isWorking: Bool
        var currentTool: String?
        var currentCommand: String?
        var isDone: Bool
        var agents: [(id: String, name: String)]
        var account: String? = nil
        var accountColor: NSColor? = nil
    }

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh(
        inputs: [InputRow],
        rows: [Row],
        spinnerChar: String = "⣷",
        usageText: String? = nil,
        onFocus: @escaping (String) -> Void,
        onAnswer: @escaping (String, String) -> Void
    ) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        // ── Section A: Pending inputs ─────────────────────────────────────────
        if !inputs.isEmpty {
            for input in inputs {
                // Question label
                let labelText = "⚡  \(input.question)  (\(input.sessionName))"
                let lbl = NSTextField(labelWithString: labelText)
                lbl.textColor = .labelColor
                lbl.font = .systemFont(ofSize: 13)
                lbl.lineBreakMode = .byTruncatingTail
                lbl.translatesAutoresizingMaskIntoConstraints = false
                let lblRow = NSView()
                lblRow.translatesAutoresizingMaskIntoConstraints = false
                lblRow.addSubview(lbl)
                NSLayoutConstraint.activate([
                    lblRow.heightAnchor.constraint(equalToConstant: 22),
                    lbl.leadingAnchor.constraint(equalTo: lblRow.leadingAnchor),
                    lbl.centerYAnchor.constraint(equalTo: lblRow.centerYAnchor),
                    lbl.trailingAnchor.constraint(lessThanOrEqualTo: lblRow.trailingAnchor),
                ])
                stack.addArrangedSubview(lblRow)
                lblRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

                // Button row
                let btnStack = NSStackView()
                btnStack.orientation = .horizontal
                btnStack.alignment = .centerY
                btnStack.spacing = 6
                btnStack.translatesAutoresizingMaskIntoConstraints = false

                for (idx, optionLabel) in input.options.enumerated() {
                    let btn = NSButton(title: optionLabel, target: nil, action: nil)
                    btn.bezelStyle = .rounded
                    btn.font = .systemFont(ofSize: 12)
                    btn.lineBreakMode = .byTruncatingTail
                    // Last button is destructive
                    if idx == input.options.count - 1 {
                        btn.bezelColor = NSColor.systemRed
                    }
                    let rid = input.requestId
                    let label = optionLabel
                    btn.onAction { onAnswer(rid, label) }
                    btnStack.addArrangedSubview(btn)
                }

                let btnRow = NSView()
                btnRow.translatesAutoresizingMaskIntoConstraints = false
                btnRow.addSubview(btnStack)
                NSLayoutConstraint.activate([
                    btnRow.heightAnchor.constraint(equalToConstant: 28),
                    btnStack.leadingAnchor.constraint(equalTo: btnRow.leadingAnchor),
                    btnStack.centerYAnchor.constraint(equalTo: btnRow.centerYAnchor),
                    btnStack.trailingAnchor.constraint(lessThanOrEqualTo: btnRow.trailingAnchor),
                ])
                stack.addArrangedSubview(btnRow)
                btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }

            // Separator after input section
            addSeparator()
        }

        // ── Section B: Done sessions ──────────────────────────────────────────
        let doneSessions = rows.filter { $0.isDone }
        if !doneSessions.isEmpty {
            for row in doneSessions {
                addRow(indent: 0, text: "✓  \(row.displayName)  —  Done", color: .labelColor, cwd: row.cwd, onFocus: onFocus)
            }

            // Separator after done section
            addSeparator()
        }

        // ── Section C: Active sessions ────────────────────────────────────────
        let activeSessions = rows.filter { !$0.isDone }
        if activeSessions.isEmpty && inputs.isEmpty && doneSessions.isEmpty {
            let lbl = NSTextField(labelWithString: "No active sessions")
            lbl.textColor = .secondaryLabelColor
            lbl.font = .systemFont(ofSize: 13)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(lbl)
            return
        }

        for row in activeSessions {
            if row.isWorking {
                if let tool = row.currentTool {
                    let cmd = row.currentCommand.map { " \($0)" } ?? ""
                    buildSessionRow(row: row, prefix: "\(spinnerChar)  \(row.displayName)", suffix: "  —  \(tool):\(cmd)", cwd: row.cwd, onFocus: onFocus)
                } else {
                    buildSessionRow(row: row, prefix: "\(spinnerChar)  \(row.displayName)", suffix: "  —  working", cwd: row.cwd, onFocus: onFocus)
                }
            } else {
                buildSessionRow(row: row, prefix: "○  \(row.displayName)", suffix: "  —  idle", cwd: row.cwd, onFocus: onFocus)
            }
            for agent in row.agents {
                addRow(
                    indent: 16,
                    text: "↳  \(agent.name.isEmpty ? "subagent" : agent.name)",
                    color: .labelColor,
                    cwd: row.cwd,
                    onFocus: onFocus
                )
            }
        }

        // ── Section D: Usage footer (future) ─────────────────────────────────────────
        if let usageText = usageText {
            addSeparator()
            let lbl = NSTextField(labelWithString: usageText)
            lbl.textColor = .secondaryLabelColor
            lbl.font = .systemFont(ofSize: 11)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            let usageRow = NSView()
            usageRow.translatesAutoresizingMaskIntoConstraints = false
            usageRow.addSubview(lbl)
            NSLayoutConstraint.activate([
                usageRow.heightAnchor.constraint(equalToConstant: 18),
                lbl.leadingAnchor.constraint(equalTo: usageRow.leadingAnchor),
                lbl.centerYAnchor.constraint(equalTo: usageRow.centerYAnchor),
                lbl.trailingAnchor.constraint(lessThanOrEqualTo: usageRow.trailingAnchor),
            ])
            stack.addArrangedSubview(usageRow)
            usageRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func buildSessionRow(
        row: Row, prefix: String, suffix: String,
        cwd: String, onFocus: @escaping (String) -> Void
    ) {
        if let accountColor = row.accountColor {
            let attr = NSMutableAttributedString()
            let base: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            let shortLabel = row.account.map { " " + String($0.prefix(4)) } ?? " ●"
            attr.append(NSAttributedString(string: prefix, attributes: base))
            attr.append(NSAttributedString(string: shortLabel, attributes: [
                .foregroundColor: accountColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]))
            attr.append(NSAttributedString(string: suffix, attributes: base))
            addRow(indent: 0, attrText: attr, cwd: cwd, onFocus: onFocus)
        } else {
            addRow(indent: 0, text: prefix + suffix, color: .labelColor, cwd: cwd, onFocus: onFocus)
        }
    }

    private func addSeparator() {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addRow(
        indent: CGFloat, attrText: NSAttributedString,
        cwd: String, onFocus: @escaping (String) -> Void
    ) {
        let row = ClickableRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        if !cwd.isEmpty { row.clickAction = { onFocus(cwd) } }

        let lbl = NSTextField(labelWithString: "")
        lbl.attributedStringValue = attrText
        lbl.lineBreakMode = .byTruncatingTail
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])

        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addRow(
        indent: CGFloat, text: String, color: NSColor,
        cwd: String, onFocus: @escaping (String) -> Void
    ) {
        let row = ClickableRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        if !cwd.isEmpty { row.clickAction = { onFocus(cwd) } }

        let lbl = NSTextField(labelWithString: text)
        lbl.textColor = color
        lbl.font = .systemFont(ofSize: 13)
        lbl.lineBreakMode = .byTruncatingTail
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])

        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

// ─────────────────────────────────────────────────────────────────────────────

class ClaudeNotifierDaemon: NSObject {
    let socketQueue = DispatchQueue(label: "com.claudeship.notifier.socket")
    let socketPath = "/tmp/claude-notifier.sock"
    let logPath = "/tmp/claude-notifier.log"
    var serverSource: DispatchSourceRead?

    struct PendingInput {
        var requestId: String
        var question: String
        var options: [String]
        var sessionName: String
        var sessionId: String?
        var replyFifoPath: String?
    }
    var pendingInputs: [String: PendingInput] = [:]

    struct AgentSession {
        var total: Int
        var completed: Int
        var agents: [(id: String, name: String)]
    }
    var agentSessions: [String: AgentSession] = [:]

    struct Session {
        var id: String
        var account: String? = nil
        var cwd: String
        var displayName: String
        var isWorking: Bool
        var currentTool: String?
        var currentCommand: String?
        var toolUpdatedAt: Date?
        var isDone: Bool
        var doneAt: Date?
    }
    var sessions: [String: Session] = [:]

    struct AccountConfig {
        var displayName: String
        var color: NSColor
    }
    var accountConfigs: [String: AccountConfig] = [:]

    // ── Status bar ────────────────────────────────────────────────────────────
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var spinnerTimer: DispatchSourceTimer?
    var spinnerFrame = 0
    let spinnerFrames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
    var hotKeyRef: EventHotKeyRef?

    // ── Panel ─────────────────────────────────────────────────────────────────
    let panel: NSPanel
    let panelContent: PanelContentView
    var globalMonitor: Any?

    override init() {
        let content = PanelContentView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true

        let vev = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        vev.material = .popover
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 10
        vev.layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        vev.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: vev.topAnchor),
            content.leadingAnchor.constraint(equalTo: vev.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: vev.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: vev.bottomAnchor),
        ])

        p.contentView = vev
        panel = p
        panelContent = content

        super.init()

        loadAccountConfigs()
        rotateLogIfNeeded()
        setupStatusItem()
        setupHotKey()
        startListening()
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
    }

    // ── Global hotkey (Cmd+Shift+C) ───────────────────────────────────────────
    func setupHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = 0x434C5348 // "CLSH"
        hotKeyID.id = 1

        // kVK_ANSI_C = 8, cmdKey | shiftKey = 256 | 512
        RegisterEventHotKey(8, UInt32(cmdKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
                let daemon = Unmanaged<ClaudeNotifierDaemon>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        daemon.refresh()
                        daemon.positionPanel()
                        daemon.panel.orderFrontRegardless()
                    } else {
                        daemon.panel.orderOut(nil)
                    }
                }
                return noErr
            },
            2, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    // ── Status item ───────────────────────────────────────────────────────────
    func setupStatusItem() {
        updateStatusTitle()
        statusItem.menu = nil
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(togglePanel(_:))
            btn.sendAction(on: .leftMouseDown)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            // If the click landed on the status button, let togglePanel handle it
            if let btn = self.statusItem.button, let win = btn.window {
                let inWin = btn.convert(btn.bounds, to: nil)
                let onScreen = win.convertToScreen(inWin)
                if onScreen.contains(NSEvent.mouseLocation) { return }
            }
            // If the click landed inside the panel, don't dismiss
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.panel.orderOut(nil)
        }
    }

    @objc func togglePanel(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            refresh()
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    func positionPanel() {
        guard let screen = NSScreen.main else { return }
        panelContent.layoutSubtreeIfNeeded()
        let height = panelContent.fittingSize.height
        let sw = screen.frame.width
        let sy = screen.frame.maxY
        let menuBarHeight = NSStatusBar.system.thickness
        let x = (sw - 340) / 2
        let y = sy - menuBarHeight - height - 20
        panel.setFrame(NSRect(x: x, y: y, width: 340, height: height), display: true)
    }

    // ── Refresh panel ─────────────────────────────────────────────────────────
    func refresh() {
        let inputs = pendingInputs.values.sorted { $0.question < $1.question }.map { p in
            PanelContentView.InputRow(
                requestId: p.requestId, question: p.question,
                options: p.options, sessionName: p.sessionName)
        }
        let rows = sessions.values.sorted { $0.displayName < $1.displayName }.map { s in
            let acctColor = s.account.flatMap { accountConfigs[$0]?.color }
            return PanelContentView.Row(
                cwd: s.cwd, displayName: s.displayName, isWorking: s.isWorking,
                currentTool: s.currentTool, currentCommand: s.currentCommand,
                isDone: s.isDone, agents: agentSessions[s.id]?.agents ?? [],
                account: s.account, accountColor: acctColor)
        }
        panelContent.refresh(
            inputs: inputs, rows: rows,
            spinnerChar: spinnerFrames[spinnerFrame],
            usageText: nil,
            onFocus: { [weak self] cwd in
                self?.focusGhostty(cwd: cwd)
                self?.panel.orderOut(nil)
            },
            onAnswer: { [weak self] requestId, chosen in
                self?.writeReply(requestId: requestId, content: chosen)
            })
        if panel.isVisible { positionPanel() }
    }

    func focusGhostty(cwd: String) {
        guard !cwd.isEmpty else { return }
        let script = """
            tell application "Ghostty"
                set matches to every terminal whose working directory contains "\(cwd)"
                if (count of matches) > 0 then focus item 1 of matches
            end tell
            """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    // ── Spinner / status title ────────────────────────────────────────────────
    func updateStatusTitle() {
        // Priority 1: any pending input
        if !pendingInputs.isEmpty {
            statusItem.button?.title = "⁇ claudeship"
            statusItem.button?.attributedTitle = NSAttributedString(string: "⁇ claudeship")
            return
        }

        let total = sessions.count
        let workingSessions = sessions.values.filter { $0.isWorking }
        let working = workingSessions.count

        // Priority 2: any session working
        if working > 0 {
            let countStr = "\(working)/\(total)"
            let recentSession = workingSessions
                .filter { $0.currentTool != nil }
                .max(by: { ($0.toolUpdatedAt ?? .distantPast) < ($1.toolUpdatedAt ?? .distantPast) })

            let toolSuffix: String
            if let tool = recentSession?.currentTool {
                let cmd = recentSession?.currentCommand.map { " \($0)" } ?? ""
                toolSuffix = " — \(tool):\(cmd)"
            } else {
                toolSuffix = ""
            }

            // Collect unique accounts from working sessions (preserve insertion order)
            var seenAccounts: [String] = []
            var accountLabels: [(label: String, color: NSColor)] = []
            for s in workingSessions {
                let key = s.account ?? "__none__"
                if !seenAccounts.contains(key) {
                    seenAccounts.append(key)
                    if let acct = s.account, let cfg = accountConfigs[acct] {
                        let short = String(acct.prefix(4))
                        accountLabels.append((label: short, color: cfg.color))
                    }
                }
            }

            if accountLabels.isEmpty {
                let plain = "\(spinnerFrames[spinnerFrame]) \(countStr) claudeship\(toolSuffix)"
                statusItem.button?.title = plain
                statusItem.button?.attributedTitle = NSAttributedString(string: plain)
            } else {
                let attr = NSMutableAttributedString()
                let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
                attr.append(NSAttributedString(string: "\(spinnerFrames[spinnerFrame]) \(countStr) ", attributes: base))
                for (i, entry) in accountLabels.enumerated() {
                    if i > 0 { attr.append(NSAttributedString(string: " ", attributes: base)) }
                    attr.append(NSAttributedString(string: entry.label, attributes: [.foregroundColor: entry.color]))
                }
                attr.append(NSAttributedString(string: " claudeship\(toolSuffix)", attributes: base))
                statusItem.button?.attributedTitle = attr
            }
            return
        }

        // Priority 3: recently done
        if sessions.values.contains(where: { $0.isDone }) {
            let plain = "✓ claudeship"
            statusItem.button?.title = plain
            statusItem.button?.attributedTitle = NSAttributedString(string: plain)
            return
        }

        // Priority 4: idle
        let plain = total == 0 ? "✳ claudeship" : "✳ \(total) claudeship"
        statusItem.button?.title = plain
        statusItem.button?.attributedTitle = NSAttributedString(string: plain)
    }

    func updateSpinnerTimer() {
        let working = sessions.values.filter { $0.isWorking }.count
        if working > 0 && spinnerTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.spinnerFrame = (self.spinnerFrame + 1) % self.spinnerFrames.count
                self.updateStatusTitle()
                // Don't rebuild the panel while inputs are pending — doing so destroys
                // buttons mid-click (between mouseDown and mouseUp), causing missed clicks.
                if self.panel.isVisible && self.pendingInputs.isEmpty { self.refresh() }
            }
            timer.resume()
            spinnerTimer = timer
        } else if working == 0, let timer = spinnerTimer {
            timer.cancel()
            spinnerTimer = nil
            spinnerFrame = 0
        }
    }

    // ── Log rotation ──────────────────────────────────────────────────────────
    func rotateLogIfNeeded() {
        let limit = 1_048_576
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
            let size = attrs[.size] as? Int, size > limit
        else { return }
        let backup = logPath + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: logPath, toPath: backup)
        print("ClaudeNotifier: rotated log (\(size) bytes → \(backup))")
    }

    // ── Socket listener ───────────────────────────────────────────────────────
    func startListening() {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fputs("ClaudeNotifier: socket() failed: \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            socketPath.withCString { cStr in
                _ = strlcpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), cStr, ptr.count)
            }
        }

        let bindResult = withUnsafeBytes(of: &addr) { ptr in
            Darwin.bind(
                fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        guard bindResult == 0 else {
            fputs("ClaudeNotifier: bind() failed: \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }

        listen(fd, 10)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)
        source.setEventHandler { [weak self] in self?.acceptConnections(serverFd: fd) }
        source.resume()
        serverSource = source

        print("ClaudeNotifier: daemon listening on \(socketPath)")
    }

    func acceptConnections(serverFd: Int32) {
        while true {
            let clientFd = accept(serverFd, nil, nil)
            if clientFd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                continue
            }
            handleClient(clientFd)
        }
    }

    // ── Message dispatch ──────────────────────────────────────────────────────
    func handleClient(_ clientFd: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(clientFd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }
        close(clientFd)

        guard !data.isEmpty,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let ts = ISO8601DateFormatter().string(from: Date())
        let msgType = json["type"] as? String ?? "notify"
        print("[\(ts)] daemon: received type=\(msgType)")

        switch msgType {
        case "session_register":
            DispatchQueue.main.async { [weak self] in self?.handleSessionRegister(json) }
        case "session_working":
            DispatchQueue.main.async { [weak self] in self?.handleSessionWorking(json) }
        case "session_tool":
            DispatchQueue.main.async { [weak self] in self?.handleSessionTool(json) }
        case "session_thinking":
            DispatchQueue.main.async { [weak self] in self?.handleSessionThinking(json) }
        case "session_end":
            DispatchQueue.main.async { [weak self] in self?.handleSessionEnd(json) }
        case "subagent_start":
            DispatchQueue.main.async { [weak self] in self?.handleSubagentStart(json) }
        case "subagent_stop":
            DispatchQueue.main.async { [weak self] in self?.handleSubagentStop(json) }
        case "turn_stop":
            DispatchQueue.main.async { [weak self] in self?.handleSessionStop(json) }
        case "input_question":
            DispatchQueue.main.async { [weak self] in
                let sid = json["session_id"] as? String ?? "(nil)"
                let rid = json["request_id"] as? String ?? "?"
                let ts = ISO8601DateFormatter().string(from: Date())
                print("[\(ts)] daemon: input_question id=\(rid) session=\(sid)")
                self?.handleInputQuestion(json)
            }
        case "session_inputs_clear":
            DispatchQueue.main.async { [weak self] in self?.handleSessionInputsClear(json) }
        case "session_idle":
            DispatchQueue.main.async { [weak self] in self?.handleSessionIdle(json) }
        case "accounts_changed":
            DispatchQueue.main.async { [weak self] in self?.handleAccountsChanged(json) }
        default:
            break
        }
    }

    // ── Session handlers ──────────────────────────────────────────────────────
    func handleSessionRegister(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let cwd = json["cwd"] as? String ?? ""
        let displayName =
            URL(fileURLWithPath: cwd).lastPathComponent.isEmpty
            ? String(sessionId.prefix(8))
            : URL(fileURLWithPath: cwd).lastPathComponent
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: session_register id=\(sessionId) name='\(displayName)'")
        let account = json["account"] as? String
        sessions[sessionId] = Session(
            id: sessionId, account: account?.isEmpty == false ? account : nil,
            cwd: cwd, displayName: displayName, isWorking: false,
            currentTool: nil, currentCommand: nil, toolUpdatedAt: nil, isDone: false, doneAt: nil)
        updateStatusTitle()
        refresh()
    }

    func handleSessionWorking(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        if sessions[sessionId] == nil {
            sessions[sessionId] = Session(
                id: sessionId, cwd: "", displayName: String(sessionId.prefix(8)), isWorking: false,
                currentTool: nil, currentCommand: nil, toolUpdatedAt: nil, isDone: false, doneAt: nil)
        }
        sessions[sessionId]!.isWorking = true
        sessions[sessionId]!.isDone = false
        updateStatusTitle()
        updateSpinnerTimer()
        refresh()
    }

    func handleSessionTool(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        sessions[sessionId]?.currentTool = json["tool_name"] as? String
        sessions[sessionId]?.currentCommand = json["command_preview"] as? String
        sessions[sessionId]?.toolUpdatedAt = Date()
        updateStatusTitle()
        if panel.isVisible { refresh() }
    }

    func handleSessionThinking(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        guard sessions[sessionId] != nil else { return }
        sessions[sessionId]!.isWorking = true
        sessions[sessionId]!.isDone = false
        sessions[sessionId]!.currentTool = nil
        sessions[sessionId]!.currentCommand = nil
        updateStatusTitle()
        updateSpinnerTimer()
        if panel.isVisible { refresh() }
    }

    func handleSessionEnd(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: session_end id=\(sessionId)")
        // Clear pending inputs so ⚡ doesn't stick after session close
        let before = pendingInputs.count
        pendingInputs = pendingInputs.filter { $0.value.sessionId != sessionId }
        if pendingInputs.count < before {
            print("[\(ts)] daemon: cleared \(before - pendingInputs.count) pending input(s) for ended session \(sessionId)")
        }
        sessions.removeValue(forKey: sessionId)
        agentSessions.removeValue(forKey: sessionId)
        updateStatusTitle()
        updateSpinnerTimer()
        refresh()
        if pendingInputs.isEmpty { panel.orderOut(nil) }
    }

    func handleSessionStop(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        if agentSessions.removeValue(forKey: sessionId) != nil {
            print("[\(ts)] daemon: cleared subagent state for session \(sessionId)")
        }
        if sessions[sessionId] != nil {
            sessions[sessionId]!.isWorking = false
            sessions[sessionId]!.currentTool = nil
            sessions[sessionId]!.currentCommand = nil
            sessions[sessionId]!.isDone = true
            sessions[sessionId]!.doneAt = Date()
            print("[\(ts)] daemon: session done id=\(sessionId)")
        }
        updateStatusTitle()
        updateSpinnerTimer()

        // Auto-clear done state after 8 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            self.sessions[sessionId]?.isDone = false
            self.updateStatusTitle()
            self.refresh()
            // Auto-close panel if nothing pending
            if self.pendingInputs.isEmpty { self.panel.orderOut(nil) }
        }

        // Auto-open panel
        refresh()
        positionPanel()
        panel.orderFrontRegardless()
    }

    // ── Subagent handlers ─────────────────────────────────────────────────────
    func handleSubagentStart(_ json: [String: Any]) {
        guard let parentId = json["parent_session_id"] as? String,
            let agentId = json["session_id"] as? String
        else {
            print("daemon: subagent_start missing IDs — raw: \(json)")
            return
        }
        let agentName = json["agent_name"] as? String ?? ""
        let ts = ISO8601DateFormatter().string(from: Date())
        print(
            "[\(ts)] daemon: subagent_start parent=\(parentId) agent=\(agentId) name='\(agentName)'"
        )
        if agentSessions[parentId] == nil {
            agentSessions[parentId] = AgentSession(total: 0, completed: 0, agents: [])
        }
        agentSessions[parentId]!.total += 1
        agentSessions[parentId]!.agents.append((id: agentId, name: agentName))
        refresh()
    }

    func handleSubagentStop(_ json: [String: Any]) {
        guard let agentId = json["session_id"] as? String,
            let parentId = json["parent_session_id"] as? String
        else {
            print("daemon: subagent_stop missing IDs — raw: \(json)")
            return
        }
        let ts = ISO8601DateFormatter().string(from: Date())

        if var session = agentSessions[parentId] {
            session.completed += 1
            var agentName = "Subagent"
            if let idx = session.agents.firstIndex(where: { $0.id == agentId }) {
                let stored = session.agents[idx].name
                if !stored.isEmpty { agentName = stored }
                session.agents.remove(at: idx)
            }
            agentSessions[parentId] = session
            let progress = "(\(session.completed)/\(session.total))"
            let message = "\(agentName) done \(progress)"
            print("[\(ts)] daemon: \(message) parent=\(parentId)")
            refresh()
        } else {
            print("[\(ts)] daemon: subagent_stop with no tracked parent \(parentId)")
        }
    }

    // ── Input question ────────────────────────────────────────────────────────
    func handleInputQuestion(_ json: [String: Any]) {
        guard let requestId = json["request_id"] as? String,
            let options = json["options"] as? [String], !options.isEmpty
        else {
            print("daemon: input_question missing required fields")
            return
        }
        let question = json["question"] as? String ?? "Claude needs your input"
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: input_question id=\(requestId) options=\(options)")

        let sessionId = json["session_id"] as? String
        let sessionName = sessionId.flatMap { sessions[$0]?.displayName }
            ?? (json["subtitle"] as? String ?? "")
        let replyFifoPath = json["reply_fifo"] as? String

        pendingInputs[requestId] = PendingInput(
            requestId: requestId, question: question, options: options,
            sessionName: sessionName, sessionId: sessionId,
            replyFifoPath: replyFifoPath)

        updateStatusTitle()
        // Auto-open panel
        refresh()
        positionPanel()
        panel.orderFrontRegardless()
    }

    func handleSessionIdle(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: session_idle id=\(sessionId)")
        if sessions[sessionId] != nil {
            sessions[sessionId]!.isWorking = false
            sessions[sessionId]!.currentTool = nil
            sessions[sessionId]!.currentCommand = nil
        }
        updateStatusTitle()
        updateSpinnerTimer()
        refresh()
    }

    func handleSessionInputsClear(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        let stored = pendingInputs.values.map { "\($0.requestId)@\($0.sessionId ?? "nil")" }.joined(separator: ", ")
        print("[\(ts)] daemon: session_inputs_clear session=\(sessionId) pending=[\(stored)]")
        let before = pendingInputs.count
        pendingInputs = pendingInputs.filter { $0.value.sessionId != sessionId }
        guard pendingInputs.count < before else { return }
        updateStatusTitle()
        refresh()
        if pendingInputs.isEmpty { panel.orderOut(nil) }
    }

    // ── Account helpers ───────────────────────────────────────────────────────
    func color(for name: String?) -> NSColor {
        switch name {
        case "blue":   return .systemBlue
        case "green":  return .systemGreen
        case "orange": return .systemOrange
        case "red":    return .systemRed
        case "purple": return .systemPurple
        case "yellow": return .systemYellow
        default:       return .secondaryLabelColor
        }
    }

    func loadAccountConfigs() {
        let path = NSHomeDirectory() + "/.claude/accounts.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [String: Any]
        else {
            accountConfigs = [:]
            return
        }
        var configs: [String: AccountConfig] = [:]
        for (name, value) in accounts {
            guard let info = value as? [String: Any] else { continue }
            let displayName = info["display_name"] as? String ?? name
            let colorName   = info["color"] as? String
            configs[name] = AccountConfig(displayName: displayName, color: color(for: colorName))
        }
        accountConfigs = configs
    }

    func handleAccountsChanged(_ json: [String: Any]) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: accounts_changed — reloading configs")
        loadAccountConfigs()
        updateStatusTitle()
        refresh()
    }

    func writeReply(requestId: String, content: String) {
        guard let pending = pendingInputs[requestId] else { return }

        if let fifoPath = pending.replyFifoPath {
            DispatchQueue.global().async {
                let ts = ISO8601DateFormatter().string(from: Date())
                if let handle = FileHandle(forWritingAtPath: fifoPath) {
                    handle.write((content + "\n").data(using: .utf8) ?? Data())
                    handle.closeFile()
                    print("[\(ts)] daemon: wrote reply '\(content)' → \(fifoPath)")
                } else {
                    print("[\(ts)] daemon: FIFO gone, skipped reply '\(content)' → \(fifoPath)")
                }
            }
        } else {
            let replyPath = "/tmp/claude-input-reply-\(requestId)"
            try? content.write(toFile: replyPath, atomically: true, encoding: .utf8)
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[\(ts)] daemon: wrote reply '\(content)' → \(replyPath)")
        }

        pendingInputs.removeValue(forKey: requestId)
        updateStatusTitle()
        refresh()
        if pendingInputs.isEmpty {
            panel.orderOut(nil)
        } else {
            // More pending inputs remain — reshow panel so user knows to answer them
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

}

// ── Entry point ───────────────────────────────────────────────────────────────
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let daemon = ClaudeNotifierDaemon()
app.run()
