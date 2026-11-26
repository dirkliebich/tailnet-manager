#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Filters

/// What the Machines table shows. The raw values stay as they were (the
/// first cases mirror DevicesFilter) so dashboard and sidebar deep links
/// ("Update available", "Disk 85% full or more", …) keep working; `label`
/// is what the admin reads.
enum MachineShow: String, CaseIterable, Identifiable {
    case all = "All machines"
    case online = "Online"
    case offline = "Offline"
    case needsApproval = "Needs approval"
    case updateAvailable = "Update available"
    case expiringKeys = "Expiring keys"
    case hasAccessGroup = "Has access group"
    case personal = "Personal (untagged)"
    case external = "External"
    case lowDisk = "Disk 85% full or more"
    case highMemory = "RAM 90% used or more"
    case highLoad = "CPU busy"
    case restartNeeded = "Restart needed"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lowDisk: return "Disk nearly full"
        case .highMemory: return "RAM high"
        case .highLoad: return "CPU busy"
        case .restartNeeded: return "Restart needed"
        default: return DevicesFilter(rawValue: rawValue)?.label ?? rawValue
        }
    }

    func matches(_ row: MachineRow) -> Bool {
        switch self {
        case .lowDisk: return (row.stats?.fullestDisk?.usedPercent ?? 0) >= MachineLimits.diskWarning
        case .highMemory: return (row.stats?.memUsedPercent ?? 0) >= MachineLimits.ramHigh
        case .highLoad: return (row.stats?.loadPerCore ?? 0) >= MachineLimits.cpuBusy
        case .restartNeeded: return row.stats?.restartNeeded == true
        default: return DevicesFilter(rawValue: rawValue)?.matches(row.device) ?? true
        }
    }
}

/// One machine with everything the table shows, worked out up front so the
/// cells only read plain values (table rows don't get the environment).
struct MachineRow: Identifiable, Hashable {
    let device: Device
    let owner: String
    let groups: [String]
    let stats: ServerStats?
    let statsDate: Date?
    let isScanTarget: Bool
    /// What it runs or serves, in one line ("Web: Chat · PM2: example-web").
    var runs: String = ""

    var id: String { device.id }
    var name: String { device.shortName }
    var system: String { device.prettyOS }
    var groupsText: String { groups.isEmpty ? "—" : groups.joined(separator: ", ") }
    var address: String { device.primaryAddress ?? "—" }
    var status: String { MachineGrouping.status(of: device) }

    /// The one pill a table row shows: signed out beats needs approval.
    var pill: MachinePill? {
        if device.keyExpired { return MachinePill(text: "Signed out", tone: .critical) }
        if device.needsApproval { return MachinePill(text: "Needs approval", tone: .warning) }
        return nil
    }

    // Sort keys.
    var statusRank: Int { device.needsApproval ? 1 : (device.isOnline ? 0 : 2) }
    var lastSeenSort: Double { device.isOnline ? .greatestFiniteMagnitude : (device.lastSeenDate?.timeIntervalSince1970 ?? 0) }
    var cpuSort: Double { stats?.loadPerCore ?? -1 }
    var memorySort: Double { stats?.memUsedPercent ?? -1 }
    var diskSort: Double { stats?.fullestDisk?.usedPercent ?? -1 }
    var uptimeSort: Double { stats?.uptimeSeconds ?? -1 }
    var signOutSort: Int {
        if device.keyExpiryDisabled == true { return Int.max }
        return device.keyExpiresInDays ?? Int.max - 1
    }
}

/// A group header or a machine.
struct MachineNode: Identifiable, Hashable {
    let id: String
    var row: MachineRow?
    var title = ""
    var children: [MachineNode] = []

    // Group totals, shown in the matching columns of the group row.
    var diskNearlyFull = 0
    var diskCritical = 0
    var ramHigh = 0
    var cpuBusy = 0
    var signedOut = 0
    var needApproval = 0

    var name: String { row?.name ?? title }
    var owner: String { row?.owner ?? "" }
    var system: String { row?.system ?? "" }
    var groupsText: String { row?.groupsText ?? "" }
    var statusRank: Int { row?.statusRank ?? -1 }
    var lastSeenSort: Double { row?.lastSeenSort ?? 0 }
    var cpuSort: Double { row?.cpuSort ?? -2 }
    var memorySort: Double { row?.memorySort ?? -2 }
    var diskSort: Double { row?.diskSort ?? -2 }
    var uptimeSort: Double { row?.uptimeSort ?? -2 }
    var address: String { row?.address ?? "" }
    var signOutSort: Int { row?.signOutSort ?? Int.min }
    var runs: String { row?.runs ?? "" }

