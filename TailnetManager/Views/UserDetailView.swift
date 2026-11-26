import SwiftUI

// MARK: - Person page

struct UserDetailView: View {
    @Environment(AppState.self) private var app

    let userID: String

    /// Live lookup so the screen reflects refreshes; nil after deletion.
    private var user: TSUser? {
        app.users.first { $0.id == userID }
    }

    var body: some View {
        if let user {
            content(for: user)
        } else {
            EmptyStateView(
                systemImage: "person.slash",
                title: "Person not found",
                message: "They’re no longer in your network."
            )
        }
    }

    // MARK: Content

    private func content(for user: TSUser) -> some View {
        let machines = app.devices.filter { $0.user == user.loginName }
        return List {
            Section {
                UserDetailHeader(user: user)
            }

            factsSection(for: user)

            reachSection(for: user)

            machinesSection(machines)

            actionsSection(for: user)
        }
        .safeAreaInset(edge: .bottom) {
            if !app.stagedAccess.isEmpty {
                AccessStagingBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: app.stagedAccess)
        .navigationTitle(user.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Sections

    private func factsSection(for user: TSUser) -> some View {
        let teams = app.teams(of: user).sorted().map(teamDisplayName)
        return Section {
            LabeledContent("Role", value: user.roleLabel)
            LabeledContent("Teams", value: teams.isEmpty ? "None" : teams.joined(separator: ", "))
            if let joined = user.createdDate {
                LabeledContent("Joined", value: joined.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent("Last seen") {
                if user.currentlyConnected == true {
                    HStack(spacing: 5) {
                        StatusDot(isOnline: true)
                        Text("Connected now")
                    }
                } else if let seen = user.lastSeenDate {
                    Text(seen, format: .relative(presentation: .named))
                } else {
                    Text("Never")
                }
            }
        }
    }

    /// Members get access switches; shared-in people only a count (their
    /// access comes from the sharing, not this network's rules).
    @ViewBuilder
    private func reachSection(for user: TSUser) -> some View {
        if !user.isExternal {
            PersonAccessSection(user: user)
        } else {
            let count = app.machinesReachable(by: user)
            Section {
                LabeledContent("Can reach", value: "\(count) machine\(count == 1 ? "" : "s")")
            }
        }
    }

    private func machinesSection(_ machines: [Device]) -> some View {
        Section("Machines") {
            if machines.isEmpty {
                Text("No machines")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(machines) { device in
                    UserDetailMachineRow(device: device)
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(for user: TSUser) -> some View {
        Section {
            if user.needsApproval {
                Button("Approve…") {
                    app.proposeApprove(user)
                }
            }
            Button("Change or remove…") {
                app.peopleSheet = .manage(userID: user.id)
            }
        }
    }
}

// MARK: - Header

private struct UserDetailHeader: View {
    let user: TSUser

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            UserAvatar(user: user, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(user.title)
                    .font(.title3.weight(.semibold))
                Text(user.loginName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                let states = user.unusualStates
                if !states.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(states, id: \.self) { StatusPill(text: $0.text, tone: $0.tone) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Machine row

private struct UserDetailMachineRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(isOnline: device.isOnline)
            Text(device.shortName)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(device.prettyOS)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
