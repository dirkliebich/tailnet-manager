import SwiftUI

// MARK: - Access network (the Map tab)

/// Who can reach what, as a force-directed network that always fits the
/// window: every machine is a dot orbiting the group of machines the same
/// people can reach; people link to those groups, and one "Everyone" hub
/// stands in for the whole org. Hover to trace, click for the inspector
/// (owned by AccessView), pinch / drag / ± to zoom and pan. One neutral
/// color throughout; the legend is behind "?".
struct AccessNetworkView: View {
    @Environment(AppState.self) private var app

    let network: AccessNetwork
    /// Node id (person login, hub id, group id or machine node id).
    @Binding var selection: String?

    @State private var hovered: String?
    @State private var zoom: Double = 1
    @State private var pan: CGSize = .zero
    @State private var showLegend = false
    @GestureState private var livePan: CGSize = .zero
    @GestureState private var liveZoom: Double = 1
    @State private var cache = AccessNetworkLayoutCache()

    var body: some View {
        let positions = cache.positions(for: network)
        GeometryReader { geo in
            let viewport = AccessNetworkViewport(positions: positions, network: network, size: geo.size,
                                                 zoom: zoom * liveZoom,
                                                 pan: CGSize(width: pan.width + livePan.width,
                                                             height: pan.height + livePan.height))
            let scene = AccessNetworkScene(network: network, positions: positions, viewport: viewport,
                                           focus: AccessNetworkFocus(hovered ?? selection, in: network),
                                           selection: selection)
            ZStack {
                Canvas { context, _ in scene.draw(in: context) }

                ForEach(network.people) { person in
                    if let point = viewport.point(positions[person.id]) {
                        AccessNetworkAvatar(user: app.users.first { $0.loginName == person.id },
                                            size: 28 * viewport.nodeScale,
                                            isSelected: selection == person.id)
                            .position(point)
                            .opacity(scene.isDimmed(person.id) ? 0.18 : 1)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered = scene.hit(location)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                let hit = scene.hit(value.location)
                selection = hit == selection ? nil : hit
            })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .updating($livePan) { value, state, _ in state = value.translation }
                .onEnded { value in
                    pan.width += value.translation.width
                    pan.height += value.translation.height
                })
            .simultaneousGesture(MagnifyGesture()
                .updating($liveZoom) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = Self.clampZoom(zoom * value.magnification) })
            .overlay(alignment: .bottomTrailing) { controls.padding(12) }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: selection)
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Button { showLegend.toggle() } label: {
                Image(systemName: "questionmark").frame(width: 30, height: 28)
            }
            .help("What the map shows")
            .popover(isPresented: $showLegend, arrowEdge: .leading) {
                AccessNetworkLegend()
                    .presentationCompactAdaptation(.popover)
            }
            Divider().frame(width: 30)
            Button { withAnimation(.snappy) { zoom = Self.clampZoom(zoom * 1.3) } } label: {
                Image(systemName: "plus").frame(width: 30, height: 28)
            }
            .help("Zoom in")
            Divider().frame(width: 30)
            Button { withAnimation(.snappy) { zoom = Self.clampZoom(zoom / 1.3) } } label: {
                Image(systemName: "minus").frame(width: 30, height: 28)
            }
            .help("Zoom out")
            Divider().frame(width: 30)
            Button { withAnimation(.snappy) { zoom = 1; pan = .zero } } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 30, height: 28)
            }
            .help("Fit everything")
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }

    private static func clampZoom(_ value: Double) -> Double { min(max(value, 0.4), 6) }
}

// MARK: - Layout cache

/// Runs the force layout only when the graph itself changes — never on
/// resize, hover or zoom — so the view stays instant.
final class AccessNetworkLayoutCache {
    private var key = ""
    private var positions: [String: CGPoint] = [:]

    func positions(for network: AccessNetwork) -> [String: CGPoint] {
        let input = network.layoutInput()
        let signature = input.nodes.map(\.id).joined(separator: ",")
            + "|" + input.links.map { "\($0.a)>\($0.b)" }.joined(separator: ",")
        if signature != key {
            key = signature
            positions = AccessNetworkLayout.layout(nodes: input.nodes, links: input.links)
                .mapValues { CGPoint(x: $0.x, y: $0.y) }
        }
        return positions
    }
}

// MARK: - Viewport

