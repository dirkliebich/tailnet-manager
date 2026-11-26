import Foundation

// MARK: - What removing someone touches

/// Everything the network holds for one person, gathered for the
/// "Remove from network" screen and People history.
struct RemovalInventory {
    let user: TSUser
    /// Untagged machines signed in as them — deleted with the account.
    let personalMachines: [Device]
    /// Tagged machines they registered. Tags own these, so they stay.
    let taggedMachines: [Device]
    /// Their auth keys and API tokens. Tailscale revokes these itself when
    /// the account is deleted (suspended: they stop working).
    let personalKeys: [AuthKey]
    /// OAuth clients / federated credentials they created. These belong to
    /// the tailnet and keep working after the person is gone.
    let automationKeys: [AuthKey]
    /// Pending invites addressed to them.
    let invites: [UserInvite]
    /// Guests: the machines shared with them (removing stops each share).
    let sharedMachines: [(device: Device, share: DeviceInvite)]
    /// Policy groups (teams) they're in.
    let teams: [String]
    /// Every place the policy names them.
    let policyMentions: [String]
    /// The access rules are loaded (nothing about them can be said otherwise).
    let policyLoaded: Bool
    /// Rules live in a GitOps repo: the app mustn't change them.
    let rulesManagedElsewhere: Bool
    /// Taking them off the rules would change something.
    let cleanupChangesRules: Bool
    /// Places that would still name them after the cleanup.
    let cleanupLeftovers: [String]
    let reachableCount: Int
    /// Why they can't be removed from here, if they can't.
    let blocker: String?
}

enum RemovalMode {
    case delete, suspend
}

extension AppState {

    /// The admin the app is acting as: the owner of this API token.
    var currentAdmin: TSUser? {
        guard let keyID = api?.keyID,
              let owner = authKeys.first(where: { $0.id == keyID })?.userId else { return nil }
        return users.first { $0.id == owner }
    }

    func removalInventory(for user: TSUser) -> RemovalInventory {
        let login = user.loginName
        let owned = devices.filter { ($0.user ?? "").caseInsensitiveCompare(login) == .orderedSame && $0.isExternal != true }
        let keys = authKeys.filter { $0.userId == user.id && $0.isActive }
        let policyMentions = policyFile.map { PolicyPersonScrubber.mentions(of: login, in: $0) } ?? []
        let scrubbed = policyMentions.isEmpty ? nil : policyFile.flatMap { try? PolicyPersonScrubber.scrub(login, from: $0) }

        let blocker: String?
        if user.isOwner {
            blocker = "\(user.title) owns this network. Make someone else the owner on the Tailscale website first."
        } else if let me = currentAdmin, me.id == user.id {
            blocker = "That’s you — you can’t remove yourself."
        } else {
            blocker = nil
        }

        return RemovalInventory(
            user: user,
            personalMachines: owned.filter { !$0.isTagged },
            taggedMachines: owned.filter(\.isTagged),
            personalKeys: keys.filter { $0.isAuthKey || $0.isAPIToken },
            automationKeys: keys.filter { !$0.isAuthKey && !$0.isAPIToken },
            invites: invites.filter { ($0.email ?? "").caseInsensitiveCompare(login) == .orderedSame },
            sharedMachines: user.isExternal ? sharedMachines(with: user) : [],
            teams: teams(of: user).sorted(),
            policyMentions: policyMentions,
            policyLoaded: policyFile != nil,
            rulesManagedElsewhere: settings?.aclsExternallyManagedOn == true,
            cleanupChangesRules: scrubbed.map { $0.text != policyFile } ?? false,
            cleanupLeftovers: scrubbed?.leftovers ?? (policyMentions.isEmpty ? [] : policyMentions),
            reachableCount: machinesReachable(by: user),
            blocker: blocker)
    }

    // MARK: Remove a person

