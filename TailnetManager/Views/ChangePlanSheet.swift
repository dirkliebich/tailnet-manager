import SwiftUI

/// The universal review dialog: shows exactly what a plan will change,
/// waits for the admin's OK, then shows each operation running live.
/// Presented globally from RootView whenever AppState.activePlan is set.
struct ChangePlanSheet: View {
    @Environment(AppState.self) private var app
    let plan: ChangePlan

    var body: some View {
        NavigationStack {
            List {
                if let summary = plan.summary {
                    Section {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let review = plan.policyReview {
                    PolicyReviewSections(review: review)
                }
                if !plan.warnings.isEmpty {
                    Section {
                        ForEach(plan.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    }
                }
                if !plan.fileDiffs.isEmpty {
                    Section("Exact changes") {
                        ForEach(plan.fileDiffs) { file in
                            DisclosureGroup("\(file.title) (−\(file.removed) +\(file.added) lines)") {
                                DiffLinesView(lines: file.lines)
                            }
                        }
                    }
                }
                Section {
                    ForEach(plan.operations) { operation in
                        ChangePlanOperationRow(operation: operation)
                    }
                } header: {
                    Text(plan.operations.count == 1
                         ? "This will happen"
                         : "\(plan.operations.count) changes will happen")
                }
            }
            .navigationTitle(plan.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                footer
                    .padding()
                    .background(.bar)
            }
        }
        .interactiveDismissDisabled(plan.phase == .running)
        #if os(macOS)
        .frame(minWidth: plan.policyReview == nil && plan.fileDiffs.isEmpty ? 460 : 560,
               minHeight: plan.policyReview == nil && plan.fileDiffs.isEmpty ? 380 : 540)
        #endif
    }

    @ViewBuilder
    private var footer: some View {
        switch plan.phase {
        case .preview:
            HStack {
                Button("Cancel") { app.dismissPlan() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await app.runActivePlan() }
                } label: {
                    Text(applyLabel)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(plan.destructiveCount > 0 ? .red : .accentColor)
                .disabled(!plan.canApply)
            }
        case .running:
            HStack(spacing: 10) {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
                Text("Applying \(plan.successCount + plan.failureCount + 1) of \(plan.operations.count)…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .finished:
            HStack {
                if plan.failureCount == 0 {
                    Label("\(plan.successCount) change\(plan.successCount == 1 ? "" : "s") applied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("\(plan.successCount) applied · \(plan.failureCount) failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Done") { app.dismissPlan() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var applyLabel: String {
        if let label = plan.applyLabel { return label }
        if plan.policyReview != nil { return "Save to Tailscale" }
        let n = plan.operations.count
        return n == 1 ? "Apply change" : "Apply \(n) changes"
    }
}

// MARK: - Policy review

/// For policy edits: who gains or loses which machines, Tailscale's own
/// verdict on the new policy, side effects to know about, and the diff.
private struct PolicyReviewSections: View {
    let review: PolicyReview

    var body: some View {
        Section {
            if review.impacts.isEmpty {
                Text(review.unchangedNote)
                    .foregroundStyle(.secondary)
            }
            ForEach(review.impacts) { impact in
                VStack(alignment: .leading, spacing: 3) {
                    Text(impact.name)
                        .fontWeight(.medium)
                    if !impact.lost.isEmpty {
                        Text("Loses \(Self.list(impact.lost))")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !impact.gained.isEmpty {
                        Text("Gains \(Self.list(impact.gained))")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Who’s affected")
        }

        if !review.notes.isEmpty {
            Section {
                ForEach(review.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }

        Section {
            switch review.validation {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                    Text("Checking with Tailscale…")
                        .foregroundStyle(.secondary)
                }
            case .passed:
                Label("Checked by Tailscale — good to go.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Tailscale said no", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fontWeight(.medium)
                    Text(reason)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }

        Section {
            DisclosureGroup("Show exact changes (+\(review.addedLines) −\(review.removedLines) lines)") {
                DiffLinesView(lines: review.diff)
            }
        }
    }

    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? "\(names.count): \(shown) and \(names.count - 6) more" : "\(names.count): \(shown)"
    }
}

/// A line diff: removed lines red, added lines green.
private struct DiffLinesView: View {
    let lines: [PolicyLineDiff.Line]

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(Self.prefix(line.kind) + line.text.replacingOccurrences(of: "\t", with: "    "))
                        .font(.caption.monospaced())
                        .foregroundStyle(Self.color(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Self.background(line.kind))
                }
            }
            .textSelection(.enabled)
        }
    }

    private static func prefix(_ kind: PolicyLineDiff.Line.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "− "
        case .same: return "  "
        case .gap: return "  "
        }
    }

    private static func color(_ kind: PolicyLineDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .same: return .primary
        case .gap: return .secondary
        }
    }

    private static func background(_ kind: PolicyLineDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return .green.opacity(0.1)
        case .removed: return .red.opacity(0.1)
        case .same, .gap: return .clear
        }
    }
}

private struct ChangePlanOperationRow: View {
    let operation: ChangePlan.Operation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: operation.symbol)
                .foregroundStyle(operation.isDestructive ? Color.red : Color.accentColor)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(operation.title)
                    .fontWeight(.medium)
                if let detail = operation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = operation.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let note = operation.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            stateIcon
                .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch operation.state {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #endif
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
