import Foundation

struct TailscaleAPIError: Error, LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        "\(message) (HTTP \(statusCode))"
    }

    var isPermissionDenied: Bool { statusCode == 403 || statusCode == 401 }
}

/// Client for the Tailscale public REST API v2.
///
/// Everything the app does goes through these endpoints. The policy (ACL)
/// file is only ever written by `savePolicyFile(_:ifMatch:)`, which is
/// guarded by an ETag and reached solely through the access review sheet.
final class TailscaleAPI: Sendable {
    private let token: String
    private let tailnet: String
    private let base = URL(string: "https://api.tailscale.com/api/v2")!
    private let session: URLSession
    private let onUnauthorized: @MainActor @Sendable (TailscaleAPI) -> Void

    /// - Parameter tailnet: "-" targets the token's own tailnet, so the
    ///   user never has to type an organization name.
    init(token: String, tailnet: String = "-",
         onUnauthorized: @escaping @MainActor @Sendable (TailscaleAPI) -> Void) {
        self.token = token
        self.tailnet = tailnet
        self.onUnauthorized = onUnauthorized
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// The token's own key ID (`tskey-api-<keyID>-<secret>`), used to tell
    /// which admin the app acts as. nil for other token shapes.
    var keyID: String? {
        let parts = token.split(separator: "-")
        guard parts.count >= 4, parts[0] == "tskey", parts[1] == "api" else { return nil }
        return String(parts[2])
    }

    // MARK: - Transport

    @discardableResult
    private func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        json: Any? = nil,
        accept: String? = nil
    ) async throws -> Data {
        var body: (Data, String)?
        if let json {
            body = (try JSONSerialization.data(withJSONObject: json), "application/json")
        }
        return try await send(method, path, query: query, body: body, accept: accept).0
    }

