import Foundation

// MARK: - Removing a person from the policy

/// Removing someone: takes every mention of them out of the policy, so an
/// old address can never quietly regain access (for example if the mailbox
/// is reused or the account is re-created).
///
/// - Groups, tag owners, auto-approvers: the person is dropped from the list.
/// - Grants / ACLs / SSH rules / node attributes: the person is dropped from
///   the rule's `src`/`dst` (`target`); a rule that named only them is
///   deleted. Other fields (e.g. SSH `users`, which are machine logins) are
///   never touched.
/// - Tests: tests about the person are deleted — they assert access that is
///   being taken away on purpose. Every other test still runs on save.
///
/// Edits are position-preserving splices (see `PolicyTextEditor`), so
/// comments and formatting elsewhere stay exactly as they were.
enum PolicyPersonScrubber {
    struct Result {
        var text: String
        /// Places that still name the person and couldn't be removed safely.
        var leftovers: [String]
    }

    private enum Edit {
        /// `entry`: a whole rule or test (its comment goes with it), not
        /// just one name in a list.
        case deleteElement(array: HuJSONNode, index: Int, entry: Bool)
        case empty(array: HuJSONNode)
    }

    static func scrub(_ login: String, from text: String) throws -> Result {
        var editor = PolicyTextEditor(text)
        var done = false
        for _ in 0..<10_000 {
            guard let root = editor.root() else { throw AccessEditError.unreadablePolicy }
            guard let edit = nextEdit(in: root, login: login) else { done = true; break }
            switch edit {
            case .deleteElement(let array, let index, let entry):
                editor.deleteElement(at: index, in: array, removingCommentsAbove: entry)
            case .empty(let array):
                editor.replace(array, with: "[]")
            }
            guard editor.root() != nil else { throw AccessEditError.editFailed }
        }
        // Never hand back a half-finished edit.
        guard done, let root = editor.root() else { throw AccessEditError.editFailed }
        var leftovers: [String] = []
        collectMentions(root, path: [], login: login, into: &leftovers)
        return Result(text: editor.text, leftovers: leftovers)
    }

    /// Every place the policy names the person.
    static func mentions(of login: String, in text: String) -> [String] {
        guard let root = HuJSONDocument.parse(text) else { return [] }
        var out: [String] = []
        collectMentions(root, path: [], login: login, into: &out)
        return out
    }

    // MARK: Finding the next edit

    private static func nextEdit(in root: HuJSONNode, login: String) -> Edit? {
        for section in root.members {
            let list = section.value
            switch section.key {
            case "acls", "grants", "ssh", "nodeAttrs":
                let fields: Set<String> = section.key == "nodeAttrs" ? ["target"] : ["src", "dst"]
                for (i, rule) in list.elements.enumerated() {
                    for field in rule.members where fields.contains(field.key) {
                        guard let j = field.value.elements.firstIndex(where: { matches($0, login) }) else { continue }
                        // A rule needs a source and a destination: when only
                        // this person was there, the whole rule goes.
                        if field.value.elements.count == 1 {
                            return .deleteElement(array: list, index: i, entry: true)
                        }
                        return .deleteElement(array: field.value, index: j, entry: false)
                    }
                }
            case "tests", "sshTests":
                for (i, test) in list.elements.enumerated() {
                    if let src = test["src"], matches(src, login) {
                        return .deleteElement(array: list, index: i, entry: true)
                    }
                    // sshTests accept/check/deny list machine logins, not people.
                    let checkFields: Set<String> = section.key == "sshTests" ? ["dst"] : ["dst", "accept", "deny"]
                    for field in test.members where checkFields.contains(field.key) {
                        guard let j = field.value.elements.firstIndex(where: { matches($0, login) }) else { continue }
                        if field.value.elements.count > 1 {
                            return .deleteElement(array: field.value, index: j, entry: false)
                        }
                        // A test needs a destination and at least one check.
                        let otherChecks = test.members.filter {
                            $0.key != field.key && $0.key != "dst" && !$0.value.elements.isEmpty
                        }
                        if field.key == "dst" || otherChecks.isEmpty {
                            return .deleteElement(array: list, index: i, entry: true)
                        }
                        return .empty(array: field.value)
                    }
                }
            default:
                if let edit = listEdit(in: list, login: login) { return edit }
            }
        }
        return nil
    }

    /// Groups, tag owners, auto-approvers and any other lists: drop the
    /// person from the list (an emptied list stays as `[]`).
    private static func listEdit(in node: HuJSONNode, login: String) -> Edit? {
        switch node.value {
        case .array(let elements):
            if let j = elements.firstIndex(where: { matches($0, login) }) {
                return .deleteElement(array: node, index: j, entry: false)
            }
            for element in elements {
                if let edit = listEdit(in: element, login: login) { return edit }
            }
        case .object(let members):
            for member in members {
                if let edit = listEdit(in: member.value, login: login) { return edit }
            }
        case .string, .scalar:
            break
        }
        return nil
    }

