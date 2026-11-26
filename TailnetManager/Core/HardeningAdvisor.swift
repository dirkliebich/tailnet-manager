import Foundation

// MARK: - Host OS

enum HostOS {
    case linux, macOS, windows, mobile, other

    init(_ device: Device) {
        switch (device.os ?? "").lowercased() {
        case "linux": self = .linux
        case "macos": self = .macOS
        case "windows": self = .windows
        case "ios", "android", "tvos": self = .mobile
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .mobile: return "Mobile"
        case .other: return "this device"
        }
    }

    /// Commands only make sense on a machine with a shell we can reach.
    var isCommandable: Bool { self == .linux || self == .macOS || self == .windows }
}

// MARK: - Command lines

/// One line of a hardening script: an optional comment above a command.
/// A step with a nil command is pure guidance (no runnable line).
struct HardeningLine: Identifiable, Hashable {
    let id = UUID()
    let comment: String?
    let command: String?
}

// MARK: - Remediation step

struct HardeningStep: Identifiable, Hashable {
    let id: String
    let severity: FindingSeverity
    let title: String
    let rationale: String
    /// An action the app itself can perform through the review sheet.
    let apiAction: HardeningAPIAction?
    /// Commands the admin runs on the machine (already boot-safe / ordered).
    let lines: [HardeningLine]
    /// When true the fix lives in the ACL policy — link to the console.
    let requiresPolicyEdit: Bool

    var hasCommands: Bool { lines.contains { $0.command != nil } }
}

/// Which app-run action (if any) a step maps to. Resolved to a DeviceChange
/// against the specific device by AppState.
enum HardeningAPIAction: Hashable {
    case disableRoutes
    case reenableKeyExpiry
    case revokeApproval
    case expireKey
}

// MARK: - Per-machine report

struct HardeningReport: Identifiable {
    let device: Device
    let os: HostOS
    let steps: [HardeningStep]

    var id: String { device.id }
    var commandableSteps: [HardeningStep] { steps.filter(\.hasCommands) }
    var topSeverity: FindingSeverity { steps.map(\.severity).max() ?? .info }

    /// The full copy-paste hardening script: a preamble that guarantees
    /// Tailscale stays reachable and starts at boot, then every step's
    /// commands in a safe order. Empty when the OS has no runnable shell.
    var fullScript: String {
        guard os.isCommandable else { return "" }
        var out: [String] = []
        out.append(HardeningAdvisor.scriptHeader(os: os, device: device))
        out.append("")
        out.append(HardeningAdvisor.tailscaleKeepAlivePreamble(os: os))
        for step in commandableSteps {
            out.append("")
            out.append("# === \(step.title) ===")
            for line in step.lines {
                if let comment = line.comment { out.append("# \(comment)") }
                if let command = line.command { out.append(command) }
            }
        }
        out.append("")
        out.append(HardeningAdvisor.verifyFooter(os: os))
        return out.joined(separator: "\n")
    }
}

// MARK: - Advisor

enum HardeningAdvisor {

    /// The Tailscale CGNAT range every host firewall rule must trust so the
    /// tailnet keeps working.
    static let cgnatRange = "100.64.0.0/10"

    // MARK: Reports

    static func reports(devices: [Device],
                        findings: [SecurityFinding],
                        settings: TailnetSettings?) -> [HardeningReport] {
        devices.compactMap { device in
            let steps = self.steps(for: device, findings: findings, settings: settings)
            guard !steps.isEmpty else { return nil }
            return HardeningReport(device: device, os: HostOS(device), steps: steps)
        }
        .sorted { $0.topSeverity > $1.topSeverity }
    }

    static func report(for device: Device,
                       findings: [SecurityFinding],
                       settings: TailnetSettings?) -> HardeningReport {
        HardeningReport(device: device, os: HostOS(device),
                        steps: steps(for: device, findings: findings, settings: settings))
    }

    // MARK: Step derivation

