import Foundation

// MARK: - What the scan runs

/// The read-only script the Services page runs on each server over
/// Tailscale SSH (as root through passwordless sudo when the login has it).
/// It only lists things: open ports and the program behind each one (with
/// the folder it runs in), running services, Docker containers (the
/// system's Docker, every user's own rootless Docker, and Podman), PM2
/// apps, Caddy's live config (also of Caddy running inside a container),
/// nginx sites (when nginx runs), Kubernetes (ingresses, services,
/// workloads, Traefik routes), Cloudflare Tunnel hostnames,
/// `tailscale serve`, basic stats (CPU, load, memory, disks, uptime), and
/// the last 7 days of Tailscale SSH logins from tailscaled's own log (who,
/// as which account, when; never the commands themselves). Container and
/// pod commands and environments, Kubernetes secrets and config maps are
/// never read (they can hold passwords); for nginx only the lines that say
/// where a site goes are sent back.
enum ServiceScanScript {
    static let text = #"""
    T=""; command -v timeout >/dev/null 2>&1 && T="timeout 15"
    echo "@@HOST"; hostname
    echo "@@USER"; id -un; id -u
    echo "@@OS"; ( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" )
    echo "@@ADDRS"; ip -o addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}'
    echo "@@LISTEN"
    if command -v ss >/dev/null 2>&1; then ss -H -tlnp 2>/dev/null; else echo "@@MISSING"; fi
    echo "@@PIDS"
    for p in $(ss -H -tlnp 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -un); do
      a=$p; up=""
      for i in 1 2 3 4; do
        a=$(awk '/^PPid:/{print $2}' /proc/$a/status 2>/dev/null)
        case "$a" in ""|0|1) break;; esac
        up="$up,$a"
      done
      printf '%s|%s|%s|%s|%s\n' "$p" "$(readlink /proc/$p/exe 2>/dev/null)" "$(tail -n1 /proc/$p/cgroup 2>/dev/null)" "${up#,}" "$(readlink /proc/$p/cwd 2>/dev/null)"
    done
    echo "@@SOCKETS"; $T systemctl list-sockets --no-legend --plain --no-pager 2>/dev/null
    echo "@@SERVICES"; $T systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null
    F='{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.swarm.service.name"}}|{{.Label "com.docker.compose.service"}}'
    echo "@@DOCKER"
    if command -v docker >/dev/null 2>&1; then
      $T docker ps --format "$F" 2>&1
    else echo "@@MISSING"; fi
    echo "@@RDOCKER"
    if command -v docker >/dev/null 2>&1; then
      for s in /run/user/*/docker.sock; do
        [ -S "$s" ] || continue
        u=$(stat -c %U "$s" 2>/dev/null)
        DOCKER_HOST="unix://$s" $T docker ps --format "$F" 2>/dev/null | sed "s/^/$u|/"
      done
    fi
    if command -v podman >/dev/null 2>&1; then
      $T podman ps --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|||' 2>/dev/null | sed 's/^/@podman|/'
    fi
    echo "@@PMTWO"
    for d in /root/.pm2 /home/*/.pm2; do
      [ -d "$d/pids" ] || continue
      u=$(stat -c %U "$d" 2>/dev/null)
      for f in "$d"/pids/*.pid; do
        [ -f "$f" ] || continue
        p=$(cat "$f" 2>/dev/null)
        [ -n "$p" ] && [ -d "/proc/$p" ] || continue
        printf '%s|%s|%s|%s|%s\n' "$u" "$(basename "$f" .pid)" "$p" "$(awk '/^PPid:/{print $2}' /proc/$p/status 2>/dev/null)" "$(readlink /proc/$p/cwd 2>/dev/null)"
      done
    done
    echo "@@CADDY"
    if command -v caddy >/dev/null 2>&1 || ss -H -tlnp 2>/dev/null | grep -qE '"caddy"|(127\.0\.0\.1|\[::1\]):2019 '; then
      C=$(curl -s --max-time 5 http://localhost:2019/config/ 2>/dev/null || wget -qO- -T 5 -t 1 http://localhost:2019/config/ 2>/dev/null)
      if [ -n "$C" ] && [ "$C" != "null" ]; then printf '%s\n' "$C"
      elif [ -f /etc/caddy/Caddyfile ] && command -v caddy >/dev/null 2>&1; then $T caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null
      fi
    else echo "@@MISSING"; fi
    echo "@@CCADDY"
    if command -v docker >/dev/null 2>&1; then
      { $T docker ps --format '|{{.ID}}|{{.Names}}|{{.Image}}|{{.Ports}}' 2>/dev/null
        for s in /run/user/*/docker.sock; do
          [ -S "$s" ] || continue
          u=$(stat -c %U "$s" 2>/dev/null)
          DOCKER_HOST="unix://$s" $T docker ps --format "$u"'|{{.ID}}|{{.Names}}|{{.Image}}|{{.Ports}}' 2>/dev/null
        done
      } | while IFS='|' read -r u id name image ports; do
        case "$image" in *caddy*) ;; *) continue;; esac
        case "$ports" in *'->2019/tcp'*) continue;; esac
        H=""; [ -n "$u" ] && H="unix:///run/user/$(id -u "$u" 2>/dev/null)/docker.sock"
        C=$(env ${H:+DOCKER_HOST=$H} $T docker exec "$id" sh -c 'wget -qO- -T 5 http://127.0.0.1:2019/config/ 2>/dev/null || caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null' </dev/null 2>/dev/null | tr -d '\n')
        case "$C" in '{'*) printf '%s|%s|%s\n' "$u" "$name" "$C";; esac
      done
    fi
    echo "@@NGINX"
    if command -v nginx >/dev/null 2>&1 && ss -H -tlnp 2>/dev/null | grep -q '"nginx"'; then
      $T nginx -T 2>/dev/null | sed 's/#.*//' | grep -E '[{}]|^[[:space:]]*(listen|server_name|proxy_pass|uwsgi_pass|fastcgi_pass|grpc_pass|root|alias|return|server)[[:space:]]'
    fi
    echo "@@TUNNEL"
    if command -v cloudflared >/dev/null 2>&1 || pgrep -x cloudflared >/dev/null 2>&1; then
      pgrep -x cloudflared >/dev/null 2>&1 && echo "running"
      for f in /etc/cloudflared/config.yml /etc/cloudflared/config.yaml /root/.cloudflared/config.yml /home/*/.cloudflared/config.yml; do
        [ -f "$f" ] && grep -E '^[[:space:]-]*(hostname|service|path):' "$f" 2>/dev/null
      done
    fi
    echo "@@KUBE"
    K=""
    if command -v k3s >/dev/null 2>&1; then K="k3s kubectl"
    elif command -v microk8s >/dev/null 2>&1; then K="microk8s kubectl"
    elif command -v kubectl >/dev/null 2>&1; then
      if [ -f /etc/kubernetes/admin.conf ]; then K="kubectl --kubeconfig /etc/kubernetes/admin.conf"
      elif [ -f /etc/rancher/rke2/rke2.yaml ]; then K="kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
      elif [ -f "$HOME/.kube/config" ]; then K="kubectl"; fi
    fi
    if [ -n "$K" ]; then
      if $T $K get --raw /version >/dev/null 2>&1; then
        $T $K get ingress -A -o go-template='{{range .items}}ING|{{.metadata.namespace}}|{{.metadata.name}}|{{.spec.ingressClassName}}{{with .metadata.annotations}}{{index . "kubernetes.io/ingress.class"}}{{end}}|{{range .status.loadBalancer.ingress}}{{.hostname}}{{.ip}},{{end}}|{{range .spec.tls}}{{range .hosts}}{{.}},{{end}}{{end}}|{{with .spec.defaultBackend}}{{with .service}}{{.name}}:{{.port.number}}{{.port.name}}{{end}}{{end}}|{{range .spec.rules}}{{.host}}={{with .http}}{{range .paths}}{{.path}}>{{.backend.service.name}}:{{.backend.service.port.number}}{{.backend.service.port.name}};{{end}}{{end}}^{{end}}|{{with .metadata.annotations}}{{index . "tailscale.com/funnel"}}{{end}}
    {{end}}' 2>/dev/null
        $T $K get service -A -o go-template='{{range .items}}SVC|{{.metadata.namespace}}|{{.metadata.name}}|{{.spec.type}}|{{.spec.loadBalancerClass}}|{{with .metadata.annotations}}{{index . "tailscale.com/expose"}}{{end}}|{{with .metadata.annotations}}{{index . "tailscale.com/hostname"}}{{end}}|{{range .status.loadBalancer.ingress}}{{.hostname}}{{.ip}},{{end}}|{{range .spec.externalIPs}}{{.}},{{end}}|{{range .spec.ports}}{{.port}}:{{.targetPort}}:{{.nodePort}}:{{.protocol}},{{end}}|{{if .spec.selector}}selector{{end}}
    {{end}}' 2>/dev/null
        $T $K get endpointslices -A -o go-template='{{range .items}}EPS|{{.metadata.namespace}}|{{with .metadata.labels}}{{index . "kubernetes.io/service-name"}}{{end}}|{{range .endpoints}}{{range .addresses}}{{.}}{{end}}@{{with .targetRef}}{{.name}}{{end}}@{{with .conditions}}{{.ready}}{{end}},{{end}}|{{range .ports}}{{.port}},{{end}}
    {{end}}' 2>/dev/null
        $T $K get deployments,statefulsets,daemonsets -A -o go-template='{{range .items}}WL|{{.kind}}|{{.metadata.namespace}}|{{.metadata.name}}|{{or .status.readyReplicas .status.numberReady 0}}|{{or .spec.replicas .status.desiredNumberScheduled 0}}|{{range .spec.template.spec.containers}}{{.image}},{{end}}
    {{end}}' 2>/dev/null
        for r in ingressroutes.traefik.io ingressroutes.traefik.containo.us; do
          $T $K get "$r" -A -o go-template='{{range .items}}IR|{{.metadata.namespace}}|{{.metadata.name}}|{{range .spec.entryPoints}}{{.}},{{end}}|{{if .spec.tls}}tls{{end}}|{{range .spec.routes}}{{.match}}>{{range .services}}{{.name}}:{{.port}},{{end}}^{{end}}
    {{end}}' 2>/dev/null
        done
      else echo "ERR|Kubernetes is installed but couldn't be read (is it running?)"; fi
    fi
    echo "@@TSSERVE"; $T tailscale serve status --json 2>/dev/null
    echo "@@STATS"
    echo "cpus $(nproc 2>/dev/null)"
    echo "cpumodel $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
    echo "load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    echo "uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    echo "kernel $(uname -r 2>/dev/null)"
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null | awk '{print "mem " $1 " " $2}'
    [ -f /var/run/reboot-required ] && echo "reboot yes"
    echo "@@DISKS"
    $T df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x fuse -x fuse.s3fs -x nfs -x nfs4 -x cifs 2>/dev/null | tail -n +2
    echo "@@SSHLOG"
    $T journalctl -u tailscaled --since "7 days ago" --no-pager -o short-iso 2>/dev/null | awk '
    /ssh-session\(sess-/ {
      if (!match($0, /sess-[0-9T]+-[0-9a-f]+/)) next
      s = substr($0, RSTART, RLENGTH)
      if (!(s in start)) { start[s] = $1; order[++n] = s }
      if (index($0, "handling new SSH connection from ")) { w = $0; sub(/.*handling new SSH connection from /, "", w); who[s] = w }
      else if (index($0, "access granted")) { res[s] = "granted" }
      else if (index($0, "starting pty command")) { kind[s] = "shell" }
      else if (index($0, "starting non-pty command")) { kind[s] = index($0, "--cmd=P=$(printf %s ") ? "app" : "command" }
      else if (index($0, "Session complete")) { fin[s] = $1 }
    }
    END { for (i = 1; i <= n; i++) { s = order[i]; print start[s] "|" fin[s] "|" s "|" res[s] "|" kind[s] "|" who[s] } }'
    echo "@@END"
    """#

    /// What runs on the server: decodes the script and runs it as root when
    /// passwordless sudo is available, otherwise as the login itself.
    static var remoteCommand: String {
        let encoded = Data(text.utf8).base64EncodedString()
        return "P=$(printf %s '\(encoded)' | base64 -d) && "
            + "if [ \"$(id -u)\" != 0 ] && sudo -n true 2>/dev/null; "
            + "then sudo -n sh -c \"$P\"; else sh -c \"$P\"; fi"
    }
}

// MARK: - Reach

/// How far a listening address reaches, read only from the address a
/// program is bound to. It says nothing about firewalls in front of it.
enum ServiceReach: Int, Codable, Comparable, CaseIterable {
    case none = 0, local, privateNetwork, tailscale, publicAddress, allNetworks

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .none: return "No open port"
        case .local: return "This server only"
        case .privateNetwork: return "Private network"
        case .tailscale: return "Tailscale only"
        case .publicAddress: return "Public address"
        case .allNetworks: return "All networks"
        }
    }

    /// Classifies a bind address as ss, Docker and Caddy print it
    /// ("0.0.0.0", "*", "[::]", "127.0.0.53%lo", "100.x", "fd7a:…").
    static func of(address raw: String) -> ServiceReach {
        let a = normalizedAddress(raw)
        let lower = a.lowercased()
        if a.isEmpty || a == "*" || a == "0.0.0.0" || a == "::" { return .allNetworks }
        if a.hasPrefix("127.") || a == "::1" || lower == "localhost" { return .local }
        if lower.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") { return .privateNetwork }
        let octets = a.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (100, 64...127): return .tailscale
            case (10, _), (192, 168), (172, 16...31), (169, 254): return .privateNetwork
            default: return .publicAddress
            }
        }
        return .publicAddress
    }
}

/// "[::ffff:127.0.0.1]" → "127.0.0.1", "127.0.0.53%lo" → "127.0.0.53".
func normalizedAddress(_ raw: String) -> String {
    var a = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
    // IPv4-mapped IPv6, as Java's dual-stack sockets show up in ss.
    if a.lowercased().hasPrefix("::ffff:"), a.contains(".") { a = String(a.dropFirst("::ffff:".count)) }
    return a
}

/// True for numeric addresses and wildcards ("*", ""), false for things
/// like "vsock:" that systemd also lists.
func isIPAddress(_ raw: String) -> Bool {
    let a = normalizedAddress(raw)
    if a.isEmpty || a == "*" { return true }
    return a.contains(where: { $0 == "." || $0 == ":" })
        && a.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
}

/// "8000-8010" → 8000...8010, "8080" → 8080...8080.
func portRange(_ text: String) -> ClosedRange<Int>? {
    let bits = text.split(separator: "-").compactMap { Int($0) }
    if bits.count == 1 { return bits[0]...bits[0] }
    if bits.count == 2, bits[0] <= bits[1] { return bits[0]...bits[1] }
    return nil
}

/// "host:port" → (host, port), for IPv6 in brackets too ("[::]:22").
func splitHostPort(_ raw: String) -> (host: String, port: String) {
    guard let colon = raw.lastIndex(of: ":") else { return (raw, "") }
    let host = String(raw[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return (host, String(raw[raw.index(after: colon)...]))
}

// MARK: - What one scan found

struct ServerScan: Codable, Identifiable, Hashable {
    var id: String { deviceID }
    let deviceID: String
    let serverName: String
    let login: String
    let scannedAt: Date
    var hostname: String = ""
    var osName: String = ""
    /// The server's own IP addresses (public, private, Docker bridges…).
    var addresses: [String] = []
    var ranAsRoot = false
    var portsListed = true
    var dockerInstalled = false
    /// Docker's own error when it's installed but couldn't be read.
    var dockerError = ""
    var caddyFound = false
    var listeners: [Listener] = []
    var sockets: [SocketUnit] = []
    var services: [SystemService] = []
    var containers: [ContainerInfo] = []
    var websites: [WebSite] = []
    var tailscaleSites: [WebSite] = []
    /// Websites from everything else that serves them: Caddy inside a
    /// container, nginx, Kubernetes (ingresses, Traefik routes, Tailscale
    /// operator) and Cloudflare Tunnel. `WebSite.via` says which.
    var otherSites: [WebSite] = []
    var pm2Apps: [PM2App] = []
    var kube: KubeInventory?
    /// cloudflared is installed or running.
    var tunnelFound = false
    var tunnelRunning = false
    var stats: ServerStats?
    var sshSessions: [SSHSession] = []

    /// Caddy runs on the server itself (not only inside a container), so
    /// its websites live in /etc/caddy/Caddyfile.
    var caddyOnHost: Bool {
        services.contains { $0.unit == "caddy.service" }
            || listeners.contains { $0.process == "caddy" && $0.containerID.isEmpty }
    }
}

/// An app PM2 keeps running (all its copies).
struct PM2App: Codable, Hashable {
    let user: String
    let name: String
    let pids: [Int]
    let folder: String
    /// The PM2 daemon(s) that started it.
    var parents: [Int] = []
}

/// One Tailscale SSH login to a server, from tailscaled's log.
struct SSHSession: Codable, Hashable {
    enum Kind: String, Codable { case shell, command, app, unknown }
    let id: String
    let start: Date?
    let end: Date?
    /// Tailnet login of the person ("alex@example.com").
    let user: String
    /// Tailscale address they came from.
    let fromIP: String
    /// Account on the server ("operator").
    let localUser: String
    let granted: Bool
    let kind: Kind
}

/// Basic health numbers read during the scan.
struct ServerStats: Codable, Hashable {
    var cpus: Int?
    var cpuModel = ""
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var uptimeSeconds: Double?
    var kernel = ""
    var memTotalKB: Int?
    var memAvailableKB: Int?
    var swapTotalKB: Int?
    var swapFreeKB: Int?
    var restartNeeded = false
    var disks: [DiskUsage] = []

    var memUsedPercent: Double? {
        guard let total = memTotalKB, total > 0, let avail = memAvailableKB else { return nil }
        return Double(total - avail) / Double(total) * 100
    }

    /// The system disk ("/"), else the first one.
    var rootDisk: DiskUsage? { disks.first { $0.mount == "/" } ?? disks.first }

    /// The fullest real disk (tiny boot partitions ignored).
    var fullestDisk: DiskUsage? {
        disks.filter { $0.sizeKB >= 1_048_576 }.max { $0.usedPercent < $1.usedPercent } ?? rootDisk
    }

    /// Load relative to the number of cores (1.0 = every core busy).
    var loadPerCore: Double? {
        guard let load1, let cpus, cpus > 0 else { return nil }
        return load1 / Double(cpus)
    }
}

struct DiskUsage: Codable, Hashable {
    let device: String
    let mount: String
    let sizeKB: Int
    let usedKB: Int
    let availableKB: Int

    /// Same as df's "Use%": used / (used + available), so reserved blocks
    /// don't hide a disk that's full for normal programs.
    var usedPercent: Double {
        let usable = usedKB + availableKB
        return usable > 0 ? Double(usedKB) / Double(usable) * 100 : 0
    }
}

/// A program listening on a TCP port.
struct Listener: Codable, Hashable {
    let address: String
    let port: Int
    /// Process name as the kernel reports it (max 15 characters).
    let process: String
    let pid: Int
    /// The program file, e.g. "node" or "python3.12".
    var program: String = ""
    /// The systemd unit it runs under, e.g. "caddy.service".
    var unit: String = ""
    /// Short Docker container ID when it runs inside a container.
    var containerID: String = ""
    /// Runs inside someone's login session (not a service).
    var inLoginSession = false
    /// The folder it runs in ("/home/operator/app"); "/" isn't kept.
    var folder: String = ""
    /// Its parent, grandparent… (up to four), to find the PM2 app it belongs to.
    var ancestors: [Int] = []

    var reach: ServiceReach { ServiceReach.of(address: address) }

    /// "PM2 v6.0.14: Go (node)", "MainThread (node)", "python3", …
    var displayName: String {
        if process.isEmpty { return program.isEmpty ? "unknown" : program }
        if program.isEmpty || program.hasPrefix(process) { return process }
        return "\(process) (\(program))"
    }
}

/// A systemd socket that listens for a service (e.g. ssh.socket on 22).
struct SocketUnit: Codable, Hashable {
    let address: String
    let port: Int
    let unit: String
    let activates: String
}

struct SystemService: Codable, Hashable {
    let unit: String
    let description: String
}

struct PublishedPort: Codable, Hashable {
    let hostAddress: String
    let hostPort: String
    let containerPort: String

    var reach: ServiceReach { ServiceReach.of(address: hostAddress) }
}

struct ContainerInfo: Codable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: [PublishedPort]
    let composeProject: String
    let swarmService: String
    /// The service name inside its compose project ("web"), which other
    /// containers of the project use as a host name.
    var composeService: String = ""
    /// "" = the system's Docker; otherwise the user whose own (rootless)
    /// Docker runs it, or "podman".
    var owner: String = ""

    /// "run by previews (their own Docker)".
    var ownerText: String {
        switch owner {
        case "": return ""
        case "podman": return "Podman"
        default: return "run by \(owner) (their own Docker)"
        }
    }
}

struct WebRoute: Codable, Hashable {
    enum Kind: String, Codable { case proxy, redirect, respond, files }
    /// "" means every path.
    let path: String
    let kind: Kind
    /// Upstream address, redirect URL, status code or folder.
    let target: String
}

struct WebSite: Codable, Hashable {
    /// Host name ("chat.example.com"), "*" for any name.
    let address: String
    let ports: [String]
    let reach: ServiceReach
    var routes: [WebRoute]
    /// Extra fact worth showing, e.g. "Tailscale Funnel".
    var note: String = ""
    /// What serves it: "Caddy", "Caddy in container x", "nginx",
    /// "Kubernetes ingress (traefik)", "Tailscale operator", … ("" = the
    /// server's own Caddy, or Tailscale serve for Tailscale sites).
    var via: String = ""
    /// Container whose Caddy serves it: its upstreams are names on that
    /// container's networks ("web:3000").
    var container: String = ""
    /// "http" or "https" when known; otherwise worked out from the port.
    var scheme: String = ""
    /// A Tailscale operator proxy: the tailnet machine that answers for it.
    var tailnetMachine: String = ""
    /// Reached on the tailnet (Kubernetes operator proxies), shown with
    /// the Tailscale sites.
    var onTailnet = false
}

/// Targets of the form "k8s://namespace/service:port" are Kubernetes
/// services, resolved against the same scan's Kubernetes inventory.
enum KubeTarget {
    static let scheme = "k8s://"

    static func make(namespace: String, backend: String) -> String { "\(scheme)\(namespace)/\(backend)" }

    /// "k8s://ns/svc:80" → ("ns", "svc", "80").
    static func parse(_ target: String) -> (namespace: String, service: String, port: String)? {
        guard target.hasPrefix(scheme) else { return nil }
        let rest = target.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let ns = String(rest[..<slash])
        let svc = String(rest[rest.index(after: slash)...])
        let bits = svc.split(separator: ":", maxSplits: 1).map(String.init)
        return (ns, bits.first ?? svc, bits.count > 1 ? bits[1] : "")
    }
}

// MARK: - Parsing the script's output

enum ServiceScanParser {

    enum ParseError: LocalizedError {
        case incomplete
        var errorDescription: String? { "The scan was cut off before it finished." }
    }

    static func parse(_ output: String, deviceID: String, serverName: String,
                      login: String, at date: Date = .now) throws -> ServerScan {
        let sections = split(output)
        guard sections["END"] != nil else { throw ParseError.incomplete }
        var scan = ServerScan(deviceID: deviceID, serverName: serverName, login: login, scannedAt: date)

        scan.hostname = sections["HOST"]?.first ?? ""
        let user = sections["USER"] ?? []
        scan.ranAsRoot = user.count > 1 && user[1] == "0"
        scan.osName = sections["OS"]?.first ?? ""
        scan.addresses = (sections["ADDRS"] ?? []).map { normalizedAddress($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }

        let listen = sections["LISTEN"] ?? []
        scan.portsListed = !listen.contains("@@MISSING")
        let pids = pidInfo(sections["PIDS"] ?? [])
        scan.listeners = listeners(listen, pids: pids)
        scan.sockets = sockets(sections["SOCKETS"] ?? [])
        scan.services = services(sections["SERVICES"] ?? [])

        let docker = sections["DOCKER"] ?? []
        scan.dockerInstalled = !docker.contains("@@MISSING")
        scan.containers = scan.dockerInstalled ? containers(docker) : []
        if scan.dockerInstalled, scan.containers.isEmpty,
           let problem = docker.first(where: { !$0.contains("|") }) {
            scan.dockerError = problem
        }
        // Every user's own (rootless) Docker, and Podman.
        scan.containers += ownedContainers(sections["RDOCKER"] ?? [])
        scan.pm2Apps = pm2Apps(sections["PMTWO"] ?? [])

        let caddy = (sections["CADDY"] ?? []).joined(separator: "\n")
        scan.caddyFound = !caddy.contains("@@MISSING")
        if scan.caddyFound, let json = jsonObject(caddy) {
            scan.websites = caddySites(json)
        }
        if let json = jsonObject((sections["TSSERVE"] ?? []).joined(separator: "\n")) {
            scan.tailscaleSites = tailscaleSites(json)
        }
        scan.otherSites += containerCaddySites(sections["CCADDY"] ?? [], containers: scan.containers)
        scan.otherSites += nginxSites(sections["NGINX"] ?? [])
        let tunnel = sections["TUNNEL"]
        scan.tunnelFound = tunnel != nil && !(tunnel ?? []).isEmpty
        scan.tunnelRunning = tunnel?.contains("running") ?? false
        if scan.tunnelRunning { scan.otherSites += tunnelSites(tunnel ?? []) }
        if let lines = sections["KUBE"] {
            let kube = kubeInventory(lines)
            scan.kube = kube
            scan.otherSites += kubeSites(kube)
        }
        if let lines = sections["STATS"] {
            scan.stats = stats(lines, disks: sections["DISKS"] ?? [])
        }
        scan.sshSessions = sshSessions(sections["SSHLOG"] ?? [])
        return scan
    }

    /// "cpus 16", "load 0.05 0.04 0.00", "mem MemTotal: 32089160", … and
    /// `df -P -k` lines (filesystem, size, used, available, capacity, mount).
    static func stats(_ lines: [String], disks: [String]) -> ServerStats {
        var s = ServerStats()
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "cpus": s.cpus = Int(value)
            case "cpumodel": s.cpuModel = value
            case "load":
                let l = value.split(separator: " ").compactMap { Double($0) }
                if l.count == 3 { (s.load1, s.load5, s.load15) = (l[0], l[1], l[2]) }
            case "uptime": s.uptimeSeconds = Double(value)
            case "kernel": s.kernel = value
            case "reboot": s.restartNeeded = true
            case "mem":
                let m = value.split(separator: " ").map(String.init)
                guard m.count == 2, let kb = Int(m[1]) else { continue }
                switch m[0] {
                case "MemTotal:": s.memTotalKB = kb
                case "MemAvailable:": s.memAvailableKB = kb
                case "SwapTotal:": s.swapTotalKB = kb
                case "SwapFree:": s.swapFreeKB = kb
                default: break
                }
            default: break
            }
        }
        var seen = Set<String>()
        for line in disks {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 6, let size = Int(f[1]), let used = Int(f[2]), let avail = Int(f[3]) else { continue }
            let mount = f[5...].joined(separator: " ")
            // The same filesystem mounted twice (bind mounts) counts once.
            guard seen.insert(f[0]).inserted || f[0] == "none" else { continue }
            s.disks.append(DiskUsage(device: f[0], mount: mount, sizeKB: size, usedKB: used, availableKB: avail))
        }
        return s
    }

    private static let sessionWho = try! NSRegularExpression(pattern: #"^(.*) \(([^)]*)\) to ssh-user "(.*)"$"#)

    /// "start|end|sess-id|granted|kind|login (ip) to ssh-user \"name\"" lines.
    static func sshSessions(_ lines: [String]) -> [SSHSession] {
        let iso = ISO8601DateFormatter()
        return lines.compactMap { line in
            let f = line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, f[2].hasPrefix("sess-") else { return nil }
            var user = "", ip = "", local = ""
            let range = NSRange(f[5].startIndex..., in: f[5])
            if let m = sessionWho.firstMatch(in: f[5], range: range),
               let u = Range(m.range(at: 1), in: f[5]), let i = Range(m.range(at: 2), in: f[5]),
               let l = Range(m.range(at: 3), in: f[5]) {
                user = String(f[5][u]); ip = String(f[5][i]); local = String(f[5][l])
            }
            guard !user.isEmpty else { return nil }
            return SSHSession(id: f[2], start: iso.date(from: f[0]), end: iso.date(from: f[1]),
                              user: user, fromIP: ip, localUser: local, granted: f[3] == "granted",
                              kind: SSHSession.Kind(rawValue: f[4]) ?? .unknown)
        }
    }

    /// Lines grouped under their "@@NAME" marker.
    static func split(_ output: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var current: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("@@"), line != "@@MISSING",
               line.dropFirst(2).allSatisfy({ $0.isUppercase }) {
                current = String(line.dropFirst(2))
                sections[current!, default: []] = sections[current!] ?? []
            } else if let current, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                sections[current, default: []].append(line)
            }
        }
        return sections
    }

    static func jsonObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: Ports

    private struct PIDInfo {
        let program: String
        let cgroup: String
        var ancestors: [Int] = []
        var folder = ""
    }

    /// "pid|exe|cgroup|parent,grandparent|cwd" (older scripts: the first three).
    private static func pidInfo(_ lines: [String]) -> [Int: PIDInfo] {
        var out: [Int: PIDInfo] = [:]
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            let program = parts[1].split(separator: "/").last.map(String.init) ?? ""
            var info = PIDInfo(program: program.replacingOccurrences(of: " (deleted)", with: ""),
                               cgroup: parts[2])
            if parts.count == 5 {
                info.ancestors = parts[3].split(separator: ",").compactMap { Int($0) }
                let folder = parts[4].replacingOccurrences(of: " (deleted)", with: "")
                info.folder = folder == "/" ? "" : folder
            }
            out[pid] = info
        }
        return out
    }

    private static let processPattern = try! NSRegularExpression(pattern: #"\("([^"]*)",pid=(\d+)"#)

    /// `ss -H -tlnp` lines → one listener per address:port, deduped.
    private static func listeners(_ lines: [String], pids: [Int: PIDInfo]) -> [Listener] {
        var out: [Listener] = []
        var seen = Set<String>()
        for line in lines where line != "@@MISSING" {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4 else { continue }
            let (address, portText) = splitHostPort(fields[3])
            guard let port = Int(portText) else { continue }
            // The lowest PID is usually the parent (uvicorn before its workers).
            let range = NSRange(line.startIndex..., in: line)
            let procs: [(name: String, pid: Int)] = processPattern.matches(in: line, range: range).compactMap { m in
                guard let n = Range(m.range(at: 1), in: line), let p = Range(m.range(at: 2), in: line),
                      let pid = Int(line[p]) else { return nil }
                return (String(line[n]), pid)
            }
            let proc = procs.min { $0.pid < $1.pid }
            let key = "\(address)|\(port)"
            guard seen.insert(key).inserted else { continue }
            var l = Listener(address: address, port: port, process: proc?.name ?? "", pid: proc?.pid ?? 0)
            if let info = proc.flatMap({ pids[$0.pid] }) {
                l.program = info.program
                let owner = cgroupOwner(info.cgroup)
                l.unit = owner.unit
                l.containerID = owner.containerID
                l.inLoginSession = owner.loginSession
                l.ancestors = info.ancestors
                // A container's own folder says nothing on the server.
                if owner.containerID.isEmpty { l.folder = info.folder }
            }
            out.append(l)
        }
        return out
    }

    /// "0::/system.slice/caddy.service" → caddy.service;
    /// ".../docker-<id>.scope" → container; ".../session-3.scope" → login session.
    static func cgroupOwner(_ line: String) -> (unit: String, containerID: String, loginSession: Bool) {
        let path = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).last.map(String.init) ?? line
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.reversed() {
            if part.hasPrefix("docker-"), part.hasSuffix(".scope") {
                return ("", String(part.dropFirst("docker-".count).prefix(12)), false)
            }
        }
        if let id = parts.last(where: { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) {
            return ("", String(id.prefix(12)), false)
        }
        if let service = parts.last(where: { $0.hasSuffix(".service") && !$0.hasPrefix("user@") }) {
            return (service, "", false)
        }
        if parts.contains(where: { $0.hasPrefix("session-") && $0.hasSuffix(".scope") }) {
            return ("", "", true)
        }
        return (parts.last ?? "", "", false)
    }

    /// `systemctl list-sockets` lines that listen on a TCP port.
    private static func sockets(_ lines: [String]) -> [SocketUnit] {
        lines.compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 3, !f[0].hasPrefix("/"), !f[0].hasPrefix("@") else { return nil }
            let (address, portText) = splitHostPort(f[0])
            // "-" = Accept=yes sockets (no single service); vsock etc. aren't TCP/IP.
            guard let port = Int(portText), isIPAddress(address), f[2] != "-" else { return nil }
            return SocketUnit(address: normalizedAddress(address), port: port, unit: f[1], activates: f[2])
        }
    }

    /// `systemctl list-units --plain` lines: unit load active sub description.
    private static func services(_ lines: [String]) -> [SystemService] {
        lines.compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4, f[0].hasSuffix(".service") else { return nil }
            return SystemService(unit: f[0], description: f.count == 5 ? f[4].trimmingCharacters(in: .whitespaces) : "")
        }
    }

    // MARK: Docker

    /// "id|name|image|status|ports|project|swarm service|compose service".
    static func containers(_ lines: [String], owner: String = "") -> [ContainerInfo] {
        lines.compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return nil }
            var c = ContainerInfo(id: String(f[0].prefix(12)), name: f[1], image: f[2], status: f[3],
                                  ports: publishedPorts(f[4]), composeProject: f[5], swarmService: f[6])
            if f.count >= 8 { c.composeService = f[7] }
            c.owner = owner
            return c
        }
    }

    /// The same lines with the owner in front ("previews|…", "@podman|…").
    static func ownedContainers(_ lines: [String]) -> [ContainerInfo] {
        lines.flatMap { line -> [ContainerInfo] in
            guard let bar = line.firstIndex(of: "|") else { return [] }
            var owner = String(line[..<bar])
            if owner == "@podman" { owner = "podman" }
            guard !owner.isEmpty else { return [] }
            return containers([String(line[line.index(after: bar)...])], owner: owner)
        }
    }

    /// "0.0.0.0:8077->8080/tcp, :::8077->8080/tcp, 9000/tcp" → published only.
    static func publishedPorts(_ text: String) -> [PublishedPort] {
        var out: [PublishedPort] = []
        for item in text.components(separatedBy: ", ") {
            let sides = item.components(separatedBy: "->")
            guard sides.count == 2 else { continue }
            var (host, port) = splitHostPort(sides[0])
            if host == "::" || host == ":" { host = "::" }
            let p = PublishedPort(hostAddress: host, hostPort: port, containerPort: sides[1])
            // ":::8077" and "0.0.0.0:8077" are the same port twice (IPv6/IPv4).
            if out.contains(where: { $0.hostPort == p.hostPort && $0.containerPort == p.containerPort && $0.reach == p.reach }) { continue }
            out.append(p)
        }
        return out
    }

    // MARK: Caddy

    static func caddySites(_ json: Any) -> [WebSite] {
        guard let root = json as? [String: Any],
              let apps = root["apps"] as? [String: Any],
              let http = apps["http"] as? [String: Any],
              let servers = http["servers"] as? [String: Any] else { return [] }
        var sites: [String: WebSite] = [:]
        var order: [String] = []
        for key in servers.keys.sorted() {
            guard let server = servers[key] as? [String: Any] else { continue }
            var reach = ServiceReach.none
            var ports: [String] = []
            for listen in server["listen"] as? [String] ?? [] {
                // "network/address": "tcp/:443", "unix//run/caddy.sock".
                var address = listen
                if let slash = listen.firstIndex(of: "/"), !listen[..<slash].contains(":") {
                    let network = listen[..<slash].lowercased()
                    if network.hasPrefix("unix") || network.hasPrefix("fd") { continue }
                    address = String(listen[listen.index(after: slash)...])
                }
                let (host, port) = splitHostPort(address)
                reach = max(reach, ServiceReach.of(address: host))
                if !port.isEmpty, !ports.contains(port) { ports.append(port) }
            }
            // Only a Unix socket: just programs on the server reach it.
            if ports.isEmpty { reach = .local }
            var found: [(hosts: [String], route: WebRoute)] = []
            walk(server["routes"] as? [[String: Any]] ?? [], hosts: [], path: "", into: &found)
            for (hosts, route) in found {
                for host in hosts.isEmpty ? ["*"] : hosts {
                    let id = "\(host)|\(ports.joined(separator: ","))"
                    if sites[id] == nil {
                        sites[id] = WebSite(address: host, ports: ports, reach: reach, routes: [])
                        order.append(id)
                    }
                    if !sites[id]!.routes.contains(route) { sites[id]!.routes.append(route) }
                }
            }
        }
        return order.compactMap { sites[$0] }
    }

    private static func walk(_ routes: [[String: Any]], hosts: [String], path: String,
                             into found: inout [(hosts: [String], route: WebRoute)]) {
        for route in routes {
            let sets = route["match"] as? [[String: Any]] ?? []
            let h = sets.flatMap { $0["host"] as? [String] ?? [] }
            let hostsHere = h.isEmpty ? hosts : h
            let pathHere = [path, condition(sets)].filter { !$0.isEmpty }.joined(separator: " · ")
            var rootFolder = ""
            for handler in route["handle"] as? [[String: Any]] ?? [] {
                switch handler["handler"] as? String {
                case "subroute":
                    walk(handler["routes"] as? [[String: Any]] ?? [], hosts: hostsHere, path: pathHere, into: &found)
                case "vars":
                    if let r = handler["root"] as? String { rootFolder = r }
                case "reverse_proxy":
                    let dials = (handler["upstreams"] as? [[String: Any]] ?? []).compactMap { $0["dial"] as? String }
                    for dial in dials.isEmpty ? ["(chosen at run time)"] : dials {
                        found.append((hostsHere, WebRoute(path: pathHere, kind: .proxy, target: dial)))
                    }
                case "static_response":
                    let headers = handler["headers"] as? [String: [String]] ?? [:]
                    let status = handler["status_code"].map { "\($0)" } ?? "200"
                    if let location = headers["Location"]?.first {
                        found.append((hostsHere, WebRoute(path: pathHere, kind: .redirect, target: location)))
                    } else {
                        found.append((hostsHere, WebRoute(path: pathHere, kind: .respond, target: status)))
                    }
                case "file_server":
                    let folder = handler["root"] as? String ?? (rootFolder.isEmpty ? "the site folder" : rootFolder)
                    found.append((hostsHere, WebRoute(path: pathHere, kind: .files, target: folder)))
                default:
                    continue
                }
            }
        }
    }

    /// A route's conditions in words: its paths, "not" paths, and the names
    /// of any other matchers ("if header_regexp matches").
    private static func condition(_ sets: [[String: Any]]) -> String {
        var parts: [String] = []
        let paths = sets.flatMap { $0["path"] as? [String] ?? [] }
        if !paths.isEmpty { parts.append(paths.joined(separator: ", ")) }
        let negated = sets.flatMap { ($0["not"] as? [[String: Any]] ?? []) }
        let notPaths = negated.flatMap { $0["path"] as? [String] ?? [] }
        if !notPaths.isEmpty {
            parts.append("not " + notPaths.prefix(3).joined(separator: ", ") + (notPaths.count > 3 ? " …" : ""))
        }
        let notOthers = Set(negated.flatMap(\.keys)).subtracting(["path"]).sorted()
        if !notOthers.isEmpty { parts.append("unless " + notOthers.joined(separator: ", ") + " matches") }
        let others = Set(sets.flatMap(\.keys)).subtracting(["host", "path", "not"]).sorted()
        if !others.isEmpty { parts.append("if " + others.joined(separator: ", ") + " matches") }
        return parts.joined(separator: " · ")
    }

    // MARK: Tailscale serve

    static func tailscaleSites(_ json: Any) -> [WebSite] {
        guard let config = json as? [String: Any] else { return [] }
        var out: [WebSite] = []
        collectServe(config, into: &out)
        // VIP services, and sessions left running in a terminal
        // ("tailscale funnel 3000") which live under Foreground.
        for section in ["Services", "Foreground"] {
            guard let nested = config[section] as? [String: Any] else { continue }
            for key in nested.keys.sorted() {
                if let sub = nested[key] as? [String: Any] { collectServe(sub, into: &out) }
            }
        }
        return out
    }

    private static func collectServe(_ config: [String: Any], into out: inout [WebSite]) {
        let funnel = config["AllowFunnel"] as? [String: Bool] ?? [:]
        let web = config["Web"] as? [String: Any] ?? [:]
        for hostPort in web.keys.sorted() {
            let handlers = (web[hostPort] as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            var routes: [WebRoute] = []
            for path in handlers.keys.sorted() {
                guard let h = handlers[path] as? [String: Any] else { continue }
                let shown = path == "/" ? "" : path
                if let proxy = h["Proxy"] as? String {
                    routes.append(WebRoute(path: shown, kind: .proxy, target: proxy))
                } else if let folder = h["Path"] as? String {
                    routes.append(WebRoute(path: shown, kind: .files, target: folder))
                } else if h["Text"] != nil {
                    routes.append(WebRoute(path: shown, kind: .respond, target: "fixed text"))
                }
            }
            let (host, port) = splitHostPort(hostPort)
            let isFunnel = funnel[hostPort] == true
            out.append(WebSite(address: port == "443" ? host : hostPort, ports: [port],
                               reach: isFunnel ? .publicAddress : .tailscale, routes: routes,
                               note: isFunnel ? "Tailscale Funnel — open to the internet" : ""))
        }
        let tcp = config["TCP"] as? [String: Any] ?? [:]
        for port in tcp.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            guard let forward = (tcp[port] as? [String: Any])?["TCPForward"] as? String else { continue }
            let isFunnel = funnel.contains { $0.key.hasSuffix(":\(port)") && $0.value }
            out.append(WebSite(address: "TCP port \(port)", ports: [port],
                               reach: isFunnel ? .publicAddress : .tailscale,
                               routes: [WebRoute(path: "", kind: .proxy, target: forward)],
                               note: isFunnel ? "Tailscale Funnel — open to the internet" : ""))
        }
    }
}

// MARK: - Inventory rows

/// One line of the service inventory, built from a scan.
struct InventoryRow: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case website = "Website"
        case tailscaleSite = "Tailscale site"
        case container = "Container"
        case kubernetes = "Kubernetes app"
        case pm2 = "PM2 app"
        case service = "Service"
        case program = "Program"

        var order: Int { Kind.allCases.firstIndex(of: self) ?? 0 }

        var plural: String {
            switch self {
            case .website: return "Websites"
            case .tailscaleSite: return "Tailscale sites"
            case .container: return "Containers"
            case .kubernetes: return "Kubernetes apps"
            case .pm2: return "PM2 apps"
            case .service: return "Services"
            case .program: return "Programs"
            }
        }

        func count(_ n: Int) -> String {
            "\(n) " + (n == 1 ? rawValue.lowercased() : plural.lowercased())
                .replacingOccurrences(of: "kubernetes", with: "Kubernetes")
                .replacingOccurrences(of: "pm2", with: "PM2")
        }

        var systemImage: String {
            switch self {
            case .website: return "globe"
            case .tailscaleSite: return "lock.shield"
            case .container: return "shippingbox"
            case .kubernetes: return "square.stack.3d.up"
            case .pm2: return "arrow.triangle.2.circlepath"
            case .service: return "gearshape.2"
            case .program: return "terminal"
            }
        }

        /// Something people open in a browser (or connect to by name).
        var isSite: Bool { self == .website || self == .tailscaleSite }
    }

    /// A website path and where it leads ("" = every other path).
    struct RouteLine: Hashable {
        let path: String
        let text: String
    }

    let id: String
    let serverID: String
    let server: String
    let kind: Kind
    let name: String
    let ports: String
    let reach: ServiceReach
    let detail: String
    var routes: [RouteLine] = []
    var note: String = ""
    /// Runs on (nearly) every server or only serves the server itself:
    /// SSH, Tailscale, fail2ban, the Docker engine, Caddy itself, and local
    /// programs no website uses. Hidden unless asked for.
    var isRoutine = false
    /// Websites: the address to open ("https://chat.example.com"); "" when
    /// it has no name of its own ("Any name", a TCP port).
    var url: String = ""
    /// Websites: what serves it ("Caddy", "nginx", "Tailscale operator …").
    var via: String = ""
    /// A website in the server's own Caddyfile (Remove broken websites).
    var removableFromCaddy = false
    /// Tailscale operator sites: the tailnet machine that answers for it.
    var tailnetMachine: String = ""
    /// Apps that aren't fully up ("0 of 1 ready").
    var problem: String = ""

    /// Sort keys.
    var kindRank: Int { kind.order }
    var reachRank: Int { reach.rawValue }
    var portSort: Int { Int(ports.prefix { $0.isNumber }) ?? Int.max }

    /// The website itself is down: its main page goes to a port nothing
    /// listens on (or, with no main page, every path does). A site whose
    /// main page works is never broken, even when one path (say /mcp)
    /// points at an empty port; the detail panel still lists that path.
    var hasMissingBackend: Bool {
        func dead(_ r: RouteLine) -> Bool { r.text.contains(InventoryBuilder.nothingListening) }
        guard routes.contains(where: dead) else { return false }
        let main = routes.filter { $0.path.isEmpty || $0.path == "/" || $0.path == "/*" }
        return main.isEmpty ? routes.allSatisfy(dead) : main.allSatisfy(dead)
    }

    /// Who can open it, in plain words. For websites the whole point is
    /// whether the outside can reach them.
    var reachLabel: String {
        switch (kind, reach) {
        case (.website, .allNetworks), (.website, .publicAddress), (.tailscaleSite, .publicAddress):
            return "Public"
        default:
            return reach.label
        }
    }
}

enum InventoryBuilder {

    /// OS plumbing that every server runs; hidden unless it listens beyond
    /// the server itself.
    private static let plumbingPrefixes = [
        "systemd-", "getty@", "serial-getty@", "user@", "hc-net-ifup@", "dbus", "polkit",
        "rsyslog", "cron", "atd", "udisks2", "unattended-upgrades", "multipathd",
        "qemu-guest-agent", "ModemManager", "snapd", "irqbalance", "networkd-dispatcher",
        "packagekit", "chrony", "lvm2-", "iscsid", "accounts-daemon", "upower", "thermald",
        "wpa_supplicant", "NetworkManager", "avahi-daemon", "cups", "bluetooth", "rtkit-daemon",
        "cloud-", "lxcfs", "fwupd", "apport", "acpid", "uuidd", "containerd", "open-vm-tools",
        "vgauth", "setvtrgb", "console-setup", "keyboard-setup", "plymouth", "kerneloops",
    ]

    /// Kubernetes' own machinery (and the Tailscale operator's proxies,
    /// which show as Tailscale sites instead).
    private static let kubeSystemNamespaces: Set<String> = [
        "kube-system", "kube-public", "kube-node-lease", "cert-manager", "tailscale",
        "metallb-system", "calico-system", "tigera-operator", "longhorn-system",
    ]

    static let nothingListening = "nothing is listening there"

    /// Tools every server runs; Caddy's own row adds nothing its websites
    /// don't already show.
    static let standardTools: Set<String> = [
        "ssh.service", "sshd.service", "tailscaled.service", "fail2ban.service",
        "docker.service", "caddy.service",
    ]

    static func isPlumbing(_ unit: String) -> Bool {
        plumbingPrefixes.contains { unit.hasPrefix($0) }
    }

    /// Listeners that belong to something shown elsewhere: Docker's port
    /// forwarders (also rootless Docker's and Podman's: the container rows)
    /// and Tailscale (the Tailscale sites).
    private static func isForwarder(_ l: Listener) -> Bool {
        ["docker-proxy", "tailscaled", "rootlesskit", "rootlessport"].contains(l.process)
    }

    private static let wildcards: Set<String> = ["", "*", "0.0.0.0", "::"]

    /// The tailnet's DNS suffix ("example.ts.net") from a machine's
    /// MagicDNS name ("server.example.ts.net").
    static func tailnetDomain(fromMachineName name: String) -> String {
        let parts = name.split(separator: ".")
        return parts.count > 1 ? parts.dropFirst().joined(separator: ".") : ""
    }

    /// `machinesByIP`: tailnet address → machine name, to name upstreams
    /// that live on another server. `tailnetDomain`: completes the names of
    /// Tailscale operator proxies ("argocd" → "argocd.example.ts.net").
    static func rows(for scan: ServerScan, machinesByIP: [String: String] = [:],
                     tailnetDomain: String = "") -> [InventoryRow] {
        var rows: [InventoryRow] = []
        let server = scan.serverName
        func rowID(_ kind: InventoryRow.Kind, _ name: String) -> String { "\(scan.deviceID)|\(kind.rawValue)|\(name)" }

        let containerByID = Dictionary(scan.containers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let containerSites = scan.otherSites.filter { !$0.container.isEmpty }
        // Addresses that are this server: what programs and containers bind
        // to, plus its own Tailscale addresses.
        var hostAddresses = Set(scan.listeners.map { normalizedAddress($0.address) })
        hostAddresses.formUnion(scan.containers.flatMap { $0.ports.map { normalizedAddress($0.hostAddress) } })
        hostAddresses.formUnion(machinesByIP.filter { $0.value == server }.keys)
        hostAddresses.formUnion(scan.addresses)
        hostAddresses.subtract(wildcards)

        // MARK: PM2 apps and the ports they listen on
        // PM2's cluster mode listens in its own daemon ("PM2 v6: God");
        // that port belongs to the cluster app when there's only one.
        // Apps that listen in their own process (fork mode).
        let forkApps = Set(scan.pm2Apps.filter { app in
            scan.listeners.contains { app.pids.contains($0.pid) || !Set(app.pids).isDisjoint(with: $0.ancestors) }
        })
        func pm2App(of l: Listener) -> PM2App? {
            if let app = scan.pm2Apps.first(where: { $0.pids.contains(l.pid) || !Set($0.pids).isDisjoint(with: l.ancestors) }) {
                return app
            }
            guard l.process.hasPrefix("PM2") else { return nil }
            // Cluster mode: the daemon holds the port for the one app it
            // started that doesn't listen itself.
            let mine = scan.pm2Apps.filter { $0.parents.contains(l.pid) && !forkApps.contains($0) }
            if mine.count == 1 { return mine.first }
            if mine.isEmpty, scan.pm2Apps.allSatisfy({ $0.parents.isEmpty }) {
                // Scans from before parents were read: one multi-copy app.
                let clusters = scan.pm2Apps.filter { $0.pids.count > 1 }
                if clusters.count == 1 { return clusters.first }
            }
            return nil
        }

        func containerName(_ c: ContainerInfo) -> String { c.swarmService.isEmpty ? c.name : c.swarmService }

        /// A container's port published on this address (nil = reached as localhost).
        func published(port: Int, address: String?) -> (container: ContainerInfo, port: PublishedPort)? {
            for c in scan.containers {
                for p in c.ports where !p.containerPort.hasSuffix("/udp") && (portRange(p.hostPort)?.contains(port) ?? false) {
                    let bound = normalizedAddress(p.hostAddress)
                    if let address {
                        if bound == address || wildcards.contains(bound) || (isLoopback(address) && acceptsLoopback(bound)) {
                            return (c, p)
                        }
                    } else if acceptsLoopback(bound) {
                        return (c, p)
                    }
                }
            }
            return nil
        }

        func containerNamed(_ host: String, near context: ContainerInfo?) -> ContainerInfo? {
            if let context, let c = scan.containers.first(where: {
                $0.owner == context.owner && $0.composeProject == context.composeProject
                    && !context.composeProject.isEmpty && $0.composeService == host
            }) { return c }
            return scan.containers.first { $0.name == host || $0.swarmService == host }
                ?? scan.containers.first { $0.composeService == host && !host.isEmpty }
        }

        // MARK: where a port on this server leads
        /// `host`: the website name asked for, so a Caddy in a container
        /// is followed to that site rather than its catch-all.
        func onHost(port: Int, address: String?, depth: Int, host: String) -> String {
            if let hit = published(port: port, address: address) {
                return "container \(containerName(hit.container))" + hop(hit.container, hit.port, depth: depth, host: host)
            }
            let onPort = scan.listeners.filter { $0.port == port }
            let here = onPort.filter { l in
                let bound = normalizedAddress(l.address)
                guard let address else { return acceptsLoopback(l.address) }
                return bound == address || wildcards.contains(bound) || (isLoopback(address) && acceptsLoopback(bound))
            }
            guard let l = here.first(where: { !isForwarder($0) }) ?? here.first else {
                // Kubernetes NodePorts are open on every address without a listener.
                if depth < 2, let kube = scan.kube,
                   let svc = kube.services.first(where: { $0.ports.contains { $0.nodePort == port } }) {
                    let p = svc.ports.first { $0.nodePort == port }.map { String($0.port) } ?? ""
                    return "Kubernetes NodePort → " + kubeBackend(svc.namespace, svc.name, p, depth: depth + 1, host: host)
                }
                guard scan.portsListed else { return "unknown" }
                if let other = onPort.first {
                    return "\(nothingListening) (only on \(other.address))"
                }
                return nothingListening
            }
            if let c = containerByID[l.containerID] { return "container \(c.name)" }
            if l.process == "tailscaled" { return "Tailscale" }
            if let app = pm2App(of: l) { return "PM2 app \(app.name)" }
            if l.process.hasPrefix("PM2") { return "an app run by PM2" + (l.folder.isEmpty ? "" : " in \(l.folder)") }
            if !l.unit.isEmpty, l.unit.hasSuffix(".service") { return l.unit.replacingOccurrences(of: ".service", with: "") }
            return l.displayName + (l.folder.isEmpty ? "" : " in \(l.folder)")
        }

        /// One step further when the container is a Caddy we read:
        /// "container edge → container web".
        func hop(_ c: ContainerInfo, _ p: PublishedPort, depth: Int, host: String) -> String {
            guard depth == 0 else { return "" }
            let inner = String(p.containerPort.split(separator: "/").first ?? "")
            let sites = containerSites.filter { $0.container == c.name && $0.ports.contains(inner) }
            guard let site = sites.first(where: { !host.isEmpty && $0.address.lowercased() == host.lowercased() })
                    ?? sites.first(where: { $0.address == "*" }) ?? sites.first,
                  let main = site.routes.first(where: { $0.path.isEmpty || $0.path == "/" || $0.path == "/*" }) ?? site.routes.first
            else { return "" }
            return " → " + describe(main, context: c, depth: depth + 1, short: true, host: host)
        }

        // MARK: Kubernetes services
        func kubeBackend(_ ns: String, _ name: String, _ port: String, depth: Int, host: String) -> String {
            let label = "Kubernetes service \(ns)/\(name)"
            guard let kube = scan.kube else { return label }
            guard let svc = kube.service(ns, name) else { return "\(label) — \(nothingListening)" }
            let slices = kube.endpoints.first { $0.namespace == ns && $0.service == name }
            let all = slices?.endpoints ?? []
            if svc.hasSelector {
                let apps = Array(Set(all.compactMap { kube.workload(ofPod: $0.pod, namespace: ns)?.name })).sorted()
                let shown = apps.isEmpty ? label : "Kubernetes app \(ns)/\(apps.joined(separator: ", "))"
                return all.contains(where: \.ready) ? shown : "\(shown) — \(nothingListening)"
            }
            // No selector: addresses set by hand, often this server itself.
            guard let ep = all.first(where: \.ready) ?? all.first else { return "\(label) — \(nothingListening)" }
            let p = slices?.ports.first ?? Int(port) ?? 0
            let a = normalizedAddress(ep.address)
            if hostAddresses.contains(a) { return "port \(p) — \(onHost(port: p, address: a, depth: depth, host: host))" }
            if let machine = machinesByIP[a] { return "\(machine) port \(p)" }
            return "\(a):\(p)"
        }

        func upstream(_ raw: String, context: ContainerInfo?, depth: Int, host siteHost: String) -> String {
            if let k = KubeTarget.parse(raw) { return kubeBackend(k.namespace, k.service, k.port, depth: depth, host: siteHost) }
            let (host, port, text) = InventoryBuilder.hostPort(of: raw)
            let portText = port.isEmpty ? "" : " port \(port)"
            if let context {
                // Inside a container, localhost is the container itself.
                if isLoopback(host) { return "container \(context.name)\(portText)" }
                if let c = containerNamed(host, near: context) { return "container \(containerName(c))\(portText)" }
            } else {
                if isLoopback(host), let p = Int(port) {
                    return "port \(p) — \(onHost(port: p, address: nil, depth: depth, host: siteHost))"
                }
                if let c = containerNamed(host, near: nil) { return "container \(containerName(c))\(portText)" }
            }
            let a = normalizedAddress(host)
            if hostAddresses.contains(a), let p = Int(port) {
                return "port \(p) — \(onHost(port: p, address: a, depth: depth, host: siteHost))"
            }
            if let machine = machinesByIP[host] { return "\(machine)\(portText)" }
            if ServiceReach.of(address: host) == .privateNetwork {
                return "private address \(text)"
            }
            return (port == "443" || port == "80" || port.isEmpty) ? host : "\(host):\(port)"
        }

        func describe(_ route: WebRoute, context: ContainerInfo? = nil, depth: Int = 0, short: Bool = false,
                      host: String = "") -> String {
            switch route.kind {
            case .proxy: return upstream(route.target, context: context, depth: depth, host: host)
            case .redirect:
                // Caddy placeholders ("{http.request.uri}") make URL() fail, so cut by hand.
                if short, let scheme = route.target.range(of: "://") {
                    let rest = route.target[scheme.upperBound...]
                    let host = rest.prefix { !"/?{:$".contains($0) }
                    if !host.isEmpty { return "redirects to \(host)" }
                }
                return "redirects to \(route.target)"
            case .respond: return "replies \(route.target)"
            case .files: return "files in \(route.target)"
            }
        }

        // MARK: websites
        // The server's Caddy may itself run in a container that publishes
        // its admin port (rootless Docker): say so.
        let hostCaddy: String = {
            guard !scan.caddyOnHost,
                  let c = scan.containers.first(where: { $0.ports.contains { $0.containerPort == "2019/tcp" } })
            else { return "Caddy" }
            return "Caddy in container \(c.name)"
        }()
        func siteRow(_ original: WebSite, kind: InventoryRow.Kind) -> InventoryRow? {
            var site = original
            let context = site.container.isEmpty ? nil : scan.containers.first { $0.name == site.container }
            // Caddy in a container: only what's published on the server
            // counts as a website of the server (the rest is internal).
            if let context {
                var hostPorts: [String] = []
                var reach = ServiceReach.none
                for p in context.ports where !p.containerPort.hasSuffix("/udp")
                    && site.ports.contains(String(p.containerPort.split(separator: "/").first ?? "")) {
                    if !hostPorts.contains(p.hostPort) { hostPorts.append(p.hostPort) }
                    reach = max(reach, p.reach)
                }
                guard !hostPorts.isEmpty else { return nil }
                if site.scheme.isEmpty { site.scheme = site.ports.contains("443") ? "https" : "http" }
                site = WebSite(address: site.address, ports: hostPorts, reach: reach, routes: site.routes,
                               note: site.note, via: site.via, container: site.container, scheme: site.scheme)
            }
            if site.onTailnet, !site.address.contains("."), !tailnetDomain.isEmpty {
                site = WebSite(address: "\(site.address).\(tailnetDomain)", ports: site.ports, reach: site.reach,
                               routes: site.routes, note: site.note, via: site.via, container: site.container,
                               scheme: site.scheme, tailnetMachine: site.tailnetMachine, onTailnet: true)
            }
            var goesTo: [String] = []
            for route in site.routes {
                let d = describe(route, context: context, short: true, host: site.address)
                if !goesTo.contains(d) { goesTo.append(d) }
            }
            // Local backends first: they're what this server actually runs.
            goesTo.sort { ($0.hasPrefix("port ") ? 0 : 1) < ($1.hasPrefix("port ") ? 0 : 1) }
            let shown = goesTo.prefix(3).joined(separator: "; ")
            let more = goesTo.count > 3 ? " +\(goesTo.count - 3) more" : ""
            var name = site.address == "*" ? "Any name" : site.address
            if site.address == "*", !site.container.isEmpty { name += " · \(site.container)" }
            // Same name on several ports (e.g. :443 and :8443) must stay apart.
            if !site.ports.isEmpty, !site.ports.contains("443"), site.ports != ["80"],
               !name.contains(":"), !name.hasPrefix("TCP port"), !site.onTailnet, site.address != "*" {
                name += ":" + site.ports.joined(separator: ",")
            }
            var row = InventoryRow(
                id: rowID(kind, "\(name)|\(site.ports.joined(separator: ","))|\(site.via)"),
                serverID: scan.deviceID, server: server, kind: kind, name: name,
                ports: site.ports.joined(separator: ", "), reach: site.reach,
                detail: goesTo.isEmpty ? "" : "→ \(shown)\(more)",
                routes: site.routes.map { InventoryRow.RouteLine(path: $0.path, text: describe($0, context: context, host: site.address)) },
                note: site.note)
            // Only what can be opened from a machine on the tailnet gets a link.
            row.url = site.reach >= .tailscale ? url(for: site) : ""
            row.via = site.via.isEmpty ? (kind == .tailscaleSite ? "Tailscale serve" : hostCaddy) : site.via
            row.removableFromCaddy = kind == .website && site.via.isEmpty && scan.caddyOnHost
            row.tailnetMachine = site.tailnetMachine
            return row
        }
        var websitePorts = Set<Int>()
        for route in (scan.websites + scan.tailscaleSites + scan.otherSites).flatMap(\.routes) where route.kind == .proxy {
            if let port = InventoryBuilder.localPort(of: route.target) { websitePorts.insert(port) }
        }
        rows += scan.websites.compactMap { siteRow($0, kind: .website) }
        rows += scan.tailscaleSites.compactMap { siteRow($0, kind: .tailscaleSite) }
        rows += scan.otherSites.compactMap { siteRow($0, kind: $0.onTailnet ? .tailscaleSite : .website) }

        // MARK: containers (Swarm copies grouped)
        var groups: [String: [ContainerInfo]] = [:]
        var groupOrder: [String] = []
        for c in scan.containers {
            let key = (c.owner.isEmpty ? "" : "\(c.owner)/") + (c.swarmService.isEmpty ? c.name : c.swarmService)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(c)
        }
        for key in groupOrder {
            let members = groups[key] ?? []
            guard let first = members.first else { continue }
            let ids = Set(members.map(\.id))
            var ports: [String] = []
            var reach = ServiceReach.none
            for p in members.flatMap(\.ports) {
                if !ports.contains(p.hostPort) { ports.append(p.hostPort) }
                reach = max(reach, p.reach)
            }
            // Containers on the host network listen directly.
            for l in scan.listeners where ids.contains(l.containerID) && !isForwarder(l) {
                if !ports.contains("\(l.port)") { ports.append("\(l.port)") }
                reach = max(reach, l.reach)
            }
            var detail = first.image
            if members.count > 1 { detail += " · \(members.count) copies" }
            detail += " · \(first.status)"
            if !first.composeProject.isEmpty { detail += " · project \(first.composeProject)" }
            if !first.ownerText.isEmpty { detail += " · \(first.ownerText)" }
            rows.append(InventoryRow(id: rowID(.container, key), serverID: scan.deviceID, server: server,
                                     kind: .container, name: containerName(first), ports: ports.joined(separator: ", "),
                                     reach: reach, detail: detail))
        }

        // MARK: Kubernetes apps
        if let kube = scan.kube {
            for w in kube.workloads {
                var reach = ServiceReach.none
                var ports: [String] = []
                // Services that send to this app and open it beyond the cluster.
                for svc in kube.services where svc.namespace == w.namespace {
                    let pods = kube.endpoints.first { $0.namespace == svc.namespace && $0.service == svc.name }?.endpoints ?? []
                    guard pods.contains(where: { kube.workload(ofPod: $0.pod, namespace: w.namespace)?.name == w.name }) else { continue }
                    if svc.isTailscale {
                        reach = max(reach, .tailscale)
                    } else if svc.type == "NodePort" || svc.type == "LoadBalancer" {
                        reach = max(reach, .allNetworks)
                        for p in svc.ports { if let n = p.nodePort, !ports.contains("\(n)") { ports.append("\(n)") } }
                    }
                }
                var bits = ["\(w.kind) · \(w.ready) of \(w.desired) ready"]
                if !w.images.isEmpty { bits.append(w.images.joined(separator: ", ")) }
                var row = InventoryRow(id: rowID(.kubernetes, "\(w.kind)/\(w.namespace)/\(w.name)"),
                                       serverID: scan.deviceID, server: server, kind: .kubernetes,
                                       name: "\(w.namespace)/\(w.name)", ports: ports.joined(separator: ", "),
                                       reach: reach, detail: bits.joined(separator: " · "))
                if w.desired > 0, w.ready < w.desired { row.problem = "\(w.ready) of \(w.desired) ready" }
                row.isRoutine = kubeSystemNamespaces.contains(w.namespace) && row.problem.isEmpty
                rows.append(row)
            }
        }

        // MARK: PM2 apps (with the ports they listen on)
        var candidates = scan.listeners.filter { !isForwarder($0) && $0.containerID.isEmpty }
        var used = Set<String>()
        func key(_ l: Listener) -> String { "\(l.address)|\(l.port)" }
        for app in scan.pm2Apps {
            let mine = candidates.filter { pm2App(of: $0) == app }
            mine.forEach { used.insert(key($0)) }
            let ports = Array(Set(mine.map(\.port))).sorted().map(String.init)
            var bits: [String] = []
            if app.pids.count > 1 { bits.append("\(app.pids.count) copies") }
            bits.append("run by \(app.user)")
            if !app.folder.isEmpty { bits.append("in \(app.folder)") }
            rows.append(InventoryRow(id: rowID(.pm2, "\(app.user)/\(app.name)"), serverID: scan.deviceID, server: server,
                                     kind: .pm2, name: app.name, ports: ports.joined(separator: ", "),
                                     reach: mine.map(\.reach).max() ?? .none, detail: bits.joined(separator: " · ")))
        }
        candidates.removeAll { used.contains(key($0)) }

        // MARK: services (with the ports they listen on)
        let running = Set(scan.services.map(\.unit))

        var serviceRows: [(unit: String, description: String, listeners: [Listener])] = []
        for svc in scan.services {
            let mine = candidates.filter { $0.unit == svc.unit }
            serviceRows.append((svc.unit, svc.description, mine))
        }
        // Socket-activated services (systemd listens on their behalf).
        for socket in scan.sockets {
            // systemd (PID 1) listens for the socket: same port AND address.
            let mine = candidates.filter { l in
                let a = normalizedAddress(l.address)
                return l.port == socket.port && l.pid == 1
                    && (a == socket.address || (wildcards.contains(a) && wildcards.contains(socket.address)))
            }
            if let i = serviceRows.firstIndex(where: { $0.unit == socket.activates }) {
                serviceRows[i].listeners += mine
            } else if !running.contains(socket.activates) {
                serviceRows.append((socket.activates, "starts on demand (\(socket.unit))", mine))
            }
        }
        for svc in serviceRows {
            svc.listeners.forEach { used.insert(key($0)) }
            let reach = svc.listeners.map(\.reach).max() ?? .none
            if isPlumbing(svc.unit) && reach <= .local { continue }
            let ports = Array(Set(svc.listeners.map(\.port))).sorted().map(String.init)
            let name = svc.unit.hasSuffix(".service") ? String(svc.unit.dropLast(".service".count)) : svc.unit
            var row = InventoryRow(id: rowID(.service, svc.unit), serverID: scan.deviceID, server: server,
                                   kind: .service, name: name, ports: ports.joined(separator: ", "),
                                   reach: reach, detail: svc.description)
            // SSH or Docker's swarm ports open on every network are worth seeing.
            row.isRoutine = standardTools.contains(svc.unit) && reach <= .tailscale
            rows.append(row)
        }

        // MARK: everything else that listens
        var programGroups: [String: [Listener]] = [:]
        var programOrder: [String] = []
        for l in candidates where !used.contains(key(l)) {
            // Plumbing units that weren't shown above (e.g. the local DNS stub).
            if !l.unit.isEmpty, running.contains(l.unit) { continue }
            let k = "\(l.displayName)|\(l.folder)|\(l.reach.rawValue)"
            if programGroups[k] == nil { programOrder.append(k) }
            programGroups[k, default: []].append(l)
        }
        for k in programOrder {
            let ls = programGroups[k] ?? []
            guard let first = ls.first else { continue }
            let name = first.displayName
            var bits: [String] = []
            if first.inLoginSession {
                bits.append("started from a login session")
            } else if !first.unit.isEmpty {
                bits.append("runs under \(first.unit)")
            }
            if !first.folder.isEmpty { bits.append("in \(first.folder)") }
            let ports = Array(Set(ls.map(\.port))).sorted()
            let portText = ports.count > 6
                ? ports.prefix(5).map(String.init).joined(separator: ", ") + " +\(ports.count - 5) more"
                : ports.map(String.init).joined(separator: ", ")
            var row = InventoryRow(id: rowID(.program, k), serverID: scan.deviceID, server: server,
                                   kind: .program, name: name, ports: portText,
                                   reach: first.reach, detail: bits.joined(separator: " · "))
            // Local-only and no website sends traffic to it.
            row.isRoutine = first.reach == .local && websitePorts.isDisjoint(with: ports)
            rows.append(row)
        }

        return rows.sorted {
            ($0.kind.order, $0.name.localizedLowercase) < ($1.kind.order, $1.name.localizedLowercase)
        }
    }

    /// The address to open a website at ("" when it has no name of its own).
    static func url(for site: WebSite) -> String {
        let address = site.address
        guard !address.isEmpty, address != "*", !address.hasPrefix("*."), !address.hasPrefix("TCP port"),
              !address.contains(" "), !address.contains("{"), address.contains(".") || address.contains(":")
        else { return "" }
        let scheme = !site.scheme.isEmpty ? site.scheme
            : (site.ports == ["80"] ? "http" : "https")
        // Tailscale serve names already carry their port ("host:8443").
        if address.contains(":"), !address.contains("::") { return "\(scheme)://\(address)" }
        let standard = scheme == "https" ? "443" : "80"
        let port = site.ports.isEmpty || site.ports.contains(standard) ? "" : ":\(site.ports[0])"
        return "\(scheme)://\(address)\(port)"
    }

    /// "localhost:8200" / "http://127.0.0.1:8081" → 8200 / 8081.
    static func localPort(of target: String) -> Int? {
        guard KubeTarget.parse(target) == nil else { return nil }
        let (host, port, _) = hostPort(of: target)
        return isLoopback(host) ? Int(port) : nil
    }

    /// Any "scheme://host:port/path" (http, https, https+insecure, h2c…) →
    /// host and port, the port defaulting from the scheme.
    static func hostPort(of target: String) -> (host: String, port: String, text: String) {
        var text = target
        var defaultPort = ""
        if let r = text.range(of: "://") {
            let scheme = text[..<r.lowerBound].lowercased()
            defaultPort = scheme.hasPrefix("https") ? "443" : (scheme.hasPrefix("http") || scheme == "h2c" ? "80" : "")
            text = String(text[r.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        var (host, port) = text.contains(":") ? splitHostPort(text) : (text, "")
        if port.isEmpty { port = defaultPort }
        return (host, port, text)
    }

    /// Where a proxy on the server itself connects to ("localhost", "127.0.0.1", "[::1]").
    static func isLoopback(_ host: String) -> Bool {
        let h = normalizedAddress(host).lowercased()
        return h == "localhost" || h == "::1" || h == "0.0.0.0" || h.isEmpty || h.hasPrefix("127.")
    }

    /// Can a connection to localhost reach something bound to this address?
    static func acceptsLoopback(_ address: String) -> Bool {
        let a = normalizedAddress(address).lowercased()
        return ["127.0.0.1", "::1", "0.0.0.0", "::", "*", "", "localhost"].contains(a)
    }

    /// Plain-language caveats about how complete a server's scan is.
    static func notes(for scan: ServerScan) -> [String] {
        var notes: [String] = []
        if !scan.ranAsRoot {
            notes.append("Signed in without admin rights (no passwordless sudo), so programs run by other users, other users' Docker and Kubernetes may be missing.")
        }
        if !scan.portsListed { notes.append("Couldn't list open ports: the 'ss' tool isn't installed.") }
        let rootless = scan.containers.contains { !$0.owner.isEmpty }
        if scan.dockerError.contains("docker.sock: connect: no such file") || scan.dockerError.contains("Is the docker daemon running") {
            // Only users' own (rootless) Docker runs: nothing to report.
            if !rootless { notes.append("Docker is installed but not running.") }
        } else if !scan.dockerError.isEmpty {
            notes.append("Docker is installed but couldn't be read: \(scan.dockerError)")
        }
        if scan.caddyFound && scan.websites.isEmpty {
            notes.append("Caddy is installed, but its live config couldn't be read.")
        }
        if let error = scan.kube?.error, !error.isEmpty { notes.append(error) }
        if scan.tunnelRunning && !scan.otherSites.contains(where: { $0.via == "Cloudflare Tunnel" }) {
            notes.append("cloudflared runs a tunnel managed in Cloudflare's dashboard; its host names are only listed there.")
        }
        return notes
    }

    static func csv(_ rows: [InventoryRow], scannedAt: [String: Date]) -> String {
        func field(_ raw: String) -> String {
            // Names come from the servers; never let a spreadsheet run one as a formula.
            let s = raw.first.map { "=+-@\t\r".contains($0) } == true ? "'" + raw : raw
            return s.contains(where: { ",\"\n\r".contains($0) })
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        let date = ISO8601DateFormatter()
        var lines = ["Server,Type,Name,Ports,Reach,Details,URL,Served by,Scanned"]
        for r in rows {
            let detail = r.routes.isEmpty
                ? r.detail
                : r.routes.map { ($0.path.isEmpty ? "" : "\($0.path) ") + "→ \($0.text)" }.joined(separator: "; ")
            lines.append([r.server, r.kind.rawValue, r.name, r.ports, r.reachLabel, detail, r.url, r.via,
                          scannedAt[r.serverID].map { date.string(from: $0) } ?? ""]
                .map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
