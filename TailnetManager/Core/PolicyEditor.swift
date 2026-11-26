import Foundation

// MARK: - HuJSON document (position-preserving)

/// A HuJSON value that remembers where it sits in the text (UTF-8 byte
/// offsets), so an edit can splice only the bytes that change and keep
/// every comment, blank line and ordering elsewhere in the policy.
struct HuJSONNode {
    struct Member {
        let key: String
        let value: HuJSONNode
    }

    enum Value {
        case object([Member])
        case array([HuJSONNode])
        case string(String)
        case scalar
    }

    let value: Value
    let start: Int
    let end: Int

    subscript(key: String) -> HuJSONNode? {
        members.last { $0.key == key }?.value
    }

    var members: [Member] {
        if case .object(let members) = value { return members }
        return []
    }

    var elements: [HuJSONNode] {
        if case .array(let elements) = value { return elements }
        return []
    }

    var stringValue: String? {
        if case .string(let s) = value { return s }
        return nil
    }

    /// The string elements of an array node.
    var strings: [String] { elements.compactMap(\.stringValue) }
}

enum HuJSONDocument {
    static func parse(_ text: String) -> HuJSONNode? {
        parse(bytes: Array(text.utf8))
    }

    static func parse(bytes: [UInt8]) -> HuJSONNode? {
        var parser = HuJSONParser(b: bytes)
        parser.skipTrivia()
        guard let root = parser.parseValue() else { return nil }
        parser.skipTrivia()
        return parser.i == bytes.count ? root : nil
    }
}

private struct HuJSONParser {
    let b: [UInt8]
    var i = 0

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    mutating func skipTrivia() {
        while i < b.count {
            switch b[i] {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "/"):
                while i < b.count, b[i] != 0x0A { i += 1 }
            case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "*"):
                i += 2
                while i + 1 < b.count, !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i = min(i + 2, b.count)
            default:
                return
            }
        }
    }

    mutating func parseValue() -> HuJSONNode? {
        guard i < b.count else { return nil }
        let start = i
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [HuJSONNode.Member] = []
            while true {
                skipTrivia()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: "}") { i += 1; break }
                guard b[i] == Self.quote, let key = parseString() else { return nil }
                skipTrivia()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                skipTrivia()
                guard let value = parseValue() else { return nil }
                members.append(.init(key: key, value: value))
                skipTrivia()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1 } else if b[i] != UInt8(ascii: "}") { return nil }
            }
            return HuJSONNode(value: .object(members), start: start, end: i)
        case UInt8(ascii: "["):
            i += 1
            var elements: [HuJSONNode] = []
            while true {
                skipTrivia()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                guard let value = parseValue() else { return nil }
                elements.append(value)
                skipTrivia()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1 } else if b[i] != UInt8(ascii: "]") { return nil }
            }
            return HuJSONNode(value: .array(elements), start: start, end: i)
        case Self.quote:
            guard let s = parseString() else { return nil }
            return HuJSONNode(value: .string(s), start: start, end: i)
        default:
            while i < b.count, !Self.isDelimiter(b[i]) { i += 1 }
            guard i > start else { return nil }
            return HuJSONNode(value: .scalar, start: start, end: i)
        }
    }

    /// Parses a string starting at its opening quote.
    mutating func parseString() -> String? {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == Self.quote {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c == Self.backslash, i + 1 < b.count {
                let e = b[i + 1]
                i += 2
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard i + 4 <= b.count,
                          let code = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else { return nil }
                    i += 4
                    out.append(contentsOf: Array(String(Unicode.Scalar(code).map(Character.init) ?? "?").utf8))
                default: out.append(e)
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return nil
    }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"),
             UInt8(ascii: ":"), UInt8(ascii: "/"):
            return true
        default:
            return false
        }
    }
}

// MARK: - Text splicing