    private static func steps(for device: Device,
                              findings: [SecurityFinding],
                              settings: TailnetSettings?) -> [HardeningStep] {
        // External (shared-in) devices aren't ours to harden.
        guard device.isExternal != true else { return [] }

        let os = HostOS(device)
        let isServer = device.isTagged
            || (device.enabledRoutes?.isEmpty == false)
            || os == .linux || os == .windows
        var steps: [HardeningStep] = []

        // 1) Public SSH exposed by a policy rule reaching this device.
        let sshFinding = findings.first { f in
            f.deviceIDs.contains(device.id) &&
            (f.id.hasPrefix("ssh-wide") || f.id.hasPrefix("ssh-members") || f.id.hasPrefix("wideopen"))
        }
        if let sshFinding {
            steps.append(HardeningStep(
                id: "close-ssh",
                severity: sshFinding.severity,
                title: "Close public SSH (port 22)",
                rationale: "A policy rule lets others reach SSH on this machine. Close port 22 to the public internet while keeping it reachable over Tailscale. The tailnet grant itself is in the policy file — tighten that in the console too.",
                apiAction: nil,
                lines: closePublicSSHLines(os: os),
                requiresPolicyEdit: true))
        }

        // 2) Accepts all incoming connections (no Tailscale-level shield).
        //    blocksIncomingConnections == false is a real, observable signal.
        if device.blocksIncomingConnections == false || device.blocksIncomingConnections == nil {
            let detected = device.blocksIncomingConnections == false
            steps.append(HardeningStep(
                id: "host-firewall",
                severity: detected ? .medium : .low,
                title: detected ? "Accepts all incoming connections" : "Confirm a host firewall is active",
                rationale: detected
                    ? "This device isn't blocking incoming connections. Add a host firewall that denies everything except the Tailscale interface, so only tailnet peers your policy allows can reach it."
                    : "The API can't see whether a host firewall is running. Apply a default-deny firewall that always trusts the Tailscale interface — safe to run even if one is already configured.",
                apiAction: nil,
                lines: hostFirewallLines(os: os, isServer: isServer),
                requiresPolicyEdit: false))
        }

        // 3) Tailscale persistence across reboot (ALWAYS — your standing rule).
        steps.append(HardeningStep(
            id: "persist-tailscale",
            severity: .info,
            title: "Keep Tailscale (and SSH) alive after reboot",
            rationale: "Guarantees tailscaled starts at boot and Tailscale SSH stays enabled, so you never lose access to this machine after a restart.",
            apiAction: nil,
            lines: persistTailscaleLines(os: os),
            requiresPolicyEdit: false))

        // 4) Exit node.
        if (device.enabledRoutes ?? []).contains(where: { $0 == "0.0.0.0/0" || $0 == "::/0" }) {
            steps.append(HardeningStep(
                id: "exit-node",
                severity: .high,
                title: "Acting as an exit node",
                rationale: "Routes other devices' internet traffic. Disable its routes from the app if that isn't intended.",
                apiAction: .disableRoutes,
                lines: [],
                requiresPolicyEdit: false))
        }

        // 5) Subnet router.
        let subnetRoutes = (device.enabledRoutes ?? []).filter { $0 != "0.0.0.0/0" && $0 != "::/0" }
        if !subnetRoutes.isEmpty {
            steps.append(HardeningStep(
                id: "subnet-router",
                severity: .medium,
                title: "Advertises subnet \(subnetRoutes.joined(separator: ", "))",
                rationale: "Exposes a LAN to the tailnet. Keep IP forwarding persistent if intended, or disable the routes from the app.",
                apiAction: .disableRoutes,
                lines: subnetForwardingLines(os: os),
                requiresPolicyEdit: false))
        }

        // 6) Node key never expires (tagged servers).
        if device.keyExpiryDisabled == true && device.isTagged {
            steps.append(HardeningStep(
                id: "key-expiry",
                severity: .low,
                title: "Node key never expires",
                rationale: "A stolen key for this server would work forever. Re-enable key expiry from the app unless uptime truly requires it.",
                apiAction: .reenableKeyExpiry,
                lines: [],
                requiresPolicyEdit: false))
        }

        // 7) Client update available + auto-update off.
        if device.updateAvailable == true {
            steps.append(HardeningStep(
                id: "auto-update",
                severity: .low,
                title: "Client update available",
                rationale: "Keep this machine on the latest Tailscale client automatically, and update it now.",
                apiAction: nil,
                lines: autoUpdateLines(os: os),
                requiresPolicyEdit: false))
        }

        return steps.sorted { $0.severity > $1.severity }
    }

