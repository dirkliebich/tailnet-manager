import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var inactiveSince: Date?

    var body: some View {
        Group {
            if !app.isSignedIn {
                OnboardingView()
            } else if !app.isUnlocked {
                LoginView()
            } else {
                MainNavigationView()
            }
        }
        // Locks again after 15 minutes away (and right away on iPhone when
        // the app goes to the background).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if let since = inactiveSince, Date().timeIntervalSince(since) > 15 * 60 { app.lock() }
                inactiveSince = nil
            case .background:
                #if os(iOS)
                app.lock()
                #endif
                if inactiveSince == nil { inactiveSince = .now }
            default:
                if inactiveSince == nil { inactiveSince = .now }
            }
        }
        .errorAlert(.root)
        // One root sheet: a plan under review, or a people screen — whose
        // own plan then opens on top of it, so Cancel returns to it as left.
        .sheet(item: Binding(
            get: { app.rootSheet },
            set: { if $0 == nil { app.dismissRootSheet() } }
        )) { sheet in
            Group {
                switch sheet {
                case .plan(let plan):
                    ChangePlanSheet(plan: plan)
                case .people(.addPerson):
                    AddPersonSheet()
                case .people(.pickPerson):
                    PersonPickerSheet()
                case .people(.manage(let userID)):
                    ManagePersonSheet(userID: userID)
                }
            }
            .errorAlert(.sheet)
            .sheet(item: Binding(
                get: { app.planOverPeopleSheet ? app.activePlan : nil },
                set: { if $0 == nil { app.dismissPlan() } }
            )) { plan in
                ChangePlanSheet(plan: plan)
                    .errorAlert(.planOverSheet)
            }
        }
    }
}

// MARK: - Errors

/// Where the app-wide "Something went wrong" alert is shown: on whatever is
/// frontmost (an alert can't appear under a sheet on iOS). Exactly one of
/// these is active at a time.
private enum AlertLevel { case root, sheet, planOverSheet }

private extension View {
    func errorAlert(_ level: AlertLevel) -> some View {
        modifier(ErrorAlert(level: level))
    }
}

private struct ErrorAlert: ViewModifier {
    @Environment(AppState.self) private var app
    let level: AlertLevel

    private var isFrontmost: Bool {
        switch level {
        case .root: return app.rootSheet == nil
        case .sheet: return app.rootSheet != nil && !app.planOverPeopleSheet
        case .planOverSheet: return app.planOverPeopleSheet
        }
    }

    func body(content: Content) -> some View {
        content.alert("Something went wrong", isPresented: Binding(
            get: { app.errorMessage != nil && isFrontmost },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

// MARK: - Top-level destinations

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, access, machines, directory, services, activity, people, admin

    var id: String { rawValue }

    /// Services signs in to servers over SSH, which only the Mac can do.
    static var visible: [AppSection] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .services && $0 != .directory }
        #endif
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .access: return "Access"
        case .machines: return "Machines"
        case .directory: return "Directory"
        case .services: return "Services"
        case .activity: return "Activity"
        case .people: return "People"
        case .admin: return "Admin"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .access: return "rectangle.3.group"
        case .machines: return "laptopcomputer"
        case .directory: return "list.bullet.rectangle.portrait"
        case .services: return "server.rack"
        case .activity: return "clock.arrow.circlepath"
        case .people: return "person.2"
        case .admin: return "slider.horizontal.3"
        }
    }
}

/// Screens that live under Admin (and are reachable as deep-links).
enum AdminRoute: String, CaseIterable, Identifiable, Hashable {
    case review, harden, keys, dns, logs, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: return "Review"
        case .harden: return "Harden"
        case .keys: return "Keys"
        case .dns: return "DNS"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .review: return "checklist"
        case .harden: return "lock.shield"
        case .keys: return "key.horizontal"
        case .dns: return "network"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .review: return "Approvals, updates, expiring keys, cleanup"
        case .harden: return "Close exposures with boot-safe commands"
        case .keys: return "Enrollment keys and API tokens"
        case .dns: return "MagicDNS, nameservers, search domains"
        case .logs: return "Configuration audit trail"
        case .settings: return "Tailnet policies and this app"
        }
    }
}

/// Resolves a navigate(to:) string (new names, plus old ones for back-compat)
/// to a top section and, when it points into Admin, the route to push.
enum NavResolution {
    static func resolve(_ target: String) -> (section: AppSection, adminRoute: AdminRoute?) {
        switch target {
        case "home", "dashboard": return (.home, nil)
        case "access": return (.access, nil)
        case "machines", "devices": return (.machines, nil)
        case "services": return (.services, nil)
        case "directory", "urls": return (.directory, nil)
        case "activity": return (.activity, nil)
        case "people", "users": return (.people, nil)
        case "admin": return (.admin, nil)
        default:
            if let route = AdminRoute(rawValue: target) {
                return (.admin, route)
            }
            return (.home, nil)
        }
    }
}

struct MainNavigationView: View {
    @Environment(AppState.self) private var app
    @State private var selection: AppSection? = .home
    @State private var adminPath: [AdminRoute] = []
    #if os(iOS)
    @State private var tab: String = AppSection.home.rawValue
    #endif

