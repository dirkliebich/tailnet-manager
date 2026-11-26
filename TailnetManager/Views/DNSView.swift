import SwiftUI

/// Tailnet-wide DNS: MagicDNS (this page is its one home), nameservers and
/// search domains. All changes go through the global review sheet —
/// nothing here mutates the tailnet directly.
struct DNSView: View {
    @Environment(AppState.self) private var app

    // Local drafts; the review sheet applies them.
    @State private var dnsNameserverDraft: [String] = []
    @State private var dnsSearchDraft: [String] = []
    @State private var dnsNewNameserver = ""
    @State private var dnsNewSearchDomain = ""
    @State private var dnsHasSeeded = false

    var body: some View {
        Form {
            if app.dnsPreferences != nil {
                dnsMagicDNSSection
            }
            dnsNameserversSection
            dnsSearchDomainsSection
            dnsMoreSection
        }
        .formStyle(.grouped)
        .navigationTitle("DNS")
        .refreshable { await app.refreshAll() }
        .onAppear {
            if !dnsHasSeeded {
                dnsNameserverDraft = app.dnsNameservers
                dnsSearchDraft = app.dnsSearchPaths
                dnsHasSeeded = true
            }
        }
        .onChange(of: app.dnsNameservers) { _, live in
            dnsNameserverDraft = live
            dnsNewNameserver = ""
        }
        .onChange(of: app.dnsSearchPaths) { _, live in
            dnsSearchDraft = live
            dnsNewSearchDomain = ""
        }
    }

    // MARK: - MagicDNS

    private var dnsMagicDNSSection: some View {
        let isOn = app.dnsPreferences?.magicDNS == true
        return Section {
            LabeledContent("MagicDNS", value: isOn ? "On" : "Off")
                .help("Machines reach each other by name (e.g. server-1) instead of by address. Rules that use names need it.")
            Button(isOn ? "Turn MagicDNS off…" : "Turn MagicDNS on…") {
                app.proposeMagicDNS(!isOn)
            }
        }
    }

    // MARK: - Nameservers

    private var dnsNameserversDirty: Bool { dnsNameserverDraft != app.dnsNameservers }

    private var dnsNameserversSection: some View {
        Section {
            ForEach(Array(dnsNameserverDraft.enumerated()), id: \.offset) { index, server in
                HStack {
                    Text(server)
                        .font(.body.monospaced())
                    Spacer()
                    Button {
                        dnsNameserverDraft.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(server)")
                    .help("Remove")
                }
            }

            HStack {
                TextField("Add nameserver (e.g. 1.1.1.1)", text: $dnsNewNameserver)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(dnsAddNameserver)
                Button(action: dnsAddNameserver) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!Self.dnsLooksValid(dnsNewNameserver))
                .accessibilityLabel("Add nameserver")
                .help("Add")
            }

            if app.dnsNameservers.isEmpty && !dnsNameserversDirty {
                Text("None — machines use their own DNS")
                    .foregroundStyle(.secondary)
            }

            if dnsNameserversDirty {
                dnsReviewRow(reset: {
                    dnsNameserverDraft = app.dnsNameservers
                    dnsNewNameserver = ""
                }, review: {
                    app.proposeNameservers(dnsNameserverDraft)
                })
            }
        } header: {
            Text("Nameservers")
                .help("Used by every machine on the tailnet")
        }
    }

    private func dnsAddNameserver() {
        let trimmed = dnsNewNameserver.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.dnsLooksValid(trimmed), !dnsNameserverDraft.contains(trimmed) else { return }
        dnsNameserverDraft.append(trimmed)
        dnsNewNameserver = ""
    }

    // MARK: - Search domains

    private var dnsSearchDirty: Bool { dnsSearchDraft != app.dnsSearchPaths }

    private var dnsSearchDomainsSection: some View {
        Section {
            ForEach(Array(dnsSearchDraft.enumerated()), id: \.offset) { index, domain in
                HStack {
                    Text(domain)
                        .font(.body.monospaced())
                    Spacer()
                    Button {
                        dnsSearchDraft.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(domain)")
                    .help("Remove")
                }
            }

            HStack {
                TextField("Add search domain (e.g. corp.example.com)", text: $dnsNewSearchDomain)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(dnsAddSearchDomain)
                Button(action: dnsAddSearchDomain) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!Self.dnsLooksValid(dnsNewSearchDomain))
                .accessibilityLabel("Add search domain")
                .help("Add")
            }

            if dnsSearchDirty {
                dnsReviewRow(reset: {
                    dnsSearchDraft = app.dnsSearchPaths
                    dnsNewSearchDomain = ""
                }, review: {
                    app.proposeSearchPaths(dnsSearchDraft)
                })
            }
        } header: {
            Text("Search domains")
                .help("Short names are tried with these domains added")
        }
    }

    private func dnsAddSearchDomain() {
        let trimmed = dnsNewSearchDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.dnsLooksValid(trimmed), !dnsSearchDraft.contains(trimmed) else { return }
        dnsSearchDraft.append(trimmed)
        dnsNewSearchDomain = ""
    }

    // MARK: - More

    private var dnsMoreSection: some View {
        Section("More") {
            Link(destination: URL(string: "https://login.tailscale.com/admin/dns")!) {
                Label("Split DNS & advanced — Tailscale console", systemImage: "arrow.up.forward.app")
            }
        }
    }

    // MARK: - Shared bits

    /// "Review changes… / Reset" row shown while a draft differs from live.
    private func dnsReviewRow(reset: @escaping () -> Void,
                              review: @escaping () -> Void) -> some View {
        HStack {
            Button("Review changes…", action: review)
                .buttonStyle(.borderedProminent)
            Button("Reset", role: .cancel, action: reset)
                .buttonStyle(.bordered)
            Spacer()
        }
    }

    /// Basic sanity check: non-empty and looks like an address or domain.
    private static func dnsLooksValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains(".") || trimmed.contains(":")
    }
}
