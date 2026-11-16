import AppKit
import UserNotifications

/// Keeps the Mac awake while an agent works: no idle sleep and no App Nap, so a run at night doesn't stop halfway.
/// The display may still go dark. Closing the lid of a laptop sleeps it anyway, unless it runs on power with a screen.
@MainActor
final class AgentAwake {
    private var activity: NSObjectProtocol?
    private(set) var reason: String?

    var isHolding: Bool { activity != nil }

    func hold(_ reason: String) {
        self.reason = reason
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    func release() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        reason = nil
    }
}

/// Sending the Mac to sleep after a run, and knowing whether someone is at it.
enum MacSleep {
    /// Seconds since the last key press, click or mouse move.
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// `pmset sleepnow` needs no administrator and no permission dialog, unlike asking System Events.
    static func sleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }
}

/// Notifications of macOS for "wartet auf dich" and "fertig". Only in the app itself: a test runner has no bundle,
/// and the notification center stops a process without one.
enum AgentNotifier {
    private static var asked = false

    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
