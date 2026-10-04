// AgentWatchdog — Claude Code 看门狗 MVP
// 监控 ~/.claude/projects 的真实用量 → 今日/7日 $ 估算 → 超预算熔断(通知 + AGENT_STOP + hook 阻断)
// ponytail: 定价表硬编码于此，Anthropic 调价改这里；15s 全量重扫在 56 文件规模没问题，>1万文件需换增量
import SwiftUI
import Foundation

// MARK: - 计价（USD / 1M tokens）
let priceTable: [(key: String, input: Double, output: Double)] = [
    ("opus", 15, 75), ("sonnet", 3, 15), ("haiku", 0.8, 4),
]

func unitPrice(_ model: String) -> (input: Double, output: Double) {
    let m = model.lowercased()
    for p in priceTable where m.contains(p.key) { return (p.input, p.output) }
    return (3, 15) // 未知模型按 sonnet 档估
}

func lineCost(_ model: String, _ inTok: Double, _ outTok: Double, _ cacheRead: Double, _ cacheWrite: Double) -> Double {
    let p = unitPrice(model)
    let inCost = (inTok + 0.1 * cacheRead + 1.25 * cacheWrite) / 1e6 * p.input
    return inCost + outTok / 1e6 * p.output
}

// MARK: - 扫描 ~/.claude/projects/**/*.jsonl
struct Rec { let date: Date; let session: String; let project: String; let cost: Double }

func scan(_ root: URL) -> (recs: [Rec], parseErrors: Int) {
    var recs: [Rec] = []; var seen = Set<String>(); var errs = 0
    let fm = FileManager.default
    guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return ([], 0) }
    let isoFs = ISO8601DateFormatter(); isoFs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter()
    for projDir in projects {
        let proj = projDir.lastPathComponent
        guard let files = try? fm.contentsOfDirectory(at: projDir, includingPropertiesForKeys: nil) else { continue }
        for f in files where f.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { errs += 1; continue } // 只有 JSON 坏行才算解析错误
                guard obj["type"] as? String == "assistant", let msg = obj["message"] as? [String: Any] else { continue } // user/tool/summary 行属正常内容，跳过
                let mid = msg["id"] as? String ?? UUID().uuidString
                guard seen.insert(mid).inserted else { continue } // 去重（ccusage 同款策略）
                let u = msg["usage"] as? [String: Any] ?? [:]
                func d(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
                let model = msg["model"] as? String ?? "sonnet"
                let ts = obj["timestamp"] as? String ?? ""
                let date = isoFs.date(from: ts) ?? iso.date(from: ts) ?? Date(timeIntervalSince1970: 0)
                let cost = lineCost(model, d("input_tokens"), d("output_tokens"), d("cache_read_input_tokens"), d("cache_creation_input_tokens"))
                recs.append(Rec(date: date, session: obj["sessionId"] as? String ?? f.deletingPathExtension().lastPathComponent, project: proj, cost: cost))
            }
        }
    }
    return (recs, errs)
}

// MARK: - Model
final class Model: ObservableObject {
    @Published var todayBurn = 0.0
    @Published var weekBurn = 0.0
    @Published var overlay = 0.0        // "simulate rogue" 的模拟增量（只进 UI，不参与熔断判定）
    @Published var tripped = false
    @Published var tripReason = ""
    @Published var tripDemo = false     // 本次熔断是自测触发，guard 会在 demo_ttl_s 后自动复位
    @Published var hookActive = false
    @Published var sessionsToday: [(project: String, session: String, cost: Double)] = []
    @Published var procs: [String] = []
    @Published var demoMode = false
    var budget: Double { didSet { UserDefaults.standard.set(budget, forKey: "wd_budget"); writeState() } }
    var hardStop: Bool { didSet { UserDefaults.standard.set(hardStop, forKey: "wd_hard"); writeState() } }
    var realBurn: Double { todayBurn }              // 真实花费：唯一允许写进 state.json 的值
    var displayBurn: Double { todayBurn + overlay }  // 演示增量只影响显示，不参与熔断判定

    let dataRoot: URL
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var alertedOnce = false

    init() {
        budget = UserDefaults.standard.object(forKey: "wd_budget") as? Double ?? 20
        hardStop = UserDefaults.standard.object(forKey: "wd_hard") as? Bool ?? true
        if let env = ProcessInfo.processInfo.environment["WATCHDOG_DATA_DIR"] {
            dataRoot = URL(fileURLWithPath: env); demoMode = true
        } else {
            dataRoot = home.appendingPathComponent(".claude/projects")
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        syncTripFromDisk()
        let cal = Calendar.current
        let (recs, _) = scan(dataRoot)
        todayBurn = recs.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.cost }
        weekBurn = recs.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.reduce(0) { $0 + $1.cost }
        var bySess: [String: (project: String, cost: Double)] = [:]
        for r in recs where cal.isDateInToday(r.date) {
            bySess[r.session, default: (r.project, 0)].cost += r.cost
        }
        sessionsToday = bySess.map { (project: $0.value.project, session: $0.key, cost: $0.value.cost) }
            .sorted { $0.cost > $1.cost }
        hookActive = isHookRegistered()
        procs = runningAgents()
        writeState()
        evaluate()
    }