    var body: some View {
        navigation
            .task {
                await app.refreshAll()
                #if os(macOS)
                Task { await app.autoScanIfDue() }
                #endif
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await app.refreshAll()
                    #if os(macOS)
                    Task { await app.autoScanIfDue() }
                    #endif
                }
            }
            .onChange(of: app.navigationTarget) { _, target in
                guard let target else { return }
                let resolved = NavResolution.resolve(target)
                #if os(macOS)
                selection = resolved.section
                #else
                tab = resolved.section.rawValue
                #endif
                if resolved.section == .admin {
                    adminPath = resolved.adminRoute.map { [$0] } ?? []
                }
                app.navigationTarget = nil
            }
    }

    @ViewBuilder
    private var navigation: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(AppSection.visible) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
                SidebarAlerts(app: app)
            }
            .safeAreaInset(edge: .bottom) { RefreshStatus(app: app) }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .navigationTitle("Tailnet")
        } detail: {
            detailStack(for: selection ?? .home)
        }
        #else
        TabView(selection: $tab) {
            ForEach(AppSection.visible) { section in
                detailStack(for: section)
                    .tabItem {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .tag(section.rawValue)
            }
        }
        #endif
    }

    /// Each destination gets its own NavigationStack; Admin threads the
    /// pushable admin routes through a bound path so deep-links land.
    @ViewBuilder
    private func detailStack(for section: AppSection) -> some View {
        if section == .admin {
            NavigationStack(path: $adminPath) {
                AdminHubView()
                    .navigationDestination(for: AdminRoute.self) { route in
                        adminDetail(for: route)
                            .toolbar { reportItem(for: section) }
                    }
                    .toolbar { reportItem(for: section) }
            }
        } else {
            NavigationStack {
                topDetail(for: section)
                    .toolbar { reportItem(for: section) }
            }
        }
    }

    /// The same "Report" button on every section, for that section's content.
    private func reportItem(for section: AppSection) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ReportButton(app: app, section: section)
        }
    }

    @ViewBuilder
    private func topDetail(for section: AppSection) -> some View {
        switch section {
        case .home: DashboardView()
        case .access: AccessView()
        case .machines: DevicesView()
        case .directory:
            #if os(macOS)
            DirectoryView()
            #else
            EmptyStateView(systemImage: "list.bullet.rectangle.portrait", title: "Directory is on the Mac",
                           message: "It lists what the Mac app's server scans found.")
            #endif
        case .services:
            #if os(macOS)
            ServicesView()
            #else
            EmptyStateView(systemImage: "server.rack", title: "Services is on the Mac",
                           message: "Scanning servers needs SSH, which runs in the Mac app.")
            #endif
        case .activity:
            #if os(macOS)
            ActivityView()
            #else
            LogsView()
            #endif
        case .people: UsersView()
        case .admin: AdminHubView()
        }
    }

    @ViewBuilder
    private func adminDetail(for route: AdminRoute) -> some View {
        switch route {
        case .review: ReviewView()
        case .harden: HardenView()
        case .keys: KeysView()
        case .dns: DNSView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - Admin hub

/// The single home for the technical screens — grouped so five loose
/// sections become one calm list.
struct AdminHubView: View {
    var body: some View {
        List {
            Section("Checklist") {
                AdminHubRow(route: .review)
            }
            Section("Security") {
                AdminHubRow(route: .harden)
                AdminHubRow(route: .keys)
            }
            Section("Network") {
                AdminHubRow(route: .dns)
            }
            Section("App") {
                AdminHubRow(route: .settings)
            }
        }
        .navigationTitle("Admin")
    }
}

private struct AdminHubRow: View {
    let route: AdminRoute

    var body: some View {
        NavigationLink(value: route) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title)
                    Text(route.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: route.systemImage)
            }
        }
    }
}

// MARK: - Sidebar alerts

/// One line under the sections: how many things need attention ("1 critical
/// · 3 warnings"), visible from every page. The list itself is on Home.
private struct SidebarAlerts: View {
    let app: AppState

    var body: some View {
        let alerts = app.alerts
        if !alerts.isEmpty {
            let critical = alerts.filter { $0.level == .critical }.count
            let warnings = alerts.count - critical
            Section("Needs attention") {
                Button {
                    app.navigate(to: "home")
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: critical > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(critical > 0 ? Tone.critical.color : Tone.warning.color)
                            .frame(width: 16)
                        Text([critical > 0 ? "\(critical) critical" : nil,
                              warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .fontWeight(.semibold)
                            .foregroundStyle(critical > 0 ? Tone.critical.color : .primary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(alerts.prefix(10).map { "\($0.title): \($0.detail)" }.joined(separator: "\n"))
            }
        }
    }
}

// MARK: - Refresh status

/// The one place that says how fresh the data is (⌘R refreshes); replaces
/// per-page Refresh buttons.
private struct RefreshStatus: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 6) {
            if app.isRefreshing {
                ProgressView().controlSize(.mini)
                Text(app.services.isScanning ? "Reading servers…" : "Updating…")
            } else if let date = app.lastRefreshed {
                Text("Updated \(date, format: .relative(presentation: .named))")
            } else {
                Text("Not updated yet")
            }
            Spacer(minLength: 4)
            Button {
                Task { await app.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(app.isRefreshing)
            .help("Refresh everything now, servers included (⌘R)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
