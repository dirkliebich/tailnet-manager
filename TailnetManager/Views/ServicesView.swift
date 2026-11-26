#if os(macOS)
import SwiftUI

// MARK: - Grouping & filters

enum InventoryGrouping: String, CaseIterable, Identifiable {
    case server = "Server"
    case type = "Type"
    case reach = "Who can reach it"
    /// Last in the Group by menu.
    case none = "None"
    var id: String { rawValue }
}

enum ReachFilter: String, CaseIterable, Identifiable {
    case any = "Anyone"
    case outside = "Public or all networks"
    case tailscale = "Tailscale only"
    case privateNetwork = "Private network"
    case local = "This server only"
    case none = "No open port"
    var id: String { rawValue }

    func matches(_ reach: ServiceReach) -> Bool {
        switch self {
        case .any: return true
        case .outside: return reach >= .publicAddress
        case .tailscale: return reach == .tailscale
        case .privateNetwork: return reach == .privateNetwork
        case .local: return reach == .local
        case .none: return reach == .none
        }
    }
}

struct InventoryFilter: Equatable {
    var server: String?
    var kind: InventoryRow.Kind?
    var reach: ReachFilter = .any
    var brokenOnly = false

    // What the stat tiles set.
    static let publicWebsites = InventoryFilter(kind: .website, reach: .outside)
    static let containers = InventoryFilter(kind: .container)
    static let services = InventoryFilter(kind: .service)
    static let broken = InventoryFilter(brokenOnly: true)

    /// How many filters are on.
    var count: Int { [server != nil, kind != nil, reach != .any, brokenOnly].filter { $0 }.count }
    var isActive: Bool { count > 0 }

    func matches(_ row: InventoryRow) -> Bool {
        (server == nil || row.server == server)
            && (kind == nil || row.kind == kind)
            && reach.matches(row.reach)
            && (!brokenOnly || row.hasMissingBackend)
    }
}

/// The page's word for a website with nothing behind it.
fileprivate func plainWords(_ text: String) -> String {
    text.replacingOccurrences(of: InventoryBuilder.nothingListening, with: "nothing is running behind it")
}

/// One line of the table: a group (server, type, reach) or an item.
struct InventoryNode: Identifiable, Hashable {
    let id: String
    var row: InventoryRow?
    var title = ""
    /// Group rows: what's there, or why there's nothing (Details column).
    var summary = ""
    /// The server is being scanned right now.
    var scanning = false
    /// At most one pill, the most serious.
    var pillText: String?
    var pillTone: Tone = .neutral
    var deviceID: String?
    var children: [InventoryNode] = []

    var pill: (text: String, tone: Tone)? { pillText.map { ($0, pillTone) } }

    // Sort keys (a group sorts by its title).
    var name: String { row?.name ?? title }
    var kindRank: Int { row?.kindRank ?? -1 }
    var server: String { row?.server ?? title }
    var portSort: Int { row?.portSort ?? Int.max }
    var reachRank: Int { row?.reachRank ?? -1 }
    var detail: String { row.map { plainWords($0.detail) } ?? summary }
}

// MARK: - Page

/// The service inventory: what runs on each server and what Caddy serves to
/// the outside. Scans sign in over Tailscale SSH and only read.
struct ServicesView: View {
    @Environment(AppState.self) private var app

    @AppStorage("servicesGrouping") private var grouping: InventoryGrouping = .server
    @AppStorage("servicesHideRoutine") private var hideRoutine = true
    @State private var filter = InventoryFilter()
    @State private var searchText = ""
    @State private var expansion = GroupExpansion()
    @State private var selection: InventoryNode.ID?
    @State private var removingWebsites = false
    /// The review plan the Remove sheet hands over; shown once it has closed.
    @State private var pendingPlan: ChangePlan?
    @State private var sortOrder = [KeyPathComparator(\InventoryNode.kindRank), KeyPathComparator(\InventoryNode.name)]

    private static let groupings: [InventoryGrouping] = [.server, .type, .reach, .none]

    private var services: ServiceInventory { app.services }

    private var narrowing: Bool { filter.isActive || !searchText.isEmpty }

    private func visible(_ rows: [InventoryRow]) -> [InventoryRow] {
        rows.filter { row in
            (!hideRoutine || !row.isRoutine) && filter.matches(row) && matchesSearch(row)
        }
    }

