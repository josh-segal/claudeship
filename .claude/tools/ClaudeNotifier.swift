import Cocoa
import UserNotifications

let args = CommandLine.arguments
let title = args.count > 1 ? args[1] : "Claude Code"
let message = args.count > 2 ? args[2] : ""
let sound = args.count > 3 ? args[3] : "Ping"

let center = UNUserNotificationCenter.current()
center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
    guard granted else { exit(1) }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = message
    content.sound = UNNotificationSound(named: UNNotificationSoundName(sound + ".aiff"))

    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(request) { _ in exit(0) }
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
