import Foundation
import Observation

/// Single source of truth for the whole app: auth, data, actions, and stats.
@MainActor
@Observable
final class AppState {
    static let tokenAccount = "tailscale-api-token"

    private(set) var api: TailscaleAPI?
    var isSignedIn: Bool { api != nil }
    private(set) var needsReplacementToken = false

    /// The app opens on the login screen: a saved token is only used after
    /// the admin confirms it's them (Touch ID / password) or signs in with
    /// a token. Never persisted, so every launch starts locked.
    private(set) var isUnlocked = false

    func unlock() { isUnlocked = true }
    func lock() { isUnlocked = false }

    private(set) var devices: [Device] = []
    private(set) var users: [TSUser] = []
    private(set) var invites: [UserInvite] = []
    private(set) var authKeys: [AuthKey] = []
    private(set) var settings: TailnetSettings?
    private(set) var dnsPreferences: DNSPreferences?

    /// Raw policy file (HuJSON). Written back only through the guarded
    /// access review (`proposeAccessEdits`), never directly.
    private(set) var policyFile: String?
    /// ETag of `policyFile`; a save must present it (If-Match) so a
    /// concurrent edit in the admin console is never overwritten.
    private(set) var policyETag: String?
    /// Pending people → machine access switches, shared by the person page
    /// and the Access Board. "Review" compiles them into one policy edit.
    var stagedAccess: [AccessToggle] = []
    /// Parsed policy + its network rules, kept for the access switches.
    private(set) var policyModel: PolicyModel?
    private(set) var accessRules: [AccessEditor.Rule] = []
    /// Tags mentioned in the policy file — the only tags the API will accept.
    private(set) var knownTags: [String] = []
    /// Read-only access map + attack-surface findings derived from the
    /// policy file and live device/user data.
    private(set) var accessAnalysis: AccessAnalysis?

    private(set) var isLoading = false
    private(set) var lastRefreshed: Date?
    private(set) var hasLoadedOnce = false

    /// Machine shares per device ID, loaded on demand (guests only need it).
    private(set) var deviceShares: [String: [DeviceInvite]] = [:]
    /// True once every machine's shares were read; reset after any change.
    var deviceSharesLoaded = false
    private var sharesLoad: Task<Void, Never>?

    /// Everyone added, changed, paused or removed through the app, newest first
    /// (see PeopleLogStore). Written only by `record(_:)`.
    var peopleLog: [PeopleLogEntry] = PeopleLogStore.load()

    /// What runs on each server (Services page); scans keep going when the
    /// admin leaves the page.
    let services = ServiceInventory()

    /// Tailscale's configuration audit log (sign-ins and changes) for the
    /// Activity page and its report; loaded on demand.
    private(set) var auditLog: [AuditLogEntry] = []
    private(set) var auditLogDays = 0
    private(set) var auditLogLoading = false

    func loadAuditLog(days: Int) async {
        auditLogLoading = true
        defer { auditLogLoading = false }
        if let logs = await fetchAuditLogs(daysBack: days) {
            auditLog = logs
            auditLogDays = days
            dataRevision &+= 1
        }
    }

    /// Bumped whenever API data changes (refresh, audit log). Together with
    /// `services.revision` it keys the cache of derived lists below.
    private(set) var dataRevision = 0

    /// Derived lists (alerts, targets, inventory, activity) are expensive and
    /// read many times per redraw; each is built once per data change.
    @ObservationIgnored private var derivedCache: [String: (key: Int, value: Any)] = [:]

    /// Reading the revisions here also makes views observe them.
    func cached<T>(_ name: String, _ make: () -> T) -> T {
        let key = dataRevision &* 1_000_003 &+ services.revision
        if let hit = derivedCache[name], hit.key == key, let value = hit.value as? T { return value }
        let value = make()
        derivedCache[name] = (key, value)
        return value
    }

    /// Bound to a global alert in RootView.
    var errorMessage: String?

