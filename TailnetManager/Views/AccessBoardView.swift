import SwiftUI

// MARK: - Shared helpers (file-scope, reused by the support views)

/// Friendly, human display for an access group: "tag:prod" → "Prod".
func accessBoardFriendlyName(_ tag: String) -> String {
    tag.replacingOccurrences(of: "tag:", with: "").capitalized
}

/// The tag set a machine WOULD have once the currently-staged edits apply:
/// current tags ∪ pending adds − pending removes. The board reasons about
/// this everywhere (which column a card belongs in, the zero-group guard,
/// the "first group" badge) so the UI always reflects what Review will do.
func accessBoardEffectiveTags(for device: Device, staged: [StagedChange]) -> Set<String> {
    var tags = Set(device.tags ?? [])
    for change in staged where change.deviceID == device.id {
        switch change.op {
        case .add: tags.insert(change.tag)
        case .remove: tags.remove(change.tag)
        }
    }
    return tags
}

/// Closures the columns/cards call to stage edits — keeps all mutation and
/// the guard rules in AccessBoardView while the subviews stay presentational.
struct AccessBoardActions {
    /// Stage adding `tag` to `device` (guards external, dedupe, cancels an
    /// opposing pending remove).
    var stageAdd: (Device, String) -> Void
    /// Stage removing `tag`. Returns false when it would leave the machine
    /// with zero groups — the caller shakes and shows the inline warning.
    var stageRemove: (Device, String) -> Bool
    /// True when the machine has any pending edit (drives the dashed ghost).
    var isPending: (Device) -> Bool
    /// Effective (post-staging) groups for a machine.
    var effective: (Device) -> Set<String>
}

/// A machine-motion shake for blocked removals (the zero-group guard).
struct AccessBoardShake: GeometryEffect {
    var amount: CGFloat = 6
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: amount * sin(animatableData * .pi * shakes), y: 0))
    }
}

// MARK: - Access Board

/// Drag-and-drop board for organizing machines into access groups. Nothing
/// mutates on drop: every drop/tap appends a `StagedChange`; only "Review"
/// hands the batch to `app.proposeAccessChanges`, which builds the single
/// global review plan. Columns come only from the policy's tags — the board
/// makes the hard rules (no zero-group machine, no re-tagging externals,
/// multi-group by ADD not move) structurally impossible to break.
struct AccessBoardView: View {
    @Environment(AppState.self) private var app

    // Staging (the only local mutation; the write path is Review).
    @State private var staged: [StagedChange] = []

    // Board controls: search is the window toolbar's; the rest is in Filters.
    @State private var searchText = ""
    @AppStorage("accessBoardShowEmptyGroups") private var showEmptyGroups = false
    @State private var guestExpanded = false

    // Mobile tap/menu path.
    @State private var selectMode = false
    @State private var selection: Set<String> = []

    // Focus + one-time explainer.
    @State private var focusedID: String?
    @State private var showTaggingExplainer = false
    @AppStorage("hasSeenTaggingExplainer") private var hasSeenTaggingExplainer = false

    private var boardUnavailable: Bool {
        app.accessAnalysis?.parsedPolicy == false || app.accessGroups.isEmpty
    }

    var body: some View {
        Group {
            if boardUnavailable {
                unavailableState
            } else {
                board
            }
        }
        .searchable(text: $searchText, prompt: "Find a machine")
        #if os(iOS)
        .toolbar { toolbarContent }
        #endif
        .sheet(isPresented: $showTaggingExplainer) {
            AccessBoardTaggingExplainerSheet()
        }
        .onAppear(perform: consumeFocusRequest)
        .onChange(of: app.accessFocusDeviceID) { _, _ in consumeFocusRequest() }
        .onChange(of: staged.isEmpty) { _, isEmpty in
            // The first staged change ever earns the one-time explainer.
            if !isEmpty && !hasSeenTaggingExplainer {
                hasSeenTaggingExplainer = true
                showTaggingExplainer = true
            }
        }
    }

    // MARK: Unavailable (read-only)

