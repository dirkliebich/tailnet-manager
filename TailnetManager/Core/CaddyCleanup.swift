#if os(macOS)
import Foundation

// MARK: - Broken websites that can be removed

/// A website the Services page marks broken, worked out for removal from
/// Caddy. Only a site that nothing on its own server answers for any more
/// may be removed: one that still reaches a working program, container,
/// folder or another of your servers stays (it is only partly broken).
struct BrokenWebsite: Identifiable, Hashable {
    let id: String
    let serverID: String
    let server: String
    /// "api.example.com" (no port).
    let host: String
    /// As Caddy serves it: ["443"], ["8443"].
    let ports: [String]
    /// The row's name on the Services page ("a.com", "a.com:8443").
    let name: String
    /// "/ → port 8001" for each path that goes nowhere.
    let deadPaths: [String]
    /// Outside places some paths still send to (they go too), e.g. PostHog.
    let alsoGoes: [String]
    /// Why it can't be removed: what still works on this server.
    let stillWorks: [String]

    var canRemove: Bool { stillWorks.isEmpty && !deadPaths.isEmpty }

    var target: CaddyfileEditor.Target { .init(host: host, ports: Set(ports)) }
}

extension AppState {

    /// Every broken website, removable ones first.
    var brokenWebsites: [BrokenWebsite] {
        cached("brokenWebsites") {
            let machines = Set(machinesByIP.values)
            return inventoryRows
                .filter { $0.removableFromCaddy && $0.hasMissingBackend && $0.name != "Any name" }
                .map { row in
                    var dead: [String] = [], also: [String] = [], works: [String] = []
                    for route in row.routes {
                        let path = route.path.isEmpty ? "/" : route.path
                        let text = route.text
                        if text.contains(InventoryBuilder.nothingListening) {
                            let target = text.components(separatedBy: " — ").first ?? text
                            dead.append("\(path) → \(target)")
                        } else if text.hasPrefix("redirects to ") {
                            also.append("\(path) \(text)")
                        } else if text.hasPrefix("port ") || text.hasPrefix("files in ") || text.hasPrefix("replies ")
                                    || text.hasPrefix("container ") || text.hasPrefix("private address ")
                                    || machines.contains(String(text.split(separator: " ").first ?? "")) {
                            works.append("\(path) → \(text)")
                        } else {
                            also.append("\(path) → \(text)")
                        }
                    }
                    let host = String(row.name.split(separator: ":").first ?? Substring(row.name))
                    let ports = row.ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    return BrokenWebsite(id: row.id, serverID: row.serverID, server: row.server, host: host,
                                         ports: ports, name: row.name, deadPaths: dead, alsoGoes: also, stillWorks: works)
                }
                .sorted { ($0.canRemove ? 0 : 1, $0.server, $0.name) < ($1.canRemove ? 0 : 1, $1.server, $1.name) }
        }
    }

    // MARK: - Plan

