import Foundation
import Observation

// MARK: - Change plan

/// Every mutation in the app flows through a ChangePlan: the admin sees
/// exactly what would change, confirms it in one dialog, then watches each
/// operation execute live. Views build plans via the `propose…` helpers on
/// AppState and never call the API directly.
@MainActor
@Observable
final class ChangePlan: Identifiable {
    enum Phase { case preview, running, finished }

    struct Operation: Identifiable {
        enum State: Equatable {
            case pending, running, done
            case failed(String)
        }

        let id = UUID()
        let title: String
        let detail: String?
        let symbol: String
        let isDestructive: Bool
        let run: @MainActor () async throws -> String?
        var state: State = .pending
        /// What actually happened, shown under the row once it has run
        /// (where the backup went, what was confirmed).
        var note: String?

        init(title: String, detail: String?, symbol: String, isDestructive: Bool,
             run: @escaping @MainActor () async throws -> Void) {
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.isDestructive = isDestructive
            self.run = { try await run(); return nil }
        }

        private init(title: String, detail: String?, symbol: String, isDestructive: Bool,
                     runReporting: @escaping @MainActor () async throws -> String?) {
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.isDestructive = isDestructive
            self.run = runReporting
        }

        /// An operation whose result line says what it did.
        static func reporting(title: String, detail: String?, symbol: String, isDestructive: Bool,
                              _ run: @escaping @MainActor () async throws -> String) -> Operation {
            Operation(title: title, detail: detail, symbol: symbol, isDestructive: isDestructive,
                      runReporting: { try await run() })
        }
    }

    /// A file a plan changes, shown as a diff in the review.
    struct FileDiff: Identifiable {
        let id = UUID()
        let title: String
        let lines: [PolicyLineDiff.Line]

        var added: Int { lines.filter { $0.kind == .added }.count }
        var removed: Int { lines.filter { $0.kind == .removed }.count }
    }

    let id = UUID()
    let title: String
    let summary: String?
    var operations: [Operation]
    var phase: Phase = .preview
    /// Set for policy edits: who gains/loses what, Tailscale's verdict and
    /// the file diff. Apply stays disabled until Tailscale accepts it.
    let policyReview: PolicyReview?
    /// Overrides the confirm button's text ("Remove Alex", …).
    var applyLabel: String?
    /// Runs once after the operations have run (e.g. writes People history).
    var onFinish: (@MainActor (ChangePlan) -> Void)?
    /// Stop at the first failed step instead of running the rest (people
    /// changes: never leave someone half-removed).
    var stopsOnFailure = false
    /// Files on servers the plan changes (Caddy settings), shown as diffs.
    var fileDiffs: [FileDiff] = []
    /// Things the admin should know before confirming (shown as warnings).
    var warnings: [String] = []

    init(title: String, summary: String? = nil, operations: [Operation], policyReview: PolicyReview? = nil) {
        self.title = title
        self.summary = summary
        self.operations = operations
        self.policyReview = policyReview
    }

    var canApply: Bool { policyReview.map { $0.validation == .passed } ?? true }

    var destructiveCount: Int { operations.filter(\.isDestructive).count }
    var successCount: Int { operations.filter { $0.state == .done }.count }
    var failureCount: Int {
        operations.filter { if case .failed = $0.state { return true } else { return false } }.count
    }
}

/// A policy edit explained for the review sheet.
@MainActor
@Observable
final class PolicyReview {
    enum Validation: Equatable {
        case checking
        case passed
        case failed(String)
    }

    struct Impact: Identifiable, Hashable {
        let id: String
        let name: String
        let lost: [String]
        let gained: [String]
    }

    var impacts: [Impact]
    /// Shown instead of the list when nobody's access changes.
    var unchangedNote = "No one’s list of reachable machines changes (only ports change)."
    let notes: [String]
    let diff: [PolicyLineDiff.Line]
    var validation: Validation = .checking

    init(impacts: [Impact], notes: [String], diff: [PolicyLineDiff.Line]) {
        self.impacts = impacts
        self.notes = notes
        self.diff = diff
    }

