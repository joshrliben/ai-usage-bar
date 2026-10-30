// AIUsageBar — menu bar app showing Claude and Codex (ChatGPT) plan-limit usage.
//
// Data sources (both undocumented; they are what Claude Code's /usage and Codex's /status use):
//   Claude: GET https://api.anthropic.com/api/oauth/usage, token from Keychain "Claude Code-credentials"
//   Codex:  GET https://chatgpt.com/backend-api/wham/usage, token from ~/.codex/auth.json
// Tokens are read fresh each refresh and never refreshed or written here, so Claude Code and
// Codex stay the owners of their sign-ins.

import AppKit
import SwiftUI

let refreshInterval: TimeInterval = 120

struct Window {
    var percent: Double
    var resetsAt: Date?
    var length: TimeInterval
    // % per hour over the last `recentSpan`, once the app has watched for at least 5 minutes.
    var recentRate: Double?

    // % per hour averaged since the window started; available immediately.
    var averageRate: Double? {
        guard let resetsAt else { return nil }
        let elapsed = length - resetsAt.timeIntervalSinceNow
        return elapsed > 60 ? percent / (elapsed / 3600) : nil
    }
}

let recentSpan: TimeInterval = 30 * 60

struct ServiceUsage {
    var fiveHour: Window?
    var weekly: Window?
    var error: String?
    var updated: Date?

    // The window closer to running out; the menu bar shows its percent and reset countdown.
    var worstWindow: Window? {
        [fiveHour, weekly].compactMap { $0 }.max { $0.percent < $1.percent }
    }

    var worst: Double? { worstWindow?.percent }
}

enum FetchError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Fetching

func getJSON(_ url: String, headers: [String: String]) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 || status == 403 {
        throw FetchError.message("Sign-in expired. Open the app once to refresh it.")
    }
    guard status == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FetchError.message("HTTP \(status)")
    }
    return obj
}

func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func fetchClaude() async throws -> ServiceUsage {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try p.run()
    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let creds = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let oauth = creds["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else {
        throw FetchError.message("No Claude Code sign-in found in Keychain.")
    }
    let obj = try await getJSON("https://api.anthropic.com/api/oauth/usage", headers: [
        "Authorization": "Bearer \(token)",
        "anthropic-beta": "oauth-2025-04-20",
    ])
    func window(_ key: String) -> Window? {
        guard let w = obj[key] as? [String: Any], let u = w["utilization"] as? Double else { return nil }
        return Window(percent: u, resetsAt: parseISO(w["resets_at"] as? String), length: key == "five_hour" ? 5 * 3600 : 7 * 86400)
    }
    return ServiceUsage(fiveHour: window("five_hour"), weekly: window("seven_day"), updated: Date())
}

func fetchCodex() async throws -> ServiceUsage {
    let path = NSString(string: "~/.codex/auth.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = auth["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String else {
        throw FetchError.message("No Codex sign-in found in ~/.codex/auth.json.")
    }
    let obj = try await getJSON("https://chatgpt.com/backend-api/wham/usage", headers: [
        "Authorization": "Bearer \(token)",
        "ChatGPT-Account-Id": tokens["account_id"] as? String ?? "",
        "User-Agent": "codex_cli_rs",
    ])
    let limits = obj["rate_limit"] as? [String: Any]
    func window(_ key: String) -> Window? {
        guard let w = limits?[key] as? [String: Any], let u = w["used_percent"] as? Double else { return nil }
        let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let fallback: TimeInterval = key == "primary_window" ? 5 * 3600 : 7 * 86400
        return Window(percent: u, resetsAt: reset, length: w["limit_window_seconds"] as? Double ?? fallback)
    }
    return ServiceUsage(fiveHour: window("primary_window"), weekly: window("secondary_window"), updated: Date())
}

// MARK: - Model

@MainActor
final class UsageModel: ObservableObject {
    @Published var claude = ServiceUsage()
    @Published var codex = ServiceUsage()
    @Published var refreshing = false
    var onChange: (() -> Void)?

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            async let c = capture { try await fetchClaude() }
            async let x = capture { try await fetchCodex() }
            apply(await c, to: \.claude, name: "claude")
            apply(await x, to: \.codex, name: "codex")
            refreshing = false
            onChange?()
        }
    }

    // On failure keep the last good numbers and attach the error, so a blip doesn't blank the bar.
    private func apply(_ r: Result<ServiceUsage, Error>, to key: ReferenceWritableKeyPath<UsageModel, ServiceUsage>, name: String) {
        switch r {
        case .success(var u):
            track("\(name)-5h", &u.fiveHour)
            track("\(name)-weekly", &u.weekly)
            self[keyPath: key] = u
        case .failure(let e): self[keyPath: key].error = e.localizedDescription
        }
    }

    // In-memory (time, percent) history per window, used for the recent burn rate.
    private var samples: [String: [(Date, Double)]] = [:]

    private func track(_ key: String, _ window: inout Window?) {
        guard var w = window else { return }
        let now = Date()
        var s = samples[key, default: []]
        if let last = s.last, w.percent < last.1 { s.removeAll() }  // the window reset
        s.append((now, w.percent))
        s.removeAll { now.timeIntervalSince($0.0) > recentSpan }
        samples[key] = s
        if let first = s.first, now.timeIntervalSince(first.0) >= 5 * 60 {
            w.recentRate = (w.percent - first.1) / (now.timeIntervalSince(first.0) / 3600)
        }
        window = w
    }
}

