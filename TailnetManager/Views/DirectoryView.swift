#if os(macOS)
import SwiftUI

// MARK: - Modes, grouping, filters

enum DirectoryMode: String, CaseIterable, Identifiable {
    /// What each server serves, in plain words.
    case overview = "Overview"
    case servers = "Servers"
    case urls = "URLs"
    var id: String { rawValue }
}

enum DirectoryURLGrouping: String, CaseIterable, Identifiable {
    case domain = "Domain"
    case server = "Server"
    case reach = "Who can open it"
    case none = "None"
    var id: String { rawValue }
}

enum DirectoryReach: String, CaseIterable, Identifiable {
    case any = "Anyone"
    case publicOnly = "Public"
    case tailnet = "Tailnet only"
    var id: String { rawValue }

    func matches(_ row: InventoryRow) -> Bool {
        switch self {
        case .any: return true
        case .publicOnly: return row.reach >= .publicAddress
        case .tailnet: return row.reach < .publicAddress
        }
    }
}

/// Which environments to show (read from server names and access groups).
enum EnvironmentFilter: String, CaseIterable, Identifiable {
    case all = "All environments"
    case production = "Production"
    case notProduction = "Not production"
    case staging = "Staging"
    case development = "Development"
    case unknown = "Unknown"
    var id: String { rawValue }

    func matches(_ e: ServerEnvironment) -> Bool {
        switch self {
        case .all: return true
        case .production: return e == .production
        case .notProduction: return e != .production
        case .staging: return e == .staging
        case .development: return e == .development
        case .unknown: return e == .unknown
        }
    }
}

enum OverviewSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case leastUsed = "Least used first"
    var id: String { rawValue }
}

struct DirectoryFilter: Equatable {
    var server: String?
    var kind: InventoryRow.Kind?
    var reach: DirectoryReach = .any
    var brokenOnly = false
    /// Servers mode: only servers that serve at least one URL.
    var withURLsOnly = false

    var count: Int { [server != nil, kind != nil, reach != .any, brokenOnly, withURLsOnly].filter { $0 }.count }
    var isActive: Bool { count > 0 }
}

/// One line of the Directory table: a group (server, domain, reach) or an item.
struct DirectoryNode: Identifiable, Hashable {
    let id: String
    var row: InventoryRow?
    var title = ""
    var summary = ""
    var pillText: String?
    var pillTone: Tone = .neutral
    var deviceID: String?
    var scanning = false
    var children: [DirectoryNode] = []

    var pill: (text: String, tone: Tone)? { pillText.map { ($0, pillTone) } }

    // Sort keys (a group sorts by its title).
    var name: String { row.map { $0.url.isEmpty ? $0.name : $0.url } ?? title }
    var kindRank: Int { row?.kindRank ?? -1 }
    var server: String { row?.server ?? title }
    var address: String { row.map { $0.url.isEmpty ? $0.ports : $0.url } ?? "" }
    var via: String { row?.via ?? "" }
    var reachRank: Int { row?.reachRank ?? -1 }
    var detail: String { row.map { directoryWords($0.problem.isEmpty ? $0.detail : "\($0.problem) · \($0.detail)") } ?? summary }
    var brokenRank: Int { row?.hasMissingBackend == true ? 0 : 1 }
}

/// The page's word for a website with nothing behind it.
fileprivate func directoryWords(_ text: String) -> String {
    text.replacingOccurrences(of: InventoryBuilder.nothingListening, with: "nothing is running behind it")
}

// MARK: - Page

/// Every server, every URL they serve and everything running on them. The
/// Services page is the port-by-port view of the same scans.
struct DirectoryView: View {
    @Environment(AppState.self) private var app

    @AppStorage("directoryView") private var mode: DirectoryMode = .overview
    @AppStorage("directoryShowApps") private var showApps = true
    @AppStorage("directoryHideEmpty") private var hideEmpty = false
    @AppStorage("directoryEnvironment") private var environment: EnvironmentFilter = .all
    @AppStorage("directoryOverviewSort") private var overviewSort: OverviewSort = .name
    @State private var unusedOnly = false
    @AppStorage("directoryURLGrouping") private var urlGrouping: DirectoryURLGrouping = .domain
    @AppStorage("directoryHideRoutine") private var hideRoutine = true
    @State private var filter = DirectoryFilter()
    @State private var searchText = ""
    @State private var expansion = GroupExpansion()
    @State private var selection: DirectoryNode.ID?
    @State private var serverSort = [KeyPathComparator(\DirectoryNode.kindRank), KeyPathComparator(\DirectoryNode.name)]
    @State private var urlSort = [KeyPathComparator(\DirectoryNode.name)]

    private var narrowing: Bool { filter.isActive || !searchText.isEmpty }