/// Maps layout coordinates to the view: fit everything (with room for
/// labels), then apply the user's zoom around the centre and pan.
struct AccessNetworkViewport {
    let scale: Double
    let offset: CGPoint
    /// How much node glyphs grow/shrink with zoom (damped so dots stay dots).
    let nodeScale: Double

    init(positions: [String: CGPoint], network: AccessNetwork, size: CGSize, zoom: Double, pan: CGSize) {
        let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
        // Room for the labels, which sit below a group's whole orbit of
        // machines — otherwise the lowest group is cut off.
        let orbit = network.groups.map { group -> Double in
            guard let c = positions[group.id] else { return 0 }
            return group.deviceIDs
                .compactMap { positions[AccessNetwork.machineNodeID($0)] }
                .map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? 0
        }.max() ?? 0
        let minX = (xs.min() ?? 0) - 90, maxX = (xs.max() ?? 0) + 90
        let minY = (ys.min() ?? 0) - 40, maxY = (ys.max() ?? 0) + max(60, orbit + 30)
        let fit = min(size.width / max(maxX - minX, 1), size.height / max(maxY - minY, 1))
        let base = min(max(fit, 0.25), 1.6)
        scale = base * zoom
        nodeScale = min(max(scale, 0.7), 1.5)
        offset = CGPoint(x: size.width / 2 - (minX + maxX) / 2 * scale + pan.width,
                         y: size.height / 2 - (minY + maxY) / 2 * scale + pan.height)
    }

    func point(_ p: CGPoint?) -> CGPoint? {
        p.map { CGPoint(x: $0.x * scale + offset.x, y: $0.y * scale + offset.y) }
    }
}

// MARK: - Focus

/// What lights up for a hovered/selected node: the node, everything it
/// connects to, and the edges between them (an edge is lit when both ends
/// are).
struct AccessNetworkFocus {
    let origin: String?
    private(set) var nodes: Set<String> = []

    init(_ origin: String?, in network: AccessNetwork) {
        self.origin = origin
        guard let origin else { return }
        nodes.insert(origin)
        let hub = AccessNetwork.hubID
        func addGroup(_ group: AccessNetwork.MachineGroup, withMachines: Bool = true) {
            nodes.insert(group.id)
            if withMachines { group.deviceIDs.forEach { nodes.insert(AccessNetwork.machineNodeID($0)) } }
        }
        func addAudience(_ group: AccessNetwork.MachineGroup) {
            if group.isEveryone { nodes.insert(hub) } else { group.audience.forEach { nodes.insert($0) } }
        }
        if origin == hub {
            network.groups.filter(\.isEveryone).forEach { addGroup($0) }
            network.people.forEach { nodes.insert($0.id) }
        } else if let group = network.group(id: origin) {
            addGroup(group)
            addAudience(group)
        } else if origin.hasPrefix("machine:") {
            if let group = network.group(containing: String(origin.dropFirst("machine:".count))) {
                addGroup(group, withMachines: false)
                addAudience(group)
            }
        } else {
            for group in network.groups(reachedBy: origin) {
                addGroup(group)
                if group.isEveryone { nodes.insert(hub) }
            }
        }
    }

    var isActive: Bool { origin != nil }
    func contains(_ id: String) -> Bool { nodes.contains(id) }
}

// MARK: - Scene (drawing + hit testing)

struct AccessNetworkScene {
    let network: AccessNetwork
    let positions: [String: CGPoint]
    let viewport: AccessNetworkViewport
    let focus: AccessNetworkFocus
    let selection: String?

    /// The map's one color: groups, machines, the Everyone hub and links
    /// are all this neutral gray (color means something elsewhere in the app).
    static let ink = Color.gray

    func color(for group: AccessNetwork.MachineGroup) -> Color { Self.ink }

    func isDimmed(_ id: String) -> Bool { focus.isActive && !focus.contains(id) }

    private func screen(_ id: String) -> CGPoint? { viewport.point(positions[id]) }

    /// How far a group's machines reach from its centre (for its label).
    private func orbit(of group: AccessNetwork.MachineGroup) -> Double {
        guard let c = positions[group.id] else { return 0 }
        return group.deviceIDs.compactMap { positions[AccessNetwork.machineNodeID($0)] }
            .map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? 0
    }

    // MARK: Hit testing