    @ViewBuilder
    private var unavailableState: some View {
        if app.accessAnalysis?.parsedPolicy == false {
            // The page banner already says the access rules couldn't be read.
            ContentUnavailableView("No access groups to show", systemImage: "lock.doc")
        } else {
            ContentUnavailableView {
                Label("No access groups yet", systemImage: "square.grid.2x2")
            } description: {
                Text("Add one in your access rules, then refresh.")
            } actions: {
                Link("Open access rules", destination: URL(string: "https://login.tailscale.com/admin/acls")!)
            }
        }
    }

    // MARK: Board

    private var actions: AccessBoardActions {
        AccessBoardActions(
            stageAdd: { stageAdd($0, $1) },
            stageRemove: { stageRemove($0, $1) },
            isPending: { device in staged.contains { $0.deviceID == device.id } },
            effective: { accessBoardEffectiveTags(for: $0, staged: staged) })
    }

    private var board: some View {
        let groups = app.accessGroups
        let byGroup = Dictionary(groups.map { ($0, app.devices(inGroup: $0)) }, uniquingKeysWith: { first, _ in first })
        let visibleGroups = groups.filter { showEmptyGroups || !(byGroup[$0] ?? []).isEmpty }
        let shown = filtered(app.devices).count

        return ListPageLayout {
            FilterBar(groupings: ["groups"],
                      grouping: .constant("groups"),
                      groupingTitle: { $0 },
                      activeFilters: showEmptyGroups ? 1 : 0,
                      onClear: { showEmptyGroups = false },
                      countText: countText(shown, of: app.devices.count, noun: "machines")) {
                Toggle("Show empty access groups", isOn: $showEmptyGroups)
            }
        } content: {
            columns(visibleGroups: visibleGroups, byGroup: byGroup)
        }
        .safeAreaInset(edge: .bottom) { pendingBar }
        .animation(.snappy, value: staged)
        .animation(.snappy, value: app.stagedAccess)
    }

