import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var showPolicyViewer = false
    @State private var showSignOutConfirm = false

    var body: some View {
        Form {
            if app.settingsAvailable && app.settings != nil {
                policiesSection
            }
            policyFileSection
            connectionSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await app.refreshAll() }
        #endif
        .sheet(isPresented: $showPolicyViewer) {
            PolicyViewerView()
        }
        // Sign-out only touches the Keychain, so it keeps a local dialog —
        // the one mutation in the app that isn't a tailnet change.
        .confirmationDialog(
            "Sign out?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                app.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the API token from your Keychain. Your tailnet is not changed — sign in again anytime with a new token.")
        }
    }

    // MARK: Tailnet policies

    private var policiesSection: some View {
        Section {
            Toggle("Approve new machines first", isOn: settingsProposalBinding(
                key: "devicesApprovalOn",
                path: \.devicesApprovalOn,
                name: "approval for new machines",
                onDetail: "New machines must be approved by an admin before they can join the tailnet.",
                offDetail: "New machines join the tailnet immediately, without admin approval."
            ))
            Toggle("Approve new people first", isOn: settingsProposalBinding(
                key: "usersApprovalOn",
                path: \.usersApprovalOn,
                name: "approval for new people",
                onDetail: "New people must be approved by an admin before their machines get access.",
                offDetail: "New people get tailnet access immediately, without admin approval."
            ))
            Toggle("Update Tailscale automatically", isOn: settingsProposalBinding(
                key: "devicesAutoUpdatesOn",
                path: \.devicesAutoUpdatesOn,
                name: "automatic updates",
                onDetail: "Tailscale on every machine updates itself when a new version ships.",
                offDetail: "Machines stay on their installed Tailscale version until someone updates them."
            ))

            Picker("Machine keys expire after", selection: settingsKeyDurationBinding) {
                ForEach(settingsKeyDurationOptions, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
        } header: {
            Text("Tailnet policies")
                .help("Every change is reviewed before it's applied.")
        }
    }

    /// Toggle binding that PROPOSES the change instead of writing through:
    /// flipping the switch opens the global review sheet, and the visible
    /// value only changes after the plan applies and data refreshes.
    private func settingsProposalBinding(key: String,
                                         path: KeyPath<TailnetSettings, Bool?>,
                                         name: String,
                                         onDetail: String,
                                         offDetail: String) -> Binding<Bool> {
        Binding(
            get: { app.settings?[keyPath: path] == true },
            set: { newValue in
                app.proposeSetting(
                    key: key,
                    value: newValue,
                    title: "Turn \(name) \(newValue ? "on" : "off")",
                    detail: newValue ? onDetail : offDetail
                )
            }
        )
    }

    private var settingsKeyDurationOptions: [Int] {
        var options: Set<Int> = [30, 60, 90, 180]
        options.insert(app.settings?.devicesKeyDurationDays ?? 180)
        return options.sorted()
    }

    private var settingsKeyDurationBinding: Binding<Int> {
        Binding(
            get: { app.settings?.devicesKeyDurationDays ?? 180 },
            set: { newValue in
                guard newValue != app.settings?.devicesKeyDurationDays else { return }
                app.proposeSetting(
                    key: "devicesKeyDurationDays",
                    value: newValue,
                    title: "Set key expiry to \(newValue) days",
                    detail: "Machine keys expire after \(newValue) days."
                )
            }
        )
    }

    // MARK: Policy file

    private var policyFileSection: some View {
        Section {
            Button {
                showPolicyViewer = true
            } label: {
                Label("Policy file & backups", systemImage: "doc.text.magnifyingglass")
            }

            if app.settings?.aclsExternallyManagedOn == true {
                HStack {
                    Label("Managed externally", systemImage: "externaldrive.badge.icloud")
                    Spacer()
                    if let link = app.settings?.aclsExternalLink,
                       let url = URL(string: link), url.scheme != nil {
                        Link("Open", destination: url)
                            .font(.callout)
                    } else {
                        Text("GitOps")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Link(destination: URL(string: "https://login.tailscale.com/admin/acls")!) {
                Label("Edit in Tailscale console", systemImage: "arrow.up.forward.app")
            }
        } header: {
            Text("Policy file")
        } footer: {
            Text("The app changes it only after you review the change.")
                .help("You see exactly what changes, Tailscale checks it, it never overwrites someone else's newer edit, and a backup is kept first.")
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Sign-in", value: "API token in Keychain")

            #if os(iOS)
            // The Mac shows this at the bottom of the sidebar.
            LabeledContent("Last updated") {
                RelativeTimeText(date: app.lastRefreshed)
            }
            #endif

            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Sign out…", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: settingsAppVersion)
            Link(destination: URL(string: "https://login.tailscale.com/admin")!) {
                Label("Tailscale admin console", systemImage: "globe")
            }
            Link(destination: URL(string: "https://tailscale.com/api")!) {
                Label("API docs", systemImage: "book")
            }
        } header: {
            Text("About")
                .help("All changes go through the official Tailscale API.")
        }
    }

    private var settingsAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
