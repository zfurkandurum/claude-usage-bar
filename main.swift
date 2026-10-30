import SwiftUI
import AppKit
import Combine
import CryptoKit
import ServiceManagement
import UniformTypeIdentifiers

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

/// One tracked login, as saved in Settings.
struct AccountSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String          // user label; empty = fall back to the account's email
    var configDir: String     // the Claude config folder (CLAUDE_CONFIG_DIR) that holds this login
    var inMenuBar: Bool
    var owned = false         // signed in by this app, so removing the account also signs out and deletes the folder

    init(id: UUID = UUID(), name: String, configDir: String, inMenuBar: Bool, owned: Bool = false) {
        self.id = id; self.name = name; self.configDir = configDir; self.inMenuBar = inMenuBar; self.owned = owned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        configDir = try c.decode(String.self, forKey: .configDir)
        inMenuBar = try c.decode(Bool.self, forKey: .inMenuBar)
        owned = try c.decodeIfPresent(Bool.self, forKey: .owned) ?? false
    }
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

    static func normDir(_ d: String) -> String {
        var s = (d as NSString).expandingTildeInPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// With `CLAUDE_CONFIG_DIR` set, Claude Code keeps the login in a Keychain item named
    /// `Claude Code-credentials-<first 8 hex of sha256(config dir path)>`.
    static func keychainService(forDir dir: String) -> String {
        let hex = SHA256.hash(data: Data(normDir(dir).utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    static func resolveDir(_ configDir: String?) -> String? {
        guard let c = configDir, !c.isEmpty else { return nil }
        return normDir(c)
    }

    /// Which account Claude Code says it is signed in as (no network, no secrets).
    static func accountFromFile(configDir: String?) -> Account? {
        guard let dir = resolveDir(configDir) else { return nil }
        let path = dir + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = j["oauthAccount"] as? [String: Any] else { return nil }
        return Account(email: a["emailAddress"] as? String, name: a["displayName"] as? String,
                       org: a["organizationName"] as? String, plan: nil)
    }

    private func keychain(service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    private func fileCreds(_ dir: String) -> (token: String, plan: String?)? {
        FileManager.default.contents(atPath: dir + "/.credentials.json").flatMap { creds(from: $0) }
    }

    /// The login of an account lives in the macOS Keychain (or in
    /// `<config dir>/.credentials.json`). Re-read on every refresh so tokens that
    /// Claude Code has refreshed are picked up automatically. A folder never falls
    /// back to another login, so one account is never shown under another's name.
    private func readCreds(configDir: String?) throws -> (token: String, plan: String?) {
        guard let dir = Self.resolveDir(configDir) else { throw UsageError.noCredentials }
        if let r = fileCreds(dir) { return r }
        if let data = keychain(service: Self.keychainService(forDir: dir)), let r = creds(from: data) { return r }
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
                    var acct = Self.accountFromFile(configDir: configDir) ?? Account()
                    acct.plan = plan
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
    case .noCredentials: return L("Not signed in — sign in again", "Oturum açık değil — yeniden giriş yap")
    case .http(401): return L("Session expired — sign in again", "Oturum süresi doldu — yeniden giriş yap")
    case .http(let c): return L("Server error (\(c))", "Sunucu hatası (\(c))")
    case .rateLimited: return L("Rate limited by the server — showing last known value", "Sunucu istek sınırına takıldı — son değer gösteriliyor")
    case .network: return L("Network error", "Ağ hatası")
    case .parse: return L("Could not read response", "Yanıt okunamadı")
    }
}

// MARK: - Claude CLI (sign-in, status, sign-out)

/// Accounts are signed in with Claude Code's own `claude auth login`, bound to the account's
/// folder through `CLAUDE_CONFIG_DIR`. The browser OAuth flow and the token storage stay in Claude Code.
enum AuthCLI {
    struct Status { let loggedIn: Bool; let email: String?; let plan: String? }

    static let binary: String? = {
        let home = NSHomeDirectory()
        var c = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                 home + "/.claude/local/claude", home + "/.npm-global/bin/claude"]
        for ext in ["/.vscode/extensions", "/.cursor/extensions"] {   // binary bundled with the editor extension
            let dir = home + ext
            for i in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().reversed() where i.hasPrefix("anthropic.claude-code") {
                c.append("\(dir)/\(i)/resources/native-binary/claude")
            }
        }
        if let f = c.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return f }
        // Apps started from Finder get a minimal PATH: ask a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    static func env(_ dir: String) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["CLAUDE_CONFIG_DIR"] = dir
        e["ANTHROPIC_API_KEY"] = nil
        e["ANTHROPIC_AUTH_TOKEN"] = nil
        return e
    }

    /// Runs `claude auth <args>` in the folder's login context; nil if the CLI is missing or fails to start.
    private static func run(_ args: [String], dir: String, completion: @escaping (Data?) -> Void) {
        guard let bin = binary else { return completion(nil) }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["auth"] + args
            p.environment = env(dir)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            var data: Data?
            if (try? p.run()) != nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
                data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            }
            DispatchQueue.main.async { completion(data) }
        }
    }

    static func status(dir: String, completion: @escaping (Status?) -> Void) {
        run(["status", "--json"], dir: dir) { data in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return completion(nil) }
            completion(Status(loggedIn: j["loggedIn"] as? Bool ?? false, email: j["email"] as? String,
                              plan: (j["subscriptionType"] as? String)?.capitalized))
        }
    }

    static func logout(dir: String, completion: @escaping () -> Void) {
        run(["logout"], dir: dir) { _ in completion() }
    }
}

