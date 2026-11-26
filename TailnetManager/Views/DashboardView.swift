import SwiftUI

/// Pages Home pushes onto its own stack. Only Home's own sub-pages live
/// here; tiles open other top-level pages through the sidebar
/// (`app.navigate`), never as a copy inside Home.
private enum HomeDestination: Hashable {
    case peopleHistory
}

/// Home: what needs the admin right now (disks filling up, RAM, servers
/// offline), the servers' RAM/disk/CPU, the everyday People actions, then
/// one strip of four tiles. Refresh is the sidebar's (⌘R).
struct DashboardView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.isLoading && !app.hasLoadedOnce {
                ProgressView("Loading your tailnet…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        AttentionCard()
                        ServersCard()
                        HomePeopleCard()
                        StatStrip(tiles: tiles)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .refreshable { await app.refreshAll() }
            }
        }
        .navigationTitle("Home")
        .navigationDestination(for: HomeDestination.self) { destination in
            switch destination {
            case .peopleHistory: PeopleLogView()
            }
        }
    }

    // MARK: - Tiles

    /// Each tile opens its page (through the sidebar) filtered to exactly
    /// the machines it counts.
    private var tiles: [StatTile] {
        let machines = app.devices
        let online = machines.filter(\.isOnline).count
        let waiting = machines.filter(\.needsApproval).count
        // Same rule as the Machines "Update available" filter, so the number
        // matches what the tile opens.
        let updates = machines.filter { $0.updateAvailable == true }.count
        let people = app.memberUsers.count

        return [
            StatTile("Online", text: "\(online) of \(machines.count)", systemImage: "wifi",
                     help: "Show the machines that are online") {
                app.navigate(to: "machines", devicesFilter: "Online")
            },
            StatTile("Waiting for approval", count: waiting, systemImage: "person.badge.clock",
                     tone: .warning, help: "Show the machines waiting for your approval") {
                app.navigate(to: "machines", devicesFilter: "Needs approval")
            },
            StatTile("Updates", count: updates, systemImage: "arrow.down.circle",
                     tone: .info, help: "Show the machines with a Tailscale update") {
                app.navigate(to: "machines", devicesFilter: "Update available")
            },
            StatTile("People", count: people, systemImage: "person.2",
                     help: "Open People") {
                app.navigate(to: "people")
            },
        ]
    }
}

// MARK: - Needs attention

/// Everything that needs the admin now, most urgent first: disks filling
/// up, RAM, CPU, servers offline or long gone, sign-outs, approvals.
/// Click one to open it.
private struct AttentionCard: View {
    @Environment(AppState.self) private var app
    @State private var showAll = false
    private let shown = 6

    var body: some View {
        let alerts = app.alerts
        let critical = alerts.filter { $0.level == .critical }.count
        let warnings = alerts.count - critical
        let visible = showAll ? alerts : Array(alerts.prefix(shown))

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Needs attention")
                    .font(.headline)
                if critical > 0 { StatusPill(text: "\(critical) critical", tone: .critical) }
                if warnings > 0 { StatusPill(text: "\(warnings) warning\(warnings == 1 ? "" : "s")", tone: .warning) }
                Spacer(minLength: 0)
            }
            .lineLimit(1)

            if alerts.isEmpty {
                Label("All clear — nothing needs you right now", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Tone.good.color)
                    .lineLimit(1)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { alert in
                        AttentionRow(alert: alert, app: app)
                        if alert.id != visible.last?.id { Divider() }
                    }
                }
                if alerts.count > shown {
                    Button(showAll ? "Show fewer" : "Show all \(alerts.count)") { showAll.toggle() }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if critical > 0 {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Tone.critical.color.opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

/// One alert: name, what's wrong, a bar for disk/RAM, and "Remove…" for a
/// server that hasn't been seen for a long time.
private struct AttentionRow: View {
    let alert: AppAlert
    let app: AppState

    private var tone: Tone { alert.level == .critical ? .critical : .warning }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                app.open(alert)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: alert.level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(tone.color)
                        .frame(width: 18)
                    #if os(macOS)
                    Text(alert.title)
                        .fontWeight(.semibold)
                        .frame(minWidth: 80, maxWidth: 180, alignment: .leading)
                    detail
                    #else
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title).fontWeight(.semibold)
                        detail.font(.caption)
                    }
                    #endif
                    Spacer(minLength: 8)
                    if let percent = alert.percent {
                        UsageBar(percent: percent, tint: tone.color, label: "")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(alert.title): \(alert.detail)")

            if alert.offerRemove {
                Button("Remove…", role: .destructive) { app.proposeRemoving(alert) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Take \(alert.title) off the network. You see exactly what happens before anything changes.")
            }
        }
        .padding(.vertical, 7)
    }

    private var detail: some View {
        Text(alert.detail)
            .foregroundStyle(alert.level == .critical ? Tone.critical.color : .secondary)
            .truncationMode(.tail)
    }
}

// MARK: - Servers

/// RAM, disk and CPU of the busiest servers, so trouble shows before it
/// becomes an alert. Numbers come from the server check (Mac only, every
/// 30 minutes); offline servers are under Needs attention instead.
private struct ServersCard: View {
    @Environment(AppState.self) private var app
    private let shown = 5