    /// Reads the Caddy settings of every server involved (read-only), works
    /// out the exact edit, and returns one review plan: per server, back up
    /// → remove → Caddy checks it → reload Caddy → confirm the sites are gone.
    func planRemovingWebsites(_ sites: [BrokenWebsite]) async throws -> ChangePlan {
        let chosen = sites.filter(\.canRemove)
        guard !chosen.isEmpty else { throw CaddyCleanupError.message("Choose at least one website.") }
        let byServer = Dictionary(grouping: chosen, by: \.serverID)
        let stamp = Self.stampFormatter.string(from: .now)

        // Read every server at once.
        var setups: [String: Swift.Result<CaddySetup, Error>] = [:]
        await withTaskGroup(of: (String, Swift.Result<CaddySetup, Error>).self) { group in
            for serverID in byServer.keys {
                guard let device = devices.first(where: { $0.id == serverID }) else { continue }
                guard let login = services.scans[serverID]?.login
                    ?? services.logins(for: device, allowed: sshLoginsAllowed(on: device)).first else {
                    setups[serverID] = .failure(CaddyCleanupError.message(
                        "Set an SSH sign-in name in Scan settings, then scan the server again."
                    ))
                    continue
                }
                group.addTask { [weak self] in
                    guard let self else { return (serverID, .failure(CaddyCleanupError.message("Stopped."))) }
                    do { return (serverID, .success(try await self.readCaddySetup(device, login: login))) }
                    catch { return (serverID, .failure(error)) }
                }
            }
            for await (id, result) in group { setups[id] = result }
        }

        var operations: [ChangePlan.Operation] = []
        var diffs: [ChangePlan.FileDiff] = []
        var warnings: [String] = []
        var removedCount = 0

        for (serverID, serverSites) in byServer.sorted(by: { $0.value[0].server < $1.value[0].server }) {
            let name = serverSites[0].server
            guard let device = devices.first(where: { $0.id == serverID }) else {
                warnings.append("\(name): this machine is no longer on your network.")
                continue
            }
            let setup: CaddySetup
            switch setups[serverID] {
            case .success(let s): setup = s
            case .failure(let error): warnings.append("\(name): \(error.localizedDescription) Nothing will change there."); continue
            case nil: warnings.append("\(name): couldn't be reached. Nothing will change there."); continue
            }

            // Edit every file that holds one of the sites.
            let targets = Set(serverSites.map(\.target))
            var edits: [CaddyFileEdit] = []
            var found = Set<CaddyfileEditor.Target>()
            var changes: [String] = []
            var refused: String?
            for file in setup.files {
                do {
                    let result = try CaddyfileEditor.remove(targets, from: file.text)
                    found.formUnion(result.found)
                    changes += result.changes
                    if result.newText != file.text {
                        edits.append(CaddyFileEdit(path: file.path, sha256: file.sha256, oldText: file.text, newText: result.newText))
                    }
                } catch {
                    refused = "\(file.path): \(error.localizedDescription)"
                    break
                }
            }
            if let refused {
                warnings.append("\(name): \(refused) Nothing will change there.")
                continue
            }
            for site in serverSites where !found.contains(site.target) {
                warnings.append("\(name): \(site.name) isn't in its Caddy files (it may come from somewhere else), so it stays.")
            }
            guard !edits.isEmpty else { continue }

            // Names that disappear completely can be checked in Caddy's live settings.
            let stillServed = setup.files.reduce(into: Set<String>()) { all, file in
                let text = edits.first { $0.path == file.path }?.newText ?? file.text
                all.formUnion(CaddyfileEditor.hosts(in: text))
            }
            let confirmHosts = serverSites.filter { found.contains($0.target) }.map(\.host)
                .filter { !stillServed.contains($0) }
            let removedHere = serverSites.filter { found.contains($0.target) }
            removedCount += removedHere.count

            for edit in edits {
                diffs.append(.init(title: "\(name) · \(edit.path)",
                                   lines: PolicyLineDiff.lines(old: edit.oldText, new: edit.newText)))
            }
            let backups = edits.map { "\($0.path).bak-tailnet-manager-\(stamp)" }
            var detail = removedHere.map(\.name).joined(separator: ", ")
            detail += "\nBackup first: \(backups.joined(separator: ", "))"
            if !setup.isRunning {
                detail += "\nCaddy isn't running on this server: only the file changes, nothing is started."
            }
            let login = setup.login
            operations.append(.reporting(
                title: "Remove \(removedHere.count) website\(removedHere.count == 1 ? "" : "s") on \(name)",
                detail: detail, symbol: "trash", isDestructive: true
            ) { [weak self] in
                guard let self else { throw CaddyCleanupError.message("Stopped.") }
                return try await self.applyCaddyEdits(edits, on: device, login: login, main: setup.mainPath,
                                                      stamp: stamp, confirm: confirmHosts)
            })
        }

        guard !operations.isEmpty else {
            throw CaddyCleanupError.message(warnings.isEmpty ? "Nothing to remove." : warnings.joined(separator: "\n"))
        }
        let plan = ChangePlan(
            title: "Remove \(removedCount) broken website\(removedCount == 1 ? "" : "s") from Caddy",
            summary: "On each server: the Caddy settings are backed up, the websites are taken out, Caddy checks the result, then Caddy reloads so the other websites keep running. If Caddy rejects anything, the backup is put back. Afterwards the app checks Caddy's live settings to confirm they're gone.",
            operations: operations)
        plan.fileDiffs = diffs
        plan.warnings = warnings
        plan.applyLabel = "Remove \(removedCount) website\(removedCount == 1 ? "" : "s")"
        let changedIDs = Array(byServer.keys)
        plan.onFinish = { [weak self] _ in
            guard let self else { return }
            let list = self.devices.filter { changedIDs.contains($0.id) }
            Task { await self.scanServices(list) }
        }
        return plan
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: - Reading

    private func readCaddySetup(_ device: Device, login: String) async throws -> CaddySetup {
        let output = try await runCaddyScript(CaddyScripts.read, argument: "-", on: device, login: login)
        return try CaddySetup.parse(output, login: login)
    }

    // MARK: - Applying

    /// Runs on the server as root: checks nothing changed since it was read,
    /// checks Caddy accepts the current settings, backs up, writes, lets
    /// Caddy check the new settings (backup put back if not), reloads Caddy
    /// when it runs (backup put back if the reload fails), then looks the
    /// removed names up in Caddy's live settings.
    private func applyCaddyEdits(_ edits: [CaddyFileEdit], on device: Device, login: String, main: String,
                                 stamp: String, confirm hosts: [String]) async throws -> String {
        // A copy on this Mac too.
        CaddyBackupStore.save(edits, server: device.shortName, stamp: stamp)

        var job = "STAMP \(stamp)\nMAIN \(main)\n"
        for edit in edits {
            job += "FILE \(edit.sha256) \(edit.path) \(Data(edit.newText.utf8).base64EncodedString())\n"
        }
        for host in hosts { job += "HOST \(host)\n" }
        let encoded = Data(job.utf8).base64EncodedString()
        guard encoded.count < 100_000 else {
            throw CaddyCleanupError.message("These Caddy files are too big to send in one go. Nothing was changed.")
        }

        let output = try await runCaddyScript(CaddyScripts.apply, argument: encoded, on: device, login: login)
        let lines = output.split(separator: "\n").map(String.init)
        func value(_ tag: String) -> [String] {
            lines.filter { $0.hasPrefix("@@\(tag)") }.map { String($0.dropFirst(tag.count + 2)).trimmingCharacters(in: .whitespaces) }
        }
        if let path = value("CHANGED").first {
            throw CaddyCleanupError.message("Someone changed \(path) after the app read it, so nothing was changed. Refresh and try again.")
        }
        if let message = value("FAIL").first { throw CaddyCleanupError.message(message) }
        guard lines.contains("@@CHECKED"), lines.contains("@@DONE") else {
            throw CaddyCleanupError.message("The server stopped before it finished. If the change was made, its backup is \(edits.map { "\($0.path).bak-tailnet-manager-\(stamp)" }.joined(separator: ", ")).")
        }

        var note = "Backed up (\(value("BACKUP").joined(separator: ", "))) · Caddy accepted the change"
        note += lines.contains("@@RELOADED") ? " · Caddy reloaded" : " · Caddy isn't running here, so nothing was reloaded"
        let gone = value("GONE"), still = value("STILL")
        if lines.contains("@@NOCONFIRM") {
            note += " · couldn't read Caddy's live settings to confirm"
        } else if !hosts.isEmpty {
            note += still.isEmpty ? " · confirmed gone: \(gone.count) of \(hosts.count)"
                : " · still mentioned in Caddy's live settings: \(still.joined(separator: ", "))"
        }
        return note
    }

    /// Runs one of the fixed Caddy scripts as root (passwordless sudo) and
    /// returns what it printed. The script text and its argument travel as
    /// base64, so nothing from the server or the admin is ever read as shell.
    private func runCaddyScript(_ script: String, argument: String, on device: Device, login: String) async throws -> String {
        guard ServiceInventory.isValidLogin(login) else { throw CaddyCleanupError.message("Bad sign-in name.") }
        guard argument.allSatisfy({ $0.isLetter || $0.isNumber || "+/=-".contains($0) }) else {
            throw CaddyCleanupError.message("Bad data.")
        }
        guard let address = device.addresses?.first(where: { !$0.contains(":") }) ?? device.primaryAddress else {
            throw CaddyCleanupError.message("This machine has no Tailscale address.")
        }
        let encoded = Data(script.utf8).base64EncodedString()
        // The login shell may be zsh: keep this line plain sh that zsh reads the same.
        let command = "P=$(printf %s '\(encoded)' | base64 -d) && "
            + "if [ \"$(id -u)\" = 0 ]; then sh -c \"$P\" sh '\(argument)'; "
            + "elif sudo -n true 2>/dev/null; then sudo -n sh -c \"$P\" sh '\(argument)'; "
            + "else echo '@@NOSUDO'; fi"
        let services = self.services
        let result = await SSHRunner.run(login: login, host: address, command: command, timeout: 180) { url in
            Task { @MainActor in services.openApproval(url) }
        }
        if result.output.contains("@@NOSUDO") {
            throw CaddyCleanupError.message("The sign-in \(login) can't use sudo without a password here, so Caddy can't be changed.")
        }
        guard result.status == 0 || result.output.contains("@@") else {
            throw CaddyCleanupError.message(result.plainError)
        }
        return result.output
    }
}

enum CaddyCleanupError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

// MARK: - What the server reports

struct CaddyFileEdit {
    let path: String
    let sha256: String
    let oldText: String
    let newText: String
}

struct CaddySetup {
    struct File {
        let path: String
        let sha256: String
        let text: String
    }

