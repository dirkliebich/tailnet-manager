import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Filter

/// The raw values are what deep links send ("Update available",
/// "Needs approval", …): keep them. `label` is what the admin reads.
enum DevicesFilter: String, CaseIterable, Identifiable {
    case all = "All machines"
    case online = "Online"
    case offline = "Offline"
    case needsApproval = "Needs approval"
    case updateAvailable = "Update available"
    case expiringKeys = "Expiring keys"
    case hasAccessGroup = "Has access group"
    case personal = "Personal (untagged)"
    case external = "External"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All machines"
        case .online: return "Online"
        case .offline: return "Offline"
        case .needsApproval: return "Needs approval"
        case .updateAvailable: return "Updates"
        case .expiringKeys: return "Expiring keys"
        case .hasAccessGroup: return "Has access group"
        case .personal: return "Personal"
        case .external: return "Shared in"
        }
    }

    func matches(_ device: Device) -> Bool {
        switch self {
        case .all: return true
        case .online: return device.isOnline
        case .offline: return !device.isOnline
        case .needsApproval: return device.needsApproval
        case .updateAvailable: return device.updateAvailable == true
        case .expiringKeys: return device.keyExpiresSoon || device.keyExpired
        case .hasAccessGroup: return device.isTagged
        case .personal: return !device.isTagged && device.isExternal != true
        case .external: return device.isExternal == true
        }
    }

    /// Resolves a filter from a stored request or preset string. Accepts the
    /// new rawValues plus the legacy short names used by dashboard tiles and
    /// deep links ("Online", "Approval", "Expiring", "Tagged", "All").
    static func resolve(_ raw: String?) -> DevicesFilter? {
        guard let raw, !raw.isEmpty else { return nil }
        if let direct = DevicesFilter(rawValue: raw) { return direct }
        switch raw {
        case "All": return .all
        case "Online": return .online
        case "Approval": return .needsApproval
        case "Expiring": return .expiringKeys
        case "Tagged": return .hasAccessGroup
        default: return nil
        }
    }
}

// MARK: - Group by (shared by the Mac table and the iPhone list)

/// "None" is last, never first.
enum MachineGrouping: String, CaseIterable, Identifiable {
    case owner = "Owner"
    case system = "System"
    case accessGroup = "Access group"
    case status = "Status"
    case none = "None"

    var id: String { rawValue }

    static let noAccessGroup = "No access group"

    static func status(of d: Device) -> String {
        if d.needsApproval { return "Needs approval" }
        return d.isOnline ? "Online" : "Offline"
    }

    /// Access groups without the "tag:" prefix.
    static func accessGroups(of d: Device) -> [String] {
        (d.tags ?? []).map { $0.replacingOccurrences(of: "tag:", with: "") }
    }

    /// The groups a machine falls in (several for access groups).
    func keys(_ d: Device, owner: String, accessGroups: [String]) -> [String] {
        switch self {
        case .none: return [""]
        case .owner: return [owner]
        case .system: return [d.prettyOS]
        case .status: return [Self.status(of: d)]
        case .accessGroup: return accessGroups.isEmpty ? [Self.noAccessGroup] : accessGroups
        }
    }

    /// Owners: servers first, people A–Z, then unassigned and shared-in.
    /// Status: online, needs approval, offline. Otherwise A–Z.
    func ordered(_ keys: [String]) -> [String] {
        let present = Set(keys)
        let az = present.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        switch self {
        case .status:
            return ["Online", "Needs approval", "Offline"].filter(present.contains)
        case .owner:
            let first = [MachineOwner.servers], last = [MachineOwner.unassigned, MachineOwner.sharedIn]
            return first.filter(present.contains) + az.filter { !(first + last).contains($0) } + last.filter(present.contains)
        case .accessGroup:
            return az.filter { $0 != Self.noAccessGroup } + [Self.noAccessGroup].filter(present.contains)
        default:
            return az
        }
    }
}

/// Who a machine belongs to, as the Machines page names it.
enum MachineOwner {
    static let servers = "Servers"
    static let sharedIn = "Shared in"
    static let unassigned = "Unassigned"

