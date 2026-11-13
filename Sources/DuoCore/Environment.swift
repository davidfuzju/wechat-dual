import Foundation

/// Fixed paths and constants. The stock WeChat app is read-only and never written to.
public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let stockApp = URL(fileURLWithPath: "/Applications/WeChat.app")
    public static let userApplications = home.appendingPathComponent("Applications", isDirectory: true)
    public static let logFile = home.appendingPathComponent("Library/Logs/WeChatDuo.log")
    public static let preferencesDir = home.appendingPathComponent("Library/Preferences", isDirectory: true)
    public static let containersDir = home.appendingPathComponent("Library/Containers", isDirectory: true)
    public static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    /// Nested mini-program helper with its own bundle ID and icon; it needs the same ID / icon / signing treatment.
    public static let nestedAppRelative = "Contents/MacOS/WeChatAppEx.app"
}

/// User settings, stored in a fixed domain shared by the menu bar app and `--cli`.
public final class Settings {
    public static let suiteName = "com.tokendivers.wechatduo"
    public static let shared = Settings()

    public let defaults: UserDefaults
    public init(defaults: UserDefaults? = nil) {
        // Inside the packaged app the suite name equals our own bundle ID, which only works as `.standard`.
        self.defaults = defaults ?? (Bundle.main.bundleIdentifier == Settings.suiteName
            ? .standard : UserDefaults(suiteName: Settings.suiteName)!)
    }

    public static let defaultName = "WeChat Dual"
    public static let defaultColor = "#1296db"
    /// The copy's bundle ID. Its data lives in ~/Library/Containers/<this>; changing it means a brand-new WeChat.
    public static let copyBundleID = "com.tencent.xin2"

    public var copyName: String {
        get { defaults.string(forKey: "copyName") ?? Settings.defaultName }
        set { defaults.set(newValue, forKey: "copyName") }
    }
    /// "#rrggbb", or "original" for the stock green icon.
    public var color: String {
        get { defaults.string(forKey: "color") ?? Settings.defaultColor }
        set { defaults.set(newValue, forKey: "color") }
    }
    /// Start the copy when this app starts (i.e. at login).
    public var launchCopyAtLogin: Bool {
        get { defaults.object(forKey: "launchCopyAtLogin") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launchCopyAtLogin") }
    }
    /// Repair the copy automatically after an update overwrites it.
    public var autoHeal: Bool {
        get { defaults.object(forKey: "autoHeal") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoHeal") }
    }
    public var didOnboard: Bool {
        get { defaults.bool(forKey: "didOnboard") }
        set { defaults.set(newValue, forKey: "didOnboard") }
    }

    public var copyURL: URL {
        Paths.userApplications.appendingPathComponent("\(copyName).app", isDirectory: true)
    }

    public func reset() {
        defaults.removePersistentDomain(forName: Settings.suiteName)
    }
}

public enum Log {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    /// Extra sink (the CLI echoes to stdout).
    public static var echo: ((String) -> Void)?

    public static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        echo?(message)
        let url = Paths.logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}

public struct DuoError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

enum Shell {
    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
