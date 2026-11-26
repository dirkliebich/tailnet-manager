import Foundation

// MARK: - Access network

/// People → machine access as a small network that stays readable at any
/// size: machines that exactly the same people can reach collapse into one
/// group, and groups that everyone in the org can reach hang off a single
/// "Everyone" hub instead of one line per person.
struct AccessNetwork {
    struct Person: Identifiable, Hashable {
        let id: String
        let title: String
        let reachCount: Int
    }

    struct MachineGroup: Identifiable, Hashable {
        struct Section: Hashable {
            let name: String
            let deviceIDs: [String]
        }

        let id: String
        let title: String
        let deviceIDs: [String]
        /// Logins that can reach every machine in this group (and no others do).
        let audience: [String]
        let isEveryone: Bool
        /// Machines in the group where at least one of these people is
        /// allowed on port 22.
        let sshDeviceIDs: Set<String>
        /// The machines, grouped by their access groups, for the inspector.
        let sections: [Section]

        var isUnreachable: Bool { audience.isEmpty }
    }

    struct Edge: Identifiable, Hashable {
        let from: String
        let to: String
        var id: String { "\(from)>\(to)" }
    }

    static let hubID = "hub:everyone"

    let people: [Person]
    let groups: [MachineGroup]
    let edges: [Edge]
    /// Device ID → short name, for labels.
    let machineNames: [String: String]
    var hasHub: Bool { groups.contains(where: \.isEveryone) }

