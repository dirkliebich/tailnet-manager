import Foundation

// MARK: - Kubernetes, as the scan reads it

/// What a server's Kubernetes cluster runs and serves: only names, images,
/// ready counts and where traffic goes. Pod specs (commands, environments),
/// secrets and config maps are never read.
struct KubeInventory: Codable, Hashable {
    var ingresses: [KubeIngress] = []
    var services: [KubeService] = []
    var endpoints: [KubeEndpoints] = []
    var workloads: [KubeWorkload] = []
    var routes: [KubeRoute] = []
    /// Why it couldn't be read ("" = it could).
    var error = ""

    func service(_ namespace: String, _ name: String) -> KubeService? {
        services.first { $0.namespace == namespace && $0.name == name }
    }

    /// The Deployment / StatefulSet / DaemonSet a pod belongs to: the
    /// longest workload name the pod's name starts with.
    func workload(ofPod pod: String, namespace: String) -> KubeWorkload? {
        workloads.filter { $0.namespace == namespace && pod.hasPrefix($0.name + "-") }
            .max { $0.name.count < $1.name.count }
    }

    /// How far the ingress controller (Traefik, ingress-nginx, …) reaches:
    /// a NodePort or LoadBalancer service listens on every address of the
    /// node; one exposed only through Tailscale is on the tailnet.
    func controllerReach(_ className: String) -> ServiceReach {
        let key = className.isEmpty ? "traefik" : className.lowercased()
        let candidates = services.filter { $0.name.lowercased().contains(key) }
        if candidates.contains(where: { $0.type == "NodePort" || ($0.type == "LoadBalancer" && !$0.isTailscale) }) {
            return .allNetworks
        }
        if candidates.contains(where: \.isTailscale) { return .tailscale }
        return candidates.isEmpty ? .allNetworks : .privateNetwork
    }
}

struct KubeIngress: Codable, Hashable {
    let namespace: String
    let name: String
    let className: String
    /// Addresses the controller gave it (the Tailscale operator: its
    /// "name.tailnet.ts.net").
    let addresses: [String]
    let tlsHosts: [String]
    /// "service:port", "" when none.
    let defaultBackend: String
    let rules: [KubeRule]
    let funnel: Bool

    var isTailscale: Bool { className == "tailscale" }
}

struct KubeRule: Codable, Hashable {
    /// "" = any name.
    let host: String
    let paths: [KubePath]
}

struct KubePath: Codable, Hashable {
    let path: String
    /// "service:port".
    let backend: String
}

struct KubeService: Codable, Hashable {
    let namespace: String
    let name: String
    let type: String
    let loadBalancerClass: String
    let tailscaleExpose: Bool
    let tailscaleHostname: String
    let addresses: [String]
    let externalIPs: [String]
    let ports: [KubePort]
    let hasSelector: Bool

    /// Put on the tailnet by the Tailscale operator.
    var isTailscale: Bool { loadBalancerClass == "tailscale" || tailscaleExpose }
}

struct KubePort: Codable, Hashable {
    let port: Int
    /// Number or name.
    let target: String
    let nodePort: Int?
    let proto: String
}

struct KubeEndpoints: Codable, Hashable {
    let namespace: String
    let service: String
    let endpoints: [KubeEndpoint]
    let ports: [Int]
}

struct KubeEndpoint: Codable, Hashable {
    let address: String
    /// The pod behind it ("" for an address set by hand).
    let pod: String
    let ready: Bool
}

struct KubeWorkload: Codable, Hashable {
    /// Deployment, StatefulSet or DaemonSet.
    let kind: String
    let namespace: String
    let name: String
    let ready: Int
    let desired: Int
    let images: [String]
}

/// A Traefik IngressRoute.
struct KubeRoute: Codable, Hashable {
    struct Rule: Codable, Hashable {
        /// Traefik's rule, e.g. "Host(`a.com`) && PathPrefix(`/api`)".
        let match: String
        /// "service:port".
        let services: [String]
    }
    let namespace: String
    let name: String
    let entryPoints: [String]
    let tls: Bool
    let rules: [Rule]
}

// MARK: - Parsing the new sections

extension ServiceScanParser {

    /// kubectl's go-templates print "<no value>" for missing fields.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<no value>", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func list(_ s: String, _ separator: Character = ",") -> [String] {
        clean(s).split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: PM2

