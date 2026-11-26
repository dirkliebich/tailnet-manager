import Foundation

// MARK: - Overview: what each server serves, in plain words

/// One thing a server serves: "Docs — docs.example.com".
struct ServedThing: Identifiable, Hashable {
    let id: String
    /// "Gist", "Canvas", "LTI Main Auth".
    let title: String
    let url: String
    /// "docs.example.com" (with a port when it isn't the usual one).
    let address: String
    let isPublic: Bool
    let broken: Bool
    /// What's behind it: "example-web (PM2 app)", "redirects to chat.example.com".
    let behind: String
    /// Known software behind it ("Keycloak", "Moodle"), "" when unknown.
    let product: String
}

/// One server in the overview.
struct ServerOverview: Identifiable {
    let device: Device
    var id: String { device.id }
    let scanned: Bool
    /// Why there's nothing to show ("No SSH access"), "" when scanned.
    let status: String
    var served: [ServedThing]
    /// Everything else it runs, by category (Docker, Kubernetes, PM2, …).
    var sections: [OverviewSection]
    var environment: ServerEnvironment = .unknown
    /// How much it's used (scanned servers only).
    var usage: ServerUsage?
    /// CPU, RAM and disk from the last scan.
    var stats: ServerStats?
    /// "Ubuntu 24.04.3 LTS".
    var osName: String = ""

    /// The hardware: "8 CPUs · 31 GB RAM · 225 GB disk".
    var specs: String { stats.map(ServerInventory.specs) ?? "" }

    /// "CPU 1% of 8 cores · RAM 9.9 / 31 GB (32%) · Disk 61 GB free of 225 GB (72% used) · up 144 days".
    var statsLine: String { stats.map(ServerInventory.statsLine) ?? "No CPU, RAM or disk figures yet" }

