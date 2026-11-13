import DuoCore
import Foundation
import ServiceManagement
import UserNotifications

/// The app's own login item (visible under System Settings → General → Login Items). Never writes LaunchAgents.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            Log.write("Login item \(on ? "enable" : "disable") failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}

enum Notifier {
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            if !ok { Log.write("Notifications not authorized\(err.map { ": \($0.localizedDescription)" } ?? "")") }
        }
    }

    static func post(_ title: String, _ body: String) {
        Log.write("Notify: \(title) — \(body)")
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                // Ad-hoc signed apps are often denied; fall back to a script notification so the user still sees it.
                fallback(title, body)
                return
            }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
                if err != nil { fallback(title, body) }
            }
        }
    }

    private static func fallback(_ title: String, _ body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"default\""]
        try? p.run()
    }
}
