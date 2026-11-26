import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Show / group

/// What the People page shows. Every stat tile sets exactly one of these;
/// the Filters menu offers the same list.
private enum PeopleShow: String, CaseIterable, Identifiable {
    case everyone = "Everyone"
    case members = "People"
    case connected = "Connected now"
    case paused = "Paused"
    case needsApproval = "Needs approval"
    case sharedIn = "Shared in"
    case invites = "Pending invites"

    var id: String { rawValue }

    func matches(_ row: PeopleRow) -> Bool {
        guard let user = row.user else { return self == .everyone || self == .invites }
        switch self {
        case .everyone: return true
        case .members: return !user.isExternal
        case .connected: return !user.isExternal && user.currentlyConnected == true
        case .paused: return !user.isExternal && user.isSuspended
        case .needsApproval: return !user.isExternal && user.needsApproval
        case .sharedIn: return user.isExternal
        case .invites: return false
        }
    }

    /// A filter asked for from elsewhere (sidebar alert, Home), including
    /// older names.
    static func resolve(_ raw: String) -> PeopleShow? {
        if let direct = PeopleShow(rawValue: raw) { return direct }
        switch raw {
        case "Members": return .members
        case "Suspended": return .paused
        case "External": return .sharedIn
        case "Invites", "Open invites": return .invites
        default: return nil
        }
    }
}

private enum PeopleGrouping: String, CaseIterable, Identifiable {
    case role = "Role"
    case status = "Status"
    case team = "Team"
    case none = "None"

    var id: String { rawValue }
}

// MARK: - Rows

/// An unusual state of a person, shown as a pill (never a normal value).
struct PersonState: Hashable {
    let text: String
    let tone: Tone
}

extension TSUser {
    /// Unusual states, most serious first. Table rows show only the first.
    var unusualStates: [PersonState] {
        var out: [PersonState] = []
        if needsApproval { out.append(PersonState(text: "Needs approval", tone: .warning)) }
        if isSuspended { out.append(PersonState(text: "Paused", tone: .warning)) }
        if isExternal { out.append(PersonState(text: "Shared in", tone: .neutral)) }
        return out
    }
}

/// One person or pending invite with everything the page shows, worked out
/// once per data change so cells only read plain values.
private struct PeopleRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case person(TSUser)
        case invite(UserInvite)
    }

    let kind: Kind
    /// Team names, sorted.
    let teams: [String]
    /// nil for invites.
    let machines: Int?
    /// Machines they can reach; nil for invites or before the access rules load.
    let canReach: Int?

    static let roleOrder = ["Owner", "Admin", "IT admin", "Network admin", "Billing admin", "Auditor", "Member"]

    var id: String {
        switch kind {
        case .person(let user): return "u:\(user.id)"
        case .invite(let invite): return "i:\(invite.id)"
        }
    }

    var user: TSUser? {
        if case .person(let user) = kind { return user }
        return nil
    }

    var invite: UserInvite? {
        if case .invite(let invite) = kind { return invite }
        return nil
    }

    var name: String {
        if let user { return user.title }
        let email = invite?.email ?? ""
        return email.isEmpty ? "Link invite" : email
    }

    var email: String { user?.loginName ?? invite?.email ?? "" }
    var role: String { user?.roleLabel ?? invite?.roleLabel ?? "" }
    var teamsText: String { teams.isEmpty ? "—" : teams.joined(separator: ", ") }
    var connected: Bool { user?.currentlyConnected == true }

    /// Pills for the inspector.
    var states: [PersonState] {
        if let user { return user.unusualStates }
        return [PersonState(text: "Invited", tone: .neutral)]
    }

    /// The one pill a table row shows (invites have the envelope instead).
    var pill: PersonState? { user?.unusualStates.first }

    var statusGroup: String {
        guard let user else { return "Invited" }
        if user.isExternal { return "Shared in" }
        if user.needsApproval { return "Needs approval" }
        if user.isSuspended { return "Paused" }
        return "Active"
    }

    // Sort keys.
    var roleRank: Int { Self.roleOrder.firstIndex(of: role) ?? Self.roleOrder.count }
    var machinesSort: Int { machines ?? -1 }
    var canReachSort: Int { canReach ?? -1 }
    var lastSeenSort: Double {
        guard let user else { return -1 }
        if user.currentlyConnected == true { return .greatestFiniteMagnitude }
        return user.lastSeenDate?.timeIntervalSince1970 ?? 0
    }
}

