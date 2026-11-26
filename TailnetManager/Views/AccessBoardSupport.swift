import SwiftUI

// MARK: - Column shell

/// Shared column chrome: fixed ~280pt width, a sticky header, and a vertical
/// scroll of cards that fills the board's height.
private struct AccessBoardColumnShell<Header: View, Body: View>: View {
    let accent: Color
    let isTargeted: Bool
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .padding(12)
            Divider()
            ScrollView(.vertical) {
                content()
                    .padding(12)
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isTargeted ? accent : .clear, lineWidth: 2)
                .background(isTargeted ? accent.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// A transient inline note (e.g. "Already in Prod") that fades itself away.
private struct AccessBoardTransientNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tone.warning.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A column title: one line (tooltip has the rest) and the machine count.
private struct AccessBoardColumnTitle: View {
    let title: String
    let count: Int
    var help = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            CountBadge(count: count)
            Spacer(minLength: 0)
        }
        .help(help.isEmpty ? title : help)
    }
}

// MARK: - Group column

/// One access group. Header shows who the policy grants it to (with a
/// "Manage people" switch list), then the machines that hold the group.
/// A drop stages an ADD.
struct AccessBoardGroupColumn: View {
    @Environment(AppState.self) private var app
    let tag: String
    let devices: [Device]
    let staged: [StagedChange]
    let actions: AccessBoardActions
    let accessGroups: [String]
    let selectMode: Bool
    @Binding var selection: Set<String>
    let focusedID: String?
    let onDrop: ([String]) -> String?

    @State private var isTargeted = false
    @State private var note: String?

