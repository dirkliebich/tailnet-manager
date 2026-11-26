import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Clipboard

private enum DeviceDetailClipboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

// MARK: - Detail (live lookup)

struct DeviceDetailView: View {
    @Environment(AppState.self) private var app
    let deviceID: String

    var body: some View {
        // Look up the live device on every render — data refreshes underneath.
        if let device = app.devices.first(where: { $0.id == deviceID }) {
            DeviceDetailContent(device: device)
        } else {
            EmptyStateView(
                systemImage: "laptopcomputer.slash",
                title: "Device not found",
                message: "It may have been removed from the tailnet."
            )
        }
    }
}

// MARK: - Content

private struct DeviceDetailContent: View {
    @Environment(AppState.self) private var app
    let device: Device

    @State private var renameText = ""
    @State private var stagedTags: [String]?
    @State private var showHardenSheet = false

    /// Tags as currently staged in the UI (falls back to the live device).
    private var workingTags: [String] {
        stagedTags ?? (device.tags ?? [])
    }

    private var hasStagedTagChanges: Bool {
        guard let stagedTags else { return false }
        return Set(stagedTags) != Set(device.tags ?? [])
    }

    var body: some View {
        Form {
            headerSection
            if device.isExternal == true {
                externalSection
            }
            detailsSection
            if device.isExternal != true {
                hardenSection
                renameSection
                tagsSection
                accessSection
            }
            routesSection
            if device.isExternal != true {
                maintenanceSection
                dangerSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device.shortName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // Quick "⋯" actions — every choice opens the global review sheet.
            DeviceActionsButton(device: device)
        }
        .sheet(isPresented: $showHardenSheet) {
            HardenMachineSheet(device: device)
        }
        .onAppear {
            if renameText.isEmpty { renameText = device.shortName }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: device.systemImageName)
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                Text(device.shortName)
                    .font(.title2.weight(.bold))
                Text(device.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    StatusDot(isOnline: device.isOnline)
                    Text(device.lastSeenDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let user = device.user, !user.isEmpty {
                    Label(user, systemImage: "person")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    if device.needsApproval { BadgeLabel(text: "Approval", tint: .orange) }
                    if device.keyExpired { BadgeLabel(text: "Expired", tint: .red) }
                    if device.updateAvailable == true { BadgeLabel(text: "Update", tint: .blue) }
                    if device.isExternal == true { BadgeLabel(text: "External", tint: .purple) }
                    if device.keyExpiryDisabled == true { BadgeLabel(text: "No expiry", tint: .gray) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: External note

    private var externalSection: some View {
        Section {
            Label {
                Text("Shared from another tailnet — read-only here.")
                    .font(.callout)
            } icon: {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundStyle(.purple)
            }
        }
    }

    // MARK: Details

    private var detailsSection: some View {
        Section("Details") {
            ForEach(device.addresses ?? [], id: \.self) { address in
                HStack {
                    DeviceDetailRow(label: "Address", value: address, monospaced: true)
                    Spacer(minLength: 8)
                    Button {
                        DeviceDetailClipboard.copy(address)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy \(address)")
                }
            }
            if let hostname = device.hostname, !hostname.isEmpty {
                DeviceDetailRow(label: "Hostname", value: hostname, monospaced: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                DeviceDetailRow(label: "OS", value: osValue)
                if device.updateAvailable == true {
                    Text("A client update is available — see Maintenance below.")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            if let created = device.createdDate {
                DeviceDetailRow(label: "Added", value: created.formatted(date: .abbreviated, time: .shortened))
            }
            DeviceDetailRow(label: "Key expires", value: expiresValue)
            if let lockError = device.tailnetLockError, !lockError.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tailnet lock error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lockError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var osValue: String {
        if let version = device.clientVersion, !version.isEmpty {
            return "\(device.prettyOS) · \(version)"
        }
        return device.prettyOS
    }

    private var expiresValue: String {
        if device.keyExpiryDisabled == true { return "Expiry disabled" }
        guard let expires = device.expiresDate else { return "Unknown" }
        let relative = TSDate.relative.localizedString(for: expires, relativeTo: .now)
        return "\(relative) · \(expires.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: Harden

    /// Prominent entry point into the per-machine hardening flow. The sheet
    /// itself routes any mutations through the global review sheet.
    private var hardenSection: some View {
        Section("Harden") {
            let report = app.hardeningReport(for: device)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        showHardenSheet = true
                    } label: {
                        Label("Harden this device…", systemImage: "shield.lefthalf.filled")
                            .font(.body.weight(.semibold))
                    }
                    Spacer(minLength: 8)
                    if !report.steps.isEmpty {
                        SeverityBadge(severity: report.topSeverity)
                    }
                }
                Text(hardenCaption(for: report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hardenCaption(for report: HardeningReport) -> String {
        if report.steps.isEmpty {
            return "No hardening steps recommended right now — open anytime to review."
        }
        let count = report.steps.count
        return "\(count) recommended step\(count == 1 ? "" : "s") for this \(report.os.label) machine."
    }

    // MARK: Rename

    private var renameSection: some View {
        Section("Rename") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Device name", text: $renameText)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Button("Rename…") {
                        app.propose(.rename(trimmedRename), on: device)
                    }
                    .disabled(trimmedRename.isEmpty || trimmedRename == device.shortName)
                }
                Text("The MagicDNS name changes, so existing URLs using the old name will break.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedRename: String {
        renameText.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Access groups (tags)

    private var tagsSection: some View {
        Section("Access groups") {
            if workingTags.isEmpty {
                Text("Personal machine — not in any access group yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workingTags, id: \.self) { tag in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deviceAccessGroupName(tag))
                                .fontWeight(.medium)
                            Text(tag)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        TagChip(tag: tag)
                        Spacer()
                        Button {
                            stagedTags = workingTags.filter { $0 != tag }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(canRemoveTags ? .red : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canRemoveTags)
                        .accessibilityLabel("Remove \(deviceAccessGroupName(tag))")
                    }
                }
                if !canRemoveTags && device.isTagged {
                    Text("Every machine needs at least one access group — at least one must remain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Read-only: who the policy lets reach this machine, unioned
            // across its access groups.
            if !reachablePrincipals.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reachable by")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(reachableBySummary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The Board is the primary way to organize access groups.
            Button {
                app.accessFocusDeviceID = device.id
                app.navigate(to: "access")
            } label: {
                Label("Manage access groups…", systemImage: "square.grid.3x3.topleft.filled")
            }

            if availableTags.isEmpty && app.knownTags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access groups are defined in your policy file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Open policy file", destination: URL(string: "https://login.tailscale.com/admin/acls")!)
                        .font(.caption)
                }
            } else if !availableTags.isEmpty {
                Menu("Add to a group") {
                    ForEach(availableTags, id: \.self) { tag in
                        Button(deviceAccessGroupName(tag)) {
                            stagedTags = workingTags + [tag]
                        }
                    }
                }
            }

            if hasStagedTagChanges {
                Button("Save access groups…") {
                    app.propose(.setTags(workingTags), on: device)
                }
            }

            Text("The first access group makes this a shared machine — it loses its owner identity and auto sign-out.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Friendly, human name for an access group, e.g. "tag:prod" → "Prod".
    private func deviceAccessGroupName(_ tag: String) -> String {
        tag.replacingOccurrences(of: "tag:", with: "").capitalized
    }

    /// The people the policy actually lets reach this machine — from the one
    /// canonical reachability relation, so it matches the map and the "can
    /// reach N" counts exactly, and works even for untagged machines.
    private var reachablePrincipals: [GrantedPrincipal] {
        app.reachers(ofDevice: device)
    }

    /// Up to five principal names, then "+N more".
    private var reachableBySummary: String {
        let names = reachablePrincipals.map(\.label)
        let shown = names.prefix(5)
        var text = shown.joined(separator: ", ")
        if names.count > shown.count {
            text += " +\(names.count - shown.count) more"
        }
        return text
    }

    /// Removal is blocked once the working set is down to one tag on a
    /// device that is (or will be) tagged — the API forbids going to zero.
    private var canRemoveTags: Bool {
        !(workingTags.count == 1 && device.isTagged)
    }

    private var availableTags: [String] {
        app.knownTags.filter { !workingTags.contains($0) }
    }

    // MARK: Access

    private var accessSection: some View {
        Section("Access") {
            VStack(alignment: .leading, spacing: 3) {
                if device.authorized == false {
                    Button("Approve…") {
                        app.propose(.approve, on: device)
                    }
                    Text("The device gains tailnet access immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Revoke approval…", role: .destructive) {
                        app.propose(.revokeApproval, on: device)
                    }
                    Text("The device loses tailnet access until you approve it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if app.settings?.devicesApprovalOn != true {
                    Text("Device approval is off for this tailnet, so new devices join automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if device.keyExpiryDisabled == true {
                    Button("Re-enable key expiry…") {
                        app.propose(.reenableKeyExpiry, on: device)
                    }
                    Text("If the original expiry date has passed, the device must re-authenticate right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Disable key expiry…") {
                        app.propose(.disableKeyExpiry, on: device)
                    }
                    Text("The node key stops expiring — revoke it manually if the device is ever lost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Routes

    /// Routes the device currently has enabled, plus the proposal to shut
    /// them all off (goes through the review sheet). Read-only for external.
    @ViewBuilder
    private var routesSection: some View {
        if let routes = device.enabledRoutes, !routes.isEmpty {
            Section("Routes") {
                ForEach(routes, id: \.self) { route in
                    Text(route)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if device.isExternal != true {
                    VStack(alignment: .leading, spacing: 3) {
                        Button("Disable routes…", role: .destructive) {
                            app.propose(.disableRoutes, on: device)
                        }
                        Text("Traffic routed through this device stops flowing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Maintenance

    private var maintenanceSection: some View {
        Section("Maintenance") {
            if device.updateAvailable == true {
                VStack(alignment: .leading, spacing: 3) {
                    Button("Update…") {
                        app.proposeTriggerUpdates(devices: [device])
                    }
                    Text("A newer Tailscale client is available for this machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Tailscale client is up to date.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Danger zone

    private var dangerSection: some View {
        Section("Danger zone") {
            VStack(alignment: .leading, spacing: 3) {
                Button("Expire key now…", role: .destructive) {
                    app.propose(.expireKey, on: device)
                }
                Text("Connections drop and the device must re-authenticate to rejoin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Button("Remove from tailnet…", role: .destructive) {
                    app.propose(.remove, on: device)
                }
                Text("Disconnects immediately and stays off until added again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Row helper

private struct DeviceDetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