    /// One pending-changes bar, never two: the Board's group moves first;
    /// switch changes from "Manage people" show once those are reviewed.
    @ViewBuilder
    private var pendingBar: some View {
        if !staged.isEmpty {
            AccessBoardStagingBar(
                staged: staged,
                waitingAfter: app.stagedAccess.count,
                onDiscard: discard,
                onReview: review)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !app.stagedAccess.isEmpty {
            AccessStagingBar()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Columns

    private func columns(visibleGroups: [String], byGroup: [String: [Device]]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                AccessBoardPersonalColumn(
                    devices: filtered(app.personalDevices),
                    staged: staged,
                    actions: actions,
                    accessGroups: app.accessGroups,
                    selectMode: selectMode,
                    selection: $selection,
                    focusedID: focusedID,
                    onDropPersonal: handlePersonalDrop)

                ForEach(visibleGroups, id: \.self) { tag in
                    AccessBoardGroupColumn(
                        tag: tag,
                        devices: filtered(byGroup[tag] ?? []),
                        staged: staged,
                        actions: actions,
                        accessGroups: app.accessGroups,
                        selectMode: selectMode,
                        selection: $selection,
                        focusedID: focusedID,
                        onDrop: { handleDrop(ids: $0, into: tag) })
                }

                if !app.guestDevices.isEmpty {
                    AccessBoardGuestColumn(
                        devices: filtered(app.guestDevices),
                        expanded: $guestExpanded)
                }

                AccessBoardNewGroupChip()
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func filtered(_ devices: [Device]) -> [Device] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return devices }
        return devices.filter { $0.shortName.localizedCaseInsensitiveContains(query) }
    }

    // MARK: Toolbar (iPhone select-mode, the no-drag path)

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !boardUnavailable {
            ToolbarItem(placement: .primaryAction) {
                if selectMode {
                    Menu {
                        if selection.isEmpty {
                            Text("Select machines first")
                        } else {
                            ForEach(app.accessGroups, id: \.self) { tag in
                                Button {
                                    moveSelected(into: tag)
                                } label: {
                                    Label(accessBoardFriendlyName(tag), systemImage: "plus")
                                }
                            }
                        }
                    } label: {
                        Text("Move to…")
                    }
                    .disabled(selection.isEmpty)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(selectMode ? "Done" : "Select") {
                    withAnimation(.snappy) {
                        selectMode.toggle()
                        if !selectMode { selection.removeAll() }
                    }
                }
            }
        }
    }
    #endif

    // MARK: Staging (the only mutation on this screen)

    private func stageAdd(_ device: Device, _ tag: String) {
        guard device.isExternal != true else { return }
        // Already a real member — nothing to add.
        if (device.tags ?? []).contains(tag),
           !staged.contains(where: { $0.deviceID == device.id && $0.tag == tag && $0.op == .remove }) {
            return
        }
        // Cancel an opposing pending remove instead of stacking an add.
        if let idx = staged.firstIndex(where: {
            $0.deviceID == device.id && $0.tag == tag && $0.op == .remove
        }) {
            withAnimation(.snappy) { _ = staged.remove(at: idx) }
            return
        }
        // Dedupe adds.
        guard !staged.contains(where: {
            $0.deviceID == device.id && $0.tag == tag && $0.op == .add
        }) else { return }
        withAnimation(.snappy) {
            staged.append(StagedChange(deviceID: device.id, tag: tag, op: .add))
        }
    }

    /// Returns false when removal would leave the machine with zero groups.
    private func stageRemove(_ device: Device, _ tag: String) -> Bool {
        var post = accessBoardEffectiveTags(for: device, staged: staged)
        post.remove(tag)
        guard !post.isEmpty else { return false }

        withAnimation(.snappy) {
            // Drop any pending add for this tag first.
            staged.removeAll { $0.deviceID == device.id && $0.tag == tag }
            // Only a currently-held tag needs an explicit remove op.
            if (device.tags ?? []).contains(tag) {
                staged.append(StagedChange(deviceID: device.id, tag: tag, op: .remove))
            }
        }
        return true
    }

    // MARK: Drop handling

    /// Resolves a dragged payload (device.apiId) to a manageable machine —
    /// externals and unknowns resolve to nil and are rejected.
    private func resolve(_ payloadID: String) -> Device? {
        app.manageableDevices.first { $0.apiId == payloadID || $0.id == payloadID }
    }

    /// Drop onto a group column. Returns nil on success, else a gentle note.
    private func handleDrop(ids: [String], into tag: String) -> String? {
        var addedAny = false
        var already: [String] = []
        for id in ids {
            guard let device = resolve(id) else { continue }
            if accessBoardEffectiveTags(for: device, staged: staged).contains(tag) {
                already.append(device.shortName)
                continue
            }
            stageAdd(device, tag)
            addedAny = true
        }
        if addedAny { return nil }
        if !already.isEmpty { return "Already in \(accessBoardFriendlyName(tag))" }
        return "That machine can’t join this group."
    }

    /// Drop onto Personal. Rejects any already-tagged machine (rule 3).
    private func handlePersonalDrop(ids: [String]) -> String? {
        for id in ids {
            guard let device = resolve(id) else { continue }
            if !accessBoardEffectiveTags(for: device, staged: staged).isEmpty {
                return "Every machine needs at least one access group. A shared machine can’t move back to Personal — remove it from the tailnet in Machines instead."
            }
        }
        return nil
    }

    private func moveSelected(into tag: String) {
        for id in selection {
            guard let device = app.manageableDevices.first(where: { $0.id == id }) else { continue }
            stageAdd(device, tag)
        }
        withAnimation(.snappy) {
            selection.removeAll()
            selectMode = false
        }
    }

    // MARK: Review / discard

    private func discard() {
        withAnimation(.snappy) { staged.removeAll() }
    }

    private func review() {
        app.proposeAccessChanges(staged)
        withAnimation(.snappy) {
            staged.removeAll()
            selection.removeAll()
            selectMode = false
        }
    }

    // MARK: Focus

    private func consumeFocusRequest() {
        guard let id = app.accessFocusDeviceID else { return }
        focusedID = id
        app.accessFocusDeviceID = nil
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            await MainActor.run { withAnimation(.easeOut) { focusedID = nil } }
        }
    }
}