/// A group header or a row in the table.
private struct PeopleNode: Identifiable, Hashable {
    let id: String
    var row: PeopleRow?
    var title = ""
    var children: [PeopleNode] = []
    /// Group total for the Machines column.
    var machinesTotal = 0

    var name: String { row?.name ?? title }
    var email: String { row?.email ?? "" }
    var roleRank: Int { row?.roleRank ?? -1 }
    var teamsText: String { row?.teamsText ?? "" }
    var machinesSort: Int { row?.machinesSort ?? machinesTotal }
    var canReachSort: Int { row?.canReachSort ?? -2 }
    var lastSeenSort: Double { row?.lastSeenSort ?? -2 }
}

/// One thing that can be done to a row. The inspector and the right-click
/// menu list the same items in the same order.
private struct PeopleAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var destructive = false
    var disabled = false
    let run: () -> Void
}

private struct PeopleActionButtons: View {
    let items: [PeopleAction]

    var body: some View {
        ForEach(items) { item in
            Button(role: item.destructive ? .destructive : nil, action: item.run) {
                Label(item.title, systemImage: item.systemImage)
            }
            .disabled(item.disabled)
        }
    }
}

// MARK: - People page

struct UsersView: View {
    @Environment(AppState.self) private var app

    @State private var searchText = ""
    @State private var show = PeopleShow.everyone
    @State private var roleFilter: String?
    @State private var teamFilter: String?
    @AppStorage("peopleGrouping") private var grouping: PeopleGrouping = .status
    @State private var sortOrder = [KeyPathComparator(\PeopleNode.name)]
    @State private var expansion = GroupExpansion()
    @State private var didAppear = false
    @State private var selection: PeopleNode.ID?
    /// The person whose page is pushed (double-click, "Open page").
    @State private var opened: String?
    @State private var showHistory = false
    /// Invite IDs on resend cooldown — the API allows 1 email per minute.
    @State private var resendCooldowns: [String: Date] = [:]

    private static let statusOrder = ["Needs approval", "Active", "Paused", "Shared in", "Invited"]
    private static let noTeam = "No team"