    func evaluate() {
        if realBurn >= budget && !tripped { trip() }
    }

    func trip(_ reason: String = "budget", demo: Bool = false) {
        tripped = true; tripReason = reason; tripDemo = demo
        let detail = reason == "budget"
            ? String(format: "$%.2f ≥ budget $%.2f — agent spend halted", realBurn, budget)
            : reason
        if !alertedOnce { notify("Circuit breaker TRIPPED", detail); alertedOnce = true }
        if hardStop && !demo { writeStopMarker() }   // 自测不写停止标记：没有真实 agent 需要停
        writeState()
    }

    /// guard（hook 侧）写入的 trip 同步进 UI——guard 与 app 共享 state.json
    private func syncTripFromDisk() {
        let f = home.appendingPathComponent(".watchdog/state.json")
        guard let data = try? Data(contentsOf: f),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["tripped"] as? Bool) == true, !tripped else { return }
        tripped = true
        tripReason = obj["reason"] as? String ?? "external"
        let demo = (obj["trip_demo"] as? Bool) == true
        tripDemo = demo
        if !alertedOnce { notify("Circuit breaker TRIPPED", tripReason); alertedOnce = true }
        if hardStop && !demo { writeStopMarker() }
    }

    private func writeStopMarker() {
        let stop = home.appendingPathComponent(".claude/AGENT_STOP")
        try? FileManager.default.createDirectory(at: stop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "watchdog tripped at \(Date())".write(to: stop, atomically: true, encoding: .utf8)
    }

    private func isHookRegistered() -> Bool {
        let s = home.appendingPathComponent(".claude/settings.json")
        return (try? String(contentsOf: s, encoding: .utf8))?.contains("watchdog-guard") ?? false
    }

    func resetTrip() {
        tripped = false; tripReason = ""; tripDemo = false; overlay = 0; alertedOnce = false
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".claude/AGENT_STOP"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".watchdog/events.jsonl")) // 清循环计数
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".watchdog/results.jsonl")) // 清连续报错计数
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".watchdog/errors.jsonl"))  // v1.1 旧文件名，顺手清掉
        notify("Breaker rearmed", "Watchdog reset — agents may proceed")
        writeState()
    }

    /// 演示：不注入假花费。过去 overlay 会把 $47 写进真实 state.json，
    /// 结果是点一下自测就真把正在跑的 agent 全拒掉。这里直接走熔断路径，
    /// 让用户能验证 hook 是否真的会拦；guard 会在 demo_ttl_s 后自动复位。
    func simulateRogue() {
        trip("DEMO: circuit-breaker self-test — no real spend, auto-rearms shortly", demo: true)
    }

    private func writeState() { // hook 的 IPC：极简 JSON 文件，无守护进程
        let dir = home.appendingPathComponent(".watchdog")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reason = tripReason.replacingOccurrences(of: "\"", with: "")
        // today_burn 只写真实花费：guard 拿这个数做预算判定，混入演示值就等于伪造账单
        let s = String(format: "{\"today_burn\": %.4f, \"budget\": %.2f, \"tripped\": %@, \"trip_demo\": %@, \"reason\": \"%@\"}\n",
                       realBurn, budget, tripped ? "true" : "false", tripDemo ? "true" : "false", reason)
        try? s.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    private func notify(_ title: String, _ body: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let esc = body.replacingOccurrences(of: "\"", with: "\\\"")
        let t = title.replacingOccurrences(of: "\"", with: "\\\"")
        p.arguments = ["-e", "display notification \"\(esc)\" with title \"AgentWatchdog\" subtitle \"\(t)\""]
        try? p.run()
    }

    private func runningAgents() -> [String] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-fl", "claude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.contains("pgrep") }
    }
}

