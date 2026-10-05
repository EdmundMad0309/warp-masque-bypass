// WARP 开关 —— 自包含的 macOS App：内置 usque + sing-box，桌面窗口 + 菜单栏
import Cocoa
import SwiftUI
import Combine

// MARK: - 路径

let HOME = NSHomeDirectory()
let LA = HOME + "/Library/LaunchAgents"                       // 放在这里 = 登录时自动启动
let SUPPORT = HOME + "/Library/Application Support/WarpSwitch" // 账号、配置、内置程序都放这里
let BIN = SUPPORT + "/bin"
let LOGS = SUPPORT + "/logs"
let MASTER_DIR = SUPPORT + "/launchd"                         // 服务配置母版(关闭自启时也保留)
let ACCOUNT = SUPPORT + "/config.json"                        // usque 的 WARP 账号(含私钥)
let SETTINGS = SUPPORT + "/settings.json"
let SINGBOX_CFG = SUPPORT + "/singbox.json"
let SERVICES = ["com.warp.usque", "com.warp.singbox"]
let APP_AGENT = "com.warp.switch.login"                       // 登录时在后台打开本 App
let HELPERS = Bundle.main.bundlePath + "/Contents/Helpers"
let DEFAULT_SNI = "www.cloudflare.com"
let USQUE_PORT = 1080, PROXY_PORT = 7890
let UIDS = String(getuid())
let FM = FileManager.default
let SHOW_NOTE = Notification.Name("com.warp.switch.show")

