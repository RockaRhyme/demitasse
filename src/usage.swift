import Foundation

// Subscription usage for the AI coding CLIs signed in on this Mac. Credentials are read
// where each CLI keeps them. A live token is used as is; an expired Claude or ChatGPT token
// is renewed and, because those refresh tokens rotate, the new tokens are written back in
// the CLI's own format so the CLI stays signed in.

struct UsageWindow {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct AccountUsage {
    let title: String
    var windows: [UsageWindow] = []
    var note: String? = nil
    // Banked limit resets that can be redeemed (ChatGPT only), soonest-expiring first.
    var resetCredits: [(id: String, expires: Date?)] = []
}

enum Usage {
    static func fetchAll() async -> [AccountUsage] {
        async let c = claude()
        async let x = codex()
        async let g = antigravity()
        return await c + x + g
    }

    // MARK: Claude — every "Claude Code-credentials*" keychain entry, one row per account

    private static var claudeIdentityByToken: [String: [String]] = [:]  // token -> [key, title]

    private static func claude() async -> [AccountUsage] {
        // Claude Code writes these entries with /usr/bin/security, so reading them the same
        // way doesn't raise a keychain prompt.
        let dump = run("/usr/bin/security", ["dump-keychain"]) ?? ""
        let regex = try! NSRegularExpression(pattern: "\"svce\"<blob>=\"(Claude Code-credentials[^\"]*)\"")
        var services = Set<String>()
        for m in regex.matches(in: dump, range: NSRange(dump.startIndex..., in: dump)) {
            if let r = Range(m.range(at: 1), in: dump) { services.insert(String(dump[r])) }
        }

        let defaults = UserDefaults.standard
        var remembered = defaults.dictionary(forKey: "claudeIdentities") as? [String: [String]] ?? [:]
        var best: [String: (title: String, service: String, token: String, expires: Date)] = [:]
        var expiredUnknown = false
        for service in services.sorted() {
            guard let raw = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]),
                  let oauth = json(Data(raw.utf8))["claudeAiOauth"] as? [String: Any],
                  var token = oauth["accessToken"] as? String else { continue }
            var expires = Date(timeIntervalSince1970: (oauth["expiresAt"] as? Double ?? 0) / 1000)
            var identity = claudeIdentityByToken[token]
            // An expired sign-in that was never identified: renew it first so the profile lookup can run.
            if identity == nil, remembered[service] == nil, expires <= Date(), let fresh = await renewClaude(service: service) {
                (token, expires) = fresh
                identity = claudeIdentityByToken[token]
            }
            if identity == nil, expires > Date() {
                let (status, profile) = await http("https://api.anthropic.com/api/oauth/profile", headers: claudeHeaders(token))
                if status == 200, let email = (profile["account"] as? [String: Any])?["email"] as? String {
                    let org = profile["organization"] as? [String: Any] ?? [:]
                    let plan = org["organization_type"] as? String ?? "claude_\(oauth["subscriptionType"] as? String ?? "")"
                    let title = plan.replacingOccurrences(of: "_", with: " ").capitalized + " · " + email
                    identity = [email + "|" + (org["uuid"] as? String ?? ""), title]
                    claudeIdentityByToken[token] = identity
                    remembered[service] = identity
                }
            }
            guard let id = identity ?? remembered[service], id.count == 2 else {
                if expires <= Date() { expiredUnknown = true }
                continue
            }
            if best[id[0]].map({ $0.expires < expires }) ?? true { best[id[0]] = (id[1], service, token, expires) }
        }
        defaults.set(remembered, forKey: "claudeIdentities")