    var body: some View {
        let app = self.app
        let all = rows(app)
        let shown = visible(all)
        let groups = makeGroups(shown)
        let groupIDs = grouping == .none ? [] : groups.map(\.id)

        ListPageLayout(stats: tiles(all)) {
            FilterBar(groupings: PeopleGrouping.allCases, grouping: $grouping,
                      groupingTitle: { $0.rawValue },
                      activeFilters: activeFilterCount,
                      onClear: { clearFilters() },
                      expandAll: expandAll(groupIDs),
                      countText: peopleCountText(shown: shown, all: all)) {
                filterMenu(all)
            }
        } content: {
            content(all: all, shown: shown, groups: groups, app: app)
        }
        .navigationTitle("People")
        .searchable(text: $searchText, prompt: "Search people")
        .toolbar { toolbarItems(app) }
        .navigationDestination(item: $opened) { UserDetailView(userID: $0) }
        .navigationDestination(isPresented: $showHistory) { PeopleLogView() }
        .onAppear {
            consumeFilterRequest()
            if !didAppear {
                didAppear = true
                expansion.reset(groups: currentGroupIDs(), rows: visible(rows(app)).count)
            }
        }
        .onChange(of: app.usersFilterRequest) { consumeFilterRequest() }
        .onChange(of: grouping) {
            selection = nil
            expansion.reset(groups: currentGroupIDs(), rows: visible(rows(app)).count)
        }
        .onChange(of: narrowingKey) { expansion.openAll(currentGroupIDs()) }
        .onChange(of: groupIDs) { old, new in
            // Groups that appear later (data loaded, a new team) start open.
            guard shown.count <= 100 else { return }
            for id in new where !old.contains(id) { expansion.set(id, open: true) }
        }
        #if os(macOS)
        .inspector(isPresented: Binding(
            get: { node(selection, in: groups)?.row != nil },
            set: { if !$0 { selection = nil } }
        )) {
            Group {
                if let row = node(selection, in: groups)?.row {
                    PeopleInspector(app: app, row: row, actions: actions(for: row, app: app))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        #endif
    }

    // MARK: Content

    @ViewBuilder
    private func content(all: [PeopleRow], shown: [PeopleRow], groups: [PeopleNode], app: AppState) -> some View {
        if all.isEmpty {
            if app.hasLoadedOnce {
                ContentUnavailableView {
                    Label("No people yet", systemImage: "person.2")
                } description: {
                    Text("Use Add someone to invite the first person.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if shown.isEmpty {
            PageEmptyState.nothingMatches(clear: {
                clearFilters()
                searchText = ""
            })
        } else {
            #if os(macOS)
            table(groups, app: app)
            #else
            list(groups, app: app)
            #endif
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems(_ app: AppState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                app.peopleSheet = .addPerson
            } label: {
                Label("Add someone", systemImage: "person.badge.plus")
            }
            #if os(macOS)
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            #endif
            .help("Invite a person to your network")
        }
        ToolbarItem {
            Button {
                showHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            #if os(macOS)
            .labelStyle(.titleAndIcon)
            #endif
            .help("People history: everyone added, changed, paused or removed")
        }
    }

    // MARK: Rows, filters, groups

    /// Built once per data change (AppState.cached).
    private func rows(_ app: AppState) -> [PeopleRow] {
        app.cached("peoplePage.rows") {
            var teamsByLogin: [String: Set<String>] = [:]
            for (group, members) in app.policyModel?.groups ?? [:] {
                for member in members {
                    teamsByLogin[member.lowercased(), default: []].insert(teamDisplayName(group))
                }
            }
            var machinesByLogin: [String: Int] = [:]
            for device in app.devices {
                if let login = device.user { machinesByLogin[login.lowercased(), default: 0] += 1 }
            }
            let reach = app.accessAnalysis?.reachability
            let people = app.users.map { user in
                let login = user.loginName.lowercased()
                return PeopleRow(kind: .person(user),
                                 teams: (teamsByLogin[login] ?? []).sorted(),
                                 machines: user.deviceCount ?? machinesByLogin[login] ?? 0,
                                 canReach: reach.map { $0.reachableByPerson[user.loginName]?.count ?? 0 })
            }
            let invites = app.invites.map { invite in
                PeopleRow(kind: .invite(invite),
                          teams: (teamsByLogin[(invite.email ?? "").lowercased()] ?? []).sorted(),
                          machines: nil, canReach: nil)
            }
            return people + invites
        }
    }

    private func visible(_ all: [PeopleRow]) -> [PeopleRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return all.filter { row in
            show.matches(row)
                && (roleFilter == nil || row.role == roleFilter)
                && (teamFilter == nil || (teamFilter == Self.noTeam ? row.teams.isEmpty : row.teams.contains(teamFilter ?? "")))
                && (query.isEmpty || [row.name, row.email, row.role, row.teamsText]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var activeFilterCount: Int {
        (show != .everyone ? 1 : 0) + (roleFilter != nil ? 1 : 0) + (teamFilter != nil ? 1 : 0)
    }

    /// Changes when the list narrows or widens (groups then open).
    private var narrowingKey: String {
        [show.rawValue, roleFilter ?? "", teamFilter ?? "", searchText].joined(separator: "|")
    }

    private func clearFilters() {
        show = .everyone
        roleFilter = nil
        teamFilter = nil
    }

    private func makeGroups(_ rows: [PeopleRow]) -> [PeopleNode] {
        func items(_ rs: [PeopleRow], in key: String) -> [PeopleNode] {
            // Someone in two teams shows in both: ids stay unique per group.
            rs.map { PeopleNode(id: grouping == .none ? $0.id : "\(key)|\($0.id)", row: $0) }
                .sorted(using: sortOrder)
        }
        if grouping == .none {
            return [PeopleNode(id: "all", children: items(rows, in: ""))]
        }
        var buckets: [String: [PeopleRow]] = [:]
        for row in rows {
            let keys: [String]
            switch grouping {
            case .role: keys = [row.role]
            case .status: keys = [row.statusGroup]
            case .team: keys = row.teams.isEmpty ? [Self.noTeam] : row.teams
            case .none: keys = [""]
            }
            for key in keys { buckets[key, default: []].append(row) }
        }
        let order: [String]
        switch grouping {
        case .role:
            order = PeopleRow.roleOrder.filter { buckets[$0] != nil }
                + buckets.keys.filter { !PeopleRow.roleOrder.contains($0) }.sorted()
        case .status:
            order = Self.statusOrder.filter { buckets[$0] != nil }
        case .team, .none:
            order = buckets.keys.filter { $0 != Self.noTeam }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                + (buckets[Self.noTeam] != nil ? [Self.noTeam] : [])
        }
        return order.map { key in
            let rs = buckets[key] ?? []
            var node = PeopleNode(id: "g:\(key)", title: key, children: items(rs, in: key))
            node.machinesTotal = rs.compactMap(\.machines).reduce(0, +)
            return node
        }
    }

    private func currentGroupIDs() -> [String] {
        grouping == .none ? [] : makeGroups(visible(rows(app))).map(\.id)
    }

    private func node(_ id: PeopleNode.ID?, in groups: [PeopleNode]) -> PeopleNode? {
        guard let id else { return nil }
        for group in groups {
            if group.id == id { return group }
            if let child = group.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    private func expandAll(_ ids: [String]) -> (allExpanded: Bool, toggle: () -> Void)? {
        #if os(macOS)
        guard !ids.isEmpty else { return nil }
        return (allExpanded: expansion.allOpen(ids), toggle: { expansion.toggleAll(ids) })
        #else
        return nil
        #endif
    }

    /// "10 people · 1 invite", "2 of 10 people", "1 invite".
    private func peopleCountText(shown: [PeopleRow], all: [PeopleRow]) -> String {
        let people = shown.filter { $0.user != nil }.count
        let total = all.filter { $0.user != nil }.count
        let invites = shown.count - people
        var parts: [String] = []
        if people > 0 || invites == 0 {
            parts.append(countText(people, of: total, noun: total == 1 ? "person" : "people"))
        }
        if invites > 0 { parts.append(invites == 1 ? "1 invite" : "\(invites) invites") }
        return parts.joined(separator: " · ")
    }

    // MARK: Stats & filters

    private func tiles(_ all: [PeopleRow]) -> [StatTile] {
        var out = [
            tile(.members, all, "person.2"),
            tile(.connected, all, "dot.radiowaves.left.and.right"),
            tile(.paused, all, "pause.circle", tone: .warning),
            tile(.needsApproval, all, "person.badge.clock", tone: .warning),
            tile(.sharedIn, all, "person.2.circle"),
        ]
        if app.invitesAvailable { out.append(tile(.invites, all, "envelope")) }
        return out
    }

    private func tile(_ target: PeopleShow, _ all: [PeopleRow], _ systemImage: String,
                      tone: Tone = .neutral) -> StatTile {
        let active = show == target
        return StatTile(target.rawValue, count: all.filter(target.matches).count,
                        systemImage: systemImage, tone: tone, active: active) {
            clearFilters()
            if !active { show = target }
        }
    }

    @ViewBuilder
    private func filterMenu(_ all: [PeopleRow]) -> some View {
        let roles = PeopleRow.roleOrder.filter { role in all.contains { $0.role == role } }
            + Set(all.map(\.role)).subtracting(PeopleRow.roleOrder).sorted()
        let teams = Set(all.flatMap(\.teams)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        Picker("Show", selection: $show) {
            ForEach(PeopleShow.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Role", selection: $roleFilter) {
            Text("Any role").tag(String?.none)
            Divider()
            ForEach(roles, id: \.self) { Text($0).tag(Optional($0)) }
        }
        Picker("Team", selection: $teamFilter) {
            Text("Any team").tag(String?.none)
            Divider()
            ForEach(teams, id: \.self) { Text($0).tag(Optional($0)) }
            Text(Self.noTeam).tag(Optional(Self.noTeam))
        }
    }

    /// "Needs approval" from the sidebar alert, or another page's link.
    private func consumeFilterRequest() {
        guard let request = app.usersFilterRequest else { return }
        if let requested = PeopleShow.resolve(request) {
            clearFilters()
            show = requested
            searchText = ""
        }
        app.usersFilterRequest = nil
    }

    // MARK: Actions

    private func actions(for row: PeopleRow, app: AppState) -> [PeopleAction] {
        switch row.kind {
        case .person(let user):
            var out: [PeopleAction] = []
            if user.needsApproval {
                out.append(PeopleAction(id: "approve", title: "Approve…", systemImage: "checkmark.circle") {
                    app.proposeApprove(user)
                })
            }
            out.append(PeopleAction(id: "manage", title: "Change or remove…", systemImage: "person.crop.circle") {
                app.peopleSheet = .manage(userID: user.id)
            })
            out.append(PeopleAction(id: "open", title: "Open page", systemImage: "arrow.right.circle") {
                opened = user.id
            })
            return out
        case .invite(let invite):
            var out: [PeopleAction] = []
            if let url = invite.inviteUrl {
                out.append(PeopleAction(id: "copy", title: "Copy invite link", systemImage: "doc.on.doc") {
                    UsersClipboard.copy(url)
                })
            }
            if invite.hasEmail {
                out.append(PeopleAction(id: "resend", title: "Resend…", systemImage: "envelope.arrow.triangle.branch",
                                        disabled: isResendDisabled(invite)) {
                    resend(invite, app: app)
                })
            }
            out.append(PeopleAction(id: "revoke", title: "Revoke…", systemImage: "trash", destructive: true) {
                app.proposeRevokeInvite(invite)
            })
            return out
        }
    }

    private func isResendDisabled(_ invite: UserInvite) -> Bool {
        guard let until = resendCooldowns[invite.id] else { return false }
        return until > .now
    }

    private func resend(_ invite: UserInvite, app: AppState) {
        app.proposeResendInvite(invite)
        resendCooldowns[invite.id] = .now.addingTimeInterval(60)
        Task {
            try? await Task.sleep(for: .seconds(60))
            resendCooldowns.removeValue(forKey: invite.id)
        }
    }

    // MARK: Table (Mac)

    #if os(macOS)
    @ViewBuilder
    private func table(_ groups: [PeopleNode], app: AppState) -> some View {
        Table(of: PeopleNode.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \PeopleNode.name) { node in
                if let row = node.row {
                    PeopleNameCell(row: row)
                } else {
                    GroupHeaderLabel(title: node.title, count: node.children.count)
                }
            }
            .width(min: 150, ideal: 230)
            Group {
                TableColumn("Email", value: \PeopleNode.email) { node in
                    Text(node.email).foregroundStyle(.secondary).lineLimit(1).help(node.email)
                }
                .width(min: 90, ideal: 190)
                TableColumn("Role", value: \PeopleNode.roleRank) { node in
                    if let row = node.row { Text(row.role).foregroundStyle(.secondary).lineLimit(1) }
                }
                .width(min: 55, ideal: 85)
                TableColumn("Teams", value: \PeopleNode.teamsText) { node in
                    if let row = node.row {
                        Text(row.teamsText).foregroundStyle(.secondary).lineLimit(1).help(row.teamsText)
                    }
                }
                .width(min: 55, ideal: 130)
            }
            Group {
                TableColumn("Machines", value: \PeopleNode.machinesSort) { node in
                    if let machines = node.row?.machines ?? (node.row == nil ? node.machinesTotal : nil) {
                        Text("\(machines)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .width(min: 55, ideal: 70)
                TableColumn("Can reach", value: \PeopleNode.canReachSort) { node in
                    if let row = node.row, row.user != nil {
                        Text(row.canReach.map { "\($0)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                            .help(row.canReach.map { "Can reach \($0) machine\($0 == 1 ? "" : "s")" } ?? "Access rules not loaded")
                    }
                }
                .width(min: 60, ideal: 75)
                TableColumn("Last seen", value: \PeopleNode.lastSeenSort) { node in
                    if let row = node.row { PeopleLastSeen(row: row).foregroundStyle(.secondary).lineLimit(1) }
                }
                .width(min: 70, ideal: 115)
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
        .contextMenu(forSelectionType: PeopleNode.ID.self) { ids in
            if let id = ids.first, let row = node(id, in: groups)?.row {
                PeopleActionButtons(items: actions(for: row, app: app))
            }
        } primaryAction: { ids in
            guard let id = ids.first, let found = node(id, in: groups) else { return }
            if let user = found.row?.user {
                opened = user.id
            } else if found.row == nil {
                expansion.set(id, open: !expansion.isOpen(id))
            }
        }
    }
    #endif

    // MARK: List (iPhone, iPad)

    #if os(iOS)
    private func list(_ groups: [PeopleNode], app: AppState) -> some View {
        List {
            ForEach(groups) { group in
                if grouping == .none {
                    ForEach(group.children) { listRow($0, app: app) }
                } else {
                    Section {
                        ForEach(group.children) { listRow($0, app: app) }
                    } header: {
                        GroupHeaderLabel(title: group.title, count: group.children.count)
                    }
                }
            }
        }
        .refreshable { await app.refreshAll() }
    }

    @ViewBuilder
    private func listRow(_ node: PeopleNode, app: AppState) -> some View {
        if let row = node.row {
            let items = actions(for: row, app: app)
            Group {
                if let user = row.user {
                    NavigationLink {
                        UserDetailView(userID: user.id)
                    } label: {
                        PeopleListRow(row: row)
                    }
                } else {
                    PeopleListRow(row: row)
                }
            }
            .contextMenu { PeopleActionButtons(items: items) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                PeopleActionButtons(items: items.filter { $0.id != "open" })
            }
        }
    }
    #endif
}

// MARK: - Cells (plain values only)

private struct PeopleAvatar: View {
    let row: PeopleRow
    let size: CGFloat

    var body: some View {
        if let user = row.user {
            UserAvatar(user: user, size: size)
        } else {
            Image(systemName: "envelope")
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

private struct PeopleNameCell: View {
    let row: PeopleRow

    var body: some View {
        HStack(spacing: 7) {
            PeopleAvatar(row: row, size: 20)
            Text(row.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
                .help(row.email)
            if let pill = row.pill {
                StatusPill(text: pill.text, tone: pill.tone)
            }
        }
    }
}

/// "Connected now", "3 days ago", "Never", or when an invite was sent.
private struct PeopleLastSeen: View {
    let row: PeopleRow

    var body: some View {
        if let invite = row.invite {
            if let sent = invite.lastSentDate {
                Text("Invited \(sent, format: .relative(presentation: .named))")
            } else {
                Text("Invited")
            }
        } else if row.connected {
            HStack(spacing: 5) {
                StatusDot(isOnline: true)
                Text("Connected now")
            }
        } else if let seen = row.user?.lastSeenDate {
            Text(seen, format: .relative(presentation: .named))
        } else {
            Text("Never")
        }
    }
}

#if os(iOS)
private struct PeopleListRow: View {
    let row: PeopleRow

    var body: some View {
        HStack(spacing: 12) {
            PeopleAvatar(row: row, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if row.connected { StatusDot(isOnline: true) }
                    if let pill = row.pill { StatusPill(text: pill.text, tone: pill.tone) }
                }
                Group {
                    if row.user != nil {
                        Text(row.email)
                    } else {
                        PeopleLastSeen(row: row)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.role)
                if let machines = row.machines {
                    Text("\(machines) machine\(machines == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
#endif

// MARK: - Inspector

private struct PeopleInspector: View {
    let app: AppState
    let row: PeopleRow
    let actions: [PeopleAction]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    PeopleAvatar(row: row, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name)
                            .font(.headline)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        if !row.states.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(row.states, id: \.self) { StatusPill(text: $0.text, tone: $0.tone) }
                            }
                        }
                    }
                }
                PeopleActionButtons(items: actions)
            }

            Section {
                facts
            }

            if let user = row.user {
                reachSection(for: user)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var facts: some View {
        let teams = row.teams.isEmpty ? "None" : row.teams.joined(separator: ", ")
        if let user = row.user {
            LabeledContent("Email") { Text(user.loginName).textSelection(.enabled) }
            LabeledContent("Role", value: user.roleLabel)
            LabeledContent("Teams", value: teams)
            LabeledContent("Joined",
                           value: user.createdDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            LabeledContent("Last seen") { PeopleLastSeen(row: row) }
        } else if let invite = row.invite {
            LabeledContent("Email") { Text(invite.email ?? "—").textSelection(.enabled) }
            LabeledContent("Role", value: invite.roleLabel)
            LabeledContent("Teams", value: teams)
            LabeledContent("Sent") {
                if let sent = invite.lastSentDate {
                    Text(sent, format: .relative(presentation: .named))
                } else {
                    Text("Not sent")
                }
            }
        }
    }

    @ViewBuilder
    private func reachSection(for user: TSUser) -> some View {
        let ids = app.reachableDeviceIDs(by: user)
        let machines = app.devices.filter { ids.contains($0.id) }
        Section {
            if app.accessAnalysis == nil {
                Text("Access rules not loaded").foregroundStyle(.secondary)
            } else if machines.isEmpty {
                Text("No machines").foregroundStyle(.secondary)
            } else {
                ForEach(machines) { device in
                    HStack(spacing: 8) {
                        StatusDot(isOnline: device.isOnline)
                        Text(device.shortName).lineLimit(1)
                    }
                }
            }
        } header: {
            Text(app.accessAnalysis == nil
                 ? "Can reach"
                 : "Can reach \(machines.count) machine\(machines.count == 1 ? "" : "s")")
        }
    }
}

// MARK: - Clipboard

private enum UsersClipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
