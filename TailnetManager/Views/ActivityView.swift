#if os(macOS)
import SwiftUI

enum ActivityGrouping: String, CaseIterable, Identifiable {
    case none = "None"
    case who = "Person"
    case target = "Server"
    case action = "Action"
    case day = "Day"
    var id: String { rawValue }

    /// Group by menu order: None last (but the default).
    static let menuOrder: [ActivityGrouping] = [.who, .target, .action, .day, .none]
}

/// The "Show" filter; each stat tile sets one of these.
enum ActivityShow: String, CaseIterable, Identifiable {
    case everything = "Everything"
    case serverLogins = "Server logins"
    case shells = "Shell sessions"
    case tailscale = "Sign-ins & settings changes"
    case signIns = "Sign-ins"
    case changes = "Settings changes"
    var id: String { rawValue }

    func matches(_ e: ActivityEvent) -> Bool {
        switch self {
        case .everything: return true
        case .serverLogins: return e.source == .serverLogin
        case .shells: return e.source == .serverLogin && e.isShell
        case .tailscale: return e.source == .tailscale
        case .signIns: return e.source == .tailscale && e.action == "Signed in"
        case .changes: return e.source == .tailscale && e.action != "Signed in"
        }
    }
}

struct ActivityFilter: Equatable {
    var show: ActivityShow = .everything
    var who: String?
    var target: String?
    var action: String?

    /// How many filters are on.
    var count: Int { [show != .everything, who != nil, target != nil, action != nil].filter { $0 }.count }
    var isActive: Bool { count > 0 }

    func matches(_ e: ActivityEvent) -> Bool {
        show.matches(e)
            && (who == nil || e.who == who)
            && (target == nil || e.target == target)
            && (action == nil || e.action == action)
    }
}

/// A group header or an event.
struct ActivityNode: Identifiable, Hashable {
    let id: String
    var event: ActivityEvent?
    var title = ""
    var children: [ActivityNode] = []
    /// Shell sessions in the group (its one pill).
    var shellSessions = 0
    /// Most recent event in the group.
    var latest: Double = 0

    var dateSort: Double { event?.date?.timeIntervalSince1970 ?? latest }
    var who: String { event?.who ?? title }
    var action: String { event?.action ?? "" }
    var target: String { event?.target ?? "" }
    var from: String { event?.from ?? "" }
    var detail: String { event?.detail ?? "" }

    var pill: (text: String, tone: Tone)? {
        shellSessions > 0 ? ("\(shellSessions) shell\(shellSessions == 1 ? "" : "s")", .warning) : nil
    }
}

/// Who did what, when: logins to servers (from each server's own Tailscale
/// log, read by the scan) and Tailscale's sign-in and change log.
struct ActivityView: View {
    @Environment(AppState.self) private var app

    @AppStorage("activityGroupBy") private var grouping: ActivityGrouping = .none
    @AppStorage("activityHideScans") private var hideScans = true
    @State private var filter = ActivityFilter()
    @State private var days = 7
    @State private var searchText = ""
    @State private var expansion = GroupExpansion()
    @State private var selection: ActivityNode.ID?
    @State private var sortOrder = [KeyPathComparator(\ActivityNode.dateSort, order: .reverse)]

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var narrowing: Bool { filter.isActive || !query.isEmpty }