/// One running `claude auth login`: opens the browser, waits for the OAuth callback and exits when done.
final class LoginSession: ObservableObject {
    enum State: Equatable { case waiting, failed(String) }
    let name: String
    let dir: String
    let existing: UUID?        // set when an existing account signs in again
    @Published var url: String?
    @Published var state: State = .waiting
    var isActive: Bool { state == .waiting }

    private var process: Process?
    private var stdin: Pipe?
    private var seen = ""
    private var stopped = false

    init(name: String, dir: String, existing: UUID?) {
        self.name = name; self.dir = dir; self.existing = existing
    }

    func start(onExit: @escaping (Bool) -> Void) {
        guard let bin = AuthCLI.binary else {
            state = .failed(L("Claude Code was not found. Install it first (claude.com/claude-code).", "Claude Code bulunamadı. Önce kurun (claude.com/claude-code)."))
            return
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["auth", "login"]
        p.environment = AuthCLI.env(dir)
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.stopped = true
                self.process = nil
                onExit(status == 0)
            }
        }
        do { try p.run() } catch {
            state = .failed(L("Could not start Claude Code.", "Claude Code başlatılamadı."))
            return
        }
        process = p
        stdin = inp
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.isActive else { return }
            self.stopped = true
            self.process?.terminate()
            self.state = .failed(L("Timed out waiting for the sign-in.", "Giriş beklenirken zaman aşımına uğradı."))
        }
    }

    /// The fallback link Claude Code prints in case the browser did not open.
    private func consume(_ text: String) {
        guard url == nil else { return }
        seen += text
        if let r = seen.range(of: "https://\\S+(?=\\s)", options: .regularExpression) { url = String(seen[r]) }
    }

    /// Only needed when the sign-in page shows a code instead of returning to the app.
    func submit(code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, process != nil else { return }
        stdin?.fileHandleForWriting.write(Data((c + "\n").utf8))
    }

    func cancel() {
        stopped = true
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
    }
}

// MARK: - Tracker (state of one account)

final class Tracker: ObservableObject, Identifiable {
    @Published var source: AccountSource
    @Published var usage: Usage?
    @Published var account: Account?
    @Published var lastError: UsageError?
    @Published var lastUpdate: Date?
    @Published var backoffUntil: Date
    var interval: Int   // seconds; kept in sync by Model

    var id: UUID { source.id }
    var isBackingOff: Bool { Date() < backoffUntil }
    /// The login is missing or expired, so a new sign-in is the only way forward.
    var needsSignIn: Bool {
        switch lastError {
        case .noCredentials?, .http(401)?: return true
        default: return false
        }
    }

    /// Name shown in the UI: the user's label, else the account email, else the folder.
    var title: String {
        if !source.name.isEmpty { return source.name }
        if let e = account?.email ?? account?.name { return e }
        return source.configDir.isEmpty ? L("Default login", "Varsayılan giriş") : (source.configDir as NSString).lastPathComponent
    }
    /// Second line under the title (email · plan, or just the plan when the email is the title).
    var subtitle: String? {
        guard let a = account else { return nil }
        let s = source.name.isEmpty ? (a.plan ?? "") : a.label
        return s.isEmpty ? nil : s
    }

    private let d = UserDefaults.standard
    private let client = UsageClient()
    private var lastFetch: Date
    private var failStreak: Int
    private var inFlight = false
    private var gen = 0            // bumped when the folder changes, so stale responses are dropped
    private var removed = false
    private var authRetried = false   // one automatic look after a 401 (Claude Code may refresh the login)
    private var retry: DispatchWorkItem?

    static func key(_ id: UUID) -> String { "acct.\(id.uuidString)" }

