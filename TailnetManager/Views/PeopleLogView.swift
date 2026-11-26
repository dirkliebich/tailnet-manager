import SwiftUI
import UniformTypeIdentifiers

// MARK: - People history

/// Everyone added, changed, paused or removed through the app: when, why, by
/// whom, what they had, and how each step went. Exportable as CSV.
struct PeopleLogView: View {
    @Environment(AppState.self) private var app
    @State private var searchText = ""

    private var entries: [PeopleLogEntry] {
        guard !searchText.isEmpty else { return app.peopleLog }
        return app.peopleLog.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.login.localizedCaseInsensitiveContains(searchText)
                || $0.reason.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Newest month first, as the log is kept.
    private var months: [PeopleLogMonth] {
        var out: [PeopleLogMonth] = []
        for entry in entries {
            let title = entry.date.formatted(.dateTime.month(.wide).year())
            if out.last?.title == title {
                out[out.count - 1].entries.append(entry)
            } else {
                out.append(PeopleLogMonth(title: title, entries: [entry]))
            }
        }
        return out
    }

    var body: some View {
        List {
            ForEach(months) { month in
                Section {
                    ForEach(month.entries) { entry in
                        NavigationLink {
                            PeopleLogDetailView(entry: entry)
                        } label: {
                            PeopleLogRow(entry: entry)
                        }
                    }
                } header: {
                    GroupHeaderLabel(title: month.title, count: month.entries.count)
                }
            }
        }
        .overlay {
            if app.peopleLog.isEmpty {
                EmptyStateView(systemImage: "clock.arrow.circlepath", title: "Nothing yet",
                               message: "Everyone you add, change, pause or remove shows up here.")
            } else if entries.isEmpty {
                PageEmptyState.nothingMatches(clear: { searchText = "" })
            }
        }
        .navigationTitle("People history")
        .searchable(text: $searchText, prompt: "Search name, email or reason")
        .toolbar {
            ToolbarItem {
                ShareLink(item: PeopleLogCSV(text: PeopleLogStore.csv(app.peopleLog)),
                          preview: SharePreview("People history.csv")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                #if os(macOS)
                .labelStyle(.titleAndIcon)
                #endif
                .help("Save the history as a spreadsheet (CSV). It's kept on this device.")
                .disabled(app.peopleLog.isEmpty)
            }
        }
    }
}

private struct PeopleLogMonth: Identifiable {
    let title: String
    var entries: [PeopleLogEntry]
    var id: String { title }
}

/// The log as a CSV file for sharing (Files, Mail, Numbers…).
struct PeopleLogCSV: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
            .suggestedFileName("people-history.csv")
    }
}

// MARK: - Row

private struct PeopleLogRow: View {
    let entry: PeopleLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if entry.failedCount > 0 {
                        StatusPill(text: "\(entry.failedCount) failed", tone: .critical)
                    }
                }
                Text("\(entry.kind.label) · \(entry.date, format: .dateTime.day().month().year().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.login != entry.name {
                    Text(entry.login)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !entry.reason.isEmpty {
                    Text(entry.reason)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct PeopleLogDetailView: View {
    let entry: PeopleLogEntry

    var body: some View {
        List {
            Section {
                LabeledContent("What", value: entry.kind.label)
                LabeledContent("Who", value: entry.login)
                LabeledContent("When", value: entry.date.formatted(date: .long, time: .shortened))
                if let by = entry.performedBy {
                    LabeledContent("By", value: by)
                }
                if let role = entry.role {
                    LabeledContent("Role", value: UserRole.label(for: role))
                }
                LabeledContent("Result") {
                    if entry.succeeded {
                        Text("Every step done")
                    } else {
                        StatusPill(text: "\(entry.failedCount) step\(entry.failedCount == 1 ? "" : "s") failed", tone: .critical)
                    }
                }
            }
            if !entry.reason.isEmpty {
                Section("Reason") {
                    Text(entry.reason)
                        .textSelection(.enabled)
                }
            }
            Section(entry.kind == .added ? "Given" : entry.kind == .removed || entry.kind == .suspended ? "What they had" : "Details") {
                ForEach(entry.snapshot, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            Section("Steps") {
                ForEach(Array(entry.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 10) {
                        StepIcon(step: step)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            if let error = step.error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if step.skipped == true {
                                Text("Skipped — an earlier step failed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let backup = entry.policyBackup {
                Section("Access rules backup") {
                    Text(backup)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .help("The access rules as they were before. Restore them from Settings.")
                }
            }
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct StepIcon: View {
    let step: PeopleLogEntry.Step

    var body: some View {
        if step.skipped == true {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        } else if step.succeeded {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        } else {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

extension PeopleLogEntry.Kind {
    var label: String {
        switch self {
        case .added: return "Added"
        case .removed: return "Removed"
        case .suspended: return "Paused"
        case .resumed: return "Resumed"
        case .approved: return "Approved"
        case .changed: return "Changed"
        }
    }

    var symbol: String {
        switch self {
        case .added: return "person.crop.circle.badge.plus"
        case .removed: return "person.crop.circle.badge.xmark"
        case .suspended: return "person.slash"
        case .resumed: return "play.circle"
        case .approved: return "checkmark.circle"
        case .changed: return "pencil.circle"
        }
    }
}
