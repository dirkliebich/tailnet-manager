import Foundation

/// One thing someone did: a login to a server (from tailscaled's log, read
/// by the server scan) or an entry of Tailscale's configuration audit log.
struct ActivityEvent: Identifiable, Hashable {
    enum Source: String, CaseIterable {
        case serverLogin = "Server logins"
        case tailscale = "Sign-ins & changes"
    }

    let id: String
    let date: Date?
    let source: Source
    /// Person (display name), or the machine that acted.
    let who: String
    let action: String
    /// Server logged in to, or what was changed.
    let target: String
    /// Machine or origin it came from.
    let from: String
    let detail: String
    /// The app's own read-only scans.
    let isAppScan: Bool
    /// An interactive shell on a server.
    let isShell: Bool
    /// Sessions merged into this row (a burst of short logins).
    var count = 1

    var day: String { date.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "Unknown day" }
    var daySort: Double { date.map { $0.timeIntervalSince1970 } ?? 0 }
}

extension AppState {

    /// Newest first: server logins from the last scans plus the loaded audit log.
    var activityEvents: [ActivityEvent] {
        cached("activity") { buildActivity() }
    }

    private func buildActivity() -> [ActivityEvent] {
        var out: [ActivityEvent] = []
        let byIP = machinesByIP
        func person(_ login: String) -> String {
            if login == "tagged-devices" { return "A tagged machine" }
            return users.first { $0.loginName.caseInsensitiveCompare(login) == .orderedSame }?.title ?? login
        }

        // Tools (editors, deploy scripts) open many short sessions: sessions
        // by the same person, on the same server, as the same account and of
        // the same kind with gaps under 15 minutes read as one visit.
        for scan in services.scans.values {
            let sorted = scan.sshSessions.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
            var bursts: [[SSHSession]] = []
            for s in sorted {
                if var last = bursts.last, let prev = last.last,
                   prev.user == s.user, prev.localUser == s.localUser, prev.kind == s.kind, prev.fromIP == s.fromIP,
                   let a = prev.end ?? prev.start, let b = s.start, b.timeIntervalSince(a) < 15 * 60 {
                    last.append(s)
                    bursts[bursts.count - 1] = last
                } else {
                    bursts.append([s])
                }
            }
            for burst in bursts {
                guard let first = burst.first else { continue }
                let n = burst.count
                let action: String
                switch first.kind {
                case .shell: action = "Opened a shell"
                case .command: action = "Ran commands"
                case .app: action = "Tailnet Manager scan"
                case .unknown: action = "Signed in"
                }
                let begin = first.start
                let finish = burst.compactMap { $0.end ?? $0.start }.max()
                var detail = "as \(first.localUser)"
                if n > 1 { detail += " · \(n) sessions" }
                if let begin, let finish {
                    detail += n > 1
                        ? " · \(begin.formatted(date: .omitted, time: .shortened)) – \(finish.formatted(date: .omitted, time: .shortened))"
                        : " · " + Self.duration(finish.timeIntervalSince(begin))
                }
                if burst.contains(where: { !$0.granted }) { detail += " · some not granted" }
                let fromName = byIP[first.fromIP].map { "\($0) (\(first.fromIP))" } ?? first.fromIP
                out.append(ActivityEvent(
                    id: "ssh:\(scan.deviceID):\(first.id)", date: begin, source: .serverLogin,
                    who: person(first.user), action: action, target: scan.serverName, from: fromName,
                    detail: detail, isAppScan: first.kind == .app, isShell: first.kind == .shell,
                    count: n))
            }
        }

        for e in auditLog {
            let action = e.action == "LOGIN" ? "Signed in" : e.actionLabel.prefix(1).uppercased() + e.actionLabel.dropFirst()
            let origin = (e.origin ?? "").replacingOccurrences(of: "_", with: " ").lowercased()
            out.append(ActivityEvent(
                id: "audit:\(e.id)", date: e.date, source: .tailscale,
                who: e.actor?.label ?? "Unknown", action: action, target: e.target?.label ?? "—",
                from: origin.isEmpty ? "—" : origin.prefix(1).uppercased() + origin.dropFirst(),
                detail: e.target?.type.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() } ?? "",
                isAppScan: false, isShell: false))
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "under a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
