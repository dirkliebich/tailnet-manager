import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

// MARK: - Saved scans

/// The last scan of each server, kept on this device so the Services page
/// shows something before (and between) scans.
enum ServiceScanStore {
    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TailnetManager")
    }
    /// Bump when ServerScan (or anything it holds) changes shape. Saved scans
    /// are a cache of what the servers report, so an old file is just
    /// dropped and the next scan fills a new one.
    private static let formatVersion = 5
    private static var url: URL? { folder?.appendingPathComponent("services-inventory-v\(formatVersion).json") }

    static func load() -> [String: ServerScan] {
        // Files from older versions are just a stale cache.
        if let folder {
            let old = ["services-inventory.json"] + (1..<formatVersion).map { "services-inventory-v\($0).json" }
            for name in old { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        }
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let scans = (try? decoder.decode([ServerScan].self, from: data)) ?? []
        return Dictionary(scans.map { ($0.deviceID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func save(_ scans: [String: ServerScan]) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(scans.values.sorted { $0.serverName < $1.serverName }) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Scan state

enum ServerScanState: Equatable {
    case idle
    case scanning(login: String)
    /// Tailscale SSH "check" rule: someone has to confirm in the browser.
    case waitingForApproval(URL)
    case failed(String)
    case done
}

/// Runs and remembers the service scans. Lives on AppState so a scan keeps
/// going when the admin leaves the page.
@MainActor
@Observable
final class ServiceInventory {
    private(set) var scans: [String: ServerScan] = ServiceScanStore.load() {
        didSet { revision &+= 1 }
    }
    private(set) var states: [String: ServerScanState] = [:] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every change to scans or states, so derived lists (alerts,
    /// inventory rows, activity) are rebuilt once per change, not per redraw.
    private(set) var revision = 0
    private(set) var isScanning = false

    /// Re-check servers in the background every 30 minutes so Home's
    /// "Needs attention" stays current. Read-only; on by default.
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "servicesAutoCheck") }
    }
    /// When the last scan (manual or automatic) started.
    private(set) var lastRunAt: Date?

    /// Sign-in names tried on each server, in order, until one works.
    var loginNames: String {
        didSet { UserDefaults.standard.set(loginNames, forKey: "servicesLoginNames") }
    }
    /// The name that worked last time, per server.
    private var rememberedLogins: [String: String] {
        didSet { UserDefaults.standard.set(rememberedLogins, forKey: "servicesRememberedLogins") }
    }

    init() {
        loginNames = UserDefaults.standard.string(forKey: "servicesLoginNames") ?? ""
        autoCheck = UserDefaults.standard.object(forKey: "servicesAutoCheck") as? Bool ?? true
        rememberedLogins = UserDefaults.standard.dictionary(forKey: "servicesRememberedLogins") as? [String: String] ?? [:]
    }

    func state(of deviceID: String) -> ServerScanState { states[deviceID] ?? .idle }

    #if os(macOS)
    /// The scan stopped because the server's SSH identity changed (rebuilt,
    /// Tailscale reinstalled). Over Tailscale the connection itself is
    /// authenticated, so the admin may choose to trust the new identity.
    func identityChanged(_ deviceID: String) -> Bool {
        states[deviceID] == .failed(SSHResult.identityChanged)
    }

    /// Forgets the saved identity of these addresses; the next scan saves the new one.
    func forgetIdentity(of addresses: [String]) {
        guard let path = SSHRunner.knownHostsPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let drop = Set(addresses)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let hosts = line.split(separator: " ").first.map { $0.split(separator: ",").map(String.init) } ?? []
            return !hosts.contains { drop.contains($0) || drop.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) }
        }
        try? kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    #endif

    /// Names to try on a server: the one that worked before, then the
    /// configured ones, then root when the access rules name it explicitly.
    func logins(for server: Device, allowed: [String]?) -> [String] {
        var out: [String] = []
        if let last = rememberedLogins[server.id] { out.append(last) }
        out += loginNames.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        if let allowed {
            out += allowed.filter { !$0.hasPrefix("autogroup:") && !$0.hasPrefix("localpart:") }
            // Only "autogroup:nonroot" granted: root would be refused.
            if !allowed.contains("root") { out.removeAll { $0 == "root" } }
        }
        var seen = Set<String>()
        return out.filter { Self.isValidLogin($0) && seen.insert($0).inserted }
    }

    /// Plain Unix user names only. Names can come from the access rules,
    /// which other admins edit; anything else (e.g. "-oProxyCommand=…")
    /// could steer ssh on this Mac.
    nonisolated static func isValidLogin(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$"#, options: .regularExpression) != nil
    }

    #if os(macOS)
    /// Scans servers a few at a time. `allowedLogins` returns the sign-in
    /// names the access rules allow on a server (nil when unknown).
    /// `interactive: false` (the automatic check) never opens an approval
    /// page in the browser; the server just shows "waiting for approval".
    func scan(_ servers: [Device], machinesByIP: [String: String], interactive: Bool = true,
              allowedLogins: @escaping (Device) -> [String]?) async {
        guard !isScanning else { return }
        isScanning = true
        lastRunAt = .now
        interactiveRun = interactive
        defer { isScanning = false }
        for s in servers { states[s.id] = .idle }
        approvalOpened = false
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for server in servers {
                if running >= 4 { await group.next(); running -= 1 }
                running += 1
                let logins = logins(for: server, allowed: allowedLogins(server))
                group.addTask { [weak self] in
                    await self?.scanOne(server, logins: logins)
                }
            }
        }
        ServiceScanStore.save(scans)
    }

    /// Opens the first approval page of a run; later ones get a button.
    private var approvalOpened = false
    private var interactiveRun = true

    /// True when the last scan is older than `interval` (a run that failed
    /// still counts, so an unreachable server can't cause a scan every minute).
    func isDue(every interval: TimeInterval) -> Bool {
        let last = lastRunAt ?? scans.values.map(\.scannedAt).max() ?? .distantPast
        return Date().timeIntervalSince(last) > interval
    }

    func openApproval(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func needsApproval(_ url: URL, for deviceID: String) {
        states[deviceID] = .waitingForApproval(url)
        if interactiveRun, !approvalOpened {
            approvalOpened = true
            openApproval(url)
        }
    }

    private func scanOne(_ server: Device, logins: [String]) async {
        guard let address = server.addresses?.first(where: { !$0.contains(":") }) ?? server.primaryAddress else {
            states[server.id] = .failed("This machine has no Tailscale address.")
            return
        }
        guard !logins.isEmpty else {
            states[server.id] = .failed("No sign-in names to try. Add one under Sign-in names.")
            return
        }
        var refused: [String] = []
        for login in logins {
            states[server.id] = .scanning(login: login)
            let deviceID = server.id
            let result = await SSHRunner.run(login: login, host: address,
                                             command: ServiceScanScript.remoteCommand) { [weak self] url in
                Task { @MainActor in self?.needsApproval(url, for: deviceID) }
            }
            if result.output.contains("@@END") {
                do {
                    let scan = try ServiceScanParser.parse(result.output, deviceID: server.id,
                                                           serverName: server.shortName, login: login)
                    scans[server.id] = scan
                    rememberedLogins[server.id] = login
                    states[server.id] = .done
                    ServiceScanStore.save(scans)
                } catch {
                    states[server.id] = .failed(error.localizedDescription)
                }
                return
            }
            if result.loginRefused {
                refused.append(login)
                continue
            }
            states[server.id] = .failed(result.plainError)
            return
        }
        states[server.id] = .failed("Your access rules don't allow signing in as \(refused.joined(separator: " or ")). Add the right name under Sign-in names.")
    }
    #endif
}

// MARK: - SSH

#if os(macOS)
struct SSHResult {
    static let identityChanged = "The server's identity changed since the last scan, so the app stopped."

    let status: Int32
    let output: String
    let errorText: String
    let timedOut: Bool

    /// Tailscale refused this login name (or the server wanted a key).
    var loginRefused: Bool {
        errorText.contains("does not permit you to SSH as user")
            || errorText.contains("unknown user")
            || errorText.contains("Permission denied")
    }

    var plainError: String {
        if timedOut { return "The scan took too long and was stopped. Try Scan this server again." }
        let e = errorText
        if e.contains("Connection refused") { return "Nothing answers on the SSH port. Tailscale SSH may be off on this server." }
        if e.contains("timed out") || e.contains("No route to host") {
            return "No answer over Tailscale (timed out). The server may be down or unreachable right now."
        }
        if e.contains("Host key verification failed") || e.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return Self.identityChanged
        }
        let last = e.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return last ?? "SSH stopped with code \(status)."
    }
}

/// Runs one command on a server with the system ssh. The tailnet does the
/// sign-in (Tailscale SSH), so no keys are involved; the app's own
/// known-hosts file pins each server's identity after the first scan.
enum SSHRunner {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var reported = false
        private(set) var deadline: Date
        private var didTimeOut = false
        func markTimedOut() { lock.lock(); didTimeOut = true; lock.unlock() }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }

        init(timeout: TimeInterval) { deadline = Date().addingTimeInterval(timeout) }

        func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }

        /// Returns the approval URL the first time Tailscale prints one.
        func appendErr(_ d: Data) -> URL? {
            lock.lock(); defer { lock.unlock() }
            err.append(d)
            guard !reported else { return nil }
            let text = String(decoding: err, as: UTF8.self)
            guard let range = text.range(of: #"https://login\.tailscale\.com/\S+"#, options: .regularExpression),
                  let url = URL(string: String(text[range])) else { return nil }
            reported = true
            // Give the admin time to approve in the browser.
            deadline = Date().addingTimeInterval(300)
            return url
        }

        private var didExit = false
        func markExited() { lock.lock(); didExit = true; lock.unlock() }
        var exited: Bool { lock.lock(); defer { lock.unlock() }; return didExit }

        var pastDeadline: Bool { lock.lock(); defer { lock.unlock() }; return Date() > deadline }
        var outText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
        var errText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    }

    static var knownHostsPath: String? {
        ServiceScanStore.folder?.appendingPathComponent("known_hosts").path
    }

    static func run(login: String, host: String, command: String, timeout: TimeInterval = 120,
                    onApproval: @escaping @Sendable (URL) -> Void) async -> SSHResult {
        if let folder = ServiceScanStore.folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var args = ["-F", "/dev/null", "-T",
                        "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=15",
                        "-o", "ServerAliveInterval=15",
                        "-o", "StrictHostKeyChecking=accept-new"]
            // Quoted: the path has a space ("Application Support") and ssh
            // reads an unquoted value as a list of files.
            if let path = knownHostsPath { args += ["-o", "UserKnownHostsFile=\"\(path)\""] }
            // -l and "--": neither the name nor the address can be read as an option.
            args += ["-l", login, "--", host, command]
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let box = Collector(timeout: timeout)
            // Done = both pipes drained AND the exit reported. The exit comes
            // through terminationHandler: waitUntilExit() on a worker thread
            // can miss it and hang forever.
            let finished = DispatchGroup()
            finished.enter()
            process.terminationHandler = { _ in
                box.markExited()
                finished.leave()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: SSHResult(status: -1, output: "",
                                                         errorText: "Couldn't start ssh: \(error.localizedDescription)",
                                                         timedOut: false))
                return
            }

            finished.enter()
            DispatchQueue.global().async {
                box.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                finished.leave()
            }
            finished.enter()
            DispatchQueue.global().async {
                while true {
                    let chunk = err.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if let url = box.appendErr(chunk) { onApproval(url) }
                }
                finished.leave()
            }
            DispatchQueue.global().async {
                while !box.exited {
                    if box.pastDeadline {
                        box.markTimedOut()
                        process.terminate()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            finished.notify(queue: .global()) {
                continuation.resume(returning: SSHResult(status: process.terminationStatus,
                                                         output: box.outText, errorText: box.errText,
                                                         timedOut: box.timedOut))
            }
        }
    }
}
#endif