    let login: String
    let isRunning: Bool
    let mainPath: String
    var files: [File]

    static func parse(_ output: String, login: String) throws -> CaddySetup {
        guard output.contains("@@END") else { throw CaddyCleanupError.message("Couldn't read the Caddy settings.") }
        let lines = output.components(separatedBy: "\n")
        var running = false, main = "", adapter = ""
        var files: [File] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("@@ACTIVE ") { running = line.dropFirst(9).trimmingCharacters(in: .whitespaces) == "active" }
            if line.hasPrefix("@@MAIN ") { main = line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("@@ADAPTER ") { adapter = line.dropFirst(10).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("@@FILE "), i + 1 < lines.count {
                let parts = line.dropFirst(7).split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, let data = Data(base64Encoded: lines[i + 1].trimmingCharacters(in: .whitespaces)),
                   let text = String(data: data, encoding: .utf8) {
                    files.append(File(path: parts[1], sha256: parts[0], text: text))
                }
                i += 1
            }
            i += 1
        }
        guard !main.isEmpty else {
            throw CaddyCleanupError.message("Couldn't tell which file Caddy reads (it doesn't run as the usual caddy service).")
        }
        guard adapter.isEmpty || adapter == "caddyfile" else {
            throw CaddyCleanupError.message("Caddy reads \(adapter) settings here, not a Caddyfile.")
        }
        guard files.first?.path == main else { throw CaddyCleanupError.message("Couldn't read \(main).") }
        let pathPattern = #"^/[A-Za-z0-9._@+/-]+$"#
        guard files.allSatisfy({ $0.path.range(of: pathPattern, options: .regularExpression) != nil
                                 && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) }) else {
            throw CaddyCleanupError.message("A Caddy file has an unusual name, so the app won't edit it.")
        }
        return CaddySetup(login: login, isRunning: running, mainPath: main, files: files)
    }
}

/// A copy of every Caddy file before and after a change, on this Mac
/// (App Support/TailnetManager/caddy-backups/<server>/<time>/).
enum CaddyBackupStore {
    static func save(_ edits: [CaddyFileEdit], server: String, stamp: String) {
        guard let base = ServiceScanStore.folder?
            .appendingPathComponent("caddy-backups")
            .appendingPathComponent(server.replacingOccurrences(of: "/", with: "_"))
            .appendingPathComponent(stamp) else { return }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for edit in edits {
            let name = edit.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "_")
            try? edit.oldText.write(to: base.appendingPathComponent(name + ".before"), atomically: true, encoding: .utf8)
            try? edit.newText.write(to: base.appendingPathComponent(name + ".after"), atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - The two scripts

/// Fixed shell scripts, run as root through `sh -c` (never the login shell).
/// Their only input is one base64 argument.
enum CaddyScripts {
    /// Read-only: is Caddy running, which file it reads, and that file plus
    /// the files it imports (path, sha256, base64 text).
    static let read = #"""
    cd / || exit 0
    echo "@@ACTIVE $(systemctl is-active caddy 2>/dev/null)"
    X=$(systemctl show -p ExecStart --value caddy 2>/dev/null | tr ' ;' '\n\n')
    M=$(printf '%s\n' "$X" | awk 'p{print; exit} $0=="--config"{p=1} /^--config=/{sub(/^--config=/,""); print; exit}')
    A=$(printf '%s\n' "$X" | awk 'p{print; exit} $0=="--adapter"{p=1} /^--adapter=/{sub(/^--adapter=/,""); print; exit}')
    echo "@@MAIN $M"
    echo "@@ADAPTER $A"
    dump() { echo "@@FILE $(sha256sum "$1" | cut -d' ' -f1) $1"; base64 -w0 "$1"; echo; }
    if [ -n "$M" ] && [ -f "$M" ]; then
      dump "$M"
      D=$(dirname "$M")
      for p in $(grep -E '^[[:space:]]*import[[:space:]]' "$M" | awk '{print $2}'); do
        case "$p" in */*|*'*'*|*.caddy|*.conf|*.caddyfile) ;; *) continue ;; esac
        case "$p" in /*) ;; *) p="$D/$p" ;; esac
        for f in $p; do [ -f "$f" ] && [ "$f" != "$M" ] && dump "$f"; done
      done
    fi
    echo "@@END"
    """#

    /// The change. $1 = base64 of lines: STAMP <time>, MAIN <file Caddy
    /// reads>, FILE <sha256 as read> <path> <base64 new text>, HOST <name to
    /// confirm gone>. Prints @@ lines the app reads; always exits 0.
    static let apply = #"""
    set -u
    cd / || exit 0
    W=$(mktemp -d 2>/dev/null) || { echo "@@FAIL Couldn't make a work folder on the server. Nothing was changed."; exit 0; }
    trap 'rm -rf "$W"' EXIT
    printf '%s' "$1" | base64 -d > "$W/job" 2>/dev/null || { echo "@@FAIL The change didn't arrive in one piece. Nothing was changed."; exit 0; }
    STAMP=$(awk '$1=="STAMP"{print $2; exit}' "$W/job")
    MAIN=$(awk '$1=="MAIN"{print $2; exit}' "$W/job")
    case "$STAMP" in ""|*[!0-9-]*) echo "@@FAIL Bad time stamp. Nothing was changed."; exit 0 ;; esac
    case "$MAIN" in /*) ;; *) echo "@@FAIL Bad file name. Nothing was changed."; exit 0 ;; esac
    U=$(systemctl show -p User --value caddy 2>/dev/null); [ -n "$U" ] || U=root
    T=""; command -v timeout >/dev/null 2>&1 && T="timeout 90"
    check() {
      if [ "$U" = root ]; then out=$($T caddy validate --config "$MAIN" --adapter caddyfile 2>&1)
      else out=$($T sudo -n -u "$U" -H caddy validate --config "$MAIN" --adapter caddyfile 2>&1); fi
      rc=$?
      [ $rc -eq 0 ] || printf '%s\n' "$out" | grep -v '^{' | grep -v '^[[:space:]]*$' | tail -n 2 | tr '\n' ' '
      return $rc
    }
    restore() {
      while read -r rk rsha rp rdata; do
        [ "$rk" = FILE ] || continue
        [ -f "$rp.bak-tailnet-manager-$STAMP" ] && cp -p "$rp.bak-tailnet-manager-$STAMP" "$rp"
      done < "$W/job"
    }
    while read -r k sha p data; do
      [ "$k" = FILE ] || continue
      case "$p" in /*) ;; *) echo "@@FAIL Bad file name. Nothing was changed."; exit 0 ;; esac
      [ -f "$p" ] || { echo "@@FAIL $p is gone. Nothing was changed."; exit 0; }
      [ "$(sha256sum "$p" | cut -d' ' -f1)" = "$sha" ] || { echo "@@CHANGED $p"; exit 0; }
    done < "$W/job"
    if ! msg=$(check); then echo "@@FAIL Caddy already rejects the current settings, so nothing was changed: $msg"; exit 0; fi
    while read -r k sha p data; do
      [ "$k" = FILE ] || continue
      cp -p "$p" "$p.bak-tailnet-manager-$STAMP" || { echo "@@FAIL Couldn't back up $p, so nothing was changed."; exit 0; }
      echo "@@BACKUP $p.bak-tailnet-manager-$STAMP"
    done < "$W/job"
    while read -r k sha p data; do
      [ "$k" = FILE ] || continue
      if ! { printf '%s' "$data" | base64 -d > "$p.tailnet-manager-new" && chown --reference="$p" "$p.tailnet-manager-new" && chmod --reference="$p" "$p.tailnet-manager-new" && mv -f "$p.tailnet-manager-new" "$p"; }; then
        rm -f "$p.tailnet-manager-new"; restore
        echo "@@FAIL Couldn't write $p, so the backup was put back."; exit 0
      fi
    done < "$W/job"
    echo "@@WRITTEN"
    if ! msg=$(check); then restore; echo "@@FAIL Caddy rejected the change, so the backup was put back: $msg"; exit 0; fi
    echo "@@CHECKED"
    if [ "$(systemctl is-active caddy 2>/dev/null)" = active ]; then
      if ! out=$($T systemctl reload caddy 2>&1); then
        restore
        echo "@@FAIL Caddy couldn't load the change, so the backup was put back and Caddy keeps running as before: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; exit 0
      fi
      echo "@@RELOADED"
      sleep 1
      LIVE=$(curl -s --max-time 5 http://localhost:2019/config/ 2>/dev/null || wget -qO- -T 5 -t 1 http://localhost:2019/config/ 2>/dev/null)
    else
      echo "@@NOTRUNNING"
      LIVE=$($T caddy adapt --config "$MAIN" --adapter caddyfile 2>/dev/null)
    fi
    [ -n "$LIVE" ] || echo "@@NOCONFIRM"
    while read -r k h rest; do
      [ "$k" = HOST ] || continue
      case "$h" in ""|*[!A-Za-z0-9.*-]*) continue ;; esac
      if printf '%s' "$LIVE" | grep -qF "\"$h\""; then echo "@@STILL $h"; else echo "@@GONE $h"; fi
    done < "$W/job"
    echo "@@DONE"
    """#
}
#endif
