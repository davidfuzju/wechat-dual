import AppKit
import Foundation

public enum Health: Equatable {
    case stockMissing        // WeChat is not installed
    case missing             // no copy yet
    case overwritten(String) // bundle ID reverted (usually Sparkle replaced the copy with the official build); current ID
    case badSignature        // signature no longer valid
    case nameDrift(String)   // display name reverted; current name
    case healthy

    public var needsRepair: Bool {
        switch self {
        case .overwritten, .badSignature, .nameDrift: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .stockMissing: return "WeChat not found"
        case .missing: return "No copy yet"
        case .overwritten: return "Overwritten by an update"
        case .badSignature: return "Signature invalid"
        case .nameDrift: return "Name was reset"
        case .healthy: return "Healthy"
        }
    }
}

public struct CopyStatus: Equatable {
    public var health: Health
    public var stockVersion: String?
    public var copyVersion: String?
    public var copyBundleID: String?
    public var running: Bool
    public var copyPath: String

    /// WeChat is newer than the copy, so the copy can be synced.
    public var outdated: Bool {
        guard health == .healthy, let s = stockVersion, let c = copyVersion else { return false }
        return s.compare(c, options: .numeric) == .orderedDescending
    }
}

/// Every operation on the copy. Changes only ever touch the copy's .app; the stock app is read-only;
/// the copy's data folder is only trashed when the user explicitly asks.
public final class CopyManager {
    public let settings: Settings
    private let opLock = NSLock()
    /// When our own last change to the copy finished. Our own touches / signing emit FSEvents the healer ignores.
    public private(set) var lastOwnWrite = Date.distantPast
    public private(set) var isBusy = false

    public init(settings: Settings = .shared) { self.settings = settings }

    var copy: URL { settings.copyURL }
    var nested: URL { copy.appendingPathComponent(Paths.nestedAppRelative) }
    var executable: URL { copy.appendingPathComponent("Contents/MacOS/WeChat") }
    var infoPlist: URL { copy.appendingPathComponent("Contents/Info.plist") }

    // MARK: Status

    public func status(checkSignature: Bool = true) -> CopyStatus {
        let fm = FileManager.default
        let stockInfo = Paths.stockApp.appendingPathComponent("Contents/Info.plist")
        let stockVersion = Plist.string(stockInfo, "CFBundleShortVersionString")
        var st = CopyStatus(health: .healthy, stockVersion: stockVersion, copyVersion: nil, copyBundleID: nil,
                            running: false, copyPath: copy.path)
        guard fm.fileExists(atPath: executable.path) else {
            st.health = fm.fileExists(atPath: Paths.stockApp.path) ? .missing : .stockMissing
            return st
        }
        let info = Plist.read(infoPlist) ?? [:]
        st.copyVersion = info["CFBundleShortVersionString"] as? String
        st.copyBundleID = info["CFBundleIdentifier"] as? String
        st.running = runningCopy() != nil
        if st.copyBundleID != Settings.copyBundleID {
            st.health = .overwritten(st.copyBundleID ?? "?")
        } else if let name = info["CFBundleName"] as? String, name != settings.copyName {
            st.health = .nameDrift(name)
        } else if checkSignature, Shell.run("/usr/bin/codesign", ["--verify", copy.path]).status != 0 {
            st.health = .badSignature
        }
        return st
    }

    // MARK: Operations (serialized)

    private func exclusive<T>(_ what: String, _ body: () throws -> T) throws -> T {
        guard opLock.try() else { throw DuoError("Another operation is in progress, please wait") }
        isBusy = true
        Log.write("▶ \(what)")
        defer { isBusy = false; lastOwnWrite = Date(); opLock.unlock() }
        do {
            let r = try body()
            Log.write("✔ \(what)")
            return r
        } catch {
            Log.write("✘ \(what): \(error.localizedDescription)")
            throw error
        }
    }

    /// Copies the stock app and applies all customizations.
    public func create() throws {
        try exclusive("Create copy") {
            let fm = FileManager.default
            guard fm.fileExists(atPath: Paths.stockApp.path) else { throw DuoError("WeChat not found in /Applications. Install WeChat first.") }
            if fm.fileExists(atPath: copy.path) { throw DuoError("\(copy.path) already exists") }
            try fm.createDirectory(at: Paths.userApplications, withIntermediateDirectories: true)
            try fm.copyItem(at: Paths.stockApp, to: copy)
            _ = Shell.run("/usr/bin/defaults", ["write", Settings.copyBundleID, "AppleLanguages", "-array", "zh-Hans", "en"])
            try customize(relaunch: false)
        }
    }

    /// Repair after an overwrite / broken signature / reset name: rename → bundle ID → icon → sign → refresh caches.
    /// relaunch: nil = restore the previous running state; true = always start afterwards.
    public func repair(relaunch: Bool? = nil) throws {
        try exclusive("Repair copy") { try customize(relaunch: relaunch) }
    }

