import SwiftUI

// One look for every page (from the UX review): a stats strip, one filter
// bar, three kinds of badge, colors with fixed meanings. Pages use these
// instead of their own tiles, chips and filter rows.
//
// Hard rules baked in:
// - Strips and bars keep ONE height at every width and never insist on a
//   minimum width (they scroll sideways when narrow). A block whose height or
//   minimum width changes with the window width makes AppKit's split view
//   loop and abort.
// - Everything here takes plain values: views inside Table rows get no
//   environment.

// MARK: - Tone (fixed color meanings)

enum Tone: Hashable {
    /// Disk ≥ 90% full, signed out, critical/high problems.
    case critical
    /// Needs approval, expiring soon, disk 85–89%, RAM high, broken websites.
    case warning
    /// Update available, restart needed, Tailscale only, low problems.
    case info
    /// Online dot and "All clear" only.
    case good
    /// Counts, roles, offline, revoked, everything normal.
    case neutral
    /// Access-group chips only.
    case accessGroup

    var color: Color {
        switch self {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        case .good: return .green
        case .neutral: return .secondary
        case .accessGroup: return .purple
        }
    }
}

// MARK: - Badges (three kinds only)

/// Marks something unusual (never a normal value): "Signed out", "4 broken".
struct StatusPill: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.color.opacity(0.15), in: Capsule())
            .foregroundStyle(tone.color)
            .fixedSize()
    }
}

/// Gray number in a capsule; group header rows only.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// An access group ("app", "restricted"); Access pages and inspectors only.
struct AccessGroupChip: View {
    let name: String

    var body: some View {
        Text(name.replacingOccurrences(of: "tag:", with: ""))
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Tone.accessGroup.color.opacity(0.14), in: Capsule())
            .foregroundStyle(Tone.accessGroup.color)
            .fixedSize()
    }
}

// MARK: - Usage bar

/// A small bar with a label: RAM, disk or CPU. Gray when normal, never green.
/// An empty label draws just the bar.
struct UsageBar: View {
    let percent: Double
    let tint: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint).frame(width: max(2, geo.size.width * min(percent, 100) / 100))
                }
            }
            .frame(minWidth: 18, idealWidth: 44, maxWidth: 44, minHeight: 7, maxHeight: 7)
            if !label.isEmpty {
                Text(label).monospacedDigit().lineLimit(1).layoutPriority(1)
            }
        }
    }
}

// MARK: - Stats strip

/// One number on a stats strip. Every tile filters its page (`action`);
/// a number that can't filter shouldn't be a tile.
struct StatTile: Identifiable {
    let id: String
    let label: String
    let value: String
    let systemImage: String
    /// Color used only when `alarming` (never on a zero).
    var tone: Tone = .neutral
    var alarming = false
    var active = false
    var help = ""
    var action: (() -> Void)?

    /// A count: colored by `tone` only when above zero.
    init(_ label: String, count: Int, systemImage: String, tone: Tone = .neutral,
         active: Bool = false, help: String = "", action: (() -> Void)? = nil) {
        self.id = label
        self.label = label
        self.value = "\(count)"
        self.systemImage = systemImage
        self.tone = tone
        self.alarming = count > 0 && tone != .neutral
        self.active = active
        self.help = help
        self.action = action
    }

    /// Free text ("39 of 48"), never colored.
    init(_ label: String, text: String, systemImage: String,
         active: Bool = false, help: String = "", action: (() -> Void)? = nil) {
        self.id = label
        self.label = label
        self.value = text
        self.systemImage = systemImage
        self.active = active
        self.help = help
        self.action = action
    }
}

/// 3–6 tiles of equal width in one 64pt row; fixed 132pt tiles scrolling
/// sideways when the window is narrow (same height either way).
struct StatStrip: View {
    let tiles: [StatTile]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(tiles) { StatTileView(tile: $0).frame(minWidth: 132, maxWidth: 220) }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tiles) { StatTileView(tile: $0).frame(width: 132) }
                }
            }
        }
        .frame(height: 64)
    }
}

private struct StatTileView: View {
    let tile: StatTile

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Label(tile.label, systemImage: tile.systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(tile.value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tile.alarming ? tile.tone.color : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(tile.active ? AnyShapeStyle(Color.blue.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if tile.active {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue, lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))

        if let action = tile.action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .help(tile.help.isEmpty ? (tile.active ? "Show everything" : "Show only these") : tile.help)
        } else {
            content.help(tile.help)
        }
    }
}

// MARK: - Filter bar

/// The one filter row (44pt): Group by · Filters ▾ · Clear · ⟷ · Collapse
/// all · count. Every dropdown, toggle and time range lives inside the
/// Filters menu; search is the window toolbar's search field.
struct FilterBar<Grouping: Hashable, FilterMenu: View>: View {
    let groupings: [Grouping]
    @Binding var grouping: Grouping
    let groupingTitle: (Grouping) -> String
    /// How many filters are on (shown as "Filters · 2").
    let activeFilters: Int
    let onClear: () -> Void
    /// nil when the list isn't grouped.
    var expandAll: (allExpanded: Bool, toggle: () -> Void)?
    let countText: String
    @ViewBuilder let filters: () -> FilterMenu

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
    }

