import SwiftUI

/// The admin's working checklist: everything on the tailnet that needs a
/// decision right now. Each section appears only when it has items, and
/// every action flows through the universal review sheet (app.propose…).
/// Problems live on Access; Review only links there.
struct ReviewView: View {
    @Environment(AppState.self) private var app

    @State private var selectedUpdateIDs: Set<String> = []
    @State private var selectedStaleIDs: Set<String> = []

    var body: some View {
        let data = ReviewData(app: app)

        List {
            if !data.approvalDevices.isEmpty || !data.approvalPeople.isEmpty {
                approvalSection(data)
            }
            if !data.updates.isEmpty {
                updatesSection(data.updates)
            }
            if !data.expiringDevices.isEmpty || !data.expiringKeys.isEmpty {
                expiringSection(data)
            }
            if !data.stale.isEmpty {
                staleSection(data.stale)
            }
            if !data.invites.isEmpty {
                invitesSection(data.invites)
            }
            if data.problemCount > 0 {
                problemsSection(data.problemCount)
            }
        }
        .overlay {
            if app.hasLoadedOnce && data.isEmpty {
                PageEmptyState.allClear("Nothing needs review right now.")
            } else if !app.hasLoadedOnce {
                ProgressView()
            }
        }
        .navigationTitle("Review")
        .refreshable { await app.refreshAll() }
    }

    // MARK: - Section header

    private func reviewHeader(_ title: String, count: Int) -> some View {
        GroupHeaderLabel(title: title, count: count)
            .textCase(nil)
    }

    // MARK: - 1. Waiting for approval