    /// The node under a point, preferring the closest; machines only count
    /// when the pointer is right on them.
    func hit(_ location: CGPoint) -> String? {
        let s = viewport.nodeScale
        var candidates: [(id: String, radius: Double)] = network.people.map { ($0.id, 16 * s) }
        if network.hasHub { candidates.append((AccessNetwork.hubID, 17 * s)) }
        for group in network.groups {
            candidates.append((group.id, 13 * s))
            candidates += group.deviceIDs.map { (AccessNetwork.machineNodeID($0), 6 * s) }
        }
        var best: (id: String, distance: Double)?
        for candidate in candidates {
            guard let p = screen(candidate.id) else { continue }
            let d = hypot(p.x - location.x, p.y - location.y)
            guard d <= candidate.radius + 3 else { continue }
            if best == nil || d - candidate.radius < best!.distance { best = (candidate.id, d - candidate.radius) }
        }
        return best?.id
    }

    // MARK: Drawing

    func draw(in context: GraphicsContext) {
        let s = viewport.nodeScale
        drawEdges(context, s: s)

        for group in network.groups {
            let color = color(for: group)
            for id in group.deviceIDs {
                let nodeID = AccessNetwork.machineNodeID(id)
                guard let p = screen(nodeID) else { continue }
                var c = context
                c.opacity = isDimmed(nodeID) ? 0.12 : 1
                c.fill(circle(p, 3.6 * s), with: .color(color))
                if selection == nodeID {
                    c.stroke(circle(p, 6.5 * s), with: .color(.primary), lineWidth: 1.5)
                }
            }
        }

        for group in network.groups {
            guard let p = screen(group.id) else { continue }
            let color = color(for: group)
            var c = context
            c.opacity = isDimmed(group.id) ? 0.15 : 1
            c.fill(circle(p, 9 * s), with: .color(color))
            c.stroke(circle(p, 9 * s), with: .color(.white.opacity(0.7)), lineWidth: 1)
            if selection == group.id {
                c.stroke(circle(p, 13 * s), with: .color(.primary), lineWidth: 2)
            }
        }

        if network.hasHub, let p = screen(AccessNetwork.hubID) {
            var c = context
            c.opacity = isDimmed(AccessNetwork.hubID) ? 0.18 : 1
            c.fill(circle(p, 15 * s), with: .color(Self.ink))
            var symbol = c.resolve(Image(systemName: "person.3.fill"))
            symbol.shading = .color(.white)
            c.draw(symbol, in: CGRect(x: p.x - 10 * s, y: p.y - 7 * s, width: 20 * s, height: 14 * s))
            if selection == AccessNetwork.hubID {
                c.stroke(circle(p, 19 * s), with: .color(.primary), lineWidth: 2)
            }
        }

        for person in network.people {
            guard let p = screen(person.id), isHighlighted(person.id) else { continue }
            context.fill(circle(p, 26 * s), with: .radialGradient(
                Gradient(colors: [Color.primary.opacity(0.22), Color.primary.opacity(0)]),
                center: p, startRadius: 0, endRadius: 26 * s))
        }

        drawLabels(context, s: s)
    }

    private func isHighlighted(_ id: String) -> Bool { focus.isActive && focus.contains(id) }

    private func drawEdges(_ context: GraphicsContext, s: Double) {
        for group in network.groups {
            guard let g = screen(group.id) else { continue }
            let color = color(for: group)
            for id in group.deviceIDs {
                let nodeID = AccessNetwork.machineNodeID(id)
                guard let m = screen(nodeID) else { continue }
                stroke(context, from: g, to: m, color: color, lit: lit(group.id, nodeID), base: 0.25, width: 0.8)
            }
        }
        for edge in network.edges {
            guard let a = screen(edge.from), let b = screen(edge.to) else { continue }
            let fromHub = edge.from == AccessNetwork.hubID
            stroke(context, from: a, to: b, color: Self.ink,
                   lit: lit(edge.from, edge.to), base: fromHub ? 0.55 : 0.4, width: fromHub ? 1.8 : 1.2)
        }
        // A focused person belongs to "Everyone": show that link.
        if let origin = focus.origin, network.people.contains(where: { $0.id == origin }),
           focus.contains(AccessNetwork.hubID), let a = screen(origin), let b = screen(AccessNetwork.hubID) {
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(path, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        }
    }

    private func lit(_ a: String, _ b: String) -> Bool? {
        guard focus.isActive else { return nil }
        return focus.contains(a) && focus.contains(b)
    }

    private func stroke(_ context: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color,
                        lit: Bool?, base: Double, width: Double) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        let opacity = lit == true ? 0.75 : (lit == false ? 0.05 : base)
        let ink = lit == true ? Color.primary : color
        context.stroke(path, with: .color(ink.opacity(opacity)), lineWidth: lit == true ? width + 1 : width)
    }

