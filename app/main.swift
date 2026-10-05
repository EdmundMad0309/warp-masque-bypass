// WARP 开关 —— 桌面窗口 + 菜单栏，控制 usque + sing-box 两个 launchd 服务
import Cocoa
import SwiftUI
import Combine

// MARK: - 后端

let HOME = NSHomeDirectory()
let LA = HOME + "/Library/LaunchAgents"            // 放在这里 = 登录时自动启动
let SERVICES = ["com.warp.usque", "com.warp.singbox"]
let SUPPORT = HOME + "/Library/Application Support/WarpSwitch"
let BASE_POINTER = SUPPORT + "/base"               // install.sh 写入的安装目录

// 安装目录(含 usque/、日志)：环境变量 > install.sh 写的指针文件 > 从现有 launchd 配置推断 > ~/warp-singbox
let BASE: String = {
    let fm = FileManager.default
    func valid(_ p: String) -> Bool { fm.fileExists(atPath: p + "/usque/config.json") }
    var candidates: [String] = []
    if let e = ProcessInfo.processInfo.environment["WARP_BASE"] { candidates.append(e) }
    if let s = try? String(contentsOfFile: BASE_POINTER, encoding: .utf8) {
        candidates.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let d = fm.contents(atPath: LA + "/com.warp.usque.plist"),
       let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
       let wd = pl["WorkingDirectory"] as? String {
        candidates.append((wd as NSString).deletingLastPathComponent)   // WorkingDirectory = <BASE>/usque
    }
    candidates.append(HOME + "/warp-singbox")
    let found = candidates.first(where: valid) ?? candidates.last!
    try? fm.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
    try? found.write(toFile: BASE_POINTER, atomically: true, encoding: .utf8)
    return found
}()
let MASTER_DIR = BASE + "/launchd"                 // 服务配置的母版(关闭自启时也保留)
let APP_AGENT = "com.warp.switch.login"            // 登录时在后台打开本 app(显示菜单栏图标)
let UIDS = String(getuid())
let FM = FileManager.default
let SHOW_NOTE = Notification.Name("com.warp.switch.show")

@discardableResult
func sh(_ cmd: String) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func isLoaded(_ l: String) -> Bool { sh("launchctl print gui/\(UIDS)/\(l) >/dev/null 2>&1").code == 0 }
func trace() -> [String: String] {
    let out = sh("curl -s --max-time 5 -x http://127.0.0.1:7890 https://www.cloudflare.com/cdn-cgi/trace").out
    var d: [String: String] = [:]
    for line in out.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1)
        if kv.count == 2 { d[String(kv[0])] = String(kv[1]) }
    }
    return d
}
func autostartOn() -> Bool { SERVICES.allSatisfy { FM.fileExists(atPath: "\(LA)/\($0).plist") } }
func plistPath(_ l: String) -> String {
    let la = "\(LA)/\(l).plist"
    return FM.fileExists(atPath: la) ? la : "\(MASTER_DIR)/\(l).plist"
}
func currentSNI() -> String {
    guard let data = FM.contents(atPath: plistPath("com.warp.usque")),
          let pl = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let args = pl["ProgramArguments"] as? [String],
          let i = args.firstIndex(of: "-s"), i + 1 < args.count else { return "默认" }
    return args[i + 1]
}
func ensureMasters() {
    try? FM.createDirectory(atPath: MASTER_DIR, withIntermediateDirectories: true)
    for l in SERVICES {
        let m = "\(MASTER_DIR)/\(l).plist", la = "\(LA)/\(l).plist"
        if !FM.fileExists(atPath: m) && FM.fileExists(atPath: la) { try? FM.copyItem(atPath: la, toPath: m) }
    }
}
let CLEAR_PROXY = #"""
networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while read -r s; do
  networksetup -getwebproxy "$s"           | grep -q "Port: 7890" && networksetup -setwebproxystate "$s" off
  networksetup -getsecurewebproxy "$s"     | grep -q "Port: 7890" && networksetup -setsecurewebproxystate "$s" off
  networksetup -getsocksfirewallproxy "$s" | grep -q "Port: 7890" && networksetup -setsocksfirewallproxystate "$s" off
