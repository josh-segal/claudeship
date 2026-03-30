import Cocoa
import UserNotifications

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

// ─────────────────────────────────────────────────────────────────────────────

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var daemon: ClaudeNotifierDaemon?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier

        if actionId == "OPEN_TERMINAL" {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.mitchellh.ghostty"
            ).first {
                app.activate(options: [.activateAllWindows])
            }
        } else if actionId.hasPrefix("PERM_allow_always_") {
            let requestId = String(actionId.dropFirst("PERM_allow_always_".count))
            daemon?.writeReply(requestId: requestId, content: "allow_always")
        } else if actionId.hasPrefix("PERM_allow_once_") {
            let requestId = String(actionId.dropFirst("PERM_allow_once_".count))
            daemon?.writeReply(requestId: requestId, content: "allow")
        } else if actionId.hasPrefix("PERM_deny_") {
            let requestId = String(actionId.dropFirst("PERM_deny_".count))
            daemon?.writeReply(requestId: requestId, content: "deny")
        } else if actionId.hasPrefix("CHOICE_") {
            // Format: CHOICE_{index}_{requestId}  (requestId is always a PID — numeric, no underscores)
            let withoutPrefix = String(actionId.dropFirst("CHOICE_".count))
            if let underscoreIdx = withoutPrefix.firstIndex(of: "_") {
                let indexStr = String(withoutPrefix[withoutPrefix.startIndex..<underscoreIdx])
                let requestId = String(withoutPrefix[withoutPrefix.index(after: underscoreIdx)...])
                if let idx = Int(indexStr),
                    let pending = daemon?.pendingReplies[requestId],
                    idx < pending.options.count
                {
                    daemon?.writeReply(requestId: requestId, content: pending.options[idx])
                }
            }
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

class ClaudeNotifierDaemon: NSObject {
    let center = UNUserNotificationCenter.current()
    let socketQueue = DispatchQueue(label: "com.claudeship.notifier.socket")
    let socketPath = "/tmp/claude-notifier.sock"
    let logPath = "/tmp/claude-notifier.log"
    let delegate = NotificationDelegate()
    var serverSource: DispatchSourceRead?

    // ── Pending input replies (keyed by requestId, mutated on DispatchQueue.main)
    struct PendingReply {
        var options: [String]  // option labels for CHOICE_ actions
    }
    var pendingReplies: [String: PendingReply] = [:]

    // ── Subagent state (all mutations on DispatchQueue.main) ──────────────────
    struct AgentSession {
        var total: Int
        var completed: Int
        var agents: [(id: String, name: String)]
    }
    var agentSessions: [String: AgentSession] = [:]

    // ── Session registry (all mutations on DispatchQueue.main) ────────────────
    struct Session {
        var id: String
        var cwd: String
        var displayName: String
        var isWorking: Bool
    }
    var sessions: [String: Session] = [:]

    // ── Menu bar status item ──────────────────────────────────────────────────
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var spinnerTimer: DispatchSourceTimer?
    var spinnerFrame = 0
    let spinnerFrames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]

    override init() {
        super.init()
        delegate.daemon = self
        center.delegate = delegate
        registerCategories()
        rotateLogIfNeeded()
        requestAuth()
        setupStatusItem()
        startListening()
    }

    func setupStatusItem() {
        updateStatusTitle()
        rebuildMenu()
    }

    func updateStatusTitle() {
        let total = sessions.count
        let working = sessions.values.filter { $0.isWorking }.count
        if total == 0 {
            statusItem.button?.title = "✳ claudeship"
        } else if working == 0 {
            statusItem.button?.title = "✳ \(total) claudeship"
        } else {
            statusItem.button?.title =
                "\(spinnerFrames[spinnerFrame]) \(working)/\(total) claudeship"
        }
    }

    @objc func focusSession(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String, !cwd.isEmpty else { return }
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

    func rebuildMenu() {
        let menu = NSMenu()
        let sorted = sessions.values.sorted { $0.displayName < $1.displayName }

        if sorted.isEmpty {
            menu.addItem(NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: ""))
        } else {
            for session in sorted {
                let bullet = session.isWorking ? "●" : "○"
                let status = session.isWorking ? "working" : "idle"
                let item = NSMenuItem(
                    title: "\(bullet)  \(session.displayName)  —  \(status)",
                    action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.cwd
                menu.addItem(item)

                if let agentSession = agentSessions[session.id] {
                    for agent in agentSession.agents {
                        let agentItem = NSMenuItem(
                            title: agent.name.isEmpty ? "subagent" : agent.name,
                            action: nil, keyEquivalent: "")
                        agentItem.indentationLevel = 1
                        menu.addItem(agentItem)
                    }
                }
            }
        }

        statusItem.menu = menu
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
        let limit = 1_048_576  // 1 MB
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
            let size = attrs[.size] as? Int,
            size > limit
        else { return }
        let backup = logPath + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: logPath, toPath: backup)
        print("ClaudeNotifier: rotated log (\(size) bytes → \(backup))")
    }

    // ── Notification categories ───────────────────────────────────────────────
    func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_TERMINAL",
            title: "Open Terminal", options: [])
        let category = UNNotificationCategory(
            identifier: "CLAUDE_ACTION",
            actions: [openAction],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func requestAuth() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                print("ClaudeNotifier: notifications authorized")
            } else {
                fputs(
                    "ClaudeNotifier: notification permission denied — grant access in System Settings\n",
                    stderr)
            }
        }
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
        case "session_end":
            DispatchQueue.main.async { [weak self] in self?.handleSessionEnd(json) }
        case "subagent_start":
            DispatchQueue.main.async { [weak self] in self?.handleSubagentStart(json) }
        case "subagent_stop":
            DispatchQueue.main.async { [weak self] in self?.handleSubagentStop(json) }
        case "turn_stop":
            DispatchQueue.main.async { [weak self] in self?.handleSessionStop(json) }
        case "permission_request":
            DispatchQueue.main.async { [weak self] in self?.handlePermissionRequest(json) }
        case "input_question":
            DispatchQueue.main.async { [weak self] in self?.handleInputQuestion(json) }
        default:
            let title = json["title"] as? String ?? "Claude Code"
            let message = json["message"] as? String ?? ""
            let subtitle = json["subtitle"] as? String ?? ""
            let sound = json["sound"] as? String ?? "Ping"
            DispatchQueue.main.async { [weak self] in
                self?.postNotification(
                    title: title, message: message,
                    subtitle: subtitle, sound: sound)
            }
        }
    }

    // ── Session registry handlers (all on DispatchQueue.main) ───────────────
    func handleSessionRegister(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let cwd = json["cwd"] as? String ?? ""
        let displayName =
            URL(fileURLWithPath: cwd).lastPathComponent.isEmpty
            ? String(sessionId.prefix(8))
            : URL(fileURLWithPath: cwd).lastPathComponent
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: session_register id=\(sessionId) name='\(displayName)'")
        sessions[sessionId] = Session(
            id: sessionId, cwd: cwd, displayName: displayName, isWorking: false)
        updateStatusTitle()
        rebuildMenu()
    }

    func handleSessionWorking(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        if sessions[sessionId] == nil {
            // Session registered before daemon knew about it — add with unknown name
            sessions[sessionId] = Session(
                id: sessionId, cwd: "", displayName: String(sessionId.prefix(8)), isWorking: false)
        }
        sessions[sessionId]!.isWorking = true
        updateStatusTitle()
        updateSpinnerTimer()
        rebuildMenu()
    }

    func handleSessionEnd(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: session_end id=\(sessionId)")
        sessions.removeValue(forKey: sessionId)
        agentSessions.removeValue(forKey: sessionId)
        updateStatusTitle()
        updateSpinnerTimer()
        rebuildMenu()
    }

    // ── Permission request (Allow Once / Allow Always / Deny) ────────────────
    func handlePermissionRequest(_ json: [String: Any]) {
        guard let requestId = json["request_id"] as? String else {
            print("daemon: permission_request missing request_id")
            return
        }
        let toolName = json["tool_name"] as? String ?? "a tool"
        let subtitle = json["subtitle"] as? String ?? ""
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: permission_request id=\(requestId) tool=\(toolName)")

        let categoryId = "CLAUDE_PERM_\(requestId)"
        let allowOnce = UNNotificationAction(
            identifier: "PERM_allow_once_\(requestId)",
            title: "Allow", options: [])
        let allowAlways = UNNotificationAction(
            identifier: "PERM_allow_always_\(requestId)",
            title: "Allow Always", options: [])
        let deny = UNNotificationAction(
            identifier: "PERM_deny_\(requestId)",
            title: "Deny", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [allowOnce, allowAlways, deny],
            intentIdentifiers: [], options: [])
        registerAndPost(category: category) { [weak self] in
            self?.pendingReplies[requestId] = PendingReply(options: [])
            self?.postInputNotification(
                title: "Permission Needed",
                message: toolName,
                subtitle: subtitle,
                categoryId: categoryId,
                requestId: requestId)
        }
    }

    // ── Input question (dynamic option buttons) ───────────────────────────────
    func handleInputQuestion(_ json: [String: Any]) {
        guard let requestId = json["request_id"] as? String,
            let options = json["options"] as? [String],
            !options.isEmpty
        else {
            print("daemon: input_question missing required fields")
            return
        }
        let question = json["question"] as? String ?? "Claude needs your input"
        let subtitle = json["subtitle"] as? String ?? ""
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: input_question id=\(requestId) options=\(options)")

        let categoryId = "CLAUDE_INPUT_\(requestId)"
        let actions = options.enumerated().map { (i, label) in
            UNNotificationAction(
                identifier: "CHOICE_\(i)_\(requestId)",
                title: label, options: [])
        }
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [], options: [])
        registerAndPost(category: category) { [weak self] in
            self?.pendingReplies[requestId] = PendingReply(options: options)
            self?.postInputNotification(
                title: "Claude Code",
                message: question,
                subtitle: subtitle,
                categoryId: categoryId,
                requestId: requestId)
        }
    }

    // ── Register a new category then post ─────────────────────────────────────
    func registerAndPost(category: UNNotificationCategory, then callback: @escaping () -> Void) {
        center.getNotificationCategories { [weak self] existing in
            guard let self = self else { return }
            var cats = existing
            cats.insert(category)
            self.center.setNotificationCategories(cats)
            // Brief delay so category registration takes effect before posting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { callback() }
        }
    }

    // ── Write reply file (polled by the hook script) ───────────────────────────
    func writeReply(requestId: String, content: String) {
        let replyPath = "/tmp/claude-input-reply-\(requestId)"
        do {
            try content.write(toFile: replyPath, atomically: true, encoding: .utf8)
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[\(ts)] daemon: wrote reply '\(content)' → \(replyPath)")
        } catch {
            fputs("daemon: failed to write reply: \(error.localizedDescription)\n", stderr)
        }
        pendingReplies.removeValue(forKey: requestId)
    }

    // ── Post an actionable (input/permission) notification ────────────────────
    func postInputNotification(
        title: String, message: String, subtitle: String,
        categoryId: String, requestId: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Ping.aiff"))
        content.categoryIdentifier = categoryId
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "input-\(requestId)",
            content: content, trigger: nil)
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: posting input notification category=\(categoryId)")
        center.add(request) { error in
            if let error = error {
                fputs(
                    "daemon: failed to post input notification: \(error.localizedDescription)\n",
                    stderr)
            }
        }
    }

    // ── Subagent lifecycle handlers (all on DispatchQueue.main) ───────────────
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
        rebuildMenu()
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
            postNotification(title: "Claude Code", message: message, subtitle: "", sound: "Ping")
            rebuildMenu()
        } else {
            // No SubagentStart was tracked — notify without count
            print("[\(ts)] daemon: subagent_stop with no tracked parent \(parentId)")
            postNotification(
                title: "Claude Code", message: "Subagent done", subtitle: "", sound: "Ping")
        }
    }

    func handleSessionStop(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        if agentSessions.removeValue(forKey: sessionId) != nil {
            print("[\(ts)] daemon: cleared subagent state for session \(sessionId)")
        }
        if sessions[sessionId] != nil {
            sessions[sessionId]!.isWorking = false
            print("[\(ts)] daemon: session idle id=\(sessionId)")
        }
        updateStatusTitle()
        updateSpinnerTimer()
        rebuildMenu()
    }

    // ── Notification posting ──────────────────────────────────────────────────
    func postNotification(title: String, message: String, subtitle: String, sound: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound + ".aiff"))
        content.categoryIdentifier = "CLAUDE_ACTION"
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        let postTs = ISO8601DateFormatter().string(from: Date())
        print("[\(postTs)] daemon: posting '\(message)'")
        center.add(request) { error in
            let doneTs = ISO8601DateFormatter().string(from: Date())
            if let error = error {
                fputs("[\(doneTs)] daemon: failed to post: \(error.localizedDescription)\n", stderr)
            } else {
                print("[\(doneTs)] daemon: notification handed to UNUserNotificationCenter")
            }
        }
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let daemon = ClaudeNotifierDaemon()
app.run()