    /// Transport core: returns the body and the response (for headers like
    /// ETag). Non-2xx statuses throw `TailscaleAPIError`.
    @discardableResult
    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (data: Data, contentType: String)? = nil,
        accept: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        var url = base.appendingPathComponent(path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accept {
            req.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let body {
            req.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data
        }
        for (field, value) in headers {
            req.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { await onUnauthorized(self) }
            let message = Self.errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw TailscaleAPIError(statusCode: http.statusCode, message: message)
        }
        return (data, http)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["message"] as? String
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Devices

    func devices() async throws -> [Device] {
        let data = try await request("GET", "tailnet/\(tailnet)/devices",
                                     query: [URLQueryItem(name: "fields", value: "all")])
        return try decode(DevicesResponse.self, from: data).devices
    }

    func setDeviceAuthorized(id: String, authorized: Bool) async throws {
        try await request("POST", "device/\(id)/authorized", json: ["authorized": authorized])
    }

    func deleteDevice(id: String) async throws {
        try await request("DELETE", "device/\(id)")
    }

    /// Expires the device's node key immediately, forcing re-authentication.
    func expireDeviceKey(id: String) async throws {
        try await request("POST", "device/\(id)/expire")
    }

    func setKeyExpiryDisabled(id: String, disabled: Bool) async throws {
        try await request("POST", "device/\(id)/key", json: ["keyExpiryDisabled": disabled])
    }

    /// Replaces the device's tags. Tags must be permitted by the tailnet
    /// policy (tagOwners); the API rejects others — no policy edits happen here.
    func setDeviceTags(id: String, tags: [String]) async throws {
        try await request("POST", "device/\(id)/tags", json: ["tags": tags])
    }

    /// Renames the device (MagicDNS base name). Empty string resets to the
    /// OS hostname. Existing MagicDNS URLs break on rename.
    func renameDevice(id: String, name: String) async throws {
        try await request("POST", "device/\(id)/name", json: ["name": name])
    }

    func deviceRoutes(id: String) async throws -> DeviceRoutes {
        let data = try await request("GET", "device/\(id)/routes")
        return try decode(DeviceRoutes.self, from: data)
    }

    /// Sets which advertised routes are enabled. An empty array disables
    /// subnet routing / exit-node service for the device.
    func setDeviceRoutes(id: String, routes: [String]) async throws {
        try await request("POST", "device/\(id)/routes", json: ["routes": routes])
    }

    // MARK: - Users

    func users() async throws -> [TSUser] {
        let data = try await request("GET", "tailnet/\(tailnet)/users",
                                     query: [URLQueryItem(name: "type", value: "all"),
                                             URLQueryItem(name: "role", value: "all")])
        return try decode(UsersResponse.self, from: data).users
    }

    func setUserRole(id: String, role: String) async throws {
        try await request("POST", "users/\(id)/role", json: ["role": role])
    }

    func suspendUser(id: String) async throws {
        try await request("POST", "users/\(id)/suspend")
    }

    func restoreUser(id: String) async throws {
        try await request("POST", "users/\(id)/restore")
    }

    func approveUser(id: String) async throws {
        try await request("POST", "users/\(id)/approve")
    }

    func deleteUser(id: String) async throws {
        try await request("POST", "users/\(id)/delete")
    }

    // MARK: - User invites

    func userInvites() async throws -> [UserInvite] {
        let data = try await request("GET", "tailnet/\(tailnet)/user-invites")
        return try decode([UserInvite].self, from: data)
    }

    /// Creates one invite. An empty email makes a shareable invite link.
    func createUserInvite(email: String, role: String) async throws {
        try await request("POST", "tailnet/\(tailnet)/user-invites",
                          json: [["email": email, "role": role]])
    }

    func deleteUserInvite(id: String) async throws {
        try await request("DELETE", "user-invites/\(id)")
    }

    func resendUserInvite(id: String) async throws {
        try await request("POST", "user-invites/\(id)/resend")
    }

    // MARK: - Machine sharing

    func deviceInvites(deviceID: String) async throws -> [DeviceInvite] {
        let data = try await request("GET", "device/\(deviceID)/device-invites")
        // An unshared machine answers `null`; anything else must decode.
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return [] }
        return try decode([DeviceInvite].self, from: data)
    }

    /// Shares a machine with one email address (single use).
    func shareDevice(id: String, with email: String, allowExitNode: Bool) async throws {
        try await request("POST", "device/\(id)/device-invites",
                          json: [["email": email, "multiUse": false, "allowExitNode": allowExitNode]])
    }

    /// Deletes a share. For an accepted one this stops sharing the machine
    /// with that person.
    func deleteDeviceInvite(id: String) async throws {
        try await request("DELETE", "device-invites/\(id)")
    }

    // MARK: - Keys

    func authKeys() async throws -> [AuthKey] {
        let data = try await request("GET", "tailnet/\(tailnet)/keys",
                                     query: [URLQueryItem(name: "all", value: "true")])
        return try decode(KeysResponse.self, from: data).keys
    }

    /// Creates an auth key. The returned key's `key` field carries the
    /// secret — shown exactly once, never retrievable again.
    func createAuthKey(description: String,
                       reusable: Bool,
                       ephemeral: Bool,
                       preauthorized: Bool,
                       tags: [String],
                       expirySeconds: Int?) async throws -> AuthKey {
        var create: [String: Any] = ["reusable": reusable,
                                     "ephemeral": ephemeral,
                                     "preauthorized": preauthorized]
        if !tags.isEmpty { create["tags"] = tags }
        var body: [String: Any] = [
            "keyType": "auth",
            "description": description,
            "capabilities": ["devices": ["create": create]],
        ]
        if let expirySeconds { body["expirySeconds"] = expirySeconds }
        let data = try await request("POST", "tailnet/\(tailnet)/keys", json: body)
        return try decode(AuthKey.self, from: data)
    }

    func revokeKey(id: String) async throws {
        try await request("DELETE", "tailnet/\(tailnet)/keys/\(id)")
    }

    // MARK: - Tailnet settings & DNS

    func tailnetSettings() async throws -> TailnetSettings {
        let data = try await request("GET", "tailnet/\(tailnet)/settings")
        return try decode(TailnetSettings.self, from: data)
    }

    /// PATCHes only the keys present in `patch`, e.g. ["devicesApprovalOn": true].
    func updateTailnetSettings(_ patch: [String: Any]) async throws {
        try await request("PATCH", "tailnet/\(tailnet)/settings", json: patch)
    }

    func dnsPreferences() async throws -> DNSPreferences {
        let data = try await request("GET", "tailnet/\(tailnet)/dns/preferences")
        return try decode(DNSPreferences.self, from: data)
    }

    func setMagicDNS(_ enabled: Bool) async throws {
        try await request("POST", "tailnet/\(tailnet)/dns/preferences", json: ["magicDNS": enabled])
    }

    func dnsNameservers() async throws -> [String] {
        let data = try await request("GET", "tailnet/\(tailnet)/dns/nameservers")
        return try decode(DNSNameserversResponse.self, from: data).dns ?? []
    }

    func setDNSNameservers(_ dns: [String]) async throws {
        try await request("POST", "tailnet/\(tailnet)/dns/nameservers", json: ["dns": dns])
    }

    func dnsSearchPaths() async throws -> [String] {
        let data = try await request("GET", "tailnet/\(tailnet)/dns/searchpaths")
        return try decode(DNSSearchPathsResponse.self, from: data).searchPaths ?? []
    }

    func setDNSSearchPaths(_ paths: [String]) async throws {
        try await request("POST", "tailnet/\(tailnet)/dns/searchpaths", json: ["searchPaths": paths])
    }

    // MARK: - Configuration audit logs (read-only)

    func configurationAuditLogs(start: Date, end: Date) async throws -> [AuditLogEntry] {
        let iso = ISO8601DateFormatter()
        let data = try await request("GET", "tailnet/\(tailnet)/logging/configuration",
                                     query: [URLQueryItem(name: "start", value: iso.string(from: start)),
                                             URLQueryItem(name: "end", value: iso.string(from: end))])
        return try decode(AuditLogResponse.self, from: data).logs ?? []
    }

    // MARK: - Policy file

    /// The policy as HuJSON (comments intact) plus its ETag, which a later
    /// save must present so a concurrent console edit is never overwritten.
    func policyFile() async throws -> (text: String, etag: String?) {
        let (data, response) = try await send("GET", "tailnet/\(tailnet)/acl", accept: "application/hujson")
        return (String(data: data, encoding: .utf8) ?? "", response.value(forHTTPHeaderField: "ETag"))
    }

    /// Asks Tailscale to validate a candidate policy and run the tests
    /// embedded in it. Saves nothing. Returns nil when it passes, otherwise
    /// the reasons it was rejected.
    func validatePolicyFile(_ text: String) async throws -> String? {
        let data: Data
        do {
            data = try await send("POST", "tailnet/\(tailnet)/acl/validate",
                                  body: (Data(text.utf8), "application/hujson")).0
        } catch let error as TailscaleAPIError where error.statusCode == 400 {
            return error.message
        }
        return Self.validationFailure(from: data)
    }

    /// Replaces the policy. `ifMatch` is the ETag of the version the edit
    /// was based on; Tailscale answers 412 if the policy changed since.
    func savePolicyFile(_ text: String, ifMatch etag: String) async throws {
        do {
            try await send("POST", "tailnet/\(tailnet)/acl",
                           body: (Data(text.utf8), "application/hujson"),
                           accept: "application/hujson",
                           headers: ["If-Match": etag])
        } catch let error as TailscaleAPIError where error.statusCode == 412 {
            throw TailscaleAPIError(
                statusCode: 412,
                message: "Your policy changed in the admin console after the app loaded it, so nothing was saved. Refresh and make the change again")
        }
    }

    /// `{"message": "...", "data": [{"user": ..., "errors": [...]}]}` → text.
    private static func validationFailure(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? String, !message.isEmpty else { return nil }
        let details = (obj["data"] as? [[String: Any]] ?? []).flatMap { entry -> [String] in
            let who = entry["user"] as? String
            let prefix = who.map { "\($0): " } ?? ""
            return (entry["errors"] as? [String] ?? []).map { prefix + $0 }
        }
        return ([message] + details).joined(separator: "\n")
    }

    // MARK: - Validation

    /// Cheap token check used during onboarding.
    func validateToken() async throws {
        try await request("GET", "tailnet/\(tailnet)/devices")
    }
}