    // MARK: Script assembly helpers

    static func scriptHeader(os: HostOS, device: Device) -> String {
        switch os {
        case .windows:
            return "# Hardening for \(device.shortName) — run in an elevated PowerShell.\n# Review every line before running. Order matters: Tailscale is preserved first."
        default:
            return "#!/usr/bin/env bash\nset -euo pipefail\n# Hardening for \(device.shortName). Review before running.\n# Order matters: Tailscale is kept reachable BEFORE anything is closed."
        }
    }

    /// The non-negotiable preamble: Tailscale up at boot + SSH persisted,
    /// so the admin can never be locked out by the steps that follow.
    static func tailscaleKeepAlivePreamble(os: HostOS) -> String {
        switch os {
        case .linux:
            return [
                "# --- Keep Tailscale reachable and persistent (run FIRST) ---",
                "sudo systemctl enable --now tailscaled",
                "sudo tailscale set --ssh",
            ].joined(separator: "\n")
        case .macOS:
            return [
                "# --- Keep Tailscale reachable and persistent (run FIRST) ---",
                "sudo tailscale set --ssh",
                "# The Tailscale.app / tailscaled login item keeps it running at boot.",
            ].joined(separator: "\n")
        case .windows:
            return [
                "# --- Keep Tailscale reachable and persistent (run FIRST) ---",
                "Set-Service Tailscale -StartupType Automatic",
                "Start-Service Tailscale",
                "tailscale set --ssh",
            ].joined(separator: "\n")
        default:
            return "# Configure Tailscale to start at login on this device."
        }
    }

    static func verifyFooter(os: HostOS) -> String {
        switch os {
        case .linux:
            return [
                "# --- Verify: you should still see this host on the tailnet ---",
                "tailscale status",
                "sudo ufw status verbose 2>/dev/null || sudo firewall-cmd --list-all 2>/dev/null || true",
            ].joined(separator: "\n")
        case .macOS:
            return "# --- Verify ---\ntailscale status\n/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"
        case .windows:
            return "# --- Verify ---\ntailscale status\nGet-NetFirewallProfile | Select Name,Enabled"
        default:
            return "# Verify Tailscale still connects."
        }
    }

    // MARK: Command blocks

    /// Close public SSH while ALWAYS keeping the Tailscale interface open.
    private static func closePublicSSHLines(os: HostOS) -> [HardeningLine] {
        switch os {
        case .linux:
            return [
                HardeningLine(comment: "Allow the Tailscale interface + CGNAT range FIRST (never lock yourself out)", command: "sudo ufw allow in on tailscale0 comment 'Tailscale'"),
                HardeningLine(comment: nil, command: "sudo ufw allow from \(cgnatRange) comment 'Tailscale CGNAT'"),
                HardeningLine(comment: "Now deny SSH on every other interface (public internet, LAN)", command: "sudo ufw deny 22/tcp"),
                HardeningLine(comment: "Enable the firewall (idempotent)", command: "sudo ufw --force enable"),
                HardeningLine(comment: "firewalld alternative (if you use firewalld instead of ufw):", command: nil),
                HardeningLine(comment: nil, command: "# sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 && sudo firewall-cmd --permanent --remove-service=ssh && sudo firewall-cmd --reload"),
                HardeningLine(comment: "Reach this box afterwards with:  ssh you@<its-100.x-tailscale-ip>  or  tailscale ssh", command: nil),
            ]
        case .macOS:
            return [
                HardeningLine(comment: "Turn on the application firewall and block incoming by default", command: "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"),
                HardeningLine(comment: nil, command: "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on"),
                HardeningLine(comment: "Tailscale traffic tunnels through tailscaled, so Tailscale SSH keeps working. If you run the built-in Remote Login, restrict it to the Tailscale IP in Sharing settings.", command: nil),
            ]
        case .windows:
            return [
                HardeningLine(comment: "Block inbound TCP 22 on the public + domain profiles", command: "New-NetFirewallRule -DisplayName 'Block public SSH' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Block -Profile Public,Domain"),
                HardeningLine(comment: "Allow anything arriving over the Tailscale adapter", command: "New-NetFirewallRule -DisplayName 'Allow Tailscale' -Direction Inbound -InterfaceAlias 'Tailscale' -Action Allow"),
            ]
        default:
            return []
        }
    }

