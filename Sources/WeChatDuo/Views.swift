import AppKit
import DuoCore
import SwiftUI

struct WeChatDuoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("WeChat Duo Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

extension AppModel {
    static let shared = AppModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in AppModel.shared.start(); AppModel.shared.refresh() }
    }
}

// MARK: Menu bar panel

struct MenuContent: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconView(color: m.color, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.settings.copyName).font(.headline)
                    StatusLine(status: m.status, busy: m.busy)
                }
                Spacer()
            }
            if let s = m.status {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow { Text("Copy version").foregroundStyle(.secondary); Text(s.copyVersion ?? "—") }
                    GridRow { Text("WeChat version").foregroundStyle(.secondary); Text(s.stockVersion ?? "Not installed") }
                    GridRow { Text("Running").foregroundStyle(.secondary); Text(s.running ? "Yes" : "No") }
                }
                .font(.callout)
            }
            if let e = m.lastError {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            actions
            Divider()
            Toggle("Start copy at login", isOn: Binding(get: { m.launchCopyAtLogin }, set: { m.setLaunchCopyAtLogin($0) }))
            Toggle("Auto-repair after updates", isOn: Binding(get: { m.autoHeal }, set: { m.setAutoHeal($0) }))
            Divider()
            HStack {
                Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                Button("Log") { m.openLog() }
                Spacer()
                Button("Quit WeChat Duo") { NSApp.terminate(nil) }
                    .help("Stops auto-repair; the copy itself keeps running")
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { m.refresh() }
    }

    @ViewBuilder var actions: some View {
        let disabled = m.busy != nil
        switch m.status?.health {
        case .missing?:
            Button("Create Copy") { m.createCopy() }.buttonStyle(.borderedProminent).disabled(disabled)
        case .stockMissing?:
            Text("Install WeChat in /Applications first").font(.callout)
        case let h? where h.needsRepair:
            Button("Repair Now") { m.repair() }.buttonStyle(.borderedProminent).disabled(disabled)
        default:
            HStack {
                if m.status?.running == true {
                    Button("Quit Copy") { m.quitCopy() }.disabled(disabled)
                } else {
                    Button("Start Copy") { m.launchCopy() }.buttonStyle(.borderedProminent).disabled(disabled)
                }
                Button("Re-apply") { m.repair() }.disabled(disabled)
                    .help("Re-apply name, icon and signature, e.g. if the icon or name looks wrong")
            }
            if m.status?.outdated == true {
                Button("WeChat updated — sync copy") { m.sync() }.disabled(disabled)
            }
        }
    }
}

struct StatusLine: View {
    let status: CopyStatus?
    let busy: String?
    var body: some View {
        if let busy {
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text(busy) }.font(.caption)
        } else if let s = status {
            Label(s.health.label, systemImage: s.health == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(s.health == .healthy ? .green : .orange)
        } else {
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Recolor preview icon (rendered from the stock icon, never touches the copy).
struct IconView: View {
    let color: String
    let size: CGFloat
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1) .resizable() } else { Color.secondary.opacity(0.15) }
        }
        .frame(width: size, height: size)
        .task(id: color) {
            let c = color, px = Int(size * 2)
            image = await Task.detached { IconPreview.render(color: c, size: max(px, 64)) }.value
        }
    }
}

// MARK: Settings window

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var draftColor: Color = .black
    @State private var draftHex: String = ""

    var body: some View {
        Form {
            Section("Icon color") {
                HStack(alignment: .top, spacing: 18) {
                    VStack {
                        IconView(color: draftHex, size: 128)
                        Text("Preview").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 4), spacing: 8) {
                            ForEach(AppModel.presets, id: \.1) { name, hex in
                                Button { pick(hex) } label: {
                                    VStack(spacing: 2) {
                                        Circle().fill(hex == "original" ? Color(red: 0.03, green: 0.76, blue: 0.38) : Color(hexString: hex))
                                            .frame(width: 22, height: 22)
                                            .overlay(Circle().stroke(draftHex == hex ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                                        Text(name).font(.caption2)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack {
                            ColorPicker("Custom", selection: $draftColor, supportsOpacity: false)
                                .onChange(of: draftColor) { _, c in if let h = c.hexString { draftHex = h } }
                            TextField("#rrggbb", text: $draftHex).frame(width: 90).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button("Apply to Copy") { m.applyColor(draftHex) }
                                .buttonStyle(.borderedProminent)
                                .disabled(m.busy != nil || draftHex == m.color || !(draftHex == "original" || RGB(hex: draftHex) != nil))
                            if draftHex != m.color { Text("Current: \(m.color)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("Copy name") {
                HStack {
                    TextField("Name", text: $m.copyName).textFieldStyle(.roundedBorder)
                    Button("Rename") { m.applyName() }.disabled(m.busy != nil || m.copyName == m.settings.copyName)
                }
                Text("Shown in the Dock and Applications folder. Location: ~/Applications/\(m.settings.copyName).app")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Login") {
                Toggle("Open WeChat Duo at login (needed for auto-repair)", isOn: Binding(get: { m.loginItemOn }, set: { m.setLoginItem($0) }))
                Toggle("Start copy at login", isOn: Binding(get: { m.launchCopyAtLogin }, set: { m.setLaunchCopyAtLogin($0) }))
                    .disabled(!m.loginItemOn)
                Toggle("Auto-repair and notify after WeChat updates", isOn: Binding(get: { m.autoHeal }, set: { m.setAutoHeal($0) }))
            }
            Section {
                HStack {
                    if let s = m.status { Text("\(s.health.label) · copy \(s.copyVersion ?? "—") · WeChat \(s.stockVersion ?? "—")").font(.callout) }
                    Spacer()
                    Button("Uninstall…", role: .destructive) { m.uninstall() }.disabled(m.busy != nil)
                }
                if let e = m.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { draftHex = m.color; if let c = RGB(hex: m.color) { draftColor = Color(hexString: c.hex) }; m.refresh() }
    }

    private func pick(_ hex: String) {
        draftHex = hex
        if hex != "original" { draftColor = Color(hexString: hex) }
    }
}

extension Color {
    init(hexString: String) {
        let c = RGB(hex: hexString) ?? RGB(r: 0, g: 0, b: 0)
        self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    var hexString: String? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return RGB(r: UInt8((ns.redComponent * 255).rounded()), g: UInt8((ns.greenComponent * 255).rounded()),
                   b: UInt8((ns.blueComponent * 255).rounded())).hex
    }
}
