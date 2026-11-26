import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Every hardening issue on every machine, with app-run fixes (via the
/// global review sheet), console links for policy-level problems, and
/// copy-ready boot-safe commands for the rest.
struct HardenView: View {
    @Environment(AppState.self) private var app
    @State private var sheetDevice: Device?
    @State private var grouping: HardenGrouping = .machine
    @State private var severityFilter: HardenSeverityFilter = .all
    @State private var needsCommandsOnly = false
    @State private var appCanFixOnly = false
    @State private var searchText = ""
    @State private var expansion = GroupExpansion()

    var body: some View {
        Group {
            if app.devices.isEmpty && !app.hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                hardenPage
            }
        }
        .navigationTitle("Harden")
        .sheet(item: $sheetDevice) { device in
            HardenMachineSheet(device: device)
        }
    }

    // MARK: - Page

    @ViewBuilder
    private var hardenPage: some View {
        let reports = hardenReports
        if reports.isEmpty {
            PageEmptyState.allClear("No machine has anything to harden.")
                .refreshable { await app.refreshAll() }
        } else {
            let all = reports.flatMap { report in report.steps.map { HardenItem(step: $0, report: report) } }
            let shown = all.filter { hardenMatches($0) }
            let groups = hardenGroups(shown)
            let groupIDs = groups.map(\.id)

            ListPageLayout(stats: hardenTiles(all)) {
                FilterBar(groupings: HardenGrouping.allCases,
                          grouping: $grouping,
                          groupingTitle: { $0.title },
                          activeFilters: hardenActiveFilters,
                          onClear: hardenClearFilters,
                          expandAll: hardenExpandAll(groupIDs),
                          countText: countText(shown.count, of: all.count, noun: all.count == 1 ? "issue" : "issues")) {
                    Picker("Severity", selection: $severityFilter) {
                        ForEach(HardenSeverityFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Needs commands on the machine", isOn: $needsCommandsOnly)
                    Toggle("The app can fix it", isOn: $appCanFixOnly)
                }
            } content: {
                if shown.isEmpty {
                    PageEmptyState.nothingMatches(clear: {
                        hardenClearFilters()
                        searchText = ""
                    })
                } else {
                    hardenList(shown: shown, groups: groups)
                }
            }
            .searchable(text: $searchText, prompt: "Search machines or issues")
            .onAppear { hardenResetExpansion() }
            .onChange(of: grouping) { _, _ in hardenResetExpansion() }
            .onChange(of: severityFilter) { _, _ in hardenOpenMatches() }
            .onChange(of: needsCommandsOnly) { _, _ in hardenOpenMatches() }
            .onChange(of: appCanFixOnly) { _, _ in hardenOpenMatches() }
            .onChange(of: searchText) { _, _ in hardenOpenMatches() }
            .onChange(of: groupIDs) { old, new in
                // Groups that show up after a refresh open like the others did.
                guard shown.count <= 100 else { return }
                if new.contains(where: { !old.contains($0) }) { expansion.openAll(new) }
            }
        }
    }

    private func hardenList(shown: [HardenItem], groups: [HardenGroup]) -> some View {
        List {
            if grouping == .none {
                Section {
                    ForEach(shown) { hardenRow($0, showsMachine: true) }
                }
            } else {
                ForEach(groups) { group in
                    Section {
                        if expansion.isOpen(group.id) {
                            ForEach(group.items) { hardenRow($0, showsMachine: grouping != .machine) }
                        }
                    } header: {
                        hardenGroupHeader(group)
                    }
                }
            }
        }
        .refreshable { await app.refreshAll() }
    }

    private func hardenRow(_ item: HardenItem, showsMachine: Bool) -> some View {
        let device = item.report.device
        var fix: (() -> Void)?
        if let action = item.step.apiAction {
            fix = { app.proposeHardeningAction(action, on: device) }
        }
        let openMachine: () -> Void = { sheetDevice = device }
        return HardenStepRow(step: item.step,
                             machineName: device.shortName,
                             showsMachine: showsMachine,
                             fix: fix)
            .contextMenu {
                if let action = item.step.apiAction, let fix {
                    Button(hardenActionLabel(action), action: fix)
                }
                if item.step.hasCommands {
                    Button("Copy commands") { hardenCopyToClipboard(hardenCommandText(for: item.step)) }
                }
                Button("Harden \(device.shortName)…", action: openMachine)
            }
    }

    private func hardenGroupHeader(_ group: HardenGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                expansion.set(group.id, open: !expansion.isOpen(group.id))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expansion.isOpen(group.id) ? 90 : 0))
                        .frame(width: 12)
                    if let device = group.device {
                        StatusDot(isOnline: device.isOnline)
                    }
                    GroupHeaderLabel(title: group.title, count: group.items.count, pill: group.pill)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expansion.isOpen(group.id) ? "Hide these" : "Show these")

            if let device = group.device {
                Button("Harden…") { sheetDevice = device }
                    .controlSize(.small)
                    .fixedSize()
                    .help("The full script and fixes for \(device.shortName)")
                DeviceActionsButton(device: device)
            }
        }
        .textCase(nil)
    }

    // MARK: - Data

    /// Built once per data change (reports are expensive to derive).
    private var hardenReports: [HardeningReport] {
        app.cached("harden.reports") { app.hardeningReports }
    }

    private func hardenMatches(_ item: HardenItem) -> Bool {
        let step = item.step
        if !severityFilter.includes(step.severity) { return false }
        if needsCommandsOnly && !step.hasCommands { return false }
        if appCanFixOnly && step.apiAction == nil { return false }
        if !searchText.isEmpty {
            return item.report.device.shortName.localizedCaseInsensitiveContains(searchText)
                || step.title.localizedCaseInsensitiveContains(searchText)
        }
        return true
    }

    private var hardenActiveFilters: Int {
        (severityFilter == .all ? 0 : 1) + (needsCommandsOnly ? 1 : 0) + (appCanFixOnly ? 1 : 0)
    }

    private func hardenClearFilters() {
        severityFilter = .all
        needsCommandsOnly = false
        appCanFixOnly = false
    }

    /// Severity tiles; tapping one shows exactly that severity, tapping it
    /// again shows everything.
    private func hardenTiles(_ all: [HardenItem]) -> [StatTile] {
        let onlySeverity = !needsCommandsOnly && !appCanFixOnly
        return [HardenSeverityFilter.criticalHigh, .medium, .low].map { bucket in
            let isActive = onlySeverity && severityFilter == bucket
            return StatTile(bucket.title,
                            count: all.filter { bucket.includes($0.step.severity) }.count,
                            systemImage: bucket.systemImage,
                            tone: bucket.tone,
                            active: isActive) {
                if isActive {
                    hardenClearFilters()
                } else {
                    hardenClearFilters()
                    severityFilter = bucket
                }
            }
        }
    }

    private func hardenGroups(_ items: [HardenItem]) -> [HardenGroup] {
        switch grouping {
        case .machine:
            // Reports arrive worst machine first; keep that order.
            var order: [String] = []
            var buckets: [String: [HardenItem]] = [:]
            for item in items {
                let id = item.report.device.id
                if buckets[id] == nil { order.append(id) }
                buckets[id, default: []].append(item)
            }
            return order.compactMap { id in
                guard let groupItems = buckets[id], let first = groupItems.first else { return nil }
                return HardenGroup(id: id,
                                   title: first.report.device.shortName,
                                   items: groupItems,
                                   device: first.report.device,
                                   pill: hardenTopPill(groupItems))
            }
        case .severity:
            return groupItems(items, by: { $0.step.severity.label },
                              order: ["Critical", "High", "Medium", "Low", "Info"])
                .map { HardenGroup(id: $0.name, title: $0.name, items: $0.items, device: nil, pill: nil) }
        case .issue:
            return groupItems(items, by: { $0.step.title })
                .map { HardenGroup(id: $0.name, title: $0.name, items: $0.items, device: nil,
                                   pill: hardenTopPill($0.items)) }
        case .none:
            return []
        }
    }

    /// The worst severity in a group, as its one pill.
    private func hardenTopPill(_ items: [HardenItem]) -> (text: String, tone: Tone)? {
        guard let top = items.map(\.step.severity).max() else { return nil }
        return (top.label, Tone(top))
    }

    private func hardenExpandAll(_ groupIDs: [String]) -> (allExpanded: Bool, toggle: () -> Void)? {
        guard grouping != .none else { return nil }
        return (allExpanded: expansion.allOpen(groupIDs), toggle: { expansion.toggleAll(groupIDs) })
    }

    private func hardenCurrentGroups() -> (ids: [String], rows: Int) {
        let all = hardenReports.flatMap { report in report.steps.map { HardenItem(step: $0, report: report) } }
        let shown = all.filter { hardenMatches($0) }
        return (hardenGroups(shown).map(\.id), shown.count)
    }

    private func hardenResetExpansion() {
        let current = hardenCurrentGroups()
        expansion.reset(groups: current.ids, rows: current.rows)
    }

    private func hardenOpenMatches() {
        expansion.openAll(hardenCurrentGroups().ids)
    }
}