    private func drawLabels(_ context: GraphicsContext, s: Double) {
        func label(_ text: Text, at p: CGPoint, dimmed: Bool) {
            var c = context
            c.opacity = dimmed ? 0.18 : 1
            c.draw(text, at: p, anchor: .top)
        }
        for group in network.groups {
            guard let p = screen(group.id) else { continue }
            let below = max(orbit(of: group) * viewport.scale, 14 * s) + 8
            label(Text("\(group.title) · \(group.deviceIDs.count)")
                    .font(.system(size: 12 * min(s, 1.2), weight: .semibold))
                    .foregroundColor(group.isUnreachable ? .secondary : .primary),
                  at: CGPoint(x: p.x, y: p.y + below), dimmed: isDimmed(group.id))
        }
        if network.hasHub, let p = screen(AccessNetwork.hubID) {
            label(Text("Everyone").font(.system(size: 12 * min(s, 1.2), weight: .semibold)).foregroundColor(.primary),
                  at: CGPoint(x: p.x, y: p.y + 18 * s), dimmed: isDimmed(AccessNetwork.hubID))
        }
        for person in network.people {
            guard let p = screen(person.id) else { continue }
            label(Text(person.title).font(.system(size: 11 * min(s, 1.2), weight: .medium)).foregroundColor(.primary),
                  at: CGPoint(x: p.x, y: p.y + 16 * s), dimmed: isDimmed(person.id))
        }
        // Machine names appear for whatever is focused, or once zoomed in.
        let showAll = viewport.scale > 1.8
        for group in network.groups {
            for id in group.deviceIDs {
                let nodeID = AccessNetwork.machineNodeID(id)
                guard showAll || (focus.isActive && focus.contains(nodeID) && focus.origin != AccessNetwork.hubID),
                      let p = screen(nodeID),
                      let name = network.machineNames[id] else { continue }
                label(Text(name).font(.system(size: 9.5 * min(s, 1.2))).foregroundColor(.secondary),
                      at: CGPoint(x: p.x, y: p.y + 5 * s), dimmed: false)
            }
        }
    }

    private func circle(_ p: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
}

// MARK: - Avatar

private struct AccessNetworkAvatar: View {
    let user: TSUser?
    let size: Double
    let isSelected: Bool

    var body: some View {
        Group {
            if let user {
                UserAvatar(user: user, size: size)
            } else {
                Circle().fill(.quaternary).frame(width: size, height: size)
            }
        }
        .overlay {
            Circle().stroke(isSelected ? Color.primary : Color.white.opacity(0.25), lineWidth: isSelected ? 2.5 : 1)
        }
    }
}

// MARK: - Legend

/// What the map's shapes mean; shown from the "?" button.
private struct AccessNetworkLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Person") {
                Circle().fill(.quaternary).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.secondary.opacity(0.5)))
            }
            row("Machines the same people can reach") {
                Circle().fill(AccessNetworkScene.ink).frame(width: 12, height: 12)
            }
            row("Machine") {
                Circle().fill(AccessNetworkScene.ink).frame(width: 6, height: 6)
            }
            row("Everyone in your org") {
                ZStack {
                    Circle().fill(AccessNetworkScene.ink).frame(width: 18, height: 18)
                    Image(systemName: "person.3.fill").font(.system(size: 7)).foregroundStyle(.white)
                }
            }
            Divider()
            Text("Click a dot for details. Drag or pinch to move.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private func row<Glyph: View>(_ title: String, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: 10) {
            glyph().frame(width: 20)
            Text(title)
        }
    }
}

// MARK: - Inspector

/// The Map's inspector, shown by AccessView. Gets `app` passed in (inspector
/// content doesn't reliably get the environment).
struct AccessNetworkInspector: View {
    let app: AppState
    let network: AccessNetwork
    let nodeID: String

    var body: some View {
        List {
            if nodeID == AccessNetwork.hubID {
                hubContent
            } else if let group = network.group(id: nodeID) {
                groupContent(group)
            } else if nodeID.hasPrefix("machine:") {
                machineContent(String(nodeID.dropFirst("machine:".count)))
            } else {
                personContent(nodeID)
            }
        }
    }

    // MARK: Person