    private func approvalSection(_ data: ReviewData) -> some View {
        Section {
            ForEach(data.approvalDevices) { device in
                HStack(spacing: 12) {
                    Image(systemName: device.systemImageName)
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.shortName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let owner = device.user, !owner.isEmpty {
                            Text(owner)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    DeviceActionsButton(device: device)
                }
            }
            ForEach(data.approvalPeople) { user in
                HStack(spacing: 12) {
                    UserAvatar(user: user, size: 30)
                    Text(user.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    UserActionsButton(user: user)
                }
            }
        } header: {
            reviewHeader("Waiting for approval", count: data.approvalDevices.count + data.approvalPeople.count)
        }
    }

    // MARK: - 2. Updates

    private func updatesSection(_ updates: [Device]) -> some View {
        let selected = updates.filter { selectedUpdateIDs.contains($0.id) }
        let targets = selected.isEmpty ? updates : selected

        return Section {
            ForEach(updates) { device in
                ReviewSelectableRow(isSelected: selectedUpdateIDs.contains(device.id)) {
                    reviewToggle(&selectedUpdateIDs, device.id)
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.shortName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(device.clientVersion?.isEmpty == false ? device.clientVersion! : "Unknown version")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    StatusDot(isOnline: device.isOnline)
                }
            }

            HStack {
                Button {
                    app.proposeTriggerUpdates(devices: targets)
                } label: {
                    Label(selected.isEmpty ? "Update all…" : "Update \(selected.count) selected…",
                          systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .help("Turns on automatic updates; these machines update at their next check-in.")
                Spacer()
            }
            .padding(.vertical, 2)

            DisclosureGroup("Update by hand") {
                ForEach(reviewUpdateSteps(for: targets)) { step in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.os)
                            .font(.caption.weight(.semibold))
                        Text(step.instruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let command = step.command {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .font(.callout)
            .help("For updating right away, on the machine itself")
        } header: {
            reviewHeader("Updates", count: updates.count)
        }
    }

    /// Per-OS update steps for the given machines.
    private func reviewUpdateSteps(for targets: [Device]) -> [ReviewUpdateStep] {
        let osSet = Set(targets.map { ($0.os ?? "").lowercased() })

        var steps: [ReviewUpdateStep] = []
        if osSet.contains("linux") {
            steps.append(ReviewUpdateStep(
                id: "linux", os: "Linux",
                instruction: "Run on the machine:",
                command: "sudo tailscale update"))
        }
        if osSet.contains("macos") {
            steps.append(ReviewUpdateStep(
                id: "macos", os: "macOS (App Store)",
                instruction: "Update Tailscale in the App Store on the machine.",
                command: nil))
        }
        if osSet.contains("windows") {
            steps.append(ReviewUpdateStep(
                id: "windows", os: "Windows",
                instruction: "Download and run the latest installer from tailscale.com/download.",
                command: nil))
        }
        if osSet.contains("ios") || osSet.contains("tvos") {
            steps.append(ReviewUpdateStep(
                id: "apple-mobile", os: "iOS / tvOS",
                instruction: "Update the Tailscale app in the App Store on the machine.",
                command: nil))
        }
        if osSet.contains("android") {
            steps.append(ReviewUpdateStep(
                id: "android", os: "Android",
                instruction: "Update the Tailscale app in Google Play on the machine.",
                command: nil))
        }
        if steps.isEmpty {
            steps.append(ReviewUpdateStep(
                id: "generic", os: "All platforms",
                instruction: "Update the Tailscale app on each machine.",
                command: nil))
        }
        return steps
    }

    // MARK: - 3. Expiring soon

    private func expiringSection(_ data: ReviewData) -> some View {
        Section {
            ForEach(data.expiringDevices) { device in
                HStack(spacing: 12) {
                    Image(systemName: device.systemImageName)
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.shortName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(reviewExpiryText(for: device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if device.keyExpired {
                        StatusPill(text: "Signed out", tone: .critical)
                    }
                    Spacer(minLength: 8)
                    DeviceActionsButton(device: device)
                }
            }
            ForEach(data.expiringKeys) { key in
                HStack(spacing: 12) {
                    Image(systemName: key.isAPIToken ? "key.viewfinder" : "key.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.description?.isEmpty == false ? key.description! : key.id)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        RelativeTimeText(date: key.expiresDate, prefix: "Expires ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if key.isAuthKey {
                        Button("Revoke…", role: .destructive) {
                            app.proposeRevokeKey(key)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .help(key.isAPIToken ? "API token. Make a replacement in the Tailscale console before it runs out." : "")
            }
        } header: {
            reviewHeader("Expiring soon", count: data.expiringDevices.count + data.expiringKeys.count)
        }
    }

    private func reviewExpiryText(for device: Device) -> String {
        guard let days = device.keyExpiresInDays else { return "Key expiry unknown" }
        if days < 0 { return "Key expired" }
        if days == 0 { return "Key expires today" }
        return "Key expires in \(days) day\(days == 1 ? "" : "s")"
    }

    // MARK: - 4. Not seen in 30 days

    private func staleSection(_ stale: [Device]) -> some View {
        let selected = stale.filter { selectedStaleIDs.contains($0.id) }
        let noun = selected.count == 1 ? "machine" : "machines"

        return Section {
            ForEach(stale) { device in
                ReviewSelectableRow(isSelected: selectedStaleIDs.contains(device.id)) {
                    reviewToggle(&selectedStaleIDs, device.id)
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.shortName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text([device.lastSeenDescription,
                              (device.user?.isEmpty == false ? device.user : nil)]
                            .compactMap { $0 }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
            }
        } header: {
            HStack(spacing: 8) {
                reviewHeader("Not seen in 30 days", count: stale.count)
                Spacer(minLength: 8)
                Button("Expire keys…") {
                    app.propose(.expireKey, on: selected,
                                title: "Expire keys on \(selected.count) \(noun) not seen in 30 days")
                }
                .disabled(selected.isEmpty)
                Button("Remove…", role: .destructive) {
                    app.propose(.remove, on: selected,
                                title: "Remove \(selected.count) \(noun) not seen in 30 days")
                }
                .disabled(selected.isEmpty)
            }
            .buttonStyle(.borderless)
            .lineLimit(1)
        }
    }

    // MARK: - 5. Pending invites

    private func invitesSection(_ invites: [UserInvite]) -> some View {
        Section {
            ForEach(invites) { invite in
                HStack(spacing: 12) {
                    Image(systemName: invite.hasEmail ? "envelope" : "link")
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.hasEmail ? (invite.email ?? "") : "Link invite")
                            .fontWeight(.medium)
                            .lineLimit(1)
                        RelativeTimeText(date: invite.lastSentDate, prefix: "Sent ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if invite.hasEmail {
                        Button("Resend…") {
                            app.proposeResendInvite(invite)
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Revoke…", role: .destructive) {
                        app.proposeRevokeInvite(invite)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            reviewHeader("Pending invites", count: invites.count)
        }
    }

    // MARK: - 6. Problems (link only)

    private func problemsSection(_ count: Int) -> some View {
        Section {
            Button {
                app.navigate(to: "access", accessTab: "problems")
            } label: {
                HStack {
                    Label("Open Problems", systemImage: "shield.lefthalf.filled")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Problems are listed on Access")
        } header: {
            reviewHeader("Problems", count: count)
        }
    }

    // MARK: - Helpers

    private func reviewToggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }
}

// MARK: - Data (built once per render)

private struct ReviewData {
    let approvalDevices: [Device]
    let approvalPeople: [TSUser]
    let updates: [Device]
    let expiringDevices: [Device]
    let expiringKeys: [AuthKey]
    let stale: [Device]
    let invites: [UserInvite]
    let problemCount: Int

    @MainActor
    init(app: AppState) {
        approvalDevices = app.devicesAwaitingApproval
        approvalPeople = app.usersNeedingApproval
        updates = app.devicesWithUpdates
        expiringDevices = app.devicesExpiringSoon
        expiringKeys = app.authKeys.filter(\.expiresSoon)
        stale = app.staleDevices(olderThanDays: 30)
        invites = app.invites
        problemCount = app.accessAnalysis?.findings.count ?? 0
    }

    var isEmpty: Bool {
        approvalDevices.isEmpty && approvalPeople.isEmpty && updates.isEmpty
            && expiringDevices.isEmpty && expiringKeys.isEmpty && stale.isEmpty
            && invites.isEmpty && problemCount == 0
    }
}

// MARK: - Building blocks

private struct ReviewUpdateStep: Identifiable {
    let id: String
    let os: String
    let instruction: String
    let command: String?
}

/// A multi-select row: a leading checkmark circle plus any content; the
/// whole row toggles selection.
private struct ReviewSelectableRow<Content: View>: View {
    let isSelected: Bool
    let toggle: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
                content()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
