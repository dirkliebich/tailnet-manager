import SwiftUI

// MARK: - Problems (Access › Problems)

/// Group by for the Problems list; "None" last.
enum AccessProblemGrouping: String, CaseIterable, Identifiable {
    case severity = "Severity"
    case machine = "Machine"
    case none = "None"

    var id: String { rawValue }
}

/// A group header or one problem (a finding from the access analysis).
struct AccessProblemNode: Identifiable, Hashable {
    let id: String
    var finding: SecurityFinding?
    var title = ""
    var children: [AccessProblemNode] = []
    /// Group rows: the most serious problem inside.
    var worst: FindingSeverity = .info
    var machines = ""
    var fix = ""

    var name: String { finding?.title ?? title }
    /// Most serious first, then by name.
    var problemSort: String {
        let rank = FindingSeverity.critical.rawValue - (finding?.severity ?? worst).rawValue
        return "\(rank)|\(name.lowercased())"
    }
}

/// Every problem the access analysis found: severity tiles that filter, one
/// filter bar, a grouped table, and the selected problem in the inspector
/// (owned by AccessView). Quick fixes go through the global review flow;
/// problems caused by an access rule link to the console editor.
struct AccessProblemsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    let findings: [SecurityFinding]
    /// The selected problem's id (drives AccessView's inspector).
    @Binding var selection: String?

    @AppStorage("accessProblemsGrouping") private var grouping: AccessProblemGrouping = .severity
    @State private var severities: Set<FindingSeverity> = []
    @State private var needsRuleEdit = false
    @State private var searchText = ""
    @State private var expansion = GroupExpansion()
    @State private var rowSelection: AccessProblemNode.ID?
    @State private var sortOrder = [KeyPathComparator(\AccessProblemNode.problemSort)]

    private static let tileSeverities: [(FindingSeverity, String)] = [
        (.critical, "exclamationmark.octagon"),
        (.high, "exclamationmark.triangle"),
        (.medium, "exclamationmark.circle"),
        (.low, "info.circle"),
    ]

    var body: some View {
        let app = self.app
        let names = machineNames
        let shown = visible(names: names)
        let groups = makeGroups(shown, names: names)
        let groupIDs = groups.map(\.id)

        Group {
            if findings.isEmpty {
                PageEmptyState.allClear("Nothing risky found in your access rules or machines.")
            } else {
                ListPageLayout(stats: tiles) {
                    FilterBar(groupings: AccessProblemGrouping.allCases,
                              grouping: $grouping,
                              groupingTitle: \.rawValue,
                              activeFilters: (severities.isEmpty ? 0 : 1) + (needsRuleEdit ? 1 : 0),
                              onClear: clearFilters,
                              expandAll: grouping == .none
                                  ? nil
                                  : (allExpanded: expansion.allOpen(groupIDs), toggle: { expansion.toggleAll(groupIDs) }),
                              countText: countText(shown.count, of: findings.count,
                                                   noun: findings.count == 1 ? "problem" : "problems")) {
                        filterMenu
                    }
                } content: {
                    if shown.isEmpty {
                        PageEmptyState.nothingMatches(clear: clearFilters)
                    } else {
                        table(groups, app: app)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Problem or machine")
        .onAppear { resetExpansion() }
        .onChange(of: grouping) { _, _ in rowSelection = nil; resetExpansion() }
        .onChange(of: severities) { _, _ in resetExpansion() }
        .onChange(of: needsRuleEdit) { _, _ in resetExpansion() }
        .onChange(of: searchText) { _, _ in
            expansion.openAll(makeGroups(visible(names: machineNames), names: machineNames).map(\.id))
        }
        .onChange(of: rowSelection) { _, id in
            selection = node(id, in: makeGroups(visible(names: machineNames), names: machineNames))?.finding?.id
        }
        .onChange(of: selection) { _, id in
            if id == nil { rowSelection = nil }
        }
    }

    // MARK: Stats + filters

    private var tiles: [StatTile] {
        let counts = Dictionary(grouping: findings, by: \.severity).mapValues(\.count)
        return Self.tileSeverities.map { severity, symbol in
            StatTile(severity.label, count: counts[severity] ?? 0, systemImage: symbol,
                     tone: Tone(severity),
                     active: severities == [severity] && !needsRuleEdit) {
                showOnly(severity)
            }
        }
    }

    /// A tile sets the filters to exactly its severity; again clears them.
    private func showOnly(_ severity: FindingSeverity) {
        if severities == [severity] && !needsRuleEdit {
            severities = []
        } else {
            severities = [severity]
            needsRuleEdit = false
        }
    }

    @ViewBuilder
    private var filterMenu: some View {
        Section("Severity") {
            ForEach(FindingSeverity.allCases.sorted(by: >), id: \.self) { severity in
                Toggle(severity.label, isOn: Binding(
                    get: { severities.contains(severity) },
                    set: { on in
                        if on { severities.insert(severity) } else { severities.remove(severity) }
                    }))
            }
        }
        Section {
            Toggle("Needs an access-rule edit", isOn: $needsRuleEdit)
        }
    }

    private func clearFilters() {
        severities = []
        needsRuleEdit = false
        searchText = ""
    }

    // MARK: Rows

    private var machineNames: [String: String] {
        Dictionary(app.devices.map { ($0.id, $0.shortName) }, uniquingKeysWith: { first, _ in first })
    }

    private func visible(names: [String: String]) -> [SecurityFinding] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return findings.filter { finding in
            (severities.isEmpty || severities.contains(finding.severity))
                && (!needsRuleEdit || finding.requiresPolicyEdit)
                && (query.isEmpty
                    || finding.title.localizedCaseInsensitiveContains(query)
                    || finding.detail.localizedCaseInsensitiveContains(query)
                    || finding.deviceIDs.contains { names[$0]?.localizedCaseInsensitiveContains(query) == true })
        }
    }

    private func makeGroups(_ shown: [SecurityFinding], names: [String: String]) -> [AccessProblemNode] {
        func row(_ finding: SecurityFinding, in key: String) -> AccessProblemNode {
            AccessProblemNode(id: "\(key)|\(finding.id)", finding: finding,
                              machines: finding.deviceIDs.compactMap { names[$0] }.joined(separator: ", "),
                              fix: accessProblemFixText(finding))
        }

        switch grouping {
        case .none:
            return [AccessProblemNode(id: "all", children: shown.map { row($0, in: "all") }.sorted(using: sortOrder))]

        case .severity:
            let buckets = Dictionary(grouping: shown, by: \.severity)
            return buckets.keys.sorted(by: >).map { severity in
                let key = "s\(severity.rawValue)"
                return AccessProblemNode(id: "g:\(key)", title: severity.label,
                                         children: (buckets[severity] ?? []).map { row($0, in: key) }.sorted(using: sortOrder),
                                         worst: severity)
            }

        case .machine:
            // A problem on several machines shows under each of them.
            var buckets: [String: [SecurityFinding]] = [:]
            for finding in shown {
                let ids = finding.deviceIDs.filter { names[$0] != nil }
                if ids.isEmpty {
                    buckets["", default: []].append(finding)
                } else {
                    for id in ids { buckets[id, default: []].append(finding) }
                }
            }
            return buckets.map { deviceID, items in
                let key = "m\(deviceID)"
                return AccessProblemNode(id: "g:\(key)",
                                         title: deviceID.isEmpty ? "Whole tailnet" : (names[deviceID] ?? deviceID),
                                         children: items.map { row($0, in: key) }.sorted(using: sortOrder),
                                         worst: items.map(\.severity).max() ?? .info)
            }
            .sorted { ($0.worst, $1.title.lowercased()) > ($1.worst, $0.title.lowercased()) }
        }
    }

    private func node(_ id: AccessProblemNode.ID?, in groups: [AccessProblemNode]) -> AccessProblemNode? {
        guard let id else { return nil }
        for group in groups {
            if group.id == id { return group }
            if let child = group.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    private func resetExpansion() {
        let shown = visible(names: machineNames)
        expansion.reset(groups: makeGroups(shown, names: machineNames).map(\.id), rows: shown.count)
    }

    // MARK: Table

    private func table(_ groups: [AccessProblemNode], app: AppState) -> some View {
        // Plain values for the cells (table rows get no environment).
        let byMachine = grouping == .machine
        let flat = grouping == .none
        return Table(of: AccessProblemNode.self, selection: $rowSelection, sortOrder: $sortOrder) {
            TableColumn("Problem", value: \AccessProblemNode.problemSort) { node in
                if let finding = node.finding {
                    AccessProblemTitleCell(severity: finding.severity, title: finding.title)
                } else {
                    GroupHeaderLabel(title: node.title, count: node.children.count,
                                     pill: byMachine ? (node.worst.label, Tone(node.worst)) : nil)
                        .help(node.title)
                }
            }
            .width(min: 200, ideal: 380)
            TableColumn("Machines", value: \AccessProblemNode.machines) { node in
                if node.finding != nil {
                    Text(node.machines.isEmpty ? "—" : node.machines)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(node.machines)
                }
            }
            .width(min: 90, ideal: 200)
            TableColumn("Fix", value: \AccessProblemNode.fix) { node in
                if node.finding != nil {
                    Text(node.fix)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 70, ideal: 110)
        } rows: {
            if flat {
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
        .contextMenu(forSelectionType: AccessProblemNode.ID.self) { ids in
            if let id = ids.first, let finding = node(id, in: groups)?.finding {
                if let fix = accessProblemFix(for: finding, app: app, openURL: openURL) {
                    Button(fix.title, role: fix.destructive ? .destructive : nil, action: fix.run)
                }
                Button("Show details") { rowSelection = id }
            }
        }
    }
}

// MARK: - Cells

/// Severity pill + problem name (plain values: table rows get no environment).
private struct AccessProblemTitleCell: View {
    let severity: FindingSeverity
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            StatusPill(text: severity.label, tone: Tone(severity))
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(title)
    }
}

// MARK: - Fixes

/// Where a problem gets fixed, in plain words (the Fix column).
func accessProblemFixText(_ finding: SecurityFinding) -> String {
    if finding.requiresPolicyEdit { return "Access rules" }
    if finding.id.hasPrefix("exit:") || finding.id.hasPrefix("subnet:") || finding.id.hasPrefix("noexpiry:") {
        return "In the app"
    }
    if finding.id.hasPrefix("posture:") { return "Settings" }
    return "On the machine"
}

/// The one action for a problem — the same in the inspector and the
/// right-click menu. Quick fixes open the global review sheet; problems an
/// access rule causes open the console editor.
struct AccessProblemFix {
    let title: String
    let destructive: Bool
    let run: () -> Void
}

@MainActor
func accessProblemFix(for finding: SecurityFinding, app: AppState, openURL: OpenURLAction) -> AccessProblemFix? {
    let device = finding.deviceIDs.lazy.compactMap { app.device(id: $0) }.first
    if finding.requiresPolicyEdit {
        return AccessProblemFix(title: "Edit access rules", destructive: false) {
            openURL(URL(string: "https://login.tailscale.com/admin/acls")!)
        }
    }
    if finding.id.hasPrefix("exit:") || finding.id.hasPrefix("subnet:"), let device {
        return AccessProblemFix(title: "Turn off routes…", destructive: true) {
            app.propose(.disableRoutes, on: device)
        }
    }
    if finding.id.hasPrefix("noexpiry:"), let device {
        return AccessProblemFix(title: "Turn key expiry back on…", destructive: false) {
            app.propose(.reenableKeyExpiry, on: device)
        }
    }
    if finding.id.hasPrefix("posture:") {
        return AccessProblemFix(title: "Open Settings", destructive: false) {
            app.navigate(to: "settings")
        }
    }
    return nil
}

// MARK: - Inspector

/// The selected problem, shown by AccessView. Gets `app` passed in.
struct AccessProblemInspector: View {
    let app: AppState
    let finding: SecurityFinding

    @Environment(\.openURL) private var openURL

    var body: some View {
        let devices = finding.deviceIDs.compactMap { app.device(id: $0) }
        let fix = accessProblemFix(for: finding, app: app, openURL: openURL)

        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(finding.title)
                        .font(.headline)
                        .lineLimit(2)
                        .help(finding.title)
                    StatusPill(text: finding.severity.label, tone: Tone(finding.severity))
                }
                .padding(.vertical, 2)
                if let fix {
                    Button(fix.title, role: fix.destructive ? .destructive : nil, action: fix.run)
                        .buttonStyle(.borderedProminent)
                        .tint(fix.destructive ? Tone.critical.color : .accentColor)
                }
            }

            Section {
                LabeledContent("Fix", value: accessProblemFixText(finding))
                LabeledContent("Machines", value: devices.isEmpty ? "—" : "\(devices.count)")
            }

            Section("What it means") {
                Text(finding.detail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let rule = finding.ruleSummary {
                Section("Access rule") {
                    Text(rule)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if !devices.isEmpty {
                Section("Machines") {
                    ForEach(devices) { device in
                        NavigationLink {
                            DeviceDetailView(deviceID: device.id).environment(app)
                        } label: {
                            HStack(spacing: 8) {
                                StatusDot(isOnline: device.isOnline)
                                Text(device.shortName).lineLimit(1)
                            }
                            .help(device.shortName)
                        }
                    }
                }
            }
        }
    }
}