    var addedLines: Int { diff.filter { $0.kind == .added }.count }
    var removedLines: Int { diff.filter { $0.kind == .removed }.count }
}

// MARK: - Change vocabularies

enum DeviceChange {
    case approve
    case revokeApproval
    case expireKey
    case remove
    case disableRoutes
    case reenableKeyExpiry
    case disableKeyExpiry
    case rename(String)
    case setTags([String])
}

enum UserChange {
    case approve
    case suspend
    case restore
    case remove
    case setRole(String)
}

/// The people flows shown in the root sheet.
enum PeopleSheet: Hashable {
    case addPerson
    case pickPerson
    case manage(userID: String)
}

/// Everything RootView's single sheet can show.
enum RootSheet: Identifiable {
    case plan(ChangePlan)
    case people(PeopleSheet)

    var id: String {
        switch self {
        case .plan(let plan): return "plan:\(plan.id)"
        case .people(.addPerson): return "add-person"
        case .people(.pickPerson): return "pick-person"
        case .people(.manage(let id)): return "manage:\(id)"
        }
    }
}

/// One pending edit on the Access Board: add or remove an access group
/// (tag) on a machine. Drops accumulate these; "Review" turns the whole
/// batch into one ChangePlan.
struct StagedChange: Identifiable, Hashable {
    enum Op: Hashable { case add, remove }
    let deviceID: String
    let tag: String
    let op: Op
    var id: String { "\(deviceID)|\(tag)|\(op == .add ? "add" : "remove")" }
}

// MARK: - Proposal builders

extension AppState {

    /// Shows a plan for review. A people screen that proposed it stays
    /// underneath (see `AppState.rootSheet`), so Cancel goes back to it.
    func propose(_ plan: ChangePlan) {
        activePlan = plan
    }

    /// Runs the active plan's operations sequentially, updating each row's
    /// state as it goes, then refreshes all data once.
    func runActivePlan() async {
        guard let plan = activePlan, plan.phase == .preview else { return }
        plan.phase = .running
        for index in plan.operations.indices {
            plan.operations[index].state = .running
            do {
                plan.operations[index].note = try await plan.operations[index].run()
                plan.operations[index].state = .done
            } catch {
                plan.operations[index].state = .failed(error.localizedDescription)
                if plan.stopsOnFailure { break }
            }
        }
        plan.phase = .finished
        plan.onFinish?(plan)
        deviceSharesLoaded = false   // shares may have changed: read them again next time
        await refreshAll()
    }

    /// Cancel returns to the people screen the plan came from; once the
    /// plan has run, Done closes everything.
    func dismissPlan() {
        if activePlan?.phase == .finished { peopleSheet = nil }
        activePlan = nil
    }

    // MARK: Devices

