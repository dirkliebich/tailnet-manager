import SwiftUI

// MARK: - Policy viewer

/// The raw HuJSON policy file, plus the local backups the app takes before
/// every save — any backup can be restored through the normal review.
struct PolicyViewerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var policyText: String?
    @State private var isLoading = true
    @State private var backups: [PolicyBackupStore.Backup] = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Policy File")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        backupsMenu
                    }
                }
                .task {
                    policyText = await app.fetchPolicyFile()
                    backups = PolicyBackupStore.list()
                    isLoading = false
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    /// Each backup is the policy as it was just before one of the app's
    /// saves. Restoring goes through the same review, checks and backup.
    private var backupsMenu: some View {
        Menu {
            if backups.isEmpty {
                Text("No backups yet — one is made before every save.")
            }
            ForEach(backups) { backup in
                Button("Restore from before \(backup.date.formatted(date: .abbreviated, time: .shortened))…") {
                    dismiss()
                    Task {
                        // Let this sheet close before the review sheet opens.
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        app.proposePolicyRestore(backup)
                    }
                }
            }
        } label: {
            Label("Backups", systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .help("Restore the policy as it was before one of the app's saves")
    }

    @ViewBuilder
    private var content: some View {
        if let policyText {
            ScrollView([.vertical, .horizontal]) {
                Text(policyText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("To change who reaches what, use Access or a person's page.")
        } else if isLoading {
            ProgressView("Loading policy…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                systemImage: "doc.text",
                title: "Policy unavailable",
                message: "The policy file couldn’t be loaded."
            )
        }
    }
}
