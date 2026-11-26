import SwiftUI

// MARK: - Pick a person

/// Step 1 of "Change or remove someone" from Home: tap the person.
struct PersonPickerSheet: View {
    @Environment(AppState.self) private var app
    @State private var searchText = ""

    private var people: [TSUser] {
        app.users
            .filter { searchText.isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.loginName.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(people) { user in
                Button {
                    app.peopleSheet = .manage(userID: user.id)
                } label: {
                    HStack(spacing: 12) {
                        UserAvatar(user: user, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.title)
                                .foregroundStyle(.primary)
                            Text(user.isExternal ? "\(user.loginName) · guest" : user.loginName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if people.isEmpty {
                    EmptyStateView(systemImage: "person.slash", title: "Nobody here",
                                   message: searchText.isEmpty ? "There’s no one in your network yet." : "No one matches.")
                }
            }
            .searchable(text: $searchText, prompt: "Search")
            .navigationTitle("Who?")
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
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

// MARK: - Remove from network

/// Everything that happens when someone leaves, in plain words, then
/// Continue → the confirmation screen. Saved to People history.
struct RemovePersonView: View {
    @Environment(AppState.self) private var app
    let userID: String

    @State private var cleanPolicy = true
    @State private var revokeKeyIDs: Set<String> = []
    @State private var reason = ""
    /// Worked out when the data changes, not on every keystroke of "Why?".
    @State private var inventory: RemovalInventory?

    var body: some View {
        Group {
            if let inventory {
                content(inventory)
            } else if app.users.contains(where: { $0.id == userID }) {
                ProgressView()
            } else {
                EmptyStateView(systemImage: "person.slash", title: "Already gone",
                               message: "This person isn’t in your network any more.")
            }
        }
        .navigationTitle("Remove from network")
        .task(id: "\(app.lastRefreshed?.timeIntervalSince1970 ?? 0)|\(app.deviceSharesLoaded)") {
            if let user = app.users.first(where: { $0.id == userID }) {
                inventory = app.removalInventory(for: user)
                if user.isExternal && !app.deviceSharesLoaded { await app.loadDeviceShares() }
            } else {
                inventory = nil
            }
        }
    }

    private func content(_ inv: RemovalInventory) -> some View {
        Form {
            if let blocker = inv.blocker {
                Label(blocker, systemImage: "hand.raised.fill")
                    .foregroundStyle(.red)
            } else {
                Section("What happens") {
                    if inv.user.isExternal {
                        Step(symbol: "rectangle.portrait.and.arrow.right", tint: .red,
                             text: !app.deviceSharesLoaded ? "Checking which machines are shared with them…"
                                 : inv.sharedMachines.isEmpty ? "No machines are shared with them"
                                 : "Stop sharing: " + Set(inv.sharedMachines.map(\.device.shortName)).sorted().joined(separator: ", "))
                    } else {
                        Step(symbol: "lock.fill", tint: .red, text: "Locked out of everything right away")
                        Step(symbol: "person.crop.circle.badge.xmark", tint: .red,
                             text: "Their account is deleted — can’t be undone")
                    }
                    if !inv.personalMachines.isEmpty {
                        Step(symbol: "laptopcomputer", tint: .red,
                             text: "Their devices are removed: " + inv.personalMachines.map(\.shortName).joined(separator: ", "))
                    }
                    if !inv.personalKeys.isEmpty {
                        Step(symbol: "key.slash", tint: .red,
                             text: "Their sign-in keys stop working: " + inv.personalKeys.map(\.displayName).joined(separator: ", "))
                    }
                    rulesStep(inv)
                    if !inv.invites.isEmpty {
                        Step(symbol: "envelope", tint: .red, text: "Their pending invite is cancelled")
                    }
                    if !inv.taggedMachines.isEmpty {
                        Step(symbol: "server.rack", tint: .green,
                             text: "Servers they set up stay online: " + inv.taggedMachines.map(\.shortName).joined(separator: ", "))
                    }
                    if !inv.user.isExternal {
                        Step(symbol: "person.badge.key", tint: .orange,
                             text: "Also turn off their company login (for example Google) so they can’t join again")
                    }
                }

                if !inv.automationKeys.isEmpty {
                    Section {
                        ForEach(inv.automationKeys) { key in
                            Toggle(key.displayName.replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: ""),
                                   isOn: Binding(
                                       get: { revokeKeyIDs.contains(key.id) },
                                       set: { on in
                                           if on { revokeKeyIDs.insert(key.id) } else { revokeKeyIDs.remove(key.id) }
                                       }))
                                .toggleStyle(.switch)
                        }
                    } header: {
                        Text("Automation keys they made")
                    } footer: {
                        Text("Things like deploys use these, so they keep working. Switch one on only to turn it off too.")
                    }
                }

                Section {
                    TextField("Why? (optional) — e.g. last day 30 Sep", text: $reason, axis: .vertical)
                        .lineLimit(1...3)
                }

                if inv.cleanupChangesRules && !inv.rulesManagedElsewhere {
                    Section {
                        DisclosureGroup("More options") {
                            Toggle("Take them off access rules and teams", isOn: $cleanPolicy)
                                .toggleStyle(.switch)
                        }
                    }
                }

                ContinueButton(tint: .red,
                               disabled: !inv.policyLoaded || (inv.user.isExternal && !app.deviceSharesLoaded)) {
                    app.proposeRemoval(inv, mode: .delete,
                                       reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                       cleanPolicy: cleanPolicy, revokeKeyIDs: revokeKeyIDs)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

extension RemovePersonView {
    /// What happens to their access rules — only what will really happen.
    @ViewBuilder
    private func rulesStep(_ inv: RemovalInventory) -> some View {
        if !inv.policyLoaded {
            Step(symbol: "list.bullet.rectangle", tint: .secondary, text: "Checking their access rules…")
        } else if inv.rulesManagedElsewhere && !inv.policyMentions.isEmpty {
            Step(symbol: "exclamationmark.triangle", tint: .orange,
                 text: "Your access rules are managed outside the app — take them off there")
        } else {
            if cleanPolicy && inv.cleanupChangesRules {
                Step(symbol: "list.bullet.rectangle", tint: .red, text: "Taken off every access rule and team")
            }
            if cleanPolicy && !inv.cleanupLeftovers.isEmpty {
                Step(symbol: "exclamationmark.triangle", tint: .orange,
                     text: "Still named somewhere the app can’t change — check the access rules on the Tailscale website")
            }
        }
    }
}

// MARK: - Pieces

struct PersonHeader: View {
    let user: TSUser

    var body: some View {
        HStack(spacing: 14) {
            UserAvatar(user: user, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.title)
                    .font(.title3.weight(.semibold))
                Text(user.loginName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Step: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}
