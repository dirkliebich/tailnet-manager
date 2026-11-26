import Foundation

/// The limits behind alerts, tiles and bars, so they always agree.
enum MachineLimits {
    /// Disk: orange from 85%, red from 90%.
    static let diskWarning = 85.0
    static let diskCritical = 90.0
    /// RAM: orange from 90%, red from 95%.
    static let ramHigh = 90.0
    static let ramCritical = 95.0
    /// CPU: orange when the load is at least one per core, red at two.
    static let cpuBusy = 1.0
    static let cpuOverloaded = 2.0
    /// A server offline this long gets "Remove…" instead of a red alert.
    static let longGoneDays = 7
    /// Server numbers older than this are marked out of date on Home.
    static let statsOutOfDate: TimeInterval = 2 * 3600
}

/// Something the admin should see right away: Home's "Needs attention".
struct AppAlert: Identifiable, Hashable {
    enum Level: Int, Comparable {
        case warning = 0, critical = 1
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where clicking the alert leads.
    enum Target: Hashable {
        /// Machines, with this "Show" filter (a DevicesFilter / MachineShow raw value).
        case machines(String)
        case services
        /// Services, showing only websites with nothing behind them.
        case brokenWebsites
        case people
        case keys
    }

    let id: String
    let level: Level
    /// Usually the machine's name.
    let title: String
    let detail: String
    let target: Target
    /// The machine it is about, if it is about one.
    var deviceID: String?
    /// Disk or RAM use, drawn as a bar.
    var percent: Double?
    /// Not seen for a long time: Home offers "Remove…".
    var offerRemove = false
}

extension AppState {

    /// Most urgent first; built from the live API data and the latest server
    /// scan (so server numbers are as fresh as that scan).
    var alerts: [AppAlert] {
        cached("alerts") { buildAlerts() }
    }

    /// Saved server scans of machines still on the network: a removed
    /// server's last scan must not keep alerting.
    var currentScans: [ServerScan] {
        cached("currentScans") {
            guard !devices.isEmpty else { return Array(services.scans.values) }
            let ids = Set(devices.map(\.id))
            return services.scans.values.filter { ids.contains($0.deviceID) }
        }
    }

    /// When the servers' RAM, disk and CPU were last read.
    var serversCheckedAt: Date? { currentScans.map(\.scannedAt).max() }

    /// Machines run as servers: tagged ones, plus any whose stats were read.
    /// Personal computers going offline is normal; a server going offline isn't.
    func isServer(_ device: Device) -> Bool {
        device.isExternal != true && (device.isTagged || services.scans[device.id] != nil)
    }

    private func buildAlerts() -> [AppAlert] {
        var out: [AppAlert] = []
        let names = Dictionary(devices.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })

        // Server health from the last scan.
        for scan in currentScans {
            guard let s = scan.stats else { continue }
            let name = names[scan.deviceID] ?? scan.serverName
            for disk in s.disks where disk.sizeKB >= 1_048_576 && disk.usedPercent >= MachineLimits.diskWarning {
                let pct = Int(disk.usedPercent.rounded())
                let free = compactSize(kb: disk.availableKB)
                let which = disk.mount == "/" ? "Disk" : "Disk \(disk.mount)"
                out.append(AppAlert(id: "disk:\(scan.deviceID):\(disk.mount)",
                                    level: disk.usedPercent >= MachineLimits.diskCritical ? .critical : .warning,
                                    title: name, detail: "\(which) \(pct)% full · \(free) free",
                                    target: .machines("Disk 85% full or more"),
                                    deviceID: scan.deviceID, percent: disk.usedPercent))
            }
            if let p = s.memUsedPercent, p >= MachineLimits.ramHigh {
                out.append(AppAlert(id: "ram:\(scan.deviceID)", level: p >= MachineLimits.ramCritical ? .critical : .warning,
                                    title: name, detail: "RAM \(Int(p.rounded()))% used",
                                    target: .machines("RAM 90% used or more"),
                                    deviceID: scan.deviceID, percent: p))
            }
            if let perCore = s.loadPerCore, perCore >= MachineLimits.cpuBusy {
                out.append(AppAlert(id: "cpu:\(scan.deviceID)", level: perCore >= MachineLimits.cpuOverloaded ? .critical : .warning,
                                    title: name,
                                    detail: String(format: "CPU overloaded (load %.1f on %d cores)", s.load1 ?? 0, s.cpus ?? 0),
                                    target: .machines("CPU busy"), deviceID: scan.deviceID))
            }
        }