    /// A group row's one problem pill (the most serious).
    var groupPill: (text: String, tone: Tone)? {
        if signedOut > 0 { return ("\(signedOut) signed out", .critical) }
        if needApproval > 0 { return ("\(needApproval) need\(needApproval == 1 ? "s" : "") approval", .warning) }
        return nil
    }
}

// MARK: - Formatting

enum MachineFormat {
    static func size(kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .binary)
    }

    /// "1.6 GB", "27 GB", "1.0 TB": short enough for a narrow column.
    static func compact(kb: Int) -> String { compactSize(kb: kb) }

    /// "1.6 / 122 GB"
    static func pair(used: Int, total: Int) -> String {
        let t = Double(total) / 1_048_576
        let u = Double(used) / 1_048_576
        let fmt = { (v: Double) in v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
        return "\(fmt(u)) / \(fmt(t)) GB"
    }

    static func uptime(_ seconds: Double) -> String {
        let days = Int(seconds / 86400)
        if days >= 1 { return "\(days) day\(days == 1 ? "" : "s")" }
        let hours = Int(seconds / 3600)
        if hours >= 1 { return "\(hours) h" }
        return "\(Int(seconds / 60)) min"
    }

    /// "just now", "11 min ago", "3 h ago", "2 days ago".
    static func ago(_ date: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    // Bar colors (fixed meanings): gray when normal, never green.
    static func diskTint(_ percent: Double) -> Color { Tone(disk: percent).color }

    static func ramTint(_ percent: Double) -> Color { Tone(ram: percent).color }

    static func cpuTint(perCore: Double) -> Color { Tone(cpuPerCore: perCore).color }
}

// MARK: - Page

struct MachinesTable: View {
    @Environment(AppState.self) private var app
    @Binding var showSelection: String
    /// The toolbar search (owned by DevicesView); Clear empties it too.
    @Binding var searchText: String

    @AppStorage("machinesGrouping") private var grouping: MachineGrouping = .owner
    @State private var ownerFilter: String?
    @State private var systemFilter: String?
    @State private var groupFilter: String?
    @State private var expansion = GroupExpansion()
    @State private var selection: MachineNode.ID?
    @State private var opened: String?
    @State private var sortOrder = [KeyPathComparator(\MachineNode.name)]
    /// Which columns show (right-click the header to change); remembered.
    /// (New key: the old one kept the narrow name column.)
    @AppStorage("machinesColumns3") private var columnsData = Data()

    private var show: MachineShow { MachineShow(rawValue: showSelection) ?? .all }

    /// Less-used columns start hidden so the table fits a normal window.
    private static var defaultColumns: TableColumnCustomization<MachineNode> {
        var c = TableColumnCustomization<MachineNode>()
        for id in ["status", "system", "groups", "lastSeen", "address", "signOut"] { c[visibility: id] = .hidden }
        return c
    }

    private var columns: Binding<TableColumnCustomization<MachineNode>> {
        Binding(
            get: { (try? JSONDecoder().decode(TableColumnCustomization<MachineNode>.self, from: columnsData)) ?? Self.defaultColumns },
            set: { columnsData = (try? JSONEncoder().encode($0)) ?? Data() }
        )
    }

    /// Every machine as a row; rebuilt only when the data or a scan changes.
    private static func rows(_ app: AppState) -> [MachineRow] {
        app.cached("MachinesTable.rows") {
            let targets = Set(app.serviceScanTargets.map(\.id))
            let names = MachineOwner.names(app.users)
            return app.devices.map { d in
                let scan = app.services.scans[d.id]
                return MachineRow(device: d, owner: MachineOwner.name(of: d, names: names),
                                  groups: MachineGrouping.accessGroups(of: d),
                                  stats: scan?.stats, statsDate: scan?.scannedAt, isScanTarget: targets.contains(d.id),
                                  runs: app.runsLine(for: d))
            }
        }
    }

    private func matchesSearch(_ r: MachineRow) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        var hay = [r.name, r.device.name, r.owner, r.system, r.status, r.groupsText, r.runs]
        if let user = r.device.user { hay.append(user) }
        if let host = r.device.hostname { hay.append(host) }
        hay += r.device.addresses ?? []
        if let s = r.stats { hay += [s.cpuModel, s.kernel] + s.disks.map(\.mount) }
        return hay.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private func visible(_ all: [MachineRow]) -> [MachineRow] {
        all.filter { r in
            show.matches(r) && matchesSearch(r)
                && (ownerFilter == nil || r.owner == ownerFilter)
                && (systemFilter == nil || r.system == systemFilter)
                && (groupFilter == nil || r.groups.contains(groupFilter!) || (groupFilter == "—" && r.groups.isEmpty))
        }
    }

    private func makeGroups(_ rows: [MachineRow]) -> [MachineNode] {
        var buckets: [String: [MachineRow]] = [:]
        for r in rows {
            for k in grouping.keys(r.device, owner: r.owner, accessGroups: r.groups) { buckets[k, default: []].append(r) }
        }
        return grouping.ordered(Array(buckets.keys)).map { key in
            let rs = buckets[key] ?? []
            // A machine can sit in several access groups: ids stay unique per group.
            var node = MachineNode(id: "g:\(key)", title: key,
                                   children: rs.map { MachineNode(id: "\(key)|\($0.id)", row: $0) }.sorted(using: sortOrder))
            for r in rs {
                if MachineShow.lowDisk.matches(r) { node.diskNearlyFull += 1 }
                if (r.stats?.fullestDisk?.usedPercent ?? 0) >= MachineLimits.diskCritical { node.diskCritical += 1 }
                if MachineShow.highMemory.matches(r) { node.ramHigh += 1 }
                if MachineShow.highLoad.matches(r) { node.cpuBusy += 1 }
                if r.device.keyExpired { node.signedOut += 1 }
                if r.device.needsApproval { node.needApproval += 1 }
            }
            return node
        }
    }

    var body: some View {
        // Worked out once per render and passed down.
        let app = self.app
        let all = Self.rows(app)
        let shown = visible(all)
        let groups = makeGroups(shown)
        let groupIDs = groups.map(\.id)
        let selected = node(selection, in: groups)

        ListPageLayout(stats: tiles(all)) {
            filterBar(all: all, shown: shown.count, groupIDs: groupIDs)
        } content: {
            if shown.isEmpty {
                if all.isEmpty {
                    ContentUnavailableView("No machines", systemImage: "laptopcomputer.slash")
                } else {
                    PageEmptyState.nothingMatches(clear: clearFilters)
                }
            } else {
                table(groups, app: app)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ScanServersButton(app: app)
            }
        }
        .inspector(isPresented: Binding(
            get: { selected?.row != nil },
            set: { if !$0 { selection = nil } }
        )) {
            Group {
                if let row = selected?.row {
                    MachinePanel(app: app, row: row) { opened = row.id }
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .navigationDestination(item: $opened) { id in
            DeviceDetailView(deviceID: id)
        }
        // First show: same as a reset. Back from a machine page: groups the
        // admin closed stay closed.
        .onAppear { if shown.count <= 100 { expansion.openAll(groupIDs) } }
        .onChange(of: grouping) { _, _ in selection = nil; resetExpansion() }
        .onChange(of: showSelection) { _, _ in resetExpansion() }
        .onChange(of: ownerFilter) { _, _ in resetExpansion() }
        .onChange(of: systemFilter) { _, _ in resetExpansion() }
        .onChange(of: groupFilter) { _, _ in resetExpansion() }
        .onChange(of: searchText) { _, _ in resetExpansion() }
        // Machines arriving (first load, new machine): open their groups.
        .onChange(of: groupIDs) { _, ids in
            if shown.count <= 100 { expansion.openAll(ids) }
        }
    }

    /// Grouping, filters or search changed: groups start open again (for
    /// lists of 100 machines or fewer).
    private func resetExpansion() {
        let shown = visible(Self.rows(app))
        expansion.reset(groups: makeGroups(shown).map(\.id), rows: shown.count)
    }

    private func clearFilters() {
        showSelection = MachineShow.all.rawValue
        ownerFilter = nil
        systemFilter = nil
        groupFilter = nil
        searchText = ""
    }

    /// A tile sets the filters to exactly its machines; tapping it again
    /// shows everything.
    private func toggle(_ target: MachineShow) {
        let active = show == target
        ownerFilter = nil
        systemFilter = nil
        groupFilter = nil
        showSelection = (active ? MachineShow.all : target).rawValue
    }

    private func node(_ id: MachineNode.ID?, in groups: [MachineNode]) -> MachineNode? {
        guard let id else { return nil }
        for g in groups {
            if g.id == id { return g }
            if let c = g.children.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    // MARK: Stats strip

    private func tiles(_ all: [MachineRow]) -> [StatTile] {
        var online = 0, approval = 0, updates = 0, disk = 0, ram = 0, restart = 0
        for r in all {
            if r.device.isOnline { online += 1 }
            if r.device.needsApproval { approval += 1 }
            if r.device.updateAvailable == true { updates += 1 }
            if MachineShow.lowDisk.matches(r) { disk += 1 }
            if MachineShow.highMemory.matches(r) { ram += 1 }
            if MachineShow.restartNeeded.matches(r) { restart += 1 }
        }
        return [
            StatTile("Online", text: "\(online) of \(all.count)", systemImage: "wifi",
                     active: show == .online) { toggle(.online) },
            StatTile("Needs approval", count: approval, systemImage: "person.badge.clock", tone: .warning,
                     active: show == .needsApproval) { toggle(.needsApproval) },
            StatTile("Updates", count: updates, systemImage: "arrow.down.circle", tone: .info,
                     active: show == .updateAvailable,
                     help: "A newer Tailscale version is available") { toggle(.updateAvailable) },
            StatTile("Disk nearly full", count: disk, systemImage: "internaldrive", tone: .critical,
                     active: show == .lowDisk, help: "Disk 85% full or more") { toggle(.lowDisk) },
            StatTile("RAM high", count: ram, systemImage: "memorychip", tone: .warning,
                     active: show == .highMemory, help: "RAM 90% used or more") { toggle(.highMemory) },
            StatTile("Restart needed", count: restart, systemImage: "restart.circle", tone: .info,
                     active: show == .restartNeeded,
                     help: "Needs a restart to finish installing updates") { toggle(.restartNeeded) },
        ]
    }

    // MARK: Filter bar

    private func filterBar(all: [MachineRow], shown: Int, groupIDs: [String]) -> some View {
        let owners = Array(Set(all.map(\.owner))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let systems = Array(Set(all.map(\.system))).sorted()
        let accessGroups = Array(Set(all.flatMap(\.groups))).sorted()
        let active = (show == .all ? 0 : 1) + (ownerFilter == nil ? 0 : 1)
            + (systemFilter == nil ? 0 : 1) + (groupFilter == nil ? 0 : 1)
        var count = countText(shown, of: all.count, noun: "machines")
        if let lastScan = all.compactMap({ $0.stats == nil ? nil : $0.statsDate }).max() {
            count += " · stats \(MachineFormat.ago(lastScan))"
        }
        var expandAll: (allExpanded: Bool, toggle: () -> Void)?
        if grouping != .none {
            expandAll = (allExpanded: expansion.allOpen(groupIDs), toggle: { expansion.toggleAll(groupIDs) })
        }

        return FilterBar(groupings: MachineGrouping.allCases, grouping: $grouping,
                         groupingTitle: { $0.rawValue }, activeFilters: active, onClear: clearFilters,
                         expandAll: expandAll, countText: count) {
            Picker("Show", selection: $showSelection) {
                ForEach(MachineShow.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Owner", selection: $ownerFilter) {
                Text("Anyone").tag(String?.none)
                Divider()
                ForEach(owners, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker("System", selection: $systemFilter) {
                Text("Any").tag(String?.none)
                Divider()
                ForEach(systems, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker("Access group", selection: $groupFilter) {
                Text("Any").tag(String?.none)
                Divider()
                ForEach(accessGroups, id: \.self) { Text($0).tag(Optional($0)) }
                Text("None").tag(Optional("—"))
            }
        }
    }

    // MARK: Table

    @ViewBuilder
    private func table(_ groups: [MachineNode], app: AppState) -> some View {
        Table(of: MachineNode.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: columns) {
            TableColumn("Machine", value: \MachineNode.name) { node in
                if let r = node.row {
                    MachineNameCell(row: r)
                } else {
                    GroupHeaderLabel(title: node.title, count: node.children.count, pill: node.groupPill)
                }
            }
            .width(min: 170, ideal: 200)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Runs", value: \MachineNode.runs) { node in
                if let r = node.row, !r.runs.isEmpty {
                    Text(r.runs)
                        .foregroundStyle(r.runs.hasPrefix("Not scanned") ? .secondary : .primary)
                        .lineLimit(1)
                        .help(r.runs.replacingOccurrences(of: " · ", with: "\n"))
                }
            }
            .width(min: 160, ideal: 420)
            .customizationID("runs")
            // RAM and disk space first: what the admin checks most.
            // (A table block takes at most 10 columns; groups lift that.)
            Group {
                TableColumn("RAM", value: \MachineNode.memorySort) { node in
                    if let r = node.row {
                        MemoryCell(row: r)
                    } else if node.ramHigh > 0 {
                        Text("\(node.ramHigh) high").foregroundStyle(Tone.warning.color)
                    }
                }
                .width(min: 105, ideal: 135)
                .customizationID("memory")
                TableColumn("Disk space", value: \MachineNode.diskSort) { node in
                    if let r = node.row {
                        DiskCell(row: r)
                    } else if node.diskNearlyFull > 0 {
                        Text("\(node.diskNearlyFull) nearly full")
                            .foregroundStyle(node.diskCritical > 0 ? Tone.critical.color : Tone.warning.color)
                    }
                }
                .width(min: 105, ideal: 140)
                .customizationID("disk")
                TableColumn("CPU", value: \MachineNode.cpuSort) { node in
                    if let s = node.row?.stats {
                        CPUCell(stats: s)
                    } else if node.row == nil, node.cpuBusy > 0 {
                        Text("\(node.cpuBusy) busy").foregroundStyle(Tone.warning.color)
                    }
                }
                .width(min: 85, ideal: 105)
                .customizationID("cpu")
                TableColumn("Up for", value: \MachineNode.uptimeSort) { node in
                    if let up = node.row?.stats?.uptimeSeconds { Text(MachineFormat.uptime(up)).foregroundStyle(.secondary) }
                }
                .width(min: 60, ideal: 80)
                .customizationID("uptime")
            }
            Group {
                TableColumn("Status", value: \MachineNode.statusRank) { node in
                    if let r = node.row {
                        Text(r.status).foregroundStyle(r.device.needsApproval ? Tone.warning.color : .secondary)
                    }
                }
                .width(min: 60, ideal: 90)
                .customizationID("status")
                TableColumn("Owner", value: \MachineNode.owner) { node in
                    if let r = node.row { Text(r.device.isTagged ? "—" : r.owner).foregroundStyle(.secondary) }
                }
                .width(min: 70, ideal: 110)
                .customizationID("owner")
                TableColumn("System", value: \MachineNode.system) { node in
                    if let r = node.row { Text(r.system).foregroundStyle(.secondary) }
                }
                .width(min: 55, ideal: 70)
                .customizationID("system")
                TableColumn("Access groups", value: \MachineNode.groupsText) { node in
                    if let r = node.row { Text(r.groupsText).foregroundStyle(.secondary).help(r.groupsText) }
                }
                .width(min: 90, ideal: 140)
                .customizationID("groups")
                TableColumn("Last seen", value: \MachineNode.lastSeenSort) { node in
                    if let r = node.row { Text(r.device.lastSeenDescription).foregroundStyle(.secondary) }
                }
                .width(min: 70, ideal: 90)
                .customizationID("lastSeen")
            }
            Group {
                TableColumn("Tailscale address", value: \MachineNode.address) { node in
                    if let r = node.row { Text(r.address).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .width(min: 100, ideal: 120)
                .customizationID("address")
                TableColumn("Auto sign-out", value: \MachineNode.signOutSort) { node in
                    if let r = node.row { SignOutCell(device: r.device) }
                }
                .width(min: 80, ideal: 100)
                .customizationID("signOut")
            }
        } rows: {
            if grouping == .none {
                ForEach(groups.flatMap(\.children)) { TableRow($0) }
            } else {
                ForEach(groups) { group in
                    DisclosureTableRow(group, isExpanded: Binding(
                        get: { expansion.isOpen(group.id) },
                        set: { expansion.set(group.id, open: $0) }
                    )) {
                        ForEach(group.children) { TableRow($0) }
                    }
                }
            }
        }
        // Same actions, same order as the inspector.
        .contextMenu(forSelectionType: MachineNode.ID.self) { ids in
            if let id = ids.first, let row = node(id, in: groups)?.row {
                MachineActions(app: app, row: row) { opened = row.id }
            }
        } primaryAction: { ids in
            guard let id = ids.first, let found = node(id, in: groups) else { return }
            if let row = found.row {
                opened = row.id
            } else {
                expansion.set(id, open: !expansion.isOpen(id))
            }
        }
    }
}

// MARK: - Toolbar

/// The page's one primary action. Gets `app` passed in: toolbar content can
/// be built outside the view that has the environment.
private struct ScanServersButton: View {
    let app: AppState

    var body: some View {
        if app.isRefreshing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Refreshing…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        } else {
            Button {
                Task { await app.refreshNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .help("Reloads everything and reads RAM, disk space and CPU from your servers again with Tailscale SSH. Nothing is changed. ⌘R does the same.")
        }
    }
}

// MARK: - Cells (plain values only)

private struct MachineNameCell: View {
    let row: MachineRow

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(isOnline: row.device.isOnline)
            Image(systemName: row.device.systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(row.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .help(row.device.name)
                .layoutPriority(1)
            if let pill = row.pill {
                StatusPill(text: pill.text, tone: pill.tone)
            }
        }
    }
}

private struct MemoryCell: View {
    let row: MachineRow

    var body: some View {
        if let s = row.stats, let p = s.memUsedPercent, let total = s.memTotalKB {
            let used = total - (s.memAvailableKB ?? 0)
            UsageBar(percent: p, tint: MachineFormat.ramTint(p), label: MachineFormat.pair(used: used, total: total))
                .help("\(MachineFormat.size(kb: used)) of \(MachineFormat.size(kb: total)) in use (\(Int(p.rounded()))%)")
        } else if row.isScanTarget {
            Text("Scan for stats").foregroundStyle(.tertiary)
        }
    }
}

private struct DiskCell: View {
    let row: MachineRow

    var body: some View {
        if let s = row.stats, let d = s.fullestDisk {
            UsageBar(percent: d.usedPercent, tint: MachineFormat.diskTint(d.usedPercent),
                     label: "\(MachineFormat.compact(kb: d.availableKB)) free")
                .help(s.disks.filter { $0.sizeKB >= 1_048_576 }
                    .map { "\($0.mount): \(Int($0.usedPercent.rounded()))% used, \(MachineFormat.size(kb: $0.availableKB)) free of \(MachineFormat.size(kb: $0.sizeKB))" }
                    .joined(separator: "\n"))
        } else if row.isScanTarget {
            Text("Scan for stats").foregroundStyle(.tertiary)
        }
    }
}

private struct CPUCell: View {
    let stats: ServerStats

    var body: some View {
        let perCore = stats.loadPerCore ?? 0
        UsageBar(percent: perCore * 100, tint: MachineFormat.cpuTint(perCore: perCore),
                 label: "\(Int((perCore * 100).rounded()))% of \(stats.cpus ?? 0)")
            .help("\(stats.cpus ?? 0) cores · \(stats.cpuModel)\nLoad (1 / 5 / 15 min): \(load(stats.load1)) / \(load(stats.load5)) / \(load(stats.load15))")
    }

    private func load(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
}

private struct SignOutCell: View {
    let device: Device

    var body: some View {
        if device.keyExpiryDisabled == true {
            Text("Never").foregroundStyle(.secondary)
        } else if let days = device.keyExpiresInDays {
            if days < 0 {
                Text("Signed out").foregroundStyle(Tone.critical.color)
            } else {
                Text(days == 0 ? "Today" : "In \(days) days")
                    .foregroundStyle(days <= 30 ? Tone.warning.color : .secondary)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Actions (inspector and right-click menu)

/// At most three, in this order, in both places.
private struct MachineActions: View {
    let app: AppState
    let row: MachineRow
    let open: () -> Void

    var body: some View {
        let d = row.device
        Button("Open machine page", action: open)
        if d.isOnline, d.isExternal != true, (d.os ?? "").lowercased() == "linux",
           app.kubeProxies[d.shortName] == nil, let login = TailscaleSSH.logins(app, d).first {
            Button("SSH as \(login)") { TailscaleSSH.open(login, d) }
                .help("Opens a Tailscale SSH session in \(TailscaleSSH.defaultAppName)")
        }
        if d.needsApproval && d.isExternal != true {
            Button("Approve…") { app.propose(.approve, on: d) }
        }
        if row.isScanTarget && d.isOnline {
            Button("Scan this server") { Task { await app.scanServices([d]) } }
                .disabled(app.services.isScanning)
        }
    }
}

// MARK: - Inspector

private struct MachinePanel: View {
    let app: AppState
    let row: MachineRow
    let open: () -> Void

    var body: some View {
        let d = row.device
        Form {
            Section {
                MachineActions(app: app, row: row, open: open)
            } header: {
                PanelHeader(row: row)
            }

            MachineRunsSection(app: app, device: d)

            Section {
                LabeledContent("Status", value: d.isOnline ? "Online" : "Offline")
                if !d.isOnline { LabeledContent("Last seen", value: d.lastSeenDescription) }
                if d.isExternal == true {
                    LabeledContent("Owner", value: d.user ?? "—")
                } else if !d.isTagged {
                    LabeledContent("Owner", value: row.owner)
                }
                LabeledContent("System", value: d.prettyOS)
                if !row.groups.isEmpty {
                    LabeledContent("Access groups") {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) { ForEach(row.groups, id: \.self) { AccessGroupChip(name: $0) } }
                            Text(row.groupsText)
                        }
                    }
                }
                LabeledContent("Tailscale address") {
                    Text(d.primaryAddress ?? "—").textSelection(.enabled)
                }
                LabeledContent("Tailscale version", value: d.clientVersion ?? "—")
                if d.isExternal != true {
                    LabeledContent("Auto sign-out", value: signOut(d))
                }
            }

            if let s = row.stats {
                ServerSection(stats: s, date: row.statsDate)
            } else if row.isScanTarget {
                Section("Server") {
                    Text("Not scanned yet.").foregroundStyle(.secondary)
                }
            }

            if d.isExternal != true {
                ReachSection(app: app, device: d)
            }
        }
        .formStyle(.grouped)
    }

    private func signOut(_ d: Device) -> String {
        if d.keyExpiryDisabled == true { return "Never" }
        guard let date = d.expiresDate else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// What the machine is used for: the websites it serves and what runs on
/// it, from the last server scan (same inventory as Directory).
private struct MachineRunsSection: View {
    let app: AppState
    let device: Device

    var body: some View {
        if let proxy = app.proxyServes(device) {
            Section {
                ForEach(proxy.things) { website($0) }
            } header: {
                Text("What it is")
            } footer: {
                Text("A Tailscale operator proxy: it puts a Kubernetes app on \(proxy.server) on your tailnet. Nothing to sign in to on this machine.")
            }
        } else if let overview = app.serverOverviews.first(where: { $0.device.id == device.id }), overview.scanned {
            Section {
                if overview.served.isEmpty && overview.sections.isEmpty {
                    Text("Nothing besides the standard tools.").foregroundStyle(.secondary)
                }
                ForEach(overview.served) { website($0) }
                ForEach(overview.sections) { section in
                    LabeledContent {
                        Text(section.items.map(\.name).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } label: {
                        Label(section.kind.title, systemImage: section.kind.systemImage)
                    }
                    .help(section.items.map { $0.name + ($0.detail.isEmpty ? "" : " — \($0.detail)") }.joined(separator: "\n"))
                }
                Button("Open in Directory") { app.navigate(to: "directory") }
                    .buttonStyle(.link)
            } header: {
                Text("What it runs")
            }
        }
    }

    private func website(_ t: ServedThing) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: t.isPublic ? "globe" : "lock.fill")
                    .foregroundStyle(t.isPublic ? Color.secondary : Tone.info.color)
                Text(t.title).fontWeight(.medium)
                if t.broken { StatusPill(text: "Broken", tone: .warning) }
                Spacer()
                if let url = URL(string: t.url) { Link(t.address, destination: url).lineLimit(1) }
            }
            if !t.behind.isEmpty {
                Text(t.product.isEmpty ? t.behind : "\(t.product) · \(t.behind)")
                    .font(.callout)
                    .foregroundStyle(t.broken ? Tone.warning.color : .secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// Name and the pills for anything unusual.
private struct PanelHeader: View {
    let row: MachineRow

    var body: some View {
        let pills = Self.pills(row)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(isOnline: row.device.isOnline)
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.device.name)
            }
            if !pills.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { pillViews(pills) }
                    VStack(alignment: .leading, spacing: 4) { pillViews(pills) }
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }

    private func pillViews(_ pills: [MachinePill]) -> some View {
        ForEach(pills, id: \.self) { StatusPill(text: $0.text, tone: $0.tone) }
    }

    static func pills(_ row: MachineRow) -> [MachinePill] {
        let d = row.device
        var out: [MachinePill] = []
        if d.keyExpired {
            out.append(MachinePill(text: "Signed out", tone: .critical))
        } else if d.keyExpiresSoon, let days = d.keyExpiresInDays {
            out.append(MachinePill(text: days == 0 ? "Signs out today" : "Signs out in \(days) day\(days == 1 ? "" : "s")",
                                   tone: .warning))
        }
        if d.needsApproval { out.append(MachinePill(text: "Needs approval", tone: .warning)) }
        if d.updateAvailable == true { out.append(MachinePill(text: "Updates", tone: .info)) }
        if row.stats?.restartNeeded == true { out.append(MachinePill(text: "Restart needed", tone: .info)) }
        if d.isExternal == true { out.append(MachinePill(text: "Shared in", tone: .neutral)) }
        return out
    }
}

/// RAM, disks and CPU from the last scan, then the other server facts.
private struct ServerSection: View {
    let stats: ServerStats
    let date: Date?

    var body: some View {
        let s = stats
        let bigDisks = s.disks.filter { $0.sizeKB >= 1_048_576 }
        let disks = bigDisks.isEmpty ? (s.fullestDisk.map { [$0] } ?? []) : bigDisks
        Section {
            if let total = s.memTotalKB, let p = s.memUsedPercent {
                let used = total - (s.memAvailableKB ?? 0)
                LabeledContent("RAM") {
                    UsageBar(percent: p, tint: MachineFormat.ramTint(p),
                             label: "\(MachineFormat.size(kb: used)) of \(MachineFormat.size(kb: total))")
                }
            }
            ForEach(disks, id: \.self) { disk in
                LabeledContent {
                    UsageBar(percent: disk.usedPercent, tint: MachineFormat.diskTint(disk.usedPercent),
                             label: "\(Int(disk.usedPercent.rounded()))% · \(MachineFormat.size(kb: disk.availableKB)) free")
                        .help("\(MachineFormat.size(kb: disk.sizeKB)) in all")
                } label: {
                    Text(disk.mount == "/" ? "Disk" : "Disk \(disk.mount)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(disk.mount)
                }
            }
            if let cpus = s.cpus, let perCore = s.loadPerCore {
                LabeledContent("CPU") {
                    UsageBar(percent: perCore * 100, tint: MachineFormat.cpuTint(perCore: perCore),
                             label: "\(Int((perCore * 100).rounded()))% of \(cpus) cores")
                }
            }
            if let up = s.uptimeSeconds { LabeledContent("Up for", value: MachineFormat.uptime(up)) }
            LabeledContent("Processor", value: s.cpuModel.isEmpty ? "—" : s.cpuModel)
            LabeledContent("Load (1 / 5 / 15 min)") {
                Text([s.load1, s.load5, s.load15].map { $0.map { String(format: "%.2f", $0) } ?? "—" }.joined(separator: " / "))
                    .monospacedDigit()
            }
            if let swap = s.swapTotalKB {
                LabeledContent("Swap", value: swap == 0 ? "None" : "\(MachineFormat.size(kb: swap - (s.swapFreeKB ?? 0))) of \(MachineFormat.size(kb: swap)) used")
            }
            if !s.kernel.isEmpty { LabeledContent("Kernel", value: s.kernel) }
        } header: {
            Text("Server")
        } footer: {
            if let date {
                Text("Stats from \(MachineFormat.ago(date)).")
            }
        }
    }
}

/// The people the access rules let reach this machine (was Access › Machines).
private struct ReachSection: View {
    let app: AppState
    let device: Device

    var body: some View {
        let reach = app.accessAnalysis?.reachability
        let names = MachineOwner.names(app.users)
        let people = (reach?.peopleByDevice[device.id] ?? [])
            .map { Person(login: $0, name: names[$0] ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Section {
            if reach == nil {
                Text("Access rules not loaded yet.").foregroundStyle(.secondary)
            } else if people.isEmpty {
                Text("No one").foregroundStyle(.secondary)
            } else if reach?.everyoneDevices.contains(device.id) == true {
                Label("Everyone (\(people.count) \(people.count == 1 ? "person" : "people"))", systemImage: "person.3")
            } else {
                ForEach(people, id: \.login) { person in
                    Label(person.name, systemImage: "person")
                        .help(person.login)
                }
            }
        } header: {
            Text("Who can reach it")
        }
    }

    private struct Person {
        let login: String
        let name: String
    }
}
#endif
