#if os(macOS)
import SwiftUI

/// Opens a Tailscale SSH session to a server: in Ghostty when it's
/// installed, else in Terminal (or another app the admin picks). Tailscale
/// signs you in; no keys involved. A "check" rule shows its approval link
/// in the terminal.
enum TailscaleSSH {

    /// Names to sign in as: the one the app's scan used, then the ones
    /// Scan settings and the access rules allow.
    @MainActor
    static func logins(_ app: AppState, _ device: Device) -> [String] {
        var out: [String] = []
        if let login = app.services.scans[device.id]?.login { out.append(login) }
        out += app.services.logins(for: device, allowed: app.sshLoginsAllowed(on: device))
        var seen = Set<String>()
        return out.filter { ServiceInventory.isValidLogin($0) && seen.insert($0).inserted }
    }

    /// The MagicDNS name ("server.example.ts.net"), else the Tailscale address.
    static func host(_ device: Device) -> String? {
        let name = device.name.hasSuffix(".") ? String(device.name.dropLast()) : device.name
        let safe = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" } }
        if safe(name), name.contains(".") { return name }
        return device.addresses?.first(where: { !$0.contains(":") }).flatMap { safe($0) ? $0 : nil }
    }

    static func command(_ login: String, _ device: Device) -> String? {
        host(device).map { "ssh \(login)@\($0)" }
    }

    private static func url(_ login: String, _ device: Device) -> URL? {
        guard ServiceInventory.isValidLogin(login), let host = host(device) else { return nil }
        return URL(string: "ssh://\(login)@\(host)")
    }

    static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    /// Ghostty, when installed (used by default).
    static var ghostty: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
    }

    /// The app SSH opens in by default: "Ghostty" or "Terminal".
    static var defaultAppName: String { ghostty == nil ? "Terminal" : "Ghostty" }

    /// The Mac's own app for ssh:// links when it isn't Terminal (Termius, iTerm…).
    static var otherApp: (name: String, url: URL)? {
        guard let probe = URL(string: "ssh://user@host"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe),
              app.lastPathComponent != "Terminal.app", app.lastPathComponent != "Ghostty.app" else { return nil }
        return (app.deletingPathExtension().lastPathComponent, app)
    }

    /// Opens the session in Ghostty (when installed) or Terminal, or in
    /// `app` when given.
    @MainActor
    static func open(_ login: String, _ device: Device, in app: URL? = nil) {
        if app == nil, let ghostty {
            openInGhostty(login, device, ghostty)
            return
        }
        guard let url = url(login, device) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app ?? terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The AppleScript that makes Ghostty open a window running ssh. The
    /// window closes when you log out; after an error it waits for Return
    /// so the message can be read. Name and host are checked (letters,
    /// digits, ".", "-", ":"), so nothing in them needs quoting.
    static func ghosttyScript(login: String, host: String) -> String? {
        guard ServiceInventory.isValidLogin(login),
              !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" })
        else { return nil }
        let line = "/usr/bin/ssh \(login)@\(host) || { echo; echo SSH ended with an error. Press Return to close.; read x; }"
        return """
        tell application id "com.mitchellh.ghostty"
            activate
            set cfg to new surface configuration
            set command of cfg to "/bin/sh -c '\(line)'"
            new window with configuration cfg
        end tell
        """
    }

    /// Ghostty ignores launch arguments from a sandboxed app (and takes no
    /// ssh:// links), so the window is asked for over AppleScript. macOS
    /// asks once for permission; if it's refused, Terminal opens instead.
    @MainActor
    static func openInGhostty(_ login: String, _ device: Device, _ app: URL) {
        guard let host = host(device), let source = ghosttyScript(login: login, host: host),
              let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        if let url = url(login, device) {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
        let alert = NSAlert()
        alert.messageText = "Couldn't open Ghostty, so the session opened in Terminal"
        alert.informativeText = code == -1743
            ? "Tailnet Manager isn't allowed to control Ghostty. Turn it on in System Settings › Privacy & Security › Automation › Tailnet Manager › Ghostty."
            : "Ghostty said: \(error[NSAppleScript.errorMessage] as? String ?? "error \(code)")"
        alert.runModal()
    }
}

/// "SSH" — opens Tailscale SSH as the usual name; the arrow offers the
/// other allowed names and copying the command.
struct SSHButton: View {
    let app: AppState
    let device: Device

    var body: some View {
        let logins = TailscaleSSH.logins(app, device)
        if let first = logins.first, TailscaleSSH.host(device) != nil {
            Menu {
                ForEach(logins, id: \.self) { login in
                    Button("SSH as \(login)") { TailscaleSSH.open(login, device) }
                }
                if TailscaleSSH.ghostty != nil {
                    Divider()
                    ForEach(logins, id: \.self) { login in
                        Button("Open in Terminal as \(login)") { TailscaleSSH.open(login, device, in: TailscaleSSH.terminal) }
                    }
                }
                if let other = TailscaleSSH.otherApp {
                    Divider()
                    ForEach(logins, id: \.self) { login in
                        Button("Open in \(other.name) as \(login)") { TailscaleSSH.open(login, device, in: other.url) }
                    }
                }
                Divider()
                if let command = TailscaleSSH.command(first, device) {
                    Button("Copy “\(command)”") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
            } label: {
                Label("SSH", systemImage: "terminal")
            } primaryAction: {
                TailscaleSSH.open(first, device)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(!device.isOnline)
            .help(device.isOnline
                  ? "Open a Tailscale SSH session to \(device.shortName) as \(first) in \(TailscaleSSH.defaultAppName)"
                  : "\(device.shortName) is offline")
        }
    }
}
#endif