    /// Cached values survive restarts so a relaunch never needs an immediate request.
    /// They are only used if they belong to the account that is signed in now.
    private static func loadCache(_ o: [String: Any], for email: String?) -> Usage? {
        guard let u = o["usage"] as? [String: Any],
              (o["email"] as? String ?? "") == (email ?? "") else { return nil }
        func lim(_ k: String) -> Limit? {
            guard let x = u[k] as? [String: Double], let util = x["u"] else { return nil }
            let r = x["r"] ?? 0
            return Limit(utilization: util, resetsAt: r > 0 ? Date(timeIntervalSince1970: r) : nil)
        }
        // A cached window that already reset is stale — don't show it.
        let five = lim("five").flatMap { ($0.resetsAt ?? .distantFuture) > Date() ? $0 : nil }
        let seven = lim("seven").flatMap { ($0.resetsAt ?? .distantFuture) > Date() ? $0 : nil }
        return (five == nil && seven == nil) ? nil : Usage(fiveHour: five, sevenDay: seven)
    }

    init(source: AccountSource, interval: Int) {
        self.source = source
        self.interval = interval
        let o = UserDefaults.standard.dictionary(forKey: Tracker.key(source.id)) ?? [:]
        func num(_ k: String) -> Double { (o[k] as? Double) ?? 0 }
        var acct = UsageClient.accountFromFile(configDir: source.configDir)
        if acct == nil, let e = o["email"] as? String, !e.isEmpty { acct = Account(email: e) }
        let cached = Tracker.loadCache(o, for: acct?.email)
        if cached != nil {
            acct?.plan = (o["plan"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            lastUpdate = num("lastUpdate") > 0 ? Date(timeIntervalSince1970: num("lastUpdate")) : nil
        }
        usage = cached
        account = acct
        backoffUntil = num("backoffUntil") > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: num("backoffUntil")) : .distantPast
        lastFetch = num("lastFetch") > 0 ? Date(timeIntervalSince1970: num("lastFetch")) : .distantPast
        failStreak = (o["failStreak"] as? Int) ?? 0
        scheduleRetry()
    }

    private func save() {
        guard !removed else { return }
        var u: [String: Any] = [:]
        for (k, l) in [("five", usage?.fiveHour), ("seven", usage?.sevenDay)] {
            if let l { u[k] = ["u": l.utilization, "r": l.resetsAt?.timeIntervalSince1970 ?? 0] }
        }
        d.set([
            "usage": u,
            "email": account?.email ?? "",
            "plan": account?.plan ?? "",
            "lastUpdate": lastUpdate?.timeIntervalSince1970 ?? 0,
            "lastFetch": lastFetch > .distantPast ? lastFetch.timeIntervalSince1970 : 0,
            "backoffUntil": backoffUntil > Date() ? backoffUntil.timeIntervalSince1970 : 0,
            "failStreak": failStreak,
        ] as [String: Any], forKey: Tracker.key(source.id))
    }

    /// When a rate-limit back-off ends, retry right away instead of waiting for the next tick.
    private func scheduleRetry() {
        retry?.cancel()
        guard backoffUntil > Date() else { return }
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + backoffUntil.timeIntervalSinceNow + 1, execute: w)
    }

    /// The account now points at another folder: forget everything about the old one.
    func reset(configDir: String) {
        gen += 1
        inFlight = false
        retry?.cancel()
        source.configDir = configDir
        usage = nil; lastError = nil; lastUpdate = nil
        account = UsageClient.accountFromFile(configDir: configDir)
        lastFetch = .distantPast; backoffUntil = .distantPast; failStreak = 0
        save()
        DispatchQueue.main.async { self.refresh(force: true) }
    }

    /// A new sign-in finished for this account: clear the old error and look again right away.
    func signedIn(_ acct: Account) {
        authRetried = false
        lastError = nil
        if acct.email != account?.email { usage = nil }
        account = acct
        lastFetch = .distantPast; backoffUntil = .distantPast; failStreak = 0
        save()
        refresh(force: true)
    }

    /// Remember who just signed in (from `claude auth status`) before the first usage fetch.
    func seed(_ acct: Account) {
        account = acct
        save()
    }

    /// The account was deleted: stop timers and drop its saved state.
    func detach() {
        removed = true
        gen += 1
        retry?.cancel()
        d.removeObject(forKey: Tracker.key(source.id))
    }

