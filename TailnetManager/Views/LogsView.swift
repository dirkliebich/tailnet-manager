import SwiftUI

/// Read-only configuration audit trail, straight from the Tailscale API.
/// Nothing here mutates the tailnet — it's the record of everyone who did.
struct LogsView: View {
    @Environment(AppState.self) private var app

    @State private var range = 7
    @State private var logs: [AuditLogEntry]?
    @State private var loadFailed = false
    @State private var searchText = ""
    @State private var logsFilter = LogsOriginFilter.all.rawValue
    @State private var logsGroup = LogsGroupMode.day.rawValue

    // MARK: - Filter / group options

    private enum LogsOriginFilter: String, CaseIterable {
        case all = "All sources"
        case console = "Console"
        case api = "API"
        case node = "Node"
        case other = "Other"
    }

    private enum LogsGroupMode: String, CaseIterable {
        case day = "Day"
        case action = "Action"
        case person = "Person"
        case source = "Source"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Range", selection: $range) {
                Text("24 h").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            if logsHasData {
                ListControlBar {
                    SelectionMenu(
                        title: "Filter",
                        systemImage: "line.3.horizontal.decrease.circle",
                        options: LogsOriginFilter.allCases.map(\.rawValue),
                        selection: $logsFilter)
                    SelectionMenu(
                        title: "Group by",
                        systemImage: "square.stack.3d.up",
                        options: LogsGroupMode.allCases.map(\.rawValue),
                        selection: $logsGroup)
                }
            }

            content
        }
        .navigationTitle("Logs")
        .searchable(text: $searchText, prompt: "Actor, target, or action")
        .task(id: range) {
            logs = nil
            loadFailed = false
            if let fetched = await app.fetchAuditLogs(daysBack: range) {
                logs = fetched
            } else {
                loadFailed = true
            }
        }
    }

    // MARK: - Content

    private var logsHasData: Bool { logs?.isEmpty == false }

    @ViewBuilder
    private var content: some View {
        if let logs {
            if logs.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.rectangle",
                    title: "No changes recorded",
                    message: "Nothing was configured in the last \(range == 1 ? "24 hours" : "\(range) days")."
                )
            } else if logsFiltered.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No log entries match the current filter or search."
                )
            } else {
                logsList
            }
        } else if loadFailed {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load the audit log",
                message: "Pull to refresh, or check that your API token can read logs."
            )
        } else {
            ProgressView("Loading the audit log…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var logsList: some View {
        List {
            if LogsGroupMode(rawValue: logsGroup) == .day {
                ForEach(logsByDay, id: \.day) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            LogsEntryRow(entry: entry)
                        }
                    } header: {
                        Text(logsDayLabel(group.day))
                    }
                }
            } else {
                ForEach(logsGroups, id: \.name) { group in
                    Section {
                        ForEach(group.items) { entry in
                            LogsEntryRow(entry: entry)
                        }
                    } header: {
                        GroupSectionHeader(title: group.name, count: group.items.count)
                    }
                }
            }

            Section {
            } footer: {
                Text("Read-only record straight from Tailscale — every configuration change, wherever it was made.")
            }
        }
        .refreshable {
            if let fresh = await app.fetchAuditLogs(daysBack: range) {
                logs = fresh
                loadFailed = false
            }
        }
    }

    // MARK: - Filtering & grouping

    private var logsFiltered: [AuditLogEntry] {
        guard let logs else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return logs.filter { entry in
            guard logsMatchesFilter(entry) else { return false }
            guard !query.isEmpty else { return true }
            return entry.actionLabel.localizedCaseInsensitiveContains(query)
                || (entry.actor?.label.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.target?.label.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func logsMatchesFilter(_ entry: AuditLogEntry) -> Bool {
        switch LogsOriginFilter(rawValue: logsFilter) ?? .all {
        case .all: return true
        case .console: return entry.origin == "ADMIN_CONSOLE"
        case .api: return entry.origin == "CONFIG_API"
        case .node: return entry.origin == "NODE"
        case .other:
            return !["ADMIN_CONSOLE", "CONFIG_API", "NODE"].contains(entry.origin ?? "")
        }
    }

    /// Non-day groupings, honoring the current selection.
    private var logsGroups: [(name: String, items: [AuditLogEntry])] {
        switch LogsGroupMode(rawValue: logsGroup) ?? .day {
        case .day:
            return []
        case .action:
            return groupItems(logsFiltered, by: { $0.actionLabel.capitalized })
        case .person:
            return groupItems(logsFiltered, by: { $0.actor?.label ?? "Unknown" })
        case .source:
            return groupItems(logsFiltered, by: { logsOriginLabel($0) })
        }
    }

    private var logsByDay: [(day: Date, entries: [AuditLogEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: logsFiltered) { entry in
            calendar.startOfDay(for: entry.date ?? .distantPast)
        }
        return groups.keys.sorted(by: >).map { day in
            (day: day, entries: groups[day] ?? [])
        }
    }

    private func logsDayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if day == calendar.startOfDay(for: .distantPast) { return "Unknown date" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func logsOriginLabel(_ entry: AuditLogEntry) -> String {
        switch entry.origin {
        case "ADMIN_CONSOLE": return "Console"
        case "CONFIG_API": return "API"
        case "NODE": return "Node"
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return "Unknown"
        }
    }
}

// MARK: - Row

private struct LogsEntryRow: View {
    let entry: AuditLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.actionLabel)
                    .font(.body.weight(.semibold))
                if let target = entry.target {
                    Text(target.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                Text(entry.actor?.label ?? "Unknown")
                    .lineLimit(1)
                BadgeLabel(text: logsOriginText, tint: logsOriginTint)
                if let date = entry.date {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var logsOriginText: String {
        switch entry.origin {
        case "ADMIN_CONSOLE": return "Console"
        case "CONFIG_API": return "API"
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return "Unknown"
        }
    }

    private var logsOriginTint: Color {
        switch entry.origin {
        case "ADMIN_CONSOLE": return .blue
        case "CONFIG_API": return .teal
        default: return .gray
        }
    }
}
