import SwiftUI

// MARK: - Change or remove someone

/// One person, one list of plain actions. Each action opens a screen with
/// just that one thing, then Continue → the confirmation screen.
struct ManagePersonSheet: View {
    @Environment(AppState.self) private var app
    let userID: String

    private var user: TSUser? { app.users.first { $0.id == userID } }

    var body: some View {
        NavigationStack {
            Group {
                if let user {
                    actions(user)
                } else {
                    EmptyStateView(systemImage: "person.slash", title: "Not found",
                                   message: "This person isn’t in your network any more.")
                }
            }
            .navigationTitle("Change or remove")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { app.dismissRootSheet() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func actions(_ user: TSUser) -> some View {
        let isYou = app.currentAdmin?.id == user.id
        // Guests (shared in from another network) have no role and can't be
        // paused; everything else works the same.
        let canChangeRole = !user.isOwner && !isYou && !user.isExternal
        let canPause = !user.isOwner && !isYou && !user.isExternal
        let canRemove = !user.isOwner && !isYou
        let teams = app.teams(of: user).sorted().map(teamDisplayName)
        return List {
            Section {
                PersonHeader(user: user)
                if user.isExternal {
                    Label("Guest from another network — they reach the machines you share with them.",
                          systemImage: "person.crop.circle.badge.questionmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    ChangeEmailView(user: user)
                } label: {
                    ActionRow(symbol: "envelope", tint: .accentColor, title: "Change email",
                              subtitle: user.isExternal ? "Keeps their access" : "Keeps their role, teams and access")
                }
                NavigationLink {
                    ChangeTeamsView(user: user, initial: app.teams(of: user))
                } label: {
                    ActionRow(symbol: "person.3", tint: .accentColor, title: "Change teams",
                              subtitle: teams.isEmpty ? "Not on a team" : "Now: " + teams.joined(separator: ", "))
                }
                if canChangeRole {
                    NavigationLink {
                        ChangeRoleView(user: user, initial: user.role ?? "member")
                    } label: {
                        ActionRow(symbol: "star", tint: .accentColor, title: "Change role",
                                  subtitle: "Now: \(user.roleLabel)")
                    }
                }
            }

            if canPause || canRemove {
                Section {
                    if canPause && user.isSuspended {
                        Button {
                            app.proposeResume(user)
                        } label: {
                            ActionRow(symbol: "play.circle", tint: .green, title: "Resume access",
                                      subtitle: "Let them back in")
                        }
                        .buttonStyle(.plain)
                    } else if canPause {
                        Button {
                            app.proposeRemoval(app.removalInventory(for: user), mode: .suspend)
                        } label: {
                            ActionRow(symbol: "pause.circle", tint: .orange, title: "Pause access",
                                      subtitle: "Lock them out — undo any time")
                        }
                        .buttonStyle(.plain)
                    }
                    if canRemove {
                        NavigationLink {
                            RemovePersonView(userID: user.id)
                        } label: {
                            ActionRow(symbol: "trash", tint: .red, title: "Remove from network",
                                      subtitle: user.isExternal ? "Stop sharing and take them off every rule"
                                                                : "Delete their account and devices")
                        }
                    }
                }
            }
        }
        .task { if user.isExternal && !app.deviceSharesLoaded { await app.loadDeviceShares() } }
    }
}

private struct ActionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Change email

struct ChangeEmailView: View {
    @Environment(AppState.self) private var app
    let user: TSUser
    @State private var email = ""
    @FocusState private var focused: Bool

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var problem: String? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.firstMatch(of: #/^[^@\s]+@[^@\s]+\.[^@\s]+$/#) == nil { return "That doesn’t look like an email address." }
        if trimmed.caseInsensitiveCompare(user.loginName) == .orderedSame { return "That’s their current email." }
        return nil
    }

    /// Someone who already has this address gets the same access too.
    private var existingOwner: TSUser? {
        guard !trimmed.isEmpty else { return nil }
        return app.users.first { $0.loginName.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        Form {
            Section {
                TextField("New email", text: $email, prompt: Text("name@company.com"))
                    .focused($focused)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let other = existingOwner {
                    Label("\(other.title) already uses this address — they’ll get the same access too.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Now: \(user.loginName)")
            }
            Section {
                Label(user.isExternal ? "Keeps their access" : "Keeps their role, teams and access",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Label(user.isExternal ? "The same machines get shared with the new email"
                                      : "They get an invite at the new email",
                      systemImage: "envelope")
                Label(user.isExternal ? "Old address keeps access until you remove it"
                                      : "Old account keeps working until you remove it",
                      systemImage: "clock")
            }
            ContinueButton(disabled: trimmed.isEmpty || problem != nil
                               || (user.isExternal && !app.deviceSharesLoaded)) {
                app.proposeEdit(user, email: trimmed, role: user.role ?? "member",
                                teams: app.teams(of: user))
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Change email")
        .onAppear { focused = true }
        .task { if user.isExternal && !app.deviceSharesLoaded { await app.loadDeviceShares() } }
    }
}

// MARK: - Change teams

struct ChangeTeamsView: View {
    @Environment(AppState.self) private var app
    let user: TSUser
    /// Their teams when the screen opened. Kept as state so a background
    /// refresh (which rebuilds this view) can't move it.
    @State private var initial: Set<String>
    @State private var teams: Set<String>

    init(user: TSUser, initial: Set<String>) {
        self.user = user
        _initial = State(initialValue: initial)
        _teams = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                ForEach((app.policyModel?.groups ?? [:]).keys.sorted(), id: \.self) { team in
                    Toggle(teamDisplayName(team), isOn: Binding(
                        get: { teams.contains(team) },
                        set: { on in
                            if on { teams.insert(team) } else { teams.remove(team) }
                        }))
                        .toggleStyle(.switch)
                }
            } footer: {
                Text("They get the same access as everyone on the team.")
            }
            ContinueButton(disabled: teams == initial) {
                // Apply only what was switched here, on top of their teams now
                // (a team added elsewhere meanwhile stays).
                let live = app.teams(of: user)
                let final = live.union(teams.subtracting(initial)).subtracting(initial.subtracting(teams))
                app.proposeEdit(user, email: user.loginName, role: user.role ?? "member", teams: final)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Change teams")
    }
}

// MARK: - Change role

struct ChangeRoleView: View {
    @Environment(AppState.self) private var app
    let user: TSUser
    /// Their role when the screen opened (state: survives refreshes).
    @State private var initial: String
    @State private var role: String

    init(user: TSUser, initial: String) {
        self.user = user
        _initial = State(initialValue: initial)
        _role = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                Picker("Role", selection: $role) {
                    ForEach(UserRole.assignable, id: \.self) { value in
                        Text(UserRole.label(for: value)).tag(value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            ContinueButton(disabled: role == initial) {
                app.proposeEdit(user, email: user.loginName, role: role, teams: app.teams(of: user))
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Change role")
    }
}

// MARK: - Shared

struct ContinueButton: View {
    var tint: Color = .accentColor
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.large)
            .disabled(disabled)
            .listRowBackground(Color.clear)
        } footer: {
            Text("You’ll confirm on the next screen.")
        }
    }
}
