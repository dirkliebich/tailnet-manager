import Foundation

/// Reports: one per sidebar section, built from the data the app already
/// holds. Only facts the app shows elsewhere go in — never secrets (invite
/// links, key values) and never container commands.
extension AppState {

    func report(for section: AppSection) -> ReportDocument {
        var doc: ReportDocument
        switch section {
        case .home: doc = homeReport()
        case .access: doc = accessReport()
        case .machines: doc = machinesReport()
        case .directory: doc = directoryReport()
        case .services: doc = servicesReport()
        case .activity: doc = activityReport()
        case .people: doc = peopleReport()
        case .admin: doc = adminReport()
        }
        let admin = currentAdmin.map { " by \($0.loginName)" } ?? ""
        doc.subtitle = "Tailnet report\(admin) · data as of "
            + (lastRefreshed ?? .now).formatted(date: .abbreviated, time: .shortened)
        return doc
    }

    // MARK: - Shared helpers

    private func ownerName(_ device: Device) -> String {
        if device.isExternal == true { return "Shared in" }
        if device.isTagged { return "Tagged server" }
        guard let login = device.user else { return "—" }
        return users.first { $0.loginName == login }?.title ?? login
    }

    private func groupsText(_ device: Device) -> String {
        let tags = (device.tags ?? []).map { $0.replacingOccurrences(of: "tag:", with: "") }
        return tags.isEmpty ? "—" : tags.joined(separator: ", ")
    }

    private func statusCell(_ device: Device) -> ReportCell {
        if device.needsApproval { return ReportCell("Needs approval", tone: .warn, badge: true) }
        if device.isOnline { return ReportCell("Online", tone: .good, badge: true) }
        return ReportCell("Offline", tone: .neutral, badge: true)
    }

    private func keyExpiryCell(_ device: Device) -> ReportCell {
        if device.keyExpiryDisabled == true { return ReportCell("Never", sort: "99999") }
        guard let days = device.keyExpiresInDays else { return ReportCell("—", sort: "") }
        if days < 0 { return ReportCell("Expired", sort: "\(days)", tone: .bad, badge: true) }
        let text = days == 0 ? "Today" : "In \(days) day\(days == 1 ? "" : "s")"
        return ReportCell(text, sort: String(format: "%05d", days), tone: days <= 30 ? .warn : nil)
    }

    private func severityCell(_ s: FindingSeverity) -> ReportCell {
        let tone: ReportTone
        switch s {
        case .critical, .high: tone = .bad
        case .medium: tone = .warn
        case .low: tone = .info
        case .info: tone = .neutral
        }
        // Sort most severe first when ascending.
        return ReportCell(s.label, sort: "\(4 - s.rawValue)", tone: tone, badge: true)
    }