    /// Rate-limit protection. Every request path (timer, popover open, wake, button,
    /// app launch) goes through here, so the server is never hit more than once per
    /// refresh interval per account — even across app restarts — and a 429 backs off exponentially.
    func refresh(force: Bool = false) {
        guard !removed, !inFlight, !isBackingOff else { return }
        let now = Date()
        let minGap: TimeInterval = force ? 15 : TimeInterval(interval) * 0.9
        guard now.timeIntervalSince(lastFetch) >= minGap else { return }
        inFlight = true
        lastFetch = now
        save()

        let g = gen
        client.fetch(configDir: source.configDir) { [weak self] r in
            guard let self, self.gen == g else { return }
            self.inFlight = false
            switch r {
            case .success(let f):
                var a = f.account ?? Account()
                if a.email == nil { a.email = self.account?.email; a.name = a.name ?? self.account?.name }   // keep what sign-in told us
                if a.email != self.account?.email { self.usage = nil }   // another account signed in to this folder
                self.account = a
                self.usage = f.usage
                self.lastError = nil
                self.lastUpdate = Date()
                self.failStreak = 0
                self.authRetried = false
            case .failure(let e):
                self.lastError = e   // keep showing the last known usage
                if case .http(401) = e, !self.authRetried {
                    // Let Claude Code look at the login (it renews expired tokens), then try once more.
                    self.authRetried = true
                    AuthCLI.status(dir: self.source.configDir) { [weak self] _ in
                        guard let self, self.gen == g else { return }
                        self.lastFetch = .distantPast
                        self.refresh(force: true)
                    }
                } else if case .rateLimited(let after) = e {
                    self.failStreak += 1
                    let exp = min(120 * pow(2, Double(self.failStreak - 1)), 1800)   // 2, 4, 8, 16, 30 min
                    self.backoffUntil = Date().addingTimeInterval(max(after ?? 0, exp) + Double.random(in: 0...15))
                    self.scheduleRetry()
                }
            }
            self.save()
        }
    }
}

// MARK: - Menu bar icon

/// Icons offered in Settings. Plain SF Symbols (template images), so they follow the menu bar's light/dark tint.
let menuIcons: [(key: String, symbol: String, en: String, tr: String)] = [
    ("gauge", "gauge.with.dots.needle.33percent", "Gauge", "Kadran"),
    ("chart", "chart.bar.fill", "Bars", "Çubuklar"),
    ("sparkle", "sparkle", "Sparkle", "Parıltı"),
    ("asterisk", "asterisk", "Asterisk", "Yıldız"),
    ("none", "", "No icon", "Simge yok"),
]

// MARK: - Model (accounts + preferences)

final class Model: ObservableObject {
    @Published var trackers: [Tracker] = []
    @Published var login: LoginSession?    // the sign-in in progress (or the last one that failed)
    @Published var showWeekly: Bool { didSet { d.set(showWeekly, forKey: "showWeekly") } }
    @Published var showUsed: Bool { didSet { d.set(showUsed, forKey: "showUsed") } }   // false = show remaining
    @Published var icon: String { didSet { d.set(icon, forKey: "icon") } }              // key of menuIcons
    @Published var interval: Int {                                                      // seconds
        didSet { d.set(interval, forKey: "interval"); trackers.forEach { $0.interval = interval } }
    }

    private let d = UserDefaults.standard
    private var bag = Set<AnyCancellable>()
    private var loginBag = Set<AnyCancellable>()

    /// Folders of accounts signed in by this app live here, one per account.
    static let accountsRoot = NSHomeDirectory() + "/Library/Application Support/ClaudeUsageBar/accounts"

    init() {
        showWeekly = d.object(forKey: "showWeekly") as? Bool ?? false
        showUsed = d.bool(forKey: "showUsed")
        icon = d.string(forKey: "icon") ?? "gauge"
        interval = d.object(forKey: "interval") as? Int ?? 120
        trackers = Model.loadSources().map { Tracker(source: $0, interval: interval) }
        persist()
        bind()
    }