    private static func collectMentions(_ node: HuJSONNode, path: [String], login: String, into out: inout [String]) {
        switch node.value {
        case .string:
            if matches(node, login) { out.append(path.joined(separator: " › ")) }
        case .array(let elements):
            for element in elements {
                collectMentions(element, path: path, login: login, into: &out)
            }
        case .object(let members):
            for member in members {
                // SSH `users` and SSH test checks are machine logins, not people.
                guard !(path.first == "ssh" && member.key == "users"),
                      !(path.first == "sshTests" && ["accept", "check", "deny"].contains(member.key)) else { continue }
                collectMentions(member.value, path: path + [member.key], login: login, into: &out)
            }
        case .scalar:
            break
        }
    }

    /// The person's address, or it with a port list (`alice@x.com:22`).
    private static func matches(_ node: HuJSONNode, _ login: String) -> Bool {
        guard let s = node.stringValue?.lowercased() else { return false }
        let l = login.lowercased()
        return s == l || s.hasPrefix(l + ":")
    }
}

// MARK: - Copying a person to a new email

/// Changing someone's email: Tailscale can't rename an account, so the new
/// address gets exactly the same access — added next to the old one
/// everywhere the policy names it (teams, rules, tag owners, …). The old
/// address stays until the old account is removed. Policy tests aren't
/// copied: Tailscale evaluates them before the new address has joined, so
/// tests that rely on "all members" would fail.
enum PolicyPersonCopier {
    static func copy(_ old: String, to new: String, in text: String) throws -> AccessEditResult {
        var editor = PolicyTextEditor(text)
        for _ in 0..<10_000 {
            guard let root = editor.root() else { throw AccessEditError.unreadablePolicy }
            guard let (array, index, value) = nextMissing(in: root, old: old, new: new) else {
                return AccessEditResult(text: editor.text, notes: [])
            }
            editor.addString(value, to: array, after: index)
            guard editor.root() != nil else { throw AccessEditError.editFailed }
        }
        // Never hand back a partial copy.
        throw AccessEditError.editFailed
    }

    /// The first list that names the old address (outside tests and SSH
    /// `users`, which are machine logins) but not yet the new one: the list,
    /// where the old entry is, and what to add.
    private static func nextMissing(in node: HuJSONNode, old: String, new: String,
                                    section: String? = nil) -> (HuJSONNode, Int, String)? {
        switch node.value {
        case .object(let members):
            for member in members {
                if section == nil, ["tests", "sshTests"].contains(member.key) { continue }
                if section == "ssh", member.key == "users" { continue }
                if let hit = nextMissing(in: member.value, old: old, new: new, section: section ?? member.key) {
                    return hit
                }
            }
        case .array(let elements):
            let existing = Set(elements.compactMap { $0.stringValue?.lowercased() })
            for (i, element) in elements.enumerated() {
                if let s = element.stringValue, let counterpart = counterpart(of: s, old: old, new: new),
                   !existing.contains(counterpart.lowercased()) {
                    return (node, i, counterpart)
                }
                if let hit = nextMissing(in: element, old: old, new: new, section: section) { return hit }
            }
        case .string, .scalar:
            break
        }
        return nil
    }

    /// "old@x.com" → "new@x.com", "old@x.com:22" → "new@x.com:22".
    private static func counterpart(of s: String, old: String, new: String) -> String? {
        let lower = s.lowercased(), o = old.lowercased()
        if lower == o { return new }
        if lower.hasPrefix(o + ":") { return new + s.dropFirst(old.count) }
        return nil
    }

}

// MARK: - Teams

/// "group:prod-devs" → "Prod-devs team".
func teamDisplayName(_ group: String) -> String {
    let name = group.replacingOccurrences(of: "group:", with: "")
    return name.prefix(1).uppercased() + name.dropFirst() + " team"
}

// MARK: - Leaving teams

enum PolicyTeamEditor {
    /// Takes one person out of the given teams (policy groups). A team left
    /// empty stays as `[]`.
    static func remove(_ login: String, fromTeams teams: [String], in text: String) throws -> String {
        var editor = PolicyTextEditor(text)
        for team in teams {
            for _ in 0..<50 {
                guard let root = editor.root() else { throw AccessEditError.unreadablePolicy }
                guard let list = root["groups"]?[team],
                      let index = list.elements.firstIndex(where: {
                          $0.stringValue?.caseInsensitiveCompare(login) == .orderedSame
                      }) else { break }
                editor.deleteElement(at: index, in: list, removingCommentsAbove: false)
                guard editor.root() != nil else { throw AccessEditError.editFailed }
            }
        }
        return editor.text
    }
}

