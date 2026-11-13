import AppKit
import DuoCore
import Foundation

@main
enum EntryPoint {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--cli" {
            exit(CLI.run(Array(args.dropFirst())))
        }
        WeChatDuoApp.main()
    }
}

/// Headless commands for troubleshooting and automated checks:
/// `"WeChat Duo.app/Contents/MacOS/WeChatDuo" --cli status`
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        Log.echo = { print($0) }
        let settings = Settings.shared
        let m = CopyManager(settings: settings)
        let cmd = args.first ?? "help"
        do {
            switch cmd {
            case "status":
                let s = m.status()
                print("""
                copy        \(s.copyPath)
                health      \(s.health.label)
                copy ver    \(s.copyVersion ?? "-")   bundle id \(s.copyBundleID ?? "-")
                WeChat ver  \(s.stockVersion ?? "-")\(s.outdated ? " (newer than the copy, can sync)" : "")
                running     \(s.running ? "yes" : "no")
                color       \(settings.color)   name \(settings.copyName)
                start copy at login \(settings.launchCopyAtLogin ? "on" : "off")   auto-repair \(settings.autoHeal ? "on" : "off")
                """)
            case "adopt": Migration.run(into: settings)
            case "create": try m.create()
            case "repair": try m.repair()
            case "sync": try m.syncFromStock()
            case "recolor": try m.recolor(try arg(args, 1, "recolor <#rrggbb|original>"))
            case "rename": try m.rename(try arg(args, 1, "rename <name>"))
            case "launch": try m.launch()
            case "quit": m.quit()
            case "set":
                let key = try arg(args, 1, "set <launchCopyAtLogin|autoHeal> <on|off>")
                let on = try arg(args, 2, "set <key> <on|off>") == "on"
                switch key {
                case "launchCopyAtLogin": settings.launchCopyAtLogin = on
                case "autoHeal": settings.autoHeal = on
                default: throw DuoError("Unknown setting \(key)")
                }
            case "preview":
                let color = try arg(args, 1, "preview <#rrggbb> <out.png>")
                let out = URL(fileURLWithPath: try arg(args, 2, "preview <#rrggbb> <out.png>"))
                guard let img = IconPreview.render(color: color, size: 512) else { throw DuoError("Render failed") }
                try IconRecolor.writePNG(img, to: out)
            case "make-icon":
                // Build step: draw this app's own icon (no WeChat artwork)
                try IconRecolor.writeICNS(AppIconArt.render(), to: URL(fileURLWithPath: try arg(args, 1, "make-icon <out.icns>")))
            case "watch":
                // Run the auto-repair watcher in the foreground; Ctrl-C to stop
                let h = Healer(manager: m)
                h.quietPeriod = Double(args.dropFirst().first ?? "") ?? 15
                h.onRepair = { r in print("repair result: \(r)") }
                h.start()
                print("watching \(settings.copyURL.path)…")
                RunLoop.main.run()
            case "uninstall":
                try Uninstaller.run(manager: m, deleteData: args.contains("--delete-data"))
            default:
                print("usage: --cli status|adopt|create|repair|sync|recolor <color>|rename <name>|launch|quit|set <key> <on|off>|preview <color> <png>|watch [quiet-seconds]|uninstall [--delete-data]")
                return cmd == "help" ? 0 : 2
            }
            return 0
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    static func arg(_ a: [String], _ i: Int, _ usage: String) throws -> String {
        guard a.count > i else { throw DuoError("usage: \(usage)") }
        return a[i]
    }
}