    private struct Row: Identifiable {
        let id: String
        let name: String
        let stats: ServerStats
        /// The highest of RAM, disk and CPU use, in percent.
        let pressure: Double
    }

    private var rows: [Row] {
        let byID = Dictionary(app.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return app.currentScans.compactMap { scan -> Row? in
            guard let stats = scan.stats, byID[scan.deviceID]?.isOnline != false else { return nil }
            let pressure = max(stats.memUsedPercent ?? 0, stats.fullestDisk?.usedPercent ?? 0,
                               (stats.loadPerCore ?? 0) * 100)
            return Row(id: scan.deviceID, name: byID[scan.deviceID]?.shortName ?? scan.serverName,
                       stats: stats, pressure: pressure)
        }
        .sorted { $0.pressure > $1.pressure }
    }

    var body: some View {
        let all = rows
        #if os(macOS)
        card(all)
        #else
        // Only the Mac can read the servers.
        if !all.isEmpty { card(all) }
        #endif
    }

    private func card(_ all: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Servers")
                    .font(.headline)
                Spacer(minLength: 8)
                checked
                #if os(macOS)
                checkNow
                #endif
            }
            .lineLimit(1)

            if all.isEmpty {
                Text("Refresh to see your servers' RAM, disk and CPU here.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Busiest first")
                        Text("RAM")
                        Text("Disk")
                        Text("CPU")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(all.prefix(shown)) { row in
                        GridRow {
                            Text(row.name)
                                .fontWeight(.medium)
                            ram(row.stats)
                            disk(row.stats)
                            cpu(row.stats)
                        }
                    }
                }
                .lineLimit(1)
                Button("All machines") { app.navigate(to: "machines") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func ram(_ s: ServerStats) -> some View {
        if let p = s.memUsedPercent {
            UsageBar(percent: p, tint: Tone(ram: p).color, label: "\(Int(p.rounded()))%")
                .help(s.memTotalKB.map { "\(Self.size(kb: $0 - (s.memAvailableKB ?? 0))) of \(Self.size(kb: $0)) in use" } ?? "")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func disk(_ s: ServerStats) -> some View {
        if let d = s.fullestDisk {
            UsageBar(percent: d.usedPercent, tint: Tone(disk: d.usedPercent).color,
                     label: "\(Int(d.usedPercent.rounded()))% · \(compactSize(kb: d.availableKB)) free")
                .help("\(d.mount): \(Self.size(kb: d.availableKB)) free of \(Self.size(kb: d.sizeKB))")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func cpu(_ s: ServerStats) -> some View {
        if let perCore = s.loadPerCore {
            UsageBar(percent: perCore * 100, tint: Tone(cpuPerCore: perCore).color,
                     label: "\(Int((perCore * 100).rounded()))%")
                .help("\(s.cpus ?? 0) cores")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    /// "Checked 4 minutes ago", orange once the numbers are out of date.
    @ViewBuilder
    private var checked: some View {
        if app.services.isScanning {
            ProgressView().controlSize(.small)
            Text("Reading servers…").foregroundStyle(.secondary)
        } else if let date = app.serversCheckedAt {
            let outOfDate = Date().timeIntervalSince(date) > MachineLimits.statsOutOfDate
            Text("Checked \(date, format: .relative(presentation: .named))")
                .foregroundStyle(outOfDate ? Tone.warning.color : .secondary)
                .help(outOfDate ? "These numbers are out of date. Refresh to read them again." : "")
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }

    #if os(macOS)
    private var checkNow: some View {
        Button {
            Task { await app.refreshNow() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(app.isRefreshing)
        .help("Reloads everything and reads RAM, disk space and CPU from your servers again. Nothing is changed. ⌘R does the same.")
    }
    #endif

    private static func size(kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .binary)
    }
}

// MARK: - People in / out

/// Home's one-tap way to add or remove someone.
private struct HomePeopleCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("People")
                    .font(.headline)
                Spacer()
                NavigationLink(value: HomeDestination.peopleHistory) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                bigButton("Add someone", systemImage: "person.crop.circle.badge.plus", tint: .green) {
                    app.peopleSheet = .addPerson
                }
                bigButton("Change or remove someone", systemImage: "person.crop.circle.badge.questionmark", tint: .blue) {
                    app.peopleSheet = .pickPerson
                }
            }
            if let last = app.peopleLog.first {
                // One line at every width, so the card keeps one height.
                Text("Last: \(last.kind.label.lowercased()) \(last.name) \(TSDate.relative.localizedString(for: last.date, relativeTo: .now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func bigButton(_ title: String, systemImage: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 30))
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