// MARK: - Adding a person to the policy

/// Onboarding: puts a new person into teams (policy groups) and gives them
/// access groups before they've even joined, so everything works the
/// moment they sign in. The policy may name people who haven't joined yet.
enum PersonPolicyAdder {
    static func add(_ person: TSUser, toTeams teams: [String], accessGroups: [String],
                    in text: String, devices: [Device]) throws -> AccessEditResult {
        var editor = PolicyTextEditor(text)
        var notes: [String] = []
        for team in teams {
            guard let root = editor.root() else { throw AccessEditError.unreadablePolicy }
            guard let node = root["groups"]?[team] else {
                notes.append("The \(teamDisplayName(team)) no longer exists, so they weren’t added to it.")
                continue
            }
            guard !node.strings.contains(where: { $0.caseInsensitiveCompare(person.loginName) == .orderedSame }) else { continue }
            editor.addString(person.loginName, to: node)
            guard editor.root() != nil else { throw AccessEditError.editFailed }
        }
        var result = editor.text
        for tag in accessGroups {
            // No-op when a team they just joined already gives this group.
            result = try AccessEditor.grant(person, .group(tag), in: result, devices: devices)
        }
        return AccessEditResult(text: result, notes: notes)
    }
}

// MARK: - People history

/// One person added, changed, paused or removed, with what was done and how
/// each step went. Kept on this device; Tailscale's own audit log
/// (Admin → Logs) records the same API calls server-side.
struct PeopleLogEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case added, removed, suspended, resumed, approved
        case changed = "edited"

        /// An entry type from a newer build still reads (as a change)
        /// instead of making the whole history unreadable.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .changed
        }
    }

    struct Step: Codable, Hashable {
        let title: String
        /// nil = done (or skipped); otherwise why it failed.
        let error: String?
        /// Not run because an earlier step failed.
        var skipped: Bool? = nil
        var succeeded: Bool { error == nil && skipped != true }
        var failed: Bool { error != nil }
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let name: String
    let login: String
    let role: String?
    let reason: String
    /// The admin whose API token made the changes, when it can be told.
    let performedBy: String?
    /// What they had (removal) or were given (addition), for the record.
    let snapshot: [String]
    let steps: [Step]
    /// File name of the policy backup taken before a policy change.
    let policyBackup: String?

    var succeeded: Bool { steps.allSatisfy(\.succeeded) }
    var failedCount: Int { steps.filter(\.failed).count }
}

enum PeopleLogStore {
    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TailnetManager/people-log.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Newest first. Empty when there's no history yet or it can't be read.
    static func load() -> [PeopleLogEntry] {
        ((try? stored()) ?? []).sorted { $0.date > $1.date }
    }

    /// Entries are only ever added, never edited or pruned. A history file
    /// that can't be read is moved aside (kept), never overwritten.
    static func append(_ entry: PeopleLogEntry) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [PeopleLogEntry]
        do {
            existing = try stored()
        } catch {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try FileManager.default.moveItem(at: url, to: aside)
            existing = []
        }
        let entries = (existing + [entry]).sorted { $0.date < $1.date }
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// What's on disk; [] when there's no file yet, throws when it's unreadable.
    private static func stored() throws -> [PeopleLogEntry] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([PeopleLogEntry].self, from: Data(contentsOf: url))
    }

    /// The whole log as CSV (one row per person event) for records/HR.
    static func csv(_ entries: [PeopleLogEntry]) -> String {
        let iso = ISO8601DateFormatter()
        func field(_ s: String) -> String {
            // A cell starting with = + - @ (or a tab/return) runs as a formula
            // in Excel/Sheets; a leading apostrophe keeps it plain text.
            let safe = s.first.map { "=+-@\t\r".contains($0) } == true ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["date,action,name,login,role,reason,performed_by,result,snapshot,steps,policy_backup"]
        for e in entries.sorted(by: { $0.date < $1.date }) {
            let steps = e.steps.map { step in
                step.title + (step.skipped == true ? " [skipped]" : step.error.map { " [FAILED: \($0)]" } ?? " [done]")
            }
            lines.append([
                iso.string(from: e.date), e.kind.rawValue, e.name, e.login, e.role ?? "", e.reason,
                e.performedBy ?? "", e.failedCount > 0 ? "\(e.failedCount) step(s) failed" : e.succeeded ? "complete" : "incomplete",
                e.snapshot.joined(separator: "; "), steps.joined(separator: "; "), e.policyBackup ?? "",
            ].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
