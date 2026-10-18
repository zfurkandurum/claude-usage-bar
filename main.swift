import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - Localization (English default, Turkish if system language is Turkish)

let isTR = Locale.preferredLanguages.first?.hasPrefix("tr") ?? false
func L(_ en: String, _ tr: String) -> String { isTR ? tr : en }

// MARK: - Model

struct Limit {
    let utilization: Double   // 0...100 (kullanılan)
    let resetsAt: Date?
    var remaining: Double { max(0, 100 - utilization) }
}

struct Usage {
    var fiveHour: Limit?
    var sevenDay: Limit?
}

struct Account: Equatable {
    var email: String?
    var name: String?
    var org: String?
    var plan: String?      // "Pro", "Max", …
    var label: String { [email ?? name, plan].compactMap { $0 }.joined(separator: " · ") }
}

struct Fetched { let usage: Usage; let account: Account? }

enum UsageError: Error { case noCredentials, http(Int), rateLimited(TimeInterval?), parse, network }

// MARK: - API

final class UsageClient {
    private func creds(from data: Data) -> (token: String, plan: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return (token, (oauth["subscriptionType"] as? String)?.capitalized)
    }

    static func resolveDir(_ configDir: String?) -> String? {
        if let c = configDir, !c.isEmpty { return (c as NSString).expandingTildeInPath }
        return ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    }

    /// Which account Claude Code says it is signed in as (no network, no secrets).
    static func accountFromFile(configDir: String?) -> Account? {
        let path = (resolveDir(configDir).map { $0 + "/.claude.json" }) ?? NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = j["oauthAccount"] as? [String: Any] else { return nil }
        return Account(email: a["emailAddress"] as? String, name: a["displayName"] as? String,
                       org: a["organizationName"] as? String, plan: nil)
    }

    /// Claude Code keeps its OAuth login in the macOS Keychain (or in
    /// `<config dir>/.credentials.json`). Re-read on every refresh so tokens that
    /// Claude Code has refreshed — or a different account after `/login` — are
    /// picked up automatically.
    private func readCreds(configDir: String?) throws -> (token: String, plan: String?) {
        let dir = Self.resolveDir(configDir)
        let file = { (d: String) -> (token: String, plan: String?)? in
            FileManager.default.contents(atPath: d + "/.credentials.json").flatMap { self.creds(from: $0) }
        }
        if let c = configDir, !c.isEmpty, let dir, let r = file(dir) { return r }   // explicit folder wins
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if p.terminationStatus == 0, let r = creds(from: data) { return r }
        }
        if let r = file(dir ?? NSHomeDirectory() + "/.claude") { return r }
        throw UsageError.noCredentials
    }

    private func parse(_ d: Any?) -> Limit? {
        guard let d = d as? [String: Any], let u = d["utilization"] as? Double else { return nil }
        var date: Date?
        if let s = d["resets_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return Limit(utilization: u, resetsAt: date)
    }

    func fetch(configDir: String?, completion: @escaping (Result<Fetched, UsageError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let token: String, plan: String?
            do { (token, plan) = try self.readCreds(configDir: configDir) } catch {
                return DispatchQueue.main.async { completion(.failure(.noCredentials)) }
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.timeoutInterval = 15
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let result: Result<Fetched, UsageError>
                if err != nil { result = .failure(.network) }
                else if let http = resp as? HTTPURLResponse, http.statusCode == 429 {
                    result = .failure(.rateLimited(TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "")))
                }
                else if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { result = .failure(.http(code)) }
                else if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var acct = Self.accountFromFile(configDir: configDir)
                    acct?.plan = plan
                    result = .success(Fetched(usage: Usage(fiveHour: self.parse(j["five_hour"]), sevenDay: self.parse(j["seven_day"])), account: acct))
                } else { result = .failure(.parse) }
                DispatchQueue.main.async { completion(result) }
            }.resume()
        }
    }
}

// MARK: - Shared helpers

func fmtReset(_ date: Date?) -> String {
    guard let date else { return "—" }
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return L("now", "şimdi") }
    let h = s / 3600, m = (s % 3600) / 60
    if h >= 24 { return "\(h / 24)\(L("d", "g")) \(h % 24)\(L("h", "sa"))" }
    return h > 0 ? "\(h)\(L("h", "sa")) \(m)\(L("m", "dk"))" : "\(m)\(L("m", "dk"))"
}