    private var row: some View {
        HStack(spacing: 10) {
            if groupings.count > 1 {
                Picker("Group by", selection: $grouping) {
                    ForEach(groupings, id: \.self) { Text(groupingTitle($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Menu {
                filters()
            } label: {
                Label(activeFilters > 0 ? "Filters · \(activeFilters)" : "Filters",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            .tint(activeFilters > 0 ? .blue : nil)
            if activeFilters > 0 {
                Button("Clear", action: onClear)
            }
            Spacer(minLength: 12)
            if let expandAll {
                Button(expandAll.allExpanded ? "Collapse all" : "Expand all", action: expandAll.toggle)
            }
            Text(countText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .lineLimit(1)
    }
}

// MARK: - Group header row (inside Tables)

/// Disclosure group row: name, count, at most one problem pill. Totals go
/// in the matching columns, not here.
struct GroupHeaderLabel: View {
    let title: String
    let count: Int
    var pill: (text: String, tone: Tone)?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.semibold).lineLimit(1)
            CountBadge(count: count)
            if let pill { StatusPill(text: pill.text, tone: pill.tone) }
        }
    }
}

// MARK: - Page layout

/// Stats strip (optional) · filter bar · divider · content, top-aligned.
struct ListPageLayout<Bar: View, Content: View>: View {
    var stats: [StatTile] = []
    @ViewBuilder let bar: () -> Bar
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if !stats.isEmpty {
                StatStrip(tiles: stats)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            bar()
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Empty states (three kinds)

enum PageEmptyState: View {
    case notScanned(message: String, actionTitle: String, action: () -> Void)
    case nothingMatches(clear: () -> Void)
    case allClear(String)

    var body: some View {
        Group {
            switch self {
            case .notScanned(let message, let title, let action):
                ContentUnavailableView {
                    Label("Not scanned yet", systemImage: "server.rack")
                } description: {
                    Text(message)
                } actions: {
                    Button(title, action: action).buttonStyle(.borderedProminent)
                }
            case .nothingMatches(let clear):
                ContentUnavailableView {
                    Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Change the filters or the search.")
                } actions: {
                    Button("Clear filters", action: clear)
                }
            case .allClear(let message):
                ContentUnavailableView {
                    Label("All clear", systemImage: "checkmark.seal")
                        .foregroundStyle(Tone.good.color)
                } description: {
                    Text(message)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

extension Tone {
    /// Problems: critical/high → red, medium → orange, low → blue, info → gray.
    init(_ severity: FindingSeverity) {
        switch severity {
        case .critical, .high: self = .critical
        case .medium: self = .warning
        case .low: self = .info
        case .info: self = .neutral
        }
    }

    /// Disk bars: orange from 85%, red from 90% (the alert limits).
    init(disk percent: Double) {
        self = percent >= MachineLimits.diskCritical ? .critical
            : percent >= MachineLimits.diskWarning ? .warning : .neutral
    }

    /// RAM bars: orange from 90%.
    init(ram percent: Double) {
        self = percent >= MachineLimits.ramHigh ? .warning : .neutral
    }

    /// CPU bars: orange when every core is busy.
    init(cpuPerCore perCore: Double) {
        self = perCore >= MachineLimits.cpuBusy ? .warning : .neutral
    }
}

/// "1.6 GB", "27 GB", "1.0 TB": short enough for a narrow column.
func compactSize(kb: Int) -> String {
    let gb = Double(kb) / 1_048_576
    if gb >= 1000 { return String(format: "%.1f TB", gb / 1024) }
    if gb >= 10 { return String(format: "%.0f GB", gb) }
    return String(format: "%.1f GB", gb)
}

/// "48 machines" or "12 of 48 machines".
func countText(_ shown: Int, of total: Int, noun: String) -> String {
    shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
}

/// Which groups of a grouped Table are open. Groups start open for lists of
/// 100 rows or fewer and closed otherwise; groups the admin closes stay
/// closed until the grouping or filters change (`reset`).
struct GroupExpansion: Equatable {
    private(set) var open: Set<String> = []
    private var closedByUser: Set<String> = []

    mutating func reset(groups: [String], rows: Int) {
        closedByUser = []
        open = rows <= 100 ? Set(groups) : []
    }

    /// Opens every group except the ones the admin closed (for narrowing:
    /// search or filters show their matches right away).
    mutating func openAll(_ groups: [String]) {
        open = Set(groups).subtracting(closedByUser)
    }

    func isOpen(_ id: String) -> Bool { open.contains(id) }

    mutating func set(_ id: String, open isOpen: Bool) {
        if isOpen { open.insert(id); closedByUser.remove(id) } else { open.remove(id); closedByUser.insert(id) }
    }

    func allOpen(_ groups: [String]) -> Bool { !groups.isEmpty && groups.allSatisfy(open.contains) }

    mutating func toggleAll(_ groups: [String]) {
        if allOpen(groups) {
            closedByUser.formUnion(groups)
            open = []
        } else {
            closedByUser.subtract(groups)
            open.formUnion(groups)
        }
    }
}
