import Foundation

/// Removes websites from a Caddyfile as text: whole site blocks, or one
/// address of a block that serves several. Every other byte stays as it
/// was (comments, snippets, global options, layout). Anything it can't read
/// with certainty makes it refuse instead of guess.
///
/// Reads the file the way Caddy's own lexer does: whitespace separates
/// tokens, `#` starts a comment only at the start of a token, "…" and `…`
/// quote (newlines included), a backslash escapes the next character,
/// `<<MARKER` heredocs run to the marker line, and a block opens and closes
/// with tokens that are exactly `{` and `}`.
enum CaddyfileEditor {

    /// A website to remove: its host name and the ports it is served on
    /// (as the Services page shows them, e.g. ["443"] or ["8443"]).
    struct Target: Hashable {
        let host: String
        let ports: Set<String>

        init(host: String, ports: Set<String>) {
            self.host = host.lowercased()
            self.ports = ports
        }
    }

    struct Result {
        let newText: String
        /// Targets that matched an address in this file.
        let found: Set<Target>
        /// One line per change, e.g. "Removed the block for a.com".
        let changes: [String]
    }

    enum EditError: LocalizedError, Equatable {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "The Caddy file can't be edited safely: \(why)"
            }
        }
    }

    // MARK: - Removing

    static func remove(_ targets: Set<Target>, from text: String) throws -> Result {
        let bytes = Array(text.utf8)
        let tokens = try tokenize(bytes)
        let blocks = try siteBlocks(tokens)

        // Work out every cut first (byte ranges + replacement), then apply
        // them back to front so earlier offsets stay valid.
        var cuts: [(range: Range<Int>, with: String)] = []
        var found = Set<Target>()
        var changes: [String] = []

        for block in blocks where block.kind == .site {
            let addresses = block.addresses
            let matched = addresses.map { address in targets.first { matches(address, $0) } }
            let hits = matched.compactMap { $0 }
            guard !hits.isEmpty else { continue }
            found.formUnion(hits)
            let kept = zip(addresses, matched).filter { $0.1 == nil }.map(\.0)

            if kept.isEmpty {
                // Whole lines only: nothing else may share the first or last line.
                let first = block.header.first ?? block.open
                if first > 0, tokens[first - 1].line == tokens[first].line {
                    throw EditError.unreadable("line \(tokens[first].line) holds more than this site.")
                }
                if block.close + 1 < tokens.count, tokens[block.close + 1].line == tokens[block.close].line {
                    throw EditError.unreadable("line \(tokens[block.close].line) holds more than this site.")
                }
                cuts.append((wholeBlockRange(block, tokens: tokens, bytes: bytes), ""))
                changes.append("Removed the block for \(addresses.joined(separator: ", "))")
            } else {
                // Rewrite just the address list in front of the "{".
                let start = tokens[block.header.first!].start
                let end = tokens[block.open].start
                cuts.append((start..<end, kept.joined(separator: ", ") + " "))
                let removed = zip(addresses, matched).filter { $0.1 != nil }.map(\.0)
                changes.append("Took \(removed.joined(separator: ", ")) out of the block that also serves \(kept.joined(separator: ", "))")
            }
        }

        var out = bytes
        for cut in cuts.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(cut.range, with: Array(cut.with.utf8))
        }
        let newText = String(decoding: out, as: UTF8.self)
        if newText != text { try selfCheck(old: text, new: newText, removed: targets) }
        return Result(newText: newText, found: found, changes: changes)
    }

    /// The new file must still parse, and hold exactly the old sites minus
    /// the removed addresses, the same snippets and the same global options.
    private static func selfCheck(old: String, new: String, removed: Set<Target>) throws {
        func shape(_ text: String) throws -> (sites: [String], other: [String]) {
            let blocks = try siteBlocks(tokenize(Array(text.utf8)))
            var sites: [String] = []
            var other: [String] = []
            for b in blocks {
                if b.kind == .site { sites += b.addresses } else { other.append(b.headerText) }
            }
            return (sites, other)
        }
        let before = try shape(old)
        guard let after = try? shape(new) else {
            throw EditError.unreadable("the edited file no longer reads as a Caddyfile.")
        }
        let expected = before.sites.filter { address in !removed.contains { matches(address, $0) } }
        guard after.sites == expected, after.other == before.other else {
            throw EditError.unreadable("the edit would change more than the chosen websites.")
        }
    }

    // MARK: - Addresses

    /// Every host name the file's sites answer to.
    static func hosts(in text: String) -> Set<String> {
        guard let blocks = try? siteBlocks(tokenize(Array(text.utf8))) else { return [] }
        return Set(blocks.filter { $0.kind == .site }.flatMap(\.addresses).map { hostAndPort(of: $0).host })
    }

    /// "https://a.com:8443/x" → ("a.com", "8443"); no port → the default for
    /// the scheme (443, or 80 for http://).
    static func hostAndPort(of address: String) -> (host: String, port: String) {
        var rest = Substring(address)
        var defaultPort = "443"
        if let range = rest.range(of: "://") {
            if rest[..<range.lowerBound].lowercased() == "http" { defaultPort = "80" }
            rest = rest[range.upperBound...]
        }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        if rest.hasPrefix("[") {   // [IPv6]:port
            if let close = rest.firstIndex(of: "]") {
                let host = rest[rest.index(after: rest.startIndex)..<close]
                let after = rest[rest.index(after: close)...]
                return (host.lowercased(), after.hasPrefix(":") ? String(after.dropFirst()) : defaultPort)
            }
        }
        if let colon = rest.lastIndex(of: ":") {
            return (rest[..<colon].lowercased(), String(rest[rest.index(after: colon)...]))
        }
        return (rest.lowercased(), defaultPort)
    }

    static func matches(_ address: String, _ target: Target) -> Bool {
        let (host, port) = hostAndPort(of: address)
        guard !host.isEmpty, host == target.host else { return false }
        return target.ports.isEmpty || target.ports.contains(port)
    }

    // MARK: - Blocks

    struct Block {
        enum Kind { case site, globalOptions, snippet, namedRoute }
        let kind: Kind
        /// Token indexes of the address list ("a.com," "b.com").
        let header: [Int]
        let open: Int
        let close: Int
        let addresses: [String]
        let headerText: String
    }

    /// The top-level blocks, in order. Top-level `import` lines are skipped.
    static func siteBlocks(_ tokens: [Token]) throws -> [Block] {
        var blocks: [Block] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.isClose { throw EditError.unreadable("a \"}\" on line \(t.line) closes nothing.") }
            if t.text == "import" && !t.quoted {
                let line = t.line
                while i < tokens.count, tokens[i].line == line { i += 1 }
                continue
            }
            // The address list runs to the "{" — on one line, or over several
            // when each line ends with a comma.
            var header: [Int] = []
            var j = i
            while j < tokens.count, !tokens[j].isOpen {
                if let last = header.last, tokens[j].line != tokens[last].line,
                   !tokens[last].text.hasSuffix(","), !tokens[j].text.hasPrefix(",") {
                    throw EditError.unreadable("line \(tokens[last].line) has a site without { … } braces.")
                }
                if tokens[j].isClose { throw EditError.unreadable("unexpected \"}\" on line \(tokens[j].line).") }
                header.append(j)
                j += 1
            }
            guard j < tokens.count else {
                throw EditError.unreadable("the file ends inside a site (line \(t.line)).")
            }
            if let last = header.last, tokens[last].line != tokens[j].line {
                throw EditError.unreadable("the \"{\" on line \(tokens[j].line) isn't on the same line as its address.")
            }
            var depth = 0
            var k = j
            while k < tokens.count {
                if tokens[k].isOpen { depth += 1 } else if tokens[k].isClose { depth -= 1 }
                if depth == 0 { break }
                k += 1
            }
            guard k < tokens.count else {
                throw EditError.unreadable("the block starting on line \(tokens[j].line) is never closed.")
            }
            let headerText = header.map { tokens[$0].text }.joined(separator: " ")
            let addresses = headerText.split(separator: ",")
                .flatMap { $0.split(separator: " ") }
                .map(String.init).filter { !$0.isEmpty }
            let kind: Block.Kind
            if header.isEmpty { kind = .globalOptions }
            else if headerText.hasPrefix("(") { kind = .snippet }
            else if headerText.hasPrefix("&(") { kind = .namedRoute }
            else { kind = .site }
            blocks.append(Block(kind: kind, header: header, open: j, close: k,
                                addresses: kind == .site ? addresses : [], headerText: headerText))
            i = k + 1
        }
        return blocks
    }

    /// From the start of the block's first line to the end of its closing
    /// line, plus one blank line so no gap is left behind. Comments around
    /// it stay.
    private static func wholeBlockRange(_ block: Block, tokens: [Token], bytes: [UInt8]) -> Range<Int> {
        let newline = UInt8(ascii: "\n")
        func lineStart(_ offset: Int) -> Int {
            var s = offset
            while s > 0, bytes[s - 1] != newline { s -= 1 }
            return s
        }
        func lineEnd(_ offset: Int) -> Int {   // just past the "\n"
            var e = offset
            while e < bytes.count, bytes[e] != newline { e += 1 }
            return min(e + 1, bytes.count)
        }
        func isBlank(_ s: Int, _ e: Int) -> Bool {
            bytes[s..<e].allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == newline || $0 == UInt8(ascii: "\r") }
        }
        let start = lineStart(tokens[block.header.first ?? block.open].start)
        var end = lineEnd(tokens[block.close].end - 1)
        // Leave one blank line, not two.
        let blankBefore = start == 0 || isBlank(lineStart(start - 1), start)
        if blankBefore, end < bytes.count {
            let nextEnd = lineEnd(end)
            if isBlank(end, nextEnd) { end = nextEnd }
        }
        return start..<end
    }

    // MARK: - Tokens

    struct Token {
        let text: String
        /// Byte offsets into the file.
        let start: Int
        let end: Int
        let line: Int
        /// Had quotes, a heredoc or an escape: never a brace.
        let quoted: Bool

        var isOpen: Bool { !quoted && text == "{" }
        var isClose: Bool { !quoted && text == "}" }
    }

    static func tokenize(_ b: [UInt8]) throws -> [Token] {
        let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), cr = UInt8(ascii: "\r"), nl = UInt8(ascii: "\n")
        let hash = UInt8(ascii: "#"), dq = UInt8(ascii: "\""), bt = UInt8(ascii: "`"), bs = UInt8(ascii: "\\")
        var tokens: [Token] = []
        var i = 0
        var line = 1
        while i < b.count {
            let c = b[i]
            if c == nl { line += 1; i += 1; continue }
            if c == space || c == tab || c == cr { i += 1; continue }
            if c == hash {   // comment to the end of the line
                while i < b.count, b[i] != nl { i += 1 }
                continue
            }
            let start = i
            let startLine = line
            var quoted = false
            var inDQ = false, inBT = false
            while i < b.count {
                let ch = b[i]
                if inDQ {
                    if ch == bs, i + 1 < b.count { if b[i + 1] == nl { line += 1 }; i += 2; continue }
                    if ch == nl { line += 1 }
                    if ch == dq { inDQ = false }
                    i += 1; continue
                }
                if inBT {
                    if ch == nl { line += 1 }
                    if ch == bt { inBT = false }
                    i += 1; continue
                }
                if ch == space || ch == tab || ch == cr || ch == nl { break }
                if ch == dq { inDQ = true; quoted = true; i += 1; continue }
                if ch == bt { inBT = true; quoted = true; i += 1; continue }
                if ch == bs, i + 1 < b.count, b[i + 1] != nl { quoted = true; i += 2; continue }
                i += 1
            }
            if inDQ || inBT { throw EditError.unreadable("a quote opened on line \(startLine) is never closed.") }
            var text = String(decoding: b[start..<i], as: UTF8.self)

            // Heredoc: <<MARKER, then lines up to one that is just MARKER.
            if text.hasPrefix("<<"), text.count > 2,
               text.dropFirst(2).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
               i < b.count, b[i] == nl || b[i] == cr {
                let marker = String(text.dropFirst(2))
                var closed = false
                while i < b.count {
                    // Move to the start of the next line.
                    while i < b.count, b[i] != nl { i += 1 }
                    guard i < b.count else { break }
                    i += 1; line += 1
                    var e = i
                    while e < b.count, b[e] != nl { e += 1 }
                    // The closing line is the marker, maybe indented and
                    // followed by more arguments ("HTML 200").
                    var m = i
                    while m < e, b[m] == space || b[m] == tab { m += 1 }
                    let markerBytes = Array(marker.utf8)
                    if e - m >= markerBytes.count, Array(b[m..<(m + markerBytes.count)]) == markerBytes {
                        let after = m + markerBytes.count
                        if after == e || b[after] == space || b[after] == tab || b[after] == cr {
                            i = after
                            closed = true
                            break
                        }
                    }
                }
                if !closed { throw EditError.unreadable("the heredoc on line \(startLine) is never closed.") }
                text = String(decoding: b[start..<i], as: UTF8.self)
                quoted = true
            }
            tokens.append(Token(text: text, start: start, end: i, line: startLine, quoted: quoted))
        }
        return tokens
    }
}