/// Minimal-diff edits on HuJSON text: every operation replaces only the
/// bytes of the value it changes and formats new text in the file's own
/// indentation style.
struct PolicyTextEditor {
    private(set) var bytes: [UInt8]
    let indentUnit: String

    init(_ text: String, indentUnit: String? = nil) {
        bytes = Array(text.utf8)
        self.indentUnit = indentUnit ?? Self.detectIndentUnit(text)
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    func root() -> HuJSONNode? { HuJSONDocument.parse(bytes: bytes) }

    func slice(_ node: HuJSONNode) -> String {
        String(decoding: bytes[node.start..<node.end], as: UTF8.self)
    }

    mutating func replace(_ range: Range<Int>, with text: String) {
        bytes.replaceSubrange(range, with: Array(text.utf8))
    }

    mutating func replace(_ node: HuJSONNode, with text: String) {
        replace(node.start..<node.end, with: text)
    }

    /// Replaces a string array, keeping it on one line if it was on one
    /// line (and still fits), otherwise one entry per line.
    mutating func replaceStrings(_ node: HuJSONNode, with items: [String]) {
        let wasMultiline = bytes[node.start..<node.end].contains(0x0A)
        replace(node, with: formatStrings(items, at: node.start, multiline: wasMultiline && items.count > 1))
    }

    /// Adds one string to an array. A short one-line list of plain strings
    /// is rewritten with the value after `index`; anything else (several
    /// lines, comments, objects) gets it appended on its own line, so nothing
    /// already there is touched.
    mutating func addString(_ value: String, to array: HuJSONNode, after index: Int? = nil) {
        let slice = self.slice(array)
        let plain = array.elements.allSatisfy { $0.stringValue != nil }
            && !slice.contains("\n") && !slice.contains("//") && !slice.contains("/*")
        if plain {
            var items = array.strings
            items.insert(value, at: index.map { $0 + 1 } ?? items.count)
            replaceStrings(array, with: items)
        } else {
            appendElement(to: array) { _ in Self.quoted(value) }
        }
    }

    func formatStrings(_ items: [String], at offset: Int, multiline: Bool = false) -> String {
        let single = "[" + items.map(Self.quoted).joined(separator: ", ") + "]"
        guard multiline || single.count > 100 else { return single }
        let base = lineIndent(at: offset)
        let inner = base + indentUnit
        return "[\n" + items.map { inner + Self.quoted($0) + "," }.joined(separator: "\n") + "\n" + base + "]"
    }

    /// Removes one element of an array, with its trailing comma. When the
    /// element sits on its own lines, the whole lines go — for a whole rule
    /// also the comment lines directly above it (they describe that rule).
    /// For one name in a list those comments usually head a group of names,
    /// so `removingCommentsAbove: false` keeps them.
    mutating func deleteElement(at index: Int, in array: HuJSONNode, removingCommentsAbove: Bool = true) {
        let element = array.elements[index]
        var lo = element.start
        var j = element.end
        skipInlineTrivia(&j)
        var hadComma = false
        if j < bytes.count, bytes[j] == UInt8(ascii: ",") { hadComma = true; j += 1 }
        skipInlineTrivia(&j)
        if j + 1 < bytes.count, bytes[j] == UInt8(ascii: "/"), bytes[j + 1] == UInt8(ascii: "/") {
            while j < bytes.count, bytes[j] != 0x0A { j += 1 }
        }
        let lineStart = startOfLine(lo)
        let ownLine = bytes[lineStart..<lo].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        if ownLine, j < bytes.count, bytes[j] == 0x0A {
            lo = lineStart
            while removingCommentsAbove, lo > 0 {
                let previousStart = startOfLine(lo - 1)
                let line = String(decoding: bytes[previousStart..<(lo - 1)], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("//") else { break }
                lo = previousStart
            }
            replace(lo..<(j + 1), with: "")
        } else {
            if !hadComma {
                var k = lo - 1
                while k >= 0, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[k]) { k -= 1 }
                if k >= 0, bytes[k] == UInt8(ascii: ",") { lo = k }
            }
            replace(lo..<j, with: "")
        }
    }

    /// Appends an element (formatted by `make` for the given indent) after
    /// the array's last element, on its own line, with a trailing comma.
    mutating func appendElement(to array: HuJSONNode, _ make: (_ indent: String) -> String) {
        guard let last = array.elements.last else {
            let base = lineIndent(at: array.start)
            let indent = base + indentUnit
            replace((array.start + 1)..<(array.start + 1), with: "\n" + indent + make(indent) + ",\n" + base)
            return
        }
        appendAfter(end: last.end, indentSource: last.start, parentStart: array.start, make)
    }

    /// Adds `"key": value` as the last member of an object.
    mutating func appendMember(to object: HuJSONNode, key: String, _ makeValue: @escaping (_ indent: String) -> String) {
        let make: (String) -> String = { indent in Self.quoted(key) + ": " + makeValue(indent) }
        guard let last = object.members.last else {
            let base = lineIndent(at: object.start)
            let indent = base + indentUnit
            replace((object.start + 1)..<(object.start + 1), with: "\n" + indent + make(indent) + ",\n" + base)
            return
        }
        appendAfter(end: last.value.end, indentSource: last.value.start, parentStart: object.start, make)
    }

    private mutating func appendAfter(end: Int, indentSource: Int, parentStart: Int,
                                      _ make: (_ indent: String) -> String) {
        var j = end
        skipInlineTrivia(&j)
        let hasComma = j < bytes.count && bytes[j] == UInt8(ascii: ",")
        if hasComma { j += 1 }
        skipInlineTrivia(&j)
        if j + 1 < bytes.count, bytes[j] == UInt8(ascii: "/"), bytes[j + 1] == UInt8(ascii: "/") {
            while j < bytes.count, bytes[j] != 0x0A { j += 1 }
        }
        let indent = isFirstOnLine(indentSource)
            ? lineIndent(at: indentSource)
            : lineIndent(at: parentStart) + indentUnit
        replace(j..<j, with: "\n" + indent + make(indent) + ",")
        if !hasComma { replace(end..<end, with: ",") }
    }

    /// Leading whitespace of the line containing `offset`.
    func lineIndent(at offset: Int) -> String {
        var k = startOfLine(offset)
        var out: [UInt8] = []
        while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x09 {
            out.append(bytes[k])
            k += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func isFirstOnLine(_ offset: Int) -> Bool {
        bytes[startOfLine(offset)..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private func startOfLine(_ offset: Int) -> Int {
        var k = min(offset, bytes.count)
        while k > 0, bytes[k - 1] != 0x0A { k -= 1 }
        return k
    }

    private func skipSpaces(_ j: inout Int) {
        while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
    }

    /// Spaces, tabs and `/* … */` comments on the same line — what can sit
    /// between an element and its comma.
    private func skipInlineTrivia(_ j: inout Int) {
        while true {
            skipSpaces(&j)
            guard j + 1 < bytes.count, bytes[j] == UInt8(ascii: "/"), bytes[j + 1] == UInt8(ascii: "*") else { return }
            var k = j + 2
            while k + 1 < bytes.count, !(bytes[k] == UInt8(ascii: "*") && bytes[k + 1] == UInt8(ascii: "/")) {
                if bytes[k] == 0x0A { return }   // spans lines: leave it alone
                k += 1
            }
            guard k + 1 < bytes.count else { return }
            j = k + 2
        }
    }

    /// A JSON string literal: quotes, backslashes and control characters
    /// escaped, so the result is always valid JSON.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func detectIndentUnit(_ text: String) -> String {
        for line in text.split(separator: "\n") {
            if line.hasPrefix("\t") { return "\t" }
            let spaces = line.prefix { $0 == " " }.count
            if spaces >= 2, line.dropFirst(spaces).first.map({ $0 == "\"" || $0 == "{" }) == true {
                return String(repeating: " ", count: spaces)
            }
        }
        return "\t"
    }
}

// MARK: - People → machine access (the switch model)

/// What a person's access switch controls: a whole access group (tag) or
/// one machine.
enum AccessTarget: Hashable {
    case group(String)
    case machine(String)

    var key: String {
        switch self {
        case .group(let tag): return "group:\(tag)"
        case .machine(let id): return "machine:\(id)"
        }
    }
}

/// One pending switch flip: give (`grant`) or take away a person's access.
struct AccessToggle: Identifiable, Hashable {
    let login: String
    let target: AccessTarget
    let grant: Bool
    var id: String { "\(login)|\(target.key)" }
}

/// One row on a person's access list.
struct AccessRow: Identifiable, Hashable {
    enum State: Hashable {
        case on
        case off
        /// Reached anyway through another group or rule; the switch can't
        /// turn it off on its own.
        case inherited(String)
    }

    let target: AccessTarget
    let title: String
    /// "21 machines" for a group, empty for a single machine.
    let count: String
    /// "ports 80, 443", "comes with Restricted", …
    let note: String
    let state: State
    var id: String { target.key }

    var detail: String { [count, note].filter { !$0.isEmpty }.joined(separator: " · ") }

    var isOn: Bool {
        switch state {
        case .on, .inherited: return true
        case .off: return false
        }
    }
    var isInherited: Bool {
        if case .inherited = state { return true }
        return false
    }
}

enum AccessEditError: LocalizedError {
    case unreadablePolicy
    case machineHasNoAddress(String)
    case editFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePolicy:
            return "The policy file couldn’t be read, so access can’t be changed. Refresh and try again."
        case .machineHasNoAddress(let name):
            return "\(name) has no Tailscale address yet, so access to it can’t be granted."
        case .editFailed:
            return "The change couldn’t be applied cleanly to your policy file. Nothing was saved."
        }
    }
}

struct AccessEditResult {
    var text: String
    /// Plain-language side effects the review sheet must call out.
    var notes: [String]
}

/// Turns access switches into the smallest policy edit that does exactly
/// that, and reads the current state of every switch. Only network rules
/// (`grants`, `acls`) are touched; SSH rules, groups, tags and tests are
/// left alone.
enum AccessEditor {

    /// A network rule as written in the file.
    struct Rule {
        let section: String
        let index: Int
        let srcs: [String]
        /// Raw destinations; ACL entries still carry their ":ports".
        let dsts: [String]
        /// Port entries as written ("*", "22", "tcp:443").
        let ports: [String]
        /// Keys other than src/dst/ip/action (app, srcPosture, via, …).
        let extraKeys: Set<String>

        func selector(_ raw: String) -> String {
            section == "acls" ? PolicyAnalyzer.splitDst(raw).0 : raw
        }
    }

    static func rules(in root: HuJSONNode) -> [Rule] {
        var out: [Rule] = []
        for section in ["acls", "grants"] {
            guard let array = root[section] else { continue }
            for (index, node) in array.elements.enumerated() {
                if section == "acls", let action = node["action"]?.stringValue, action != "accept" { continue }
                let dsts = node["dst"]?.strings ?? []
                let ports: [String] = section == "acls"
                    ? dsts.flatMap { PolicyAnalyzer.splitDst($0).1 }
                    : (node["ip"]?.strings ?? ["*"])
                let extras = Set(node.members.map(\.key)).subtracting(["src", "dst", "ip", "action", "proto"])
                out.append(Rule(section: section, index: index,
                                srcs: node["src"]?.strings ?? [], dsts: dsts,
                                ports: ports, extraKeys: extras))
            }
        }
        return out
    }

    static func rules(inText text: String) -> [Rule] {
        HuJSONDocument.parse(text).map(rules(in:)) ?? []
    }

    // MARK: Targeting

    /// Does a destination selector point at this target? For a machine only
    /// selectors that name exactly that machine (its address or a host
    /// alias for it) count — wider selectors aren't per-machine switches.
    static func selector(_ sel: String, targets target: AccessTarget,
                         model: PolicyModel, devices: [Device]) -> Bool {
        switch target {
        case .group(let tag):
            return sel == tag
        case .machine(let id):
            guard let device = devices.first(where: { $0.id == id }),
                  let address = singleAddress(sel, model: model) else { return false }
            return (device.addresses ?? []).contains(address)
        }
    }

    /// "100.1.2.3", "100.1.2.3/32", "fd7a::1/128" or a host alias → the one
    /// address it names; nil for anything wider.
    private static func singleAddress(_ sel: String, model: PolicyModel) -> String? {
        let raw = model.hosts[sel] ?? sel
        guard raw.contains(".") || raw.contains(":"), !raw.contains("@") else { return nil }
        let parts = raw.split(separator: "/")
        if parts.count == 2, parts[1] != "32", parts[1] != "128" { return nil }
        return parts.first.map(String.init)
    }

    // MARK: Reading the switches

    /// Every switch on a person's access list: one per access group that has
    /// machines, plus one per machine they're given individually.
    static func rows(for person: TSUser, rules: [Rule], model: PolicyModel,
                     reach: AccessReachability, devices: [Device], groups: [String]) -> [AccessRow] {
        var rows: [AccessRow] = []
        for tag in groups {
            let members = devices.filter { ($0.tags ?? []).contains(tag) }
            guard !members.isEmpty else { continue }
            rows.append(row(for: person, target: .group(tag), rules: rules, model: model,
                            reach: reach, devices: devices, groups: groups))
        }
        var seen = Set<String>()
        for rule in rules where rule.srcs.contains(where: { PolicyAnalyzer.source($0, matches: person, model: model) }) {
            for dst in rule.dsts {
                let sel = rule.selector(dst)
                for device in devices where !seen.contains(device.id)
                    && selector(sel, targets: .machine(device.id), model: model, devices: devices) {
                    seen.insert(device.id)
                    rows.append(row(for: person, target: .machine(device.id), rules: rules, model: model,
                                    reach: reach, devices: devices, groups: groups))
                }
            }
        }
        return rows
    }

    static func row(for person: TSUser, target: AccessTarget, rules: [Rule], model: PolicyModel,
                    reach: AccessReachability, devices: [Device], groups: [String]) -> AccessRow {
        let direct = directRules(for: person, target: target, rules: rules, model: model, devices: devices)
        let covered: [Device]
        let title: String
        switch target {
        case .group(let tag):
            covered = devices.filter { ($0.tags ?? []).contains(tag) }
            title = accessGroupName(tag)
        case .machine(let id):
            covered = devices.filter { $0.id == id }
            title = covered.first?.shortName ?? id
        }
        let count: String = {
            guard case .group = target else { return "" }
            return "\(covered.count) machine\(covered.count == 1 ? "" : "s")"
        }()

        if !direct.isEmpty {
            let ports = portsLabel(direct.flatMap { portsTouching(target, in: $0, model: model, devices: devices) })
            return AccessRow(target: target, title: title, count: count, note: ports, state: .on)
        }
        let reached = covered.filter { reach.reaches(person.loginName, $0.id) }
        if !covered.isEmpty, reached.count == covered.count {
            let via = viaLabel(for: person, devices: reached, excluding: target, rules: rules,
                               model: model, allDevices: devices, groups: groups)
            return AccessRow(target: target, title: title, count: count, note: via, state: .inherited(via))
        }
        let note = reached.isEmpty ? "" : "reaches \(reached.count) through other rules"
        return AccessRow(target: target, title: title, count: count, note: note, state: .off)
    }

    /// Rules that match the person AND name the target directly.
    static func directRules(for person: TSUser, target: AccessTarget, rules: [Rule],
                            model: PolicyModel, devices: [Device]) -> [Rule] {
        rules.filter { rule in
            rule.srcs.contains { PolicyAnalyzer.source($0, matches: person, model: model) }
                && rule.dsts.contains { selector(rule.selector($0), targets: target, model: model, devices: devices) }
        }
    }

    private static func portsTouching(_ target: AccessTarget, in rule: Rule,
                                      model: PolicyModel, devices: [Device]) -> [String] {
        guard rule.section == "acls" else { return rule.ports }
        return rule.dsts
            .filter { selector(rule.selector($0), targets: target, model: model, devices: devices) }
            .flatMap { PolicyAnalyzer.splitDst($0).1 }
    }

    private static func portsLabel(_ entries: [String]) -> String {
        let cleaned = entries.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
        if cleaned.contains("*") { return "all ports" }
        var seen = Set<String>()
        let unique = cleaned.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "" : "port\(unique.count == 1 ? "" : "s") \(unique.joined(separator: ", "))"
    }

    private static func viaLabel(for person: TSUser, devices reached: [Device], excluding target: AccessTarget,
                                 rules: [Rule], model: PolicyModel, allDevices: [Device], groups: [String]) -> String {
        let otherTags = Set(reached.flatMap { $0.tags ?? [] })
            .subtracting(target.groupTag.map { [$0] } ?? [])
            .filter { !directRules(for: person, target: .group($0), rules: rules, model: model, devices: allDevices).isEmpty }
            .sorted()
        if !otherTags.isEmpty {
            return "comes with " + otherTags.map(accessGroupName).joined(separator: ", ")
        }
        let machines = reached
            .filter { !directRules(for: person, target: .machine($0.id), rules: rules, model: model, devices: allDevices).isEmpty }
            .map(\.shortName)
            .sorted()
        if machines.count == reached.count {
            return "comes with " + machines.joined(separator: ", ")
        }
        return "comes with another rule"
    }

    static func accessGroupName(_ tag: String) -> String {
        tag.replacingOccurrences(of: "tag:", with: "").capitalized
    }

    // MARK: Writing the switches

    /// Applies the switches in order and returns the edited policy text.
    static func apply(_ toggles: [AccessToggle], to text: String,
                      users: [TSUser], devices: [Device]) throws -> AccessEditResult {
        var result = AccessEditResult(text: text, notes: [])
        let members = users.filter { !$0.isExternal }
        for toggle in toggles {
            guard let person = users.first(where: { $0.loginName == toggle.login }) else { continue }
            if toggle.grant {
                result.text = try grant(person, toggle.target, in: result.text, devices: devices)
            } else {
                let (text, notes) = try revoke(person, toggle.target, in: result.text,
                                               members: members, devices: devices)
                result.text = text
                for note in notes where !result.notes.contains(note) { result.notes.append(note) }
            }
        }
        return result
    }

    /// Takes the target away from one person and nobody else. Each rule that
    /// gives it to them either drops them from its sources, or — when the
    /// rule also covers other destinations — keeps those and hands the
    /// target to everyone else through a copy of the rule.
    static func revoke(_ person: TSUser, _ target: AccessTarget, in text: String,
                       members: [TSUser], devices: [Device]) throws -> (String, [String]) {
        var editor = PolicyTextEditor(text)
        var notes: [String] = []
        for _ in 0..<500 {
            guard let root = editor.root(),
                  let model = PolicyAnalyzer.parse(policyText: editor.text) else { throw AccessEditError.unreadablePolicy }
            guard let rule = directRules(for: person, target: target, rules: rules(in: root),
                                         model: model, devices: devices).first,
                  let section = root[rule.section] else { break }
            let node = section.elements[rule.index]
            guard let srcNode = node["src"], let dstNode = node["dst"] else { throw AccessEditError.editFailed }

            let (keptSrc, note) = subtract(person, from: rule.srcs, model: model, members: members)
            if let note, !notes.contains(note) { notes.append(note) }
            let hit = rule.dsts.filter { selector(rule.selector($0), targets: target, model: model, devices: devices) }
            let others = rule.dsts.filter { !hit.contains($0) }

            if others.isEmpty {
                if keptSrc.isEmpty {
                    editor.deleteElement(at: rule.index, in: section)
                } else {
                    editor.replaceStrings(srcNode, with: keptSrc)
                }
            } else {
                // Append first (it lands after this rule), then edit this
                // rule's destinations, so offsets stay valid.
                if !keptSrc.isEmpty {
                    let copy = try copyRule(node, in: editor, src: keptSrc, dst: hit)
                    editor.appendElement(to: section) { _ in copy }
                }
                editor.replaceStrings(dstNode, with: others)
            }
            guard editor.root() != nil else { throw AccessEditError.editFailed }
        }
        return (editor.text, notes)
    }

    /// Gives the target to one person with all ports (no-op when their
    /// switch is already on). Joins an existing
    /// person-only, all-ports grant for exactly that target when there is
    /// one; otherwise adds a new grant.
    static func grant(_ person: TSUser, _ target: AccessTarget, in text: String,
                      devices: [Device]) throws -> String {
        var editor = PolicyTextEditor(text)
        guard let root = editor.root(), let model = PolicyAnalyzer.parse(policyText: text) else {
            throw AccessEditError.unreadablePolicy
        }
        let all = rules(in: root)
        // Already switched on (any ports) — nothing to do.
        if !directRules(for: person, target: target, rules: all, model: model, devices: devices).isEmpty {
            return text
        }

        let dsts: [String]
        switch target {
        case .group(let tag):
            dsts = [tag]
        case .machine(let id):
            guard let device = devices.first(where: { $0.id == id }) else { throw AccessEditError.editFailed }
            let addresses = device.addresses ?? []
            guard !addresses.isEmpty else { throw AccessEditError.machineHasNoAddress(device.shortName) }
            dsts = addresses
        }

        if let existing = all.first(where: { rule in
            rule.section == "grants" && Set(rule.dsts) == Set(dsts) && rule.ports == ["*"]
                && rule.extraKeys.isEmpty && !rule.srcs.isEmpty && rule.srcs.allSatisfy { $0.contains("@") }
        }), let srcNode = root["grants"]?.elements[existing.index]["src"] {
            if !existing.srcs.contains(person.loginName) {
                editor.replaceStrings(srcNode, with: existing.srcs + [person.loginName])
            }
        } else {
            let unit = editor.indentUnit
            let srcText = editor.formatStrings([person.loginName], at: 0)
            let dstText = editor.formatStrings(dsts, at: 0)
            let make: (String) -> String = { indent in
                let inner = indent + unit
                return "{\n"
                    + inner + "\"src\": " + srcText + ",\n"
                    + inner + "\"dst\": " + dstText + ",\n"
                    + inner + "\"ip\": [\"*\"],\n"
                    + indent + "}"
            }
            if let grants = root["grants"] {
                editor.appendElement(to: grants, make)
            } else {
                editor.appendMember(to: root, key: "grants") { indent in "[\n" + indent + unit + make(indent + unit) + ",\n" + indent + "]" }
            }
        }
        guard editor.root() != nil else { throw AccessEditError.editFailed }
        return editor.text
    }

    /// The sources of a rule minus one person. Direct mentions are dropped;
    /// a group or a broad source (everyone, admins, …) is spelled out as the
    /// people it covers today, minus them.
    static func subtract(_ person: TSUser, from srcs: [String], model: PolicyModel,
                         members: [TSUser]) -> ([String], String?) {
        var out: [String] = []
        var note: String?
        for src in srcs {
            guard PolicyAnalyzer.source(src, matches: person, model: model) else {
                out.append(src)
                continue
            }
            if src == person.loginName { continue }
            if src.hasPrefix("group:") {
                out += (model.groups[src] ?? []).filter { $0 != person.loginName }
                note = "\(src) is listed person by person in the changed rule, so later edits to \(src) won’t apply there."
                continue
            }
            out += members
                .filter { $0.loginName != person.loginName && PolicyAnalyzer.source(src, matches: $0, model: model) }
                .map(\.loginName)
            if src == "*" {
                out += ["autogroup:tagged", "autogroup:shared"]
            }
            note = "This access was open to \(broadLabel(src)). It’s now a list of named people, so people who join later won’t get it automatically."
        }
        var seen = Set<String>()
        return (out.filter { seen.insert($0).inserted }, note)
    }

    private static func broadLabel(_ src: String) -> String {
        switch src {
        case "*": return "everyone and every machine"
        case "autogroup:member", "autogroup:members": return "everyone in your org"
        case "autogroup:admin": return "all admins"
        case "autogroup:owner": return "the owner"
        default: return src
        }
    }

    /// The rule's text with new sources/destinations, everything else kept.
    private static func copyRule(_ node: HuJSONNode, in editor: PolicyTextEditor,
                                 src: [String], dst: [String]) throws -> String {
        var copy = PolicyTextEditor(editor.slice(node), indentUnit: editor.indentUnit)
        guard let root = copy.root(), let srcNode = root["src"], let dstNode = root["dst"] else {
            throw AccessEditError.editFailed
        }
        // Later offset first so the earlier one stays valid.
        for (field, items) in [(srcNode, src), (dstNode, dst)].sorted(by: { $0.0.start > $1.0.start }) {
            copy.replaceStrings(field, with: items)
        }
        return copy.text
    }
}

extension AccessTarget {
    var groupTag: String? {
        if case .group(let tag) = self { return tag }
        return nil
    }
}

// MARK: - Line diff

/// A readable line diff of two policy versions for the review sheet.
enum PolicyLineDiff {
    struct Line: Identifiable, Hashable {
        enum Kind: Hashable { case same, added, removed, gap }
        let id: Int
        let kind: Kind
        let text: String
    }

    /// Changed lines with `context` unchanged lines around each change.
    static func lines(old: String, new: String, context: Int = 2) -> [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [(Line.Kind, String)] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                ops.append((.same, a[i])); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                ops.append((.added, b[j])); j += 1
            } else {
                ops.append((.removed, a[i])); i += 1
            }
        }
        let changed = ops.indices.filter { ops[$0].0 != .same }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(ops.count - 1, index + context) { keep.insert(k) }
        }
        var out: [Line] = []
        var lastKept = -1
        for index in ops.indices where keep.contains(index) {
            if lastKept >= 0, index > lastKept + 1 {
                out.append(Line(id: out.count, kind: .gap, text: "⋯"))
            }
            out.append(Line(id: out.count, kind: ops[index].0, text: ops[index].1))
            lastKept = index
        }
        return out
    }
}

// MARK: - Backups

/// A copy of the policy is saved locally before every write, so any change
/// the app makes can be put back.
enum PolicyBackupStore {
    struct Backup: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    private static let keep = 50

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TailnetManager/PolicyBackups", isDirectory: true)
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    @discardableResult
    static func save(_ text: String) throws -> URL {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("policy-\(nameFormatter.string(from: .now)).hujson")
        try Data(text.utf8).write(to: url, options: .atomic)
        // Keep the newest ones, plus every backup People history points to.
        let referenced = Set(PeopleLogStore.load().compactMap(\.policyBackup))
        for old in list().dropFirst(keep) where !referenced.contains(old.url.lastPathComponent) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return url
    }

    static func list() -> [Backup] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.compactMap { url -> Backup? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("policy-"),
                  let date = nameFormatter.date(from: String(name.dropFirst("policy-".count))) else { return nil }
            return Backup(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    static func read(_ backup: Backup) -> String? {
        (try? Data(contentsOf: backup.url)).map { String(decoding: $0, as: UTF8.self) }
    }
}
