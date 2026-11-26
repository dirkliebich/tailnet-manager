import SwiftUI

// MARK: - Stat card

struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .contentTransition(.numericText())

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Equal-height grid

/// Adaptive columns like `LazyVGrid(.adaptive(minimum:))`, except every
/// card in a row gets the row's full height, so a row of tiles always lines
/// up. Cards fill it with `.frame(maxHeight: .infinity)`.
struct EqualHeightGrid: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat = 12

    private struct Rows {
        var columnWidth: CGFloat
        var members: [[Int]]
        var heights: [CGFloat]
    }

    private func rows(of subviews: Subviews, width proposed: CGFloat) -> Rows {
        let width = proposed.isFinite ? max(proposed, 0) : minimumWidth
        let columns = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var out = Rows(columnWidth: columnWidth, members: [], heights: [])
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = Array(start..<min(start + columns, subviews.count))
            out.members.append(row)
            out.heights.append(row.map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }.max() ?? 0)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth
        let rows = rows(of: subviews, width: width)
        let height = rows.heights.reduce(0, +) + spacing * CGFloat(max(0, rows.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(of: subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in zip(rows.members, rows.heights) {
            for (column, index) in row.enumerated() {
                let x = bounds.minX + CGFloat(column) * (rows.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: rows.columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}

// MARK: - Status

struct StatusDot: View {
    let isOnline: Bool

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 9, height: 9)
            .accessibilityLabel(isOnline ? "Online" : "Offline")
    }
}

struct BadgeLabel: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag.replacingOccurrences(of: "tag:", with: ""))
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.indigo.opacity(0.12), in: Capsule())
            .foregroundStyle(.indigo)
    }
}

// MARK: - People

struct UserAvatar: View {
    let user: TSUser
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let urlString = user.profilePicUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsView
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initialsView: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.2))
            Text(user.initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Misc

struct RelativeTimeText: View {
    let date: Date?
    var prefix: String = ""

    var body: some View {
        if let date {
            Text("\(prefix)\(date, format: .relative(presentation: .named))")
        } else {
            Text("\(prefix)never")
        }
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}

extension Color {
    static func forRole(_ role: String?) -> Color {
        switch role {
        case "owner": return .purple
        case "admin": return .orange
        case "it-admin", "network-admin": return .blue
        case "billing-admin": return .teal
        case "auditor": return .mint
        default: return .secondary
        }
    }

    static func forSeverity(_ severity: FindingSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .info: return .secondary
        }
    }
}

struct SeverityBadge: View {
    let severity: FindingSeverity

    var body: some View {
        BadgeLabel(text: severity.label, tint: .forSeverity(severity))
    }
}

// MARK: - Filter / group controls (shared across every list view)

/// A compact dropdown used for both "Filter" and "Group by" so every list
/// in the app gets the same, obvious control. Bind it to a String-backed
/// enum's rawValue.
struct SelectionMenu: View {
    let title: String
    let systemImage: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(selection == options.first ? title : selection)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// The bar that hosts Filter + Group-by menus above a list. Horizontally
/// scrollable so it never truncates on iPhone.
struct ListControlBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

/// Section header used when a list is grouped, showing the group name and
/// its item count.
struct GroupSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
        }
    }
}

/// Groups items into named buckets, sorted by the given order (or by count
/// then name when no order is supplied). Empty buckets are omitted.
func groupItems<T>(_ items: [T], by key: (T) -> String,
                   order: [String]? = nil) -> [(name: String, items: [T])] {
    let buckets = Dictionary(grouping: items, by: key)
    let names: [String]
    if let order {
        names = order.filter { buckets[$0] != nil }
            + buckets.keys.filter { !order.contains($0) }.sorted()
    } else {
        names = buckets.keys.sorted {
            let a = buckets[$0]?.count ?? 0, b = buckets[$1]?.count ?? 0
            return a == b ? $0 < $1 : a > b
        }
    }
    return names.compactMap { name in
        guard let items = buckets[name], !items.isEmpty else { return nil }
        return (name, items)
    }
}

// MARK: - Quick actions

/// The "⋯" menu for a device, usable from any row or card. Every choice
/// opens the global review sheet (preview → OK → progress) — no change
/// happens from the tap itself. Renders nothing for external devices.
struct DeviceActionsButton: View {
    @Environment(AppState.self) private var app
    let device: Device

    var body: some View {
        if device.isExternal != true {
            Menu {
                if device.needsApproval {
                    Button {
                        app.propose(.approve, on: device)
                    } label: {
                        Label("Approve…", systemImage: "checkmark.circle")
                    }
                } else if app.settings?.devicesApprovalOn == true {
                    Button(role: .destructive) {
                        app.propose(.revokeApproval, on: device)
                    } label: {
                        Label("Revoke approval…", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                if device.enabledRoutes?.isEmpty == false {
                    Button(role: .destructive) {
                        app.propose(.disableRoutes, on: device)
                    } label: {
                        Label("Disable routes…", systemImage: "arrow.triangle.branch")
                    }
                }
                if device.keyExpiryDisabled == true {
                    Button {
                        app.propose(.reenableKeyExpiry, on: device)
                    } label: {
                        Label("Re-enable key expiry…", systemImage: "clock.arrow.circlepath")
                    }
                }
                Button(role: .destructive) {
                    app.propose(.expireKey, on: device)
                } label: {
                    Label("Expire key…", systemImage: "clock.badge.xmark")
                }
                if device.canBeDeleted {
                    Button(role: .destructive) {
                        app.propose(.remove, on: device)
                    } label: {
                        Label("Remove from network…", systemImage: "trash")
                    }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// The "⋯" menu for a person: Approve (when they're waiting) and Change or
/// remove, which opens the one task list for them.
struct UserActionsButton: View {
    @Environment(AppState.self) private var app
    let user: TSUser

    var body: some View {
        if user.needsApproval {
            Menu {
                Button {
                    app.proposeApprove(user)
                } label: {
                    Label("Approve…", systemImage: "checkmark.circle")
                }
                Button {
                    app.peopleSheet = .manage(userID: user.id)
                } label: {
                    Label("Change or remove…", systemImage: "person.crop.circle")
                }
            } label: {
                icon
            }
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            // Only one thing to do — open it straight away.
            Button {
                app.peopleSheet = .manage(userID: user.id)
            } label: {
                icon
            }
            .buttonStyle(.borderless)
            .help("Change or remove…")
        }
    }

    private var icon: some View {
        Label("Change or remove…", systemImage: "ellipsis.circle")
            .labelStyle(.iconOnly)
    }
}