    private func gb(_ kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .binary)
    }

    private func percentTone(_ p: Double) -> ReportTone? {
        p >= 90 ? .bad : (p >= 80 ? .warn : nil)
    }

    private func machineNames(_ ids: [String]) -> String {
        ids.compactMap { id in devices.first { $0.id == id }?.shortName }.sorted().joined(separator: ", ")
    }

    // MARK: - Home

    private func homeReport() -> ReportDocument {
        var doc = ReportDocument(title: "Home", subtitle: "")
        doc.stats = [
            ReportStat(label: "Online", value: "\(onlineDevices.count) of \(devices.count)", note: "machines connected", tone: .good),
            ReportStat(label: "Needs approval", value: "\(devicesAwaitingApproval.count + usersNeedingApproval.count)",
                       note: "machines and people", tone: devicesAwaitingApproval.isEmpty && usersNeedingApproval.isEmpty ? .neutral : .warn),
            ReportStat(label: "Auto sign-out soon", value: "\(devicesExpiringSoon.count)",
                       note: devicesWithExpiredKeys.isEmpty ? "within 30 days" : "\(devicesWithExpiredKeys.count) already expired",
                       tone: devicesWithExpiredKeys.isEmpty ? (devicesExpiringSoon.isEmpty ? .neutral : .warn) : .bad),
            ReportStat(label: "Updates available", value: "\(devicesWithUpdates.count)", note: "machines can update", tone: .info),
            ReportStat(label: "Members", value: "\(memberUsers.count)", note: "\(connectedUsers.count) connected now"),
            ReportStat(label: "Paused", value: "\(suspendedUsers.count)", note: "people", tone: suspendedUsers.isEmpty ? .neutral : .warn),
            ReportStat(label: "Pending invites", value: "\(invites.count)", note: "not yet accepted"),
            ReportStat(label: "Active enrollment keys", value: "\(activeAuthKeys.count)"),
        ]

        var attention: [ReportRow] = []
        func item(_ name: String, _ kind: String, _ issue: String, _ tone: ReportTone, _ sev: String) {
            attention.append(ReportRow(cells: [
                "name": ReportCell(name), "kind": ReportCell(kind),
                "issue": ReportCell(issue, tone: tone), "urgency": ReportCell(sev, sort: tone == .bad ? "0" : "1", tone: tone, badge: true),
            ]))
        }
        devicesAwaitingApproval.forEach { item($0.shortName, "Machine", "Waiting for approval", .warn, "Soon") }
        usersNeedingApproval.forEach { item($0.title, "Person", "Waiting for approval", .warn, "Soon") }
        devicesWithExpiredKeys.forEach { item($0.shortName, "Machine", "Signed out (key expired) — can't connect", .bad, "Now") }
        devicesExpiringSoon.filter { !$0.keyExpired }.forEach { d in
            item(d.shortName, "Machine", "Signs out in \(d.keyExpiresInDays ?? 0) days", .warn, "Soon")
        }
        apiTokensExpiringSoon.forEach { key in
            item(key.description?.isEmpty == false ? key.description! : "API token \(key.id)", "Access token",
                 "Expires \(key.expiresDate?.formatted(date: .abbreviated, time: .omitted) ?? "soon")", .warn, "Soon")
        }
        let attentionTable = ReportTable(
            id: "attention", title: "Needs attention",
            columns: [
                ReportColumn(key: "name", title: "Name"),
                ReportColumn(key: "kind", title: "Kind", filter: true, group: true),
                ReportColumn(key: "issue", title: "Issue", filter: true, group: true),
                ReportColumn(key: "urgency", title: "Urgency", filter: true, group: true),
            ],
            rows: attention, sortBy: "urgency", emptyText: "All clear — nothing needs your attention.")

        var osRows: [ReportRow] = []
        for group in osBreakdown {
            let list = devices.filter { $0.prettyOS == group.name }
            osRows.append(ReportRow(cells: [
                "os": ReportCell(group.name), "count": ReportCell(group.count),
                "online": ReportCell(list.filter(\.isOnline).count),
                "updates": ReportCell(list.filter { $0.updateAvailable == true }.count),
            ]))
        }
        let osTable = ReportTable(
            id: "systems", title: "Machines by system",
            columns: [
                ReportColumn(key: "os", title: "System"),
                ReportColumn(key: "count", title: "Machines", numeric: true),
                ReportColumn(key: "online", title: "Online", numeric: true),
                ReportColumn(key: "updates", title: "Can update", numeric: true),
            ],
            rows: osRows, sortBy: "count", sortDescending: true)

        let roleRows = roleBreakdown.map { g in
            ReportRow(cells: ["role": ReportCell(g.name), "count": ReportCell(g.count)])
        }
        let roleTable = ReportTable(
            id: "roles", title: "People by role",
            columns: [ReportColumn(key: "role", title: "Role"), ReportColumn(key: "count", title: "People", numeric: true)],
            rows: roleRows, sortBy: "count", sortDescending: true)

        doc.tables = [attentionTable, osTable, roleTable]
        return doc
    }

    // MARK: - Machines

    private func machinesReport() -> ReportDocument {
        var doc = ReportDocument(title: "Machines", subtitle: "")
        doc.stats = [
            ReportStat(label: "Machines", value: "\(devices.count)"),
            ReportStat(label: "Online", value: "\(onlineDevices.count)", tone: .good),
            ReportStat(label: "Servers (tagged)", value: "\(taggedDevices.count)"),
            ReportStat(label: "Shared in", value: "\(externalDevices.count)"),
            ReportStat(label: "Can update", value: "\(devicesWithUpdates.count)", tone: .info),
            ReportStat(label: "Signed out / soon", value: "\(devicesWithExpiredKeys.count) / \(devicesExpiringSoon.count)",
                       tone: devicesWithExpiredKeys.isEmpty ? .neutral : .bad),
            ReportStat(label: "Disk 85%+ full", value: "\(services.scans.values.filter { ($0.stats?.fullestDisk?.usedPercent ?? 0) >= 85 }.count)",
                       note: "scanned servers", tone: .warn),
            ReportStat(label: "Restart needed", value: "\(services.scans.values.filter { $0.stats?.restartNeeded == true }.count)",
                       note: "scanned servers", tone: .info),
        ]
        let rows = devices.map { d -> ReportRow in
            var details = [
                ReportDetail(label: "Full name", value: d.name),
                ReportDetail(label: "Addresses", value: (d.addresses ?? []).joined(separator: ", ")),
                ReportDetail(label: "Added", value: d.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"),
                ReportDetail(label: "Auto sign-out", value: d.keyExpiryDisabled == true ? "Off" : (d.expiresDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")),
                ReportDetail(label: "Tailscale version", value: d.clientVersion ?? "—"),
            ]
            if let routes = d.advertisedRoutes, !routes.isEmpty {
                details.append(ReportDetail(label: "Offered routes", value: routes.joined(separator: ", ")))
                details.append(ReportDetail(label: "Turned on", value: (d.enabledRoutes ?? []).joined(separator: ", ").ifEmpty("none")))
            }
            if let err = d.tailnetLockError, !err.isEmpty { details.append(ReportDetail(label: "Tailnet lock", value: err)) }
            let scan = services.scans[d.id]
            let stats = scan?.stats
            if let st = stats {
                details.append(ReportDetail(label: "Processor", value: "\(st.cpus.map(String.init) ?? "?") cores · \(st.cpuModel)"))
                details.append(ReportDetail(label: "Load (1/5/15 min)", value: [st.load1, st.load5, st.load15]
                    .map { $0.map { String(format: "%.2f", $0) } ?? "—" }.joined(separator: " / ")))
                if let total = st.memTotalKB {
                    details.append(ReportDetail(label: "Memory", value: "\(gb(total - (st.memAvailableKB ?? 0))) of \(gb(total)) used"))
                }
                if let swap = st.swapTotalKB { details.append(ReportDetail(label: "Swap", value: swap == 0 ? "None" : gb(swap))) }
                details.append(ReportDetail(label: "Disks", value: st.disks.filter { $0.sizeKB >= 1_048_576 }.map {
                    "\($0.mount): \(Int($0.usedPercent.rounded()))% of \(gb($0.sizeKB)), \(gb($0.availableKB)) free"
                }.joined(separator: "\n")))
                if !st.kernel.isEmpty { details.append(ReportDetail(label: "Kernel", value: st.kernel)) }
                if let date = scan?.scannedAt { details.append(ReportDetail(label: "Stats from", value: date.formatted(date: .abbreviated, time: .shortened))) }
            }
            let reachers = accessAnalysis?.reachability.peopleByDevice[d.id]?.count ?? 0
            return ReportRow(cells: [
                "name": ReportCell(d.shortName),
                "os": ReportCell(d.prettyOS),
                "owner": ReportCell(ownerName(d)),
                "groups": ReportCell(groupsText(d)),
                "status": statusCell(d),
                "lastSeen": d.isOnline ? ReportCell("Now", sort: "9999") : ReportCell(date: d.lastSeenDate, empty: "Never"),
                "address": ReportCell(d.primaryAddress ?? "—"),
                "update": d.updateAvailable == true ? ReportCell("Update available", tone: .info) : ReportCell("Up to date"),
                "signOut": keyExpiryCell(d),
                "reach": ReportCell(reachers),
                "ssh": ReportCell.yesNo(d.sshEnabled),
                "cpu": stats.map { st in
                    ReportCell("\(st.cpus ?? 0) cores · load \(String(format: "%.2f", st.load1 ?? 0))",
                               sort: String(format: "%08.3f", st.loadPerCore ?? 0),
                               tone: (st.loadPerCore ?? 0) >= 1 ? .bad : ((st.loadPerCore ?? 0) >= 0.7 ? .warn : nil))
                } ?? ReportCell("—", sort: ""),
                "memory": stats.flatMap { st in st.memUsedPercent.map { p in
                    ReportCell("\(Int(p.rounded()))% of \(gb(st.memTotalKB ?? 0))", sort: String(format: "%06.2f", p), tone: percentTone(p))
                } } ?? ReportCell("—", sort: ""),
                "disk": stats.flatMap { st in st.fullestDisk.map { disk in
                    ReportCell("\(Int(disk.usedPercent.rounded()))% (\(disk.mount)) · \(gb(disk.availableKB)) free",
                               sort: String(format: "%06.2f", disk.usedPercent), tone: percentTone(disk.usedPercent))
                } } ?? ReportCell("—", sort: ""),
                "uptime": stats?.uptimeSeconds.map { up in
                    ReportCell(up >= 86400 ? "\(Int(up / 86400)) days" : "\(Int(up / 3600)) h", sort: String(format: "%012.0f", up))
                } ?? ReportCell("—", sort: ""),
                "restart": stats == nil ? ReportCell("—") : (stats!.restartNeeded ? ReportCell("Restart needed", tone: .warn, badge: true) : ReportCell("No")),
            ], details: details)
        }
        let table = ReportTable(
            id: "machines", title: "All machines",
            columns: [
                ReportColumn(key: "name", title: "Machine"),
                ReportColumn(key: "os", title: "System", filter: true, group: true),
                ReportColumn(key: "owner", title: "Owner", filter: true, group: true),
                ReportColumn(key: "groups", title: "Access groups", filter: true, group: true),
                ReportColumn(key: "status", title: "Status", filter: true, group: true),
                ReportColumn(key: "lastSeen", title: "Last seen"),
                ReportColumn(key: "address", title: "Tailscale address"),
                ReportColumn(key: "update", title: "Updates", filter: true, group: true),
                ReportColumn(key: "signOut", title: "Auto sign-out", filter: true),
                ReportColumn(key: "cpu", title: "CPU"),
                ReportColumn(key: "memory", title: "Memory"),
                ReportColumn(key: "disk", title: "Fullest disk"),
                ReportColumn(key: "uptime", title: "Up for"),
                ReportColumn(key: "restart", title: "Restart", filter: true, group: true),
                ReportColumn(key: "reach", title: "People who can reach it", numeric: true),
                ReportColumn(key: "ssh", title: "Tailscale SSH", filter: true),
            ],
            rows: rows, groupBy: "owner", sortBy: "name")
        doc.tables = [table]
        return doc
    }

    // MARK: - People

    private func peopleReport() -> ReportDocument {
        var doc = ReportDocument(title: "People", subtitle: "")
        doc.stats = [
            ReportStat(label: "Members", value: "\(memberUsers.count)"),
            ReportStat(label: "Connected now", value: "\(connectedUsers.count)", tone: .good),
            ReportStat(label: "Paused", value: "\(suspendedUsers.count)", tone: suspendedUsers.isEmpty ? .neutral : .warn),
            ReportStat(label: "Guests", value: "\(externalUsers.count)", note: "shared in from other networks"),
            ReportStat(label: "Pending invites", value: "\(invites.count)"),
        ]
        let reach = accessAnalysis?.reachability
        let rows = users.map { u -> ReportRow in
            let teams = teams(of: u).map { $0.replacingOccurrences(of: "group:", with: "") }.sorted()
            let owned = devices.filter { $0.user == u.loginName && !$0.isTagged }
            let reachable = Array(reach?.reachableByPerson[u.loginName] ?? [])
            let statusTone: ReportTone? = u.isSuspended ? .warn : (u.needsApproval ? .warn : nil)
            return ReportRow(cells: [
                "name": ReportCell(u.title),
                "email": ReportCell(u.loginName),
                "role": ReportCell(u.isExternal ? "Guest" : u.roleLabel),
                "status": ReportCell(u.statusLabel, tone: statusTone, badge: statusTone != nil),
                "teams": ReportCell(teams.isEmpty ? "—" : teams.joined(separator: ", ")),
                "owned": ReportCell(owned.count),
                "reach": ReportCell(reachable.count),
                "connected": ReportCell.yesNo(u.currentlyConnected, yesTone: .good),
                "lastSeen": u.currentlyConnected == true ? ReportCell("Now", sort: "9999") : ReportCell(date: u.lastSeenDate, empty: "Never"),
            ], details: [
                ReportDetail(label: "Joined", value: u.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"),
                ReportDetail(label: "Teams", value: teams.joined(separator: ", ").ifEmpty("none")),
                ReportDetail(label: "Their machines", value: owned.map(\.shortName).sorted().joined(separator: ", ").ifEmpty("none")),
                ReportDetail(label: "Can reach", value: machineNames(reachable).ifEmpty("nothing")),
            ])
        }
        let people = ReportTable(
            id: "people", title: "Everyone",
            columns: [
                ReportColumn(key: "name", title: "Name"),
                ReportColumn(key: "email", title: "Email"),
                ReportColumn(key: "role", title: "Role", filter: true, group: true),
                ReportColumn(key: "status", title: "Status", filter: true, group: true),
                ReportColumn(key: "teams", title: "Teams", filter: true, group: true),
                ReportColumn(key: "owned", title: "Own machines", numeric: true),
                ReportColumn(key: "reach", title: "Machines they can reach", numeric: true),
                ReportColumn(key: "connected", title: "Connected", filter: true),
                ReportColumn(key: "lastSeen", title: "Last seen"),
            ],
            rows: rows, groupBy: "role", sortBy: "name")

        // Invite links are left out on purpose: they let anyone join.
        let inviteRows = invites.map { inv in
            ReportRow(cells: [
                "email": ReportCell(inv.hasEmail ? inv.email! : "Link invite (no email)"),
                "role": ReportCell(inv.roleLabel),
                "sent": ReportCell(date: inv.lastSentDate, empty: "Not emailed"),
            ])
        }
        let invitesTable = ReportTable(
            id: "invites", title: "Pending invites",
            columns: [
                ReportColumn(key: "email", title: "Invited"),
                ReportColumn(key: "role", title: "Role", filter: true, group: true),
                ReportColumn(key: "sent", title: "Last emailed"),
            ],
            rows: inviteRows, sortBy: "sent", sortDescending: true, emptyText: "No pending invites.")

        let historyRows = peopleLog.map { e -> ReportRow in
            var details = [ReportDetail(label: "Reason", value: e.reason.ifEmpty("—"))]
            if !e.snapshot.isEmpty { details.append(ReportDetail(label: "Had / was given", value: e.snapshot.joined(separator: "\n"))) }
            details.append(ReportDetail(label: "Steps", value: e.steps.map { step in
                (step.error != nil ? "✗ " : (step.skipped == true ? "– " : "✓ ")) + step.title + (step.error.map { " — \($0)" } ?? "")
            }.joined(separator: "\n")))
            if let backup = e.policyBackup { details.append(ReportDetail(label: "Policy backup", value: backup)) }
            return ReportRow(cells: [
                "date": ReportCell(date: e.date),
                "change": ReportCell(e.kind.rawValue.capitalized),
                "name": ReportCell(e.name),
                "email": ReportCell(e.login),
                "by": ReportCell(e.performedBy ?? "—"),
                "result": e.succeeded ? ReportCell("Done", tone: .good) : ReportCell("\(e.failedCount) step(s) failed", tone: .bad, badge: true),
            ], details: details)
        }
        let history = ReportTable(
            id: "history", title: "People history",
            note: "Every add, change, pause and removal made in this app on this Mac.",
            columns: [
                ReportColumn(key: "date", title: "When"),
                ReportColumn(key: "change", title: "Change", filter: true, group: true),
                ReportColumn(key: "name", title: "Person"),
                ReportColumn(key: "email", title: "Email"),
                ReportColumn(key: "by", title: "Done by", filter: true, group: true),
                ReportColumn(key: "result", title: "Result", filter: true),
            ],
            rows: historyRows, sortBy: "date", sortDescending: true, emptyText: "No changes recorded yet.")

        doc.tables = [people, invitesTable, history]
        return doc
    }

    // MARK: - Access

    private func accessReport() -> ReportDocument {
        var doc = ReportDocument(title: "Access", subtitle: "")
        guard let analysis = accessAnalysis else {
            doc.stats = [ReportStat(label: "Access rules", value: "Not loaded", tone: .warn)]
            return doc
        }
        let reach = analysis.reachability
        let findings = analysis.findings
        doc.stats = [
            ReportStat(label: "People with access", value: "\(reach.reachableByPerson.filter { !$0.value.isEmpty }.count)"),
            ReportStat(label: "Person → machine links", value: "\(reach.reachableByPerson.values.reduce(0) { $0 + $1.count })"),
            ReportStat(label: "Open to everyone", value: "\(reach.everyoneDevices.count)", note: "machines",
                       tone: reach.everyoneDevices.isEmpty ? .neutral : .warn),
            ReportStat(label: "Findings", value: "\(findings.count)",
                       note: "\(findings.filter { $0.severity >= .high }.count) high or critical",
                       tone: findings.contains { $0.severity >= .high } ? .bad : .neutral),
        ]

        var pairRows: [ReportRow] = []
        for person in memberUsers {
            for id in reach.reachableByPerson[person.loginName] ?? [] {
                guard let d = devices.first(where: { $0.id == id }) else { continue }
                let key = "\(person.loginName)|\(id)"
                let rules = reach.why(person.loginName, id)
                pairRows.append(ReportRow(cells: [
                    "person": ReportCell(person.title),
                    "machine": ReportCell(d.shortName),
                    "groups": ReportCell(groupsText(d)),
                    "owner": ReportCell(ownerName(d)),
                    "everyone": reach.pairOpenToEveryone.contains(key) ? ReportCell("Yes", tone: .warn) : ReportCell("No"),
                    "ssh": reach.pairSSH.contains(key) ? ReportCell("Port 22 allowed", tone: .info) : ReportCell("—"),
                    "online": d.isOnline ? ReportCell("Online", tone: .good) : ReportCell("Offline"),
                ], details: [ReportDetail(label: "Allowed by", value: rules.joined(separator: "\n").ifEmpty("—"))]))
            }
        }
        let pairs = ReportTable(
            id: "who", title: "Who can reach which machine",
            note: "Worked out from your access rules, with every group, tag and wildcard expanded.",
            columns: [
                ReportColumn(key: "person", title: "Person", filter: true, group: true),
                ReportColumn(key: "machine", title: "Machine", filter: true, group: true),
                ReportColumn(key: "groups", title: "Access groups", filter: true, group: true),
                ReportColumn(key: "owner", title: "Machine owner", filter: true, group: true),
                ReportColumn(key: "everyone", title: "Open to everyone", filter: true),
                ReportColumn(key: "ssh", title: "SSH", filter: true),
                ReportColumn(key: "online", title: "Machine status", filter: true),
            ],
            rows: pairRows, groupBy: "person", sortBy: "machine")

        var machineRows: [ReportRow] = []
        for (srcID, dsts) in reach.machineReach {
            guard let src = devices.first(where: { $0.id == srcID }) else { continue }
            for dstID in dsts {
                guard let dst = devices.first(where: { $0.id == dstID }) else { continue }
                machineRows.append(ReportRow(cells: [
                    "from": ReportCell(src.shortName), "fromGroups": ReportCell(groupsText(src)),
                    "to": ReportCell(dst.shortName), "toGroups": ReportCell(groupsText(dst)),
                    "ssh": reach.pairMachineSSH.contains("\(srcID)|\(dstID)") ? ReportCell("Port 22 allowed", tone: .info) : ReportCell("—"),
                ]))
            }
        }
        let machines = ReportTable(
            id: "m2m", title: "Machine to machine",
            columns: [
                ReportColumn(key: "from", title: "From", filter: true, group: true),
                ReportColumn(key: "fromGroups", title: "From groups", filter: true, group: true),
                ReportColumn(key: "to", title: "To", filter: true, group: true),
                ReportColumn(key: "toGroups", title: "To groups", filter: true, group: true),
                ReportColumn(key: "ssh", title: "SSH", filter: true),
            ],
            rows: machineRows, groupBy: "from", sortBy: "to", emptyText: "No machine can reach another.")

        let findingRows = findings.map { f in
            ReportRow(cells: [
                "severity": severityCell(f.severity),
                "title": ReportCell(f.title),
                "machines": ReportCell(machineNames(f.deviceIDs).ifEmpty("—")),
                "fix": ReportCell(f.requiresPolicyEdit ? "Access rules" : "In the app"),
            ], details: [
                ReportDetail(label: "What it means", value: f.detail),
                ReportDetail(label: "Rule", value: f.ruleSummary ?? "—"),
            ])
        }
        let findingsTable = ReportTable(
            id: "findings", title: "Security findings",
            columns: [
                ReportColumn(key: "severity", title: "Severity", filter: true, group: true),
                ReportColumn(key: "title", title: "Finding"),
                ReportColumn(key: "machines", title: "Machines"),
                ReportColumn(key: "fix", title: "Fixed in", filter: true, group: true),
            ],
            rows: findingRows, groupBy: "severity", sortBy: "severity", emptyText: "No findings.")

        doc.tables = [findingsTable, pairs, machines]
        return doc
    }

    // MARK: - Services

    private func servicesReport() -> ReportDocument {
        var doc = ReportDocument(title: "Services", subtitle: "")
        let byIP = machinesByIP
        let scans = services.scans.values.sorted { $0.serverName.localizedStandardCompare($1.serverName) == .orderedAscending }
        let rows = scans.flatMap { InventoryBuilder.rows(for: $0, machinesByIP: byIP, tailnetDomain: tailnetDomain) }
        let shown = rows.filter { !$0.isRoutine }
        let targets = serviceScanTargets
        doc.stats = [
            ReportStat(label: "Servers scanned", value: "\(targets.filter { services.scans[$0.id] != nil }.count) of \(targets.count)"),
            ReportStat(label: "Public websites", value: "\(shown.filter { $0.kind == .website && $0.reach >= .publicAddress }.count)", tone: .warn),
            ReportStat(label: "Containers", value: "\(shown.filter { $0.kind == .container }.count)", tone: .info),
            ReportStat(label: "Services", value: "\(shown.filter { $0.kind == .service }.count)", note: "standard tools not counted"),
            ReportStat(label: "Nothing behind", value: "\(rows.filter(\.hasMissingBackend).count)",
                       note: "websites pointing at a port nothing listens on",
                       tone: rows.contains(where: \.hasMissingBackend) ? .bad : .good),
        ]
        let itemRows = rows.map { r -> ReportRow in
            var details: [ReportDetail] = r.routes.map {
                ReportDetail(label: $0.path.isEmpty ? "Everything else" : $0.path, value: "→ " + $0.text)
            }
            if r.routes.isEmpty, !r.detail.isEmpty { details.append(ReportDetail(label: "Details", value: r.detail)) }
            if !r.note.isEmpty { details.append(ReportDetail(label: "Note", value: r.note)) }
            let link: String? = r.url.isEmpty ? nil : r.url
            let reachTone: ReportTone? = r.reach >= .publicAddress ? .warn : (r.reach == .tailscale ? .info : nil)
            return ReportRow(cells: [
                "server": ReportCell(r.server),
                "type": ReportCell(r.kind.rawValue, sort: "\(r.kindRank)"),
                "name": ReportCell(r.name, link: link),
                "ports": ReportCell(r.ports, sort: String(format: "%06d", r.portSort == Int.max ? 999_999 : r.portSort)),
                "reach": ReportCell(r.reachLabel, sort: "\(9 - r.reachRank)", tone: reachTone),
                "detail": ReportCell(r.detail),
                "problem": r.hasMissingBackend ? ReportCell("Nothing behind it", tone: .bad, badge: true) : ReportCell("—"),
                "standard": ReportCell(r.isRoutine ? "Standard tool" : "—"),
            ], details: details)
        }
        let inventory = ReportTable(
            id: "inventory", title: "Service inventory",
            note: "“Who can reach it” comes from the address a program listens on; a firewall in front of a server may still block it.",
            columns: [
                ReportColumn(key: "server", title: "Server", filter: true, group: true),
                ReportColumn(key: "type", title: "Type", filter: true, group: true),
                ReportColumn(key: "name", title: "Name"),
                ReportColumn(key: "ports", title: "Ports"),
                ReportColumn(key: "reach", title: "Who can reach it", filter: true, group: true),
                ReportColumn(key: "problem", title: "Problem", filter: true, group: true),
                ReportColumn(key: "standard", title: "Standard tool", filter: true),
                ReportColumn(key: "detail", title: "Details"),
            ],
            rows: itemRows, groupBy: "server", sortBy: "type",
            emptyText: "No scan yet — press Refresh in the app.")

        let serverRows = targets.map { d -> ReportRow in
            let scan = services.scans[d.id]
            let mine = rows.filter { $0.serverID == d.id }
            let status: ReportCell
            switch services.state(of: d.id) {
            case .failed(let message): status = ReportCell("Failed: \(message)", tone: .bad)
            case .scanning: status = ReportCell("Scanning…")
            case .waitingForApproval: status = ReportCell("Waiting for approval", tone: .warn)
            case .idle, .done:
                status = scan != nil ? ReportCell("Scanned", tone: .good) : ReportCell(d.isOnline ? "Not scanned" : "Offline")
            }
            return ReportRow(cells: [
                "server": ReportCell(d.shortName),
                "status": status,
                "system": ReportCell(scan?.osName ?? "—"),
                "login": ReportCell(scan.map { $0.login + ($0.ranAsRoot ? " (sudo)" : "") } ?? "—"),
                "scanned": ReportCell(date: scan?.scannedAt, empty: "Never"),
                "websites": ReportCell(mine.filter { $0.kind == .website }.count),
                "containers": ReportCell(mine.filter { $0.kind == .container }.count),
                "services": ReportCell(mine.filter { $0.kind == .service && !$0.isRoutine }.count),
                "broken": ReportCell(mine.filter(\.hasMissingBackend).count,
                                     tone: mine.contains(where: \.hasMissingBackend) ? .bad : nil),
            ], details: scan.map { InventoryBuilder.notes(for: $0).map { ReportDetail(label: "Note", value: $0) } } ?? [])
        }
        let servers = ReportTable(
            id: "servers", title: "Servers",
            columns: [
                ReportColumn(key: "server", title: "Server"),
                ReportColumn(key: "status", title: "Scan", filter: true, group: true),
                ReportColumn(key: "system", title: "System", filter: true, group: true),
                ReportColumn(key: "login", title: "Signed in as", filter: true),
                ReportColumn(key: "scanned", title: "Scanned"),
                ReportColumn(key: "websites", title: "Websites", numeric: true),
                ReportColumn(key: "containers", title: "Containers", numeric: true),
                ReportColumn(key: "services", title: "Services", numeric: true),
                ReportColumn(key: "broken", title: "Nothing behind", numeric: true),
            ],
            rows: serverRows, sortBy: "server")
        doc.tables = [inventory, servers]
        return doc
    }

    // MARK: - Directory

    private func directoryReport() -> ReportDocument {
        var doc = ReportDocument(title: "Servers and URLs", subtitle: "")
        let rows = inventoryRows
        let urls = directoryURLs
        let servers = directoryServers
        doc.stats = [
            ReportStat(label: "Servers", value: "\(servers.count)",
                       note: "\(servers.filter { services.scans[$0.id] != nil }.count) scanned"),
            ReportStat(label: "URLs", value: "\(urls.count)", tone: .info),
            ReportStat(label: "Public URLs", value: "\(urls.filter { $0.reach >= .publicAddress }.count)", tone: .warn),
            ReportStat(label: "Tailnet-only URLs", value: "\(urls.filter { $0.reach < .publicAddress }.count)", tone: .info),
            ReportStat(label: "Broken URLs", value: "\(urls.filter(\.hasMissingBackend).count)",
                       note: "nothing running behind them",
                       tone: urls.contains(where: \.hasMissingBackend) ? .bad : .good),
        ]
        let urlRows = urls.map { r -> ReportRow in
            var details: [ReportDetail] = r.routes.map {
                ReportDetail(label: $0.path.isEmpty ? "Everything else" : $0.path, value: "→ " + $0.text)
            }
            if !r.note.isEmpty { details.append(ReportDetail(label: "Note", value: r.note)) }
            let open = r.reach >= .publicAddress ? "Public" : (r.reach == .tailscale ? "Tailnet only" : r.reach.label)
            return ReportRow(cells: [
                "url": ReportCell(r.url, link: r.url),
                "domain": ReportCell(AppState.domainGroup(of: r.url)),
                "server": ReportCell(r.server),
                "via": ReportCell(r.via),
                "reach": ReportCell(open, tone: r.reach >= .publicAddress ? .warn : .info),
                "goes": ReportCell(r.detail),
                "status": r.hasMissingBackend ? ReportCell("Broken", tone: .bad, badge: true) : ReportCell("OK", tone: .good),
            ], details: details)
        }
        let urlTable = ReportTable(
            id: "urls", title: "URLs",
            note: "Every address your servers serve that can be opened from the tailnet. “Who can open it” comes from the address a program listens on; a firewall may still block it.",
            columns: [
                ReportColumn(key: "url", title: "URL"),
                ReportColumn(key: "domain", title: "Domain", filter: true, group: true),
                ReportColumn(key: "server", title: "Server", filter: true, group: true),
                ReportColumn(key: "via", title: "Served by", filter: true),
                ReportColumn(key: "reach", title: "Who can open it", filter: true, group: true),
                ReportColumn(key: "status", title: "Status", filter: true, group: true),
                ReportColumn(key: "goes", title: "Goes to"),
            ],
            rows: urlRows, groupBy: "domain", sortBy: "url",
            emptyText: "No scan yet — press Refresh in the app.")

        let byServer = Dictionary(grouping: rows, by: \.serverID)
        let serverRows = servers.map { d -> ReportRow in
            let mine = byServer[d.id] ?? []
            let status = directoryStatus(of: d)
            let theirURLs = mine.filter { $0.kind.isSite && !$0.url.isEmpty }
            let apps = mine.filter { !$0.kind.isSite && !$0.isRoutine }
            var details = theirURLs.map { ReportDetail(label: "URL", value: $0.url) }
            details += apps.map { ReportDetail(label: $0.kind.rawValue, value: $0.name + ($0.detail.isEmpty ? "" : " — \($0.detail)")) }
            return ReportRow(cells: [
                "server": ReportCell(d.shortName),
                "status": ReportCell(status.pill ?? (d.isOnline ? "Scanned" : "Offline"),
                                     tone: status.pill == nil ? .good : (status.tone == .critical ? .bad : .neutral)),
                "system": ReportCell(services.scans[d.id]?.osName.isEmpty == false ? services.scans[d.id]!.osName : d.prettyOS),
                "address": ReportCell(d.primaryAddress ?? "—"),
                "urls": ReportCell(theirURLs.count),
                "apps": ReportCell(apps.count),
                "broken": ReportCell(mine.filter(\.hasMissingBackend).count,
                                     tone: mine.contains(where: \.hasMissingBackend) ? .bad : nil),
            ], details: details)
        }
        let serverTable = ReportTable(
            id: "servers", title: "Servers",
            note: "Open a server to see its URLs and everything that runs on it.",
            columns: [
                ReportColumn(key: "server", title: "Server"),
                ReportColumn(key: "status", title: "Status", filter: true, group: true),
                ReportColumn(key: "system", title: "System", filter: true, group: true),
                ReportColumn(key: "address", title: "Tailscale address"),
                ReportColumn(key: "urls", title: "URLs", numeric: true),
                ReportColumn(key: "apps", title: "Apps", numeric: true),
                ReportColumn(key: "broken", title: "Broken", numeric: true),
            ],
            rows: serverRows, sortBy: "server")
        doc.tables = [urlTable, serverTable]
        return doc
    }

    // MARK: - Activity

    private func activityReport() -> ReportDocument {
        var doc = ReportDocument(title: "Activity", subtitle: "")
        let events = activityEvents
        let logins = events.filter { $0.source == .serverLogin }
        doc.stats = [
            ReportStat(label: "People", value: "\(Set(events.filter { !$0.isAppScan }.map(\.who)).count)"),
            ReportStat(label: "Server logins", value: "\(logins.filter { !$0.isAppScan }.count)", note: "this app's scans not counted", tone: .info),
            ReportStat(label: "Interactive shells", value: "\(logins.filter(\.isShell).count)", tone: .warn),
            ReportStat(label: "Sign-ins & changes", value: "\(events.filter { $0.source == .tailscale }.count)",
                       note: auditLogDays > 0 ? "last \(auditLogDays) days" : "not loaded"),
        ]
        let rows = events.map { e in
            ReportRow(cells: [
                "when": ReportCell(date: e.date),
                "day": ReportCell(e.day, sort: e.date.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
                "who": ReportCell(e.who),
                "did": ReportCell(e.action, tone: e.isShell ? .warn : nil),
                "on": ReportCell(e.target),
                "from": ReportCell(e.from),
                "detail": ReportCell(e.detail),
                "kind": ReportCell(e.source.rawValue),
                "scan": ReportCell(e.isAppScan ? "App scan" : "—"),
            ])
        }
        doc.tables = [ReportTable(
            id: "activity", title: "Who did what, when",
            note: "Server logins come from each server's Tailscale log (last 7 days, as of the last scan). Tailscale doesn't offer network connection logs on this tailnet's plan.",
            columns: [
                ReportColumn(key: "when", title: "When"),
                ReportColumn(key: "day", title: "Day", filter: true, group: true),
                ReportColumn(key: "who", title: "Who", filter: true, group: true),
                ReportColumn(key: "did", title: "Did", filter: true, group: true),
                ReportColumn(key: "on", title: "On", filter: true, group: true),
                ReportColumn(key: "from", title: "From", filter: true),
                ReportColumn(key: "detail", title: "Details"),
                ReportColumn(key: "kind", title: "Log", filter: true, group: true),
                ReportColumn(key: "scan", title: "This app's scans", filter: true),
            ],
            rows: rows, groupBy: "who", sortBy: "when", sortDescending: true,
            emptyText: "No activity loaded yet.")]
        return doc
    }

    // MARK: - Admin

    private func adminReport() -> ReportDocument {
        var doc = ReportDocument(title: "Admin", subtitle: "")
        let hardening = hardeningReports
        let steps = hardening.flatMap { r in r.steps.map { (r, $0) } }
        doc.stats = [
            ReportStat(label: "Active enrollment keys", value: "\(activeAuthKeys.count)"),
            ReportStat(label: "Access tokens expiring", value: "\(apiTokensExpiringSoon.count)",
                       tone: apiTokensExpiringSoon.isEmpty ? .neutral : .warn),
            ReportStat(label: "Hardening steps", value: "\(steps.count)", note: "on \(hardening.filter { !$0.steps.isEmpty }.count) machines",
                       tone: steps.contains { $0.1.severity >= .high } ? .bad : .neutral),
            ReportStat(label: "Stale machines", value: "\(staleDevices().count)", note: "offline 30+ days"),
        ]

        // Key values are never included — only what they are and when they end.
        let keyRows = authKeys.map { k -> ReportRow in
            let owner = users.first { $0.id == k.userId }?.title ?? "—"
            let status: ReportCell
            if k.invalid == true { status = ReportCell("Invalid", tone: .bad, badge: true) }
            else if TSDate.parse(k.revoked) != nil { status = ReportCell("Revoked", badge: true) }
            else if !k.isActive { status = ReportCell("Expired", badge: true) }
            else if k.expiresSoon { status = ReportCell("Expires soon", tone: .warn, badge: true) }
            else { status = ReportCell("Active", tone: .good, badge: true) }
            return ReportRow(cells: [
                "name": ReportCell(k.description?.isEmpty == false ? k.description! : k.id),
                "type": ReportCell(k.isAPIToken ? "Access token" : (k.isAuthKey ? "Enrollment key" : (k.keyType ?? "Key"))),
                "owner": ReportCell(owner),
                "status": status,
                "created": ReportCell(date: k.createdDate),
                "expires": ReportCell(date: k.expiresDate, empty: "Never"),
                "tags": ReportCell((k.tags ?? []).map { $0.replacingOccurrences(of: "tag:", with: "") }.joined(separator: ", ").ifEmpty("—")),
            ], details: [ReportDetail(label: "Key ID", value: k.id)])
        }
        let keys = ReportTable(
            id: "keys", title: "Keys and access tokens",
            columns: [
                ReportColumn(key: "name", title: "Name"),
                ReportColumn(key: "type", title: "Type", filter: true, group: true),
                ReportColumn(key: "owner", title: "Created by", filter: true, group: true),
                ReportColumn(key: "status", title: "Status", filter: true, group: true),
                ReportColumn(key: "created", title: "Created"),
                ReportColumn(key: "expires", title: "Expires"),
                ReportColumn(key: "tags", title: "Access groups", filter: true),
            ],
            rows: keyRows, groupBy: "type", sortBy: "expires", emptyText: "No keys (or this token can't list them).")

        let stepRows = steps.map { (report, step) -> ReportRow in
            let fix = step.apiAction != nil ? "In the app" : (step.requiresPolicyEdit ? "Access rules" : (step.hasCommands ? "Commands on the machine" : "On the machine"))
            return ReportRow(cells: [
                "machine": ReportCell(report.device.shortName),
                "system": ReportCell(report.os.label),
                "severity": severityCell(step.severity),
                "issue": ReportCell(step.title),
                "fix": ReportCell(fix),
            ], details: [ReportDetail(label: "Why", value: step.rationale)])
        }
        let harden = ReportTable(
            id: "hardening", title: "Hardening",
            columns: [
                ReportColumn(key: "machine", title: "Machine", filter: true, group: true),
                ReportColumn(key: "system", title: "System", filter: true, group: true),
                ReportColumn(key: "severity", title: "Severity", filter: true, group: true),
                ReportColumn(key: "issue", title: "Issue"),
                ReportColumn(key: "fix", title: "Fixed in", filter: true, group: true),
            ],
            rows: stepRows, groupBy: "severity", sortBy: "machine", emptyText: "Nothing to harden.")

        var settingRows: [ReportRow] = []
        func setting(_ area: String, _ name: String, _ value: ReportCell) {
            settingRows.append(ReportRow(cells: ["area": ReportCell(area), "name": ReportCell(name), "value": value]))
        }
        if let s = settings {
            setting("Machines", "New machines need approval", .yesNo(s.devicesApprovalOn))
            setting("Machines", "Automatic updates", .yesNo(s.devicesAutoUpdatesOn))
            setting("Machines", "Auto sign-out after", ReportCell(s.devicesKeyDurationDays.map { "\($0) days" } ?? "—"))
            setting("People", "New people need approval", .yesNo(s.usersApprovalOn))
            setting("People", "Who may join other networks", ReportCell(s.usersRoleAllowedToJoinExternalTailnets ?? "—"))
            setting("Network", "Network flow logs", .yesNo(s.networkFlowLoggingOn))
            setting("Network", "Regional routing", .yesNo(s.regionalRoutingOn))
            setting("Network", "HTTPS certificates", .yesNo(s.httpsEnabled))
            setting("Network", "Collect device posture", .yesNo(s.postureIdentityCollectionOn))
            setting("Access rules", "Managed outside the console (GitOps)", .yesNo(s.aclsExternallyManagedOn))
        }
        setting("DNS", "MagicDNS", .yesNo(dnsPreferences?.magicDNS))
        setting("DNS", "Nameservers", ReportCell(dnsNameservers.joined(separator: ", ").ifEmpty("—")))
        setting("DNS", "Search domains", ReportCell(dnsSearchPaths.joined(separator: ", ").ifEmpty("—")))
        let settingsTable = ReportTable(
            id: "settings", title: "Network settings",
            columns: [
                ReportColumn(key: "area", title: "Area", filter: true, group: true),
                ReportColumn(key: "name", title: "Setting"),
                ReportColumn(key: "value", title: "Value", filter: true),
            ],
            rows: settingRows, groupBy: "area", sortBy: "name")

        doc.tables = [harden, keys, settingsTable]
        return doc
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