    private func matchesSearch(_ row: InventoryRow) -> Bool {
        guard !searchText.isEmpty else { return true }
        return [row.name, row.server, plainWords(row.detail), row.ports, row.kind.rawValue, row.reachLabel]
            .contains { $0.localizedCaseInsensitiveContains(searchText) }
            || row.routes.contains {
                plainWords($0.text).localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
            }
    }

    var body: some View {
        // Computed once per render and passed down.
        let rows = app.inventoryRows
        let shown = visible(rows)
        let groups = grouping == .none ? [] : makeGroups(shown)
        let items = grouping == .none ? makeItems(shown) : []
        let groupIDs = groups.map(\.id)
        let selected = node(selection, in: grouping == .none ? items : groups)

        ListPageLayout(stats: services.scans.isEmpty ? [] : tiles(rows)) {
            FilterBar(
                groupings: Self.groupings,
                grouping: $grouping,
                groupingTitle: { $0.rawValue },
                activeFilters: filter.count + (searchText.isEmpty ? 0 : 1),
                onClear: clearFilters,
                expandAll: grouping == .none ? nil : (expansion.allOpen(groupIDs), { expansion.toggleAll(groupIDs) }),
                countText: countText(shown.count, of: rows.count, noun: "items")
                    + (app.serversCheckedAt.map { " · checked \(MachineFormat.ago($0))" } ?? "")
            ) {
                filterMenu(rows)
            }
        } content: {
            if services.scans.isEmpty && !services.isScanning {
                PageEmptyState.notScanned(
                    message: "Scan your \(app.serviceScanTargets.count) servers to see what runs on them.",
                    actionTitle: "Scan servers",
                    action: { Task { await app.scanServices() } })
            } else if groups.isEmpty && items.isEmpty {
                if services.isScanning && !narrowing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PageEmptyState.nothingMatches(clear: { clearFilters() })
                }
            } else {
                table(groups: groups, items: items)
            }
        }
        .navigationTitle("Services")
        .searchable(text: $searchText, prompt: "Search name, server, port, path")
        .inspector(isPresented: Binding(
            get: { selected?.row != nil || selected?.deviceID != nil },
            set: { if !$0 { selection = nil } }
        )) {
            Group {
                if let row = selected?.row {
                    ServiceRowDetail(row: row, scannedAt: services.scans[row.serverID]?.scannedAt)
                } else if let id = selected?.deviceID, let device = app.devices.first(where: { $0.id == id }) {
                    ServerPanel(app: app, device: device)
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .toolbar {
            if app.brokenWebsites.contains(where: \.canRemove) {
                ToolbarItem {
                    Button {
                        removingWebsites = true
                    } label: {
                        Label("Remove broken websites…", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Take websites that nothing answers for out of Caddy on their servers. You see the exact change first; a backup is made and Caddy checks it before reloading.")
                }
            }
            ToolbarItem {
                ScanServersMenu(app: app)
            }
        }
        .sheet(isPresented: $removingWebsites, onDismiss: {
            if let plan = pendingPlan {
                pendingPlan = nil
                app.propose(plan)
            }
        }) {
            RemoveWebsitesSheet(app: app,
                                preselected: selected?.row.map { [$0.id] } ?? [],
                                onPlan: { pendingPlan = $0 })
        }
        .onAppear {
            consumeFilterRequest()
            syncExpansion(reset: true)
        }
        .onChange(of: app.servicesFilterRequest) { _, _ in consumeFilterRequest() }
        .onChange(of: grouping) { _, _ in
            selection = nil
            syncExpansion(reset: true)
        }
        .onChange(of: filter) { _, _ in syncExpansion(reset: true) }
        .onChange(of: hideRoutine) { _, _ in syncExpansion(reset: true) }
        // Narrowing opens every group so matches show at once; clearing the
        // search goes back to the default.
        .onChange(of: searchText) { _, _ in syncExpansion(reset: !narrowing) }
        // New groups (a scan finished, a server came online) follow the same rule.
        .onChange(of: groupIDs) { _, _ in syncExpansion(reset: false) }
    }

    /// Groups start open for 100 rows or fewer; filters and search open
    /// every group except the ones the admin closed.
    private func syncExpansion(reset: Bool) {
        guard grouping != .none else { return }
        let shown = visible(app.inventoryRows)
        let ids = makeGroups(shown).map(\.id)
        if reset { expansion.reset(groups: ids, rows: shown.count) }
        if narrowing || shown.count <= 100 { expansion.openAll(ids) }
    }

    /// The sidebar's broken-websites alert opens the page filtered to them.
    private func consumeFilterRequest() {
        guard let request = app.servicesFilterRequest else { return }
        app.servicesFilterRequest = nil
        if request == "broken" {
            searchText = ""
            filter = .broken
        }
    }

    private func clearFilters() {
        filter = InventoryFilter()
        searchText = ""
    }

    /// A tile sets the filters to exactly its subset; tapping it again clears.
    private func toggle(_ f: InventoryFilter) {
        searchText = ""
        filter = filter == f ? InventoryFilter() : f
    }

    private func node(_ id: InventoryNode.ID?, in nodes: [InventoryNode]) -> InventoryNode? {
        guard let id else { return nil }
        for node in nodes {
            if node.id == id { return node }
            if let child = node.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    // MARK: - Stats

    /// The numbers count exactly the rows each tile's filter then lists.
    private func tiles(_ all: [InventoryRow]) -> [StatTile] {
        let rows = hideRoutine ? all.filter { !$0.isRoutine } : all
        let targets = app.serviceScanTargets
        let scanned = targets.filter { services.scans[$0.id] != nil }.count
        func count(_ f: InventoryFilter) -> Int { rows.filter(f.matches).count }
        func tile(_ label: String, _ f: InventoryFilter, _ image: String, tone: Tone = .neutral, help: String) -> StatTile {
            let active = filter == f
            return StatTile(label, count: count(f), systemImage: image, tone: tone, active: active,
                            help: active ? "Show everything" : help) { toggle(f) }
        }
        return [
            StatTile("Servers scanned", text: "\(scanned) of \(targets.count)", systemImage: "server.rack",
                     help: "Show every server") {
                clearFilters()
                grouping = .server
            },
            tile("Public websites", .publicWebsites, "globe", help: "Show the websites anyone on the internet can open"),
            tile("Containers", .containers, "shippingbox", help: "Show the Docker containers"),
            tile("Services", .services, "gearshape.2", help: "Show the running services"),
            tile("Broken websites", .broken, "exclamationmark.triangle", tone: .warning,
                 help: "Show the websites with nothing running behind them"),
        ]
    }

    // MARK: - Filters menu

    @ViewBuilder
    private func filterMenu(_ rows: [InventoryRow]) -> some View {
        let servers = Array(Set(rows.map(\.server))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        Picker("Server", selection: $filter.server) {
            Text("All servers").tag(String?.none)
            Divider()
            ForEach(servers, id: \.self) { Text($0).tag(Optional($0)) }
        }
        Picker("Type", selection: $filter.kind) {
            Text("All types").tag(InventoryRow.Kind?.none)
            Divider()
            ForEach(InventoryRow.Kind.allCases, id: \.self) { kind in
                Label(kind.plural, systemImage: kind.systemImage).tag(Optional(kind))
            }
        }
        Picker("Who can reach it", selection: $filter.reach) {
            ForEach(ReachFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        Divider()
        Toggle("Only broken websites", isOn: $filter.brokenOnly)
        Toggle("Hide standard tools", isOn: $hideRoutine)
    }

    // MARK: - Groups

    private func makeItems(_ rows: [InventoryRow]) -> [InventoryNode] {
        rows.map { InventoryNode(id: $0.id, row: $0) }.sorted(using: sortOrder)
    }

    private func makeGroups(_ rows: [InventoryRow]) -> [InventoryNode] {
        switch grouping {
        case .none:
            return []
        case .server:
            var groups: [InventoryNode] = []
            var devices = app.serviceScanTargets
            // Servers scanned earlier that aren't targets any more still show.
            for id in services.scans.keys where !devices.contains(where: { $0.id == id }) {
                if let d = app.devices.first(where: { $0.id == id }) { devices.append(d) }
            }
            devices.sort { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
            let byServer = Dictionary(grouping: rows, by: \.serverID)
            for device in devices {
                let mine = byServer[device.id] ?? []
                // While narrowing, only servers with matches; otherwise all,
                // so failed or unscanned servers stay visible.
                if mine.isEmpty && narrowing { continue }
                groups.append(serverGroup(device, rows: mine))
            }
            return groups
        case .type:
            return InventoryRow.Kind.allCases.compactMap { kind in
                let mine = rows.filter { $0.kind == kind }
                guard !mine.isEmpty else { return nil }
                let servers = Set(mine.map(\.serverID)).count
                var group = InventoryNode(id: "type:\(kind.rawValue)", title: kind.plural,
                                          summary: "on \(servers) server\(servers == 1 ? "" : "s")",
                                          children: makeItems(mine))
                setBrokenPill(&group, rows: mine)
                return group
            }
        case .reach:
            return ServiceReach.allCases.reversed().compactMap { reach in
                let mine = rows.filter { $0.reach == reach }
                guard !mine.isEmpty else { return nil }
                var group = InventoryNode(id: "reach:\(reach.rawValue)", title: reach.label,
                                          summary: kindCounts(mine), children: makeItems(mine))
                setBrokenPill(&group, rows: mine)
                return group
            }
        }
    }

    private func setBrokenPill(_ group: inout InventoryNode, rows: [InventoryRow]) {
        let broken = rows.filter(\.hasMissingBackend).count
        if broken > 0 {
            group.pillText = "\(broken) broken"
            group.pillTone = .warning
        }
    }

    /// "17 websites · 1 container · 3 services".
    private func kindCounts(_ rows: [InventoryRow]) -> String {
        InventoryRow.Kind.allCases.compactMap { kind -> String? in
            let n = rows.filter { $0.kind == kind }.count
            return n == 0 ? nil : kind.count(n)
        }
        .joined(separator: " · ")
    }

    /// A server's row: the most serious pill (Scan failed › Needs approval ›
    /// N broken › Offline) and one plain line for the Details column.
    private func serverGroup(_ device: Device, rows: [InventoryRow]) -> InventoryNode {
        var group = InventoryNode(id: "server:\(device.id)", title: device.shortName,
                                  deviceID: device.id, children: makeItems(rows))
        let scanned = services.scans[device.id] != nil
        switch services.state(of: device.id) {
        case .scanning(let login):
            group.scanning = true
            group.summary = "Signing in as \(login)…"
        case .waitingForApproval:
            group.summary = "Waiting for you to approve in the browser"
            group.pillText = "Needs approval"
            group.pillTone = .warning
        case .failed(let message):
            group.summary = message
            group.pillText = "Scan failed"
            group.pillTone = .critical
        case .idle, .done:
            if !scanned {
                group.summary = device.isOnline ? "Not scanned yet" : "Not scanned"
            } else {
                let counts = kindCounts(rows)
                group.summary = counts.isEmpty ? "Nothing besides the standard tools" : counts
            }
        }
        if group.pillText == nil {
            setBrokenPill(&group, rows: rows)
        }
        if group.pillText == nil && !device.isOnline {
            group.pillText = "Offline"
            group.pillTone = .neutral
        }
        return group
    }

    // MARK: - Table

    private func table(groups: [InventoryNode], items: [InventoryNode]) -> some View {
        Table(of: InventoryNode.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \InventoryNode.name) { node in
                if let row = node.row {
                    ItemNameCell(row: row)
                } else {
                    GroupHeaderLabel(title: node.title, count: node.children.count, pill: node.pill)
                        .help(node.title)
                }
            }
            .width(min: 160, ideal: 320)
            TableColumn("Type", value: \InventoryNode.kindRank) { node in
                if let row = node.row { Text(row.kind.rawValue).foregroundStyle(.secondary) }
            }
            .width(min: 70, ideal: 95)
            TableColumn("Server", value: \InventoryNode.server) { node in
                if let row = node.row { Text(row.server).foregroundStyle(.secondary) }
            }
            .width(min: 80, ideal: 120)
            TableColumn("Ports", value: \InventoryNode.portSort) { node in
                if let row = node.row { Text(row.ports).help(row.ports) }
            }
            .width(min: 45, ideal: 70)
            TableColumn("Who can reach it", value: \InventoryNode.reachRank) { node in
                if let row = node.row { ReachLabel(row: row) }
            }
            .width(min: 85, ideal: 115)
            TableColumn("Details", value: \InventoryNode.detail) { node in
                DetailsCell(node: node)
            }
        } rows: {
            if grouping == .none {
                ForEach(items) { TableRow($0) }
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
        .contextMenu(forSelectionType: InventoryNode.ID.self) { ids in
            if let id = ids.first, let node = node(id, in: grouping == .none ? items : groups) {
                if let deviceID = node.deviceID, let device = app.devices.first(where: { $0.id == deviceID }), device.isOnline {
                    Button("Scan this server") { Task { await app.scanServices([device]) } }
                        .disabled(services.isScanning)
                }
                Button("Copy name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.name, forType: .string)
                }
            }
        } primaryAction: { ids in
            // Double-click a group to open or close it.
            guard let id = ids.first, id.hasPrefix("server:") || id.hasPrefix("type:") || id.hasPrefix("reach:") else { return }
            expansion.set(id, open: !expansion.isOpen(id))
        }
    }
}

// MARK: - Cells (plain values only: table rows don't get the app's environment)

private struct ItemNameCell: View {
    let row: InventoryRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(row.name).lineLimit(1).help(row.name)
            if row.hasMissingBackend {
                StatusPill(text: "Broken", tone: .warning)
                    .help("Nothing is running behind it")
            }
        }
    }
}

private struct DetailsCell: View {
    let node: InventoryNode

    var body: some View {
        HStack(spacing: 6) {
            if node.scanning { ProgressView().controlSize(.mini) }
            Text(node.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(node.detail)
        }
    }
}

// MARK: - Toolbar

/// "Refresh" with Scan settings behind its arrow.
struct ScanServersMenu: View {
    // Passed in: toolbar content can be built outside the view that has it.
    let app: AppState
    @State private var showSettings = false

    var body: some View {
        let busy = app.isRefreshing
        Menu {
            Button("Scan settings…") { showSettings = true }
        } label: {
            Label(busy ? "Refreshing…" : "Refresh",
                  systemImage: busy ? "hourglass" : "arrow.clockwise")
        } primaryAction: {
            guard !app.isRefreshing else { return }
            Task { await app.refreshNow() }
        }
        .labelStyle(.titleAndIcon)
        .help(busy
              ? "Reading your servers…"
              : "Reads every server again with Tailscale SSH (websites, containers, services, open ports). Nothing is changed. ⌘R does the same.")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            ScanSettings(app: app)
        }
    }
}

// MARK: - Reach

private struct ReachLabel: View {
    let row: InventoryRow

    var body: some View {
        Text(row.reachLabel)
            .foregroundStyle(Self.tint(row.reach))
            .help(Self.explanation(row.reach))
    }

    /// Blue = Tailscale only (fixed color meaning); no other decoration.
    static func tint(_ reach: ServiceReach) -> Color {
        switch reach {
        case .tailscale: return Tone.info.color
        case .allNetworks, .publicAddress, .privateNetwork: return .primary
        case .local, .none: return .secondary
        }
    }

    static func explanation(_ reach: ServiceReach) -> String {
        switch reach {
        case .allNetworks: return "Listens on every network address of the server, including its public one. A firewall in front of the server may still block it."
        case .publicAddress: return "Listens on the server's public address. A firewall in front of the server may still block it."
        case .tailscale: return "Listens only on the server's Tailscale address, so only machines on your network can reach it (as your access rules allow)."
        case .privateNetwork: return "Listens on a private address, such as the cloud provider's internal network or Docker's."
        case .local: return "Only programs on the server itself can reach it."
        case .none: return "Doesn't listen on any port of the server."
        }
    }
}

// MARK: - Item detail (inspector)

private struct ServiceRowDetail: View {
    let row: InventoryRow
    let scannedAt: Date?

    private var websiteURL: URL? { row.url.isEmpty ? nil : URL(string: row.url) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Type") { Label(row.kind.rawValue, systemImage: row.kind.systemImage) }
                LabeledContent("Server", value: row.server)
                if !row.ports.isEmpty { LabeledContent("Ports", value: row.ports) }
                LabeledContent("Who can reach it") { ReachLabel(row: row) }
                if !row.via.isEmpty { LabeledContent("Served by", value: row.via) }
                if !row.problem.isEmpty {
                    LabeledContent("Status") { Text(row.problem).foregroundStyle(Tone.warning.color) }
                }
                if let url = websiteURL {
                    Link(destination: url) {
                        Label("Open \(url.host ?? row.name)", systemImage: "safari")
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(row.name).font(.headline).textSelection(.enabled)
                    if row.hasMissingBackend { StatusPill(text: "Broken", tone: .warning) }
                }
            } footer: {
                Text(ReachLabel.explanation(row.reach))
            }

            if !row.note.isEmpty {
                Section { Label(row.note, systemImage: "info.circle") }
            }

            if !row.routes.isEmpty {
                Section("Where each path goes") {
                    ForEach(Array(row.routes.enumerated()), id: \.offset) { _, route in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.path.isEmpty ? "Everything else" : route.path)
                                .font(.callout.monospaced())
                            Text(plainWords(route.text))
                                .foregroundStyle(route.text.contains(InventoryBuilder.nothingListening)
                                                 ? Tone.warning.color : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else if !row.detail.isEmpty {
                Section("Details") {
                    Text(plainWords(row.detail)).textSelection(.enabled)
                }
            }

            Section {
                RelativeTimeText(date: scannedAt, prefix: "Scanned ")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Server detail (inspector)

private struct ServerPanel: View {
    let app: AppState
    let device: Device

    private var scan: ServerScan? { app.services.scans[device.id] }
    private var state: ServerScanState { app.services.state(of: device.id) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { status }
                if let scan {
                    if !scan.osName.isEmpty { LabeledContent("System", value: scan.osName) }
                    LabeledContent("Signed in as", value: scan.login + (scan.ranAsRoot ? " (with sudo)" : ""))
                    LabeledContent("Scanned") {
                        Text(scan.scannedAt, format: .relative(presentation: .named))
                    }
                }
                LabeledContent("Tailscale address", value: device.primaryAddress ?? "—")
            } header: {
                Text(device.shortName).font(.headline).textSelection(.enabled)
            }

            if let scan {
                let rows = app.inventoryRows.filter { $0.serverID == device.id }
                Section("Found") {
                    ForEach(InventoryRow.Kind.allCases, id: \.self) { kind in
                        let n = rows.filter { $0.kind == kind }.count
                        if n > 0 {
                            LabeledContent { Text("\(n)").monospacedDigit() } label: {
                                Label(kind.plural, systemImage: kind.systemImage)
                            }
                        }
                    }
                    let broken = rows.filter(\.hasMissingBackend).count
                    if broken > 0 {
                        LabeledContent {
                            Text("\(broken)").monospacedDigit().foregroundStyle(Tone.warning.color)
                        } label: {
                            Label("Broken websites", systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                let notes = InventoryBuilder.notes(for: scan)
                if !notes.isEmpty {
                    Section("Notes") {
                        ForEach(notes, id: \.self) { Text($0) }
                    }
                }
            }

            Section {
                switch state {
                case .waitingForApproval(let url):
                    Button("Open approval page") { app.services.openApproval(url) }
                case .scanning:
                    ProgressView().controlSize(.small)
                default:
                    if app.services.identityChanged(device.id) {
                        Button("Trust its new identity and scan again") {
                            app.services.forgetIdentity(of: device.addresses ?? [])
                            Task { await app.scanServices([device]) }
                        }
                        .disabled(app.services.isScanning)
                    } else {
                        Button("Scan this server") {
                            Task { await app.scanServices([device]) }
                        }
                        .disabled(!device.isOnline || app.services.isScanning)
                    }
                }
            } footer: {
                if app.services.identityChanged(device.id) {
                    Text("Only do this if you know the server was rebuilt or its SSH keys were renewed.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .scanning(let login): Text("Signing in as \(login)…")
        case .waitingForApproval: StatusPill(text: "Needs approval", tone: .warning)
        case .failed(let message): Text(message).foregroundStyle(Tone.critical.color).textSelection(.enabled)
        case .done: Text("Scanned")
        case .idle:
            if !device.isOnline { Text("Offline") } else if scan != nil { Text("Scanned") } else { Text("Not scanned yet") }
        }
    }
}

// MARK: - Settings

private struct ScanSettings: View {
    let app: AppState
    @State private var showScript = false

    var body: some View {
        @Bindable var services = app.services
        Form {
            Section {
                Toggle("Check servers automatically every 30 minutes", isOn: $services.autoCheck)
            } footer: {
                Text("Keeps RAM, disk space and problems on Home current. Read-only, and it never opens approval pages on its own.")
            }
            Section {
                TextField("Sign-in names to try", text: $services.loginNames, prompt: Text("operator, admin"))
            } footer: {
                Text("Tried in order on each server; the one that works is remembered.")
            }
            Section {
                DisclosureGroup("What the scan runs on each server", isExpanded: $showScript) {
                    ScrollView {
                        Text(ServiceScanScript.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 260)
                }
            } footer: {
                Text("Scans the \(app.serviceScanTargets.count) Linux machines your access rules let you sign in to with Tailscale SSH. Offline ones are skipped.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
#endif
