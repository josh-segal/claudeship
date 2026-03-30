import Cocoa
import UserNotifications

let args = CommandLine.arguments

// ── check-focus mode ──────────────────────────────────────────────────────────
if args.count > 1 && args[1] == "check-focus" {
    let target    = args.count > 2 ? args[2].lowercased() : ""
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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == "OPEN_TERMINAL" {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.mitchellh.ghostty"
            ).first {
                app.activate(options: [.activateAllWindows])
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

class ClaudeNotifierDaemon: NSObject {
    let center      = UNUserNotificationCenter.current()
    let socketQueue = DispatchQueue(label: "com.claudeship.notifier.socket")
    let socketPath  = "/tmp/claude-notifier.sock"
    let logPath     = "/tmp/claude-notifier.log"
    let delegate    = NotificationDelegate()
    var serverSource: DispatchSourceRead?

    // ── Subagent state (all mutations on DispatchQueue.main) ──────────────────
    struct AgentSession {
        var total:     Int
        var completed: Int
        var agents:    [(id: String, name: String, done: Bool)]
    }
    var agentSessions: [String: AgentSession] = [:]

    override init() {
        super.init()
        center.delegate = delegate
        registerCategories()
        rotateLogIfNeeded()
        requestAuth()
        startListening()
    }

    // ── Log rotation ──────────────────────────────────────────────────────────
    func rotateLogIfNeeded() {
        let limit = 1_048_576  // 1 MB
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size  = attrs[.size] as? Int,
              size > limit
        else { return }
        let backup = logPath + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: logPath, toPath: backup)
        print("ClaudeNotifier: rotated log (\(size) bytes → \(backup))")
    }

    // ── Notification categories ───────────────────────────────────────────────
    func registerCategories() {
        let openAction = UNNotificationAction(identifier: "OPEN_TERMINAL",
                                              title: "Open Terminal", options: [])
        let category   = UNNotificationCategory(identifier: "CLAUDE_ACTION",
                                                actions: [openAction],
                                                intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func requestAuth() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                print("ClaudeNotifier: notifications authorized")
            } else {
                fputs("ClaudeNotifier: notification permission denied — grant access in System Settings\n", stderr)
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
            Darwin.bind(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
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
        var buf  = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(clientFd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }
        close(clientFd)

        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let ts      = ISO8601DateFormatter().string(from: Date())
        let msgType = json["type"] as? String ?? "notify"
        print("[\(ts)] daemon: received type=\(msgType)")

        switch msgType {
        case "subagent_start":
            DispatchQueue.main.async { [weak self] in self?.handleSubagentStart(json) }
        case "subagent_stop":
            DispatchQueue.main.async { [weak self] in self?.handleSubagentStop(json) }
        case "turn_stop":
            DispatchQueue.main.async { [weak self] in self?.handleSessionStop(json) }
        default:
            let title    = json["title"]    as? String ?? "Claude Code"
            let message  = json["message"]  as? String ?? ""
            let subtitle = json["subtitle"] as? String ?? ""
            let sound    = json["sound"]    as? String ?? "Ping"
            DispatchQueue.main.async { [weak self] in
                self?.postNotification(title: title, message: message,
                                       subtitle: subtitle, sound: sound)
            }
        }
    }

    // ── Subagent lifecycle handlers (all on DispatchQueue.main) ───────────────
    func handleSubagentStart(_ json: [String: Any]) {
        guard let parentId  = json["parent_session_id"] as? String,
              let agentId   = json["session_id"]        as? String
        else {
            print("daemon: subagent_start missing IDs — raw: \(json)")
            return
        }
        let agentName = json["agent_name"] as? String ?? ""
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] daemon: subagent_start parent=\(parentId) agent=\(agentId) name='\(agentName)'")

        if agentSessions[parentId] == nil {
            agentSessions[parentId] = AgentSession(total: 0, completed: 0, agents: [])
        }
        agentSessions[parentId]!.total += 1
        agentSessions[parentId]!.agents.append((id: agentId, name: agentName, done: false))
    }

    func handleSubagentStop(_ json: [String: Any]) {
        guard let agentId  = json["session_id"]        as? String,
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
                session.agents[idx].done = true
            }
            agentSessions[parentId] = session

            let progress = "(\(session.completed)/\(session.total))"
            let message  = "\(agentName) done \(progress)"
            print("[\(ts)] daemon: \(message) parent=\(parentId)")
            postNotification(title: "Claude Code", message: message, subtitle: "", sound: "Ping")
        } else {
            // No SubagentStart was tracked — notify without count
            print("[\(ts)] daemon: subagent_stop with no tracked parent \(parentId)")
            postNotification(title: "Claude Code", message: "Subagent done", subtitle: "", sound: "Ping")
        }
    }

    func handleSessionStop(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        if agentSessions.removeValue(forKey: sessionId) != nil {
            print("[\(ts)] daemon: cleared subagent state for session \(sessionId)")
        }
    }

    // ── Notification posting ──────────────────────────────────────────────────
    func postNotification(title: String, message: String, subtitle: String, sound: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = message
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound              = UNNotificationSound(named: UNNotificationSoundName(sound + ".aiff"))
        content.categoryIdentifier = "CLAUDE_ACTION"
        content.interruptionLevel  = .timeSensitive

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let postTs  = ISO8601DateFormatter().string(from: Date())
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