    func operation(for change: DeviceChange, on device: Device) -> ChangePlan.Operation? {
        guard let api else { return nil }
        let name = device.shortName
        let deviceID = device.apiId
        switch change {
        case .approve:
            return .init(title: "Approve \(name)",
                         detail: "The device gains tailnet access immediately.",
                         symbol: "checkmark.circle", isDestructive: false) {
                try await api.setDeviceAuthorized(id: deviceID, authorized: true)
            }
        case .revokeApproval:
            return .init(title: "Revoke approval — \(name)",
                         detail: "The device loses tailnet access until you approve it again.",
                         symbol: "person.crop.circle.badge.xmark", isDestructive: true) {
                try await api.setDeviceAuthorized(id: deviceID, authorized: false)
            }
        case .expireKey:
            return .init(title: "Expire key — \(name)",
                         detail: "Connections drop; the device must re-authenticate to rejoin.",
                         symbol: "clock.badge.xmark", isDestructive: true) {
                try await api.expireDeviceKey(id: deviceID)
            }
        case .remove:
            return .init(title: "Remove \(name) from the network",
                         detail: "Disconnects immediately and stays off until added again.",
                         symbol: "trash", isDestructive: true) {
                try await api.deleteDevice(id: deviceID)
            }
        case .disableRoutes:
            let routes = (device.enabledRoutes ?? []).joined(separator: ", ")
            return .init(title: "Disable routes — \(name)",
                         detail: "Stops routing \(routes.isEmpty ? "LAN/internet traffic" : routes). Connections through it drop.",
                         symbol: "arrow.triangle.branch", isDestructive: true) {
                try await api.setDeviceRoutes(id: deviceID, routes: [])
            }
        case .reenableKeyExpiry:
            return .init(title: "Re-enable key expiry — \(name)",
                         detail: "If the original expiry date has passed, the device must re-authenticate right away.",
                         symbol: "clock.arrow.circlepath", isDestructive: false) {
                try await api.setKeyExpiryDisabled(id: deviceID, disabled: false)
            }
        case .disableKeyExpiry:
            return .init(title: "Disable key expiry — \(name)",
                         detail: "The node key stops expiring. Revoke it manually if the device is ever lost.",
                         symbol: "clock.badge.checkmark", isDestructive: false) {
                try await api.setKeyExpiryDisabled(id: deviceID, disabled: true)
            }
        case .rename(let newName):
            return .init(title: "Rename \(name) → \(newName)",
                         detail: "Existing MagicDNS URLs for the old name stop working.",
                         symbol: "pencil", isDestructive: false) {
                try await api.renameDevice(id: deviceID, name: newName)
            }
        case .setTags(let tags):
            return .init(title: "Set tags on \(name)",
                         detail: "Tags become: \(tags.joined(separator: ", ")). Tagging removes user identity from the device.",
                         symbol: "tag", isDestructive: false) {
                try await api.setDeviceTags(id: deviceID, tags: tags)
            }
        }
    }

    func propose(_ change: DeviceChange, on device: Device) {
        guard let op = operation(for: change, on: device) else { return }
        propose(ChangePlan(title: "Review change", operations: [op]))
    }

    /// One plan applying the same change to many devices.
    func propose(_ change: DeviceChange, on devices: [Device], title: String, summary: String? = nil) {
        let ops = devices.compactMap { operation(for: change, on: $0) }
        guard !ops.isEmpty else { return }
        propose(ChangePlan(title: title, summary: summary, operations: ops))
    }

    /// Turns a batch of staged Access Board edits into ONE review plan:
    /// per machine, computes the final tag set (current ∪ adds − removes)
    /// and emits a single .setTags operation — the whole board rides on the
    /// existing ChangePlan machinery, and every write is the FULL tag set
    /// (never a partial that could clobber other groups).
    func proposeAccessChanges(_ staged: [StagedChange]) {
        guard api != nil, !staged.isEmpty else { return }
        let byDevice = Dictionary(grouping: staged, by: \.deviceID)
        var ops: [ChangePlan.Operation] = []
        var skipped: [String] = []

        for (deviceID, changes) in byDevice {
            guard let device = devices.first(where: { $0.id == deviceID }),
                  device.isExternal != true else { continue }

            var tags = Set(device.tags ?? [])
            let before = tags
            for change in changes {
                switch change.op {
                case .add: tags.insert(change.tag)
                case .remove: tags.remove(change.tag)
                }
            }
            // Backstop for the zero-tag rule — the UI blocks this, but never
            // emit an empty tag set to the API.
            if tags.isEmpty {
                skipped.append(device.shortName)
                continue
            }
            guard tags != before else { continue }
            if let op = operation(for: .setTags(tags.sorted()), on: device) {
                ops.append(op)
            }
        }

        if !skipped.isEmpty {
            errorMessage = "Kept in at least one access group: \(skipped.joined(separator: ", ")). A machine can't be left with no group."
        }
        guard !ops.isEmpty else { return }

        let machineWord = ops.count == 1 ? "machine" : "machines"
        propose(ChangePlan(
            title: "Review access changes",
            summary: "Updates the access groups on \(ops.count) \(machineWord). Each line shows the machine's full resulting group set — everyone your policy grants those groups will be able to reach it.",
            operations: ops))
    }

