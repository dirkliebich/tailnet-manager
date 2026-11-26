import SwiftUI

// MARK: - Add someone

/// Email, team, Continue. Their access is ready before they sign in and the
/// invite goes out — confirmed on one summary screen, saved to People
/// history. No email = a shareable invite link.
struct AddPersonSheet: View {
    @Environment(AppState.self) private var app

    @State private var email = ""
    @State private var role = "member"
    @State private var sendInvite = true
    @State private var teams: Set<String> = []
    @State private var groups: Set<String> = []
    @State private var reason = ""
    /// Machines they'd reach — worked out when the choices change, not on
    /// every keystroke of the note.
    @State private var reach: Int?

    private struct ReachInputs: Hashable {
        let email: String, role: String, teams: Set<String>, groups: Set<String>
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var existingMember: TSUser? {
        guard !trimmedEmail.isEmpty else { return nil }
        return app.users.first { $0.loginName.caseInsensitiveCompare(trimmedEmail) == .orderedSame }
    }

    private var pendingInvite: UserInvite? {
        guard !trimmedEmail.isEmpty else { return nil }
        return app.invites.first { ($0.email ?? "").caseInsensitiveCompare(trimmedEmail) == .orderedSame }
    }

    private var looksLikeEmail: Bool {
        trimmedEmail.isEmpty || trimmedEmail.firstMatch(of: #/^[^@\s]+@[^@\s]+\.[^@\s]+$/#) != nil
    }

    private var policyTeams: [(group: String, members: Int)] {
        (app.policyModel?.groups ?? [:]).map { ($0.key, $0.value.count) }.sorted { $0.group < $1.group }
    }

    private var accessGroups: [String] {
        app.accessGroups.filter { !app.devices(inGroup: $0).isEmpty }
    }

    /// Without an invite they join by signing in, as a Member.
    private var effectiveRole: String { sendInvite || trimmedEmail.isEmpty ? role : "member" }

    private var hasEmail: Bool { !trimmedEmail.isEmpty && existingMember == nil && looksLikeEmail }

    private var canContinue: Bool {
        existingMember == nil && looksLikeEmail
            && (trimmedEmail.isEmpty || sendInvite || !teams.isEmpty || !groups.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                whoSection
                if hasEmail {
                    teamSection
                    extraAccessSection
                }
                Section {
                    TextField("Note (optional) — e.g. starts 1 Oct", text: $reason, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section {
                    Button {
                        // Teams need an email; without one it's just an invite link.
                        app.proposeOnboarding(email: trimmedEmail, role: effectiveRole,
                                              teams: hasEmail ? teams.sorted() : [],
                                              accessGroups: hasEmail ? groups.sorted() : [],
                                              sendInvite: sendInvite,
                                              reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
                    } label: {
                        Text(trimmedEmail.isEmpty ? "Create invite link" : "Continue")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canContinue)
                    .listRowBackground(Color.clear)
                } footer: {
                    if hasEmail, let reach {
                        Text("They’ll be able to reach \(reach) machine\(reach == 1 ? "" : "s"). You’ll confirm on the next screen.")
                    } else {
                        Text("You’ll confirm on the next screen.")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Add someone")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { app.dismissRootSheet() }
                }
            }
            .task(id: ReachInputs(email: trimmedEmail, role: effectiveRole, teams: teams, groups: groups)) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                reach = hasEmail ? app.pendingReach(email: trimmedEmail, role: effectiveRole,
                                                    teams: teams.sorted(), accessGroups: groups.sorted()) : nil
            }
            .onChange(of: pendingInvite?.id) { _, id in
                // Don't send a second invite by default.
                sendInvite = id == nil
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    // MARK: Sections

    @ViewBuilder
    private var whoSection: some View {
        Section {
            TextField("Email", text: $email, prompt: Text("name@company.com"))
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if hasEmail {
                Toggle("Email them an invite", isOn: $sendInvite)
                    .toggleStyle(.switch)
            }
            if sendInvite || trimmedEmail.isEmpty {
                Picker("Role", selection: $role) {
                    ForEach(UserRole.assignable, id: \.self) { value in
                        Text(UserRole.label(for: value)).tag(value)
                    }
                }
            }
            if let member = existingMember {
                Label("\(member.title) is already in your network.", systemImage: "info.circle")
                    .foregroundStyle(.orange)
            } else if !looksLikeEmail {
                Label("That doesn’t look like an email address.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if pendingInvite != nil {
                Label("They already have an invite waiting.", systemImage: "envelope.badge")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if trimmedEmail.isEmpty {
                Text("No email? You’ll get an invite link to send yourself.")
            } else if hasEmail && !sendInvite {
                Text("No email goes out — they just sign in with this address.")
            }
        }
    }

    @ViewBuilder
    private var teamSection: some View {
        if !policyTeams.isEmpty {
            Section {
                ForEach(policyTeams, id: \.group) { team in
                    Toggle(isOn: binding(team.group, in: $teams)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(teamDisplayName(team.group))
                            Text("\(team.members) \(team.members == 1 ? "person" : "people")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                Text("Which team?")
            } footer: {
                Text("They get the same access as everyone on the team.")
            }
        }
    }

    @ViewBuilder
    private var extraAccessSection: some View {
        if !accessGroups.isEmpty {
            Section {
                DisclosureGroup(groups.isEmpty ? "Extra access (optional)" : "Extra access (\(groups.count))") {
                    ForEach(accessGroups, id: \.self) { tag in
                        let n = app.devices(inGroup: tag).count
                        Toggle(isOn: binding(tag, in: $groups)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AccessEditor.accessGroupName(tag))
                                Text("\(n) machine\(n == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private func binding(_ key: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(key) },
            set: { on in
                if on { set.wrappedValue.insert(key) } else { set.wrappedValue.remove(key) }
            })
    }
}
