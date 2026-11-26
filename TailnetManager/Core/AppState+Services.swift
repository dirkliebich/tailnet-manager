import Foundation

extension AppState {

    /// Linux machines the access rules let the admin sign in to with
    /// Tailscale SSH — the servers the Services page scans. Shared-in
    /// machines are never scanned. When the admin or the rules aren't known
    /// yet, only tagged (server) machines are: never someone's own computer.
    var serviceScanTargets: [Device] {
        cached("scanTargets") {
            let proxies = kubeProxies
            return devices.filter { device in
                guard (device.os ?? "").lowercased() == "linux", device.isExternal != true else { return false }
                // A Tailscale operator proxy is a website of its cluster, with nothing to sign in to.
                guard proxies[device.shortName] == nil else { return false }
                guard currentAdmin != nil, policyModel != nil else { return device.isTagged }
                return sshLoginsAllowed(on: device) != nil
            }
        }
    }

    /// Tailnet machines that are Tailscale operator proxies of a scanned
    /// Kubernetes cluster (machine name → the server the cluster runs on).
    /// They show as that server's websites, not as servers.
    var kubeProxies: [String: String] {
        cached("kubeProxies") {
            var out: [String: String] = [:]
            for row in inventoryRows where !row.tailnetMachine.isEmpty { out[row.tailnetMachine] = row.server }
            return out
        }
    }

    /// Every server's inventory rows (Services page, alerts, reports).
    var inventoryRows: [InventoryRow] {
        cached("inventoryRows") {
            let byIP = machinesByIP
            let domain = tailnetDomain
            return currentScans
                .sorted { $0.serverName.localizedStandardCompare($1.serverName) == .orderedAscending }
                .flatMap { InventoryBuilder.rows(for: $0, machinesByIP: byIP, tailnetDomain: domain) }
        }
    }

    /// Sign-in names the SSH rules allow the admin on this machine
    /// (nil = no rule covers it, or unknown).
    func sshLoginsAllowed(on device: Device) -> [String]? {
        guard let admin = currentAdmin, let policyModel else { return nil }
        return PolicyAnalyzer.sshLogins(for: admin, on: device, model: policyModel,
                                        members: users.filter { $0.type != "shared" })
    }

    /// The tailnet's DNS suffix ("example.ts.net"), from the machines' names.
    var tailnetDomain: String {
        cached("tailnetDomain") {
            devices.lazy.map { InventoryBuilder.tailnetDomain(fromMachineName: $0.name) }
                .first { $0.hasSuffix(".ts.net") } ?? ""
        }
    }

    /// Tailscale address → machine name, to name upstreams on other servers.
    var machinesByIP: [String: String] {
        cached("machinesByIP") {
            var out: [String: String] = [:]
            for device in devices {
                for address in device.addresses ?? [] where out[address] == nil { out[address] = device.shortName }
            }
            return out
        }
    }

    /// What Refresh does (⌘R, the sidebar, the Refresh buttons): reloads the
    /// network data AND reads the servers again, so Services and the server
    /// stats change too. The minute-by-minute background refresh doesn't
    /// scan; servers are re-checked every 30 minutes on their own.
    func refreshNow() async {
        await refreshAll()
        #if os(macOS)
        await scanServices()
        #endif
    }

    /// Refresh is running (network data or the servers).
    var isRefreshing: Bool { isLoading || services.isScanning }

    #if os(macOS)
    /// The automatic check: a read-only scan when the last one is more than
    /// 30 minutes old, so disks running out show up on Home.
    func autoScanIfDue() async {
        guard services.autoCheck, !services.isScanning, services.isDue(every: 30 * 60) else { return }
        let list = serviceScanTargets.filter(\.isOnline)
        guard !list.isEmpty else { return }
        await services.scan(list, machinesByIP: machinesByIP, interactive: false) { [weak self] device in
            self?.sshLoginsAllowed(on: device)
        }
    }

    /// Scans the given servers (default: every online target).
    func scanServices(_ servers: [Device]? = nil) async {
        let list = (servers ?? serviceScanTargets).filter(\.isOnline)
        await services.scan(list, machinesByIP: machinesByIP) { [weak self] device in
            self?.sshLoginsAllowed(on: device)
        }
    }
    #endif
}