func errorText(_ e: UsageError) -> String {
    switch e {
    case .noCredentials: return L("Claude Code login not found (run `claude` and sign in)", "Claude Code girişi bulunamadı (claude ile giriş yap)")
    case .http(let c): return L("Server error (\(c)) — token may be expired, open Claude Code once", "Sunucu hatası (\(c)) — token yenilenmemiş olabilir, Claude Code'u aç")
    case .rateLimited: return L("Rate limited by the server — showing last known value", "Sunucu istek sınırına takıldı — son değer gösteriliyor")
    case .network: return L("Network error", "Ağ hatası")
    case .parse: return L("Could not read response", "Yanıt okunamadı")
    }
}

// MARK: - Model (state + preferences)

final class Model: ObservableObject {
    @Published var usage: Usage?
    @Published var account: Account?
    @Published var lastError: UsageError?
    @Published var lastUpdate: Date?
    @Published var backoffUntil: Date { didSet { d.set(backoffUntil > Date() ? backoffUntil.timeIntervalSince1970 : 0, forKey: "backoffUntil") } }
    @Published var showWeekly: Bool { didSet { d.set(showWeekly, forKey: "showWeekly") } }
    @Published var showUsed: Bool { didSet { d.set(showUsed, forKey: "showUsed") } }   // false = show remaining
    @Published var interval: Int { didSet { d.set(interval, forKey: "interval") } }    // seconds
    /// Optional Claude config folder (empty = the account Claude Code is signed into by default).
    @Published var configDir: String {
        didSet {
            guard oldValue != configDir else { return }
            d.set(configDir, forKey: "configDir")
            usage = nil; lastError = nil; lastUpdate = nil
            account = UsageClient.accountFromFile(configDir: configDir)
            lastFetch = .distantPast
            DispatchQueue.main.async { self.refresh(force: true) }
        }
    }

    private let d = UserDefaults.standard
    private let client = UsageClient()
    private var lastFetch: Date
    private var failStreak: Int
    private var inFlight = false

    private func cache(_ u: Usage) {
        var o: [String: Any] = [:]
        for (k, l) in [("five", u.fiveHour), ("seven", u.sevenDay)] {
            if let l { o[k] = ["u": l.utilization, "r": l.resetsAt?.timeIntervalSince1970 ?? 0] }
        }
        d.set(o, forKey: "cachedUsage")
        d.set(account?.email ?? "", forKey: "cachedEmail")
        d.set(account?.plan ?? "", forKey: "cachedPlan")
        d.set(lastUpdate?.timeIntervalSince1970 ?? 0, forKey: "lastUpdate")
    }
    /// Cached values survive restarts so a relaunch never needs an immediate request.
    /// They are only used if they belong to the account that is signed in now.
    private func loadCache(for email: String?) -> Usage? {
        guard let o = d.dictionary(forKey: "cachedUsage"),
              (d.string(forKey: "cachedEmail") ?? "") == (email ?? "") else { return nil }
        func lim(_ k: String) -> Limit? {
            guard let x = o[k] as? [String: Double], let u = x["u"] else { return nil }
            let r = x["r"] ?? 0
            return Limit(utilization: u, resetsAt: r > 0 ? Date(timeIntervalSince1970: r) : nil)
        }
        // A cached window that already reset is stale — don't show it.
        let five = lim("five").flatMap { ($0.resetsAt ?? .distantFuture) > Date() ? $0 : nil }
        let seven = lim("seven").flatMap { ($0.resetsAt ?? .distantFuture) > Date() ? $0 : nil }
        return (five == nil && seven == nil) ? nil : Usage(fiveHour: five, sevenDay: seven)
    }

    init() {
        showWeekly = d.object(forKey: "showWeekly") as? Bool ?? false
        showUsed = d.bool(forKey: "showUsed")
        interval = d.object(forKey: "interval") as? Int ?? 120
        configDir = d.string(forKey: "configDir") ?? ""
        let b = d.double(forKey: "backoffUntil")
        backoffUntil = b > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: b) : .distantPast
        let lf = d.double(forKey: "lastFetch")
        lastFetch = lf > 0 ? Date(timeIntervalSince1970: lf) : .distantPast
        failStreak = d.integer(forKey: "failStreak")