done; true
"""#

// MARK: - 状态模型(窗口和菜单栏共用)

enum Phase { case checking, on, connecting, off, starting, stopping }

final class WarpModel: ObservableObject {
    @Published var phase: Phase = .checking
    @Published var autostart = autostartOn()
    @Published var ip = "—"
    @Published var colo = "—"
    @Published var sni = currentSNI()
    @Published var lastChecked: Date? = nil
    @Published var errorText: String? = nil
    private var refreshing = false
    private var timer: Timer?
    private let worker = DispatchQueue(label: "warp.worker")

    var busy: Bool { phase == .starting || phase == .stopping }
    var running: Bool { phase == .on || phase == .connecting }

    init() {
        ensureMasters()
        if autostartOn() && !FM.fileExists(atPath: "\(LA)/\(APP_AGENT).plist") { setAutostart(true) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        if busy || refreshing { return }
        refreshing = true
        worker.async {
            let any = SERVICES.contains(where: isLoaded)
            let t = any ? trace() : [:]
            let p: Phase = !any ? .off : (t["warp"] == "on" ? .on : .connecting)
            DispatchQueue.main.async {
                self.refreshing = false
                self.autostart = autostartOn()
                self.sni = currentSNI()
                self.lastChecked = Date()
                if self.busy { return }
                self.phase = p
                self.ip = p == .on ? (t["ip"] ?? "—") : "—"
                self.colo = p == .on ? (t["colo"] ?? "—") : "—"
                if p == .on { self.errorText = nil }
            }
        }
    }

    func start() {
        if busy { return }
        phase = .starting; errorText = nil
        worker.async {
            for l in SERVICES {
                sh("launchctl bootout gui/\(UIDS)/\(l) 2>/dev/null; launchctl enable gui/\(UIDS)/\(l); launchctl bootstrap gui/\(UIDS) \(q(plistPath(l)))")
            }
            var ok = false
            for _ in 0..<12 { Thread.sleep(forTimeInterval: 2); if trace()["warp"] == "on" { ok = true; break } }
            let log = ok ? "" : sh("tail -3 \(q(BASE + "/usque.log")) | cut -c1-160").out
            DispatchQueue.main.async {
                self.phase = .connecting
                if !ok { self.errorText = "24 秒内没有连上，后台会继续重连。\n" + log }
                self.refresh()
            }
        }
    }

    func stop() {
        if busy { return }
        phase = .stopping
        worker.async {
            for l in SERVICES.reversed() { sh("launchctl bootout gui/\(UIDS)/\(l) 2>/dev/null") }
            sh(CLEAR_PROXY)
            DispatchQueue.main.async { self.phase = .off; self.ip = "—"; self.colo = "—"; self.refresh() }
        }
    }

    func setAutostart(_ on: Bool) {
        do {
            if on {
                try FM.createDirectory(atPath: LA, withIntermediateDirectories: true)
                for l in SERVICES {
                    let p = "\(LA)/\(l).plist"
                    if !FM.fileExists(atPath: p) { try FM.copyItem(atPath: "\(MASTER_DIR)/\(l).plist", toPath: p) }
                    sh("launchctl enable gui/\(UIDS)/\(l)")
                }
                let agent: [String: Any] = [
                    "Label": APP_AGENT,
                    "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--background"],
                    "RunAtLoad": true,
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                try data.write(to: URL(fileURLWithPath: "\(LA)/\(APP_AGENT).plist"))
            } else {
                for l in SERVICES + [APP_AGENT] {
                    let p = "\(LA)/\(l).plist"
                    if FM.fileExists(atPath: p) { try FM.removeItem(atPath: p) }
                }
            }
            errorText = nil
        } catch {
            errorText = "修改开机自启失败：\(error.localizedDescription)"
        }
        autostart = autostartOn()
    }
}

// MARK: - 桌面窗口 UI

extension Phase {
    var title: String {
        switch self {
        case .checking: return "正在检查…"
        case .on: return "已连接"
        case .connecting: return "连接中…"
        case .off: return "未开启"
        case .starting: return "正在开启…"
        case .stopping: return "正在关闭…"
        }
    }
    var subtitle: String {
        switch self {
        case .on: return "流量正通过 Cloudflare WARP 加密传输"
        case .connecting: return "服务已启动，正在建立隧道"
        case .off: return "当前为直连，未使用 WARP"
        default: return " "
        }
    }
    var symbol: String {
        switch self {
        case .on: return "checkmark.shield.fill"
        case .off: return "shield.slash"
        default: return "shield.lefthalf.filled"
        }
    }
    var color: Color {
        switch self {
        case .on: return .green
        case .off: return .secondary
        default: return .orange
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .lineLimit(1).truncationMode(.middle)
                .font(.system(size: value.count > 22 ? 11 : 13, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct ContentView: View {
    @ObservedObject var m: WarpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── 标题行 ──────────────────────────────────────────
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WARP 开关").font(.headline)
                    Text("MASQUE · HTTP/2 · SNI 伪装")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 20)

            // ── 状态图标 ────────────────────────────────────────
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(m.phase.color.opacity(0.12))
                            .frame(width: 100, height: 100)
                        Circle()
                            .strokeBorder(m.phase.color.opacity(0.4), lineWidth: 2.5)
                            .frame(width: 100, height: 100)
                        if m.busy || m.phase == .checking {
                            ProgressView().controlSize(.large)
                        } else {
                            Image(systemName: m.phase.symbol)
                                .font(.system(size: 42, weight: .semibold))
                                .foregroundStyle(m.phase.color)
                        }
                    }
                    Text(m.phase.title).font(.title3.weight(.semibold))
                    Text(m.phase.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.2), value: m.phase)
            .padding(.bottom, 20)

            // ── 连接信息 ────────────────────────────────────────
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    .overlay(
                        VStack(spacing: 0) {
                            InfoRow(label: "出口 IP", value: m.ip)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                            Divider()
                            InfoRow(label: "节点", value: m.colo)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                            Divider()
                            InfoRow(label: "伪装 SNI", value: m.sni)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                            Divider()
                            InfoRow(label: "本机代理", value: "127.0.0.1:7890")
                                .padding(.horizontal, 12).padding(.vertical, 9)
                        }
                    )
                    .frame(height: 168)
            }
            .padding(.bottom, 16)

            // ── 主按钮 ──────────────────────────────────────────
            Button {
                m.running ? m.stop() : m.start()
            } label: {
                Text(m.running ? "关闭" : "开启")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(m.running ? .red : Color.accentColor)
            .disabled(m.busy || m.phase == .checking)
            .keyboardShortcut(.defaultAction)

            if m.phase == .connecting {
                HStack { Spacer(); Button("重新连接") { m.start() }.buttonStyle(.link); Spacer() }
                    .padding(.top, 4)
            }

            if let e = m.errorText {
                Text(e).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .textSelection(.enabled)
            }

            Divider().padding(.vertical, 14)

            // ── 开机自启 ────────────────────────────────────────
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开机自启").font(.body)
                    Text("登录时自动连接，并在菜单栏显示图标")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { m.autostart }, set: { m.setAutostart($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(m.busy)
            }
            .padding(.bottom, 12)

            // ── 底部按钮 ────────────────────────────────────────
            HStack {
                Button("打开日志") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: BASE))
                }
                Spacer()
                Button("退出 App") { NSApp.terminate(nil) }
                    .help("只关闭这个界面，不影响连接")
            }
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - App: 窗口 + 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = WarpModel()
    var window: NSWindow?
    var item: NSStatusItem!
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { snapshot(to: args[i + 1]); return }

        // 只保留一个实例；重复打开时让已有实例显示窗口
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(SHOW_NOTE, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        DistributedNotificationCenter.default().addObserver(forName: SHOW_NOTE, object: nil, queue: .main) { [weak self] _ in self?.showWindow() }

        buildMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        model.$phase.receive(on: RunLoop.main).sink { [weak self] p in
            let img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: "WARP")
            img?.isTemplate = true
            self?.item.button?.image = img
            self?.item.button?.toolTip = "WARP 开关 — " + p.title
        }.store(in: &bag)

        if !args.contains("--background") { showWindow() }
    }

    // 菜单栏下拉菜单(每次打开时按当前状态重建)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = NSMenuItem(title: "状态：" + model.phase.title, action: nil, keyEquivalent: ""); s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())
        add(menu, "打开主窗口", #selector(showWindow))
        add(menu, "开启", #selector(startW)).isEnabled = !model.busy && !model.running
        add(menu, "关闭", #selector(stopW)).isEnabled = !model.busy && model.running
        menu.addItem(.separator())
        let a = add(menu, "开机自启", #selector(toggleAuto)); a.state = model.autostart ? .on : .off
        menu.addItem(.separator())
        add(menu, "退出 App（不影响连接）", #selector(quit))
    }
    @discardableResult
    func add(_ m: NSMenu, _ t: String, _ s: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; m.addItem(i); return i
    }
    @objc func startW() { model.start() }
    @objc func stopW() { model.stop() }
    @objc func toggleAuto() { model.setAutostart(!model.autostart) }
    @objc func quit() { NSApp.terminate(nil) }

    func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "WARP 开关"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ContentView(m: model))
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        return w
    }

    @objc func showWindow() {
        if window == nil { window = makeWindow(); window?.delegate = self }
        NSApp.setActivationPolicy(.regular)          // 窗口打开时显示 Dock 图标
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh()
    }
    func windowWillClose(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)        // 关掉窗口后只留菜单栏图标
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WARP 开关", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 WARP 开关", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    // 调试用：把窗口内容渲染成 PNG
    func snapshot(to path: String) {
        let w = makeWindow()
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? String(w.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