    @ViewBuilder
    private func personContent(_ login: String) -> some View {
        let user = app.users.first { $0.loginName == login }
        let groups = network.groups(reachedBy: login)
        let count = groups.reduce(0) { $0 + $1.deviceIDs.count }
        Section {
            HStack(spacing: 12) {
                if let user { UserAvatar(user: user, size: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(user?.title ?? login).font(.headline)
                    Text(login).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Can reach \(count) machine\(count == 1 ? "" : "s")")
            if let user {
                NavigationLink {
                    UserDetailView(userID: user.id).environment(app)
                } label: {
                    Label("Manage access", systemImage: "switch.2")
                }
            }
        }
        ForEach(groups) { group in
            Section {
                machineRows(group.deviceIDs, ssh: group.sshDeviceIDs)
            } header: {
                Text(group.isEveryone ? "\(group.title) · everyone" : group.title)
            }
        }
    }

    // MARK: Hub

    @ViewBuilder
    private var hubContent: some View {
        Section {
            Label("Everyone in your org", systemImage: "person.3.fill")
                .font(.headline)
                .lineLimit(1)
            LabeledContent("People", value: "\(network.people.count)")
        }
        ForEach(network.groups.filter(\.isEveryone)) { group in
            Section(group.title) {
                machineRows(group.deviceIDs, ssh: group.sshDeviceIDs)
            }
        }
    }

    // MARK: Group

    @ViewBuilder
    private func groupContent(_ group: AccessNetwork.MachineGroup) -> some View {
        Section {
            Text(group.isUnreachable ? "Machines no one can reach" : group.title)
                .font(.headline)
                .lineLimit(2)
            LabeledContent("Machines", value: "\(group.deviceIDs.count)")
            if !group.sshDeviceIDs.isEmpty {
                LabeledContent("Port 22 (SSH) allowed on", value: "\(group.sshDeviceIDs.count)")
            }
        }
        audienceSection(group)
        ForEach(group.sections, id: \.name) { section in
            Section(section.name) {
                machineRows(section.deviceIDs, ssh: group.sshDeviceIDs)
            }
        }
    }

    // MARK: Machine

    @ViewBuilder
    private func machineContent(_ deviceID: String) -> some View {
        if let device = app.device(id: deviceID) {
            let group = network.group(containing: deviceID)
            Section {
                HStack(spacing: 8) {
                    StatusDot(isOnline: device.isOnline)
                    Text(device.shortName).font(.headline).lineLimit(1)
                }
                .help(device.shortName)
                if device.isTagged {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(device.tags ?? [], id: \.self) { AccessGroupChip(name: $0) }
                        }
                    }
                } else {
                    Text("Personal machine")
                        .foregroundStyle(.secondary)
                }
                if group?.sshDeviceIDs.contains(deviceID) == true {
                    LabeledContent("Port 22 (SSH)", value: "Allowed")
                }
                NavigationLink {
                    DeviceDetailView(deviceID: device.id).environment(app)
                } label: {
                    Label("Open machine", systemImage: "arrow.right.circle")
                }
            }
            if let group { audienceSection(group) }
        }
    }

    // MARK: Shared

    @ViewBuilder
    private func audienceSection(_ group: AccessNetwork.MachineGroup) -> some View {
        Section("Who can reach") {
            if group.isUnreachable {
                Text("No one")
                    .foregroundStyle(.secondary)
                    .help("No person can reach these; only other machines, if your access rules allow it.")
            } else if group.isEveryone {
                Label("Everyone in your org (\(group.audience.count))", systemImage: "person.3.fill")
            } else {
                ForEach(group.audience, id: \.self) { login in
                    if let user = app.users.first(where: { $0.loginName == login }) {
                        NavigationLink {
                            UserDetailView(userID: user.id).environment(app)
                        } label: {
                            HStack(spacing: 8) {
                                UserAvatar(user: user, size: 22)
                                Text(user.title)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func machineRows(_ ids: [String], ssh: Set<String>) -> some View {
        ForEach(ids, id: \.self) { id in
            if let device = app.device(id: id) {
                NavigationLink {
                    DeviceDetailView(deviceID: device.id).environment(app)
                } label: {
                    HStack(spacing: 8) {
                        StatusDot(isOnline: device.isOnline)
                        Text(device.shortName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if ssh.contains(id) {
                            Text("22")
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .help("Port 22 (SSH) is allowed")
                        }
                    }
                }
            }
        }
    }
}
