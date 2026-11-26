import Foundation

// MARK: - Date parsing

/// Tailscale returns RFC 3339 timestamps; empty strings, missing keys and
/// "0001-01-01T00:00:00Z" all mean "no value", so dates are kept as raw
/// strings and parsed leniently.
enum TSDate {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = iso.date(from: raw) ?? isoFractional.date(from: raw) else { return nil }
        // Zero-value Go timestamps ("0001-01-01T00:00:00Z") mean "never".
        if date.timeIntervalSince1970 < 0 { return nil }
        return date
    }
}

/// A named count used for stats breakdowns (OS chart, role chart, …).
struct CountedGroup: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }
}

// MARK: - Device

struct Device: Identifiable, Codable, Hashable {
    var id: String
    var nodeId: String?
    var name: String
    var hostname: String?
    var addresses: [String]?
    var user: String?
    var os: String?
    var clientVersion: String?
    var created: String?
    var expires: String?
    var lastSeen: String?
    var connectedToControl: Bool?
    var authorized: Bool?
    var isExternal: Bool?
    var isEphemeral: Bool?
    var keyExpiryDisabled: Bool?
    var updateAvailable: Bool?
    var blocksIncomingConnections: Bool?
    var tags: [String]?
    var tailnetLockError: String?
    var enabledRoutes: [String]?
    var advertisedRoutes: [String]?
    var sshEnabled: Bool?

    // MARK: Derived

    /// Canonical identifier for API calls (nodeId preferred over legacy id).
    var apiId: String { nodeId ?? id }

    /// First label of the MagicDNS name, e.g. "dirks-macbook".
    var shortName: String {
        name.split(separator: ".").first.map(String.init) ?? name
    }

    var primaryAddress: String? { addresses?.first }

    var createdDate: Date? { TSDate.parse(created) }
    var expiresDate: Date? { TSDate.parse(expires) }
    var lastSeenDate: Date? { TSDate.parse(lastSeen) }

    /// `connectedToControl` is the authoritative online signal.
    /// `lastSeen` is OMITTED while a device is connected — never use it alone.
    var isOnline: Bool { connectedToControl == true }

    /// Ready-made "Online now" / "2 hr. ago" / "Never seen" string.
    var lastSeenDescription: String {
        if isOnline { return "Online now" }
        if let seen = lastSeenDate {
            return TSDate.relative.localizedString(for: seen, relativeTo: .now)
        }
        return "Never seen"
    }

    var needsApproval: Bool { authorized == false }
    var isTagged: Bool { !(tags ?? []).isEmpty }

    /// External (shared-in) devices can't be deleted via the API (501).
    var canBeDeleted: Bool { isExternal != true }

    /// Days until the node key expires (negative = already expired);
    /// nil when expiry is disabled or unknown.
    var keyExpiresInDays: Int? {
        guard keyExpiryDisabled != true, isExternal != true, let exp = expiresDate else { return nil }
        return Calendar.current.dateComponents([.day], from: .now, to: exp).day
    }

    var keyExpired: Bool { (keyExpiresInDays ?? 1) < 0 }

    var keyExpiresSoon: Bool {
        guard let days = keyExpiresInDays else { return false }
        return days <= 30
    }

    var prettyOS: String {
        switch (os ?? "").lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "tvos": return "tvOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        case "android": return "Android"
        case "": return "Unknown"
        default: return os ?? "Unknown"
        }
    }

    var systemImageName: String {
        switch (os ?? "").lowercased() {
        case "macos": return "macbook"
        case "ios": return "iphone"
        case "tvos": return "appletv"
        case "windows": return "pc"
        case "linux": return "server.rack"
        case "android": return "candybarphone"
        default: return "questionmark.square.dashed"
        }
    }
}

struct DevicesResponse: Codable {
    var devices: [Device]
}

// MARK: - User

struct TSUser: Identifiable, Codable, Hashable {
    var id: String
    var displayName: String?
    var loginName: String
    var profilePicUrl: String?
    var role: String?
    var status: String?
    var type: String?
    var deviceCount: Int?
    var created: String?
    var lastSeen: String?
    var currentlyConnected: Bool?

    // MARK: Derived

    var title: String {
        let dn = (displayName ?? "").trimmingCharacters(in: .whitespaces)
        return dn.isEmpty ? loginName : dn
    }

    var initials: String {
        let parts = title.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    var createdDate: Date? { TSDate.parse(created) }
    var lastSeenDate: Date? { TSDate.parse(lastSeen) }

    var isOwner: Bool { role == "owner" }
    var isSuspended: Bool { status == "suspended" }
    var needsApproval: Bool { status == "needs-approval" }
    /// Shared (external) users joined via device sharing, not tailnet members.
    var isExternal: Bool { type == "shared" }

    var roleLabel: String { UserRole.label(for: role ?? "member") }

    var statusLabel: String {
        switch status {
        case "active": return "Active"
        case "idle": return "Idle"
        case "suspended": return "Paused"
        case "needs-approval": return "Needs approval"
        case "over-billing-limit": return "Over billing limit"
        default: return status?.capitalized ?? "Unknown"
        }
    }
}

struct UsersResponse: Codable {
    var users: [TSUser]
}

/// Roles assignable through the API. "owner" is excluded — ownership
/// transfer is admin-console territory. Advanced roles (it-admin,
/// network-admin, billing-admin, auditor) need a Standard+ plan; the API
/// returns a clear error on free plans.
enum UserRole {
    static let assignable = ["member", "admin", "it-admin", "network-admin", "billing-admin", "auditor"]