    /// Replaces the copy's .app with the current stock app (chat data lives in Containers and is kept), then customizes.
    public func syncFromStock() throws {
        try exclusive("Sync with WeChat") {
            let fm = FileManager.default
            let wasRunning = quitCopy()
            let staging = Paths.userApplications.appendingPathComponent(".\(settings.copyName)-staging.app")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: Paths.stockApp, to: staging)
            _ = try fm.replaceItemAt(copy, withItemAt: staging)
            try customize(relaunch: wasRunning)
        }
    }

    public func recolor(_ color: String) throws {
        if color != "original", RGB(hex: color) == nil { throw DuoError("Color must be #rrggbb") }
        try exclusive("Recolor \(color)") {
            settings.color = color
            let wasRunning = quitCopy()
            try applyIcon()
            try sign()
            refreshCaches()
            if wasRunning { try launchUnlocked() }
        }
    }

    /// Renames the copy: both the .app file name and the display name.
    public func rename(_ newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw DuoError("Invalid name") }
        guard name != "WeChat" else { throw DuoError("The copy cannot be named WeChat") }
        try exclusive("Rename to \(name)") {
            let fm = FileManager.default
            let old = copy
            let target = Paths.userApplications.appendingPathComponent("\(name).app")
            if old.path != target.path {
                if fm.fileExists(atPath: target.path) { throw DuoError("\(target.path) already exists") }
                let wasRunning = quitCopy()
                if fm.fileExists(atPath: old.path) {
                    try fm.moveItem(at: old, to: target)
                    _ = Shell.run(Paths.lsregister.path, ["-u", old.path])
                }
                settings.copyName = name
                if fm.fileExists(atPath: target.path) {
                    try applyName()
                    try sign()
                    refreshCaches()
                    if wasRunning { try launchUnlocked() }
                }
            } else {
                settings.copyName = name
            }
        }
    }

    public func launch() throws {
        try exclusive("Start copy") { try launchUnlocked() }
    }

    /// Quits the copy. Returns whether it was running.
    @discardableResult
    public func quit() -> Bool { quitCopy() }

    /// Removes the copy: its .app and preferences go to the Trash; with `deleteData` its chat data folder too.
    public func removeCopy(deleteData: Bool) throws {
        try exclusive("Remove copy\(deleteData ? " (with data)" : "")") {
            let fm = FileManager.default
            quitCopy()
            if fm.fileExists(atPath: copy.path) {
                _ = Shell.run(Paths.lsregister.path, ["-u", copy.path])
                try fm.trashItem(at: copy, resultingItemURL: nil)
                Log.write("Moved copy to Trash: \(copy.path)")
            }
            let prefs = Paths.preferencesDir.appendingPathComponent("\(Settings.copyBundleID).plist")
            if fm.fileExists(atPath: prefs.path) { try? fm.trashItem(at: prefs, resultingItemURL: nil) }
            if deleteData {
                let container = Paths.containersDir.appendingPathComponent(Settings.copyBundleID)
                if fm.fileExists(atPath: container.path) {
                    try fm.trashItem(at: container, resultingItemURL: nil)
                    Log.write("Moved copy data to Trash: \(container.path)")
                }
            }
        }
    }

    // MARK: Steps

    /// relaunch: nil = restore the previous running state; true/false = force.
    private func customize(relaunch: Bool?) throws {
        let wasRunning = quitCopy()
        try applyName()
        try assignIdentifier()
        do { try applyIcon() } catch { Log.write("Recolor failed (non-fatal): \(error.localizedDescription)") }
        try sign()
        refreshCaches()
        if relaunch ?? wasRunning { try launchUnlocked() }
    }

    private func assignIdentifier() throws {
        try Plist.update(infoPlist, ["CFBundleIdentifier": Settings.copyBundleID,
                                     // With this key the icon comes from Assets.car and the .icns is ignored
                                     "CFBundleIconName": nil])
        let nestedInfo = nested.appendingPathComponent("Contents/Info.plist")
        if var dict = Plist.read(nestedInfo), let id = dict["CFBundleIdentifier"] as? String {
            // The helper needs its own ID too, otherwise both instances share helper state and the
            // second window reuses the first account's session.
            if !id.hasSuffix(".dual") { dict["CFBundleIdentifier"] = id + ".dual" }
            dict.removeValue(forKey: "CFBundleIconName")
            try Plist.write(dict, to: nestedInfo)
        }
    }

    /// Display name: existing CFBundleName / CFBundleDisplayName in Info.plist and every InfoPlist.strings.
    private func applyName() throws {
        let name = settings.copyName
        var files = [infoPlist]
        let res = copy.appendingPathComponent("Contents/Resources")
        if let items = try? FileManager.default.contentsOfDirectory(at: res, includingPropertiesForKeys: nil) {
            for dir in items where dir.pathExtension == "lproj" {
                let f = dir.appendingPathComponent("InfoPlist.strings")
                if FileManager.default.fileExists(atPath: f.path) { files.append(f) }
            }
        }
        for f in files {
            try Plist.update(f, onlyExisting: true, ["CFBundleName": name, "CFBundleDisplayName": name])
        }
    }

    var iconTargets: [(copy: URL, stock: URL)] {
        [("Contents/Resources/AppIcon.icns", "Contents/Resources/AppIcon.icns"),
         (Paths.nestedAppRelative + "/Contents/Resources/app.icns", Paths.nestedAppRelative + "/Contents/Resources/app.icns")]
            .map { (copy.appendingPathComponent($0.0), Paths.stockApp.appendingPathComponent($0.1)) }
            .filter { FileManager.default.fileExists(atPath: $0.0.path) }
    }

    /// Rewrites the copy's icons in the configured color. The source is always the (read-only) stock icon,
    /// so no backups are needed.
    private func applyIcon() throws {
        let color = settings.color
        let targets = iconTargets
        guard !targets.isEmpty else { throw DuoError("The copy has no icon files to replace") }
        if color == "original" {
            for t in targets where FileManager.default.fileExists(atPath: t.stock.path) {
                try Data(contentsOf: t.stock).write(to: t.copy, options: .atomic)
            }
            return
        }
        guard let rgb = RGB(hex: color) else { throw DuoError("Invalid color: \(color)") }
        let source = Paths.stockApp.appendingPathComponent("Contents/Resources/AppIcon.icns")
        guard let master = IconRecolor.largestImage(in: source) else { throw DuoError("Cannot read the WeChat icon") }
        let (img, selected) = IconRecolor.recolor(master, to: rgb)
        guard selected > 0 else { throw DuoError("No green pixels found in the WeChat icon; the artwork may have changed") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-duo-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IconRecolor.writeICNS(img, to: tmp)
        let data = try Data(contentsOf: tmp)
        for t in targets { try data.write(to: t.copy, options: .atomic) }
    }

    /// Ad-hoc signs inside-out. Clears Finder metadata first, which makes codesign fail with "detritus".
    private func sign() throws {
        let fm = FileManager.default
        let iconFile = copy.appendingPathComponent("Icon\r")
        if fm.fileExists(atPath: iconFile.path) { try? fm.removeItem(at: iconFile) }
        _ = Shell.run("/usr/bin/xattr", ["-c", copy.path])
        var bundles = [copy]
        if fm.fileExists(atPath: nested.path) { bundles.insert(nested, at: 0) }
        for b in bundles {
            var r = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", b.path])
            if r.status != 0 {
                _ = Shell.run("/usr/bin/xattr", ["-cr", b.path])
                r = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", b.path])
            }
            if r.status != 0 { throw DuoError("Signing failed for \(b.lastPathComponent): \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
    }

    /// Makes the Dock / Finder show the new icon and name right away. Replacing only the .icns leaves the
    /// bundle's mtime unchanged and LaunchServices keeps its cache, so touch three places and re-register.
    private func refreshCaches() {
        let now = Date()
        for url in [copy, copy.appendingPathComponent("Contents"), infoPlist] {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
        for b in [copy, nested] where FileManager.default.fileExists(atPath: b.path) {
            _ = Shell.run(Paths.lsregister.path, ["-f", b.path])
        }
        _ = Shell.run("/usr/bin/killall", ["iconservicesagent"])
        _ = Shell.run("/usr/bin/killall", ["Dock"])
    }

    // MARK: Process

    /// PID of the copy's main process, matched by executable path (after an overwrite its bundle ID equals the
    /// stock app's). Uses libproc rather than NSWorkspace, which only refreshes on the main run loop.
    func runningCopy() -> pid_t? {
        let exe = executable.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf) == exe { return pid }
        }
        return nil
    }

    /// The copy must quit before re-signing. Asks politely (like ⌘Q), then SIGTERM after 15 s, SIGKILL after
    /// another 15 s. Returns whether it was running.
    @discardableResult
    private func quitCopy() -> Bool {
        guard let pid = runningCopy() else { return false }
        Log.write("Quitting copy (pid \(pid))")
        let alive = { kill(pid, 0) == 0 }
        if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() } else { kill(pid, SIGTERM) }
        func wait(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while alive() && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        }
        wait(15)
        if alive() {
            // WeChat sometimes ignores the quit request (e.g. a dialog is open); SIGTERM lets it clean up.
            Log.write("Copy did not quit within 15 s, sending SIGTERM")
            kill(pid, SIGTERM)
            wait(15)
        }
        if alive() {
            Log.write("Copy still running, killing it")
            kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 2)
        }
        return true
    }

    /// Runs Contents/MacOS/WeChat directly in a new session. `open` does not work: LaunchServices hands the
    /// request to the running instance and rejects it as a duplicate launch.
    private func launchUnlocked() throws {
        guard runningCopy() == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DuoError("No copy yet; create it first") }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        let path = executable.path
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, path, &fileActions, &attr, argv, environ)
        guard rc == 0 else { throw DuoError("Launch failed (\(rc))") }
        Log.write("Started copy (pid \(pid))")
    }
}