    /// The lockdown bundle: selected mitigations across selected servers.
    func proposeLockdown(devices: [Device], expireKeys: Bool, revokeApproval: Bool, disableRoutes: Bool) {
        var ops: [ChangePlan.Operation] = []
        for device in devices {
            if disableRoutes, device.enabledRoutes?.isEmpty == false,
               let op = operation(for: .disableRoutes, on: device) { ops.append(op) }
            if revokeApproval, device.authorized != false,
               let op = operation(for: .revokeApproval, on: device) { ops.append(op) }
            if expireKeys, let op = operation(for: .expireKey, on: device) { ops.append(op) }
        }
        guard !ops.isEmpty else { return }
        propose(ChangePlan(title: "Lockdown \(devices.count) server\(devices.count == 1 ? "" : "s")",
                           summary: "Applies the selected mitigations in order. Each device is listed below with exactly what will happen.",
                           operations: ops))
    }

    // MARK: Access switches (policy edits)

    /// Flips a person's access switch. Flipping it back to where it started
    /// cancels the pending change instead of stacking a second one.
    func setAccess(login: String, target: AccessTarget, on: Bool, currentlyOn: Bool) {
        stagedAccess.removeAll { $0.login == login && $0.target == target }
        if on != currentlyOn {
            stagedAccess.append(AccessToggle(login: login, target: target, grant: on))
        }
    }

    func pendingAccess(login: String, target: AccessTarget) -> AccessToggle? {
        stagedAccess.first { $0.login == login && $0.target == target }
    }

    /// Compiles every pending switch into ONE policy edit and opens review.
    func proposeAccessEdits() {
        guard let original = policyFile, policyETag != nil else {
            errorMessage = "Still loading — try again in a moment."
            return
        }
        let toggles = stagedAccess
        let result: AccessEditResult
        do {
            result = try AccessEditor.apply(toggles, to: original, users: users, devices: manageableDevices)
        } catch {
            show(error)
            return
        }
        guard result.text != original else {
            stagedAccess = []
            errorMessage = "Those switches already match your policy, so there’s nothing to save."
            return
        }
        proposePolicyEdit(result.text, basedOn: original, notes: result.notes,
                          title: "Review access changes", clearsStagedAccess: true) { [weak self] plan, backup in
            self?.recordAccessSwitches(toggles, plan: plan, backup: backup)
        }
    }

    /// One People history entry per person whose switches were saved.
    private func recordAccessSwitches(_ toggles: [AccessToggle], plan: ChangePlan, backup: String?) {
        let admin = currentAdmin?.loginName
        for (login, changes) in Dictionary(grouping: toggles, by: \.login) {
            let person = users.first { $0.loginName == login }
            let lines = changes.map { toggle -> String in
                let what: String
                switch toggle.target {
                case .group(let tag): what = AccessEditor.accessGroupName(tag)
                case .machine(let id): what = device(id: id)?.shortName ?? "a machine"
                }
                return "\(what): \(toggle.grant ? "given access" : "access taken away")"
            }
            record(PeopleLogEntry(date: .now, kind: .changed, name: person?.title ?? login, login: login,
                                  role: person?.role, reason: "", performedBy: admin, snapshot: lines,
                                  steps: plan.logSteps, policyBackup: backup))
        }
    }

    /// Puts a backed-up policy back, through the same review and checks.
    func proposePolicyRestore(_ backup: PolicyBackupStore.Backup) {
        guard let original = policyFile, policyETag != nil,
              let text = PolicyBackupStore.read(backup) else {
            errorMessage = "That backup couldn’t be read, or the current policy isn’t loaded."
            return
        }
        guard text != original else {
            errorMessage = "That backup is identical to your current policy."
            return
        }
        let when = backup.date.formatted(date: .abbreviated, time: .shortened)
        proposePolicyEdit(text, basedOn: original,
                          notes: ["Restores the policy as it was before the change made \(when)."],
                          title: "Restore policy", clearsStagedAccess: false)
    }