        var acct = UsageClient.accountFromFile(configDir: configDir)
        usage = loadCache(for: acct?.email)
        if usage != nil {
            acct?.plan = d.string(forKey: "cachedPlan").flatMap { $0.isEmpty ? nil : $0 }
            let lu = d.double(forKey: "lastUpdate")
            lastUpdate = lu > 0 ? Date(timeIntervalSince1970: lu) : nil
        }
        account = acct
    }

    func value(_ l: Limit) -> Int { Int((showUsed ? l.utilization : l.remaining).rounded()) }

    var isBackingOff: Bool { Date() < backoffUntil }

    /// Rate-limit protection. Every request path (timer, popover open, wake, button,
    /// app launch) goes through here, so the server is never hit more than once per
    /// refresh interval — even across app restarts — and a 429 backs off exponentially.
    func refresh(force: Bool = false) {
        guard !inFlight, !isBackingOff else { return }
        let now = Date()
        let minGap: TimeInterval = force ? 15 : TimeInterval(interval) * 0.9
        guard now.timeIntervalSince(lastFetch) >= minGap else { return }
        inFlight = true
        lastFetch = now
        d.set(now.timeIntervalSince1970, forKey: "lastFetch")

        client.fetch(configDir: configDir) { [weak self] r in
            guard let self else { return }
            self.inFlight = false
            switch r {
            case .success(let f):
                if f.account?.email != self.account?.email { self.usage = nil }   // account was switched
                self.account = f.account
                self.usage = f.usage
                self.lastError = nil
                self.lastUpdate = Date()
                self.failStreak = 0; self.d.set(0, forKey: "failStreak")
                self.cache(f.usage)
            case .failure(let e):
                self.lastError = e   // keep showing the last known usage
                if case .rateLimited(let after) = e {
                    self.failStreak += 1
                    self.d.set(self.failStreak, forKey: "failStreak")
                    let exp = min(120 * pow(2, Double(self.failStreak - 1)), 1800)   // 2, 4, 8, 16, 30 min
                    self.backoffUntil = Date().addingTimeInterval(max(after ?? 0, exp) + Double.random(in: 0...15))
                }
            }
        }
    }
}

func levelColor(_ l: Limit) -> Color {
    l.remaining <= 10 ? .red : (l.remaining <= 25 ? .orange : .green)
}

// MARK: - Popover UI

