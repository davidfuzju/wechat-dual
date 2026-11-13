import AppKit
import CoreServices
import Foundation

/// Watches the copy's folder; after the copy changes and things settle, checks its health and repairs it.
///
/// FSEvents on ~/Applications rather than a file descriptor on Info.plist: Sparkle replaces the whole bundle,
/// so a watch on the old inode goes stale. Our own changes (touching Info.plist, signing) emit events too;
/// they are filtered via `CopyManager.isBusy` / `lastOwnWrite`, and a check on a healthy copy does nothing.
public final class Healer {
    public let manager: CopyManager
    /// Repair result callback (main thread), used for notifications.
    public var onRepair: ((Result<String, Error>) -> Void)?
    /// Called (main thread) after anything that may change the status, used to refresh the UI.
    public var onChange: (() -> Void)?

    /// Sparkle takes a while to install; wait this long after the last event before checking.
    public var quietPeriod: TimeInterval = 15
    /// Fallback periodic check.
    public var pollInterval: TimeInterval = 600

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "wechat-duo.healer")
    private var pending: DispatchWorkItem?
    private var timer: DispatchSourceTimer?

    public init(manager: CopyManager) { self.manager = manager }

    public func start() {
        stop()
        let dir = Paths.userApplications.path as CFString
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<Healer>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            me.handle(paths: list)
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [dir] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.check(reason: "Periodic check") }
        t.resume()
        timer = t
    }

    public func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
        timer?.cancel(); timer = nil
        pending?.cancel(); pending = nil
    }

    private func handle(paths: [String]) {
        let prefix = manager.settings.copyURL.path
        guard paths.contains(where: { $0.hasPrefix(prefix) }) else { return }
        // Ignore our own changes (in progress, or just finished — FSEvents lags a little)
        if manager.isBusy || Date().timeIntervalSince(manager.lastOwnWrite) < 8 { return }
        schedule(after: quietPeriod, reason: "Copy changed")
    }

    public func schedule(after delay: TimeInterval, reason: String) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.check(reason: reason) }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Synchronous check on the healer queue.
    private func check(reason: String) {
        defer { DispatchQueue.main.async { self.onChange?() } }
        guard manager.settings.autoHeal, !manager.isBusy else { return }
        let st = manager.status()
        guard st.health.needsRepair else { return }
        Log.write("\(reason): \(st.health.label), repairing")
        do {
            // After an overwrite Sparkle usually quits the copy or relaunches it as the official app;
            // if "start copy at login" is on, bring it back up after repairing.
            try manager.repair(relaunch: manager.settings.launchCopyAtLogin ? true : nil)
            let msg = "\(st.health.label) — repaired" + (st.copyVersion.map { " (\($0))" } ?? "")
            DispatchQueue.main.async { self.onRepair?(.success(msg)) }
        } catch {
            DispatchQueue.main.async { self.onRepair?(.failure(error)) }
        }
    }
}

/// First-run adoption: take over an existing copy and migrate from the previous release of this app.
public enum Migration {
    /// Bundle ID of the previous release (renamed since).
    static let previousAppID = "com.tokendivers.wechatdualhelper"

    /// Finds an existing copy (an .app in ~/Applications with the copy's bundle ID); returns its name without ".app".
    public static func existingCopyName() -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: Paths.userApplications, includingPropertiesForKeys: nil) else { return nil }
        for app in items where app.pathExtension == "app" {
            if Plist.string(app.appendingPathComponent("Contents/Info.plist"), "CFBundleIdentifier") == Settings.copyBundleID {
                return app.deletingPathExtension().lastPathComponent
            }
        }
        return nil
    }

    /// Returns true when settings were migrated from the previous release.
    @discardableResult
    public static func run(into settings: Settings) -> Bool {
        let migrated = migratePreviousApp(into: settings)
        if settings.defaults.string(forKey: "copyName") == nil, let name = existingCopyName() {
            settings.copyName = name
            Log.write("Adopted existing copy: \(name).app")
        }
        return migrated
    }

    /// Copies settings from the previous release, stops it and moves it to the Trash.
    static func migratePreviousApp(into settings: Settings) -> Bool {
        let fm = FileManager.default
        var migrated = false
        if let old = UserDefaults(suiteName: previousAppID), let dict = old.persistentDomain(forName: previousAppID), !dict.isEmpty {
            for key in ["copyName", "color", "launchCopyAtLogin", "autoHeal", "didOnboard"] where settings.defaults.object(forKey: key) == nil {
                if let v = dict[key] { settings.defaults.set(v, forKey: key) }
            }
            old.removePersistentDomain(forName: previousAppID)
            Log.write("Migrated settings from the previous release")
            migrated = true
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: previousAppID) {
            kill(app.processIdentifier, SIGTERM)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previousAppID),
           url.path.hasPrefix("/Applications/") || url.path.hasPrefix(Paths.userApplications.path),
           fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
            Log.write("Moved the previous release to Trash: \(url.lastPathComponent)")
        }
        let oldLog = Paths.home.appendingPathComponent("Library/Logs/WeChatDualHelper.log")
        if fm.fileExists(atPath: oldLog.path) { try? fm.trashItem(at: oldLog, resultingItemURL: nil) }
        return migrated
    }
}