    private func proposePolicyEdit(_ newText: String, basedOn original: String, notes: [String],
                                   title: String, clearsStagedAccess: Bool,
                                   onFinish: (@MainActor (ChangePlan, _ backup: String?) -> Void)? = nil) {
        let backup = Box<String?>(nil)
        guard let step = policySaveStep(newText, basedOn: original, notes: notes,
                                        onSaved: { [weak self] url in
                                            backup.value = url.lastPathComponent
                                            if clearsStagedAccess { self?.stagedAccess = [] }
                                        }) else { return }
        let plan = ChangePlan(title: title, operations: [step.operation], policyReview: step.review)
        if let onFinish {
            plan.onFinish = { plan in onFinish(plan, backup.value) }
        }
        propose(plan)
    }

    /// The guarded policy save used by every policy edit: a review (who gains
    /// or loses what, the diff, Tailscale's verdict — checked in the
    /// background) and one operation that backs up the current policy, then
    /// saves with If-Match. `extraPeople` are people not in the tailnet yet
    /// (an invitee) whose access the review should show too. nil when the
    /// policy can't be saved from here (GitOps) — errorMessage says why.
    func policySaveStep(_ newText: String, basedOn original: String, notes: [String],
                        extraPeople: [TSUser] = [],
                        onSaved: @escaping @MainActor (_ backup: URL) -> Void = { _ in })
        -> (operation: ChangePlan.Operation, review: PolicyReview)? {
        guard let api, let etag = policyETag else {
            errorMessage = "Still loading — try again in a moment."
            return nil
        }
        if settings?.aclsExternallyManagedOn == true {
            errorMessage = "Your policy is managed outside Tailscale (GitOps). Make this change there — a save from this app would be overwritten by your next sync."
            return nil
        }
        let review = PolicyReview(impacts: accessImpact(from: original, to: newText, extraPeople: extraPeople),
                                  notes: notes,
                                  diff: PolicyLineDiff.lines(old: original, new: newText))
        let save = ChangePlan.Operation(
            title: "Save the policy to Tailscale",
            detail: "Your current policy is backed up on this device first (restore it from Settings → Policy file & backups). Tailscale applies the change to every machine within seconds.",
            symbol: "lock.shield", isDestructive: false) {
            let backup = try PolicyBackupStore.save(original)
            try await api.savePolicyFile(newText, ifMatch: etag)
            onSaved(backup)
        }

        Task { [weak self] in
            let verdict: PolicyReview.Validation
            do {
                if let failure = try await api.validatePolicyFile(newText) {
                    verdict = .failed(self?.friendlyValidation(failure) ?? failure)
                } else {
                    verdict = .passed
                }
            } catch {
                verdict = .failed(error.localizedDescription)
            }
            review.validation = verdict
        }
        return (save, review)
    }