    /// Login → display name; build once per list.
    static func names(_ users: [TSUser]) -> [String: String] {
        Dictionary(users.map { ($0.loginName, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    static func name(of d: Device, names: [String: String]) -> String {
        if d.isExternal == true { return sharedIn }
        if d.isTagged { return servers }
        guard let login = d.user, !login.isEmpty else { return unassigned }
        return names[login] ?? login
    }
}

/// A pill's text and color (see StatusPill).
struct MachinePill: Hashable {
    let text: String
    let tone: Tone
}

// MARK: - Clipboard

private enum DevicesClipboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

// MARK: - Devices list

struct DevicesView: View {
    @Environment(AppState.self) private var app
    @State private var filterSelection: String
    @State private var searchText = ""
    #if !os(macOS)
    @AppStorage("machinesGroupingPhone") private var grouping: MachineGrouping = .none
    #endif

    /// Pushed presentations (dashboard tiles) preset the filter directly;
    /// sidebar/tab navigation still uses AppState.devicesFilterRequest.
    init(initialFilter: String? = nil) {
        let resolved = DevicesFilter.resolve(initialFilter) ?? .all
        _filterSelection = State(initialValue: resolved.rawValue)
    }

    private var filter: DevicesFilter {
        DevicesFilter(rawValue: filterSelection) ?? .all
    }

    var body: some View {
        content
            .navigationTitle("Machines")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .searchable(text: $searchText, prompt: "Name, person, IP, or access group")
            .refreshable { await app.refreshAll() }
            .onAppear { consumeFilterRequest() }
            .onChange(of: app.devicesFilterRequest) { consumeFilterRequest() }
    }

    /// The Mac gets one sortable, groupable table with server stats; the
    /// iPhone keeps the list.
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        MachinesTable(showSelection: $filterSelection, searchText: $searchText)
        #else
        list
        #endif
    }

    #if !os(macOS)
    private var list: some View {
        // Worked out once per render.
        let owners = MachineOwner.names(app.users)
        let shown = app.devices.filter { filter.matches($0) && matchesSearch($0) }
        let grouped = grouping == .none ? [] : sections(shown, owners: owners)

        return ListPageLayout {
            FilterBar(groupings: MachineGrouping.allCases, grouping: $grouping,
                      groupingTitle: { $0.rawValue }, activeFilters: filter == .all ? 0 : 1,
                      onClear: clearFilters,
                      countText: countText(shown.count, of: app.devices.count, noun: "machines")) {
                Picker("Show", selection: $filterSelection) {
                    ForEach(DevicesFilter.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
        } content: {
            List {
                if grouping == .none {
                    ForEach(shown) { device in
                        DevicesRow(device: device, owner: MachineOwner.name(of: device, names: owners))
                    }
                } else {
                    ForEach(grouped, id: \.name) { section in
                        Section {
                            ForEach(section.items) { device in
                                DevicesRow(device: device, owner: MachineOwner.name(of: device, names: owners))
                            }
                        } header: {
                            GroupHeaderLabel(title: section.name, count: section.items.count)
                        }
                    }
                }
            }
            .overlay {
                if shown.isEmpty && app.hasLoadedOnce {
                    if app.devices.isEmpty {
                        EmptyStateView(systemImage: "laptopcomputer.slash", title: "No machines")
                    } else {
                        PageEmptyState.nothingMatches(clear: clearFilters)
                    }
                }
            }
        }
    }

    /// Buckets the shown machines for the current Group-by choice.
    private func sections(_ devices: [Device], owners: [String: String]) -> [(name: String, items: [Device])] {
        var buckets: [String: [Device]] = [:]
        for d in devices {
            let keys = grouping.keys(d, owner: MachineOwner.name(of: d, names: owners),
                                     accessGroups: MachineGrouping.accessGroups(of: d))
            for key in keys { buckets[key, default: []].append(d) }
        }
        return grouping.ordered(Array(buckets.keys)).map { (name: $0, items: buckets[$0] ?? []) }
    }

    /// Clear empties the search too.
    private func clearFilters() {
        filterSelection = DevicesFilter.all.rawValue
        searchText = ""
    }
    #endif

    /// Dashboard tiles navigate here with a requested filter — apply and clear it.
    private func consumeFilterRequest() {
        guard let request = app.devicesFilterRequest else { return }
        if let requested = DevicesFilter.resolve(request) {
            filterSelection = requested.rawValue
        }
        #if os(macOS)
        // Sidebar alerts ask for the stats-based views ("Disk 85% full or more").
        if MachineShow(rawValue: request) != nil { filterSelection = request }
        #endif
        app.devicesFilterRequest = nil
    }

    private func matchesSearch(_ device: Device) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        var haystack: [String] = [device.shortName, device.name]
        if let hostname = device.hostname { haystack.append(hostname) }
        if let user = device.user { haystack.append(user) }
        haystack.append(contentsOf: device.addresses ?? [])
        haystack.append(contentsOf: device.tags ?? [])
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Row (iPhone)

#if !os(macOS)
private struct DevicesRow: View {
    @Environment(AppState.self) private var app
    let device: Device
    let owner: String

    var body: some View {
        NavigationLink {
            DeviceDetailView(deviceID: device.id)
        } label: {
            rowContent
        }
        .contextMenu { menuItems }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            StatusDot(isOnline: device.isOnline)
            Image(systemName: device.systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.shortName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let pill {
                        StatusPill(text: pill.text, tone: pill.tone)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            DeviceActionsButton(device: device)
        }
        .padding(.vertical, 2)
    }

    /// One pill, the most serious; nothing for a normal machine.
    private var pill: MachinePill? {
        if device.keyExpired { return MachinePill(text: "Signed out", tone: .critical) }
        if device.needsApproval { return MachinePill(text: "Needs approval", tone: .warning) }
        if device.updateAvailable == true { return MachinePill(text: "Updates", tone: .info) }
        if device.isExternal == true { return MachinePill(text: "Shared in", tone: .neutral) }
        return nil
    }

    /// Owner (or access groups for servers) · system · last seen.
    private var subtitle: String {
        var parts: [String] = []
        if device.isTagged {
            parts.append(MachineGrouping.accessGroups(of: device).joined(separator: ", "))
        } else if device.isExternal != true, owner != MachineOwner.unassigned {
            parts.append(owner)
        }
        parts.append(device.prettyOS)
        parts.append(device.lastSeenDescription)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menuItems: some View {
        // External devices are read-only — only Copy IP applies.
        if device.needsApproval && device.isExternal != true {
            Button {
                app.propose(.approve, on: device)
            } label: {
                Label("Approve…", systemImage: "checkmark.circle")
            }
        }
        if let address = device.primaryAddress {
            Button {
                DevicesClipboard.copy(address)
            } label: {
                Label("Copy IP", systemImage: "doc.on.doc")
            }
        }
        if device.isExternal != true {
            Button(role: .destructive) {
                app.propose(.expireKey, on: device)
            } label: {
                Label("Expire key…", systemImage: "clock.badge.xmark")
            }
        }
        if device.canBeDeleted {
            Button(role: .destructive) {
                app.propose(.remove, on: device)
            } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
    }
}
#endif