// MARK: - UI
struct PanelView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "$%.2f", m.displayBurn)).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundColor(m.tripped ? .red : .primary)
                Text("today").foregroundStyle(.secondary)
                Spacer()
                if m.tripped { Text("🔴 TRIPPED").font(.callout.bold()).foregroundStyle(.red) }
            }
            Text(String(format: "7d: $%.2f   ·   budget: $%.2f   ·   source: %@", m.weekBurn, m.budget, m.demoMode ? "demo" : "live ~/.claude")).font(.caption).foregroundStyle(.secondary)
            Text(m.hookActive ? "hook: ACTIVE ✓" : "hook: not registered (see README)")
                .font(.caption).foregroundStyle(m.hookActive ? Color.green : Color.orange)
            Divider()
            HStack {
                Text("Daily budget").font(.callout)
                Spacer()
                TextField("$", value: $m.budget, format: .number).textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
            }
            HStack(spacing: 6) {
                ForEach([5.0, 10, 20, 50], id: \.self) { v in
                    Button(String(format: "$%.0f", v)) { m.budget = v }.controlSize(.small)
                }
                Spacer()
                Toggle("Hard stop", isOn: $m.hardStop).toggleStyle(.switch).controlSize(.small)
            }
            if m.tripped {
                Text("reason: \(m.tripReason)").font(.caption).foregroundStyle(.red).lineLimit(2)
                if m.tripDemo {
                    Text("self-test — no real spend, will re-arm automatically").font(.caption2).foregroundStyle(.orange)
                }
                Button("Reset & rearm breaker") { m.resetTrip() }.controlSize(.small)
            }
            Divider()
            Text("Top sessions today").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(m.sessionsToday.prefix(5), id: \.session) { s in
                HStack {
                    Text(String(s.project.suffix(30))).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(String(format: "$%.2f  %@", s.cost, String(s.session.prefix(8)))).monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
            }
            Divider()
            Text("Running agents (patrol)").font(.caption.bold()).foregroundStyle(.secondary)
            if m.procs.isEmpty { Text("none detected").font(.caption).foregroundStyle(.secondary) }
            else { ForEach(m.procs.prefix(4), id: \.self) { Text($0).font(.caption.monospaced()).lineLimit(1) } }
            Text("rules: budget · loop 8×/10min · errors ×5").font(.caption2).foregroundStyle(.tertiary)
            Divider()
            HStack {
                Button("⚡ Simulate rogue (+$47)") { m.simulateRogue() }.controlSize(.small)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.controlSize(.small)
            }
        }.padding(12).frame(width: 360)
    }
}

// MARK: - CLI（--stats / --selftest）
enum CLI {
    static func run(_ args: [String]) {
        let root: URL
        if let i = args.firstIndex(of: "--stats"), i + 1 < args.count { root = URL(fileURLWithPath: args[i + 1]) }
        else if let env = ProcessInfo.processInfo.environment["WATCHDOG_DATA_DIR"] { root = URL(fileURLWithPath: env) }
        else { root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects") }
        if args.contains("--selftest") { selftest(root); exit(0) }
        let (recs, errs) = scan(root)
        let cal = Calendar.current
        let today = recs.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.cost }
        let week = recs.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.reduce(0) { $0 + $1.cost }
        print(String(format: "records=%d parseErrors=%d today=$%.2f 7d=$%.2f", recs.count, errs, today, week))
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let hook = (try? String(contentsOf: settings, encoding: .utf8))?.contains("watchdog-guard") == true
        print("hook=\(hook ? "active" : "not-registered")")
    }
    static func selftest(_ root: URL) {
        var failed = false
        // 检查 1：计价公式 — 1M sonnet 输入 + 1M 输出 应恰好 $18.00
        let unit = lineCost("claude-sonnet-4-5", 1_000_000, 1_000_000, 0, 0)
        if abs(unit - 18.0) >= 0.001 { print("FAIL  unit-price=$\(unit) (expect 18.00)"); failed = true }
        // 检查 2：demo 数据（rogue 场景）今日烧钱应 > $180 且解析健康
        let (recs, errs) = scan(root)
        let cal = Calendar.current
        let today = recs.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.cost }
        if today <= 180 { print(String(format: "FAIL  demo-today=$%.2f (expect >180) — 数据没被解析", today)); failed = true }
        if recs.count < 50 || errs > 0 { print("FAIL  parse unhealthy: \(recs.count) recs, \(errs) errors"); failed = true }
        if failed { exit(1) }
        print(String(format: "PASS  unit-price=$%.2f  demo-today=$%.2f  records=%d", unit, today, recs.count))
    }
}

@main struct WatchdogApp: App {
    @StateObject private var model = Model()
    init() {
        let args = CommandLine.arguments
        if args.contains("--stats") || args.contains("--selftest") { CLI.run(args); exit(0) }
    }
    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Text(model.tripped
                 ? String(format: "🔴 $%.2f", model.displayBurn)
                 : String(format: "🐕 $%.2f", model.displayBurn))
        }
        .menuBarExtraStyle(.window)
    }
}
