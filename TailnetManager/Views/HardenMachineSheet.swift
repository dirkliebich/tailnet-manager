import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The per-machine hardening sheet: the full, boot-safe, copy-ready script
/// for one machine, plus the fixes the app can run itself (each of those
/// goes through the global review sheet — nothing mutates here).
struct HardenMachineSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let device: Device

    @State private var justCopied = false
    @State private var showRenamePrompt = false
    @State private var renameText = ""

    init(device: Device) {
        self.device = device
    }

    var body: some View {
        NavigationStack {
            let report = app.hardeningReport(for: device)
            List {
                if report.steps.contains(where: { $0.apiAction != nil }) {
                    appActionsSection(report: report)
                }
                deviceEditSection

                if report.os.isCommandable && !report.fullScript.isEmpty {
                    scriptSection(report: report)
                } else {
                    nonCommandableSection(report: report)
                }
            }
            .navigationTitle("Harden \(device.shortName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename \(device.shortName)", isPresented: $showRenamePrompt) {
                TextField("New machine name", text: $renameText)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                Button("Review rename…") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    app.propose(.rename(trimmed), on: device)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You review it before anything changes. Links that use the old name stop working.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 700)
        #endif
    }

    // MARK: - App-side actions

    private func appActionsSection(report: HardeningReport) -> some View {
        Section {
            ForEach(report.steps.filter { $0.apiAction != nil }) { step in
                Button {
                    if let action = step.apiAction {
                        app.proposeHardeningAction(action, on: device)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Label(hardenMachineActionLabel(for: step.apiAction),
                                  systemImage: hardenMachineActionSymbol(for: step.apiAction))
                            Spacer(minLength: 0)
                            StatusPill(text: step.severity.label, tone: Tone(step.severity))
                        }
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(step.rationale)
            }
        } header: {
            Text("Fix from the app")
                .help("Each fix opens the review first. Nothing changes until you confirm.")
        }
    }

    // MARK: - Device edit shortcuts

    private var deviceEditSection: some View {
        Section {
            Button {
                renameText = device.shortName
                showRenamePrompt = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        } header: {
            Text("Machine")
        }
    }

    // MARK: - Script

    private func scriptSection(report: HardeningReport) -> some View {
        Section {
            Button {
                hardenMachineCopyToClipboard(report.fullScript)
                justCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    justCopied = false
                }
            } label: {
                Label(justCopied ? "Copied!" : "Copy full script",
                      systemImage: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowSeparator(.hidden)
            .help("Run it on \(device.shortName) over Tailscale SSH. Tailscale stays reachable and starts at boot before anything is closed, so you won't lose access. Read every line first.")

            ScrollView(.horizontal) {
                hardenMachineScriptText(report.fullScript)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .listRowSeparator(.hidden)
        } header: {
            Text("Hardening script — \(report.os.label)")
        }
    }

    // MARK: - Machines without a shell

    private func nonCommandableSection(report: HardeningReport) -> some View {
        Section {
            EmptyStateView(
                systemImage: "iphone.gen3",
                title: "Nothing to run",
                message: "Change its settings in the Tailscale app on \(device.shortName).")
        }
    }

    // MARK: - Private helpers

    private func hardenMachineActionLabel(for action: HardeningAPIAction?) -> String {
        switch action {
        case .disableRoutes: return "Disable routes…"
        case .reenableKeyExpiry: return "Re-enable key expiry…"
        case .revokeApproval: return "Revoke approval…"
        case .expireKey: return "Expire key…"
        case nil: return "Review…"
        }
    }

    private func hardenMachineActionSymbol(for action: HardeningAPIAction?) -> String {
        switch action {
        case .disableRoutes: return "arrow.triangle.branch"
        case .reenableKeyExpiry: return "clock.arrow.circlepath"
        case .revokeApproval: return "person.crop.circle.badge.xmark"
        case .expireKey: return "clock.badge.xmark"
        case nil: return "questionmark.circle"
        }
    }

    /// Renders the script as one selectable Text, dimming comment lines.
    private func hardenMachineScriptText(_ script: String) -> Text {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        var result = Text(verbatim: "")
        for (index, line) in lines.enumerated() {
            var piece = Text(verbatim: String(line))
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                piece = piece.foregroundStyle(.secondary)
            }
            if index > 0 { result = result + Text(verbatim: "\n") }
            result = result + piece
        }
        return result
    }

    private func hardenMachineCopyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