    /// One reviewed plan that removes (or pauses) a person, then records it
    /// in People history. Steps stop at the first failure, so a refused
    /// account deletion never leaves someone half-removed.
    ///
    /// Remove: account (Tailscale deletes their devices and keys with it) →
    /// pending invites → access rules → chosen automation keys.
    /// Guest: stop each share → access rules.  Pause: suspend the account.
    func proposeRemoval(_ inventory: RemovalInventory, mode: RemovalMode, reason: String = "",
                        cleanPolicy: Bool = false, revokeKeyIDs: Set<String> = []) {
        guard let api, inventory.blocker == nil else { return }
        let user = inventory.user
        let cleanRules = cleanPolicy && mode == .delete && !inventory.rulesManagedElsewhere
        if cleanRules && !inventory.policyLoaded {
            errorMessage = "Still loading — try again in a moment."
            return
        }
        if user.isExternal && !deviceSharesLoaded {
            errorMessage = "Still checking which machines are shared with \(user.title) — try again in a moment."
            return
        }
        var ops: [ChangePlan.Operation] = []
        var review: PolicyReview?
        let backupName = Box<String?>(nil)

        // 1. Access rules first: backed up and reversible, and if the save is
        //    refused nothing else has happened yet.
        if cleanRules, let original = policyFile, inventory.cleanupChangesRules {
            let scrubbed: PolicyPersonScrubber.Result
            do {
                scrubbed = try PolicyPersonScrubber.scrub(user.loginName, from: original)
            } catch {
                show(error)
                return
            }
            let notes = scrubbed.leftovers.isEmpty ? [] :
                ["They’re still named somewhere the app can’t change. Check your access rules on the Tailscale website."]
            guard let step = policySaveStep(scrubbed.text, basedOn: original, notes: notes,
                                            onSaved: { url in backupName.value = url.lastPathComponent })
            else { return }
            ops.append(.init(title: "Remove \(user.title) from all access rules",
                             detail: "Everyone else keeps their access. A backup is saved first.",
                             symbol: "lock.shield", isDestructive: false, run: { [run = step.operation.run] in _ = try await run() }))
            // Their own loss is the point; the review shows everyone else.
            step.review.impacts.removeAll { $0.id == user.loginName }
            step.review.unchangedNote = "Nobody else loses or gains access."
            review = step.review
        }

        // 2. Pending invites to their address.
        if mode == .delete {
            for invite in inventory.invites {
                ops.append(.init(title: "Cancel their pending invite",
                                 detail: "Nobody can join with it any more.",
                                 symbol: "envelope.badge.shield.half.filled", isDestructive: true) {
                    try await api.deleteUserInvite(id: invite.id)
                })
            }
        }

        // 3. Automation keys the admin chose to turn off.
        for key in inventory.automationKeys where mode == .delete && revokeKeyIDs.contains(key.id) {
            ops.append(.init(title: "Turn off automation key \(key.displayName)",
                             detail: "Anything that uses it stops working.",
                             symbol: "key.slash", isDestructive: true) {
                try await api.revokeKey(id: key.id)
            })
        }

        // 4. Last, the step that can't be undone.
        if user.isExternal {
            // A guest's account lives in their own network: stop every share.
            for (device, share) in inventory.sharedMachines {
                let pending = share.accepted != true
                ops.append(.init(title: pending ? "Cancel the invite to use \(device.shortName)"
                                                : "Stop sharing \(device.shortName) with \(user.title)",
                                 detail: pending ? "The emailed link stops working." : "They can’t reach it any more.",
                                 symbol: "rectangle.portrait.and.arrow.right", isDestructive: true) {
                    try await api.deleteDeviceInvite(id: share.id.value)
                })
            }
        } else if mode == .delete {
            if let op = operation(for: .remove, on: user) { ops.append(op) }
        } else if !user.isSuspended, let op = operation(for: .suspend, on: user) {
            ops.append(op)
        }

        guard !ops.isEmpty else {
            errorMessage = user.isExternal
                ? "Nothing is shared with \(user.title) and no access rule names them — nothing to remove."
                : "\(user.title)’s access is already paused — nothing else to do."
            return
        }

        let snapshot = removalSnapshot(inventory, mode: mode)
        let admin = currentAdmin?.loginName
        let plan = ChangePlan(
            title: mode == .delete ? "Remove \(user.title)" : "Pause \(user.title)’s access",
            summary: removalSummary(inventory, mode: mode),
            operations: ops,
            policyReview: review)
        plan.applyLabel = mode == .delete ? "Remove \(user.title)" : "Pause access"
        plan.stopsOnFailure = true
        plan.onFinish = { [weak self] plan in
            self?.record(PeopleLogEntry(
                date: .now, kind: mode == .delete ? .removed : .suspended,
                name: user.title, login: user.loginName, role: user.role,
                reason: reason, performedBy: admin, snapshot: snapshot,
                steps: plan.logSteps, policyBackup: backupName.value))
        }
        propose(plan)
    }