// MARK: - Options

private enum HardenGrouping: String, CaseIterable, Hashable {
    case machine, severity, issue, none

    var title: String {
        switch self {
        case .machine: return "Machine"
        case .severity: return "Severity"
        case .issue: return "Issue"
        case .none: return "None"
        }
    }
}

private enum HardenSeverityFilter: String, CaseIterable, Hashable {
    case all, criticalHigh, medium, low

    var title: String {
        switch self {
        case .all: return "Any severity"
        case .criticalHigh: return "Critical and high"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "shield"
        case .criticalHigh: return "exclamationmark.octagon"
        case .medium: return "exclamationmark.triangle"
        case .low: return "info.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .all: return .neutral
        case .criticalHigh: return .critical
        case .medium: return .warning
        case .low: return .info
        }
    }

    func includes(_ severity: FindingSeverity) -> Bool {
        switch self {
        case .all: return true
        case .criticalHigh: return severity >= .high
        case .medium: return severity == .medium
        case .low: return severity <= .low
        }
    }
}

// MARK: - Items & groups

/// A hardening step paired with its report, unique across machines so
/// steps can be regrouped by severity or issue.
private struct HardenItem: Identifiable {
    let step: HardeningStep
    let report: HardeningReport
    var id: String { report.device.id + "·" + step.id }
}