struct LimitRow: View {
    @ObservedObject var m: Model
    let title: String
    let limit: Limit?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let l = limit {
                    Text("\(m.value(l))% " + (m.showUsed ? L("used", "kullanıldı") : L("left", "kalan")))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    if let l = limit {
                        Capsule().fill(levelColor(l))
                            .frame(width: max(4, g.size.width * CGFloat(m.value(l)) / 100))
                    }
                }
            }
            .frame(height: 6)
            if let l = limit {
                Text(L("Resets in \(fmtReset(l.resetsAt))", "Sıfırlanmaya \(fmtReset(l.resetsAt)) var"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var m: Model
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude").font(.system(size: 14, weight: .bold))
                    if let a = m.account, !a.label.isEmpty {
                        Text(a.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { m.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L("Refresh now", "Şimdi yenile"))
            }
            LimitRow(m: m, title: L("5-hour", "5 saatlik"), limit: m.usage?.fiveHour)
            LimitRow(m: m, title: L("Weekly", "Haftalık"), limit: m.usage?.sevenDay)

            if let e = m.lastError {
                Group {
                    if case .rateLimited = e, m.isBackingOff {
                        Text("⚠︎ " + L("Rate limited — showing last value, next try ", "İstek sınırı — son değer gösteriliyor, sonraki deneme ")) + Text(m.backoffUntil, style: .time)
                    } else {
                        Text("⚠︎ " + errorText(e))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button(L("Settings…", "Ayarlar…"), action: openSettings)
                Spacer()
                if let t = m.lastUpdate {
                    Text(t, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Quit", "Çık")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 290)
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @ObservedObject var m: Model
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var draftDir = ""

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.message = L("Choose a Claude config folder (contains .credentials.json)", "Bir Claude yapılandırma klasörü seç (.credentials.json içeren)")
        if p.runModal() == .OK, let u = p.url { draftDir = u.path; m.configDir = u.path }
    }

    var body: some View {
        Form {
            Section(L("Account", "Hesap")) {
                LabeledContent(L("Signed in as", "Giriş yapılan hesap")) {
                    Text(m.account?.label.isEmpty == false ? m.account!.label : L("unknown", "bilinmiyor"))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    TextField(L("Config folder (optional)", "Klasör (isteğe bağlı)"), text: $draftDir, prompt: Text("~/.claude"))
                        .onSubmit { m.configDir = draftDir.trimmingCharacters(in: .whitespaces) }
                    Button(L("Choose…", "Seç…"), action: chooseFolder)
                    if !m.configDir.isEmpty {
                        Button(L("Reset", "Sıfırla")) { draftDir = ""; m.configDir = "" }
                    }
                }
                Text(L("By default the bar follows the account Claude Code is signed into on this Mac (switch with `claude /login`). Set a folder only if you keep a separate Claude config folder.",
                       "Varsayılan olarak bar, bu Mac'te Claude Code'a giriş yapılmış hesabı izler (`claude /login` ile değişir). Sadece ayrı bir Claude yapılandırma klasörün varsa klasör seç."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Menu bar", "Menü çubuğu")) {
                Toggle(L("Also show weekly limit", "Haftalık limiti de göster"), isOn: $m.showWeekly)
                Toggle(L("Show used % instead of remaining %", "Kalan yerine kullanılan % göster"), isOn: $m.showUsed)
            }
            Section(L("General", "Genel")) {
                Toggle(L("Launch at login", "Girişte otomatik başlat"), isOn: Binding(
                    get: { login },
                    set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                        login = SMAppService.mainApp.status == .enabled
                    }))
                Picker(L("Refresh every", "Yenileme sıklığı"), selection: $m.interval) {
                    Text(L("1 minute", "1 dakika")).tag(60)
                    Text(L("2 minutes", "2 dakika")).tag(120)
                    Text(L("5 minutes", "5 dakika")).tag(300)
                    Text(L("10 minutes", "10 dakika")).tag(600)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 470)
        .onAppear { draftDir = m.configDir }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = Model()
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        popover.behavior = CommandLine.arguments.contains("--open-popover") ? .applicationDefined : .transient   // flag: stays open for screenshots
        let host = NSHostingController(
            rootView: PopoverView(m: model, openSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateTitle()

        // objectWillChange fires before the change lands; hop to next runloop tick.
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle(); self?.scheduleTimer() }
        }.store(in: &bag)

        // When a rate-limit back-off ends, retry right away instead of waiting for the next tick.
        model.$backoffUntil.removeDuplicates().sink { [weak self] until in
            guard until > Date() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 1) { self?.model.refresh() }
        }.store(in: &bag)

        model.refresh()
        scheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.model.refresh() }
        }

        // Enable launch-at-login on first run (can be turned off in Settings).
        if !UserDefaults.standard.bool(forKey: "loginInitDone") {
            UserDefaults.standard.set(true, forKey: "loginInitDone")
            try? SMAppService.mainApp.register()
        }

        // Dev/testing helpers.
        if CommandLine.arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePopover() }
        }
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openSettings() }
        }
    }

    private var scheduledInterval = 0
    private func scheduleTimer() {
        guard scheduledInterval != model.interval else { return }
        scheduledInterval = model.interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(model.interval), repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
    }

    // MARK: Status item

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let s = NSMenuItem(title: L("Settings…", "Ayarlar…"), action: #selector(openSettings), keyEquivalent: ",")
            s.target = self; menu.addItem(s)
            let r = NSMenuItem(title: L("Refresh now", "Şimdi yenile"), action: #selector(refreshNow), keyEquivalent: "r")
            r.target = self; menu.addItem(r)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: L("Quit", "Çık"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc private func refreshNow() { model.refresh(force: true) }

    private func togglePopover() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        model.refresh()   // no-op while backing off after a 429
        // Give the popover its real size up front; otherwise it is placed using a stale size and floats below the menu bar.
        if let v = popover.contentViewController?.view {
            v.layoutSubtreeIfNeeded()
            popover.contentSize = v.fittingSize
        }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(m: model))
            let w = NSWindow(contentViewController: host)
            w.title = L("Claude Usage Bar — Settings", "Claude Usage Bar — Ayarlar")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(host.view.fittingSize)
            settingsWindow = w
        }
        if let w = settingsWindow, !w.isVisible {
            // Exact center of the screen the mouse is on (NSWindow.center() sits above center).
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let vf = screen?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Title

    private func updateTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ c: NSColor? = nil) {
            var a: [NSAttributedString.Key: Any] = [.font: font]
            if let c { a[.foregroundColor] = c }
            out.append(NSAttributedString(string: s, attributes: a))
        }
        func tint(_ l: Limit) -> NSColor? {
            l.remaining <= 10 ? .systemRed : (l.remaining <= 25 ? .systemOrange : nil)
        }
        guard let u = model.usage, let five = u.fiveHour else {
            add(model.lastError == nil ? "…" : "⚠︎")
            item.button?.attributedTitle = out
            return
        }
        add("\(model.value(five))%", tint(five))
        if model.showWeekly, let w = u.sevenDay {
            add(" · ")
            add("\(model.value(w))%", tint(w))
        }
        if model.lastError != nil { add(" ⚠︎") }
        item.button?.attributedTitle = out
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