    private func removalSummary(_ inv: RemovalInventory, mode: RemovalMode) -> String {
        var parts = [inv.user.isExternal
            ? "\(inv.user.title) can’t reach your machines any more."
            : mode == .delete
            ? "\(inv.user.title) is locked out right away. To stop them joining again, also turn off their company login (for example Google)."
            : "\(inv.user.title) is locked out right away. Undo it any time from their page."]
        if !inv.taggedMachines.isEmpty {
            parts.append("Servers they set up stay online.")
        }
        parts.append("Saved to People history.")
        return parts.joined(separator: " ")
    }

    private func removalSnapshot(_ inv: RemovalInventory, mode: RemovalMode) -> [String] {
        var lines = [inv.user.isExternal ? "Guest from another network" : "Role: \(inv.user.roleLabel)", "Could reach \(inv.reachableCount) machine\(inv.reachableCount == 1 ? "" : "s")"]
        if let joined = inv.user.createdDate {
            lines.append("Member since \(joined.formatted(date: .abbreviated, time: .omitted))")
        }
        if !inv.personalMachines.isEmpty {
            let verb = mode == .delete ? "Devices removed" : "Devices (kept, locked out)"
            lines.append("\(verb): " + inv.personalMachines.map { "\($0.shortName) (\($0.prettyOS)\($0.primaryAddress.map { ", \($0)" } ?? ""))" }.joined(separator: ", "))
        }
        if !inv.sharedMachines.isEmpty {
            lines.append("Machines shared with them: " + inv.sharedMachines.map(\.device.shortName).joined(separator: ", "))
        }
        if !inv.taggedMachines.isEmpty {
            lines.append("Servers they set up (kept): " + inv.taggedMachines.map(\.shortName).joined(separator: ", "))
        }
        if !inv.teams.isEmpty { lines.append("Teams: " + inv.teams.map(teamDisplayName).joined(separator: ", ")) }
        if !inv.personalKeys.isEmpty {
            lines.append("Sign-in keys (\(mode == .delete ? "revoked" : "stop working")): " + inv.personalKeys.map(\.displayName).joined(separator: ", "))
        }
        if !inv.automationKeys.isEmpty {
            lines.append("Automation keys they made: " + inv.automationKeys.map(\.displayName).joined(separator: ", "))
        }
        return lines
    }

    /// Lets a paused person back in, recorded in People history.
    func proposeResume(_ user: TSUser) {
        guard let op = operation(for: .restore, on: user) else { return }
        proposeLogged(ChangePlan(title: "Resume \(user.title)’s access", operations: [op]),
                      kind: .resumed, user: user, snapshot: ["Access resumed"])
    }

    /// Approves someone waiting to join, recorded in People history.
    func proposeApprove(_ user: TSUser) {
        guard let op = operation(for: .approve, on: user) else { return }
        proposeLogged(ChangePlan(title: "Approve \(user.title)", operations: [op]),
                      kind: .approved, user: user, snapshot: ["Approved to join"])
    }

    private func proposeLogged(_ plan: ChangePlan, kind: PeopleLogEntry.Kind, user: TSUser, snapshot: [String]) {
        let admin = currentAdmin?.loginName
        plan.onFinish = { [weak self] plan in
            self?.record(PeopleLogEntry(date: .now, kind: kind, name: user.title, login: user.loginName,
                                        role: user.role, reason: "", performedBy: admin, snapshot: snapshot,
                                        steps: plan.logSteps, policyBackup: nil))
        }
        propose(plan)
    }