    /// "Web: Chat, Docs · PM2: example-web · Databases: PostgreSQL": the
    /// names of what it runs, by category, on one line.
    var runsLine: String {
        var parts: [String] = []
        if !served.isEmpty {
            var titles: [String] = []
            for t in served where !titles.contains(t.title) { titles.append(t.title) }
            parts.append("Web: " + titles.joined(separator: ", "))
        }
        for section in sections where section.kind != .programs {
            let label: String
            switch section.kind {
            case .docker: label = "Docker"
            case .kubernetes: label = "Kubernetes"
            case .pm2: label = "PM2"
            case .services: label = "Services"
            case .databases: label = "Databases"
            case .programs: label = "Programs"
            }
            parts.append(label + ": " + section.items.map(\.name).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// "2 websites · Docker · PM2 · PostgreSQL": what the server is for, at a glance.
    var usedFor: String {
        var bits: [String] = []
        if !served.isEmpty { bits.append("\(served.count) website\(served.count == 1 ? "" : "s")") }
        for section in sections {
            switch section.kind {
            case .databases: bits += section.items.map(\.name)
            case .programs: continue
            default: bits.append("\(section.kind.title) (\(section.items.count))")
            }
        }
        return bits.joined(separator: " · ")
    }
}

/// Production, staging or development, read from the server's name
/// ("prod-web-1", "staging-web-1", "dev-web-1") and else its access groups
/// ("tag:web-prod", "tag:preview-host").
enum ServerEnvironment: String, CaseIterable, Identifiable {
    case production = "Production"
    case staging = "Staging"
    case development = "Development"
    case unknown = "Unknown"
    var id: String { rawValue }

    private static func of(words: [String]) -> ServerEnvironment? {
        let w = Set(words.map { $0.lowercased() })
        if !w.isDisjoint(with: ["prd", "prod", "production", "live"]) { return .production }
        if !w.isDisjoint(with: ["uat", "stage", "staging", "stg", "preview", "qa"]) { return .staging }
        if !w.isDisjoint(with: ["dev", "develop", "development", "test", "testing", "loadtest", "sandbox", "demo"]) { return .development }
        return nil
    }

    static func of(_ device: Device) -> ServerEnvironment {
        func words(_ s: String) -> [String] { s.split(whereSeparator: { "-_.:".contains($0) }).map(String.init) }
        if let fromName = of(words: words(device.shortName)) { return fromName }
        let tags = (device.tags ?? []).map { $0.replacingOccurrences(of: "tag:", with: "") }
        return of(words: tags.flatMap(words)) ?? .unknown
    }
}

/// How much a server is used, from its last scan: working websites, people
/// signing in (Tailscale SSH, last 7 days; this app's scans not counted)
/// and CPU load.
struct ServerUsage: Hashable {
    let workingWebsites: Int
    /// Docker, Kubernetes, PM2 apps, services and databases.
    let apps: Int
    let signIns: Int
    let lastSignIn: Date?
    let lastSignInBy: String
    /// Average CPU use over 15 minutes, in percent of all cores.
    let cpuPercent: Double?

    /// Nothing works on it, nobody signed in for a week and the CPU is idle.
    var looksUnused: Bool {
        workingWebsites == 0 && signIns == 0 && (cpuPercent ?? 0) < 5
    }

    /// Why it looks unused, in plain words.
    var reasons: [String] {
        guard looksUnused else { return [] }
        var out = [apps == 0 ? "runs nothing besides the standard tools" : "no working websites",
                   "nobody signed in for 7 days"]
        if let cpu = cpuPercent { out.append(String(format: "CPU idle (%.0f%%)", cpu)) }
        return out
    }

    /// "3 sign-ins in 7 days (last: dirk, 2 days ago)" (CPU is on the stats line).
    var line: String {
        var bits: [String] = []
        if signIns == 0 {
            bits.append("no sign-ins in 7 days")
        } else {
            var text = "\(signIns) sign-in\(signIns == 1 ? "" : "s") in 7 days"
            if let last = lastSignIn {
                let who = lastSignInBy.split(separator: "@").first.map(String.init) ?? lastSignInBy
                text += " (last: \(who), \(last.formatted(.relative(presentation: .named))))"
            }
            bits.append(text)
        }
        return bits.joined(separator: " · ")
    }

    static func of(scan: ServerScan, served: [ServedThing], sections: [OverviewSection]) -> ServerUsage {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let people = scan.sshSessions.filter { $0.kind != .app && $0.granted && ($0.start ?? .distantPast) > weekAgo }
        let last = people.max { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        var cpu: Double?
        if let s = scan.stats, let cpus = s.cpus, cpus > 0, let load = s.load15 ?? s.load1 {
            cpu = min(100, load / Double(cpus) * 100)
        }
        let apps = sections.filter { $0.kind != .programs }.reduce(0) { $0 + $1.items.count }
        return ServerUsage(workingWebsites: served.filter { !$0.broken }.count, apps: apps,
                           signIns: people.count, lastSignIn: last?.start, lastSignInBy: last?.user ?? "",
                           cpuPercent: cpu)
    }
}

/// One category of things a server runs.
struct OverviewSection: Identifiable, Hashable {
    enum Kind: Int, CaseIterable {
        case docker, kubernetes, pm2, services, databases, programs

        var title: String {
            switch self {
            case .docker: return "Docker"
            case .kubernetes: return "Kubernetes"
            case .pm2: return "PM2 apps"
            case .services: return "Services"
            case .databases: return "Databases & caches"
            case .programs: return "Other programs"
            }
        }

        var systemImage: String {
            switch self {
            case .docker: return "shippingbox"
            case .kubernetes: return "square.stack.3d.up"
            case .pm2: return "arrow.triangle.2.circlepath"
            case .services: return "gearshape.2"
            case .databases: return "cylinder.split.1x2"
            case .programs: return "terminal"
            }
        }
    }
    let kind: Kind
    var items: [OverviewItem]
    var id: Int { kind.rawValue }
}

/// "example-auth — Keycloak · port 8500".
struct OverviewItem: Hashable {
    let name: String
    let detail: String
    var warning = false
}

enum ServiceNaming {
    /// Known software, matched in image, unit, app and container names.
    /// Order matters: the first match names a thing.
    static let products: [(key: String, name: String)] = [
        ("keycloak", "Keycloak"), ("vaultwarden", "Vaultwarden"), ("moodle", "Moodle"),
        ("auto-grader-canvas", "Canvas LMS"), ("canvas", "Canvas LMS"), ("argocd", "Argo CD"),
        ("grafana", "Grafana"), ("prometheus-node-exporter", ""), ("node-exporter", ""),
        ("prometheus", "Prometheus"), ("portainer", "Portainer"), ("traefik", "Traefik"),
        ("minio", "MinIO"), ("mailpit", "Mailpit"), ("hatchet", "Hatchet"), ("mediamtx", "MediaMTX"),
        ("pgbouncer", "PgBouncer"), ("pgvector", "PostgreSQL"), ("postgres", "PostgreSQL"),
        ("mariadb", "MariaDB"), ("mysql", "MySQL"), ("redis", "Redis"), ("memcached", "Memcached"),
        ("mongo", "MongoDB"), ("rabbitmq", "RabbitMQ"), ("elasticsearch", "Elasticsearch"),
        ("hindsight", "Hindsight"), ("k3s", "Kubernetes (k3s)"), ("dex", "Dex"),
        ("cert-manager", ""), ("coredns", ""), ("metrics-server", ""), ("local-path", ""),
        ("sealed-secrets", ""), ("tailscale", ""), ("caddy", ""), ("nginx", ""),
    ]

    static func product(in text: String) -> String? {
        let t = text.lowercased()
        return products.first { t.contains($0.key) }?.name
    }

    private static let acronyms: Set<String> = [
        "ai", "api", "lti", "mcp", "ag", "gui", "db", "wcu", "bff", "uat", "prd", "cdn", "ui", "lms", "sso", "s3", "dl", "dlg",
    ]

    /// "lti-main-auth" → "LTI Main Auth", "auth.staging" → "Auth Staging".
    static func humanize(_ text: String) -> String {
        text.split(whereSeparator: { "-_. ".contains($0) })
            .map { w -> String in
                let s = String(w)
                return acronyms.contains(s.lowercased()) ? s.uppercased() : s.prefix(1).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }

    /// "chat.example.com" → "example.com"; "x.example.ts.net" → "example.ts.net".
    static func baseDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        if host.hasSuffix(".ts.net"), labels.count >= 3 { return labels.suffix(3).joined(separator: ".") }
        let twoPart: Set<String> = ["co.uk", "org.uk", "ac.uk", "com.au", "net.au", "co.nz", "com.br", "co.jp", "co.za"]
        if labels.count >= 3, twoPart.contains(labels.suffix(2).joined(separator: ".")) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Where the main page ends up, in plain words: the last hop of
    /// "port 18083 — container edge → container web port 80" is "web".
    static func behind(_ row: InventoryRow) -> String {
        var main = row.routes.first { $0.path.isEmpty || $0.path == "/" || $0.path == "/*" } ?? row.routes.first
        // Files or a fixed reply at the top, an app on other paths: the app
        // is what the site is for.
        if let m = main, m.text.hasPrefix("files in ") || m.text.hasPrefix("replies "),
           let app = row.routes.first(where: { r in
               // A working app on this server: a local port, a container, Kubernetes or PM2.
               let local = ["port ", "container ", "Kubernetes ", "PM2 app "].contains { r.text.hasPrefix($0) }
               return local && !r.text.contains(InventoryBuilder.nothingListening)
           }) {
            main = app
        }
        guard var text = main?.text else { return "" }
        if text.contains(InventoryBuilder.nothingListening) { return "nothing is running behind it" }
        if text.hasPrefix("redirects to ") {
            // Just the host of the target.
            if let r = text.range(of: "://") {
                let host = text[r.upperBound...].prefix { !"/?{:$".contains($0) }
                if !host.isEmpty { return "redirects to \(host)" }
            }
            return text
        }
        if let last = text.components(separatedBy: " → ").last { text = last }
        if let dash = text.range(of: " — ") { text = String(text[dash.upperBound...]) }
        // "container x port 80" → "x (container)".
        text = text.replacingOccurrences(of: #" port \d+$"#, with: "", options: .regularExpression)
        let kinds = [("container ", "container"), ("PM2 app ", "PM2 app"), ("Kubernetes app ", "Kubernetes"),
                     ("Kubernetes service ", "Kubernetes")]
        for (prefix, word) in kinds where text.hasPrefix(prefix) {
            return "\(text.dropFirst(prefix.count)) (\(word))"
        }
        if text.hasPrefix("files in ") { return "a folder of files (\(text.dropFirst("files in ".count)))" }
        if text.hasPrefix("replies ") { return "a fixed reply (\(text.dropFirst("replies ".count)))" }
        return text
    }
}

extension Device {
    /// The full Tailscale name: "server.example.ts.net".
    var tailnetName: String { name.hasSuffix(".") ? String(name.dropLast()) : name }
}

/// Builds the plain-language server inventory from a server's scan.
enum ServerInventory {

    private static func gb(_ kb: Int) -> String {
        let v = Double(kb) / 1_048_576
        if v >= 1000 { return String(format: "%.1f TB", v / 1024) }
        return v >= 10 ? String(format: "%.0f GB", v) : String(format: "%.1f GB", v)
    }

    static func cpuText(_ s: ServerStats) -> String? {
        guard let perCore = s.loadPerCore else { return nil }
        return "\(Int((perCore * 100).rounded()))% of \(s.cpus ?? 0) cores"
    }

    static func ramText(_ s: ServerStats) -> String? {
        guard let total = s.memTotalKB, let p = s.memUsedPercent else { return nil }
        let used = total - (s.memAvailableKB ?? 0)
        return "\(gb(used)) / \(gb(total)) (\(Int(p.rounded()))%)"
    }

    static func diskText(_ s: ServerStats) -> String? {
        guard let d = s.fullestDisk else { return nil }
        return "\(gb(d.availableKB)) free of \(gb(d.sizeKB)) (\(Int(d.usedPercent.rounded()))% used)"
            + (d.mount == "/" ? "" : " on \(d.mount)")
    }

    /// "8 CPUs · 31 GB RAM · 225 GB disk" (several disks: "2 disks, 1.2 TB").
    static func specs(_ s: ServerStats) -> String {
        var bits: [String] = []
        if let cpus = s.cpus { bits.append("\(cpus) CPU\(cpus == 1 ? "" : "s")") }
        if let ram = s.memTotalKB { bits.append("\(gb(ram)) RAM") }
        let disks = s.disks.filter { $0.sizeKB >= 1_048_576 }
        if disks.count == 1 {
            bits.append("\(gb(disks[0].sizeKB)) disk")
        } else if disks.count > 1 {
            bits.append("\(disks.count) disks, \(gb(disks.reduce(0) { $0 + $1.sizeKB })) total")
        }
        return bits.joined(separator: " · ")
    }

    static func statsLine(_ s: ServerStats) -> String {
        var bits: [String] = []
        if let t = cpuText(s) { bits.append("CPU \(t)") }
        if let t = ramText(s) { bits.append("RAM \(t)") }
        if let t = diskText(s) { bits.append("Disk \(t)") }
        if let up = s.uptimeSeconds { bits.append("up \(Int(up / 86_400)) days") }
        return bits.joined(separator: " · ")
    }

    static func servedThings(_ rows: [InventoryRow], device: Device) -> [ServedThing] {
        var seen: [String: ServedThing] = [:]
        var order: [String] = []
        for row in rows where row.kind.isSite && !row.url.isEmpty {
            guard let url = URL(string: row.url), let host = url.host?.lowercased() else { continue }
            let portText = url.port.map { ":\($0)" } ?? ""
            let address = host + portText
            let behind = ServiceNaming.behind(row)
            // Named after what answers, never after the server's own name.
            let product = ServiceNaming.product(in: behind) ?? ""
            // The name people use: the part before the domain ("gist"); for
            // the machine's own name, what runs behind it.
            let base = ServiceNaming.baseDomain(host)
            var sub = host.hasSuffix("." + base) ? String(host.dropLast(base.count + 1)) : ""
            if sub == device.shortName.lowercased() { sub = "" }
            var title: String
            if !sub.isEmpty {
                let squashed = product.lowercased().replacingOccurrences(of: " ", with: "")
                title = !product.isEmpty && squashed.hasPrefix(sub.replacingOccurrences(of: "-", with: ""))
                    ? product : ServiceNaming.humanize(sub)
            } else if host != base, !behind.isEmpty, !behind.hasPrefix("nothing"), !behind.hasPrefix("a "),
                      !behind.hasPrefix("an "), !behind.hasPrefix("redirects") {
                // The machine's own address: name it after what answers.
                let name = behind.components(separatedBy: " (").first ?? behind
                title = product.isEmpty ? ServiceNaming.humanize(name) : product
            } else if host != base {
                title = "Website"
            } else {
                title = host
            }
            if !portText.isEmpty, sub.isEmpty { title += " (port \(url.port!))" }
            let thing = ServedThing(id: row.id, title: title, url: row.url, address: address,
                                    isPublic: row.reach >= .publicAddress, broken: row.hasMissingBackend,
                                    behind: behind, product: product == title ? "" : product)
            // One line per address: https over http, working over broken.
            if let old = seen[address] {
                let better = (old.broken && !thing.broken) || (!old.url.hasPrefix("https") && thing.url.hasPrefix("https"))
                if better { seen[address] = thing }
            } else {
                seen[address] = thing
                order.append(address)
            }
        }
        return order.compactMap { seen[$0] }.sorted {
            ($0.isPublic ? 0 : 1, $0.title.localizedLowercase) < ($1.isPublic ? 0 : 1, $1.title.localizedLowercase)
        }
    }

    /// "registry.example.com/team/web-app:v1" → "web-app".
    static func shortImage(_ image: String) -> String {
        var name = String(image.split(separator: "/").last ?? Substring(image))
        if let colon = name.firstIndex(of: ":") {
            let tag = name[name.index(after: colon)...]
            if tag.count > 14 || tag == "latest" { name = String(name[..<colon]) }
        }
        // A bare image ID ("47293dc1c064") says nothing.
        return name.count == 12 && name.allSatisfy(\.isHexDigit) ? "" : name
    }

    static let databaseProducts: Set<String> = [
        "PostgreSQL", "PgBouncer", "Redis", "Memcached", "MariaDB", "MySQL", "MongoDB", "RabbitMQ", "Elasticsearch",
    ]

    static func sections(_ rows: [InventoryRow], scan: ServerScan?) -> [OverviewSection] {
        var out: [OverviewSection.Kind: [OverviewItem]] = [:]
        func add(_ kind: OverviewSection.Kind, _ item: OverviewItem) { out[kind, default: []].append(item) }
        func join(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }

        // Docker: compose stacks as one line with their parts; Swarm
        // services and lone containers one line each.
        if let containers = scan?.containers, !containers.isEmpty {
            var stacks: [String: [ContainerInfo]] = [:]
            var stackOrder: [String] = []
            var swarm: [String: [ContainerInfo]] = [:]
            var swarmOrder: [String] = []
            var lone: [ContainerInfo] = []
            for c in containers {
                if !c.swarmService.isEmpty {
                    if swarm[c.swarmService] == nil { swarmOrder.append(c.swarmService) }
                    swarm[c.swarmService, default: []].append(c)
                } else if !c.composeProject.isEmpty {
                    let key = c.owner + "|" + c.composeProject
                    if stacks[key] == nil { stackOrder.append(key) }
                    stacks[key, default: []].append(c)
                } else {
                    lone.append(c)
                }
            }
            func partName(_ c: ContainerInfo) -> String {
                if !c.composeService.isEmpty { return c.composeService }
                var n = c.name
                if n.hasPrefix(c.composeProject + "-") { n = String(n.dropFirst(c.composeProject.count + 1)) }
                return n.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
            }
            func products(_ cs: [ContainerInfo]) -> [String] {
                var found: [String] = []
                for c in cs {
                    if let p = ServiceNaming.product(in: c.image + " " + c.name), !p.isEmpty, !found.contains(p) { found.append(p) }
                }
                return found
            }
            func down(_ cs: [ContainerInfo]) -> Bool { cs.contains { !$0.status.hasPrefix("Up") || $0.status.contains("unhealthy") } }
            for key in stackOrder {
                let cs = stacks[key] ?? []
                guard let first = cs.first else { continue }
                if cs.count == 1 {
                    lone.append(first)
                    continue
                }
                let parts = cs.map(partName).sorted()
                let found = products(cs)
                add(.docker, OverviewItem(
                    name: first.composeProject,
                    detail: join(["\(cs.count) containers: " + parts.joined(separator: ", "),
                                  found.isEmpty ? "" : "with " + found.joined(separator: ", "),
                                  first.owner.isEmpty ? "" : first.ownerText]),
                    warning: down(cs)))
            }
            for name in swarmOrder {
                let cs = swarm[name] ?? []
                guard let first = cs.first else { continue }
                add(.docker, OverviewItem(
                    name: name,
                    detail: join([products(cs).first ?? "", shortImage(first.image),
                                  cs.count > 1 ? "\(cs.count) copies (Swarm)" : "Swarm service"]),
                    warning: down(cs)))
            }
            for c in lone {
                let ports = c.ports.map(\.hostPort)
                add(.docker, OverviewItem(
                    name: c.name,
                    detail: join([products([c]).first ?? "", shortImage(c.image) == c.name ? "" : shortImage(c.image),
                                  ports.isEmpty ? "" : "port " + Array(Set(ports)).sorted().joined(separator: ", "),
                                  c.status.hasPrefix("Up") ? "" : c.status, c.ownerText]),
                    warning: down([c])))
            }
        }

        // Kubernetes: one line per namespace with its apps.
        let kube = rows.filter { $0.kind == .kubernetes && !$0.isRoutine }
        var namespaces: [String: [InventoryRow]] = [:]
        for row in kube { namespaces[row.name.components(separatedBy: "/").first ?? row.name, default: []].append(row) }
        for (ns, apps) in namespaces.sorted(by: { $0.key < $1.key }) {
            let names = apps.map { $0.name.components(separatedBy: "/").last ?? $0.name }.sorted()
            let notReady = apps.filter { !$0.problem.isEmpty }.count
            add(.kubernetes, OverviewItem(
                name: ns,
                detail: join([names.joined(separator: ", "), notReady > 0 ? "\(notReady) not ready" : ""]),
                warning: notReady > 0))
        }

        // PM2 apps.
        for row in rows where row.kind == .pm2 {
            add(.pm2, OverviewItem(name: row.name, detail: join([row.detail.replacingOccurrences(of: "run by ", with: "as "),
                                                                  row.ports.isEmpty ? "" : "port \(row.ports)"])))
        }

        // systemd services: databases apart; copies ("media@1…@30") once.
        var copies: [String: (count: Int, row: InventoryRow)] = [:]
        var order: [String] = []
        for row in rows where row.kind == .service && !row.isRoutine {
            let base = row.name.components(separatedBy: "@").first ?? row.name
            if ["docker", "caddy", "nginx", "ssh", "sshd", "pm2-", "snap.", "tailscaled"].contains(where: { base.hasPrefix($0) }) { continue }
            if let product = ServiceNaming.product(in: base), databaseProducts.contains(product) {
                let ports = row.ports.isEmpty ? "" : "port \(row.ports), \(row.reachLabel.lowercased())"
                if !(out[.databases] ?? []).contains(where: { $0.name == product }) {
                    add(.databases, OverviewItem(name: product, detail: ports))
                }
                continue
            }
            if copies[base] == nil { order.append(base) }
            copies[base] = ((copies[base]?.count ?? 0) + 1, copies[base]?.row ?? row)
        }
        for base in order {
            guard let entry = copies[base] else { continue }
            let row = entry.row
            var description = row.detail
            if entry.count > 1 {
                // "load-test media processor 1" → drop the instance number.
                description = description.replacingOccurrences(of: #"\s*\d+$"#, with: "", options: .regularExpression)
            }
            add(.services, OverviewItem(
                name: entry.count > 1 ? "\(base) ×\(entry.count)" : base,
                detail: join([description.hasPrefix("[systemd-run]") ? "" : description,
                              row.ports.isEmpty || entry.count > 1 ? "" : "port \(row.ports)"])))
        }

        // Databases run as plain programs or containers are listed above;
        // other programs that listen beyond the server.
        for row in rows where row.kind == .program && !row.isRoutine {
            if let product = ServiceNaming.product(in: row.name), databaseProducts.contains(product) {
                if !(out[.databases] ?? []).contains(where: { $0.name == product }) {
                    add(.databases, OverviewItem(name: product, detail: "port \(row.ports)"))
                }
                continue
            }
            add(.programs, OverviewItem(name: row.name, detail: join([row.detail, "port \(row.ports)", row.reachLabel.lowercased()])))
        }

        return OverviewSection.Kind.allCases.compactMap { kind in
            out[kind].map { OverviewSection(kind: kind, items: $0) }
        }
    }

    /// The overview as Markdown: per server, what it serves and runs.
    static func markdown(_ servers: [ServerOverview], checkedAt: Date?) -> String {
        var out = "# Server inventory\n\n"
        out += "Checked \((checkedAt ?? .now).formatted(date: .abbreviated, time: .shortened)).\n"
        for s in servers {
            out += "\n## \(s.device.shortName)\n\n"
            out += "`\(s.device.tailnetName)`" + (s.device.primaryAddress.map { " · \($0)" } ?? "") + "\n\n"
            if !s.scanned { out += "\(s.status)\n"; continue }
            if !s.specs.isEmpty {
                out += "**\(s.specs)**" + (s.osName.isEmpty ? "" : " · \(s.osName)")
                    + (s.stats?.cpuModel.isEmpty == false ? " · \(s.stats!.cpuModel)" : "") + "\n\n"
            }
            out += "\(s.statsLine)\n\n"
            if !s.usedFor.isEmpty { out += "Used for: \(s.usedFor)\n\n" }
            if let u = s.usage { out += "Usage: \(u.line)" + (u.looksUnused ? " — **possibly unused**" : "") + "\n\n" }
            if !s.served.isEmpty {
                out += "**Websites**\n\n"
                for t in s.served {
                    let behind = t.product.isEmpty ? t.behind : "\(t.product), \(t.behind)"
                    out += "- \(t.title): <\(t.url)> (\(t.isPublic ? "public" : "tailnet only"))"
                        + (behind.isEmpty ? "" : " → \(behind)") + (t.broken ? " — **broken**" : "") + "\n"
                }
                out += "\n"
            }
            for section in s.sections {
                out += "**\(section.kind.title)**\n\n"
                for item in section.items {
                    out += "- \(item.name)" + (item.detail.isEmpty ? "" : " — \(item.detail)") + "\n"
                }
                out += "\n"
            }
        }
        return out
    }
}