    /// The period and "Hide this app's scans": what the tiles count.
    private func inScope(_ all: [ActivityEvent]) -> [ActivityEvent] {
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 86400)
        return all.filter { ($0.date ?? .distantPast) >= cutoff && !(hideScans && $0.isAppScan) }
    }

    private func visible(_ scope: [ActivityEvent]) -> [ActivityEvent] {
        let q = query
        return scope.filter { e in
            filter.matches(e)
                && (q.isEmpty || [e.who, e.action, e.target, e.from, e.detail].contains { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    private func makeRows(_ events: [ActivityEvent]) -> [ActivityNode] {
        events.map { ActivityNode(id: $0.id, event: $0) }.sorted(using: sortOrder)
    }

    private func makeGroups(_ events: [ActivityEvent]) -> [ActivityNode] {
        guard grouping != .none else { return [] }
        var buckets: [String: [ActivityEvent]] = [:]
        for e in events {
            let key: String
            switch grouping {
            case .none: key = ""
            case .who: key = e.who
            case .target: key = e.target
            case .action: key = e.action
            case .day: key = e.day
            }
            buckets[key, default: []].append(e)
        }
        let groups = buckets.map { key, items in
            ActivityNode(id: "g:\(key)", title: key,
                         children: items.map { ActivityNode(id: "\(key)|\($0.id)", event: $0) }.sorted(using: sortOrder),
                         shellSessions: items.filter(\.isShell).reduce(0) { $0 + $1.count },
                         latest: items.compactMap { $0.date?.timeIntervalSince1970 }.max() ?? 0)
        }
        // Days newest first; everything else by most recent activity.
        return groups.sorted { $0.dateSort > $1.dateSort }
    }

    var body: some View {
        // Computed once per render and passed down.
        let all = app.activityEvents
        let scope = inScope(all)
        let shown = visible(scope)
        let groups = makeGroups(shown)
        let rows = grouping == .none ? makeRows(shown) : []
        let groupIDs = groups.map(\.id)

        ListPageLayout(stats: tiles(scope)) {
            FilterBar(
                groupings: ActivityGrouping.menuOrder,
                grouping: $grouping,
                groupingTitle: { $0.rawValue },
                activeFilters: filter.count + (query.isEmpty ? 0 : 1),
                onClear: clearFilters,
                expandAll: grouping == .none ? nil : (expansion.allOpen(groupIDs), { expansion.toggleAll(groupIDs) }),
                countText: countText(shown.count, of: scope.count, noun: "events")
            ) {
                filterMenu(scope)
            }
        } content: {
            if shown.isEmpty {
                emptyState(all: all)
            } else {
                table(groups: groups, rows: rows)
            }
        }
        .navigationTitle("Activity")
        .searchable(text: $searchText, prompt: "Person, server, action")
        // Tailscale's log loads with the page and the period; the sidebar's
        // refresh (⌘R) reloads it too.
        .task(id: days) { await app.loadAuditLog(days: days) }
        .onChange(of: app.isLoading) { wasLoading, isLoading in
            if wasLoading && !isLoading { Task { await app.loadAuditLog(days: days) } }
        }
        .onAppear { syncExpansion(reset: true) }
        .onChange(of: grouping) { _, _ in
            selection = nil
            syncExpansion(reset: true)
        }
        .onChange(of: filter) { _, _ in syncExpansion(reset: true) }
        .onChange(of: days) { _, _ in syncExpansion(reset: true) }
        .onChange(of: hideScans) { _, _ in syncExpansion(reset: true) }
        // Narrowing opens every group so matches show at once; clearing the
        // search goes back to the default.
        .onChange(of: searchText) { _, _ in syncExpansion(reset: !narrowing) }
        // New groups (the log loaded, a scan finished) follow the same rule.
        .onChange(of: groupIDs) { _, _ in syncExpansion(reset: false) }
    }

    /// Groups start open for 100 rows or fewer; filters and search open
    /// every group except the ones the admin closed.
    private func syncExpansion(reset: Bool) {
        guard grouping != .none else { return }
        let shown = visible(inScope(app.activityEvents))
        let ids = makeGroups(shown).map(\.id)
        if reset { expansion.reset(groups: ids, rows: shown.count) }
        if narrowing || shown.count <= 100 { expansion.openAll(ids) }
    }

    private func clearFilters() {
        filter = ActivityFilter()
        searchText = ""
    }

    /// A tile sets the filters to exactly its subset; tapping it again clears.
    private func toggle(_ show: ActivityShow) {
        searchText = ""
        filter = filter == ActivityFilter(show: show) ? ActivityFilter() : ActivityFilter(show: show)
    }

    // MARK: Stats

    private func tiles(_ scope: [ActivityEvent]) -> [StatTile] {
        /// Server logins count sessions (a row can merge a burst of them).
        func sessions(_ show: ActivityShow) -> Int {
            scope.filter(show.matches).reduce(0) { $0 + $1.count }
        }
        func tile(_ label: String, _ show: ActivityShow, count: Int, _ image: String,
                  tone: Tone = .neutral, help: String) -> StatTile {
            let active = filter == ActivityFilter(show: show)
            return StatTile(label, count: count, systemImage: image, tone: tone, active: active,
                            help: active ? "Show everything" : help) { toggle(show) }
        }
        return [
            tile("Server logins", .serverLogins, count: sessions(.serverLogins), "server.rack",
                 help: "Show logins to your servers, from each server's own Tailscale log"),
            tile("Shell sessions", .shells, count: sessions(.shells), "terminal", tone: .warning,
                 help: "Show the interactive shells opened on your servers"),
            tile("Sign-ins", .signIns, count: scope.filter(ActivityShow.signIns.matches).count, "person.badge.key",
                 help: "Show sign-ins to Tailscale"),
            tile("Changes", .changes, count: scope.filter(ActivityShow.changes.matches).count, "slider.horizontal.3",
                 help: "Show settings changes in Tailscale"),
        ]
    }

    // MARK: Filters menu

    @ViewBuilder
    private func filterMenu(_ scope: [ActivityEvent]) -> some View {
        let people = Array(Set(scope.map(\.who))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let targets = Array(Set(scope.map(\.target))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let actions = Array(Set(scope.map(\.action))).sorted()
        Picker("Period", selection: $days) {
            Text("24 hours").tag(1)
            Text("7 days").tag(7)
            Text("30 days").tag(30)
            Text("90 days").tag(90)
        }
        Picker("Show", selection: $filter.show) {
            Text(ActivityShow.everything.rawValue).tag(ActivityShow.everything)
            Divider()
            Text(ActivityShow.serverLogins.rawValue).tag(ActivityShow.serverLogins)
            Text(ActivityShow.shells.rawValue).tag(ActivityShow.shells)
            Divider()
            Text(ActivityShow.tailscale.rawValue).tag(ActivityShow.tailscale)
            Text(ActivityShow.signIns.rawValue).tag(ActivityShow.signIns)
            Text(ActivityShow.changes.rawValue).tag(ActivityShow.changes)
        }
        Picker("Person", selection: $filter.who) {
            Text("Anyone").tag(String?.none)
            Divider()
            ForEach(people, id: \.self) { Text($0).tag(Optional($0)) }
        }
        Picker("Server", selection: $filter.target) {
            Text("Any").tag(String?.none)
            Divider()
            ForEach(targets, id: \.self) { Text($0).tag(Optional($0)) }
        }
        Picker("Action", selection: $filter.action) {
            Text("Any").tag(String?.none)
            Divider()
            ForEach(actions, id: \.self) { Text($0).tag(Optional($0)) }
        }
        Divider()
        Toggle("Hide this app's scans", isOn: $hideScans)
    }

    // MARK: Empty

    @ViewBuilder
    private func emptyState(all: [ActivityEvent]) -> some View {
        if narrowing {
            PageEmptyState.nothingMatches(clear: { clearFilters() })
        } else if all.isEmpty && app.auditLogLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if all.isEmpty && app.services.scans.isEmpty {
            PageEmptyState.notScanned(
                message: "Scan your servers to see who signs in to them.",
                actionTitle: "Scan servers",
                action: { Task { await app.scanServices() } })
        } else {
            ContentUnavailableView("No activity", systemImage: "clock.arrow.circlepath",
                                   description: Text("Nothing happened in this period."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Table

    private func table(groups: [ActivityNode], rows: [ActivityNode]) -> some View {
        Table(of: ActivityNode.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("When", value: \ActivityNode.dateSort) { node in
                if let e = node.event {
                    Text(e.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        .monospacedDigit()
                } else {
                    GroupHeaderLabel(title: node.title, count: node.children.count, pill: node.pill)
                        .help(node.title)
                }
            }
            .width(min: 140, ideal: 230)
            TableColumn("Who", value: \ActivityNode.who) { node in
                if let e = node.event { Text(e.who).fontWeight(.medium) }
            }
            .width(min: 100, ideal: 150)
            TableColumn("Did", value: \ActivityNode.action) { node in
                if let e = node.event {
                    Text(e.action).foregroundStyle(e.isShell ? Tone.warning.color : (e.isAppScan ? .secondary : .primary))
                }
            }
            .width(min: 100, ideal: 150)
            TableColumn("On", value: \ActivityNode.target) { node in
                if let e = node.event { Text(e.target).help(e.target) }
            }
            .width(min: 100, ideal: 170)
            TableColumn("From", value: \ActivityNode.from) { node in
                if let e = node.event { Text(e.from).foregroundStyle(.secondary).help(e.from) }
            }
            .width(min: 90, ideal: 170)
            TableColumn("Details", value: \ActivityNode.detail) { node in
                if let e = node.event { Text(e.detail).foregroundStyle(.secondary).help(e.detail) }
            }
        } rows: {
            if grouping == .none {
                ForEach(rows) { TableRow($0) }
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
    }
}
#endif