    /// Saved accounts. Older versions tracked one account with loose keys; move those
    /// into the first account so nothing is lost and no extra request is made.
    private static func loadSources() -> [AccountSource] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "accounts"),
           let s = try? JSONDecoder().decode([AccountSource].self, from: data) { return withoutDefaultLogin(s) }
        let src = AccountSource(name: "", configDir: d.string(forKey: "configDir") ?? "", inMenuBar: true)
        var o: [String: Any] = [:]
        if let u = d.dictionary(forKey: "cachedUsage") { o["usage"] = u }
        o["email"] = d.string(forKey: "cachedEmail") ?? ""
        o["plan"] = d.string(forKey: "cachedPlan") ?? ""
        for k in ["lastUpdate", "lastFetch", "backoffUntil"] { o[k] = d.double(forKey: k) }
        o["failStreak"] = d.integer(forKey: "failStreak")
        d.set(o, forKey: Tracker.key(src.id))
        for k in ["cachedUsage", "cachedEmail", "cachedPlan", "lastUpdate", "lastFetch", "backoffUntil", "failStreak", "configDir"] {
            d.removeObject(forKey: k)
        }
        return withoutDefaultLogin([src])
    }

    /// The default Claude Code login is no longer tracked: every account is added explicitly.
    private static func withoutDefaultLogin(_ sources: [AccountSource]) -> [AccountSource] {
        for s in sources where s.configDir.isEmpty { UserDefaults.standard.removeObject(forKey: Tracker.key(s.id)) }
        return sources.filter { !$0.configDir.isEmpty }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(trackers.map(\.source)) { d.set(data, forKey: "accounts") }
    }

    /// Forward every tracker's changes so views and the menu bar title update.
    private func bind() {
        bag.removeAll()
        for t in trackers {
            t.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    func value(_ l: Limit) -> Int { Int((showUsed ? l.utilization : l.remaining).rounded()) }

    func refresh(force: Bool = false) { trackers.forEach { $0.refresh(force: force) } }

    // MARK: Account management

    private static func norm(_ dir: String) -> String {
        let s = dir.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "" : UsageClient.normDir(s)
    }

    /// Returns false when the new folder is already used by another account.
    @discardableResult
    func update(id: UUID, name: String, configDir: String) -> Bool {
        guard let t = trackers.first(where: { $0.id == id }) else { return false }
        let dir = Model.norm(configDir)
        if dir.isEmpty { return false }
        if dir != t.source.configDir, trackers.contains(where: { $0.id != id && $0.source.configDir == dir }) { return false }
        t.source.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if dir != t.source.configDir { t.reset(configDir: dir) }
        persist()
        return true
    }

    /// Accounts signed in by this app are signed out and their folder is deleted; existing folders are left alone.
    func remove(_ id: UUID) {
        guard let i = trackers.firstIndex(where: { $0.id == id }) else { return }
        let src = trackers[i].source
        if login?.existing == id { cancelSignIn() }
        trackers[i].detach()
        trackers.remove(at: i)
        persist(); bind()
        if src.owned, src.configDir.hasPrefix(Model.accountsRoot + "/") {
            AuthCLI.logout(dir: src.configDir) { try? FileManager.default.removeItem(atPath: src.configDir) }
        }
    }

    // MARK: Sign-in

    /// Why `name` can't be used for a new account, or nil if it is fine.
    func nameError(_ name: String) -> String? {
        if name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$", options: .regularExpression) == nil {
            return L("Use letters, digits, . _ - (max 40, start with a letter or digit)", "Harf, rakam, . _ - kullan (en fazla 40, harf veya rakamla başla)")
        }
        let dir = Model.accountsRoot + "/" + name
        if trackers.contains(where: { $0.source.configDir == dir }) || FileManager.default.fileExists(atPath: dir) {
            return L("An account with this name already exists.", "Bu adda bir hesap zaten var.")
        }
        return nil
    }

    /// Starts `claude auth login` for a new account called `name`, or for `existing` to sign it in again.
    func signIn(name: String, existing: UUID? = nil) {
        if login?.isActive == true { return }
        cancelSignIn()   // clears an earlier failed attempt
        let dir: String
        if let id = existing, let t = trackers.first(where: { $0.id == id }) { dir = t.source.configDir }
        else { dir = Model.accountsRoot + "/" + name }
        let s = LoginSession(name: name, dir: dir, existing: existing)
        login = s
        loginBag.removeAll()
        s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &loginBag)
        s.start { [weak self] ok in self?.loginExited(s, ok: ok) }
    }

    func cancelSignIn() {
        guard let s = login else { return }
        s.cancel()
        // A half-finished new account leaves nothing behind.
        if s.existing == nil, s.dir.hasPrefix(Model.accountsRoot + "/"), !trackers.contains(where: { $0.source.configDir == s.dir }) {
            try? FileManager.default.removeItem(atPath: s.dir)
        }
        login = nil
        loginBag.removeAll()
    }

    private func loginExited(_ s: LoginSession, ok: Bool) {
        guard ok else { s.state = .failed(L("Sign-in did not complete.", "Giriş tamamlanmadı.")); return }
        AuthCLI.status(dir: s.dir) { [weak self] st in
            guard let self, self.login === s else { return }
            guard let st, st.loggedIn else { s.state = .failed(L("Sign-in did not complete.", "Giriş tamamlanmadı.")); return }
            let acct = Account(email: st.email, plan: st.plan)
            if let id = s.existing, let t = self.trackers.first(where: { $0.id == id }) {
                t.signedIn(acct)
            } else {
                let first = !self.trackers.contains { $0.source.inMenuBar }
                let t = Tracker(source: AccountSource(name: s.name, configDir: s.dir, inMenuBar: first, owned: true), interval: self.interval)
                t.seed(acct)
                self.trackers.append(t)
                self.persist(); self.bind()
                t.refresh(force: true)
            }
            self.login = nil
            self.loginBag.removeAll()
        }
    }

    func setInMenuBar(_ id: UUID, _ on: Bool) {
        trackers.first { $0.id == id }?.source.inMenuBar = on
        persist()
    }

    /// Puts `id` where `target` is (used while dragging a row over another).
    func move(_ id: UUID, onto target: UUID) {
        guard id != target, let i = trackers.firstIndex(where: { $0.id == id }),
              let j = trackers.firstIndex(where: { $0.id == target }) else { return }
        trackers.move(fromOffsets: IndexSet(integer: i), toOffset: j > i ? j + 1 : j)
        persist()
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = trackers.firstIndex(where: { $0.id == id }), trackers.indices.contains(i + delta) else { return }
        trackers.swapAt(i, i + delta)
        persist()
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

struct ErrorLine: View {
    @ObservedObject var m: Model
    let t: Tracker

    var body: some View {
        if let e = t.lastError {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if case .rateLimited = e, t.isBackingOff {
                        Text("⚠︎ " + L("Rate limited — showing last value, next try ", "İstek sınırı — son değer gösteriliyor, sonraki deneme ")) + Text(t.backoffUntil, style: .time)
                    } else {
                        Text("⚠︎ " + errorText(e))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                if t.needsSignIn {
                    if let s = m.login, s.existing == t.id, s.isActive {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L("Waiting for the browser…", "Tarayıcı bekleniyor…")).font(.system(size: 11)).foregroundStyle(.secondary)
                            Button(L("Cancel", "Vazgeç")) { m.cancelSignIn() }.controlSize(.small)
                        }
                    } else {
                        if let s = m.login, s.existing == t.id, case .failed(let msg) = s.state {
                            Text(msg).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Button(L("Sign in again", "Yeniden giriş yap")) { m.signIn(name: t.title, existing: t.id) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

struct AccountBlock: View {
    @ObservedObject var m: Model
    let t: Tracker
    let showHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showHeader {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        if let s = t.subtitle {
                            Text(s).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { m.setInMenuBar(t.id, !t.source.inMenuBar) } label: {
                        Image(systemName: t.source.inMenuBar ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(t.source.inMenuBar ? L("Shown in the menu bar — click to hide", "Menü çubuğunda gösteriliyor — gizlemek için tıkla")
                                             : L("Show in the menu bar", "Menü çubuğunda göster"))
                }
            }
            LimitRow(m: m, title: L("5-hour", "5 saatlik"), limit: t.usage?.fiveHour)
            LimitRow(m: m, title: L("Weekly", "Haftalık"), limit: t.usage?.sevenDay)
            ErrorLine(m: m, t: t)
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
                    if m.trackers.count == 1, let a = m.trackers[0].account, !a.label.isEmpty {
                        Text(a.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if !m.trackers.isEmpty {
                    Button { m.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("Refresh now", "Şimdi yenile"))
                }
            }
            if m.trackers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("No accounts yet", "Henüz hesap yok")).font(.system(size: 13, weight: .semibold))
                    Text(L("Add a Claude account in Settings to see its usage limits.", "Kullanım limitlerini görmek için Ayarlar'dan bir Claude hesabı ekle."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(m.trackers.enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider() }
                AccountBlock(m: m, t: t, showHeader: m.trackers.count > 1)
            }

            Divider()
            HStack {
                Button(L("Settings…", "Ayarlar…"), action: openSettings)
                Spacer()
                if let t = m.trackers.compactMap(\.lastUpdate).max() {
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

enum SettingsSheet: Identifiable {
    case add
    case edit(Tracker)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let t): return "edit-\(t.id)"
        }
    }
}

/// Name the account, then sign in through the browser.
struct AddAccountSheet: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var started: Bool
    @State private var code = ""

    init(m: Model) {
        self.m = m
        _started = State(initialValue: m.login != nil)   // signing an existing account in again
    }

    private var nameError: String? { name.isEmpty ? nil : m.nameError(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(m.login?.existing == nil ? L("Add account", "Hesap ekle") : L("Sign in again", "Yeniden giriş yap")).font(.headline)
            if let s = m.login {
                switch s.state {
                case .waiting: waiting(s)
                case .failed(let msg): failed(s, msg)
                }
            } else {
                Text(L("Choose a name, then sign in to Claude in your browser. The login is kept separate from your other Claude logins.",
                       "Bir ad seç, sonra tarayıcıda Claude'a giriş yap. Bu giriş diğer Claude girişlerinden ayrı tutulur."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(L("Name", "Ad"), text: $name, prompt: Text("work"))
                    .onSubmit { go() }
                if let e = nameError { Text(e).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button(L("Cancel", "Vazgeç")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("Sign in…", "Giriş yap…")) { go() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.isEmpty || nameError != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: m.login == nil) { gone in
            if started && gone { dismiss() }   // signed in, or cancelled
        }
    }

    private func go() {
        guard !name.isEmpty, nameError == nil else { return }
        started = true
        m.signIn(name: name)
    }

    @ViewBuilder private func waiting(_ s: LoginSession) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("Waiting for you to sign in in the browser…", "Tarayıcıda giriş yapman bekleniyor…"))
        }
        if let u = s.url {
            Text(L("Browser didn't open? Open the link yourself. If the page shows a code, paste it below.",
                   "Tarayıcı açılmadı mı? Bağlantıyı kendin aç. Sayfa bir kod gösterirse aşağıya yapıştır."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Copy link", "Bağlantıyı kopyala")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(u, forType: .string)
                }
                Button(L("Open link", "Bağlantıyı aç")) { if let url = URL(string: u) { NSWorkspace.shared.open(url) } }
            }
            HStack {
                TextField(L("Code (only if the page shows one)", "Kod (yalnızca sayfa gösteriyorsa)"), text: $code)
                    .onSubmit { s.submit(code: code) }
                Button(L("Submit", "Gönder")) { s.submit(code: code) }.disabled(code.isEmpty)
            }
        }
        HStack {
            Spacer()
            Button(L("Cancel", "Vazgeç")) { m.cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private func failed(_ s: LoginSession, _ msg: String) -> some View {
        Text("⚠︎ " + msg).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(L("Close", "Kapat")) { m.cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Try again", "Tekrar dene")) {
                let n = s.name, e = s.existing
                m.cancelSignIn()
                m.signIn(name: n, existing: e)
            }.keyboardShortcut(.defaultAction)
        }
    }
}

struct AccountEditor: View {
    @ObservedObject var m: Model
    let t: Tracker
    let onSignIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var dir: String
    @State private var error: String?

    init(m: Model, t: Tracker, onSignIn: @escaping () -> Void) {
        self.m = m
        self.t = t
        self.onSignIn = onSignIn
        _name = State(initialValue: t.source.name)
        _dir = State(initialValue: t.source.configDir)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.message = L("Choose a Claude config folder (contains .credentials.json)", "Bir Claude yapılandırma klasörü seç (.credentials.json içeren)")
        if p.runModal() == .OK, let u = p.url { dir = u.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Edit account", "Hesabı düzenle")).font(.headline)
            TextField(L("Name", "Ad"), text: $name, prompt: Text(t.account?.email ?? L("Optional", "İsteğe bağlı")))
            if !t.source.owned {
                HStack {
                    TextField(L("Config folder", "Klasör"), text: $dir)
                    Button(L("Choose…", "Seç…"), action: choose)
                }
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(L("Sign in again…", "Yeniden giriş yap…"), action: onSignIn)
                    .help(L("Sign in to this account again, or switch the Claude account behind it", "Bu hesapta yeniden giriş yap veya arkasındaki Claude hesabını değiştir"))
                Spacer()
                Button(L("Cancel", "Vazgeç")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "Kaydet")) {
                    if dir.trimmingCharacters(in: .whitespaces).isEmpty { error = L("Choose a folder.", "Bir klasör seç."); return }
                    if m.update(id: t.id, name: name, configDir: dir) { dismiss() }
                    else { error = L("This folder is already added.", "Bu klasör zaten ekli.") }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Reorders accounts live while a row is dragged over the others.
struct RowDrop: DropDelegate {
    let target: Tracker
    let m: Model
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let from = dragging else { return }
        withAnimation(.easeInOut(duration: 0.15)) { m.move(from, onto: target.id) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var sheet: SettingsSheet?
    @State private var deleting: Tracker?
    @State private var dragging: UUID?

    private func row(_ t: Tracker, index: Int) -> some View {
        let dup = m.trackers.first { $0.id != t.id && t.account?.email != nil && $0.account?.email == t.account?.email }
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                .help(L("Drag to reorder", "Sıralamak için sürükle"))
            Toggle("", isOn: Binding(get: { t.source.inMenuBar }, set: { m.setInMenuBar(t.id, $0) }))
                .labelsHidden()
                .help(L("Show in the menu bar", "Menü çubuğunda göster"))
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let s = t.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(t.source.owned ? L("Signed in with this app", "Bu uygulamayla giriş yapıldı") : t.source.configDir)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if t.needsSignIn, let e = t.lastError {
                    HStack(spacing: 6) {
                        Text("⚠︎ " + errorText(e)).font(.caption2).foregroundStyle(.orange)
                        Button(L("Sign in again", "Yeniden giriş yap")) {
                            m.signIn(name: t.title, existing: t.id)
                            sheet = .add
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                }
                if let dup {
                    Text("⚠︎ " + L("Same account as \(dup.title)", "\(dup.title) ile aynı hesap"))
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { sheet = .edit(t) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help(L("Edit", "Düzenle"))
            Button { deleting = t } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(L("Remove", "Kaldır"))
        }
        .opacity(dragging == t.id ? 0.4 : 1)
        .onDrag {
            dragging = t.id
            return NSItemProvider(object: t.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: RowDrop(target: t, m: m, dragging: $dragging))
        .contextMenu {   // fallback for dragging
            Button(L("Move up", "Yukarı taşı")) { m.move(t.id, by: -1) }.disabled(index == 0)
            Button(L("Move down", "Aşağı taşı")) { m.move(t.id, by: 1) }.disabled(index == m.trackers.count - 1)
        }
    }

    var body: some View {
        Form {
            Section(L("Accounts", "Hesaplar")) {
                if m.trackers.isEmpty {
                    Text(L("No accounts yet.", "Henüz hesap yok.")).foregroundStyle(.secondary)
                }
                ForEach(Array(m.trackers.enumerated()), id: \.element.id) { i, t in row(t, index: i) }
                Button(L("Add account…", "Hesap ekle…")) { sheet = .add }
            }
            Section(L("Menu bar", "Menü çubuğu")) {
                Toggle(L("Also show weekly limit", "Haftalık limiti de göster"), isOn: $m.showWeekly)
                Toggle(L("Show used % instead of remaining %", "Kalan yerine kullanılan % göster"), isOn: $m.showUsed)
                Picker(L("Icon", "Simge"), selection: $m.icon) {
                    ForEach(menuIcons, id: \.key) { i in
                        if i.symbol.isEmpty { Text(L(i.en, i.tr)).tag(i.key) }
                        else { Label(L(i.en, i.tr), systemImage: i.symbol).tag(i.key) }
                    }
                }
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
        .frame(minWidth: 480, idealWidth: 480, minHeight: 420, idealHeight: 600)
        .sheet(item: $sheet) { s in
            switch s {
            case .add: AddAccountSheet(m: m)
            case .edit(let t):
                AccountEditor(m: m, t: t) {
                    m.signIn(name: t.title, existing: t.id)
                    sheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sheet = .add }   // show the sign-in window
                }
            }
        }
        .alert(L("Remove this account?", "Bu hesap kaldırılsın mı?"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Remove", "Kaldır"), role: .destructive) { if let t = deleting { m.remove(t.id) }; deleting = nil }
            Button(L("Cancel", "Vazgeç"), role: .cancel) { deleting = nil }
        } message: {
            let title = deleting?.title ?? ""
            Text(deleting?.source.owned == true
                 ? L("\"\(title)\" will be signed out and its saved login deleted.", "\"\(title)\" oturumdan çıkarılacak ve kayıtlı girişi silinecek.")
                 : L("\"\(title)\" will no longer be tracked. Its Claude login is not touched.", "\"\(title)\" artık izlenmeyecek. Claude girişine dokunulmaz."))
        }
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
            if model.trackers.count > 1 {
                let sub = NSMenu()
                for t in model.trackers {
                    let i = NSMenuItem(title: t.title, action: #selector(toggleAccount(_:)), keyEquivalent: "")
                    i.target = self
                    i.state = t.source.inMenuBar ? .on : .off
                    i.representedObject = t.id
                    sub.addItem(i)
                }
                let parent = NSMenuItem(title: L("Menu bar accounts", "Menü çubuğu hesapları"), action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
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

    @objc private func toggleAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let t = model.trackers.first(where: { $0.id == id }) else { return }
        model.setInMenuBar(id, !t.source.inMenuBar)
    }

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
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = L("Claude Usage Bar — Settings", "Claude Usage Bar — Ayarlar")
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 480, height: 600))
            w.contentMinSize = NSSize(width: 480, height: 420)
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
        func addAccount(_ t: Tracker) {
            guard let u = t.usage, let five = u.fiveHour else {
                add(t.lastError == nil ? "…" : "⚠︎")
                return
            }
            add("\(model.value(five))%", tint(five))
            if model.showWeekly, let w = u.sevenDay {
                add(" · ")
                add("\(model.value(w))%", tint(w))
            }
            if t.lastError != nil { add(" ⚠︎") }
        }

        // The accounts ticked in Settings, in list order; the first one if none is ticked.
        let ticked = model.trackers.filter { $0.source.inMenuBar }
        let shown = ticked.isEmpty ? Array(model.trackers.prefix(1)) : ticked
        for (i, t) in shown.enumerated() {
            if i > 0 { add(" | ") }
            addAccount(t)
        }
        if shown.isEmpty { add("—") }
        item.button?.attributedTitle = out
        if let sym = menuIcons.first(where: { $0.key == model.icon })?.symbol, !sym.isEmpty,
           let img = NSImage(systemSymbolName: sym, accessibilityDescription: "Claude usage")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            img.isTemplate = true
            item.button?.image = img
            item.button?.imagePosition = .imageLeading
        } else {
            item.button?.image = nil
        }
        item.button?.toolTip = shown.count > 1 ? shown.map(\.title).joined(separator: " | ") : nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
