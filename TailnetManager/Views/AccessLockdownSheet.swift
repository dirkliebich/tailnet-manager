import SwiftUI

// MARK: - Lockdown sheet

/// Batch mitigation for servers: pick tagged devices and routers, choose
/// which API-level mitigations to apply, then hand off to the global review
/// sheet — it lists every per-device operation and runs them with live
/// progress. Policy-caused exposure still needs a console edit — this app
/// never touches the policy.
struct AccessLockdownSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var disableRoutes = false
    @State private var revokeApproval = false
    @State private var expireKeys = false

    // MARK: Derived

    private var candidates: [Device] {
        app.devices
            .filter { $0.isTagged || $0.enabledRoutes?.isEmpty == false }
            .sorted { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
    }

    private var selectedDevices: [Device] {
        candidates.filter { selected.contains($0.id) }
    }

    private var mitigationChosen: Bool {
        disableRoutes || revokeApproval || expireKeys
    }

    private var canApply: Bool {
        !selected.isEmpty && mitigationChosen
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            List {
                serversSection
                mitigationsSection
                applySection
            }
            .navigationTitle("Lockdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 540)
        #endif
    }

    // MARK: Servers

    @ViewBuilder
    private var serversSection: some View {
        Section {
            if candidates.isEmpty {
                Text("No servers or routing machines to lock down.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { device in
                    AccessLockdownServerRow(
                        device: device,
                        isSelected: selected.contains(device.id)
                    ) {
                        if selected.contains(device.id) {
                            selected.remove(device.id)
                        } else {
                            selected.insert(device.id)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Servers")
                Spacer()
                if !candidates.isEmpty {
                    Button(selected.count == candidates.count ? "Deselect" : "Select all") {
                        if selected.count == candidates.count {
                            selected.removeAll()
                        } else {
                            selected = Set(candidates.map(\.id))
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        } footer: {
            Text("Machines in an access group or with routes turned on.")
        }
    }

    // MARK: Mitigations

    private var mitigationsSection: some View {
        Section("Mitigations") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Turn off routes (subnet and exit node)", isOn: $disableRoutes)
                Text("The machine stops passing LAN or internet traffic for the tailnet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Revoke approval", isOn: $revokeApproval)
                Text("When machine approval is on, the machine is cut off until approved again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Expire keys now", isOn: $expireKeys)
                Text("Every selected machine must sign in again right away; connections drop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Apply

    private var applySection: some View {
        Section {
            Button {
                app.proposeLockdown(devices: selectedDevices,
                                    expireKeys: expireKeys,
                                    revokeApproval: revokeApproval,
                                    disableRoutes: disableRoutes)
                dismiss()
            } label: {
                Text("Review lockdown for \(selected.count) server\(selected.count == 1 ? "" : "s")…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!canApply)
        } footer: {
            Text("You’ll review every change before anything runs. A port opened by an access rule (for example SSH on 22) needs an access-rule edit; see Problems.")
        }
    }
}

// MARK: - Server row

private struct AccessLockdownServerRow: View {
    let device: Device
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Image(systemName: device.systemImageName)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.shortName)
                        .font(.body)
                        .lineLimit(1)
                        .help(device.shortName)
                    if device.isTagged {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(device.tags ?? [], id: \.self) { tag in
                                    AccessGroupChip(name: tag)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                if device.enabledRoutes?.isEmpty == false {
                    Text("Routes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Routes are turned on for this machine")
                }
                StatusDot(isOnline: device.isOnline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