    var body: some View {
        AccessBoardColumnShell(accent: .accentColor, isTargeted: isTargeted) {
            header
        } content: {
            LazyVStack(spacing: 10) {
                if let note {
                    AccessBoardTransientNote(text: note)
                }
                if devices.isEmpty && note == nil {
                    Text("Drag a machine here to add it to \(accessBoardFriendlyName(tag)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(devices) { device in
                    AccessBoardMachineCard(
                        device: device,
                        columnTag: tag,
                        staged: staged,
                        actions: actions,
                        accessGroups: accessGroups,
                        selectMode: selectMode,
                        selection: $selection,
                        isFocused: focusedID == device.id)
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            let rejection = onDrop(items)
            if let rejection { flash(rejection) }
            return rejection == nil
        } isTargeted: { targeted in
            withAnimation(.snappy) { isTargeted = targeted }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccessBoardColumnTitle(
                title: accessBoardFriendlyName(tag),
                count: devices.count,
                help: "Access group \(accessBoardFriendlyName(tag)) (\(tag)) · \(devices.count) machine\(devices.count == 1 ? "" : "s")")
            AccessBoardGrantedPeopleRow(tag: tag)
        }
    }

    private func flash(_ message: String) {
        withAnimation(.snappy) { note = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            await MainActor.run { withAnimation(.easeOut) { note = nil } }
        }
    }
}

// MARK: - Granted people row

/// The people/teams the policy grants this group, and the way in to
/// change it: "Manage people" opens a switch per person.
struct AccessBoardGrantedPeopleRow: View {
    @Environment(AppState.self) private var app
    let tag: String

    @State private var showPeople = false

    private var principals: [GrantedPrincipal] { app.grantedPrincipals(forGroup: tag) }

    var body: some View {
        let people = principals.filter { $0.kind == .person }
        let others = principals.filter { $0.kind != .person }.map(\.label)
        VStack(alignment: .leading, spacing: 5) {
            if principals.isEmpty {
                Text("No one has access yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                // Who the access rules give this group to: faces, then
                // teams / everyone as plain text.
                HStack(spacing: 4) {
                    ForEach(people.prefix(4)) { principal in
                        personGlyph(principal)
                    }
                    if people.count > 4 {
                        Text("+\(people.count - 4)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if !others.isEmpty {
                        Text(others.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, people.isEmpty ? 0 : 4)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 24)
                .help(principals.map(\.label).joined(separator: ", "))
            }
            Button {
                showPeople = true
            } label: {
                Label("Manage people", systemImage: "person.2.badge.gearshape")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showPeople) {
                AccessGroupPeopleSheet(tag: tag)
            }
        }
    }

    @ViewBuilder
    private func personGlyph(_ principal: GrantedPrincipal) -> some View {
        if let login = principal.loginName,
           let user = app.users.first(where: { $0.loginName == login }) {
            UserAvatar(user: user, size: 24)
        } else {
            initials(principal.label)
        }
    }

    private func initials(_ label: String) -> some View {
        let letters = label.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }.joined().uppercased()
        return ZStack {
            Circle().fill(.quaternary)
            Text(letters.isEmpty ? "?" : letters)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Personal column

/// Untagged, user-owned machines. The board's only first-group source
/// (these cards are draggable). As a drop target it REJECTS already-tagged
/// machines, because a shared machine can never go back to Personal.
struct AccessBoardPersonalColumn: View {
    let devices: [Device]
    let staged: [StagedChange]
    let actions: AccessBoardActions
    let accessGroups: [String]
    let selectMode: Bool
    @Binding var selection: Set<String>
    let focusedID: String?
    let onDropPersonal: ([String]) -> String?

    @State private var isTargeted = false
    @State private var note: String?

    var body: some View {
        AccessBoardColumnShell(accent: .secondary, isTargeted: isTargeted) {
            AccessBoardColumnTitle(
                title: "Personal",
                count: devices.count,
                help: "Machines owned by one person and in no access group")
        } content: {
            LazyVStack(spacing: 10) {
                if let note {
                    AccessBoardTransientNote(text: note)
                }
                if devices.isEmpty && note == nil {
                    Text("No personal machines.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(devices) { device in
                    AccessBoardMachineCard(
                        device: device,
                        columnTag: nil,
                        staged: staged,
                        actions: actions,
                        accessGroups: accessGroups,
                        selectMode: selectMode,
                        selection: $selection,
                        isFocused: focusedID == device.id)
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            if let rejection = onDropPersonal(items) {
                flash(rejection)
                return false
            }
            return false // Untagged→Personal is a no-op; nothing to stage.
        } isTargeted: { targeted in
            withAnimation(.snappy) { isTargeted = targeted }
        }
    }

    private func flash(_ message: String) {
        withAnimation(.snappy) { note = message }
        Task {
            try? await Task.sleep(nanoseconds: 3_400_000_000)
            await MainActor.run { withAnimation(.easeOut) { note = nil } }
        }
    }
}

// MARK: - Shared-in column

/// Shared-in (external) machines. Always locked: dimmed, non-draggable, and
/// rejected by every drop handler. Collapsed by default.
struct AccessBoardGuestColumn: View {
    let devices: [Device]
    @Binding var expanded: Bool

    @State private var explain: Device?

    var body: some View {
        AccessBoardColumnShell(accent: .secondary, isTargeted: false) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    AccessBoardColumnTitle(
                        title: "Shared in",
                        count: devices.count,
                        help: "Machines shared in from other tailnets; they can’t be put in access groups here")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } content: {
            if expanded {
                LazyVStack(spacing: 10) {
                    ForEach(devices) { device in
                        guestCard(device)
                    }
                }
            } else {
                Text("From other tailnets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .popover(item: $explain) { device in
            Text("\(device.shortName) is shared in from another tailnet. You can’t add it to an access group or change it here; manage the share in the Tailscale admin console.")
                .font(.callout)
                .frame(maxWidth: 260)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }

    private func guestCard(_ device: Device) -> some View {
        Button {
            explain = device
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StatusDot(isOnline: device.isOnline)
                    Text(device.shortName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Image(systemName: device.systemImageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(device.shortName)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1)
            }
            .opacity(0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - New-group explainer chip

/// The disabled "+ New group" affordance — an explainer, never an action.
struct AccessBoardNewGroupChip: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.square.dashed")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("New access group")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding()
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.quaternary)
        }
        .help("Access groups are made in your access rules (the Tailscale policy file); this app can’t create them.")
        .accessibilityLabel("New access group — disabled. Access groups are made in your access rules.")
    }
}

// MARK: - Machine card

/// One machine, shown in every group column it holds. Chips are its
/// effective groups (each removable except the last, which locks — a
/// machine can never reach zero groups). Draggable for manageable machines;
/// the ⋯ menu and select-mode checkbox provide the no-drag paths.
struct AccessBoardMachineCard: View {
    @Environment(AppState.self) private var app
    let device: Device
    /// The group whose column this card is rendered in (nil in Personal).
    let columnTag: String?
    let staged: [StagedChange]
    let actions: AccessBoardActions
    let accessGroups: [String]
    let selectMode: Bool
    @Binding var selection: Set<String>
    let isFocused: Bool

    @State private var shake: CGFloat = 0
    @State private var blockedNote = false

    private var effective: Set<String> { actions.effective(device) }
    private var sortedGroups: [String] { effective.sorted() }
    private var isPending: Bool { actions.isPending(device) }
    private var isSelected: Bool { selection.contains(device.id) }

    /// A pending FIRST group: an add onto a machine that has no tags today.
    private var pendingFirstGroup: Bool {
        !device.isTagged && !effective.isEmpty &&
        staged.contains { $0.deviceID == device.id && $0.op == .add }
    }

    /// Groups held beyond this column's group (drives the "also in N" note).
    private var alsoInCount: Int {
        guard let columnTag else { return 0 }
        return effective.subtracting([columnTag]).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            chipRow

            if alsoInCount > 0 {
                Text("Also in \(alsoInCount) other group\(alsoInCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if pendingFirstGroup {
                StatusPill(text: "Becomes shared", tone: .warning)
                    .help("Becomes a shared machine: it loses its owner and auto sign-out.")
            }

            if blockedNote {
                Text("Every machine needs at least one access group. Add it to another group first, or remove it from the tailnet in Machines.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay { cardBorder }
        .modifier(AccessBoardShake(animatableData: shake))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectMode { toggleSelection() }
        }
        .modifier(AccessBoardDraggableIfManageable(device: device, enabled: !selectMode))
    }

    // MARK: Rows

    private var titleRow: some View {
        HStack(spacing: 8) {
            if selectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            StatusDot(isOnline: device.isOnline)
            Text(device.shortName)
                .fontWeight(.medium)
                .lineLimit(1)
                .help(device.shortName)
            Image(systemName: device.systemImageName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if !selectMode {
                groupMenu
            }
        }
    }

    private var chipRow: some View {
        FlowingChips(groups: sortedGroups) { tag in
            let isLast = sortedGroups.count == 1
            AccessBoardTagChip(
                tag: tag,
                locked: isLast,
                staged: staged.contains { $0.deviceID == device.id && $0.tag == tag },
                onRemove: isLast ? nil : { attemptRemove(tag) })
        }
    }

    private var groupMenu: some View {
        Menu {
            let addable = accessGroups.filter { !effective.contains($0) }.sorted()
            if !addable.isEmpty {
                Menu("Add to group") {
                    ForEach(addable, id: \.self) { tag in
                        Button(accessBoardFriendlyName(tag)) { actions.stageAdd(device, tag) }
                    }
                }
            }
            let removable = effective.count > 1 ? sortedGroups : []
            if !removable.isEmpty {
                Menu("Remove from group") {
                    ForEach(removable, id: \.self) { tag in
                        Button(role: .destructive) {
                            _ = actions.stageRemove(device, tag)
                        } label: {
                            Text(accessBoardFriendlyName(tag))
                        }
                    }
                }
            }
            if addable.isEmpty && removable.isEmpty {
                Text("No group changes available")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Styling

    private var cardBackground: some ShapeStyle {
        isFocused ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                  : AnyShapeStyle(.background.opacity(0.5))
    }

    @ViewBuilder
    private var cardBorder: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if isPending {
            shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.accentColor)
        } else if isFocused {
            shape.stroke(Color.accentColor, lineWidth: 1.5)
        } else {
            shape.stroke(.quaternary, lineWidth: 1)
        }
    }

    // MARK: Actions

    private func toggleSelection() {
        withAnimation(.snappy) {
            if isSelected { selection.remove(device.id) } else { selection.insert(device.id) }
        }
    }

    private func attemptRemove(_ tag: String) {
        if actions.stageRemove(device, tag) { return }
        // Blocked: shake + show the friendly zero-group warning briefly.
        withAnimation(.snappy) { blockedNote = true }
        withAnimation(.default) { shake += 1 }
        Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            await MainActor.run { withAnimation(.easeOut) { blockedNote = false } }
        }
    }
}

/// Applies `.draggable` only to manageable machines (guests never drag), and
/// only when not in select mode. The payload is the machine's apiId.
private struct AccessBoardDraggableIfManageable: ViewModifier {
    let device: Device
    let enabled: Bool

    func body(content: Content) -> some View {
        if device.isExternal != true && enabled {
            content.draggable(device.apiId) {
                Label(device.shortName, systemImage: device.systemImageName)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content
        }
    }
}

// MARK: - Tag chip (removable / locked)

/// An access-group chip on a card (purple, like every access group). Shows
/// "×" to stage removal, a lock when it's the machine's last group, and a
/// dashed outline while its change is staged.
struct AccessBoardTagChip: View {
    let tag: String
    let locked: Bool
    let staged: Bool
    /// nil = not removable (last group).
    let onRemove: (() -> Void)?

    private var color: Color { Tone.accessGroup.color }

    var body: some View {
        HStack(spacing: 4) {
            Text(accessBoardFriendlyName(tag))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 8))
                    .help("A machine’s last access group can’t be removed")
            } else if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Remove from \(accessBoardFriendlyName(tag))")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(staged ? 0.24 : 0.14), in: Capsule())
        .foregroundStyle(color)
        .overlay {
            if staged {
                Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(color)
            }
        }
    }
}

/// A tiny wrapping layout for the chips (avoids a fixed-height HStack).
private struct FlowingChips<Chip: View>: View {
    let groups: [String]
    @ViewBuilder let chip: (String) -> Chip

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(groups, id: \.self) { chip($0) }
        }
    }
}

/// Minimal flow layout: lays children left-to-right, wrapping as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGFloat]] = [[]]
        var x: CGFloat = 0
        var rowHeights: [CGFloat] = [0]
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                rows.append([]); rowHeights.append(0); x = 0
            }
            rows[rows.count - 1].append(size.width)
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            x += size.width + spacing
        }
        let height = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Staging bar

/// The bottom bar summarizing pending Board edits. "Discard" clears them;
/// "Review" hands the batch to the global review sheet via
/// proposeAccessChanges. Same look as the switches' bar (AccessPendingBar).
struct AccessBoardStagingBar: View {
    @Environment(AppState.self) private var app
    let staged: [StagedChange]
    /// Switch changes ("Manage people") queued behind these.
    let waitingAfter: Int
    let onDiscard: () -> Void
    let onReview: () -> Void

    private var lines: [String] {
        staged.prefix(3).map { change in
            let name = app.device(id: change.deviceID)?.shortName ?? "machine"
            let group = accessBoardFriendlyName(change.tag)
            return change.op == .add ? "\(name) → \(group)" : "\(name) ✕ \(group)"
        }
    }

    var body: some View {
        let count = staged.count
        AccessPendingBar(
            title: "\(count) access-group change\(count == 1 ? "" : "s") waiting",
            systemImage: "tray.full",
            lines: lines,
            more: count - lines.count,
            note: waitingAfter > 0
                ? "Then \(waitingAfter) people-access change\(waitingAfter == 1 ? "" : "s")"
                : nil,
            reviewTitle: "Review \(count) change\(count == 1 ? "" : "s")",
            onDiscard: onDiscard,
            onReview: onReview)
    }
}

// MARK: - Tagging explainer (one-time)

/// Shown the first time any change is staged. Plain-language warning that
/// handing a machine to a group changes what it is.
struct AccessBoardTaggingExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.badge.gearshape")
                            .font(.largeTitle)
                            .foregroundStyle(Color.accentColor)
                        Text("Adding a machine to a group changes what it is")
                            .font(.title3.weight(.semibold))
                    }

                    explainer("It stops being personal",
                              "A machine in an access group is a shared machine. It no longer belongs to one person — it belongs to whoever your access rules give the group to.",
                              "person.crop.circle.badge.xmark")
                    explainer("It loses its owner and auto sign-out",
                              "The person’s identity is removed and the key stops expiring automatically. Revoke it manually if the machine is ever lost.",
                              "clock.badge.xmark")
                    explainer("It can’t simply go back",
                              "A shared machine can’t return to Personal here. It can hold several groups at once — adding one keeps the others.",
                              "arrow.uturn.left.circle")

                    Text("Nothing happens yet. You’ll see every change and confirm it on the Review screen before anything is written.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Before you share a machine")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Got it").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
        #endif
    }

    private func explainer(_ title: String, _ body: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
