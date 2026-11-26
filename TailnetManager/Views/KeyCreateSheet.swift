import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Creates a new auth key in three phases inside one sheet:
/// form → progress → secret-shown-once. Creating a key is non-destructive,
/// so this sheet itself is the preview — no ChangePlan involved. The secret
/// is shown only here, once, and never logged.
struct KeyCreateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum KeyCreatePhase: Equatable {
        case form
        case creating
        case created(AuthKey)
    }

    private static let keyCreateExpiryOptions = [1, 7, 30, 90]

    @State private var keyCreatePhase: KeyCreatePhase = .form
    @State private var keyCreateDescription = ""
    @State private var keyCreateReusable = false
    @State private var keyCreateEphemeral = false
    @State private var keyCreatePreauthorized = false
    @State private var keyCreateSelectedTags: Set<String> = []
    @State private var keyCreateExpiryDays = 90
    @State private var keyCreateCopied = false

    var body: some View {
        NavigationStack {
            Group {
                switch keyCreatePhase {
                case .form:
                    keyCreateForm
                case .creating:
                    keyCreateProgress
                case .created(let key):
                    keyCreateSuccess(key)
                }
            }
            .navigationTitle("Create key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if keyCreatePhase == .form {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(keyCreatePhase == .creating)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 500)
        #endif
    }

    // MARK: - Phase 1: form

    private var keyCreateForm: some View {
        Form {
            Section {
                TextField("Name", text: $keyCreateDescription,
                          prompt: Text("e.g. CI runners"))
                    .onChange(of: keyCreateDescription) { _, newValue in
                        if newValue.count > 50 {
                            keyCreateDescription = String(newValue.prefix(50))
                        }
                    }
                    .help("A short label so you recognize this key later")
            }

            Section {
                Toggle("Use for more than one machine", isOn: $keyCreateReusable)
                    .help("Off: the key stops working after the first machine joins.")
                Toggle("Remove machines when they go offline", isOn: $keyCreateEphemeral)
                    .help("For short-lived machines such as CI runners.")
                Toggle("Skip approval for these machines", isOn: $keyCreatePreauthorized)
                    .help("Machines that join with this key don't wait for your approval.")
            }

            if !app.knownTags.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(app.knownTags, id: \.self) { tag in
                            keyCreateTagChip(tag)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Access groups")
                        .help("Machines that join with this key get these access groups.")
                }
            }

            Section {
                Picker("Key works for", selection: $keyCreateExpiryDays) {
                    ForEach(Self.keyCreateExpiryOptions, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .help("After this, no new machines can join with it. Machines that already joined stay.")
            }

            Section {
                Button {
                    Task { await keyCreateRun() }
                } label: {
                    Text("Create key")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .listRowBackground(Color.clear)
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private func keyCreateTagChip(_ tag: String) -> some View {
        let isOn = keyCreateSelectedTags.contains(tag)
        return Button {
            if isOn {
                keyCreateSelectedTags.remove(tag)
            } else {
                keyCreateSelectedTags.insert(tag)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                Text(tag.replacingOccurrences(of: "tag:", with: ""))
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isOn ? Tone.accessGroup.color.opacity(0.14) : Color.secondary.opacity(0.1),
                        in: Capsule())
            .foregroundStyle(isOn ? Tone.accessGroup.color : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tag), \(isOn ? "selected" : "not selected")")
    }

    // MARK: - Phase 2: creating

    private var keyCreateProgress: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Creating key…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func keyCreateRun() async {
        keyCreatePhase = .creating
        let created = await app.createAuthKey(
            description: keyCreateDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            reusable: keyCreateReusable,
            ephemeral: keyCreateEphemeral,
            preauthorized: keyCreatePreauthorized,
            tags: keyCreateSelectedTags.sorted(),
            expiryDays: keyCreateExpiryDays)
        if let created {
            keyCreatePhase = .created(created)
        } else {
            // The global alert already showed the error; keep the form state.
            keyCreatePhase = .form
        }
    }

    // MARK: - Phase 3: secret shown once

    private func keyCreateSuccess(_ key: AuthKey) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)

                Text("Key created")
                    .font(.title2.bold())

                if let description = key.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }

                Text(key.key ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 12))

                Button {
                    keyCreateCopyToClipboard(key.key ?? "")
                    keyCreateCopied = true
                } label: {
                    Label(keyCreateCopied ? "Copied" : "Copy key",
                          systemImage: keyCreateCopied ? "checkmark" : "doc.on.doc")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Label("This is the only time the key is shown.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Button("Done") { dismiss() }
                    .padding(.top, 6)
            }
            .padding()
        }
    }

    private func keyCreateCopyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