    // MARK: Change email, teams or role

    /// Teams (policy groups) the person is in today.
    func teams(of user: TSUser) -> Set<String> {
        Set((policyModel?.groups ?? [:])
            .filter { $0.value.contains { $0.caseInsensitiveCompare(user.loginName) == .orderedSame } }
            .keys)
    }

    /// One confirmation for a change made from "Change or remove": role,
    /// teams, and a new email (same access copied, invite sent, old account
    /// kept until removed — Tailscale can't rename an account).
    func proposeEdit(_ user: TSUser, email: String, role: String, teams newTeams: Set<String>) {
        guard let api else { return }
        let newEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let emailChanged = !newEmail.isEmpty && newEmail.caseInsensitiveCompare(user.loginName) != .orderedSame
        let oldTeams = teams(of: user)
        let joins = newTeams.subtracting(oldTeams).sorted()
        let leaves = oldTeams.subtracting(newTeams).sorted()
        let roleChanged = role != (user.role ?? "member") && !user.isOwner && !user.isExternal
        var ops: [ChangePlan.Operation] = []
        var review: PolicyReview?
        let backupName = Box<String?>(nil)
        var changes: [String] = []

        if roleChanged, let op = operation(for: .setRole(role), on: user) {
            ops.append(op)
            changes.append("Role: \(UserRole.label(for: role))")
        }

        if emailChanged && policyFile == nil {
            errorMessage = "Still loading — try again in a moment."
            return
        }
        if emailChanged && user.isExternal && !deviceSharesLoaded {
            errorMessage = "Still checking which machines are shared with \(user.title) — try again in a moment."
            return
        }
        // The owner role can't be given by invite; the new address joins as an admin.
        let inviteRole = UserRole.assignable.contains(role) ? role : "admin"
        let mentioned = policyFile.map { !PolicyPersonScrubber.mentions(of: user.loginName, in: $0).isEmpty } ?? false
        if !joins.isEmpty || !leaves.isEmpty || (emailChanged && mentioned) {
            guard let original = policyFile, policyETag != nil else {
                errorMessage = "Still loading — try again in a moment."
                return
            }
            var text = original
            do {
                text = try PolicyTeamEditor.remove(user.loginName, fromTeams: leaves, in: text)
                text = try PersonPolicyAdder.add(user, toTeams: joins, accessGroups: [], in: text,
                                                 devices: manageableDevices).text
                if emailChanged {
                    text = try PolicyPersonCopier.copy(user.loginName, to: newEmail, in: text).text
                }
            } catch {
                show(error)
                return
            }
            var what = joins.map { "Joins \(teamDisplayName($0))" } + leaves.map { "Leaves \(teamDisplayName($0))" }
            if emailChanged && mentioned { what.append("Same access for \(newEmail)") }
            if text != original {
                let alreadyMember = users.contains { $0.loginName.caseInsensitiveCompare(newEmail) == .orderedSame }
                // Guests don't join as members, so they aren't previewed as one.
                let newcomer = emailChanged && !alreadyMember && !user.isExternal
                    ? [TSUser.pending(email: newEmail, role: inviteRole)] : []
                guard let step = policySaveStep(text, basedOn: original, notes: [], extraPeople: newcomer,
                                                onSaved: { url in backupName.value = url.lastPathComponent })
                else { return }
                ops.append(.init(title: "Update \(user.title)’s access",
                                 detail: what.joined(separator: " · ") + ". A backup is saved first.",
                                 symbol: "lock.shield", isDestructive: false, run: { [run = step.operation.run] in _ = try await run() }))
                step.review.unchangedNote = "No machines change for anyone."
                review = step.review
                changes += what
            }
        }

        if emailChanged && user.isExternal {
            // Guests: share the same machines with the new address.
            var seen = Set<String>()
            for (device, share) in sharedMachines(with: user) where seen.insert(device.apiId).inserted {
                let exitNode = share.allowExitNode ?? false
                ops.append(.init(title: "Share \(device.shortName) with \(newEmail)",
                                 detail: "They get an email to accept it.",
                                 symbol: "envelope", isDestructive: false) {
                    try await api.shareDevice(id: device.apiId, with: newEmail, allowExitNode: exitNode)
                })
            }
            changes.append("New email: \(newEmail) (old address kept until removed)")
        } else if emailChanged {
            let alreadyMember = users.contains { $0.loginName.caseInsensitiveCompare(newEmail) == .orderedSame }
            let alreadyInvited = invites.contains { ($0.email ?? "").caseInsensitiveCompare(newEmail) == .orderedSame }
            if !alreadyMember && !alreadyInvited {
                ops.append(.init(title: "Email an invite to \(newEmail)",
                                 detail: "Role: \(UserRole.label(for: inviteRole)). They sign in with it on their devices; the old account keeps working until you remove it.",
                                 symbol: "envelope", isDestructive: false) {
                    try await api.createUserInvite(email: newEmail, role: inviteRole)
                })
            }
            changes.append("New email: \(newEmail) (old account kept until removed)")
        }

        guard !ops.isEmpty else {
            errorMessage = "Nothing changed."
            return
        }

        let admin = currentAdmin?.loginName
        let changed = [emailChanged ? "email" : nil, joins.isEmpty && leaves.isEmpty ? nil : "teams",
                       roleChanged ? "role" : nil].compactMap { $0 }
        let plan = ChangePlan(
            title: changed.count == 1 ? "Change \(user.title)’s \(changed[0])" : "Update \(user.title)",
            summary: (emailChanged
                ? "Their old account keeps working until you remove it — do that once they’ve signed in with \(newEmail). "
                : "") + "Saved to People history.",
            operations: ops,
            policyReview: review)
        plan.applyLabel = "Save changes"
        plan.stopsOnFailure = true
        plan.onFinish = { [weak self] plan in
            self?.record(PeopleLogEntry(
                date: .now, kind: .changed, name: user.title,
                login: emailChanged ? "\(user.loginName) → \(newEmail)" : user.loginName, role: role,
                reason: "", performedBy: admin, snapshot: changes,
                steps: plan.logSteps, policyBackup: backupName.value))
        }
        propose(plan)
    }

