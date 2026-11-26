#if os(macOS)
import SwiftUI

/// Pick broken websites to take out of Caddy, any number across servers.
/// "Review…" reads each server's Caddy settings and opens the usual review
/// sheet with the exact change; nothing changes before that is confirmed.
struct RemoveWebsitesSheet: View {
    // Passed in: sheet content gets no AppState environment for sure.
    let app: AppState
    let preselected: Set<String>
    /// Called with the plan to review; the sheet then closes.
    let onPlan: (ChangePlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var reading = false
    @State private var problem: String?

    var body: some View {
        let sites = app.brokenWebsites
        let servers = Dictionary(grouping: sites, by: \.server).sorted { $0.key < $1.key }

        NavigationStack {
            List {
                ForEach(servers, id: \.key) { server, list in
                    Section {
                        ForEach(list) { site in row(site) }
                    } header: {
                        HStack {
                            Text(server)
                            Spacer()
                            let removable = list.filter(\.canRemove).map(\.id)
                            if !removable.isEmpty {
                                let all = Set(removable).isSubset(of: chosen)
                                Button(all ? "Select none" : "Select all") {
                                    if all { chosen.subtract(removable) } else { chosen.formUnion(removable) }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Remove broken websites")
            .safeAreaInset(edge: .bottom) { footer(sites).padding().background(.bar) }
            .overlay {
                if sites.isEmpty {
                    PageEmptyState.allClear("No broken websites.")
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .interactiveDismissDisabled(reading)
        .onAppear {
            chosen = Set(sites.filter { $0.canRemove && preselected.contains($0.id) }.map(\.id))
        }
    }

    @ViewBuilder
    private func row(_ site: BrokenWebsite) -> some View {
        Toggle(isOn: Binding(
            get: { chosen.contains(site.id) },
            set: { if $0 { chosen.insert(site.id) } else { chosen.remove(site.id) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .fontWeight(.medium)
                Text("Nothing is listening: \(site.deadPaths.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !site.canRemove {
                    Text("Stays: part of it still works (\(site.stillWorks.joined(separator: ", "))). Fix the broken paths by hand.")
                        .font(.caption)
                        .foregroundStyle(Tone.warning.color)
                } else if !site.alsoGoes.isEmpty {
                    Text("Also removed: \(site.alsoGoes.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(Tone.warning.color)
                }
            }
            .textSelection(.enabled)
        }
        .toggleStyle(.checkbox)
        .disabled(!site.canRemove || reading)
    }

    private func footer(_ sites: [BrokenWebsite]) -> some View {
        let picked = sites.filter { chosen.contains($0.id) && $0.canRemove }
        return HStack(spacing: 10) {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(reading)
            if reading {
                ProgressView().controlSize(.small)
                Text("Reading the Caddy settings…").foregroundStyle(.secondary)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.warning.color)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                Task { await review(picked) }
            } label: {
                Text(picked.isEmpty ? "Review…" : "Review \(picked.count) website\(picked.count == 1 ? "" : "s")…")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(picked.isEmpty || reading)
        }
    }

    private func review(_ sites: [BrokenWebsite]) async {
        reading = true
        problem = nil
        defer { reading = false }
        do {
            let plan = try await app.planRemovingWebsites(sites)
            onPlan(plan)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
#endif