    /// "user|name-id|pid|parent|folder" → one app per user and name (its copies together).
    static func pm2Apps(_ lines: [String]) -> [PM2App] {
        var order: [String] = []
        var apps: [String: (user: String, name: String, pids: [Int], folder: String, parents: [Int])] = [:]
        for line in lines {
            let f = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let pid = Int(f[2]) else { continue }
            // PM2 names pid files "<name>-<id>.pid".
            var name = f[1]
            if let dash = name.lastIndex(of: "-"), name[name.index(after: dash)...].allSatisfy(\.isNumber),
               name.index(after: dash) < name.endIndex {
                name = String(name[..<dash])
            }
            let key = "\(f[0])|\(name)"
            if apps[key] == nil {
                order.append(key)
                apps[key] = (f[0], name, [], "", [])
            }
            apps[key]!.pids.append(pid)
            if f.count == 5 {
                if let parent = Int(f[3]), !apps[key]!.parents.contains(parent) { apps[key]!.parents.append(parent) }
                if apps[key]!.folder.isEmpty { apps[key]!.folder = f[4] }
            }
        }
        return order.compactMap { apps[$0] }.map {
            PM2App(user: $0.user, name: $0.name, pids: $0.pids.sorted(), folder: $0.folder, parents: $0.parents)
        }
    }

    // MARK: Caddy inside containers

    /// "owner|container|{json}" → the container's websites, on the
    /// container's own ports (mapped to the server's ports when shown).
    static func containerCaddySites(_ lines: [String], containers: [ContainerInfo]) -> [WebSite] {
        lines.flatMap { line -> [WebSite] in
            let f = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let json = jsonObject(f[2]) else { return [] }
            return caddySites(json).map { site in
                var s = site
                s.container = f[1]
                s.via = "Caddy in container \(f[1])"
                return s
            }
        }
    }

    // MARK: nginx