    // MARK: Add a person

    /// One reviewed plan that prepares a new person's access in the policy
    /// (teams + access groups) and sends the invite, then logs it.
    func proposeOnboarding(email: String, role: String, teams: [String], accessGroups: [String],
                           sendInvite: Bool, reason: String) {
        guard let api else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let person = TSUser.pending(email: email, role: role)
        var ops: [ChangePlan.Operation] = []
        var review: PolicyReview?
        let backupName = Box<String?>(nil)

        if !email.isEmpty, !teams.isEmpty || !accessGroups.isEmpty {
            guard let original = policyFile, policyETag != nil else {
                errorMessage = "Still loading — try again in a moment."
                return
            }
            let result: AccessEditResult
            do {
                result = try PersonPolicyAdder.add(person, toTeams: teams, accessGroups: accessGroups,
                                                   in: original, devices: manageableDevices)
            } catch {
                show(error)
                return
            }
            if result.text != original {
                guard let step = policySaveStep(result.text, basedOn: original, notes: result.notes,
                                                extraPeople: [person],
                                                onSaved: { url in backupName.value = url.lastPathComponent })
                else { return }
                let what = teams.map(teamDisplayName) + accessGroups.map(AccessEditor.accessGroupName)
                ops.append(.init(title: "Set up \(email)’s access",
                                 detail: "\(what.joined(separator: ", ")). Ready the moment they sign in. A backup is saved first.",
                                 symbol: "lock.shield", isDestructive: false, run: { [run = step.operation.run] in _ = try await run() }))
                step.review.unchangedNote = "No machines change for anyone."
                review = step.review
            }
        }

        if sendInvite || email.isEmpty {
            ops.append(.init(title: email.isEmpty ? "Create an invite link" : "Email an invite to \(email)",
                             detail: email.isEmpty
                                 ? "Copy it from People → Pending invites."
                                 : "They get a link to join as \(UserRole.label(for: role)).",
                             symbol: "envelope", isDestructive: false) {
                try await api.createUserInvite(email: email, role: role)
            })
        }

        guard !ops.isEmpty else {
            errorMessage = "Pick a team or turn on the invite email — there’s nothing to do yet."
            return
        }

        var snapshot = ["Role: \(UserRole.label(for: role))"]
        if !email.isEmpty, !teams.isEmpty { snapshot.append("Teams: " + teams.map(teamDisplayName).joined(separator: ", ")) }
        if !email.isEmpty, !accessGroups.isEmpty {
            snapshot.append("Extra access: " + accessGroups.map(AccessEditor.accessGroupName).joined(separator: ", "))
        }
        let reach = pendingReach(email: email, role: role, teams: teams, accessGroups: accessGroups)
        if let reach { snapshot.append("Will reach \(reach) machine\(reach == 1 ? "" : "s")") }
        if !sendInvite && !email.isEmpty { snapshot.append("No invite sent (joins by signing in)") }

        let admin = currentAdmin?.loginName
        let name = email.isEmpty ? "Invite link" : email
        let plan = ChangePlan(
            title: email.isEmpty ? "Create an invite link" : "Add \(email)",
            summary: email.isEmpty
                ? "Anyone with the link can join as \(UserRole.label(for: role)). Saved to People history."
                : "Their access is ready before they sign in. Saved to People history.",
            operations: ops,
            policyReview: review)
        plan.applyLabel = email.isEmpty ? "Create link" : "Add them"
        plan.stopsOnFailure = true
        plan.onFinish = { [weak self] plan in
            self?.record(PeopleLogEntry(
                date: .now, kind: .added, name: name, login: email, role: role,
                reason: reason, performedBy: admin, snapshot: snapshot,
                steps: plan.logSteps, policyBackup: backupName.value))
        }
        propose(plan)
    }