        var rows: [AccountUsage] = []
        for account in best.values.sorted(by: { $0.title < $1.title }) {
            var row = AccountUsage(title: account.title)
            let token = account.expires > Date() && !forceRenew ? account.token : await renewClaude(service: account.service)?.token
            if let token {
                let (status, body) = await http("https://api.anthropic.com/api/oauth/usage", headers: claudeHeaders(token))
                if debug { print("claude: usage HTTP \(status):", body) }
                if status == 200 {
                    // Newer responses list every limit, including per-model weekly ones (e.g. Fable).
                    for limit in body["limits"] as? [[String: Any]] ?? [] {
                        guard let used = limit["percent"] as? Double else { continue }
                        let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                        let label: String
                        switch limit["kind"] as? String {
                        case "session": label = "5h"
                        case "weekly_all": label = "Wk"
                        case "weekly_scoped": label = (model ?? "Scoped") + " Wk"
                        default: continue
                        }
                        row.windows.append(UsageWindow(label: label, usedPercent: used, resetsAt: isoDate(limit["resets_at"] as? String)))
                    }
                    for (label, key) in row.windows.isEmpty ? [("5h", "five_hour"), ("Wk", "seven_day")] : [] {
                        guard let w = body[key] as? [String: Any], let used = w["utilization"] as? Double else { continue }
                        row.windows.append(UsageWindow(label: label, usedPercent: used, resetsAt: isoDate(w["resets_at"] as? String)))
                    }
                    if row.windows.isEmpty { row.note = "no usage limits reported" }
                } else {
                    row.note = failure(status, cli: "Claude Code")
                }
            } else {
                row.note = "sign-in expired — sign in again in Claude Code"
            }
            if unsavedClaude[account.service] != nil, row.note == nil {
                row.note = "renewed sign-in couldn't be saved — Claude Code may ask you to sign in again"
            }
            rows.append(row)
        }
        if rows.isEmpty, expiredUnknown {
            rows.append(AccountUsage(title: "Claude", note: "sign-in expired — sign in again in Claude Code"))
        }
        return rows
    }

    // Renews an expired sign-in with its refresh token and stores the result back in the
    // keychain entry the way Claude Code does, keeping every other field of the entry.
    private static func renewClaude(service: String) async -> (token: String, expires: Date)? {
        // Re-read first: a running Claude Code may have renewed it already.
        guard var stored = readClaude(service), var oauth = stored["claudeAiOauth"] as? [String: Any] else { return nil }
        let inKeychain = oauth["refreshToken"] as? String
        if let pending = unsavedClaude[service] {
            // An earlier renewal couldn't be saved. If the keychain still holds the refresh token
            // it spent, carry on from the renewed tokens and try saving them again.
            if pending.spent == inKeychain, let kept = pending.stored["claudeAiOauth"] as? [String: Any] {
                (stored, oauth) = (pending.stored, kept)
                if saveClaude(service, stored) { unsavedClaude[service] = nil }
            } else {
                unsavedClaude[service] = nil
            }
        }
        if !forceRenew, let token = oauth["accessToken"] as? String {
            let expires = claudeExpiry(oauth)
            if expires > Date() { return (token, expires) }
        }
        guard let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else { return nil }

        var request: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh,
                                      "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]  // Claude Code's public client
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty { request["scope"] = scopes.joined(separator: " ") }
        let (status, body) = await http("https://platform.claude.com/v1/oauth/token", method: "POST",
                                        headers: ["Content-Type": "application/json"],
                                        body: try? JSONSerialization.data(withJSONObject: request))
        guard status == 200, let token = body["access_token"] as? String else {
            if debug { print("claude: renewal HTTP \(status):", body["error"] ?? "", body["error_description"] ?? "") }
            return nil
        }
        oauth["accessToken"] = token
        if let rotated = body["refresh_token"] as? String { oauth["refreshToken"] = rotated }
        let expires = Date().addingTimeInterval(body["expires_in"] as? Double ?? 3600)
        oauth["expiresAt"] = Int(expires.timeIntervalSince1970 * 1000)
        if let scope = body["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        stored["claudeAiOauth"] = oauth

        // Claude Code may have renewed, switched account or signed out during the request;
        // whatever it wrote wins over this renewal.
        guard let current = readClaude(service)?["claudeAiOauth"] as? [String: Any] else { return nil }
        if current["refreshToken"] as? String != inKeychain {
            unsavedClaude[service] = nil
            return (current["accessToken"] as? String).map { ($0, claudeExpiry(current)) }
        }
        let saved = saveClaude(service, stored)
        unsavedClaude[service] = saved ? nil : (inKeychain ?? "", stored)
        if debug { print("claude: renewed \(service), keychain write \(saved ? "ok" : "FAILED")") }
        return (token, expires)
    }

    // Renewed entries whose keychain write failed, kept so the rotated refresh token isn't lost.
    private static var unsavedClaude: [String: (spent: String, stored: [String: Any])] = [:]

    private static func readClaude(_ service: String) -> [String: Any]? {
        run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]).map { json(Data($0.utf8)) }
    }

    private static func claudeExpiry(_ oauth: [String: Any]) -> Date {
        Date(timeIntervalSince1970: (oauth["expiresAt"] as? Double ?? 0) / 1000)
    }

    private static func saveClaude(_ service: String, _ stored: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: stored, options: [.withoutEscapingSlashes]) else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(NSUserName())\" -s \"\(service)\" -X \"\(hex)\""
        // Via stdin keeps the secret out of the process list; `security -i` caps line length,
        // so long entries go as arguments (Claude Code does the same).
        let saved = command.utf8.count < 4000
            ? run("/usr/bin/security", ["-i"], input: command + "\n")
            : run("/usr/bin/security", ["add-generic-password", "-U", "-a", NSUserName(), "-s", service, "-X", hex])
        return saved != nil
    }

    private static func claudeHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]
    }

    // MARK: ChatGPT — the Codex CLI sign-in in ~/.codex/auth.json

    private static func codex() async -> [AccountUsage] {
        guard let tokens = codexTokens(), var token = tokens["access_token"] as? String else { return [] }
        let email = jwtPayload(tokens["id_token"] as? String)["email"] as? String
        var headers = ["User-Agent": "codex_cli_rs"]
        if let account = tokens["account_id"] as? String { headers["chatgpt-account-id"] = account }

        var renewed = false
        if forceRenew || (jwtPayload(token)["exp"] as? Double ?? .infinity) < Date().timeIntervalSince1970 {
            token = await renewCodex() ?? token
            renewed = true
        }
        headers["Authorization"] = "Bearer \(token)"
        var (status, body) = await http("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        if status == 401, !renewed, let fresh = await renewCodex() {
            headers["Authorization"] = "Bearer \(fresh)"
            (status, body) = await http("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        }

        if debug { print("codex: usage HTTP \(status):", body) }
        let plan = (body["plan_type"] as? String).map { " " + $0.capitalized } ?? ""
        var row = AccountUsage(title: "ChatGPT" + plan + (email.map { " · " + $0 } ?? ""))
        guard status == 200 else {
            row.note = status == 401 ? "sign-in expired — sign in again in Codex" : failure(status, cli: "Codex")
            return [row]
        }
        let limits = body["rate_limit"] as? [String: Any] ?? [:]
        for key in ["primary_window", "secondary_window"] {
            guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
            var resets: Date?
            if let at = w["reset_at"] as? Double {
                resets = Date(timeIntervalSince1970: at)
            } else if let after = w["reset_after_seconds"] as? Double {
                resets = Date().addingTimeInterval(after)
            }
            let seconds = w["limit_window_seconds"] as? Double ?? 0
            let label = seconds >= 6 * 86400 ? "Wk" : seconds >= 86400 ? "\(Int(seconds / 86400))d" : "\(Int(seconds / 3600))h"
            row.windows.append(UsageWindow(label: label, usedPercent: used, resetsAt: resets))
        }
        if row.windows.isEmpty { row.note = "no usage limits reported" }
        if unsavedCodex != nil, row.note == nil {
            row.note = "renewed sign-in couldn't be saved — Codex may ask you to sign in again"
        }

        if ((body["rate_limit_reset_credits"] as? [String: Any])?["available_count"] as? Int ?? 0) > 0 {
            let (code, banked) = await http(codexResetsURL, headers: headers)
            if debug { print("codex: reset credits HTTP \(code):", banked) }
            row.resetCredits = (banked["credits"] as? [[String: Any]] ?? [])
                .filter { $0["status"] as? String == "available" && $0["is_supported_by_plan"] as? Bool != false }
                .compactMap { credit in (credit["id"] as? String).map { ($0, isoDate(credit["expires_at"] as? String)) } }
                .sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
        }
        return [row]
    }

    private static let codexResetsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

    // Spends one banked reset. Returns a sentence describing what happened.
    static func redeemCodexReset(_ creditID: String) async -> String {
        guard let tokens = codexTokens(), let token = tokens["access_token"] as? String else { return "Not signed in to Codex." }
        var headers = ["Authorization": "Bearer \(token)", "User-Agent": "codex_cli_rs", "Content-Type": "application/json"]
        if let account = tokens["account_id"] as? String { headers["chatgpt-account-id"] = account }
        let request = ["redeem_request_id": UUID().uuidString.lowercased(), "credit_id": creditID]
        let (status, body) = await http(codexResetsURL + "/consume", method: "POST", headers: headers,
                                        body: try? JSONSerialization.data(withJSONObject: request))
        if debug { print("codex: consume HTTP \(status):", body) }
        switch (body["outcome"] as? String ?? "").replacingOccurrences(of: "_", with: "").lowercased() {
        case "reset": return "Your ChatGPT usage limits were reset."
        case "nothingtoreset": return "Your usage doesn't need a reset right now. No reset was used."
        case "nocredit", "alreadyredeemed": return "That reset is no longer available."
        default: return "Couldn't reset usage (HTTP \(status)). Check Codex before trying again."
        }
    }

    private static let codexAuthPath = NSHomeDirectory() + "/.codex/auth.json"

    private static func codexTokens() -> [String: Any]? {
        FileManager.default.contents(atPath: codexAuthPath).flatMap { json($0)["tokens"] as? [String: Any] }
    }

    // Renews the Codex sign-in with its refresh token and rewrites auth.json the way Codex
    // does, keeping every other field of the file.
    private static func renewCodex() async -> String? {
        guard let data = FileManager.default.contents(atPath: codexAuthPath) else { return nil }
        var stored = json(data)
        guard var tokens = stored["tokens"] as? [String: Any] else { return nil }
        let onDisk = tokens["refresh_token"] as? String
        if let pending = unsavedCodex {
            // An earlier renewal couldn't be saved. If auth.json still holds the refresh token
            // it spent, carry on from the renewed tokens and try saving them again.
            if pending.spent == onDisk, let kept = pending.stored["tokens"] as? [String: Any] {
                (stored, tokens) = (pending.stored, kept)
                if saveCodex(stored) { unsavedCodex = nil }
                if !forceRenew, let token = tokens["access_token"] as? String,
                   (jwtPayload(token)["exp"] as? Double ?? 0) > Date().timeIntervalSince1970 { return token }
            } else {
                unsavedCodex = nil
            }
        }
        guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else { return nil }
        let request = ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann",  // Codex's public client
                       "grant_type": "refresh_token", "refresh_token": refresh, "scope": "openid profile email"]
        let (status, body) = await http("https://auth.openai.com/oauth/token", method: "POST",
                                        headers: ["Content-Type": "application/json"],
                                        body: try? JSONSerialization.data(withJSONObject: request))
        guard status == 200, let token = body["access_token"] as? String else {
            if debug { print("codex: renewal HTTP \(status):", body["error"] ?? "") }
            return nil
        }
        tokens["access_token"] = token
        for key in ["id_token", "refresh_token"] { if let value = body[key] as? String { tokens[key] = value } }
        stored["tokens"] = tokens
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        stored["last_refresh"] = stamp.string(from: Date())

        // Codex may have renewed, switched account or signed out during the request;
        // whatever it wrote wins over this renewal.
        guard let current = codexTokens() else { return nil }
        if current["refresh_token"] as? String != onDisk {
            unsavedCodex = nil
            return current["access_token"] as? String
        }
        let saved = saveCodex(stored)
        unsavedCodex = saved ? nil : (onDisk ?? "", stored)
        if debug { print("codex: renewed, auth.json write \(saved ? "ok" : "FAILED")") }
        return token
    }

    // A renewed auth.json whose write failed, kept so the rotated refresh token isn't lost.
    private static var unsavedCodex: (spent: String, stored: [String: Any])?

    private static func saveCodex(_ stored: [String: Any]) -> Bool {
        // Owner-only temp file, then an atomic rename over auth.json.
        let temp = codexAuthPath + ".demitasse-tmp"
        guard let out = try? JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .withoutEscapingSlashes]),
              FileManager.default.createFile(atPath: temp, contents: out, attributes: [.posixPermissions: 0o600]) else { return false }
        return rename(temp, codexAuthPath) == 0
    }

    // MARK: Google — the Antigravity CLI (agy) sign-in in ~/.gemini/jetski-standalone-oauth-token

    // Antigravity's installed-app OAuth clients aren't ours to publish, so they're read from
    // ~/.config/demitasse/google-oauth.json: [{"client_id": "…", "client_secret": "…"}].
    // Google access tokens last an hour and the refresh token doesn't rotate, so refreshing
    // in memory is safe.
    private static var googleClients: [(String, String)] {
        let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.config/demitasse/google-oauth.json") ?? Data()
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] ?? []
        return list.compactMap { c in c["client_id"].flatMap { id in c["client_secret"].map { (id, $0) } } }
    }
    private static var googleToken: (value: String, expires: Date)?
    private static var googleAccount: (project: String, title: String)?
    private static var googleRefresh: String?  // the sign-in the two caches above belong to
    static let debug = CommandLine.arguments.contains("--debug")
    // `--renew` treats the Claude and ChatGPT tokens as expired, to exercise renewal.
    static let forceRenew = CommandLine.arguments.contains("--renew")

    private static func antigravity() async -> [AccountUsage] {
        let cli = "Antigravity (agy)"
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.gemini/jetski-standalone-oauth-token") else { return [] }
        let stored = json(data)
        let creds = stored["token"] as? [String: Any] ?? stored
        guard let refresh = (creds["refresh_token"] ?? creds["refreshToken"]) as? String else {
            if debug { print("antigravity: no refresh token; top-level keys:", stored.keys.sorted()) }
            return [AccountUsage(title: "Antigravity", note: "sign-in not readable")]
        }

        if refresh != googleRefresh {  // a different sign-in: drop the previous account's token and identity
            googleRefresh = refresh
            googleToken = nil
            googleAccount = nil
        }

        let clients = googleClients
        guard !clients.isEmpty else { return [AccountUsage(title: "Antigravity", note: "needs Google client config — see README")] }

        if googleToken.map({ $0.expires < Date().addingTimeInterval(60) }) ?? true {
            var status = 0
            for (id, secret) in clients {
                var form = URLComponents()
                form.queryItems = [
                    URLQueryItem(name: "client_id", value: id),
                    URLQueryItem(name: "client_secret", value: secret),
                    URLQueryItem(name: "refresh_token", value: refresh),
                    URLQueryItem(name: "grant_type", value: "refresh_token"),
                ]
                let (code, body) = await http("https://oauth2.googleapis.com/token", method: "POST",
                                              headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                              body: Data((form.percentEncodedQuery ?? "").utf8))
                status = code
                if code == 200, let token = body["access_token"] as? String {
                    googleToken = (token, Date().addingTimeInterval(body["expires_in"] as? Double ?? 3600))
                    break
                }
                if debug { print("antigravity: token renewal HTTP \(code):", body["error"] ?? "", body["error_description"] ?? "") }
                if code == 0 { break }
            }
            if googleToken.map({ $0.expires < Date() }) ?? true {
                return [AccountUsage(title: "Antigravity", note: failure(status == 400 ? 401 : status, cli: cli))]
            }
        }
        guard let token = googleToken?.value else { return [] }
        // The API only serves clients that identify as Antigravity.
        let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json",
                       "User-Agent": "antigravity/1.2.16 darwin/arm64"]
        let base = "https://cloudcode-pa.googleapis.com/v1internal:"

        if googleAccount == nil {
            var status = 0
            var body: [String: Any] = [:]
            for ide in ["ANTIGRAVITY", "JETSKI"] {
                let request: [String: Any] = ["metadata": ["ideType": ide, "platform": "DARWIN_ARM64", "pluginType": "GEMINI"]]
                (status, body) = await http(base + "loadCodeAssist", method: "POST", headers: headers,
                                            body: try? JSONSerialization.data(withJSONObject: request))
                if debug { print("antigravity: loadCodeAssist as \(ide) HTTP \(status):", body) }
                if body["cloudaicompanionProject"] != nil || body["currentTier"] != nil || body["paidTier"] != nil { break }
            }
            guard status == 200 else { return [AccountUsage(title: "Antigravity", note: failure(status, cli: cli))] }
            let project = body["cloudaicompanionProject"]
            let id = project as? String ?? (project as? [String: Any])?["id"] as? String ?? ""
            let tier = (body["paidTier"] as? [String: Any] ?? body["currentTier"] as? [String: Any])?["name"] as? String
            let (_, user) = await http("https://www.googleapis.com/oauth2/v2/userinfo", headers: headers)
            googleAccount = (id, (tier ?? "Antigravity") + ((user["email"] as? String).map { " · " + $0 } ?? ""))
        }
        var row = AccountUsage(title: googleAccount!.title)
        let request = googleAccount!.project.isEmpty ? [:] : ["project": googleAccount!.project]
        let (status, body) = await http(base + "retrieveUserQuotaSummary", method: "POST", headers: headers,
                                        body: try? JSONSerialization.data(withJSONObject: request))
        if debug { print("antigravity: retrieveUserQuotaSummary HTTP \(status):", body) }
        guard status == 200 else {
            row.note = failure(status, cli: cli)
            return [row]
        }
        // Two quota pools, each with a 5h and a weekly bucket: Gemini models, and the Claude and
        // GPT models Antigravity can run against the Google plan.
        for group in body["groups"] as? [[String: Any]] ?? [] {
            let family = (group["displayName"] as? String ?? "").replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " and ", with: "/")
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).filter { $0["disabled"] as? Bool != true }
            for bucket in buckets.sorted(by: { ($0["window"] as? String ?? "") < ($1["window"] as? String ?? "") }) {
                let window = bucket["window"] as? String ?? ""
                let name = family + " " + (window == "weekly" ? "Wk" : window)
                row.windows.append(UsageWindow(label: name, usedPercent: (1 - (bucket["remainingFraction"] as? Double ?? 0)) * 100,
                                               resetsAt: isoDate(bucket["resetTime"] as? String)))
            }
        }
        if row.windows.isEmpty { row.note = "no quota reported" }
        return [row]
    }

    // MARK: Helpers

    private static func failure(_ status: Int, cli: String) -> String {
        switch status {
        case 401: return "sign-in expired — open \(cli) to renew"
        case 429: return "rate limited — try again shortly"
        case 0: return "offline"
        default: return "usage unavailable (HTTP \(status))"
        }
    }

    private static func run(_ path: String, _ args: [String], input: String? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { p.standardInput = stdin }
        do { try p.run() } catch { return nil }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            stdin.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private static func http(_ url: String, method: String = "GET", headers: [String: String], body: Data? = nil) async -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: request) else { return (0, [:]) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json(data))
    }

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func jwtPayload(_ jwt: String?) -> [String: Any] {
        guard let parts = jwt?.split(separator: "."), parts.count > 1 else { return [:] }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64).map(json) ?? [:]
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        // Fractional seconds vary in length (Claude sends microseconds); drop them.
        let trimmed = string.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