    /// `nginx -T`, cut down to braces and the lines that say where a site
    /// goes, → one website per server name.
    static func nginxSites(_ lines: [String]) -> [WebSite] {
        guard !lines.isEmpty else { return [] }
        let text = lines.joined(separator: "\n")

        struct Block { var name: String; var args: [String]; var statements: [[String]] = []; var children: [Block] = [] }
        var stack: [Block] = [Block(name: "main", args: [])]
        var current = ""
        func words(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        for ch in text {
            switch ch {
            case "{":
                let w = words(current)
                stack.append(Block(name: w.first ?? "", args: Array(w.dropFirst())))
                current = ""
            case "}":
                if stack.count > 1 {
                    let done = stack.removeLast()
                    stack[stack.count - 1].children.append(done)
                }
                current = ""
            case ";":
                let w = words(current)
                if !w.isEmpty { stack[stack.count - 1].statements.append(w) }
                current = ""
            default:
                current.append(ch)
            }
        }
        while stack.count > 1 {
            let done = stack.removeLast()
            stack[stack.count - 1].children.append(done)
        }

        func all(_ b: Block, named: String) -> [Block] {
            (b.name == named ? [b] : []) + b.children.flatMap { all($0, named: named) }
        }
        let root = stack[0]
        // upstream name → its first server.
        var upstreams: [String: String] = [:]
        for u in all(root, named: "upstream") {
            if let name = u.args.first, let server = u.statements.first(where: { $0.first == "server" }), server.count > 1 {
                upstreams[name] = server[1]
            }
        }
        func route(_ statement: [String], path: String) -> WebRoute? {
            guard let directive = statement.first, statement.count > 1 else { return nil }
            switch directive {
            case "proxy_pass", "uwsgi_pass", "fastcgi_pass", "grpc_pass":
                var target = statement[1]
                let (host, _, _) = InventoryBuilder.hostPort(of: target)
                if let up = upstreams[host] { target = up }
                return WebRoute(path: path, kind: .proxy, target: target)
            case "return":
                if statement.count > 2 { return WebRoute(path: path, kind: .redirect, target: statement[2]) }
                if statement[1].contains("://") { return WebRoute(path: path, kind: .redirect, target: statement[1]) }
                return WebRoute(path: path, kind: .respond, target: statement[1])
            case "root", "alias":
                return WebRoute(path: path, kind: .files, target: statement[1])
            default:
                return nil
            }
        }

        var sites: [WebSite] = []
        // `server` lines inside `upstream` have no braces, so every
        // `server` block is a virtual host.
        for server in all(root, named: "server") {
            var ports: [String] = []
            var reach = ServiceReach.none
            var tls = false
            for listen in server.statements where listen.first == "listen" && listen.count > 1 {
                let spec = listen[1]
                if spec.hasPrefix("unix:") { continue }
                let (host, port) = spec.contains(":") ? splitHostPort(spec) : ("", spec)
                guard Int(port) != nil else { continue }
                if !ports.contains(port) { ports.append(port) }
                reach = max(reach, ServiceReach.of(address: host))
                if listen.contains("ssl") || listen.contains("quic") { tls = true }
            }
            if ports.isEmpty { ports = ["80"]; reach = .allNetworks }
            var routes: [WebRoute] = []
            for location in server.children where location.name == "location" {
                let path = location.args.last ?? ""
                let shown = path == "/" ? "" : path
                routes += location.statements.compactMap { route($0, path: shown) }
            }
            let hasMain = routes.contains { $0.path.isEmpty }
            if !hasMain {
                // Server-level return / root apply where no location does.
                if let r = server.statements.lazy.compactMap({ route($0, path: "") }).first { routes.insert(r, at: 0) }
            }
            let names = server.statements.filter { $0.first == "server_name" }.flatMap { $0.dropFirst() }
            for name in names.isEmpty ? ["*"] : names {
                let host = name == "_" || name.isEmpty ? "*" : name
                var site = WebSite(address: host, ports: ports, reach: reach, routes: routes)
                site.via = "nginx"
                site.scheme = tls ? "https" : (ports.contains("443") ? "https" : "http")
                sites.append(site)
            }
        }
        return sites
    }

    // MARK: Cloudflare Tunnel

    /// "- hostname: a.com" / "service: http://localhost:8000" / "path: …"
    /// lines from cloudflared's config files.
    static func tunnelSites(_ lines: [String]) -> [WebSite] {
        var sites: [WebSite] = []
        var host = "", path = ""
        func value(_ line: String) -> String {
            guard let colon = line.firstIndex(of: ":") else { return "" }
            return line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        for raw in lines where raw != "running" {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -\t"))
            if line.hasPrefix("hostname:") {
                host = value(line); path = ""
            } else if line.hasPrefix("path:") {
                path = value(line)
            } else if line.hasPrefix("service:") {
                let service = value(line)
                defer { host = ""; path = "" }
                // The catch-all rule ("- service: http_status:404") has no host.
                guard !host.isEmpty else { continue }
                let route: WebRoute
                if service.hasPrefix("http_status:") {
                    route = WebRoute(path: path, kind: .respond, target: String(service.dropFirst("http_status:".count)))
                } else if service.contains("://") {
                    route = WebRoute(path: path, kind: .proxy, target: service)
                } else {
                    route = WebRoute(path: path, kind: .respond, target: service)
                }
                if let i = sites.firstIndex(where: { $0.address == host }) {
                    sites[i].routes.append(route)
                } else {
                    var site = WebSite(address: host, ports: ["443"], reach: .publicAddress, routes: [route])
                    site.via = "Cloudflare Tunnel"
                    site.scheme = "https"
                    site.note = "Served through a Cloudflare Tunnel: open to the internet unless Cloudflare Access protects it."
                    sites.append(site)
                }
            }
        }
        return sites
    }

    // MARK: Kubernetes

    static func kubeInventory(_ lines: [String]) -> KubeInventory {
        var k = KubeInventory()
        for line in lines {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let tag = f.first else { continue }
            switch tag {
            case "ERR":
                k.error = f.dropFirst().joined(separator: "|")
            case "ING" where f.count >= 9:
                let rules = list(f[7], "^").map { rule -> KubeRule in
                    let parts = rule.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    let paths = list(parts.count > 1 ? parts[1] : "", ";").compactMap { p -> KubePath? in
                        let bits = p.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                        guard bits.count == 2 else { return nil }
                        return KubePath(path: clean(bits[0]), backend: clean(bits[1]))
                    }
                    return KubeRule(host: clean(parts[0]), paths: paths)
                }
                k.ingresses.append(KubeIngress(
                    namespace: f[1], name: f[2], className: clean(f[3]), addresses: list(f[4]),
                    tlsHosts: list(f[5]), defaultBackend: clean(f[6]).hasSuffix(":") ? "" : clean(f[6]),
                    rules: rules, funnel: clean(f[8]) == "true"))
            case "SVC" where f.count >= 11:
                let ports = list(f[9]).compactMap { p -> KubePort? in
                    let b = p.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard b.count >= 4, let port = Int(b[0]) else { return nil }
                    return KubePort(port: port, target: b[1], nodePort: Int(b[2]), proto: b[3])
                }
                k.services.append(KubeService(
                    namespace: f[1], name: f[2], type: clean(f[3]), loadBalancerClass: clean(f[4]),
                    tailscaleExpose: clean(f[5]) == "true", tailscaleHostname: clean(f[6]),
                    addresses: list(f[7]), externalIPs: list(f[8]), ports: ports,
                    hasSelector: clean(f[10]) == "selector"))
            case "EPS" where f.count >= 5:
                let endpoints = list(f[3]).compactMap { e -> KubeEndpoint? in
                    let b = e.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
                    guard b.count == 3, !b[0].isEmpty else { return nil }
                    // No "ready" condition means ready (Kubernetes' own rule).
                    return KubeEndpoint(address: b[0], pod: clean(b[1]), ready: clean(b[2]) != "false")
                }
                let ports = list(f[4]).compactMap { Int($0) }
                let service = clean(f[2])
                guard !service.isEmpty else { continue }
                // A service can have several slices: merge them.
                if let i = k.endpoints.firstIndex(where: { $0.namespace == f[1] && $0.service == service }) {
                    let old = k.endpoints[i]
                    k.endpoints[i] = KubeEndpoints(namespace: old.namespace, service: old.service,
                                                   endpoints: old.endpoints + endpoints,
                                                   ports: old.ports.isEmpty ? ports : old.ports)
                } else {
                    k.endpoints.append(KubeEndpoints(namespace: f[1], service: service, endpoints: endpoints, ports: ports))
                }
            case "WL" where f.count >= 7:
                k.workloads.append(KubeWorkload(kind: f[1], namespace: f[2], name: f[3],
                                                ready: Int(clean(f[4])) ?? 0, desired: Int(clean(f[5])) ?? 0,
                                                images: list(f[6])))
            case "IR" where f.count >= 6:
                // The same route can come from both Traefik API groups.
                guard !k.routes.contains(where: { $0.namespace == f[1] && $0.name == f[2] }) else { continue }
                let rules = list(f[5], "^").map { r -> KubeRoute.Rule in
                    let bits = r.components(separatedBy: ">")
                    let services = bits.count > 1 ? list(bits.last ?? "") : []
                    let match = bits.count > 1 ? bits.dropLast().joined(separator: ">") : r
                    return KubeRoute.Rule(match: clean(match), services: services)
                }
                k.routes.append(KubeRoute(namespace: f[1], name: f[2], entryPoints: list(f[3]),
                                          tls: clean(f[4]) == "tls", rules: rules))
            default:
                continue
            }
        }
        return k
    }

    private static let hostRule = try! NSRegularExpression(pattern: #"Host(?:SNI)?\(([^)]*)\)"#)
    private static let pathRule = try! NSRegularExpression(pattern: #"Path(?:Prefix)?\(`([^`]*)`\)"#)
    private static let backticked = try! NSRegularExpression(pattern: #"`([^`]*)`"#)

    private static func matches(_ re: NSRegularExpression, in text: String, group: Int = 1) -> [String] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    /// Host names and paths in a Traefik rule.
    static func traefikRule(_ match: String) -> (hosts: [String], paths: [String]) {
        let hosts = matches(hostRule, in: match).flatMap { matches(backticked, in: $0) }
        return (hosts, matches(pathRule, in: match))
    }

    /// Websites the cluster serves: ingresses (the Tailscale operator's
    /// and any other controller's), Traefik routes, and services the
    /// Tailscale operator puts on the tailnet.
    static func kubeSites(_ k: KubeInventory) -> [WebSite] {
        var sites: [WebSite] = []
        func target(_ ns: String, _ backend: String) -> WebRoute {
            WebRoute(path: "", kind: .proxy, target: KubeTarget.make(namespace: ns, backend: backend))
        }
        func add(_ site: WebSite) {
            if let i = sites.firstIndex(where: { $0.address == site.address && $0.ports == site.ports && $0.via == site.via }) {
                for r in site.routes where !sites[i].routes.contains(r) { sites[i].routes.append(r) }
            } else {
                sites.append(site)
            }
        }

        for ing in k.ingresses {
            var routes: [WebRoute] = []
            for rule in ing.rules {
                for p in rule.paths {
                    let path = p.path == "/" ? "" : p.path
                    routes.append(WebRoute(path: path, kind: .proxy, target: KubeTarget.make(namespace: ing.namespace, backend: p.backend)))
                }
            }
            if !ing.defaultBackend.isEmpty, !routes.contains(where: { $0.path.isEmpty }) {
                routes.append(target(ing.namespace, ing.defaultBackend))
            }
            if ing.isTailscale {
                // The operator gives the proxy "name.tailnet.ts.net"; until
                // then only the requested name (the TLS host) is known.
                let fqdn = ing.addresses.first { $0.contains(".") } ?? ing.tlsHosts.first ?? ing.name
                var site = WebSite(address: fqdn, ports: ["443"], reach: ing.funnel ? .publicAddress : .tailscale,
                                   routes: routes)
                site.via = "Tailscale operator (ingress \(ing.namespace)/\(ing.name))"
                site.scheme = "https"
                site.tailnetMachine = String(fqdn.split(separator: ".").first ?? Substring(fqdn))
                site.onTailnet = true
                if ing.funnel { site.note = "Tailscale Funnel — open to the internet" }
                if ing.addresses.isEmpty { site.note = "The Tailscale operator hasn't given it an address yet." }
                add(site)
            } else {
                let reach = k.controllerReach(ing.className)
                let hosts = ing.rules.isEmpty ? ["*"] : ing.rules.map { $0.host.isEmpty ? "*" : $0.host }
                for host in Set(hosts).sorted() {
                    let rulesHere = ing.rules.filter { ($0.host.isEmpty ? "*" : $0.host) == host }
                    var r = rulesHere.flatMap(\.paths).map {
                        WebRoute(path: $0.path == "/" ? "" : $0.path, kind: .proxy,
                                 target: KubeTarget.make(namespace: ing.namespace, backend: $0.backend))
                    }
                    if r.isEmpty || (!ing.defaultBackend.isEmpty && !r.contains(where: { $0.path.isEmpty })) {
                        if !ing.defaultBackend.isEmpty { r.append(target(ing.namespace, ing.defaultBackend)) }
                    }
                    let tls = ing.tlsHosts.contains(host)
                    var site = WebSite(address: host, ports: [tls ? "443" : "80"], reach: reach, routes: r)
                    site.via = "Kubernetes ingress \(ing.namespace)/\(ing.name)"
                        + (ing.className.isEmpty ? "" : " (\(ing.className))")
                    site.scheme = tls ? "https" : "http"
                    add(site)
                }
            }
        }

        let traefikReach = k.controllerReach("traefik")
        for route in k.routes {
            let tls = route.tls || route.entryPoints.contains { $0.lowercased().contains("secure") || $0 == "https" }
            for rule in route.rules {
                let (hosts, paths) = traefikRule(rule.match)
                let backends: [WebRoute] = rule.services.flatMap { svc -> [WebRoute] in
                    let routePaths = paths.isEmpty ? [""] : paths.map { $0 == "/" ? "" : $0 }
                    return routePaths.map { path in
                        // "api@internal" and friends are Traefik's own handlers.
                        svc.contains("@")
                            ? WebRoute(path: path, kind: .respond, target: "Traefik's \(svc)")
                            : WebRoute(path: path, kind: .proxy, target: KubeTarget.make(namespace: route.namespace, backend: svc))
                    }
                }
                for host in hosts.isEmpty ? ["*"] : hosts {
                    var site = WebSite(address: host, ports: [tls ? "443" : "80"], reach: traefikReach, routes: backends)
                    site.via = "Traefik route \(route.namespace)/\(route.name)"
                    site.scheme = tls ? "https" : "http"
                    add(site)
                }
            }
        }

        for svc in k.services where svc.isTailscale {
            let name = svc.addresses.first { $0.contains(".") }
                ?? (svc.tailscaleHostname.isEmpty ? "\(svc.namespace)-\(svc.name)" : svc.tailscaleHostname)
            let ports = svc.ports.filter { $0.proto.uppercased() != "UDP" }.map { String($0.port) }
            let first = svc.ports.first.map { String($0.port) } ?? ""
            var site = WebSite(address: name, ports: ports.isEmpty ? ["80"] : ports, reach: .tailscale,
                               routes: [target(svc.namespace, "\(svc.name):\(first)")])
            site.via = "Tailscale operator (service \(svc.namespace)/\(svc.name))"
            site.scheme = ports.contains("80") || !ports.contains("443") ? "http" : "https"
            site.tailnetMachine = String(name.split(separator: ".").first ?? Substring(name))
            site.onTailnet = true
            add(site)
        }
        return sites
    }
}