    static func label(for role: String) -> String {
        switch role {
        case "owner": return "Owner"
        case "admin": return "Admin"
        case "it-admin": return "IT admin"
        case "network-admin": return "Network admin"
        case "billing-admin": return "Billing admin"
        case "auditor": return "Auditor"
        case "member": return "Member"
        default: return role.capitalized
        }
    }
}

// MARK: - User invites

struct UserInvite: Identifiable, Codable, Hashable {
    var id: String
    var email: String?
    var role: String?
    var inviteUrl: String?
    var lastEmailSentAt: String?

    var roleLabel: String { UserRole.label(for: role ?? "member") }
    var lastSentDate: Date? { TSDate.parse(lastEmailSentAt) }
    var hasEmail: Bool { !(email ?? "").isEmpty }
}

// MARK: - Machine sharing

/// A machine shared with someone outside the tailnet. Once accepted,
/// `acceptedBy` names the guest; until then `email` says who it was sent to.
/// The API sends some IDs as numbers, so they're read as either.
struct DeviceInvite: Identifiable, Codable, Hashable {
    struct Acceptor: Codable, Hashable {
        var id: FlexibleID?
        var loginName: String?
    }

    var id: FlexibleID
    var deviceId: FlexibleID?
    var email: String?
    var multiUse: Bool?
    var allowExitNode: Bool?
    var accepted: Bool?
    var acceptedBy: Acceptor?
}

/// An ID the API may send as a string or a number.
struct FlexibleID: Codable, Hashable, CustomStringConvertible {
    let value: String
    var description: String { value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else {
            value = String(try container.decode(Int64.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Keys

struct AuthKey: Identifiable, Codable, Hashable {
    var id: String
    var keyType: String?
    var key: String?
    var description: String?
    var created: String?
    var updated: String?
    var expires: String?
    var revoked: String?
    var invalid: Bool?
    var userId: String?
    var tags: [String]?

    var createdDate: Date? { TSDate.parse(created) }
    var expiresDate: Date? { TSDate.parse(expires) }
    var isAuthKey: Bool { keyType == nil || keyType == "auth" }
    var isAPIToken: Bool { keyType == "api" }
    var isActive: Bool {
        guard invalid != true, TSDate.parse(revoked) == nil else { return false }
        if let exp = expiresDate { return exp > .now }
        return true
    }
    var expiresSoon: Bool {
        guard isActive, let exp = expiresDate else { return false }
        return exp < Date(timeIntervalSinceNow: 30 * 86400)
    }
}

struct KeysResponse: Codable {
    var keys: [AuthKey]
}

// MARK: - Tailnet settings

struct TailnetSettings: Codable, Hashable {
    var devicesApprovalOn: Bool?
    var devicesAutoUpdatesOn: Bool?
    var devicesKeyDurationDays: Int?
    var usersApprovalOn: Bool?
    var usersRoleAllowedToJoinExternalTailnets: String?
    var networkFlowLoggingOn: Bool?
    var regionalRoutingOn: Bool?
    var postureIdentityCollectionOn: Bool?
    var aclsExternallyManagedOn: Bool?
    var aclsExternalLink: String?
    var httpsEnabled: Bool?
}

struct DNSPreferences: Codable, Hashable {
    var magicDNS: Bool?
}

struct DeviceRoutes: Codable, Hashable {
    var advertisedRoutes: [String]?
    var enabledRoutes: [String]?
}

// MARK: - DNS

struct DNSNameserversResponse: Codable, Hashable {
    var dns: [String]?
}

struct DNSSearchPathsResponse: Codable, Hashable {
    var searchPaths: [String]?
}

// MARK: - Configuration audit log

struct AuditLogActor: Codable, Hashable {
    var id: String?
    var type: String?
    var loginName: String?
    var displayName: String?
    var tags: [String]?

    var label: String {
        if let name = displayName, !name.isEmpty { return name }
        if let login = loginName, !login.isEmpty { return login }
        if let tags, !tags.isEmpty { return tags.joined(separator: ", ") }
        return type?.capitalized ?? "Unknown"
    }
}

struct AuditLogTarget: Codable, Hashable {
    var id: String?
    var name: String?
    var type: String?
    var property: String?

    var label: String {
        var parts: [String] = []
        if let name, !name.isEmpty { parts.append(name) }
        else if let type { parts.append(type.replacingOccurrences(of: "_", with: " ").lowercased()) }
        if let property { parts.append(property.replacingOccurrences(of: "_", with: " ").lowercased()) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

struct AuditLogEntry: Codable, Hashable, Identifiable {
    var eventTime: String?
    var origin: String?
    var action: String?
    var actor: AuditLogActor?
    var target: AuditLogTarget?
    var eventGroupID: String?

    var id: String {
        (eventGroupID ?? "") + (eventTime ?? "") + (action ?? "") + (target?.id ?? "") + (target?.property ?? "")
    }
    var date: Date? { TSDate.parse(eventTime) }
    var actionLabel: String {
        (action ?? "change").replacingOccurrences(of: "_", with: " ").lowercased()
    }
}

struct AuditLogResponse: Codable {
    var logs: [AuditLogEntry]?
}
