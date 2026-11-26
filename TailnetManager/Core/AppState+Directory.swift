import Foundation

/// The Directory: every server in the network, every address (URL) they
/// serve and everything that runs on them — built from the same server
/// scans as Services, plus the machine list for servers that can't be
/// scanned.
extension AppState {

    /// Every server: tagged machines, Linux machines and anything scanned.
    /// Personal computers and phones aren't servers; Tailscale operator
    /// proxies of a scanned cluster show as that server's websites instead.
    var directoryServers: [Device] {
        cached("directoryServers") {
            let proxies = kubeProxies
            return devices
                .filter { d in
                    d.isExternal != true && proxies[d.shortName] == nil
                        && (isServer(d) || (d.os ?? "").lowercased() == "linux")
                }
                .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
        }
    }

    /// Every address a server serves that can be opened from the tailnet.
    var directoryURLs: [InventoryRow] {
        cached("directoryURLs") {
            inventoryRows.filter { $0.kind.isSite && !$0.url.isEmpty }
        }
    }

    /// Why a server has nothing listed: never scanned, can't be, or failed.
    func directoryStatus(of device: Device) -> (text: String, pill: String?, tone: Tone) {
        switch services.state(of: device.id) {
        case .scanning(let login): return ("Signing in as \(login)…", nil, .neutral)
        case .waitingForApproval: return ("Waiting for you to approve in the browser", "Needs approval", .warning)
        case .failed(let message): return (message, "Scan failed", .critical)
        case .idle, .done: break
        }
        if services.scans[device.id] != nil {
            return ("", device.isOnline ? nil : "Offline", .neutral)
        }
        if (device.os ?? "").lowercased() != "linux" {
            return ("Not scanned: only Linux servers can be scanned", "Not scanned", .neutral)
        }
        if !serviceScanTargets.contains(where: { $0.id == device.id }) {
            return ("Not scanned: your access rules don't let you sign in to it with Tailscale SSH", "No access", .neutral)
        }
        if !device.isOnline { return ("Offline, not scanned yet", "Offline", .neutral) }
        return ("Not scanned yet — press Refresh", "Not scanned", .neutral)
    }

    /// "example.com", "example.ts.net (tailnet)": what a URL list is
    /// grouped by.
    static func domainGroup(of url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return "Other" }
        let labels = host.split(separator: ".")
        if host.hasSuffix(".ts.net"), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".") + " (tailnet)"
        }
        if labels.allSatisfy({ Int($0) != nil }) { return "IP addresses" }
        // Two-part country suffixes ("co.uk", "com.au").
        let twoPart: Set<String> = ["co.uk", "org.uk", "ac.uk", "com.au", "net.au", "co.nz", "com.br", "co.jp", "co.za"]
        if labels.count >= 3, twoPart.contains(labels.suffix(2).joined(separator: ".")) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// The directory as Markdown: servers, their addresses and what runs.
    func directoryMarkdown(servers: [Device], rows: [InventoryRow]) -> String {
        var out = "# Servers and URLs\n\n"
        let date = (serversCheckedAt ?? .now).formatted(date: .abbreviated, time: .shortened)
        out += "Checked \(date). “Who can open it” comes from the address a program listens on; a firewall may still block it.\n"
        let byServer = Dictionary(grouping: rows, by: \.serverID)
        for device in servers {
            let mine = byServer[device.id] ?? []
            out += "\n## \(device.shortName)\n\n"
            var facts: [String] = []
            if let os = services.scans[device.id]?.osName, !os.isEmpty { facts.append(os) }
            facts.append(device.tailnetName)
            if let ip = device.primaryAddress { facts.append(ip) }
            if let stats = services.scans[device.id]?.stats { facts.append(ServerInventory.statsLine(stats)) }
            if !device.isOnline { facts.append("offline") }
            let status = directoryStatus(of: device).text
            if !status.isEmpty { facts.append(status) }
            if !facts.isEmpty { out += facts.joined(separator: " · ") + "\n\n" }
            let urls = mine.filter { $0.kind.isSite && !$0.url.isEmpty }
            if !urls.isEmpty {
                out += "**URLs**\n\n"
                for r in urls {
                    let broken = r.hasMissingBackend ? " — **broken**" : ""
                    out += "- <\(r.url)> (\(r.reachLabel.lowercased()), \(r.via)) \(r.detail)\(broken)\n"
                }
                out += "\n"
            }
            let apps = mine.filter { !($0.kind.isSite && !$0.url.isEmpty) }
            for kind in InventoryRow.Kind.allCases {
                let these = apps.filter { $0.kind == kind }
                guard !these.isEmpty else { continue }
                out += "**\(kind.plural)**\n\n"
                for r in these {
                    var bits: [String] = []
                    if !r.ports.isEmpty { bits.append("ports \(r.ports)") }
                    if r.reach != .none { bits.append(r.reachLabel.lowercased()) }
                    if !r.problem.isEmpty { bits.append(r.problem) }
                    let detail = r.detail.isEmpty ? "" : " — \(r.detail)"
                    out += "- \(r.name)" + (bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))") + detail + "\n"
                }
                out += "\n"
            }
        }
        return out
    }
}

extension AppState {

    /// Every server with the things it serves, simplest first.
    var serverOverviews: [ServerOverview] {
        cached("serverOverviews") {
            let byServer = Dictionary(grouping: inventoryRows, by: \.serverID)
            return directoryServers.map { device in
                let rows = byServer[device.id] ?? []
                let scanned = services.scans[device.id] != nil
                let status = directoryStatus(of: device)
                let scan = services.scans[device.id]
                let served = ServerInventory.servedThings(rows, device: device)
                let sections = ServerInventory.sections(rows, scan: scan)
                return ServerOverview(device: device, scanned: scanned,
                                      status: scanned ? "" : (status.pill.map { "\($0): " } ?? "") + status.text,
                                      served: served, sections: sections,
                                      environment: ServerEnvironment.of(device),
                                      usage: scan.map { ServerUsage.of(scan: $0, served: served, sections: sections) },
                                      stats: scan?.stats, osName: scan?.osName ?? "")
            }
        }
    }


    /// A Tailscale operator proxy machine: the server its cluster runs on
    /// and the website(s) it answers for.
    func proxyServes(_ device: Device) -> (server: String, things: [ServedThing])? {
        guard let server = kubeProxies[device.shortName] else { return nil }
        let rows = inventoryRows.filter { $0.tailnetMachine == device.shortName }
        let host = directoryServers.first { $0.shortName == server } ?? device
        return (server, ServerInventory.servedThings(rows, device: host))
    }

    /// One line for the Machines table: what this machine runs or serves.
    func runsLine(for device: Device) -> String {
        if let proxy = proxyServes(device) {
            let what = proxy.things.map { $0.title + ($0.behind.isEmpty ? "" : " → \($0.behind)") }
            return "Proxy on \(proxy.server) for " + what.joined(separator: ", ")
        }
        guard let overview = serverOverviews.first(where: { $0.device.id == device.id }) else { return "" }
        if !overview.scanned { return services.scans[device.id] == nil && serviceScanTargets.contains(where: { $0.id == device.id }) ? "Not scanned yet" : "" }
        return overview.runsLine.isEmpty ? "Nothing besides the standard tools" : overview.runsLine
    }

    func overviewMarkdown(_ servers: [ServerOverview]) -> String {
        ServerInventory.markdown(servers, checkedAt: serversCheckedAt)
    }
}
