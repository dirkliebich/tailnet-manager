import Foundation

// MARK: - HuJSON

/// Converts Tailscale's HuJSON (JSON with comments and trailing commas)
/// into something JSONSerialization accepts. Edits go through
/// `HuJSONDocument` (PolicyEditor.swift), which preserves comments.
enum HuJSON {
    static func toJSONObject(_ text: String) -> Any? {
        let stripped = stripCommentsAndTrailingCommas(text)
        guard let data = stripped.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func stripCommentsAndTrailingCommas(_ text: String) -> String {
        var out: [Character] = []
        // "\r\n" is a single Character, so it would never match "\n" below.
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var i = 0
        var inString = false

        // Pass 1: remove // and /* */ comments (string-aware).
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count {
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }

        // Pass 2: drop trailing commas before ] or } (string-aware).
        chars = out
        out = []
        inString = false
        i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count {
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "]" || chars[j] == "}" {
                    i += 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}

// MARK: - Policy model

struct PolicyRule: Identifiable, Hashable {
    enum Kind: String { case acl = "ACL", grant = "Grant", ssh = "SSH" }

    let id: Int
    let kind: Kind
    let srcs: [String]
    let dsts: [String]
    /// Human-readable port list: ["22", "80-443"], ["tcp/443"], or ["*"].
    let ports: [String]
    let sshUsers: [String]

    var summary: String {
        let portText = ports.isEmpty ? "" : " : \(ports.joined(separator: ", "))"
        return "\(kind.rawValue)  \(srcs.joined(separator: ", "))  →  \(dsts.joined(separator: ", "))\(portText)"
    }

    /// True when the port list covers TCP 22.
    var coversSSH: Bool {
        if kind == .ssh { return true }
        return ports.contains { portEntry in
            let p = portEntry.split(separator: "/").last.map(String.init) ?? portEntry
            if p == "*" { return true }
            if p == "22" { return true }
            if p.contains("-"),
               let lo = Int(p.split(separator: "-")[0]),
               let hi = Int(p.split(separator: "-").last ?? "") {
                return lo <= 22 && 22 <= hi
            }
            return false
        }
    }

    var coversAllPorts: Bool {
        kind != .ssh && ports.contains("*")
    }
}

struct PolicyModel {
    var groups: [String: [String]] = [:]
    var hosts: [String: String] = [:]
    var tagOwners: [String: [String]] = [:]
    var rules: [PolicyRule] = []
    /// Selectors (tags/users) granted the "funnel" node attribute —
    /// their devices can be exposed to the public internet.
    var funnelTargets: [String] = []
    var declaredTags: [String] { Array(tagOwners.keys).sorted() }
}

// MARK: - Access graph

enum AccessNodeKind: String {
    case user, everyone, allMembers, device, allDevices, internet, outside
}

struct AccessNode: Identifiable, Hashable {
    let id: String
    let kind: AccessNodeKind
    let label: String
    var deviceID: String? = nil
    var online: Bool = false
    var risky: Bool = false
    /// For a person node: how many machines they can actually reach (the
    /// true count, wildcards/autogroups expanded). nil for non-person nodes.
    var reachCount: Int? = nil
}

struct AccessEdge: Identifiable, Hashable {
    let id: String
    let from: String
    let to: String
    let ports: [String]
    let ruleID: Int
    let openToEveryone: Bool
    let includesSSH: Bool
    let touchesOutside: Bool
    /// True when this edge is device OWNERSHIP (a person owns the machine),
    /// NOT an access grant. Access views must not conflate the two. This is
    /// authoritative — never infer ownership from `ruleID == -1`, which also
    /// marks a merged multi-rule access edge.
    var isOwnership: Bool = false
}

/// The one true reachability relation: who can reach which machine, with
/// wildcards (`*`), `autogroup:*`, groups, tags, hosts and IPs all fully
/// expanded and untagged machines included. Every access view derives from
/// this so they can never disagree.
struct AccessReachability {
    /// person login → the set of device IDs they can reach.
    var reachableByPerson: [String: Set<String>] = [:]
    /// device ID → the set of person logins that can reach it.
    var peopleByDevice: [String: Set<String>] = [:]
    /// device IDs reachable by *everyone* (granted via a `*`/member-wide src).
    var everyoneDevices: Set<String> = []
    /// "login|deviceID" pairs whose grant came (also) from a `*` source.
    var pairOpenToEveryone: Set<String> = []
    /// "login|deviceID" pairs whose grant covers SSH / port 22.
    var pairSSH: Set<String> = []
    /// source device ID → destination device IDs (machine-to-machine).
    var machineReach: [String: Set<String>] = [:]
    var pairMachineSSH: Set<String> = []

    /// "login|deviceID" → the policy rule IDs that grant that access. This is
    /// the audit trail: every connection can be traced back to the exact
    /// rule(s) responsible, so the map can show its work.
    var grantingRules: [String: Set<Int>] = [:]
    /// rule ID → its human-readable summary ("ACL  * → tag:prod : 22").
    var ruleSummaries: [Int: String] = [:]

    func reaches(_ login: String, _ deviceID: String) -> Bool {
        reachableByPerson[login]?.contains(deviceID) ?? false
    }

    /// The rule summaries that explain why `login` can reach `deviceID`.
    func why(_ login: String, _ deviceID: String) -> [String] {
        (grantingRules["\(login)|\(deviceID)"] ?? [])
            .sorted()
            .compactMap { ruleSummaries[$0] }
    }
}

// MARK: - Table rows

struct AccessDestination: Identifiable, Hashable {
    let id: String
    let label: String
    let deviceIDs: [String]
    let ports: [String]
    /// Rule provenance, e.g. "ACL  * → tag:prod : 22".
    let via: String
    let risky: Bool
}

struct PrincipalAccess: Identifiable, Hashable {
    let id: String
    let label: String
    /// "User", "Group", "Everyone", "Tag", "Server", …
    let kindLabel: String
    let destinations: [AccessDestination]
}

// MARK: - Findings

enum FindingSeverity: Int, Comparable, CaseIterable {
    case info = 0, low = 1, medium = 2, high = 3, critical = 4

    static func < (a: FindingSeverity, b: FindingSeverity) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .info: return "Info"
        }
    }
}

struct SecurityFinding: Identifiable, Hashable {
    let id: String
    let severity: FindingSeverity
    let title: String
    let detail: String
    let deviceIDs: [String]
    /// The policy rule that causes this, when applicable.
    let ruleSummary: String?
    /// True when fixing this needs a policy edit (console) rather than an API action.
    let requiresPolicyEdit: Bool
}

/// A person or team the policy grants access to some access group (tag),
/// surfaced on the Access Board so the admin sees who a group hands a
/// machine to.
struct GrantedPrincipal: Identifiable, Hashable {
    enum Kind: String { case person, team, everyone, tagged, other }
    let kind: Kind
    let label: String
    /// Login name when this is a concrete person (for avatar resolution).
    let loginName: String?
    var id: String { "\(kind.rawValue):\(label)" }
}

struct AccessAnalysis {
    var nodes: [AccessNode] = []
    var edges: [AccessEdge] = []
    var userAccess: [PrincipalAccess] = []
    var machineAccess: [PrincipalAccess] = []
    var findings: [SecurityFinding] = []
    /// tag → the people/teams the policy grants to reach it.
    var grantsByTag: [String: [GrantedPrincipal]] = [:]
    /// The canonical who-reaches-what relation that drives every view.
    var reachability = AccessReachability()
    var parsedPolicy: Bool = false
}

// MARK: - Analyzer

enum PolicyAnalyzer {

    // MARK: Parse

    static func parse(policyText: String) -> PolicyModel? {
        guard let obj = HuJSON.toJSONObject(policyText) as? [String: Any] else { return nil }
        var model = PolicyModel()

        if let groups = obj["groups"] as? [String: [String]] { model.groups = groups }
        if let hosts = obj["hosts"] as? [String: String] { model.hosts = hosts }
        if let tagOwners = obj["tagOwners"] as? [String: [String]] { model.tagOwners = tagOwners }

        var ruleID = 0
        if let acls = obj["acls"] as? [[String: Any]] {
            for acl in acls where (acl["action"] as? String ?? "accept") == "accept" {
                let srcs = acl["src"] as? [String] ?? []
                var dsts: [String] = []
                var ports = Set<String>()
                for raw in acl["dst"] as? [String] ?? [] {
                    let (selector, portList) = splitDst(raw)
                    dsts.append(selector)
                    portList.forEach { ports.insert($0) }
                }
                model.rules.append(PolicyRule(id: ruleID, kind: .acl, srcs: srcs, dsts: dsts,
                                              ports: ports.sorted(), sshUsers: []))
                ruleID += 1
            }
        }
        if let grants = obj["grants"] as? [[String: Any]] {
            for grant in grants {
                let srcs = grant["src"] as? [String] ?? []
                let dsts = grant["dst"] as? [String] ?? []
                let ip = grant["ip"] as? [String] ?? ["*"]
                let ports = ip.map { $0.replacingOccurrences(of: ":", with: "/") }
                model.rules.append(PolicyRule(id: ruleID, kind: .grant, srcs: srcs, dsts: dsts,
                                              ports: ports, sshUsers: []))
                ruleID += 1
            }
        }
        if let ssh = obj["ssh"] as? [[String: Any]] {
            for rule in ssh {
                let action = rule["action"] as? String ?? "accept"
                guard action == "accept" || action == "check" else { continue }
                model.rules.append(PolicyRule(id: ruleID, kind: .ssh,
                                              srcs: rule["src"] as? [String] ?? [],
                                              dsts: rule["dst"] as? [String] ?? [],
                                              ports: ["ssh"],
                                              sshUsers: rule["users"] as? [String] ?? []))
                ruleID += 1
            }
        }
        if let nodeAttrs = obj["nodeAttrs"] as? [[String: Any]] {
            for entry in nodeAttrs {
                let attrs = entry["attr"] as? [String] ?? []
                guard attrs.contains("funnel") else { continue }
                model.funnelTargets.append(contentsOf: entry["target"] as? [String] ?? [])
            }
        }
        return model
    }

    /// "tag:prod:22,80" → ("tag:prod", ["22","80"]); "*:*" → ("*", ["*"]).
    static func splitDst(_ raw: String) -> (String, [String]) {
        guard let lastColon = raw.lastIndex(of: ":") else { return (raw, ["*"]) }
        let selector = String(raw[..<lastColon])
        let portPart = String(raw[raw.index(after: lastColon)...])
        let valid = portPart == "*" || portPart.allSatisfy { $0.isNumber || $0 == "," || $0 == "-" }
        guard valid, !portPart.isEmpty else { return (raw, ["*"]) }
        return (selector, portPart.split(separator: ",").map(String.init))
    }

    // MARK: Analyze

    static func analyze(model: PolicyModel?,
                        devices: [Device],
                        users: [TSUser],
                        settings: TailnetSettings?) -> AccessAnalysis {
        var analysis = AccessAnalysis()
        analysis.parsedPolicy = model != nil

        let members = users.filter { $0.type != "shared" }
        let ctx = Context(model: model ?? PolicyModel(), devices: devices, members: members)

        analysis.reachability = computeReachability(ctx: ctx)
        buildGraph(&analysis, ctx: ctx)
        buildTables(&analysis, ctx: ctx)
        buildGrantsByTag(&analysis, ctx: ctx)
        buildFindings(&analysis, ctx: ctx, devices: devices, users: users, settings: settings)
        return analysis
    }

    // MARK: - Canonical reachability (the single source of truth)

    /// Does this policy source match this person? Same semantics the
    /// reachability relation uses, exposed for the access editor.
    static func source(_ src: String, matches person: TSUser, model: PolicyModel) -> Bool {
        srcMatchesPerson(src, person, ctx: Context(model: model, devices: [], members: [person]))
    }

    /// The sign-in names the policy's SSH rules let this person use on this
    /// machine (e.g. ["autogroup:nonroot", "root"]); nil when no SSH rule
    /// covers the pair.
    static func sshLogins(for person: TSUser, on device: Device, model: PolicyModel,
                          members: [TSUser]) -> [String]? {
        let ctx = Context(model: model, devices: [device], members: members)
        var logins: [String] = []
        var matched = false
        for rule in model.rules where rule.kind == .ssh {
            guard rule.srcs.contains(where: { srcMatchesPerson($0, person, ctx: ctx) }),
                  rule.dsts.contains(where: { dstMatchesDevice($0, device, forPerson: person, ctx: ctx) })
            else { continue }
            matched = true
            for user in rule.sshUsers where !logins.contains(user) { logins.append(user) }
        }
        return matched ? logins : nil
    }

    /// Selector without its trailing port (":22", ":*", ":80,443").
    private static func selector(of raw: String) -> String {
        splitDst(raw).0
    }

    /// Does this policy source match this PERSON? Fully expands `*`,
    /// `autogroup:member/admin/owner`, and `group:`. Machine sources
    /// (tags/hosts/IPs) never match a person.
    private static func srcMatchesPerson(_ src: String, _ person: TSUser, ctx: Context) -> Bool {
        switch src {
        case "*": return true
        case person.loginName: return true
        case "autogroup:member", "autogroup:members": return true
        case "autogroup:admin":
            return ["owner", "admin", "it-admin", "network-admin"].contains(person.role ?? "member")
        case "autogroup:owner":
            return person.role == "owner"
        default:
            if src.hasPrefix("group:") { return ctx.expandGroup(src).contains(person.loginName) }
            return false
        }
    }

    /// Does this policy source match this DEVICE acting as a source
    /// (machine-to-machine)? Only tag / autogroup:tagged / host / IP sources.
    private static func srcMatchesDevice(_ src: String, _ device: Device, ctx: Context) -> Bool {
        if src.hasPrefix("tag:") { return (device.tags ?? []).contains(src) }
        if src == "autogroup:tagged" { return device.isTagged }
        if let ip = ctx.model.hosts[src] { return (device.addresses ?? []).contains(ip) }
        if src.contains("/") || (src.contains(".") && !src.contains("@")) || src.contains("::") {
            let ip = src.split(separator: "/").first.map(String.init) ?? src
            return (device.addresses ?? []).contains(ip)
        }
        return false
    }

    /// Does this destination selector match this device? `forPerson` is used
    /// only to resolve the relational `autogroup:self`.
    private static func dstMatchesDevice(_ rawDst: String, _ device: Device,
                                         forPerson person: TSUser?, ctx: Context) -> Bool {
        let sel = selector(of: rawDst)
        switch sel {
        case "*": return true
        case "autogroup:member", "autogroup:members":
            return !device.isTagged && ctx.members.contains { $0.loginName == device.user }
        case "autogroup:tagged":
            return device.isTagged
        case "autogroup:self":
            guard let person else { return false }
            return !device.isTagged && device.user == person.loginName
        case "autogroup:internet":
            return false
        default:
            if sel.hasPrefix("tag:") { return (device.tags ?? []).contains(sel) }
            if sel.hasPrefix("group:") {
                return !device.isTagged && ctx.expandGroup(sel).contains(device.user ?? "")
            }
            if let ip = ctx.model.hosts[sel] { return (device.addresses ?? []).contains(ip) }
            if sel.contains("@") { return !device.isTagged && device.user == sel }
            if sel.contains("/") || sel.contains(".") || sel.contains("::") {
                let ip = sel.split(separator: "/").first.map(String.init) ?? sel
                return (device.addresses ?? []).contains(ip)
            }
            return false
        }
    }

    private static func computeReachability(ctx: Context) -> AccessReachability {
        var r = AccessReachability()
        let devices = ctx.devices.filter { $0.isExternal != true }
        for rule in ctx.model.rules { r.ruleSummaries[rule.id] = rule.summary }
        // Only network rules (ACLs/grants) open a connection. An SSH rule on
        // its own is not reach: Tailscale drops tcp/22 unless a network rule
        // also allows it (verified against /acl/validate).
        let rules = ctx.model.rules.filter { $0.kind != .ssh }

        // People → machines.
        for person in ctx.members {
            for device in devices {
                var reached = false, viaEveryone = false, viaSSH = false
                var granting: Set<Int> = []
                for rule in rules {
                    guard rule.srcs.contains(where: { srcMatchesPerson($0, person, ctx: ctx) }),
                          rule.dsts.contains(where: { dstMatchesDevice($0, device, forPerson: person, ctx: ctx) })
                    else { continue }
                    reached = true
                    granting.insert(rule.id)
                    if rule.srcs.contains("*") { viaEveryone = true }
                    if rule.coversSSH { viaSSH = true }
                }
                guard reached else { continue }
                r.reachableByPerson[person.loginName, default: []].insert(device.id)
                r.peopleByDevice[device.id, default: []].insert(person.loginName)
                let key = "\(person.loginName)|\(device.id)"
                r.grantingRules[key] = granting
                if viaEveryone { r.pairOpenToEveryone.insert(key); r.everyoneDevices.insert(device.id) }
                if viaSSH { r.pairSSH.insert(key) }
            }
        }

        // Machines → machines (tag/host/IP sources).
        for src in devices {
            for dst in devices where dst.id != src.id {
                var reached = false, viaSSH = false
                for rule in rules {
                    guard rule.srcs.contains(where: { srcMatchesDevice($0, src, ctx: ctx) }),
                          rule.dsts.contains(where: { dstMatchesDevice($0, dst, forPerson: nil, ctx: ctx) })
                    else { continue }
                    reached = true
                    if rule.coversSSH { viaSSH = true }
                }
                guard reached else { continue }
                r.machineReach[src.id, default: []].insert(dst.id)
                if viaSSH { r.pairMachineSSH.insert("\(src.id)|\(dst.id)") }
            }
        }
        return r
    }

    // MARK: Grants by tag (who can reach each access group)

    private static func buildGrantsByTag(_ analysis: inout AccessAnalysis, ctx: Context) {
        var result: [String: [GrantedPrincipal]] = [:]
        let allTags = Set(ctx.model.tagOwners.keys)
            .union(ctx.devices.flatMap { $0.tags ?? [] })
        guard !allTags.isEmpty else { return }

        func principals(from srcs: [String]) -> [GrantedPrincipal] {
            var out: [GrantedPrincipal] = []
            for src in srcs {
                if src == "*" {
                    out.append(GrantedPrincipal(kind: .everyone, label: "Everyone", loginName: nil))
                } else if src == "autogroup:member" || src == "autogroup:members" {
                    out.append(GrantedPrincipal(kind: .everyone, label: "Everyone in your org", loginName: nil))
                } else if src == "autogroup:tagged" {
                    out.append(GrantedPrincipal(kind: .tagged, label: "Tagged machines", loginName: nil))
                } else if src.hasPrefix("autogroup:") {
                    out.append(GrantedPrincipal(kind: .other, label: src.replacingOccurrences(of: "autogroup:", with: "").capitalized, loginName: nil))
                } else if src.hasPrefix("group:") {
                    let name = String(src.dropFirst("group:".count))
                    out.append(GrantedPrincipal(kind: .team, label: "Team \(name)", loginName: nil))
                    // Also expand the team's members so avatars can render.
                    for login in ctx.expandGroup(src) {
                        let member = ctx.members.first { $0.loginName == login }
                        out.append(GrantedPrincipal(kind: .person, label: member?.title ?? login, loginName: login))
                    }
                } else if src.contains("@") {
                    let member = ctx.members.first { $0.loginName == src }
                    out.append(GrantedPrincipal(kind: .person, label: member?.title ?? src, loginName: src))
                }
            }
            return out
        }

        for rule in ctx.model.rules {
            let grantsAllDevices = rule.dsts.contains("*")
            let dstTags = rule.dsts.filter { $0.hasPrefix("tag:") }
            let targetTags = grantsAllDevices ? Array(allTags) : dstTags
            guard !targetTags.isEmpty else { continue }
            let people = principals(from: rule.srcs)
            guard !people.isEmpty else { continue }
            for tag in targetTags {
                result[tag, default: []].append(contentsOf: people)
            }
        }

        // De-duplicate per tag, keep a stable order (people, then teams/other).
        for (tag, list) in result {
            var seen = Set<String>()
            let deduped = list.filter { seen.insert($0.id).inserted }
                .sorted { a, b in
                    if a.kind == b.kind { return a.label < b.label }
                    return a.kind == .person && b.kind != .person
                }
            result[tag] = deduped
        }
        analysis.grantsByTag = result
    }

    // MARK: Selector resolution

    private struct Context {
        let model: PolicyModel
        let devices: [Device]
        let members: [TSUser]

        func devicesOwned(by login: String) -> [Device] {
            devices.filter { $0.user == login && !$0.isTagged }
        }
        func devicesTagged(_ tag: String) -> [Device] {
            devices.filter { ($0.tags ?? []).contains(tag) }
        }
        func device(forHostIP ip: String) -> Device? {
            devices.first { ($0.addresses ?? []).contains(ip) }
        }
        func expandGroup(_ group: String) -> [String] {
            model.groups[group] ?? []
        }
    }

    /// What a src/dst selector resolves to for graph purposes.
    private enum Resolved {
        case everyone
        case allMembers
        case users([String])
        case devices([Device])
        case allDevices
        case internet
        case outside(String)
        case none
    }

    private static func resolve(_ selector: String, ctx: Context, asSource: Bool) -> Resolved {
        if selector == "*" { return asSource ? .everyone : .allDevices }
        if selector.hasPrefix("autogroup:") {
            switch selector {
            case "autogroup:member", "autogroup:members":
                return asSource ? .allMembers : .allDevices
            case "autogroup:tagged":
                let tagged = ctx.devices.filter(\.isTagged)
                return tagged.isEmpty ? .none : .devices(tagged)
            case "autogroup:internet":
                return .internet
            case "autogroup:self", "autogroup:admin", "autogroup:owner":
                return asSource ? .allMembers : .allDevices
            case "autogroup:shared", "autogroup:danger-all":
                return .outside(selector)
            default:
                return .outside(selector)
            }
        }
        if selector.hasPrefix("group:") {
            let logins = ctx.expandGroup(selector)
            if asSource { return .users(logins) }
            let devs = logins.flatMap { ctx.devicesOwned(by: $0) }
            return devs.isEmpty ? .none : .devices(devs)
        }
        if selector.hasPrefix("tag:") {
            let devs = ctx.devicesTagged(selector)
            return devs.isEmpty ? .outside(selector) : .devices(devs)
        }
        if selector.contains("@") {
            if asSource { return .users([selector]) }
            let devs = ctx.devicesOwned(by: selector)
            return devs.isEmpty ? .none : .devices(devs)
        }
        // Host alias from the hosts section.
        if let ip = ctx.model.hosts[selector] {
            if let dev = ctx.device(forHostIP: ip) { return .devices([dev]) }
            return .outside("\(selector) (\(ip))")
        }
        // Raw IP or CIDR.
        if selector == "0.0.0.0/0" || selector == "::/0" { return .internet }
        if selector.contains("/") || selector.contains(".") || selector.contains("::") {
            let ip = selector.split(separator: "/").first.map(String.init) ?? selector
            if let dev = ctx.device(forHostIP: ip) { return .devices([dev]) }
            return .outside(selector)
        }
        return .outside(selector)
    }

    // MARK: Graph

    private static func buildGraph(_ analysis: inout AccessAnalysis, ctx: Context) {
        var nodes: [String: AccessNode] = [:]
        var edges: [AccessEdge] = []

        func node(_ n: AccessNode) -> String {
            if nodes[n.id] == nil { nodes[n.id] = n }
            return n.id
        }
        func userNode(_ login: String) -> String {
            let member = ctx.members.first { $0.loginName == login }
            return node(AccessNode(id: "user:\(login)", kind: .user,
                                   label: member?.title ?? login,
                                   online: member?.currentlyConnected == true,
                                   reachCount: analysis.reachability.reachableByPerson[login]?.count ?? 0))
        }
        func deviceNode(_ d: Device) -> String {
            node(AccessNode(id: "device:\(d.id)", kind: .device, label: d.shortName,
                            deviceID: d.id, online: d.isOnline,
                            risky: d.isExternal == true || (d.enabledRoutes?.isEmpty == false)))
        }
        func specialNode(_ kind: AccessNodeKind, _ label: String) -> String {
            node(AccessNode(id: kind.rawValue, kind: kind, label: label,
                            risky: kind == .internet || kind == .outside))
        }
        let reach = analysis.reachability

        // REAL person → machine access edges, straight from the canonical
        // relation (wildcards and autogroups already expanded, untagged
        // machines included). One edge per reachable pair — exactly what the
        // person can reach, no aggregate stand-ins.
        for person in ctx.members {
            let login = person.loginName
            guard let reachedIDs = reach.reachableByPerson[login], !reachedIDs.isEmpty else { continue }
            let from = userNode(login)
            for devID in reachedIDs {
                guard let dev = ctx.devices.first(where: { $0.id == devID }) else { continue }
                let key = "\(login)|\(devID)"
                edges.append(AccessEdge(
                    id: "acc:\(login)>\(devID)",
                    from: from, to: deviceNode(dev),
                    ports: [], ruleID: 0,
                    openToEveryone: reach.pairOpenToEveryone.contains(key),
                    includesSSH: reach.pairSSH.contains(key),
                    touchesOutside: false,
                    isOwnership: false))
            }
        }

        // REAL machine → machine access edges (tag/host-sourced rules).
        for (srcID, dstIDs) in reach.machineReach {
            guard let srcDev = ctx.devices.first(where: { $0.id == srcID }) else { continue }
            let from = deviceNode(srcDev)
            for dstID in dstIDs {
                guard let dstDev = ctx.devices.first(where: { $0.id == dstID }) else { continue }
                edges.append(AccessEdge(
                    id: "m:\(srcID)>\(dstID)",
                    from: from, to: deviceNode(dstDev),
                    ports: [], ruleID: 0,
                    openToEveryone: false,
                    includesSSH: reach.pairMachineSSH.contains("\(srcID)|\(dstID)"),
                    touchesOutside: false,
                    isOwnership: false))
            }
        }

        // Ownership: a person OWNS an untagged machine (identity, not an ACL
        // grant). Flagged isOwnership so the view never draws it as access.
        for member in ctx.members {
            let owned = ctx.devicesOwned(by: member.loginName)
            guard !owned.isEmpty else { continue }
            let from = userNode(member.loginName)
            for dev in owned {
                edges.append(AccessEdge(id: "own:\(member.loginName):\(dev.id)",
                                        from: from, to: deviceNode(dev),
                                        ports: [], ruleID: -1,
                                        openToEveryone: false, includesSSH: false,
                                        touchesOutside: false, isOwnership: true))
            }
        }

        // Shared-in devices come from outside tailnets.
        let externals = ctx.devices.filter { $0.isExternal == true }
        if !externals.isEmpty {
            let from = node(AccessNode(id: "outside:shared", kind: .outside,
                                       label: "Other tailnets", risky: true))
            for dev in externals {
                edges.append(AccessEdge(id: "ext:\(dev.id)", from: from, to: deviceNode(dev),
                                        ports: [], ruleID: -1, openToEveryone: false,
                                        includesSSH: false, touchesOutside: true))
            }
        }

        // Funnel-capable devices touch the public internet.
        for target in ctx.model.funnelTargets {
            if case .devices(let devs) = resolve(target, ctx: ctx, asSource: false) {
                let internet = specialNode(.internet, "Internet")
                for dev in devs {
                    edges.append(AccessEdge(id: "funnel:\(dev.id)", from: internet,
                                            to: deviceNode(dev), ports: ["funnel"],
                                            ruleID: -1, openToEveryone: true,
                                            includesSSH: false, touchesOutside: true))
                }
            }
        }

        // Devices that appear in no edge still belong on the map.
        for dev in ctx.devices where nodes["device:\(dev.id)"] == nil {
            _ = deviceNode(dev)
        }

        analysis.nodes = nodes.values.sorted { $0.label < $1.label }
        analysis.edges = Self.mergeEdges(edges)
    }

    /// Collapses every edge between the same two endpoints into ONE
    /// connection, so the map shows exactly one line per real reachability
    /// relationship. Without this a server carrying two tags the person is
    /// granted (or access granted by both an ACL and an SSH rule) would be
    /// drawn as several parallel lines, hugely overstating how many
    /// connections a person has. Flags are OR-ed and ports unioned so the
    /// single line still reflects the strongest access (SSH, open-to-all,
    /// outside).
    private static func mergeEdges(_ edges: [AccessEdge]) -> [AccessEdge] {
        var merged: [String: AccessEdge] = [:]
        var order: [String] = []
        for edge in edges {
            let key = "\(edge.from)\u{1}\(edge.to)"
            if let existing = merged[key] {
                merged[key] = AccessEdge(
                    id: existing.id,
                    from: existing.from,
                    to: existing.to,
                    ports: Array(Set(existing.ports).union(edge.ports)).sorted(),
                    // A merged pair loses a single authoritative rule id.
                    // -1 no longer implies ownership (that's isOwnership now).
                    ruleID: existing.ruleID == edge.ruleID ? existing.ruleID : 0,
                    openToEveryone: existing.openToEveryone || edge.openToEveryone,
                    includesSSH: existing.includesSSH || edge.includesSSH,
                    touchesOutside: existing.touchesOutside || edge.touchesOutside,
                    // Ownership only survives if EVERY merged edge was
                    // ownership — any real access grant makes the pair access.
                    isOwnership: existing.isOwnership && edge.isOwnership)
            } else {
                merged[key] = edge
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }

    // MARK: Tables

    private static func buildTables(_ analysis: inout AccessAnalysis, ctx: Context) {
        let rules = ctx.model.rules

        func destinations(for matching: [PolicyRule]) -> [AccessDestination] {
            var result: [AccessDestination] = []
            for rule in matching {
                for dst in rule.dsts {
                    let resolved = resolve(dst, ctx: ctx, asSource: false)
                    let (label, deviceIDs): (String, [String]) = {
                        switch resolved {
                        case .devices(let devs) where dst.hasPrefix("tag:"):
                            return ("\(dst) — \(devs.map(\.shortName).joined(separator: ", "))", devs.map(\.id))
                        case .devices(let devs):
                            return (devs.map(\.shortName).joined(separator: ", "), devs.map(\.id))
                        case .allDevices: return ("All devices", [])
                        case .internet: return ("Internet (exit nodes)", [])
                        case .everyone: return ("Everyone", [])
                        case .allMembers: return ("All members' devices", [])
                        case .users(let u): return (u.joined(separator: ", "), [])
                        case .outside(let l): return (l, [])
                        case .none: return (dst, [])
                        }
                    }()
                    result.append(AccessDestination(
                        id: "\(rule.id):\(dst)",
                        label: label,
                        deviceIDs: deviceIDs,
                        ports: rule.ports,
                        via: rule.summary,
                        risky: rule.coversAllPorts || (rule.coversSSH && rule.srcs.contains("*"))))
                }
            }
            return result
        }

        // Users → hardware, derived from the ONE canonical reachability
        // relation so the table always matches the map and the reach counts.
        var userRows: [PrincipalAccess] = []
        for member in ctx.members {
            let login = member.loginName
            let reachedIDs = analysis.reachability.reachableByPerson[login] ?? []
            let reached = ctx.devices
                .filter { reachedIDs.contains($0.id) }
                .sorted { $0.shortName < $1.shortName }
            var dests: [AccessDestination] = []
            if !reached.isEmpty {
                dests.append(AccessDestination(
                    id: "reach:\(login)",
                    label: reached.map(\.shortName).joined(separator: ", "),
                    deviceIDs: reached.map(\.id),
                    ports: [],
                    via: "Can reach \(reached.count) machine\(reached.count == 1 ? "" : "s")",
                    risky: false))
            }
            let owned = ctx.devicesOwned(by: login)
            if !owned.isEmpty {
                dests.append(AccessDestination(
                    id: "own:\(login)",
                    label: owned.map(\.shortName).joined(separator: ", "),
                    deviceIDs: owned.map(\.id),
                    ports: [],
                    via: "Owns these machines",
                    risky: false))
            }
            userRows.append(PrincipalAccess(
                id: "user:\(login)", label: member.title,
                kindLabel: member.roleLabel, destinations: dests))
        }
        analysis.userAccess = userRows

        // Hardware → hardware. A device matches a rule via its tags,
        // autogroup:tagged, or its host alias / IP. Rules with src "*"
        // are people-level noise here — they live in the user table and
        // in the findings instead.
        func machineMatches(_ dev: Device, _ src: String) -> Bool {
            (src.hasPrefix("tag:") && (dev.tags ?? []).contains(src))
                || (src == "autogroup:tagged" && dev.isTagged)
                || (ctx.model.hosts[src].map { ip in (dev.addresses ?? []).contains(ip) } ?? false)
        }
        var machineRows: [PrincipalAccess] = []
        let sources = ctx.devices.filter { dev in
            rules.contains { rule in rule.srcs.contains { machineMatches(dev, $0) } }
        }
        for dev in sources {
            let matching = rules.filter { rule in
                rule.srcs.contains { machineMatches(dev, $0) }
            }
            machineRows.append(PrincipalAccess(
                id: "machine:\(dev.id)",
                label: dev.shortName,
                kindLabel: (dev.tags ?? []).joined(separator: " "),
                destinations: destinations(for: matching)))
        }
        analysis.machineAccess = machineRows.sorted { $0.label < $1.label }
    }

    // MARK: Findings

    private static func buildFindings(_ analysis: inout AccessAnalysis,
                                      ctx: Context,
                                      devices: [Device],
                                      users: [TSUser],
                                      settings: TailnetSettings?) {
        var findings: [SecurityFinding] = []

        // Public internet exposure via Funnel.
        for target in ctx.model.funnelTargets {
            if case .devices(let devs) = resolve(target, ctx: ctx, asSource: false), !devs.isEmpty {
                findings.append(SecurityFinding(
                    id: "funnel:\(target)",
                    severity: .critical,
                    title: "Public internet exposure (Funnel)",
                    detail: "\(target) devices are allowed to publish services to the open internet via Tailscale Funnel. Anyone online can reach what they share.",
                    deviceIDs: devs.map(\.id),
                    ruleSummary: "nodeAttrs: \(target) → funnel",
                    requiresPolicyEdit: true))
            }
        }

        // Wide-open and SSH-wide rules.
        for rule in ctx.model.rules {
            let wideSource = rule.srcs.contains("*")
            let memberWide = rule.srcs.contains("autogroup:member") || rule.srcs.contains("autogroup:members")
            let dstDevices = rule.dsts.flatMap { dst -> [String] in
                if case .devices(let devs) = resolve(dst, ctx: ctx, asSource: false) { return devs.map(\.id) }
                return []
            }
            // A rule whose only destination is the internet (exit-node use)
            // exposes no machine's port 22.
            let dstIsInternetOnly = !rule.dsts.isEmpty && rule.dsts.allSatisfy { $0 == "autogroup:internet" }
            if wideSource && rule.coversAllPorts && !dstIsInternetOnly && (rule.dsts.contains("*") || !dstDevices.isEmpty) {
                findings.append(SecurityFinding(
                    id: "wideopen:\(rule.id)",
                    severity: .critical,
                    title: "Everything open to everyone",
                    detail: "This rule lets every user and device reach \(rule.dsts.joined(separator: ", ")) on every port. Tighten it to specific groups, tags and ports.",
                    deviceIDs: dstDevices,
                    ruleSummary: rule.summary,
                    requiresPolicyEdit: true))
            } else if wideSource && rule.coversSSH && !dstIsInternetOnly {
                findings.append(SecurityFinding(
                    id: "ssh-wide:\(rule.id)",
                    severity: .high,
                    title: "Port 22 open to the entire tailnet",
                    detail: "SSH on \(rule.dsts.joined(separator: ", ")) is reachable by every user and device — including shared-in ones. Restrict the source to an admin group.",
                    deviceIDs: dstDevices,
                    ruleSummary: rule.summary,
                    requiresPolicyEdit: true))
            } else if memberWide && rule.coversSSH && !dstIsInternetOnly {
                findings.append(SecurityFinding(
                    id: "ssh-members:\(rule.id)",
                    severity: .medium,
                    title: "Port 22 open to all members",
                    detail: "Every member can reach SSH on \(rule.dsts.joined(separator: ", ")). Consider limiting to a group of admins.",
                    deviceIDs: dstDevices,
                    ruleSummary: rule.summary,
                    requiresPolicyEdit: true))
            }
            if rule.dsts.contains("autogroup:internet") {
                findings.append(SecurityFinding(
                    id: "exit-use:\(rule.id)",
                    severity: .info,
                    title: "Exit-node use allowed",
                    detail: "\(rule.srcs.joined(separator: ", ")) may route internet traffic through your exit nodes.",
                    deviceIDs: [],
                    ruleSummary: rule.summary,
                    requiresPolicyEdit: true))
            }
        }

        // Device-level surface.
        for dev in devices {
            let routes = dev.enabledRoutes ?? []
            let exitRoutes = routes.filter { $0 == "0.0.0.0/0" || $0 == "::/0" }
            let subnetRoutes = routes.filter { $0 != "0.0.0.0/0" && $0 != "::/0" }
            if !exitRoutes.isEmpty {
                findings.append(SecurityFinding(
                    id: "exit:\(dev.id)",
                    severity: .high,
                    title: "Exit node: \(dev.shortName)",
                    detail: "This device routes tailnet traffic to the internet. Disable its routes if that isn't intended.",
                    deviceIDs: [dev.id], ruleSummary: nil, requiresPolicyEdit: false))
            }
            if !subnetRoutes.isEmpty {
                findings.append(SecurityFinding(
                    id: "subnet:\(dev.id)",
                    severity: .medium,
                    title: "Subnet router: \(dev.shortName)",
                    detail: "Exposes \(subnetRoutes.joined(separator: ", ")) to the tailnet. Every reachable LAN host inherits your access rules.",
                    deviceIDs: [dev.id], ruleSummary: nil, requiresPolicyEdit: false))
            }
            if dev.sshEnabled == true {
                findings.append(SecurityFinding(
                    id: "ssh-on:\(dev.id)",
                    severity: .low,
                    title: "Tailscale SSH enabled: \(dev.shortName)",
                    detail: "The device accepts Tailscale SSH sessions from anyone your policy's ssh rules allow.",
                    deviceIDs: [dev.id], ruleSummary: nil, requiresPolicyEdit: false))
            }
            if dev.isExternal == true {
                findings.append(SecurityFinding(
                    id: "external:\(dev.id)",
                    severity: .medium,
                    title: "Shared-in device: \(dev.shortName)",
                    detail: "This device belongs to another tailnet. You can't manage it — remove the share in the console if it's no longer needed.",
                    deviceIDs: [dev.id], ruleSummary: nil, requiresPolicyEdit: true))
            }
            if dev.keyExpiryDisabled == true && dev.isTagged {
                findings.append(SecurityFinding(
                    id: "noexpiry:\(dev.id)",
                    severity: .low,
                    title: "Key never expires: \(dev.shortName)",
                    detail: "A stolen key for this server works forever. Re-enable expiry unless uptime truly demands it.",
                    deviceIDs: [dev.id], ruleSummary: nil, requiresPolicyEdit: false))
            }
            if let lockError = dev.tailnetLockError, !lockError.isEmpty {
                findings.append(SecurityFinding(
                    id: "lock:\(dev.id)",
                    severity: .medium,
                    title: "Tailnet lock error: \(dev.shortName)",
                    detail: lockError,
                    deviceIDs: [dev.id], ruleSummary: nil, requiresPolicyEdit: false))
            }
        }

        // Tailnet posture.
        if settings?.devicesApprovalOn != true {
            findings.append(SecurityFinding(
                id: "posture:device-approval",
                severity: .medium,
                title: "Device approval is off",
                detail: "Any successful login adds hardware to the tailnet instantly. Turn on device approval in Settings so new machines wait for you.",
                deviceIDs: [], ruleSummary: nil, requiresPolicyEdit: false))
        }
        if settings?.usersApprovalOn != true {
            findings.append(SecurityFinding(
                id: "posture:user-approval",
                severity: .low,
                title: "User approval is off",
                detail: "New users from your identity provider join without review. Turn on user approval in Settings.",
                deviceIDs: [], ruleSummary: nil, requiresPolicyEdit: false))
        }

        analysis.findings = findings.sorted {
            $0.severity == $1.severity ? $0.title < $1.title : $0.severity > $1.severity
        }
    }
}