    var body: some View {
        let all = app.inventoryRows
        let urls = app.directoryURLs
        let groups = mode == .servers ? serverGroups(all) : (mode == .urls ? urlGroups(urls) : [])
        let items = mode == .urls && urlGrouping == .none ? urlItems(urls) : []
        let groupIDs = groups.map(\.id)
        let selected = node(selection, in: items.isEmpty ? groups : items)

        ListPageLayout(stats: tiles(all: all, urls: urls)) {
            if mode == .overview {
                FilterBar(
                    groupings: [DirectoryURLGrouping.server], grouping: .constant(.server),
                    groupingTitle: { $0.rawValue },
                    activeFilters: (hideEmpty ? 1 : 0) + (environment != .all ? 1 : 0) + (unusedOnly ? 1 : 0)
                        + (searchText.isEmpty ? 0 : 1),
                    onClear: { hideEmpty = false; environment = .all; unusedOnly = false; searchText = "" },
                    countText: "\(app.directoryServers.count) servers · \(app.serverOverviews.reduce(0) { $0 + $1.served.count }) things served"
                ) {
                    Picker("Environment", selection: $environment) {
                        ForEach(EnvironmentFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Sort", selection: $overviewSort) {
                        ForEach(OverviewSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Toggle("Only servers that look unused", isOn: $unusedOnly)
                    Toggle("Hide servers that serve nothing", isOn: $hideEmpty)
                    Toggle("Show everything each server runs", isOn: $showApps)
                }
            } else {
            FilterBar(
                groupings: mode == .urls ? DirectoryURLGrouping.allCases : [DirectoryURLGrouping.server],
                grouping: mode == .urls ? $urlGrouping : .constant(.server),
                groupingTitle: { $0.rawValue },
                activeFilters: filter.count + (searchText.isEmpty ? 0 : 1),
                onClear: clearFilters,
                expandAll: items.isEmpty && !groups.isEmpty ? (expansion.allOpen(groupIDs), { expansion.toggleAll(groupIDs) }) : nil,
                countText: countLine(groups: groups, items: items, urls: urls)
            ) {
                filterMenu(all)
            }
            }
        } content: {
            if mode == .overview {
                if app.services.scans.isEmpty && !app.services.isScanning {
                    PageEmptyState.notScanned(
                        message: "Scan your servers to see what each one serves.",
                        actionTitle: "Scan servers",
                        action: { Task { await app.scanServices() } })
                } else {
                    DirectoryOverviewList(app: app, servers: app.serverOverviews, search: searchText,
                                          showApps: showApps, hideEmpty: hideEmpty,
                                          environment: environment, unusedOnly: unusedOnly, sort: overviewSort)
                }
            } else if app.services.scans.isEmpty && !app.services.isScanning && mode == .urls {
                PageEmptyState.notScanned(
                    message: "Scan your servers to list the addresses they serve.",
                    actionTitle: "Scan servers",
                    action: { Task { await app.scanServices() } })
            } else if groups.isEmpty && items.isEmpty {
                if app.services.isScanning && !narrowing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PageEmptyState.nothingMatches(clear: { clearFilters() })
                }
            } else if mode == .servers {
                serversTable(groups)
            } else {
                urlsTable(groups: groups, items: items)
            }
        }
        .navigationTitle("Directory")
        .searchable(text: $searchText, prompt: mode == .servers ? "Search server, URL, app, image" : "Search server, website, app")
        .inspector(isPresented: Binding(
            get: { selected?.row != nil || selected?.deviceID != nil },
            set: { if !$0 { selection = nil } }
        )) {
            Group {
                if let row = selected?.row {
                    DirectoryItemDetail(row: row, scannedAt: app.services.scans[row.serverID]?.scannedAt)
                } else if let id = selected?.deviceID, let device = app.devices.first(where: { $0.id == id }) {
                    DirectoryServerPanel(app: app, device: device)
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $mode) {
                    ForEach(DirectoryMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Overview: what each server serves, in plain words. Servers: everything on each server. URLs: every address your servers serve.")
            }
            ToolbarItem {
                Button {
                    let shownServers = mode != .urls
                        ? groups.compactMap { g in g.deviceID.flatMap { id in app.devices.first { $0.id == id } } }
                        : app.directoryServers
                    let shownRows = mode == .overview ? all : (groups.flatMap(\.children) + items).compactMap(\.row)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mode == .overview
                                                   ? app.overviewMarkdown(app.serverOverviews)
                                                   : app.directoryMarkdown(servers: shownServers, rows: shownRows),
                                                   forType: .string)
                } label: {
                    Label("Copy as Markdown", systemImage: "doc.on.doc")
                }
                .help("Copies what's shown (servers, their URLs and what runs on them) as a Markdown list.")
            }
            ToolbarItem {
                ScanServersMenu(app: app)
            }
        }
        .onAppear { syncExpansion(reset: true) }
        .onChange(of: mode) { _, _ in
            selection = nil
            filter = DirectoryFilter()
            syncExpansion(reset: true)
        }
        .onChange(of: urlGrouping) { _, _ in
            selection = nil
            syncExpansion(reset: true)
        }
        .onChange(of: filter) { _, _ in syncExpansion(reset: true) }
        .onChange(of: hideRoutine) { _, _ in syncExpansion(reset: true) }
        .onChange(of: searchText) { _, _ in syncExpansion(reset: !narrowing) }
        .onChange(of: groupIDs) { _, _ in syncExpansion(reset: false) }
    }

    // MARK: - Visible rows

    private func matchesSearch(_ row: InventoryRow) -> Bool {
        guard !searchText.isEmpty else { return true }
        return [row.name, row.url, row.server, row.via, directoryWords(row.detail), row.ports, row.kind.rawValue, row.reachLabel]
            .contains { $0.localizedCaseInsensitiveContains(searchText) }
            || row.routes.contains {
                directoryWords($0.text).localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
            }
    }

    private func visible(_ rows: [InventoryRow]) -> [InventoryRow] {
        rows.filter { row in
            (mode == .urls || !hideRoutine || !row.isRoutine)
                && (filter.server == nil || row.server == filter.server)
                && (filter.kind == nil || row.kind == filter.kind)
                && filter.reach.matches(row)
                && (!filter.brokenOnly || row.hasMissingBackend || !row.problem.isEmpty)
                && matchesSearch(row)
        }
    }

    private func syncExpansion(reset: Bool) {
        guard mode != .overview else { return }
        let rows = mode == .servers ? app.inventoryRows : app.directoryURLs
        let groups = mode == .servers ? serverGroups(rows) : urlGroups(rows)
        let ids = groups.map(\.id)
        let shown = groups.reduce(0) { $0 + $1.children.count }
        if reset { expansion.reset(groups: ids, rows: shown) }
        if narrowing || shown <= 100 { expansion.openAll(ids) }
    }

    private func clearFilters() {
        filter = DirectoryFilter()
        searchText = ""
    }

    private func node(_ id: DirectoryNode.ID?, in nodes: [DirectoryNode]) -> DirectoryNode? {
        guard let id else { return nil }
        for node in nodes {
            if node.id == id { return node }
            if let child = node.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    private func countLine(groups: [DirectoryNode], items: [DirectoryNode], urls: [InventoryRow]) -> String {
        if mode != .urls {
            let total = app.directoryServers.count
            var text = countText(groups.count, of: total, noun: "servers")
            if let checked = app.serversCheckedAt { text += " · checked \(MachineFormat.ago(checked))" }
            return text
        }
        let shown = items.isEmpty ? groups.reduce(0) { $0 + $1.children.count } : items.count
        return countText(shown, of: urls.count, noun: "URLs")
    }

    // MARK: - Stats

    private func tiles(all: [InventoryRow], urls: [InventoryRow]) -> [StatTile] {
        let servers = app.directoryServers
        let scanned = servers.filter { app.services.scans[$0.id] != nil }.count
        func show(_ m: DirectoryMode, _ f: DirectoryFilter) {
            searchText = ""
            mode = m
            filter = f
        }
        func isOn(_ m: DirectoryMode, _ f: DirectoryFilter) -> Bool { mode == m && filter == f }
        func toggle(_ m: DirectoryMode, _ f: DirectoryFilter) {
            if isOn(m, f) { show(m, DirectoryFilter()) } else { show(m, f) }
        }
        let publicURLs = DirectoryFilter(reach: .publicOnly)
        let tailnetURLs = DirectoryFilter(reach: .tailnet)
        let broken = DirectoryFilter(brokenOnly: true)
        return [
            StatTile("Servers", text: "\(scanned) of \(servers.count) scanned", systemImage: "server.rack",
                     active: isOn(.overview, DirectoryFilter()), help: "Show what every server serves") { show(.overview, DirectoryFilter()) },
            StatTile("URLs", count: urls.count, systemImage: "link",
                     active: isOn(.urls, DirectoryFilter()), help: "Show every address your servers serve") { show(.urls, DirectoryFilter()) },
            StatTile("Public", count: urls.filter { $0.reach >= .publicAddress }.count, systemImage: "globe",
                     active: isOn(.urls, publicURLs), help: "Show the URLs anyone on the internet can open") { toggle(.urls, publicURLs) },
            StatTile("Tailnet only", count: urls.filter { $0.reach < .publicAddress }.count, systemImage: "lock.shield",
                     active: isOn(.urls, tailnetURLs), help: "Show the URLs only machines on your tailnet can open") { toggle(.urls, tailnetURLs) },
            StatTile("Broken URLs", count: urls.filter(\.hasMissingBackend).count, systemImage: "exclamationmark.triangle",
                     tone: .warning, active: isOn(.urls, broken), help: "Show the URLs with nothing running behind them") { toggle(.urls, broken) },
            StatTile("Look unused", count: app.serverOverviews.filter { $0.usage?.looksUnused == true && environment.matches($0.environment) }.count,
                     systemImage: "moon.zzz", tone: .warning, active: mode == .overview && unusedOnly,
                     help: "Show the servers with no working websites, nobody signed in for 7 days and an idle CPU") {
                searchText = ""
                if mode == .overview && unusedOnly { unusedOnly = false } else { mode = .overview; unusedOnly = true }
            },
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
        if mode == .servers {
            Picker("Type", selection: $filter.kind) {
                Text("All types").tag(InventoryRow.Kind?.none)
                Divider()
                ForEach(InventoryRow.Kind.allCases, id: \.self) { kind in
                    Label(kind.plural, systemImage: kind.systemImage).tag(Optional(kind))
                }
            }
        }
        Picker("Who can open it", selection: $filter.reach) {
            ForEach(DirectoryReach.allCases) { Text($0.rawValue).tag($0) }
        }
        Divider()
        Toggle(mode == .urls ? "Only broken URLs" : "Only problems", isOn: $filter.brokenOnly)
        if mode == .servers {
            Toggle("Only servers with URLs", isOn: $filter.withURLsOnly)
            Toggle("Hide standard tools", isOn: $hideRoutine)
        }
    }

    // MARK: - Servers mode

    /// Every server (scanned or not), each with its URLs first, then what runs.
    private func serverGroups(_ all: [InventoryRow]) -> [DirectoryNode] {
        let rows = visible(all)
        let byServer = Dictionary(grouping: rows, by: \.serverID)
        let everything = Dictionary(grouping: all, by: \.serverID)
        return app.directoryServers.compactMap { device in
            let mine = byServer[device.id] ?? []
            if let name = filter.server, device.shortName != name { return nil }
            if !environment.matches(ServerEnvironment.of(device)) { return nil }
            if mine.isEmpty && narrowing && !(filter.withURLsOnly && filter.count == 1 && searchText.isEmpty) { return nil }
            let urls = (everything[device.id] ?? []).filter { $0.kind.isSite && !$0.url.isEmpty }
            if filter.withURLsOnly && urls.isEmpty { return nil }
            // URLs first, then the rest in kind order.
            let children = mine
                .map { DirectoryNode(id: $0.id, row: $0) }
                .sorted { a, b in
                    let ua = a.row?.url.isEmpty == false ? 0 : 1, ub = b.row?.url.isEmpty == false ? 0 : 1
                    if ua != ub { return ua < ub }
                    return a.kindRank != b.kindRank ? a.kindRank < b.kindRank
                        : a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            var group = DirectoryNode(id: "server:\(device.id)", title: device.shortName, deviceID: device.id,
                                      children: serverSort == [KeyPathComparator(\DirectoryNode.kindRank), KeyPathComparator(\DirectoryNode.name)]
                                        ? children : children.sorted(using: serverSort))
            let status = app.directoryStatus(of: device)
            if case .scanning = app.services.state(of: device.id) { group.scanning = true }
            var facts: [String] = []
            if let os = app.services.scans[device.id]?.osName, !os.isEmpty { facts.append(os) }
            facts.append(device.tailnetName)
            if let ip = device.primaryAddress { facts.append(ip) }
            if let s = app.services.scans[device.id]?.stats { facts.append(ServerInventory.statsLine(s)) }
            if !status.text.isEmpty {
                facts.append(status.text)
            } else {
                let all = everything[device.id] ?? []
                let appCount = all.filter { !$0.kind.isSite && !$0.isRoutine }.count
                facts.append("\(urls.count) URL\(urls.count == 1 ? "" : "s")")
                facts.append("\(appCount) app\(appCount == 1 ? "" : "s")")
            }
            group.summary = facts.joined(separator: " · ")
            let broken = (everything[device.id] ?? []).filter(\.hasMissingBackend).count
            if let pill = status.pill {
                group.pillText = pill
                group.pillTone = status.tone
            } else if broken > 0 {
                group.pillText = "\(broken) broken"
                group.pillTone = .warning
            }
            return group
        }
    }

    private func serversTable(_ groups: [DirectoryNode]) -> some View {
        Table(of: DirectoryNode.self, selection: $selection, sortOrder: $serverSort) {
            TableColumn("Name", value: \DirectoryNode.name) { node in
                if let row = node.row {
                    DirectoryNameCell(row: row, showURL: false)
                } else {
                    GroupHeaderLabel(title: node.title, count: node.children.count, pill: node.pill)
                        .help(node.title)
                }
            }
            .width(min: 160, ideal: 300)
            TableColumn("Type", value: \DirectoryNode.kindRank) { node in
                if let row = node.row { Text(row.kind.rawValue).foregroundStyle(.secondary) }
            }
            .width(min: 70, ideal: 105)
            TableColumn("Address", value: \DirectoryNode.address) { node in
                if let row = node.row { DirectoryAddressCell(row: row) }
            }
            .width(min: 60, ideal: 220)
            TableColumn("Who can reach it", value: \DirectoryNode.reachRank) { node in
                if let row = node.row, row.reach != .none { DirectoryReachLabel(row: row) }
            }
            .width(min: 80, ideal: 110)
            TableColumn("Details", value: \DirectoryNode.detail) { node in
                DirectoryDetailsCell(node: node)
            }
        } rows: {
            ForEach(groups) { group in
                DisclosureTableRow(group, isExpanded: Binding(
                    get: { expansion.isOpen(group.id) },
                    set: { expansion.set(group.id, open: $0) }
                )) {
                    ForEach(group.children) { TableRow($0) }
                }
            }
        }
        .contextMenu(forSelectionType: DirectoryNode.ID.self) { ids in
            contextMenu(ids, in: groups)
        } primaryAction: { ids in
            guard let id = ids.first, id.hasPrefix("server:") else { return }
            expansion.set(id, open: !expansion.isOpen(id))
        }
    }

    // MARK: - URLs mode

    private func urlItems(_ urls: [InventoryRow]) -> [DirectoryNode] {
        visible(urls).map { DirectoryNode(id: $0.id, row: $0) }.sorted(using: urlSort)
    }

    private func urlGroups(_ urls: [InventoryRow]) -> [DirectoryNode] {
        let rows = visible(urls)
        func group(_ id: String, _ title: String, _ mine: [InventoryRow]) -> DirectoryNode {
            var g = DirectoryNode(id: id, title: title, children: mine.map { DirectoryNode(id: $0.id, row: $0) }.sorted(using: urlSort))
            let servers = Set(mine.map(\.server)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            g.summary = servers.count <= 3 ? "on " + servers.joined(separator: ", ") : "on \(servers.count) servers"
            let broken = mine.filter(\.hasMissingBackend).count
            if broken > 0 { g.pillText = "\(broken) broken"; g.pillTone = .warning }
            return g
        }
        switch urlGrouping {
        case .none:
            return []
        case .domain:
            return Dictionary(grouping: rows) { AppState.domainGroup(of: $0.url) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { group("domain:\($0.key)", $0.key, $0.value) }
        case .server:
            return Dictionary(grouping: rows, by: \.server)
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { key, mine in
                    var g = group("urlserver:\(key)", key, mine)
                    g.summary = "\(mine.count) URL\(mine.count == 1 ? "" : "s")"
                    return g
                }
        case .reach:
            return [("Public", mine: rows.filter { $0.reach >= .publicAddress }),
                    ("Tailnet only", mine: rows.filter { $0.reach < .publicAddress })]
                .filter { !$0.mine.isEmpty }
                .map { group("reach:\($0.0)", $0.0, $0.mine) }
        }
    }

    private func urlsTable(groups: [DirectoryNode], items: [DirectoryNode]) -> some View {
        Table(of: DirectoryNode.self, selection: $selection, sortOrder: $urlSort) {
            TableColumn("URL", value: \DirectoryNode.name) { node in
                if let row = node.row {
                    DirectoryNameCell(row: row, showURL: true)
                } else {
                    GroupHeaderLabel(title: node.title, count: node.children.count, pill: node.pill)
                        .help(node.title)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Server", value: \DirectoryNode.server) { node in
                if let row = node.row { Text(row.server).foregroundStyle(.secondary) }
            }
            .width(min: 80, ideal: 130)
            TableColumn("Served by", value: \DirectoryNode.via) { node in
                if let row = node.row { Text(row.via).foregroundStyle(.secondary).lineLimit(1).help(row.via) }
            }
            .width(min: 70, ideal: 150)
            TableColumn("Who can open it", value: \DirectoryNode.reachRank) { node in
                if let row = node.row { DirectoryReachLabel(row: row) }
            }
            .width(min: 80, ideal: 105)
            TableColumn("Goes to", value: \DirectoryNode.detail) { node in
                DirectoryDetailsCell(node: node)
            }
        } rows: {
            if !items.isEmpty {
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
        .contextMenu(forSelectionType: DirectoryNode.ID.self) { ids in
            contextMenu(ids, in: items.isEmpty ? groups : items)
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            if let row = node(id, in: items.isEmpty ? groups : items)?.row, let url = URL(string: row.url) {
                NSWorkspace.shared.open(url)
            } else if groups.contains(where: { $0.id == id }) {
                expansion.set(id, open: !expansion.isOpen(id))
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(_ ids: Set<DirectoryNode.ID>, in nodes: [DirectoryNode]) -> some View {
        if let id = ids.first, let node = node(id, in: nodes) {
            if let row = node.row, let url = URL(string: row.url), !row.url.isEmpty {
                Button("Open \(url.host ?? row.url)") { NSWorkspace.shared.open(url) }
                Button("Copy URL") { copy(row.url) }
            }
            if let deviceID = node.deviceID, let device = app.devices.first(where: { $0.id == deviceID }), device.isOnline,
               let login = TailscaleSSH.logins(app, device).first {
                Button("SSH as \(login)") { TailscaleSSH.open(login, device) }
            }
            if let deviceID = node.deviceID, let device = app.devices.first(where: { $0.id == deviceID }),
               device.isOnline, app.serviceScanTargets.contains(where: { $0.id == deviceID }) {
                Button("Scan this server") { Task { await app.scanServices([device]) } }
                    .disabled(app.services.isScanning)
            }
            if node.row == nil, !node.children.isEmpty {
                let urls = node.children.compactMap(\.row).map(\.url).filter { !$0.isEmpty }
                if !urls.isEmpty {
                    Button("Copy \(urls.count) URL\(urls.count == 1 ? "" : "s")") { copy(urls.joined(separator: "\n")) }
                }
            }
            Button("Copy name") { copy(node.row?.name ?? node.title) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Overview

/// One card per server: what it serves (name, address, who can open it,
/// what's behind it), then everything else it runs by category.
private struct DirectoryOverviewList: View {
    let app: AppState
    let servers: [ServerOverview]
    let search: String
    let showApps: Bool
    let hideEmpty: Bool
    let environment: EnvironmentFilter
    let unusedOnly: Bool
    let sort: OverviewSort
    /// The card clicked last: it shows the SSH button.
    @State private var selected: String?

    private func matches(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(search) }

    /// Least used first: looks unused, then fewest working websites,
    /// sign-ins and CPU.
    private func lessUsed(_ a: ServerOverview, _ b: ServerOverview) -> Bool {
        func key(_ s: ServerOverview) -> (Int, Int, Int, Double) {
            let u = s.usage
            return (u?.looksUnused == true ? 0 : 1, u?.workingWebsites ?? 0, u?.signIns ?? 0, u?.cpuPercent ?? 0)
        }
        let ka = key(a), kb = key(b)
        if ka != kb { return ka < kb }
        return a.device.shortName.localizedStandardCompare(b.device.shortName) == .orderedAscending
    }

    /// Servers to show; with a search, a server whose name doesn't match
    /// keeps only the matching lines.
    private var shown: [ServerOverview] {
        let list: [ServerOverview] = servers.compactMap { s in
            guard s.scanned, environment.matches(s.environment) else { return nil }
            if unusedOnly && s.usage?.looksUnused != true { return nil }
            if hideEmpty && s.served.isEmpty { return nil }
            guard !search.isEmpty, !matches(s.device.shortName) else { return s }
            let served = s.served.filter { matches($0.title) || matches($0.address) || matches($0.behind) || matches($0.product) }
            let sections = s.sections.compactMap { section -> OverviewSection? in
                var kept = section
                kept.items = section.items.filter { matches($0.name) || matches($0.detail) || matches(section.kind.title) }
                return kept.items.isEmpty ? nil : kept
            }
            guard !served.isEmpty || !sections.isEmpty else { return nil }
            var narrowed = s
            narrowed.served = served
            narrowed.sections = sections
            return narrowed
        }
        return sort == .leastUsed ? list.sorted(by: lessUsed) : list
    }

    private var notScanned: [ServerOverview] {
        guard !unusedOnly else { return [] }
        return servers.filter { !$0.scanned && environment.matches($0.environment) && (search.isEmpty || matches($0.device.shortName)) }
    }

    var body: some View {
        let list = shown
        let others = notScanned
        if list.isEmpty && others.isEmpty {
            PageEmptyState.nothingMatches(clear: {})
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(list) { server in
                        ServerCard(app: app, server: server, showApps: showApps, isSelected: selected == server.id) {
                            selected = selected == server.id ? nil : server.id
                        }
                    }
                    if !others.isEmpty { NotScannedCard(servers: others) }
                }
                .padding(16)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }
}

private struct ServerCard: View {
    let app: AppState
    let server: ServerOverview
    let showApps: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text(server.device.shortName).font(.title3.weight(.semibold)).textSelection(.enabled)
                if !server.device.isOnline { StatusPill(text: "Offline", tone: .neutral) }
                if server.environment != .unknown {
                    StatusPill(text: server.environment.rawValue, tone: server.environment == .production ? .info : .neutral)
                        .help("From the server's name or access groups")
                }
                if let usage = server.usage, usage.looksUnused {
                    StatusPill(text: "Possibly unused", tone: .warning)
                        .help("Looks unused: " + usage.reasons.joined(separator: ", "))
                }
                let broken = server.served.filter(\.broken).count
                if broken > 0 { StatusPill(text: "\(broken) broken", tone: .warning) }
                Spacer()
                if isSelected { SSHButton(app: app, device: server.device) }
                TailnetAddress(device: server.device)
            }

            if !server.specs.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(server.specs).font(.headline)
                    Text([server.osName, server.stats?.cpuModel ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .textSelection(.enabled)
            }
            ServerStatsRow(stats: server.stats)

            if !server.usedFor.isEmpty {
                Text("Used for: ").fontWeight(.medium) + Text(server.usedFor).foregroundStyle(.secondary)
            }
            if let usage = server.usage {
                (Text("Usage: ").fontWeight(.medium) + Text(usage.line).foregroundStyle(.secondary))
                    .help("CPU is the 15-minute average across all cores. Sign-ins are Tailscale SSH logins in the last 7 days (this app's scans not counted).")
                if usage.looksUnused {
                    Text("Looks unused: " + usage.reasons.joined(separator: ", ") + ".")
                        .foregroundStyle(Tone.warning.color)
                }
            }

            if server.served.isEmpty {
                if !showApps || server.sections.isEmpty { Text("Serves no websites").foregroundStyle(.secondary) }
            } else {
                SectionHeader(title: "Websites", systemImage: "globe")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(server.served) { thing in
                        GridRow {
                            Image(systemName: thing.isPublic ? "globe" : "lock.fill")
                                .foregroundStyle(thing.isPublic ? Color.secondary : Tone.info.color)
                                .help(thing.isPublic ? "Anyone on the internet can open it" : "Only machines on your tailnet can open it")
                            Text(thing.title).fontWeight(.medium).lineLimit(1)
                            if let url = URL(string: thing.url) {
                                Link(thing.address, destination: url).lineLimit(1).help("Open \(thing.url)")
                            } else {
                                Text(thing.address)
                            }
                            HStack(spacing: 6) {
                                if thing.broken { StatusPill(text: "Broken", tone: .warning) }
                                Text(thing.product.isEmpty ? thing.behind : "\(thing.product) · \(thing.behind)")
                                    .foregroundStyle(thing.broken ? Tone.warning.color : .secondary)
                                    .lineLimit(1)
                                    .help(thing.behind)
                            }
                            .gridColumnAlignment(.leading)
                        }
                        .contextMenu {
                            Button("Copy URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(thing.url, forType: .string)
                            }
                        }
                    }
                }
            }

            if showApps {
                ForEach(server.sections) { section in
                    SectionHeader(title: section.kind.title, systemImage: section.kind.systemImage)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                        ForEach(section.items, id: \.self) { item in
                            GridRow {
                                Text(item.name)
                                    .fontWeight(.medium)
                                    .foregroundStyle(item.warning ? Tone.warning.color : .primary)
                                    .lineLimit(1)
                                    .help(item.name)
                                Text(item.detail)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .help(item.detail)
                                    .gridColumnAlignment(.leading)
                            }
                        }
                    }
                    .padding(.leading, 22)
                    .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: select)
        .contextMenu {
            ForEach(TailscaleSSH.logins(app, server.device), id: \.self) { login in
                Button("SSH as \(login)") { TailscaleSSH.open(login, server.device) }
            }
            .disabled(!server.device.isOnline)
        }
    }
}

/// "server.example.ts.net · 192.0.2.10" with a copy button.
private struct TailnetAddress: View {
    let device: Device

    var body: some View {
        HStack(spacing: 6) {
            Text(device.tailnetName)
                .font(.callout.monospaced())
            if let ip = device.primaryAddress {
                Text("· \(ip)").font(.callout.monospacedDigit())
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.tailnetName, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(device.tailnetName)")
        }
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(1)
    }
}

/// CPU, RAM and disk with bars, on every server card.
private struct ServerStatsRow: View {
    let stats: ServerStats?

    var body: some View {
        if let s = stats {
            HStack(spacing: 22) {
                if let perCore = s.loadPerCore {
                    stat("CPU", percent: perCore * 100, tint: MachineFormat.cpuTint(perCore: perCore),
                         text: ServerInventory.cpuText(s) ?? "")
                        .help("Load (1 / 5 / 15 min): " + [s.load1, s.load5, s.load15]
                            .map { $0.map { String(format: "%.2f", $0) } ?? "—" }.joined(separator: " / ")
                            + (s.cpuModel.isEmpty ? "" : "\n\(s.cpuModel)"))
                }
                if let p = s.memUsedPercent {
                    stat("RAM", percent: p, tint: MachineFormat.ramTint(p), text: ServerInventory.ramText(s) ?? "")
                }
                if let d = s.fullestDisk {
                    stat("Disk", percent: d.usedPercent, tint: MachineFormat.diskTint(d.usedPercent),
                         text: ServerInventory.diskText(s) ?? "")
                        .help(s.disks.filter { $0.sizeKB >= 1_048_576 }
                            .map { "\($0.mount): \(Int($0.usedPercent.rounded()))% used, \(MachineFormat.size(kb: $0.availableKB)) free of \(MachineFormat.size(kb: $0.sizeKB))" }
                            .joined(separator: "\n"))
                }
                if let up = s.uptimeSeconds {
                    Text("Up \(MachineFormat.uptime(up))").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        } else {
            Text("No CPU, RAM or disk figures yet — press Refresh.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, percent: Double, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(.medium)
            UsageBar(percent: percent, tint: tint, label: text)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct NotScannedCard: View {
    let servers: [ServerOverview]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not scanned (\(servers.count))").font(.headline)
            ForEach(servers) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(s.device.shortName).fontWeight(.medium)
                    Text(s.device.tailnetName).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(s.status).foregroundStyle(.secondary).lineLimit(2)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Cells (plain values only: table rows don't get the app's environment)

private struct DirectoryNameCell: View {
    let row: InventoryRow
    /// URLs mode: the URL itself is the name.
    let showURL: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(showURL ? row.url : row.name).lineLimit(1).help(showURL ? row.url : row.name)
            if row.hasMissingBackend {
                StatusPill(text: "Broken", tone: .warning).help("Nothing is running behind it")
            } else if !row.problem.isEmpty {
                StatusPill(text: "Not ready", tone: .warning).help(row.problem)
            }
        }
    }
}

private struct DirectoryAddressCell: View {
    let row: InventoryRow

    var body: some View {
        if !row.url.isEmpty, let url = URL(string: row.url) {
            Link(row.url, destination: url)
                .lineLimit(1)
                .help("Open \(row.url)")
        } else if !row.ports.isEmpty {
            Text("port\(row.ports.contains(",") ? "s" : "") \(row.ports)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(row.ports)
        }
    }
}

private struct DirectoryDetailsCell: View {
    let node: DirectoryNode

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

private struct DirectoryReachLabel: View {
    let row: InventoryRow

    var body: some View {
        let text = row.kind.isSite ? (row.reach >= .publicAddress ? "Public" : (row.reach == .tailscale ? "Tailnet only" : row.reach.label)) : row.reachLabel
        Text(text)
            .foregroundStyle(row.reach == .tailscale ? Tone.info.color : (row.reach >= .publicAddress ? .primary : .secondary))
            .help(DirectoryReachLabel.explanation(row.reach))
    }

    static func explanation(_ reach: ServiceReach) -> String {
        switch reach {
        case .allNetworks: return "Listens on every network address of the server, including its public one. A firewall in front of the server may still block it."
        case .publicAddress: return "Open to the internet (public address, Cloudflare Tunnel or Tailscale Funnel). A firewall may still block it."
        case .tailscale: return "Only machines on your tailnet can open it (as your access rules allow)."
        case .privateNetwork: return "Listens on a private address, such as the cloud provider's internal network or Docker's."
        case .local: return "Only programs on the server itself can reach it."
        case .none: return "Doesn't listen on any port of the server."
        }
    }
}

// MARK: - Item detail (inspector)

private struct DirectoryItemDetail: View {
    let row: InventoryRow
    let scannedAt: Date?

    var body: some View {
        Form {
            Section {
                if let url = URL(string: row.url), !row.url.isEmpty {
                    Link(destination: url) { Label("Open \(url.host ?? row.url)", systemImage: "safari") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.url, forType: .string)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Type") { Label(row.kind.rawValue, systemImage: row.kind.systemImage) }
                LabeledContent("Server", value: row.server)
                if !row.via.isEmpty { LabeledContent("Served by", value: row.via) }
                if !row.ports.isEmpty { LabeledContent("Ports", value: row.ports) }
                LabeledContent("Who can reach it") { DirectoryReachLabel(row: row) }
                if !row.problem.isEmpty {
                    LabeledContent("Status") { Text(row.problem).foregroundStyle(Tone.warning.color) }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(row.url.isEmpty ? row.name : row.url).font(.headline).textSelection(.enabled)
                    if row.hasMissingBackend { StatusPill(text: "Broken", tone: .warning) }
                }
            } footer: {
                Text(DirectoryReachLabel.explanation(row.reach))
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
                            Text(directoryWords(route.text))
                                .foregroundStyle(route.text.contains(InventoryBuilder.nothingListening)
                                                 ? Tone.warning.color : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else if !row.detail.isEmpty {
                Section("Details") {
                    Text(directoryWords(row.detail)).textSelection(.enabled)
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

private struct DirectoryServerPanel: View {
    let app: AppState
    let device: Device

    private var scan: ServerScan? { app.services.scans[device.id] }

    var body: some View {
        let rows = app.inventoryRows.filter { $0.serverID == device.id }
        let status = app.directoryStatus(of: device)
        Form {
            Section {
                LabeledContent("Status") {
                    if let pill = status.pill { StatusPill(text: pill, tone: status.tone) }
                    else { Text(device.isOnline ? "Online" : "Offline") }
                }
                if !status.text.isEmpty {
                    Text(status.text).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let scan, !scan.osName.isEmpty { LabeledContent("System", value: scan.osName) }
                else { LabeledContent("System", value: device.prettyOS) }
                LabeledContent("Tailscale address", value: device.primaryAddress ?? "—")
                LabeledContent("Name on the tailnet") { Text(device.name).textSelection(.enabled) }
                if let tags = device.tags, !tags.isEmpty {
                    LabeledContent("Access groups", value: tags.map { $0.replacingOccurrences(of: "tag:", with: "") }.joined(separator: ", "))
                }
                let ownIPs = (scan?.addresses ?? []).filter { ServiceReach.of(address: $0) == .publicAddress }
                if !ownIPs.isEmpty {
                    LabeledContent("Public addresses", value: ownIPs.joined(separator: ", "))
                }
                if let scan {
                    LabeledContent("Signed in as", value: scan.login + (scan.ranAsRoot ? " (with sudo)" : ""))
                    LabeledContent("Scanned") { Text(scan.scannedAt, format: .relative(presentation: .named)) }
                }
            } header: {
                Text(device.shortName).font(.headline).textSelection(.enabled)
            }

            let urls = rows.filter { $0.kind.isSite && !$0.url.isEmpty }
            if !urls.isEmpty {
                Section("URLs") {
                    ForEach(urls, id: \.id) { row in
                        if let url = URL(string: row.url) {
                            HStack {
                                Link(row.url, destination: url).lineLimit(1)
                                if row.hasMissingBackend { StatusPill(text: "Broken", tone: .warning) }
                            }
                            .help(directoryWords(row.detail))
                        }
                    }
                }
            }

            if scan != nil {
                Section("Runs") {
                    ForEach(InventoryRow.Kind.allCases, id: \.self) { kind in
                        let n = rows.filter { $0.kind == kind && !$0.isRoutine && !(kind.isSite && !$0.url.isEmpty) }.count
                        if n > 0 {
                            LabeledContent { Text("\(n)").monospacedDigit() } label: {
                                Label(kind.plural, systemImage: kind.systemImage)
                            }
                        }
                    }
                }
                let notes = scan.map { InventoryBuilder.notes(for: $0) } ?? []
                if !notes.isEmpty {
                    Section("Notes") { ForEach(notes, id: \.self) { Text($0) } }
                }
            }

            Section {
                SSHButton(app: app, device: device)
            }

            if app.serviceScanTargets.contains(where: { $0.id == device.id }) {
                Section {
                    if case .waitingForApproval(let url) = app.services.state(of: device.id) {
                        Button("Open approval page") { app.services.openApproval(url) }
                    } else {
                        Button("Scan this server") { Task { await app.scanServices([device]) } }
                            .disabled(!device.isOnline || app.services.isScanning)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