// MARK: - 工具函数

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
    let out = sh("curl -s --max-time 5 -x http://127.0.0.1:\(PROXY_PORT) https://www.cloudflare.com/cdn-cgi/trace").out
    var d: [String: String] = [:]
    for line in out.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1)
        if kv.count == 2 { d[String(kv[0])] = String(kv[1]) }
    }
    return d
}
func readPlist(_ path: String) -> [String: Any]? {
    guard let d = FM.contents(atPath: path) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
}
/// 写文件，内容没变就不写；返回是否有变化
@discardableResult
func writeIfChanged(_ data: Data, _ path: String, mode: Int = 0o644) -> Bool {
    if FM.contents(atPath: path) == data { return false }
    FM.createFile(atPath: path, contents: data, attributes: [.posixPermissions: mode])
    return true
}
func plistData(_ d: [String: Any]) -> Data {
    (try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)) ?? Data()
}
func autostartOn() -> Bool { SERVICES.allSatisfy { FM.fileExists(atPath: "\(LA)/\($0).plist") } }
func plistPath(_ l: String) -> String {
    let la = "\(LA)/\(l).plist"
    return FM.fileExists(atPath: la) ? la : "\(MASTER_DIR)/\(l).plist"
}
/// 重新加载一个 launchd 服务(bootout 后 bootstrap，带重试)
func reload(_ l: String) {
    sh("launchctl bootout gui/\(UIDS)/\(l) 2>/dev/null; launchctl enable gui/\(UIDS)/\(l)")
    for _ in 0..<6 {
        if sh("launchctl bootstrap gui/\(UIDS) \(q(plistPath(l)))").code == 0 { return }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
let CLEAR_PROXY = #"""
networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while read -r s; do
  networksetup -getwebproxy "$s"           | grep -q "Port: 7890" && networksetup -setwebproxystate "$s" off
  networksetup -getsecurewebproxy "$s"     | grep -q "Port: 7890" && networksetup -setsecurewebproxystate "$s" off
  networksetup -getsocksfirewallproxy "$s" | grep -q "Port: 7890" && networksetup -setsocksfirewallproxystate "$s" off
done; true
"""#

// MARK: - 设置

func loadSNI() -> String {
    if let d = FM.contents(atPath: SETTINGS),
       let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
       let s = j["sni"] as? String, !s.isEmpty { return s }
    // 第一次运行：沿用旧版安装里设置的 SNI
    if let pl = readPlist("\(LA)/com.warp.usque.plist"), let a = pl["ProgramArguments"] as? [String],
       let i = a.firstIndex(of: "-s"), i + 1 < a.count { return a[i + 1] }
    return DEFAULT_SNI
}
func saveSNI(_ s: String) {
    let d = (try? JSONSerialization.data(withJSONObject: ["sni": s], options: [.prettyPrinted])) ?? Data()
    writeIfChanged(d, SETTINGS)
}

// MARK: - 安装 / 迁移 / 生成配置

/// 应用是否在 DMG 或"App 转移"(未移动到 应用程序 文件夹)状态下运行
func runningFromTemporaryLocation() -> Bool {
    let p = Bundle.main.bundlePath
    return p.contains("/AppTranslocation/") || p.hasPrefix("/Volumes/")
}

/// 从旧版(命令行版)安装中找到 WARP 账号，避免重复注册
func legacyAccount() -> String? {
    var c: [String] = []
    if let s = try? String(contentsOfFile: SUPPORT + "/base", encoding: .utf8) {
        c.append(s.trimmingCharacters(in: .whitespacesAndNewlines) + "/usque/config.json")
    }
    if let pl = readPlist("\(LA)/com.warp.usque.plist"), let a = pl["ProgramArguments"] as? [String],
       let i = a.firstIndex(of: "-c"), i + 1 < a.count { c.append(a[i + 1]) }
    c.append(HOME + "/warp-singbox/usque/config.json")
    return c.first { $0 != ACCOUNT && FM.fileExists(atPath: $0) }
}

/// 把 App 内置的程序复制到 BIN；返回是否有更新
func installHelpers() -> Bool {
    var changed = false
    for name in ["usque", "sing-box"] {
        let src = HELPERS + "/" + name, dst = BIN + "/" + name
        guard FM.fileExists(atPath: src) else { continue }
        if FM.fileExists(atPath: dst) && FM.contentsEqual(atPath: src, andPath: dst) { continue }
        try? FM.removeItem(atPath: dst)              // 正在运行的旧进程不受影响(仍持有旧文件)
        do { try FM.copyItem(atPath: src, toPath: dst) } catch { continue }
        removexattr(dst, "com.apple.quarantine", 0)
        chmod(dst, 0o755)
        changed = true
    }
    return changed
}
func helpersReady() -> Bool { ["usque", "sing-box"].allSatisfy { FM.isExecutableFile(atPath: BIN + "/" + $0) } }

func usquePlist(_ sni: String) -> [String: Any] {[
    "Label": "com.warp.usque",
    "ProgramArguments": [BIN + "/usque", "-c", ACCOUNT, "socks", "-b", "127.0.0.1", "-p", String(USQUE_PORT), "--http2", "-s", sni],
    "WorkingDirectory": SUPPORT,
    "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5,
    "StandardOutPath": LOGS + "/usque.log", "StandardErrorPath": LOGS + "/usque.log",
]}
func singboxPlist() -> [String: Any] {[
    "Label": "com.warp.singbox",
    "ProgramArguments": [BIN + "/sing-box", "run", "-c", SINGBOX_CFG],
    "WorkingDirectory": SUPPORT,
    "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5,
    "StandardOutPath": LOGS + "/singbox.log", "StandardErrorPath": LOGS + "/singbox.log",
]}
func singboxConfig() -> Data {
    let cfg: [String: Any] = [
        "log": ["level": "warn", "timestamp": true],
        "inbounds": [["type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": PROXY_PORT, "set_system_proxy": true]],
        "outbounds": [
            ["type": "socks", "tag": "warp-masque", "server": "127.0.0.1", "server_port": USQUE_PORT, "version": "5"],
            ["type": "direct", "tag": "direct"],
        ],
        "route": ["rules": [["action": "sniff"], ["ip_is_private": true, "outbound": "direct"]], "final": "warp-masque"],
    ]
    return (try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])) ?? Data()
}
func loginAgentData() -> Data {
    plistData(["Label": APP_AGENT,
               "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--background"],
               "RunAtLoad": true])
}

/// 生成所有配置；开着自启时同步到 LaunchAgents。返回内容有变化的服务
func writeConfigs() -> Set<String> {
    var changed = Set<String>()
    let sni = loadSNI()
    saveSNI(sni)
    if writeIfChanged(singboxConfig(), SINGBOX_CFG) { changed.insert("com.warp.singbox") }
    let plists = ["com.warp.usque": plistData(usquePlist(sni)), "com.warp.singbox": plistData(singboxPlist())]
    let auto = autostartOn()
    for (l, d) in plists {
        if writeIfChanged(d, "\(MASTER_DIR)/\(l).plist") { changed.insert(l) }
        if auto && writeIfChanged(d, "\(LA)/\(l).plist") { changed.insert(l) }
    }
    if auto { writeIfChanged(loginAgentData(), "\(LA)/\(APP_AGENT).plist") }
    return changed
}

/// 启动时调用：准备目录、复制程序、迁移旧账号、生成配置；已在运行的服务如有变化则重启
func prepare() {
    for d in [SUPPORT, BIN, LOGS, MASTER_DIR, LA] { try? FM.createDirectory(atPath: d, withIntermediateDirectories: true) }
    chmod(SUPPORT, 0o700)
    let binChanged = installHelpers()
    if !FM.fileExists(atPath: ACCOUNT), let old = legacyAccount() {
        try? FM.copyItem(atPath: old, toPath: ACCOUNT)
    }
    if FM.fileExists(atPath: ACCOUNT) { chmod(ACCOUNT, 0o600) }
    for f in ["usque.log", "singbox.log"] {                    // 日志超过 5MB 就清空
        let p = LOGS + "/" + f
        if let s = (try? FM.attributesOfItem(atPath: p))?[.size] as? Int, s > 5_000_000 { truncate(p, 0) }
    }
    var changed = writeConfigs()
    if binChanged { changed.formUnion(SERVICES) }
    if FM.fileExists(atPath: ACCOUNT) {
        for l in SERVICES where changed.contains(l) && isLoaded(l) { reload(l) }
    }
}

// MARK: - 状态模型(窗口和菜单栏共用)

enum Phase { case checking, on, connecting, off, starting, stopping }

final class WarpModel: ObservableObject {
    @Published var phase: Phase = .checking
    @Published var autostart = autostartOn()
    @Published var ip = "—"
    @Published var colo = "—"
    @Published var sni = loadSNI()
    @Published var needsSetup = !FM.fileExists(atPath: ACCOUNT)
    @Published var registering = false
    @Published var errorText: String? = nil
    let temporaryLocation = runningFromTemporaryLocation()
    private var refreshing = false
    private var timer: Timer?
    private let worker = DispatchQueue(label: "warp.worker")

    var busy: Bool { phase == .starting || phase == .stopping }
    var running: Bool { phase == .on || phase == .connecting }

    init() {
        if !temporaryLocation {
            prepare()
            needsSetup = !FM.fileExists(atPath: ACCOUNT)
            if !helpersReady() { errorText = "安装包缺少内置组件(usque / sing-box)，请重新下载。" }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        if busy || refreshing || needsSetup || temporaryLocation { if needsSetup || temporaryLocation { phase = .off }; return }
        refreshing = true
        worker.async {
            let any = SERVICES.contains(where: isLoaded)
            let t = any ? trace() : [:]
            let p: Phase = !any ? .off : (t["warp"] == "on" ? .on : .connecting)
            DispatchQueue.main.async {
                self.refreshing = false
                self.autostart = autostartOn()
                self.sni = loadSNI()
                if self.busy { return }
                self.phase = p
                self.ip = p == .on ? (t["ip"] ?? "—") : "—"
                self.colo = p == .on ? (t["colo"] ?? "—") : "—"
                if p == .on { self.errorText = nil }
            }
        }
    }

    /// 首次使用：注册 WARP 设备账号
    func register() {
        if registering { return }
        registering = true; errorText = nil
        worker.async {
            let r = sh("cd \(q(SUPPORT)) && \(q(BIN + "/usque")) -c \(q(ACCOUNT)) register -a 2>&1 | tail -4")
            let ok = FM.fileExists(atPath: ACCOUNT)
            if ok { chmod(ACCOUNT, 0o600) }
            DispatchQueue.main.async {
                self.registering = false
                if ok {
                    self.needsSetup = false
                    self.start()
                } else {
                    self.errorText = "注册失败(可能当前网络无法访问 Cloudflare 接口)：\n" + r.out
                }
            }
        }
    }

    func start() {
        if busy || needsSetup { return }
        phase = .starting; errorText = nil
        worker.async {
            _ = writeConfigs()
            for l in SERVICES { reload(l) }
            var ok = false
            for _ in 0..<12 { Thread.sleep(forTimeInterval: 2); if trace()["warp"] == "on" { ok = true; break } }
            let log = ok ? "" : sh("tail -3 \(q(LOGS + "/usque.log")) | cut -c1-160").out
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
                for l in SERVICES {
                    let p = "\(LA)/\(l).plist"
                    try? FM.removeItem(atPath: p)
                    try FM.copyItem(atPath: "\(MASTER_DIR)/\(l).plist", toPath: p)
                    sh("launchctl enable gui/\(UIDS)/\(l)")
                }
                try loginAgentData().write(to: URL(fileURLWithPath: "\(LA)/\(APP_AGENT).plist"))
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

    func setSNI(_ s: String) {
        saveSNI(s); sni = s
        let wasRunning = isLoaded("com.warp.usque")
        worker.async {
            _ = writeConfigs()
            if wasRunning { reload("com.warp.usque") }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// 完全卸载：停止服务、删除自启项和所有数据(包括 WARP 账号)
    func uninstall() {
        for l in SERVICES.reversed() { sh("launchctl bootout gui/\(UIDS)/\(l) 2>/dev/null") }
        sh(CLEAR_PROXY)
        for l in SERVICES + [APP_AGENT] { try? FM.removeItem(atPath: "\(LA)/\(l).plist") }
        try? FM.removeItem(atPath: SUPPORT)
    }
}

// MARK: - 对话框

func promptSNI(current: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "修改伪装 SNI"
    a.informativeText = "TLS 握手里明文可见的域名。如果某天连不上，换一个常见、未被封锁的域名试试(例如 www.bing.com)。"
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    f.stringValue = current
    a.accessoryView = f
    a.addButton(withTitle: "保存"); a.addButton(withTitle: "恢复默认"); a.addButton(withTitle: "取消")
    a.window.initialFirstResponder = f
    switch a.runModal() {
    case .alertFirstButtonReturn:
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ok = s.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil
        if !ok { let e = NSAlert(); e.messageText = "“\(s)” 不是有效的域名"; e.runModal(); return nil }
        return s
    case .alertSecondButtonReturn: return DEFAULT_SNI
    default: return nil
    }
}

func confirmUninstall() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = "完全卸载 WARP 开关？"
    a.informativeText = "会停止连接、关闭开机自启，并删除本机保存的 WARP 账号和全部配置。之后把 App 拖到废纸篓即可。"
    a.addButton(withTitle: "卸载"); a.addButton(withTitle: "取消")
    a.buttons.first?.hasDestructiveAction = true
    return a.runModal() == .alertFirstButtonReturn
}

/// 从 DMG / 下载文件夹 运行时：复制到 /Applications 并重新打开
func moveToApplications() {
    let name = Bundle.main.bundleURL.lastPathComponent
    let dest = "/Applications/" + name
    do {
        if FM.fileExists(atPath: dest) { try FM.removeItem(atPath: dest) }
        try FM.copyItem(atPath: Bundle.main.bundlePath, toPath: dest)
        sh("xattr -dr com.apple.quarantine \(q(dest)) 2>/dev/null; (sleep 1; open \(q(dest))) >/dev/null 2>&1 &")
        NSApp.terminate(nil)
    } catch {
        let a = NSAlert()
        a.messageText = "无法自动移动"
        a.informativeText = "请手动把「\(name)」拖到“应用程序”文件夹后再打开。\n\n\(error.localizedDescription)"
        a.runModal()
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


struct SetupView: View {
    @ObservedObject var m: WarpModel
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text(m.temporaryLocation ? "请先安装到“应用程序”" : "欢迎使用 WARP 开关").font(.title2.weight(.semibold))
            if m.temporaryLocation {
                Text("App 现在是从磁盘映像或下载文件夹里直接运行的。为了能开机自启，需要先放到“应用程序”文件夹。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { moveToApplications() } label: {
                    Text("移到“应用程序”并重新打开").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("首次使用需要注册一个免费的 Cloudflare WARP 设备账号。账号只保存在这台 Mac 上。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Link("查看 Cloudflare 服务条款", destination: URL(string: "https://www.cloudflare.com/application/terms/")!)
                    .font(.callout)
                Button { m.register() } label: {
                    HStack(spacing: 8) {
                        if m.registering { ProgressView().controlSize(.small) }
                        Text(m.registering ? "正在注册…" : "同意条款并注册").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(m.registering || !helpersReady())
            }
            if let e = m.errorText {
                Text(e).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding(28)
        .frame(width: 360)
    }
}

struct RootView: View {
    @ObservedObject var m: WarpModel
    var body: some View {
        if m.needsSetup || m.temporaryLocation { SetupView(m: m) } else { ContentView(m: m) }
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
                            HStack(spacing: 6) {
                                InfoRow(label: "伪装 SNI", value: m.sni)
                                Button {
                                    if let s = promptSNI(current: m.sni) { m.setSNI(s) }
                                } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("修改伪装 SNI")
                                .disabled(m.busy)
                            }
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
                    NSWorkspace.shared.open(URL(fileURLWithPath: LOGS))
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
        a.isEnabled = !model.needsSetup
        menu.items.filter { $0.title == "开启" || $0.title == "关闭" }.forEach { if model.needsSetup { $0.isEnabled = false } }
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
    @objc func editSNI() { if let s = promptSNI(current: model.sni) { model.setSNI(s) } }
    @objc func uninstall() {
        guard confirmUninstall() else { return }
        model.uninstall()
        let a = NSAlert(); a.messageText = "已卸载"; a.informativeText = "数据和自启项都已删除。现在可以把 App 拖到废纸篓。"; a.runModal()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "WARP 开关"
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(m: model))
        w.contentView = host
        w.setContentSize(host.fittingSize)
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
        let sniItem = appMenu.addItem(withTitle: "修改伪装 SNI…", action: #selector(editSNI), keyEquivalent: ","); sniItem.target = self
        let unItem = appMenu.addItem(withTitle: "完全卸载…", action: #selector(uninstall), keyEquivalent: ""); unItem.target = self
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            w.setContentSize(w.contentView!.fittingSize)
            try? "\(w.windowNumber) \(NSStringFromRect(w.frame)) visible=\(w.isVisible)".write(toFile: path, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()