    /// Who reaches which machines before vs after — computed with the same
    /// analyzer that drives every access view.
    private func accessImpact(from old: String, to new: String, extraPeople: [TSUser] = []) -> [PolicyReview.Impact] {
        let people = users + extraPeople
        func reach(_ text: String) -> AccessReachability {
            PolicyAnalyzer.analyze(model: PolicyAnalyzer.parse(policyText: text),
                                   devices: devices, users: people, settings: settings).reachability
        }
        func names(_ ids: Set<String>) -> [String] {
            devices.filter { ids.contains($0.id) }.map(\.shortName)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        let before = reach(old), after = reach(new)
        var impacts: [PolicyReview.Impact] = []
        for user in (memberUsers + extraPeople).sorted(by: { $0.title < $1.title }) {
            // Someone who hasn't joined yet reaches nothing today.
            let isNew = extraPeople.contains { $0.loginName == user.loginName }
            let was = isNew ? [] : before.reachableByPerson[user.loginName] ?? []
            let now = after.reachableByPerson[user.loginName] ?? []
            guard was != now else { continue }
            impacts.append(.init(id: user.loginName, name: user.title,
                                 lost: names(was.subtracting(now)), gained: names(now.subtracting(was))))
        }
        var machineLost = 0, machineGained = 0
        for id in Set(before.machineReach.keys).union(after.machineReach.keys) {
            let was = before.machineReach[id] ?? [], now = after.machineReach[id] ?? []
            machineLost += was.subtracting(now).count
            machineGained += now.subtracting(was).count
        }
        if machineLost + machineGained > 0 {
            impacts.append(.init(id: "machines", name: "Machine-to-machine links",
                                 lost: machineLost > 0 ? ["\(machineLost) link\(machineLost == 1 ? "" : "s")"] : [],
                                 gained: machineGained > 0 ? ["\(machineGained) link\(machineGained == 1 ? "" : "s")"] : []))
        }
        return impacts
    }

    /// Rewrites Tailscale's test failures in plain words, with machine names.
    private func friendlyValidation(_ message: String) -> String {
        let pattern = /^(.+?): \[acl test error\]: address "(.+):(\d+)".*want: (\w+), got: (\w+)/
        var lines: [String] = []
        var testFailed = false
        for line in message.components(separatedBy: "\n") where line != "test(s) failed" {
            guard let match = line.firstMatch(of: pattern) else {
                lines.append(line)
                continue
            }
            testFailed = true
            let login = String(match.1), address = String(match.2), port = String(match.3)
            let who = users.first { $0.loginName == login }?.title ?? login
            let machine = devices.first { ($0.addresses ?? []).contains(address) }?.shortName ?? address
            lines.append(match.4 == "Accept"
                ? "Your policy’s tests say \(who) must reach \(machine) on port \(port). This change would block that."
                : "Your policy’s tests say \(who) must not reach \(machine) on port \(port). This change would allow it.")
        }
        if testFailed {
            lines.append("Nothing was saved. If this is intended, change or remove that test on the Tailscale website first.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Users

    func operation(for change: UserChange, on user: TSUser) -> ChangePlan.Operation? {
        guard let api else { return nil }
        let name = user.title
        let userID = user.id
        switch change {
        case .approve:
            return .init(title: "Approve \(name)",
                         detail: "The user and their devices gain tailnet access.",
                         symbol: "checkmark.circle", isDestructive: false) {
                try await api.approveUser(id: userID)
            }
        case .suspend:
            return .init(title: "Pause \(name)’s access",
                         detail: "Locked out of every device until you resume. Nothing is deleted.",
                         symbol: "person.slash", isDestructive: true) {
                try await api.suspendUser(id: userID)
            }
        case .restore:
            return .init(title: "Resume \(name)’s access",
                         detail: "They can connect again.",
                         symbol: "person.crop.circle.badge.checkmark", isDestructive: false) {
                try await api.restoreUser(id: userID)
            }
        case .remove:
            return .init(title: "Delete \(name)’s account",
                         detail: "Can’t be undone. Their devices and sign-in keys go with it.",
                         symbol: "trash", isDestructive: true) {
                try await api.deleteUser(id: userID)
            }
        case .setRole(let role):
            return .init(title: "Change \(name)'s role to \(UserRole.label(for: role))",
                         detail: "Takes effect immediately. Tailscale rejects changing your own role.",
                         symbol: "person.badge.key", isDestructive: false) {
                try await api.setUserRole(id: userID, role: role)
            }
        }
    }

    func propose(_ change: UserChange, on user: TSUser) {
        guard let op = operation(for: change, on: user) else { return }
        propose(ChangePlan(title: "Review change", operations: [op]))
    }

    // MARK: Invites

    func proposeRevokeInvite(_ invite: UserInvite) {
        guard let api else { return }
        let label = invite.hasEmail ? (invite.email ?? "invite") : "the invite link"
        propose(ChangePlan(title: "Review change", operations: [
            .init(title: "Revoke \(label)",
                  detail: "The invite stops working immediately; nobody holding it can join.",
                  symbol: "envelope.badge.shield.half.filled", isDestructive: true) {
                try await api.deleteUserInvite(id: invite.id)
            },
        ]))
    }

    func proposeResendInvite(_ invite: UserInvite) {
        guard let api, invite.hasEmail else { return }
        propose(ChangePlan(title: "Review change", operations: [
            .init(title: "Resend invite to \(invite.email ?? "")",
                  detail: "Sends the invite email again (Tailscale allows one resend per minute).",
                  symbol: "envelope.arrow.triangle.branch", isDestructive: false) {
                try await api.resendUserInvite(id: invite.id)
            },
        ]))
    }

    // MARK: Updates

    /// "Trigger update" for the given machines — as close as the public
    /// API allows: (re)asserts tailnet auto-updates so the clients install
    /// the latest release at their next check-in. The plan's summary tells
    /// the admin exactly which machines are affected and how to force an
    /// immediate update if they can't wait.
    func proposeTriggerUpdates(devices: [Device]) {
        guard let api, !devices.isEmpty else { return }
        let names = devices.map(\.shortName).joined(separator: ", ")
        let autoAlreadyOn = settings?.devicesAutoUpdatesOn == true
        let title = devices.count == 1
            ? "Update \(devices[0].shortName)"
            : "Update \(devices.count) machines"
        propose(ChangePlan(
            title: title,
            summary: "Tailscale's API can't force an instant update, so this \(autoAlreadyOn ? "re-asserts" : "turns on") tailnet auto-updates: \(names) will install the latest client at the next check-in (typically minutes to a few hours). Can't wait? Run “sudo tailscale update” on the machine, or use Update in the admin console.",
            operations: [
                .init(title: autoAlreadyOn ? "Re-assert tailnet auto-updates" : "Turn on tailnet auto-updates",
                      detail: "Every device with an update available installs the latest stable Tailscale client automatically.",
                      symbol: "arrow.down.circle", isDestructive: false) {
                    try await api.updateTailnetSettings(["devicesAutoUpdatesOn": true])
                },
            ]))
    }

    // MARK: Keys

    func proposeRevokeKey(_ key: AuthKey) {
        guard let api else { return }
        propose(ChangePlan(title: "Review change", operations: [
            .init(title: "Revoke key \(key.description?.isEmpty == false ? "“\(key.description!)”" : key.id)",
                  detail: "The key stops working immediately. Devices already enrolled with it stay on the tailnet.",
                  symbol: "key.slash", isDestructive: true) {
                try await api.revokeKey(id: key.id)
            },
        ]))
    }

    // MARK: Settings & DNS

    func proposeSetting(key: String, value: Any, title: String, detail: String) {
        guard let api else { return }
        propose(ChangePlan(title: "Review change", operations: [
            .init(title: title, detail: detail, symbol: "gearshape", isDestructive: false) {
                try await api.updateTailnetSettings([key: value])
            },
        ]))
    }

    func proposeMagicDNS(_ enabled: Bool) {
        guard let api else { return }
        propose(ChangePlan(title: "Review change", operations: [
            .init(title: enabled ? "Turn MagicDNS on" : "Turn MagicDNS off",
                  detail: enabled
                      ? "Devices become reachable by name across the tailnet."
                      : "Name-based access stops working; devices are reachable by IP only.",
                  symbol: "network", isDestructive: !enabled) {
                try await api.setMagicDNS(enabled)
            },
        ]))
    }

    func proposeNameservers(_ dns: [String]) {
        guard let api else { return }
        propose(ChangePlan(title: "Review change", operations: [
            .init(title: "Set tailnet DNS servers",
                  detail: dns.isEmpty ? "Removes all global nameservers — devices fall back to their local DNS."
                                      : "Nameservers become: \(dns.joined(separator: ", ")). Applies to every device.",
                  symbol: "server.rack", isDestructive: dns.isEmpty) {
                try await api.setDNSNameservers(dns)
            },
        ]))
    }

    func proposeSearchPaths(_ paths: [String]) {
        guard let api else { return }
        propose(ChangePlan(title: "Review change", operations: [
            .init(title: "Set DNS search domains",
                  detail: paths.isEmpty ? "Removes all search domains."
                                        : "Search domains become: \(paths.joined(separator: ", ")).",
                  symbol: "magnifyingglass", isDestructive: false) {
                try await api.setDNSSearchPaths(paths)
            },
        ]))
    }
}