    init(reach: AccessReachability, members: [TSUser], devices: [Device]) {
        let logins = Set(members.map(\.loginName))
        let usable = devices.filter { $0.isExternal != true }

        var byAudience: [String: [Device]] = [:]
        for device in usable {
            let audience = (reach.peopleByDevice[device.id] ?? []).intersection(logins)
            byAudience[audience.sorted().joined(separator: "|"), default: []].append(device)
        }

        var groups: [MachineGroup] = []
        for (key, devs) in byAudience {
            let audience = key.isEmpty ? [] : key.components(separatedBy: "|")
            let sorted = devs.sorted { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
            let ssh = Set(sorted.filter { device in
                audience.contains { reach.pairSSH.contains("\($0)|\(device.id)") }
            }.map(\.id))
            let sections = Dictionary(grouping: sorted, by: Self.sectionName)
                .map { MachineGroup.Section(name: $0.key, deviceIDs: $0.value.map(\.id)) }
                .sorted { ($0.deviceIDs.count, $1.name) > ($1.deviceIDs.count, $0.name) }
            groups.append(MachineGroup(
                id: key.isEmpty ? "group:nobody" : "group:\(key)",
                title: key.isEmpty ? "No one" : Self.title(for: sorted),
                deviceIDs: sorted.map(\.id),
                audience: audience,
                isEveryone: !audience.isEmpty && audience.count == logins.count && logins.count > 1,
                sshDeviceIDs: ssh,
                sections: sections))
        }
        groups.sort { a, b in
            if a.isUnreachable != b.isUnreachable { return !a.isUnreachable }
            if a.isEveryone != b.isEveryone { return a.isEveryone }
            if a.audience.count != b.audience.count { return a.audience.count > b.audience.count }
            return a.deviceIDs.count > b.deviceIDs.count
        }

        var edges: [Edge] = []
        for group in groups {
            if group.isEveryone {
                edges.append(Edge(from: Self.hubID, to: group.id))
            } else {
                edges += group.audience.map { Edge(from: $0, to: group.id) }
            }
        }

        self.groups = groups
        self.edges = edges
        self.machineNames = Dictionary(usable.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
        self.people = members
            .map { Person(id: $0.loginName, title: $0.title,
                          reachCount: reach.reachableByPerson[$0.loginName]?.count ?? 0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func group(id: String) -> MachineGroup? { groups.first { $0.id == id } }

    func group(containing deviceID: String) -> MachineGroup? {
        groups.first { $0.deviceIDs.contains(deviceID) }
    }

    /// The groups a person reaches (directly or as part of everyone).
    func groups(reachedBy login: String) -> [MachineGroup] {
        groups.filter { $0.audience.contains(login) }
    }

    // MARK: Naming

    /// A group's name: the access group all its machines share, else the
    /// most common one plus how many others ("K8s +3"), else the machine.
    private static func title(for devices: [Device]) -> String {
        if devices.count == 1 { return devices[0].shortName }
        let tagSets = devices.map { Set($0.tags ?? []) }
        if tagSets.allSatisfy(\.isEmpty) { return "Personal machines" }
        if !tagSets.contains(where: \.isEmpty) {
            let common = tagSets.dropFirst().reduce(tagSets[0]) { $0.intersection($1) }
            if !common.isEmpty {
                return common.sorted().map(AccessEditor.accessGroupName).joined(separator: " + ")
            }
        }
        var counts: [String: Int] = [:]
        for tags in tagSets { for tag in tags { counts[tag, default: 0] += 1 } }
        guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else {
            return "\(devices.count) machines"
        }
        let rest = devices.count - top.value
        return AccessEditor.accessGroupName(top.key) + (rest > 0 ? " +\(rest)" : "")
    }

    private static func sectionName(_ device: Device) -> String {
        let tags = (device.tags ?? []).sorted()
        return tags.isEmpty ? "Personal machines" : tags.map(AccessEditor.accessGroupName).joined(separator: " + ")
    }
}

// MARK: - Layout

/// Deterministic force-directed layout (d3-force style: link springs,
/// many-body repulsion, collision, centring) in abstract coordinates. The
/// view fits the result to whatever size it has, so resizing never
/// re-runs the simulation and the whole graph always fits without
/// scrolling. Same input → same picture.
enum AccessNetworkLayout {
    enum Kind { case person, hub, group, machine }

    struct Node {
        let id: String
        let kind: Kind
        /// Collision radius, including room for the node's label.
        let collide: Double
    }

    struct Link {
        let a: String
        let b: String
        let distance: Double
        let strength: Double
    }

    static func layout(nodes: [Node], links: [Link], ticks: Int = 320) -> [String: (x: Double, y: Double)] {
        let n = nodes.count
        guard n > 0 else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        var x = [Double](repeating: 0, count: n), y = x, vx = x, vy = x

        // Phyllotaxis start, in node order (d3's default seeding).
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for i in 0..<n {
            let r = 14 * (Double(i) + 0.5).squareRoot(), a = Double(i) * golden
            x[i] = r * cos(a)
            y[i] = r * sin(a)
        }

        let resolved = links.compactMap { link -> (Int, Int, Double, Double)? in
            guard let a = index[link.a], let b = index[link.b], a != b else { return nil }
            return (a, b, link.distance, link.strength)
        }
        var degree = [Int](repeating: 0, count: n)
        for (a, b, _, _) in resolved { degree[a] += 1; degree[b] += 1 }
        let charge = nodes.map { node -> Double in
            switch node.kind {
            case .machine: return -35
            case .group: return -420
            case .person: return -260
            case .hub: return -420
            }
        }
        let radius = nodes.map(\.collide)

        var alpha = 1.0
        let decay = 1 - pow(0.001, 1 / Double(ticks))
        for _ in 0..<ticks {
            alpha -= alpha * decay

            for (a, b, distance, strength) in resolved {
                var dx = x[b] + vx[b] - x[a] - vx[a]
                var dy = y[b] + vy[b] - y[a] - vy[a]
                let l = max((dx * dx + dy * dy).squareRoot(), 1e-6)
                let k = (l - distance) / l * alpha * strength
                dx *= k; dy *= k
                let bias = Double(degree[a]) / Double(degree[a] + degree[b])
                vx[b] -= dx * bias; vy[b] -= dy * bias
                vx[a] += dx * (1 - bias); vy[a] += dy * (1 - bias)
            }

            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = x[j] - x[i], dy = y[j] - y[i]
                    let l = max(dx * dx + dy * dy, 1)
                    let wi = charge[j] * alpha / l, wj = charge[i] * alpha / l
                    vx[i] += dx * wi; vy[i] += dy * wi
                    vx[j] -= dx * wj; vy[j] -= dy * wj
                }
                vx[i] -= x[i] * 0.06 * alpha
                vy[i] -= y[i] * 0.06 * alpha
            }

            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = (x[i] + vx[i]) - (x[j] + vx[j]), dy = (y[i] + vy[i]) - (y[j] + vy[j])
                    let r = radius[i] + radius[j]
                    let l2 = dx * dx + dy * dy
                    guard l2 < r * r else { continue }
                    let l = max(l2.squareRoot(), 1e-6)
                    let push = (r - l) / l * 0.7
                    let ri2 = radius[i] * radius[i], rj2 = radius[j] * radius[j]
                    let share = rj2 / (ri2 + rj2)
                    vx[i] += dx * push * share; vy[i] += dy * push * share
                    vx[j] -= dx * push * (1 - share); vy[j] -= dy * push * (1 - share)
                }
            }

            for i in 0..<n {
                vx[i] *= 0.6; vy[i] *= 0.6
                x[i] += vx[i]; y[i] += vy[i]
            }
        }

        var result: [String: (x: Double, y: Double)] = [:]
        for (i, node) in nodes.enumerated() { result[node.id] = (x[i], y[i]) }
        return result
    }
}

// MARK: - Layout input

extension AccessNetwork {
    /// Every node the graph draws, and the springs between them: machines
    /// orbit their group, groups sit between the people who reach them,
    /// and the Everyone hub sits among the people (a layout-only spring).
    func layoutInput() -> (nodes: [AccessNetworkLayout.Node], links: [AccessNetworkLayout.Link]) {
        var nodes: [AccessNetworkLayout.Node] = []
        var links: [AccessNetworkLayout.Link] = []
        if hasHub { nodes.append(.init(id: Self.hubID, kind: .hub, collide: 30)) }
        nodes += groups.map { .init(id: $0.id, kind: .group, collide: 28) }
        nodes += people.map { .init(id: $0.id, kind: .person, collide: 42) }
        for group in groups {
            nodes += group.deviceIDs.map { .init(id: Self.machineNodeID($0), kind: .machine, collide: 7) }
            links += group.deviceIDs.map { .init(a: group.id, b: Self.machineNodeID($0), distance: 22, strength: 0.9) }
        }
        for edge in edges {
            links.append(edge.from == Self.hubID
                ? .init(a: edge.from, b: edge.to, distance: 120, strength: 0.6)
                : .init(a: edge.from, b: edge.to, distance: 160, strength: 0.3))
        }
        if hasHub {
            links += people.map { .init(a: Self.hubID, b: $0.id, distance: 95, strength: 0.2) }
        }
        return (nodes, links)
    }

    static func machineNodeID(_ deviceID: String) -> String { "machine:\(deviceID)" }
}
