import SwiftUI

/// Auth keys (revocable through the review sheet) and API access tokens
/// (read-only here), behind the one filter bar.
struct KeysView: View {
    @Environment(AppState.self) private var app

    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var grouping: KeysGrouping = .type
    @State private var statusFilter: KeysStatusFilter = .all
    @State private var typeFilter: KeysTypeFilter = .all
    @State private var expansion = GroupExpansion()

    var body: some View {
        Group {
            if !app.keysAvailable {
                EmptyStateView(systemImage: "key.slash",
                               title: "Keys unavailable",
                               message: "This sign-in can't read keys.")
            } else if app.authKeys.isEmpty && !app.hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                keysPage
            }
        }
        .navigationTitle("Keys")
        .toolbar {
            if app.keysAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("Create key", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Create a key that lets new machines join")
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            KeyCreateSheet()
        }
    }

    // MARK: - Page

    private var keysPage: some View {
        let all = app.authKeys
        let shown = keysShown(all)
        let groups = keysGroups(shown)
        let groupIDs = groups.map(\.name)
        var expandAll: (allExpanded: Bool, toggle: () -> Void)?
        if grouping != .none {
            expandAll = (allExpanded: expansion.allOpen(groupIDs),
                         toggle: { expansion.toggleAll(groupIDs) })
        }

        return ListPageLayout {
            FilterBar(groupings: KeysGrouping.allCases,
                      grouping: $grouping,
                      groupingTitle: { $0.title },
                      activeFilters: keysActiveFilters,
                      onClear: keysClearFilters,
                      expandAll: expandAll,
                      countText: countText(shown.count, of: all.count, noun: all.count == 1 ? "key" : "keys")) {
                Picker("Status", selection: $statusFilter) {
                    ForEach(KeysStatusFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Type", selection: $typeFilter) {
                    ForEach(KeysTypeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        } content: {
            if all.isEmpty {
                EmptyStateView(systemImage: "key", title: "No keys yet")
            } else if shown.isEmpty {
                PageEmptyState.nothingMatches(clear: {
                    keysClearFilters()
                    searchText = ""
                })
            } else {
                keysList(shown: shown, groups: groups)
            }
        }
        .searchable(text: $searchText, prompt: "Search keys")
        .onAppear { keysResetExpansion() }
        .onChange(of: grouping) { _, _ in keysResetExpansion() }
        .onChange(of: statusFilter) { _, _ in keysOpenMatches() }
        .onChange(of: typeFilter) { _, _ in keysOpenMatches() }
        .onChange(of: searchText) { _, _ in keysOpenMatches() }
        .onChange(of: groupIDs) { old, new in
            // Groups that show up after a refresh open like the others did.
            guard shown.count <= 100 else { return }
            if new.contains(where: { !old.contains($0) }) { expansion.openAll(new) }
        }
    }

    private func keysList(shown: [AuthKey], groups: [(name: String, items: [AuthKey])]) -> some View {
        List {
            if grouping == .none {
                Section {
                    ForEach(shown) { keysRow($0) }
                }
            } else {
                ForEach(groups, id: \.name) { group in
                    Section {
                        if expansion.isOpen(group.name) {
                            ForEach(group.items) { keysRow($0) }
                        }
                    } header: {
                        KeysGroupHeader(title: group.name,
                                        count: group.items.count,
                                        isOpen: expansion.isOpen(group.name)) {
                            expansion.set(group.name, open: !expansion.isOpen(group.name))
                        }
                    }
                }
            }

            Section {
                Link(destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!) {
                    Label("Key settings in the Tailscale console", systemImage: "arrow.up.forward.app")
                }
                .help("API tokens are revoked there.")
            }
        }
        .refreshable { await app.refreshAll() }
    }

    private func keysRow(_ key: AuthKey) -> some View {
        let revoke: (() -> Void)? = key.isAuthKey && key.isActive ? { app.proposeRevokeKey(key) } : nil
        return KeysRow(key: key, revoke: revoke)
            .contextMenu {
                if let revoke {
                    Button("Revoke…", role: .destructive, action: revoke)
                }
            }
    }

    // MARK: - Filtering & grouping

    private var keysActiveFilters: Int {
        (statusFilter == .all ? 0 : 1) + (typeFilter == .all ? 0 : 1)
    }

    private func keysClearFilters() {
        statusFilter = .all
        typeFilter = .all
    }

    private func keysMatchesSearch(_ key: AuthKey) -> Bool {
        guard !searchText.isEmpty else { return true }
        if let description = key.description,
           description.localizedCaseInsensitiveContains(searchText) {
            return true
        }
        return key.id.localizedCaseInsensitiveContains(searchText)
    }

    private func keysMatchesFilters(_ key: AuthKey) -> Bool {
        let statusOK: Bool
        switch statusFilter {
        case .all: statusOK = true
        case .active: statusOK = key.isActive && !key.expiresSoon
        case .expiresSoon: statusOK = key.expiresSoon
        case .ended: statusOK = !key.isActive
        }
        let typeOK: Bool
        switch typeFilter {
        case .all: typeOK = true
        case .authKeys: typeOK = !key.isAPIToken
        case .apiTokens: typeOK = key.isAPIToken
        }
        return statusOK && typeOK
    }

    /// Keys passing filters + search, newest first.
    private func keysShown(_ all: [AuthKey]) -> [AuthKey] {
        all.filter { keysMatchesFilters($0) && keysMatchesSearch($0) }
            .sorted { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
    }

    private func keysGroups(_ keys: [AuthKey]) -> [(name: String, items: [AuthKey])] {
        switch grouping {
        case .type:
            return groupItems(keys,
                              by: { $0.isAPIToken ? "API tokens" : "Auth keys" },
                              order: ["Auth keys", "API tokens"])
        case .status:
            return groupItems(keys,
                              by: { keysStatusGroup($0) },
                              order: ["Expires soon", "Active", "Expired or revoked"])
        case .none:
            return []
        }
    }

    private func keysStatusGroup(_ key: AuthKey) -> String {
        if key.expiresSoon { return "Expires soon" }
        if key.isActive { return "Active" }
        return "Expired or revoked"
    }

    private func keysCurrentGroupIDs() -> (ids: [String], rows: Int) {
        let shown = keysShown(app.authKeys)
        return (keysGroups(shown).map(\.name), shown.count)
    }

    private func keysResetExpansion() {
        let current = keysCurrentGroupIDs()
        expansion.reset(groups: current.ids, rows: current.rows)
    }

    private func keysOpenMatches() {
        expansion.openAll(keysCurrentGroupIDs().ids)
    }
}

// MARK: - Options

private enum KeysGrouping: String, CaseIterable, Hashable {
    case type, status, none

    var title: String {
        switch self {
        case .type: return "Type"
        case .status: return "Status"
        case .none: return "None"
        }
    }
}

private enum KeysStatusFilter: String, CaseIterable, Hashable {
    case all, active, expiresSoon, ended

    var title: String {
        switch self {
        case .all: return "Any status"
        case .active: return "Active"
        case .expiresSoon: return "Expires soon"
        case .ended: return "Expired or revoked"
        }
    }
}

private enum KeysTypeFilter: String, CaseIterable, Hashable {
    case all, authKeys, apiTokens

    var title: String {
        switch self {
        case .all: return "Any type"
        case .authKeys: return "Auth keys"
        case .apiTokens: return "API tokens"
        }
    }
}

// MARK: - Status

/// The one pill a key gets, or nil when it's simply active.
/// Expires soon is always orange; expired/invalid red; revoked gray.
private func keysStatusPill(_ key: AuthKey) -> (text: String, tone: Tone)? {
    if TSDate.parse(key.revoked) != nil { return ("Revoked", .neutral) }
    if key.invalid == true { return ("Invalid", .critical) }
    if let expires = key.expiresDate, expires <= .now { return ("Expired", .critical) }
    if key.expiresSoon { return ("Expires soon", .warning) }
    return nil
}

// MARK: - Group header

/// Group row for the keys list: chevron, name, gray count. Tapping it opens
/// or closes the group.
private struct KeysGroupHeader: View {
    let title: String
    let count: Int
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                GroupHeaderLabel(title: title, count: count)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .help(isOpen ? "Hide these" : "Show these")
    }
}

// MARK: - Row

/// One key or API token: name, at most one status pill, dates, access
/// groups as plain text. Active auth keys get "Revoke…". Never shows a
/// key's secret.
private struct KeysRow: View {
    let key: AuthKey
    let revoke: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title
                    if let pill = keysStatusPill(key) {
                        StatusPill(text: pill.text, tone: pill.tone)
                    }
                }
                Text(dateLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !accessGroups.isEmpty {
                    Text(accessGroups)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Access groups machines get when they join with this key")
                }
            }

            Spacer(minLength: 8)

            if let revoke {
                Button("Revoke…", role: .destructive, action: revoke)
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .help(key.isAPIToken ? "API token. One of these is the token this app signs in with; tokens are revoked in the Tailscale console." : "")
    }

    @ViewBuilder
    private var title: some View {
        if let description = key.description, !description.isEmpty {
            Text(description)
                .fontWeight(.medium)
                .lineLimit(1)
        } else {
            Text(key.id)
                .font(.body.monospaced())
                .fontWeight(.medium)
                .lineLimit(1)
        }
    }

    private var accessGroups: String {
        (key.tags ?? [])
            .map { $0.replacingOccurrences(of: "tag:", with: "") }
            .joined(separator: ", ")
    }

    private var dateLine: String {
        var parts: [String] = []
        if let created = key.createdDate {
            parts.append("Created \(TSDate.relative.localizedString(for: created, relativeTo: .now))")
        }
        if let revoked = TSDate.parse(key.revoked) {
            parts.append("Revoked \(TSDate.relative.localizedString(for: revoked, relativeTo: .now))")
        } else if let expires = key.expiresDate {
            let relative = TSDate.relative.localizedString(for: expires, relativeTo: .now)
            parts.append(expires > .now ? "Expires \(relative)" : "Expired \(relative)")
        } else {
            parts.append("No expiry")
        }
        return parts.joined(separator: " · ")
    }
}
