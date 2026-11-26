import SwiftUI

// MARK: - Person access section

/// A person's access as simple switches: one per access group, plus any
/// machine they're given individually. Flipping switches only stages;
/// the bar's Review turns them into one reviewed policy edit.
struct PersonAccessSection: View {
    @Environment(AppState.self) private var app
    let user: TSUser

    var body: some View {
        let rows = app.accessRows(for: user)
        let count = app.machinesReachable(by: user)
        Section {
            if rows.isEmpty {
                Text("The access rules aren’t loaded, so access can’t be shown.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                AccessSwitchRow(row: row, login: user.loginName, title: row.title, showsCount: true) {
                    Image(systemName: row.target.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }
            }
            if !rows.isEmpty {
                AccessGiveMachineMenu(user: user, listed: Set(rows.map(\.target)))
            }
        } header: {
            Text("Access · can reach \(count) machine\(count == 1 ? "" : "s")")
        } footer: {
            Text("Flip switches, then Review. Nothing changes until you save. Turning a switch on gives access on all ports.")
        }
    }
}

// MARK: - Switch row

/// One access switch. Shows the pending state until the change is saved;
/// a switch that's on only because of another group is locked on.
struct AccessSwitchRow<Leading: View>: View {
    @Environment(AppState.self) private var app
    let row: AccessRow
    let login: String
    let title: String
    let showsCount: Bool
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        let pending = app.pendingAccess(login: login, target: row.target)
        Toggle(isOn: Binding(
            get: { pending?.grant ?? row.isOn },
            set: { app.setAccess(login: login, target: row.target, on: $0, currentlyOn: row.isOn) }
        )) {
            HStack(spacing: 10) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    if let pending {
                        Text(pending.grant ? "Will get access · all ports" : "Will lose access")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    } else if !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(row.isInherited)
        .help(row.isInherited ? "On because of another group or rule. Turn that one off instead." : "")
    }

    private var caption: String { showsCount ? row.detail : row.note }
}

// MARK: - Give access to one machine

struct AccessGiveMachineMenu: View {
    @Environment(AppState.self) private var app
    let user: TSUser
    let listed: Set<AccessTarget>

    private var candidates: [Device] {
        let reached = app.reachableDeviceIDs(by: user)
        return app.manageableDevices.filter {
            !reached.contains($0.id) && !listed.contains(.machine($0.id)) && !($0.addresses ?? []).isEmpty
        }
    }

    var body: some View {
        let personal = candidates.filter { !$0.isTagged }
        let grouped = candidates.filter(\.isTagged)
        Menu {
            if !personal.isEmpty {
                Section("Personal machines") {
                    ForEach(personal) { device in button(for: device) }
                }
            }
            if !grouped.isEmpty {
                Section("Machines in access groups") {
                    ForEach(grouped) { device in button(for: device) }
                }
            }
        } label: {
            Label("Give access to one machine…", systemImage: "plus.circle")
        }
        .disabled(candidates.isEmpty)
    }

    private func button(for device: Device) -> some View {
        Button(device.shortName) {
            app.setAccess(login: user.loginName, target: .machine(device.id), on: true, currentlyOn: false)
        }
    }
}

// MARK: - Pending changes bar

/// Shown wherever switches can be flipped while any are pending.
struct AccessStagingBar: View {
    @Environment(AppState.self) private var app

    private var lines: [String] {
        app.stagedAccess.prefix(3).map { toggle in
            let who = app.users.first { $0.loginName == toggle.login }?.title ?? toggle.login
            let what: String
            switch toggle.target {
            case .group(let tag): what = AccessEditor.accessGroupName(tag)
            case .machine(let id): what = app.device(id: id)?.shortName ?? "a machine"
            }
            return "\(who) · \(what) \(toggle.grant ? "on" : "off")"
        }
    }

    var body: some View {
        let app = self.app
        let count = app.stagedAccess.count
        AccessPendingBar(
            title: "\(count) access change\(count == 1 ? "" : "s") waiting",
            systemImage: "switch.2",
            lines: lines,
            more: count - lines.count,
            reviewTitle: "Review \(count) change\(count == 1 ? "" : "s")",
            onDiscard: { app.stagedAccess.removeAll() },
            onReview: { app.proposeAccessEdits() })
    }
}

/// The one "changes waiting" bar look (Board moves and access switches):
/// a title, up to three one-line changes, Discard and Review. Its height
/// never depends on the window width. Plain values only.
struct AccessPendingBar: View {
    let title: String
    let systemImage: String
    let lines: [String]
    let more: Int
    var note: String?
    let reviewTitle: String
    let onDiscard: () -> Void
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if more > 0 {
                    Text("+\(more) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            HStack {
                Button("Discard", role: .destructive, action: onDiscard)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button(action: onReview) {
                    Text(reviewTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - Group → people sheet

/// From an Access Board column: everyone in the org with a switch for
/// this group.
struct AccessGroupPeopleSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let tag: String

    var body: some View {
        let machines = app.devices(inGroup: tag).count
        NavigationStack {
            List {
                Section {
                    ForEach(app.memberUsers.sorted { $0.title < $1.title }) { user in
                        if let row = app.accessRow(for: user, target: .group(tag)) {
                            AccessSwitchRow(row: row, login: user.loginName, title: user.title, showsCount: false) {
                                UserAvatar(user: user, size: 26)
                            }
                        }
                    }
                } header: {
                    Text("\(machines) machine\(machines == 1 ? "" : "s") in \(AccessEditor.accessGroupName(tag))")
                } footer: {
                    Text("Changes wait for your review. When you’re done, press Review on the board.")
                }
            }
            .navigationTitle("Who can reach \(AccessEditor.accessGroupName(tag))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }
}

extension AccessTarget {
    var symbol: String {
        switch self {
        case .group: return "square.stack.3d.up"
        case .machine: return "desktopcomputer"
        }
    }
}