// One line for the popover, e.g. "12%/h last 30m · 100% in ~1h40m". `warn` is set when the
// limit is projected to run out before it resets.
func burnSummary(_ w: Window) -> (text: String, warn: Bool)? {
    if w.percent >= 100 { return ("Limit reached", true) }
    let (rate, source) = w.recentRate.map { ($0, "last 30m") } ?? w.averageRate.map { ($0, "avg") } ?? (nil, "")
    guard let rate else { return nil }
    // Weekly windows read better per day.
    let rateText = w.length > 86400
        ? String(format: "%.1f%%/day", rate * 24)
        : String(format: "%.0f%%/h", rate)
    guard rate > 0.05 else { return ("\(rateText) \(source) · idle", false) }
    let runsOut = Date().addingTimeInterval((100 - w.percent) / rate * 3600)
    if let reset = w.resetsAt, runsOut >= reset {
        return ("\(rateText) \(source) · lasts to reset", false)
    }
    return ("\(rateText) \(source) · 100% in ~\(compactUntil(runsOut))", true)
}

func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

func severityColor(_ p: Double?) -> NSColor {
    guard let p else { return .secondaryLabelColor }
    if p >= 90 { return .systemRed }
    if p >= 70 { return .systemOrange }
    return .labelColor
}

func untilString(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, Int(d.timeIntervalSinceNow))
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return "resets in \(days)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

func compactUntil(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, Int(d.timeIntervalSinceNow))
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return "\(days)d\(h)h" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}

// MARK: - Popover UI

struct LimitRow: View {
    let label: String
    let window: Window?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(window.map { "\(Int($0.percent.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color(severityColor(window?.percent)))
            }
            ProgressView(value: min(window?.percent ?? 0, 100), total: 100)
                .tint(Color(severityColor(window?.percent) == .labelColor ? .controlAccentColor : severityColor(window?.percent)))
            Text(untilString(window?.resetsAt)).font(.system(size: 10)).foregroundColor(.secondary)
            if let burn = window.flatMap(burnSummary) {
                Text(burn.text).font(.system(size: 10)).foregroundColor(burn.warn ? .orange : .secondary)
            }
        }
    }
}

struct ServiceSection: View {
    let title: String
    let usage: ServiceUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold))
            LimitRow(label: "5-hour", window: usage.fiveHour)
            LimitRow(label: "Weekly", window: usage.weekly)
            if let err = usage.error {
                Text(err).font(.system(size: 10)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ServiceSection(title: "Claude", usage: model.claude)
            Divider()
            ServiceSection(title: "Codex (ChatGPT)", usage: model.codex)
            Divider()
            HStack {
                let last = [model.claude.updated, model.codex.updated].compactMap { $0 }.min()
                Text(model.refreshing ? "Refreshing…" : last.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button("Refresh") { model.refresh() }.controlSize(.small)
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()
    var item: NSStatusItem!
    let popover = NSPopover()
    var timer: Timer?
    var clockTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        model.onChange = { [weak self] in self?.updateTitle() }
        updateTitle()
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
        // Keep the countdowns ticking between data refreshes.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    func updateTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        func part(_ label: String, _ u: ServiceUsage) {
            let pct = u.worst.map { "\(Int($0.rounded()))%" } ?? "–"
            title.append(NSAttributedString(string: "\(label) \(pct)", attributes: [
                .font: font, .foregroundColor: severityColor(u.worst),
            ]))
            let until = compactUntil(u.worstWindow?.resetsAt)
            if !until.isEmpty {
                title.append(NSAttributedString(string: " \(until)", attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
        }
        part("C", model.claude)
        title.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        part("X", model.codex)
        item.button?.attributedTitle = title
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// `AIUsageBar --print` fetches once and prints, for checking the data path without the UI.
if CommandLine.arguments.contains("--print") {
    func show(_ name: String, _ r: Result<ServiceUsage, Error>) {
        switch r {
        case .success(let u):
            for (label, w) in [("5h", u.fiveHour), ("weekly", u.weekly)] {
                print("\(name) \(label): \(w.map { "\(Int($0.percent))% \(untilString($0.resetsAt)) | \(burnSummary($0)?.text ?? "")" } ?? "—")")
            }
            print("\(name) bar: \(u.worst.map { "\(Int($0.rounded()))%" } ?? "–") \(compactUntil(u.worstWindow?.resetsAt))")
        case .failure(let e): print("\(name) error: \(e.localizedDescription)")
        }
    }
    let done = DispatchSemaphore(value: 0)
    Task {
        show("Claude", await capture { try await fetchClaude() })
        show("Codex", await capture { try await fetchCodex() })
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
