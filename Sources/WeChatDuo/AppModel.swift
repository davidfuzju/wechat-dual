import AppKit
import DuoCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let settings = Settings.shared
    let manager: CopyManager
    let healer: Healer
    private let work = DispatchQueue(label: "wechat-duo.ops")

    @Published var status: CopyStatus?
    @Published var busy: String?
    @Published var lastError: String?
    @Published var loginItemOn = LoginItem.isEnabled
    @Published var launchCopyAtLogin: Bool
    @Published var autoHeal: Bool
    @Published var color: String
    @Published var copyName: String

    static let presets: [(String, String)] = [
        ("Black", "#262626"), ("Gray", "#8e8e93"), ("Blue", "#1296db"), ("Purple", "#8e5cf7"),
        ("Pink", "#ff5fa2"), ("Red", "#e5484d"), ("Orange", "#ff8a00"), ("Original", "original"),
    ]

    init() {
        manager = CopyManager(settings: settings)
        healer = Healer(manager: manager)
        launchCopyAtLogin = settings.launchCopyAtLogin
        autoHeal = settings.autoHeal
        color = settings.color
        copyName = settings.copyName
    }

    var menuIcon: String {
        if busy != nil { return "arrow.triangle.2.circlepath" }
        switch status?.health {
        case .healthy?: return "bubble.left.and.bubble.right.fill"
        case .missing?, nil: return "bubble.left.and.bubble.right"
        default: return "exclamationmark.bubble.fill"
        }
    }

    /// Launch: migrate / adopt → first-run onboarding → health check → start the copy if configured.
    func start() {
        // The previous release had its own login item; take it over so repairs keep running after a restart.
        if Migration.run(into: settings) { setLoginItem(true) }
        color = settings.color
        copyName = settings.copyName
        launchCopyAtLogin = settings.launchCopyAtLogin
        autoHeal = settings.autoHeal
        Notifier.requestPermission()
        healer.onChange = { [weak self] in self?.refresh() }
        healer.onRepair = { [weak self] r in
            switch r {
            case .success(let msg): Notifier.post("WeChat copy repaired", msg)
            case .failure(let e): Notifier.post("WeChat copy repair failed", e.localizedDescription)
            }
            self?.refresh()
        }
        healer.start()

        if !settings.didOnboard { onboard() }
        let launchAfter = settings.launchCopyAtLogin
        perform("Startup check", silent: true) { m in
            if m.status().health.needsRepair, m.settings.autoHeal {
                try m.repair()
                DispatchQueue.main.async { Notifier.post("WeChat copy repaired", "The copy was overwritten by an update and has been repaired") }
            }
            if launchAfter, m.status(checkSignature: false).health == .healthy { try m.launch() }
        }
    }

    func refresh() {
        work.async { [manager] in
            let s = manager.status()
            DispatchQueue.main.async { self.status = s; self.loginItemOn = LoginItem.isEnabled }
        }
    }

    /// Runs an operation on the background serial queue, then refreshes the status.
    func perform(_ label: String, silent: Bool = false, _ body: @escaping (CopyManager) throws -> Void) {
        if busy != nil, !silent { return }
        busy = label
        lastError = nil
        work.async { [manager] in
            var err: String?
            do { try body(manager) } catch { err = error.localizedDescription }
            let s = manager.status()
            DispatchQueue.main.async {
                self.busy = nil
                self.status = s
                if let err { self.lastError = err; if !silent { Notifier.post("\(label) failed", err) } }
            }
        }
    }

    // MARK: Actions

    func createCopy() { perform("Creating copy…") { try $0.create(); try $0.launch() } }
    func repair() { perform("Repairing…") { try $0.repair() } }
    func sync() { perform("Syncing with WeChat…") { try $0.syncFromStock() } }
    func launchCopy() { perform("Starting…") { try $0.launch() } }
    func quitCopy() { perform("Quitting copy…") { $0.quit() } }

    func applyColor(_ c: String) {
        color = c
        if status?.health == .missing { settings.color = c; return }
        perform("Recoloring…") { try $0.recolor(c) }
    }

    func applyName() {
        let n = copyName
        perform("Renaming…") { try $0.rename(n) }
    }

    func setLaunchCopyAtLogin(_ on: Bool) { settings.launchCopyAtLogin = on; launchCopyAtLogin = on }
    func setAutoHeal(_ on: Bool) { settings.autoHeal = on; autoHeal = on }

    func setLoginItem(_ on: Bool) {
        if let err = LoginItem.setEnabled(on) { lastError = "Login item: \(err)" }
        if LoginItem.needsApproval {
            lastError = "Allow WeChat Duo in System Settings → General → Login Items"
            openLoginItemsSettings()
        }
        loginItemOn = LoginItem.isEnabled
    }

    func openLog() { NSWorkspace.shared.open(Paths.logFile) }

    // MARK: Onboarding

    private func onboard() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Welcome to WeChat Duo"
        let hasCopy = FileManager.default.fileExists(atPath: settings.copyURL.path)
        a.informativeText = hasCopy
            ? "Found the copy “\(settings.copyName)”. WeChat Duo will keep it working and repair it after WeChat updates overwrite it.\n\nOpen WeChat Duo at login? (Recommended — otherwise repairs stop after a restart.)"
            : "WeChat Duo will make a second WeChat, “\(settings.copyName)”, in your Applications folder (~/Applications). The original WeChat is not modified.\n\nAlso open WeChat Duo at login? (Recommended.)"
        a.addButton(withTitle: hasCopy ? "Open at Login" : "Create Copy & Open at Login")
        a.addButton(withTitle: hasCopy ? "Not Now" : "Create Copy Only")
        a.addButton(withTitle: "Later")
        let r = a.runModal()
        if r == .alertThirdButtonReturn { return }
        settings.didOnboard = true
        if r == .alertFirstButtonReturn { setLoginItem(true) }
        if !hasCopy { createCopy() }
    }

    // MARK: Uninstall

    func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Uninstall WeChat Duo?"
        a.informativeText = "The copy “\(settings.copyName)” is moved to the Trash, WeChat Duo's login item and settings are removed, and WeChat Duo itself is moved to the Trash. The original WeChat is not affected."
        let box = NSButton(checkboxWithTitle: "Also delete the copy's chat history and data (~/Library/Containers/\(Settings.copyBundleID))", target: nil, action: nil)
        box.state = .off
        a.accessoryView = box
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let deleteData = box.state == .on
        if deleteData {
            let c = NSAlert()
            c.alertStyle = .critical
            c.messageText = "Delete the copy's chat data?"
            c.informativeText = "The data folder goes to the Trash and cannot be recovered once the Trash is emptied."
            c.addButton(withTitle: "Delete Data")
            c.addButton(withTitle: "Keep Data")
            if c.runModal() != .alertFirstButtonReturn { return uninstallRun(deleteData: false) }
        }
        uninstallRun(deleteData: deleteData)
    }

    private func uninstallRun(deleteData: Bool) {
        healer.stop()
        perform("Uninstalling…") { m in
            try Uninstaller.run(manager: m, deleteData: deleteData)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Uninstall: copy (optionally with data) → login item → settings → log → the app itself, all to the Trash.
/// Shared by the UI and `--cli uninstall`.
enum Uninstaller {
    static func run(manager m: CopyManager, deleteData: Bool) throws {
        try m.removeCopy(deleteData: deleteData)
        LoginItem.setEnabled(false)
        m.settings.reset()
        let fm = FileManager.default
        let me = Bundle.main.bundleURL
        if me.pathExtension == "app" {
            try? fm.trashItem(at: me, resultingItemURL: nil)
            Log.write("Moved WeChat Duo to Trash: \(me.path)")
        }
        Log.write("Uninstall complete")
        try? fm.trashItem(at: Paths.logFile, resultingItemURL: nil)
        // When started from the CLI, also stop the running menu bar instance
        let myPid = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != myPid {
                kill(app.processIdentifier, SIGTERM)
            }
        }
    }
}

private func openLoginItemsSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}