    /// Default-deny host firewall that always trusts the Tailscale interface.
    private static func hostFirewallLines(os: HostOS, isServer: Bool) -> [HardeningLine] {
        switch os {
        case .linux:
            var lines = [
                HardeningLine(comment: "Trust the Tailscale interface and CGNAT range before denying anything", command: "sudo ufw allow in on tailscale0 comment 'Tailscale'"),
                HardeningLine(comment: nil, command: "sudo ufw allow from \(cgnatRange) comment 'Tailscale CGNAT'"),
                HardeningLine(comment: "Default deny all other inbound traffic", command: "sudo ufw default deny incoming"),
                HardeningLine(comment: nil, command: "sudo ufw default allow outgoing"),
                HardeningLine(comment: nil, command: "sudo ufw --force enable"),
            ]
            if !isServer {
                lines.append(HardeningLine(comment: "Client-only alternative — let Tailscale itself block all incoming (do NOT use on a box you SSH into):", command: nil))
                lines.append(HardeningLine(comment: nil, command: "# sudo tailscale set --shields-up"))
            }
            return lines
        case .macOS:
            return [
                HardeningLine(comment: "Enable the built-in application firewall, stealth mode on", command: "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"),
                HardeningLine(comment: nil, command: "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on"),
            ]
        case .windows:
            return [
                HardeningLine(comment: "Default-deny inbound on public/domain, allow the Tailscale adapter", command: "Set-NetFirewallProfile -Profile Public,Domain -DefaultInboundAction Block -Enabled True"),
                HardeningLine(comment: nil, command: "New-NetFirewallRule -DisplayName 'Allow Tailscale' -Direction Inbound -InterfaceAlias 'Tailscale' -Action Allow"),
            ]
        default:
            return []
        }
    }

    private static func persistTailscaleLines(os: HostOS) -> [HardeningLine] {
        switch os {
        case .linux:
            return [
                HardeningLine(comment: "Start tailscaled automatically at boot", command: "sudo systemctl enable --now tailscaled"),
                HardeningLine(comment: "Persist Tailscale SSH so you keep access after a reboot", command: "sudo tailscale set --ssh"),
            ]
        case .macOS:
            return [
                HardeningLine(comment: "Persist Tailscale SSH", command: "sudo tailscale set --ssh"),
                HardeningLine(comment: "Keep Tailscale running at login (System Settings ▸ General ▸ Login Items).", command: nil),
            ]
        case .windows:
            return [
                HardeningLine(comment: "Run the Tailscale service automatically at boot", command: "Set-Service Tailscale -StartupType Automatic"),
                HardeningLine(comment: nil, command: "tailscale set --ssh"),
            ]
        default:
            return [HardeningLine(comment: "Set Tailscale to launch on startup in the app settings.", command: nil)]
        }
    }

    private static func subnetForwardingLines(os: HostOS) -> [HardeningLine] {
        switch os {
        case .linux:
            return [
                HardeningLine(comment: "Persist IP forwarding across reboots (needed for subnet routing)", command: "echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf"),
                HardeningLine(comment: nil, command: "echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf"),
                HardeningLine(comment: nil, command: "sudo sysctl -p /etc/sysctl.d/99-tailscale.conf"),
            ]
        default:
            return [HardeningLine(comment: "Subnet routing is typically a Linux role.", command: nil)]
        }
    }

    private static func autoUpdateLines(os: HostOS) -> [HardeningLine] {
        switch os {
        case .linux:
            return [
                HardeningLine(comment: "Keep the client current automatically, then update now", command: "sudo tailscale set --auto-update"),
                HardeningLine(comment: nil, command: "sudo tailscale update"),
            ]
        case .macOS:
            return [HardeningLine(comment: "Update via the App Store or the Tailscale app; enable auto-update in the app.", command: "tailscale set --auto-update")]
        case .windows:
            return [HardeningLine(comment: "Enable auto-update; run the latest installer to update now.", command: "tailscale set --auto-update")]
        default:
            return [HardeningLine(comment: "Update Tailscale from the device's app store.", command: nil)]
        }
    }
}