private struct HardenGroup: Identifiable {
    let id: String
    let title: String
    let items: [HardenItem]
    /// Set when grouped by machine.
    let device: Device?
    let pill: (text: String, tone: Tone)?
}

// MARK: - Step row

/// One issue on one machine: severity pill, what it is, the app-run fix or
/// console link, and the details (why + commands) folded away.
private struct HardenStepRow: View {
    let step: HardeningStep
    let machineName: String
    let showsMachine: Bool
    let fix: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusPill(text: step.severity.label, tone: Tone(step.severity))
                Text(step.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if showsMachine {
                    Text(machineName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if fix != nil || step.requiresPolicyEdit {
                HStack(spacing: 12) {
                    if let action = step.apiAction, let fix {
                        Button(hardenActionLabel(action), action: fix)
                            .controlSize(.small)
                            .fixedSize()
                    }
                    if step.requiresPolicyEdit {
                        Link(destination: URL(string: "https://login.tailscale.com/admin/acls")!) {
                            Label("Fix in policy (console)", systemImage: "arrow.up.forward.app")
                                .font(.callout)
                        }
                        .help("Needs a rule change in the policy file.")
                    }
                }
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.rationale)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if step.hasCommands {
                        commandBlock
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Text(step.hasCommands ? "Details and commands" : "Details")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .help(step.hasCommands
                  ? "Run these on \(machineName). They keep Tailscale reachable and start it at boot first, so you never lock yourself out."
                  : "Why this matters")
        }
        .padding(.vertical, 3)
    }

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(step.lines) { line in
                if let comment = line.comment {
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let command = line.command {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button {
                hardenCopyToClipboard(hardenCommandText(for: step))
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Private helpers

private func hardenActionLabel(_ action: HardeningAPIAction) -> String {
    switch action {
    case .disableRoutes: return "Disable routes…"
    case .reenableKeyExpiry: return "Re-enable key expiry…"
    case .revokeApproval: return "Revoke approval…"
    case .expireKey: return "Expire key…"
    }
}

/// A single step's commands as copyable text, comments rendered as # lines.
private func hardenCommandText(for step: HardeningStep) -> String {
    var out: [String] = []
    for line in step.lines {
        if let comment = line.comment { out.append("# \(comment)") }
        if let command = line.command { out.append(command) }
    }
    return out.joined(separator: "\n")
}

private func hardenCopyToClipboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
