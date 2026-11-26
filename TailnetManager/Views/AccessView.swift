import SwiftUI

// MARK: - Tabs

/// The three Access views, picked in the window toolbar.
private enum AccessTab: String, CaseIterable, Identifiable {
    case board, map, problems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: return "Board"
        case .map: return "Map"
        case .problems: return "Problems"
        }
    }

    /// Deep links (`app.accessTabRequest`), old tab names included: the
    /// Machines and People tables are gone, so they land on the Map.
    init?(request raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "board", "groups", "access groups", "basic":
            self = .board
        case "map", "network", "graph", "advanced", "machines", "people", "users":
            self = .map
        case "problems", "surface", "attack surface", "attacksurface", "findings", "security", "lockdown":
            self = .problems
        default:
            return nil
        }
    }
}

// MARK: - Access container

/// Board · Map · Problems, switched in the toolbar. The inspector lives here
/// (at the top of the page) so it never pushes a blank band above the map.
struct AccessView: View {
    @Environment(AppState.self) private var app

    @AppStorage("accessTab") private var tab: AccessTab = .board
    /// Map: the selected node (person login, hub, group or machine node id).
    @State private var mapSelection: String?
    /// Problems: the selected problem's id.
    @State private var problemSelection: String?
    @State private var showingLockdown = false

    var body: some View {
        let app = self.app
        let analysis = app.accessAnalysis
        let network = analysis.map { analysis in
            app.cached("access.network") {
                AccessNetwork(reach: analysis.reachability, members: app.memberUsers, devices: app.manageableDevices)
            }
        }

        VStack(spacing: 0) {
            if let analysis, !analysis.parsedPolicy {
                AccessRulesBanner()
            }
            content(analysis: analysis, network: network)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Access")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .inspector(isPresented: inspectorShown) {
            inspector(analysis: analysis, network: network)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .sheet(isPresented: $showingLockdown) {
            AccessLockdownSheet()
        }
        .refreshable { await app.refreshAll() }
        .onAppear(perform: consumeRequests)
        .onChange(of: app.accessTabRequest) { _, _ in consumeRequests() }
        .onChange(of: app.accessFocusDeviceID) { _, _ in consumeRequests() }
        .onChange(of: tab) { _, _ in
            mapSelection = nil
            problemSelection = nil
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(analysis: AccessAnalysis?, network: AccessNetwork?) -> some View {
        switch tab {
        case .board:
            AccessBoardView()
        case .map:
            if let network {
                AccessNetworkView(network: network, selection: $mapSelection)
            } else {
                waiting
            }
        case .problems:
            if let analysis {
                AccessProblemsView(findings: analysis.findings, selection: $problemSelection)
            } else {
                waiting
            }
        }
    }

    @ViewBuilder
    private var waiting: some View {
        if app.isLoading || !app.hasLoadedOnce {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Nothing to show yet", systemImage: "shield.slash",
                                   description: Text("Refresh to see who can reach what."))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(AccessTab.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Board: put machines in access groups · Map: who can reach what · Problems: risky access")
        }
        if tab == .problems {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingLockdown = true
                } label: {
                    Label("Lockdown…", systemImage: "lock.shield")
                        .labelStyle(.titleAndIcon)
                }
                .help("Turn off routes, approval or keys on several servers at once")
            }
        }
    }

    // MARK: Inspector

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { (tab == .map && mapSelection != nil) || (tab == .problems && problemSelection != nil) },
            set: { shown in
                if !shown {
                    mapSelection = nil
                    problemSelection = nil
                }
            })
    }

    @ViewBuilder
    private func inspector(analysis: AccessAnalysis?, network: AccessNetwork?) -> some View {
        switch tab {
        case .map:
            if let network, let mapSelection {
                AccessNetworkInspector(app: app, network: network, nodeID: mapSelection)
            }
        case .problems:
            if let problemSelection, let finding = analysis?.findings.first(where: { $0.id == problemSelection }) {
                AccessProblemInspector(app: app, finding: finding)
            }
        case .board:
            EmptyView()
        }
    }

    // MARK: Deep links

    /// "Open Access on Problems", or a machine to focus on the Board.
    private func consumeRequests() {
        if let raw = app.accessTabRequest {
            app.accessTabRequest = nil
            if let requested = AccessTab(request: raw) { tab = requested }
        }
        if app.accessFocusDeviceID != nil {
            tab = .board
        }
    }
}

// MARK: - Banner

/// The one Access banner: the access rules couldn't be read. One line; the
/// details are in the tooltip.
private struct AccessRulesBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tone.warning.color)
            Text("Couldn’t read the access rules — showing live machines only")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .background(Tone.warning.color.opacity(0.10))
        .help("The Tailscale policy file couldn’t be loaded, so access groups, the Board and rule-based problems are missing. Refresh to try again.")
    }
}