    /// Shows an error, except a cancelled request: leaving a page or a newer
    /// refresh stops the old one, and that isn't a failure ("cancelled").
    func show(_ error: Error) {
        guard !Self.isCancellation(error),
              (error as? TailscaleAPIError)?.statusCode != 401 else { return }
        errorMessage = error.localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// The pending change awaiting review — presented globally as the
    /// preview → confirm → progress sheet (see ChangePlan.swift).
    var activePlan: ChangePlan?
    /// "Add someone" / "Change or remove someone" — presented in the root
    /// sheet; their review opens on top of them.
    var peopleSheet: PeopleSheet?

    /// What the root sheet shows. A people screen stays up while its plan
    /// is reviewed on top of it (so Cancel keeps what was typed); any other
    /// plan gets the root sheet itself.
    var rootSheet: RootSheet? {
        if let peopleSheet { return .people(peopleSheet) }
        return activePlan.map(RootSheet.plan)
    }

    /// A people screen's plan is open on top of it.
    var planOverPeopleSheet: Bool { peopleSheet != nil && activePlan != nil }

    func dismissRootSheet() {
        activePlan = nil
        peopleSheet = nil
    }

    /// Cross-section navigation intents (e.g. a tapped dashboard tile).
    /// RootView consumes `navigationTarget`; list screens consume their
    /// filter request when they appear or when it changes.
    var navigationTarget: String?
    var devicesFilterRequest: String?
    var usersFilterRequest: String?
    var accessTabRequest: String?
    /// Services opens with this filter ("broken" = websites with nothing behind them).
    var servicesFilterRequest: String?
    /// When set, the Access Board opens focused on this machine.
    var accessFocusDeviceID: String?

    func navigate(to section: String,
                  devicesFilter: String? = nil,
                  usersFilter: String? = nil,
                  accessTab: String? = nil) {
        devicesFilterRequest = devicesFilter
        usersFilterRequest = usersFilter
        accessTabRequest = accessTab
        navigationTarget = section
    }

    // DNS details (beyond MagicDNS): global nameservers + search domains.
    private(set) var dnsNameservers: [String] = []
    private(set) var dnsSearchPaths: [String] = []

    /// Some token scopes can't read invites/keys/settings; the UI hides
    /// those sections instead of erroring.
    private(set) var invitesAvailable = true
    private(set) var keysAvailable = true
    private(set) var settingsAvailable = true

    init() {
        #if DEBUG
        // Development builds are re-signed on every build, so the Keychain
        // prompts each time. TAILNET_MANAGER_TOKEN skips it.
        if let token = ProcessInfo.processInfo.environment["TAILNET_MANAGER_TOKEN"], !token.isEmpty {
            api = makeAPI(token: token)
            isUnlocked = true
            return
        }
        #endif
        if let token = KeychainStore.load(account: Self.tokenAccount), !token.isEmpty {
            api = makeAPI(token: token)
        }
    }

    // MARK: - Auth

    private func makeAPI(token: String) -> TailscaleAPI {
        TailscaleAPI(token: token) { [weak self] rejectedAPI in
            guard let self, self.api === rejectedAPI, !self.needsReplacementToken else { return }
            self.needsReplacementToken = true
            self.errorMessage = nil
            self.lock()
        }
    }

    /// Validates the token against the API before storing it.
    func signIn(token: String) async -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Paste your Tailscale API access token first."
            return false
        }
        let candidate = makeAPI(token: trimmed)
        do {
            try await candidate.validateToken()
        } catch {
            errorMessage = "That token didn’t work: \(error.localizedDescription)"
            return false
        }
        KeychainStore.save(trimmed, account: Self.tokenAccount)
        api = candidate
        needsReplacementToken = false
        isUnlocked = true
        await refreshAll()
        return true
    }

    func signOut() {
        KeychainStore.delete(account: Self.tokenAccount)
        api = nil
        needsReplacementToken = false
        isUnlocked = false
        devices = []
        users = []
        invites = []
        authKeys = []
        settings = nil
        dnsPreferences = nil
        policyFile = nil
        policyETag = nil
        stagedAccess = []
        deviceShares = [:]
        deviceSharesLoaded = false
        policyModel = nil
        accessRules = []
        knownTags = []
        accessAnalysis = nil
        lastRefreshed = nil
        hasLoadedOnce = false
    }

    // MARK: - Refresh

    /// Pulls everything in parallel. Devices/users failures surface as an
    /// error; invites/keys/settings degrade silently (limited-scope tokens).
    func refreshAll() async {
        guard let api, !needsReplacementToken else { return }
        isLoading = true
        defer {
            isLoading = false
            dataRevision &+= 1
            hasLoadedOnce = true
        }

        async let devicesResult = Result { try await api.devices() }
        async let usersResult = Result { try await api.users() }
        async let invitesResult = Result { try await api.userInvites() }
        async let keysResult = Result { try await api.authKeys() }
        async let settingsResult = Result { try await api.tailnetSettings() }
        async let dnsResult = Result { try await api.dnsPreferences() }
        async let nameserversResult = Result { try await api.dnsNameservers() }
        async let searchPathsResult = Result { try await api.dnsSearchPaths() }
        async let policyResult = Result { try await api.policyFile() }

        let deviceResponse = await devicesResult
        guard self.api === api, !needsReplacementToken else { return }
        switch deviceResponse {
        case .success(let list): devices = list.sorted { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
        case .failure(let error): show(error)
        }
        switch await usersResult {
        case .success(let list): users = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .failure(let error):
            if errorMessage == nil { show(error) }
        }
        switch await invitesResult {
        case .success(let list): invites = list; invitesAvailable = true
        case .failure: invitesAvailable = false; invites = []
        }
        switch await keysResult {
        case .success(let list): authKeys = list; keysAvailable = true
        case .failure: keysAvailable = false; authKeys = []
        }
        switch await settingsResult {
        case .success(let value): settings = value; settingsAvailable = true
        case .failure: settingsAvailable = false; settings = nil
        }
        if case .success(let value) = await dnsResult {
            dnsPreferences = value
        }
        if case .success(let list) = await nameserversResult {
            dnsNameservers = list
        }
        if case .success(let list) = await searchPathsResult {
            dnsSearchPaths = list
        }
        if case .success(let policy) = await policyResult {
            policyFile = policy.text
            policyETag = policy.etag
            knownTags = Self.extractTags(from: policy.text)
        }

        let model = policyFile.flatMap { PolicyAnalyzer.parse(policyText: $0) }
        accessAnalysis = PolicyAnalyzer.analyze(model: model, devices: devices,
                                                users: users, settings: settings)
        policyModel = model
        accessRules = policyFile.map(AccessEditor.rules(inText:)) ?? []

        lastRefreshed = .now
    }

    /// Pulls every `tag:x` mentioned anywhere in the policy file. The API
    /// validates against tagOwners on write, so over-matching is harmless.
    private static func extractTags(from policy: String) -> [String] {
        let pattern = /"(tag:[A-Za-z0-9._-]+)"/
        let tags = policy.matches(of: pattern).map { String($0.1) }
        return Array(Set(tags)).sorted()
    }

    // MARK: - Reads on demand

    func fetchPolicyFile() async -> String? {
        if let policyFile { return policyFile }
        guard let api else { return nil }
        do {
            let policy = try await api.policyFile()
            policyFile = policy.text
            policyETag = policy.etag
            knownTags = Self.extractTags(from: policy.text)
            return policy.text
        } catch {
            show(error)
            return nil
        }
    }

    /// Reads every machine's shares (one request per machine, in parallel).
    /// Runs on its own (a closing screen can't cut it short) and only counts
    /// as loaded when every machine answered; otherwise it says so.
    func loadDeviceShares() async {
        if let sharesLoad { return await sharesLoad.value }
        let load = Task { await fetchDeviceShares() }
        sharesLoad = load
        await load.value
        sharesLoad = nil
    }

    private func fetchDeviceShares() async {
        guard let api else { return }
        let ids = manageableDevices.map(\.apiId)
        var shares: [String: [DeviceInvite]] = [:]
        var failed = false
        await withTaskGroup(of: (String, [DeviceInvite]?).self) { group in
            for id in ids {
                group.addTask { (id, try? await api.deviceInvites(deviceID: id)) }
            }
            for await (id, list) in group {
                guard let list else { failed = true; continue }
                if !list.isEmpty { shares[id] = list }
            }
        }
        deviceShares = shares
        deviceSharesLoaded = !failed
        if failed {
            errorMessage = "Couldn’t check which machines are shared with guests. Try again in a moment."
        }
    }

    /// Machines shared with this person: accepted shares, plus emailed ones
    /// they haven't accepted yet (the link still works until it's revoked).
    func sharedMachines(with user: TSUser) -> [(device: Device, share: DeviceInvite)] {
        func same(_ a: String?) -> Bool { (a ?? "").caseInsensitiveCompare(user.loginName) == .orderedSame }
        return manageableDevices.flatMap { device in
            (deviceShares[device.apiId] ?? [])
                .filter { $0.accepted == true ? same($0.acceptedBy?.loginName) : same($0.email) }
                .map { (device, $0) }
        }
    }

    // MARK: - Device stats

    var onlineDevices: [Device] { devices.filter(\.isOnline) }
    var devicesAwaitingApproval: [Device] { devices.filter(\.needsApproval) }
    var devicesExpiringSoon: [Device] { devices.filter(\.keyExpiresSoon) }
    var devicesWithExpiredKeys: [Device] { devices.filter(\.keyExpired) }
    var devicesWithUpdates: [Device] { devices.filter { $0.updateAvailable == true && $0.isExternal != true } }
    var externalDevices: [Device] { devices.filter { $0.isExternal == true } }
    var taggedDevices: [Device] { devices.filter(\.isTagged) }

    var osBreakdown: [CountedGroup] {
        breakdown(devices.map(\.prettyOS))
    }

    // MARK: - User stats

    /// Tailnet members (excludes shared-in external users).
    var memberUsers: [TSUser] { users.filter { !$0.isExternal } }
    var externalUsers: [TSUser] { users.filter(\.isExternal) }
    var activeUsers: [TSUser] { memberUsers.filter { !$0.isSuspended } }
    var suspendedUsers: [TSUser] { memberUsers.filter(\.isSuspended) }
    var usersNeedingApproval: [TSUser] { memberUsers.filter(\.needsApproval) }
    var connectedUsers: [TSUser] { memberUsers.filter { $0.currentlyConnected == true } }

    var roleBreakdown: [CountedGroup] {
        breakdown(memberUsers.map(\.roleLabel))
    }

    // MARK: - Key stats

    var activeAuthKeys: [AuthKey] { authKeys.filter { $0.isAuthKey && $0.isActive } }
    /// API access tokens nearing expiry — the app's own token is one of these.
    var apiTokensExpiringSoon: [AuthKey] { authKeys.filter { $0.isAPIToken && $0.expiresSoon } }

    /// Devices that haven't connected in `olderThanDays` days (and aren't
    /// online now) — candidates for cleanup during a review.
    func staleDevices(olderThanDays days: Int = 30) -> [Device] {
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 86400)
        return devices.filter { device in
            guard !device.isOnline, device.isExternal != true else { return false }
            if let seen = device.lastSeenDate { return seen < cutoff }
            return (device.createdDate ?? .now) < cutoff
        }
    }

    // MARK: - Access board

    /// Access groups (tags) known from the policy — the ONLY groups the API
    /// will accept, so the ONLY columns the board may offer.
    var accessGroups: [String] { knownTags }

    /// Machines that can be organized on the board (excludes shared-in).
    var manageableDevices: [Device] { devices.filter { $0.isExternal != true } }

    /// Untagged, user-owned machines — the board's "Personal" column.
    var personalDevices: [Device] { manageableDevices.filter { !$0.isTagged } }

    /// Shared-in machines — shown locked on the board, never editable.
    var guestDevices: [Device] { devices.filter { $0.isExternal == true } }

    func devices(inGroup tag: String) -> [Device] {
        manageableDevices.filter { ($0.tags ?? []).contains(tag) }
    }

    /// The people/teams the policy grants to reach an access group.
    func grantedPrincipals(forGroup tag: String) -> [GrantedPrincipal] {
        accessAnalysis?.grantsByTag[tag] ?? []
    }

    /// How many machines a person can actually reach — from the ONE canonical
    /// reachability relation (wildcards/autogroups expanded, untagged machines
    /// included). This is the same relation the access map draws, so the map,
    /// this count, and the device "Reachable by" list can never disagree.
    func machinesReachable(by user: TSUser) -> Int {
        accessAnalysis?.reachability.reachableByPerson[user.loginName]?.count ?? 0
    }

    /// The exact device IDs a person can reach (canonical).
    func reachableDeviceIDs(by user: TSUser) -> Set<String> {
        accessAnalysis?.reachability.reachableByPerson[user.loginName] ?? []
    }

    /// The policy rule(s) that explain why a person can reach a machine —
    /// the audit trail behind each connection, quoted from the policy so the
    /// admin can verify it against the raw file. Empty = ownership/no grant.
    func whyReachable(login: String, deviceID: String) -> [String] {
        accessAnalysis?.reachability.why(login, deviceID) ?? []
    }

    /// Who can reach a device, as display principals — works for untagged
    /// machines too, and collapses to "Everyone" when everyone can reach it.
    func reachers(ofDevice device: Device) -> [GrantedPrincipal] {
        guard let reach = accessAnalysis?.reachability else { return [] }
        if reach.everyoneDevices.contains(device.id) {
            return [GrantedPrincipal(kind: .everyone, label: "Everyone", loginName: nil)]
        }
        let logins = reach.peopleByDevice[device.id] ?? []
        return logins.sorted().map { login in
            let member = users.first { $0.loginName == login }
            return GrantedPrincipal(kind: .person, label: member?.title ?? login, loginName: login)
        }
    }

    func device(id: String) -> Device? { devices.first { $0.id == id } }

    // MARK: - Access switches

    /// The switches on a person's page: every access group with machines,
    /// then each machine they're given one by one (including ones switched
    /// on but not saved yet).
    func accessRows(for user: TSUser) -> [AccessRow] {
        guard let model = policyModel, let reach = accessAnalysis?.reachability else { return [] }
        var rows = AccessEditor.rows(for: user, rules: accessRules, model: model, reach: reach,
                                     devices: manageableDevices, groups: accessGroups)
        for toggle in stagedAccess where toggle.login == user.loginName && toggle.grant {
            guard case .machine = toggle.target, !rows.contains(where: { $0.target == toggle.target }),
                  let row = accessRow(for: user, target: toggle.target) else { continue }
            rows.append(row)
        }
        return rows
    }

    func accessRow(for user: TSUser, target: AccessTarget) -> AccessRow? {
        guard let model = policyModel, let reach = accessAnalysis?.reachability else { return nil }
        return AccessEditor.row(for: user, target: target, rules: accessRules, model: model, reach: reach,
                                devices: manageableDevices, groups: accessGroups)
    }

    // MARK: - Hardening

    /// Per-machine hardening reports (only devices with at least one issue),
    /// combining policy findings with host-level checks.
    var hardeningReports: [HardeningReport] {
        HardeningAdvisor.reports(devices: devices,
                                 findings: accessAnalysis?.findings ?? [],
                                 settings: settings)
    }

    func hardeningReport(for device: Device) -> HardeningReport {
        HardeningAdvisor.report(for: device,
                                findings: accessAnalysis?.findings ?? [],
                                settings: settings)
    }

    /// Runs a hardening step's app-side action (if any) through the review sheet.
    func proposeHardeningAction(_ action: HardeningAPIAction, on device: Device) {
        switch action {
        case .disableRoutes: propose(.disableRoutes, on: device)
        case .reenableKeyExpiry: propose(.reenableKeyExpiry, on: device)
        case .revokeApproval: propose(.revokeApproval, on: device)
        case .expireKey: propose(.expireKey, on: device)
        }
    }

    // MARK: - Keys & audit (on demand)

    /// Creates an auth key and returns it (its `key` field holds the
    /// secret, shown once). Errors surface via the global alert.
    func createAuthKey(description: String,
                       reusable: Bool,
                       ephemeral: Bool,
                       preauthorized: Bool,
                       tags: [String],
                       expiryDays: Int) async -> AuthKey? {
        guard let api else { return nil }
        do {
            let key = try await api.createAuthKey(description: description,
                                                  reusable: reusable,
                                                  ephemeral: ephemeral,
                                                  preauthorized: preauthorized,
                                                  tags: tags,
                                                  expirySeconds: expiryDays * 86400)
            await refreshAll()
            return key
        } catch {
            show(error)
            return nil
        }
    }

    /// Configuration audit log for the last `daysBack` days; nil on failure.
    func fetchAuditLogs(daysBack: Int) async -> [AuditLogEntry]? {
        guard let api else { return nil }
        do {
            let logs = try await api.configurationAuditLogs(
                start: Date(timeIntervalSinceNow: -Double(daysBack) * 86400),
                end: .now)
            return logs.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        } catch {
            show(error)
            return nil
        }
    }

    private func breakdown(_ names: [String]) -> [CountedGroup] {
        Dictionary(grouping: names, by: { $0 })
            .map { CountedGroup(name: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}

/// Allows `async let` capture of throwing calls without losing the error.
extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