    /// How many machines a not-yet-joined person would reach with these
    /// teams and access groups (same analyzer as every access view).
    func pendingReach(email: String, role: String, teams: [String], accessGroups: [String]) -> Int? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, let original = policyFile else { return nil }
        let person = TSUser.pending(email: email, role: role)
        guard let text = try? PersonPolicyAdder.add(person, toTeams: teams, accessGroups: accessGroups,
                                                    in: original, devices: manageableDevices).text else { return nil }
        let reach = PolicyAnalyzer.analyze(model: PolicyAnalyzer.parse(policyText: text), devices: devices,
                                           users: users + [person], settings: settings).reachability
        return reach.reachableByPerson[email]?.count ?? 0
    }

    // MARK: Log

    func record(_ entry: PeopleLogEntry) {
        do {
            try PeopleLogStore.append(entry)
        } catch {
            errorMessage = "Done, but it couldn’t be saved to People history: \(error.localizedDescription)"
        }
        peopleLog = PeopleLogStore.load()
    }
}

// MARK: - Helpers

/// A mutable slot an operation can fill in for the plan's log entry.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension ChangePlan {
    /// Every operation and how it went, for People history.
    var logSteps: [PeopleLogEntry.Step] {
        operations.map { op in
            switch op.state {
            case .done: return .init(title: op.title, error: nil)
            case .failed(let message): return .init(title: op.title, error: message)
            case .pending, .running: return .init(title: op.title, error: nil, skipped: true)
            }
        }
    }
}

extension TSUser {
    /// Someone who hasn't joined yet — used to preview and prepare access.
    static func pending(email: String, role: String) -> TSUser {
        TSUser(id: "pending:\(email)", loginName: email, role: role, status: "active", type: "member")
    }
}

extension AuthKey {
    var displayName: String {
        if let description, !description.isEmpty { return "“\(description)”" }
        return id
    }
}
