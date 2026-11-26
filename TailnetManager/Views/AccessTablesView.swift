import SwiftUI

// The Access › Machines and Access › People tables are gone: they repeated
// the Machines and People pages. What one person or one machine can reach
// belongs in those pages' inspectors; this is the shared piece for that.

extension AccessAnalysis {
    /// What one person can reach, per the access rules.
    func access(forPerson login: String) -> PrincipalAccess? {
        userAccess.first { $0.id == "user:\(login)" }
    }

    /// What one machine can reach (rules whose source is an access group or host).
    func access(forMachine deviceID: String) -> PrincipalAccess? {
        machineAccess.first { $0.id == "machine:\(deviceID)" }
    }
}

/// "Can reach" for an inspector: one row per destination with its ports and
/// the rule behind it. Plain values only (safe in inspectors).
struct AccessReachSection: View {
    var title = "Can reach"
    let access: PrincipalAccess?

    var body: some View {
        Section(title) {
            if let access, !access.destinations.isEmpty {
                ForEach(access.destinations) { destination in
                    AccessReachRow(destination: destination)
                }
            } else {
                Text("Nothing")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccessReachRow: View {
    let destination: AccessDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(destination.label)
                    .lineLimit(1)
                    .help(destination.label)
                Spacer(minLength: 4)
                if let ports = Self.portSummary(destination.ports) {
                    if destination.risky {
                        StatusPill(text: ports, tone: .critical)
                    } else {
                        Text(ports)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Text(destination.via)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(destination.via)
        }
    }

    /// ["*"] → "all ports"; ["22"] / ["ssh"] → "SSH"; else the list.
    static func portSummary(_ ports: [String]) -> String? {
        guard !ports.isEmpty else { return nil }
        if ports == ["*"] { return "all ports" }
        let normalized = ports.map { $0.lowercased() }
        if normalized == ["22"] || normalized == ["ssh"] { return "SSH" }
        return ports.joined(separator: ", ")
    }
}