        // Servers that dropped off the network. A restart is off for a
        // minute or two, so only after 5 minutes; after a week it reads as
        // gone and Home offers to remove it.
        for d in devices where isServer(d) && !d.isOnline {
            let seen = d.lastSeenDate ?? d.createdDate
            if let seen, Date().timeIntervalSince(seen) < 5 * 60 { continue }
            let days = seen.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 } ?? .max
            if days >= MachineLimits.longGoneDays {
                out.append(AppAlert(id: "gone:\(d.id)", level: .warning, title: d.shortName,
                                    detail: seen == nil ? "Never seen online" : "Not seen for \(days) days",
                                    target: .machines("Offline"), deviceID: d.id, offerRemove: d.canBeDeleted))
            } else {
                let since = seen.map {
                    Calendar.current.isDateInToday($0) ? $0.formatted(date: .omitted, time: .shortened)
                        : $0.formatted(.dateTime.weekday(.wide).hour().minute())
                }
                out.append(AppAlert(id: "offline:\(d.id)", level: .critical, title: d.shortName,
                                    detail: since.map { "Offline since \($0)" } ?? "Offline",
                                    target: .machines("Offline"), deviceID: d.id))
            }
        }

        // Machines that can't connect or wait for the admin.
        for d in devices where d.isExternal != true {
            if d.keyExpired {
                out.append(AppAlert(id: "expired:\(d.id)", level: .critical, title: d.shortName,
                                    detail: "Signed out — its key expired", target: .machines("Expiring keys"),
                                    deviceID: d.id))
            } else if isServer(d), let days = d.keyExpiresInDays, days <= 14 {
                // A server signing itself out takes everything on it offline.
                out.append(AppAlert(id: "expiring:\(d.id)", level: days <= 3 ? .critical : .warning, title: d.shortName,
                                    detail: days == 0 ? "Signs itself out today" : "Signs itself out in \(days) day\(days == 1 ? "" : "s")",
                                    target: .machines("Expiring keys"), deviceID: d.id))
            }
            if d.needsApproval {
                out.append(AppAlert(id: "approve:\(d.id)", level: .warning, title: d.shortName,
                                    detail: "Waiting for your approval", target: .machines("Needs approval"),
                                    deviceID: d.id))
            }
        }

        // People waiting to be let in.
        for u in usersNeedingApproval {
            out.append(AppAlert(id: "approve-person:\(u.id)", level: .warning, title: u.title,
                                detail: "Waiting for your approval", target: .people))
        }

        // Scans that failed.
        for d in devices {
            if case .failed(let message) = services.state(of: d.id) {
                out.append(AppAlert(id: "scan:\(d.id)", level: .warning, title: d.shortName,
                                    detail: "Scan failed: \(message)", target: .services, deviceID: d.id))
            }
        }

        // Websites pointing at nothing (one line, not one per site).
        let broken = inventoryRows.filter(\.hasMissingBackend)
        if !broken.isEmpty {
            let servers = Set(broken.map(\.serverID)).count
            out.append(AppAlert(id: "broken-sites", level: .warning,
                                title: "\(broken.count) broken website\(broken.count == 1 ? "" : "s")",
                                detail: "nothing is running behind them (\(servers) server\(servers == 1 ? "" : "s"))",
                                target: .brokenWebsites))
        }

        // The app's own access token (and others) running out.
        for key in apiTokensExpiringSoon {
            let days = key.expiresDate.map { Calendar.current.dateComponents([.day], from: .now, to: $0).day ?? 0 } ?? 0
            out.append(AppAlert(id: "token:\(key.id)", level: days <= 3 ? .critical : .warning,
                                title: key.description?.isEmpty == false ? key.description! : "Access token",
                                detail: days <= 0 ? "Expires today" : "Expires in \(days) day\(days == 1 ? "" : "s")",
                                target: .keys))
        }

        return out.sorted { ($0.level, $1.title) > ($1.level, $0.title) }
    }

    /// Count shown on a sidebar entry.
    func alertCount(for section: AppSection) -> Int {
        alerts.filter { alert in
            switch (alert.target, section) {
            case (.machines, .machines), (.services, .services), (.brokenWebsites, .services),
                 (.people, .people), (.keys, .admin): return true
            default: return false
            }
        }.count
    }

    /// "Remove…" on a server not seen for a long time: the usual review sheet.
    func proposeRemoving(_ alert: AppAlert) {
        guard let id = alert.deviceID, let device = devices.first(where: { $0.id == id }) else { return }
        let seen = (device.lastSeenDate ?? device.createdDate).map { "Last seen \($0.formatted(date: .abbreviated, time: .omitted)). " } ?? ""
        propose(.remove, on: [device], title: "Remove \(device.shortName) from the network",
                summary: "\(seen)It disappears from every list. If it ever comes back, it has to be added again.")
    }

    func open(_ alert: AppAlert) {
        switch alert.target {
        case .machines(let filter): navigate(to: "machines", devicesFilter: filter)
        case .services: navigate(to: "services")
        case .brokenWebsites:
            servicesFilterRequest = "broken"
            navigate(to: "services")
        case .people: navigate(to: "people", usersFilter: "Needs approval")
        case .keys: navigate(to: "keys")
        }
    }
}
