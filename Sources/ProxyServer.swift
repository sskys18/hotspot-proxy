import CryptoKit
import Foundation
import Network
import os

/// Proxy serving HTTP (incl. CONNECT) and SOCKS5 on the same port.
/// Only Personal Hotspot clients that present the proxy password are served.
final class ProxyServer {
    let queue = DispatchQueue(label: "proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var live: [ObjectIdentifier: Session] = [:]
    var onStats: ((Int, UInt64) -> Void)?
    var onState: ((String?) -> Void)?
    private let bytes = OSAllocatedUnfairLock(initialState: UInt64(0))
    private lazy var udp = UdpRelay(queue: queue)
    /// Hotspot clients holding an open SOCKS5 UDP ASSOCIATE control connection (count per address). Accessed on `queue`.
    private var associations: [NWEndpoint.Host: Int] = [:]
    /// Each session gets a serial queue targeting this concurrent queue, so connections run in parallel across cores.
    private let work = DispatchQueue(label: "proxy.sessions", qos: .userInitiated, attributes: .concurrent)
    static let maxSessions = 256

    func start(port: UInt16, auth: ProxyAuth) {
        stop()
        do {
            let params = Tcp.params()
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c, auth: auth) }
            l.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready: self?.onState?(nil)
                case .failed(let e): self?.onState?("Listener error: \(e)")
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
            queue.async { [self] in
                udp.isAllowed = { [weak self] ip in self?.associations[ip] != nil }
                udp.onBytes = { [weak self] n in self?.bytes.withLock { $0 &+= UInt64(n) } }
                udp.start(port: port)
            }
        } catch {
            onState?("Failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        queue.async { [weak self] in
            self?.udp.stop()
            self?.associations.removeAll()
            self?.live.values.forEach { s in s.queue.async { s.close() } }
            self?.live.removeAll()
            self?.report()
        }
    }

    private func accept(_ c: NWConnection, auth: ProxyAuth) {
        guard case .hostPort(let ip, _) = c.endpoint, live.count < Self.maxSessions else { c.cancel(); return }
        let s = Session(client: c, auth: auth, queue: DispatchQueue(label: "proxy.s", target: work))
        let id = ObjectIdentifier(s)
        live[id] = s
        s.onBytes = { [weak self] n in self?.bytes.withLock { $0 &+= UInt64(n) } }
        s.onClose = { [weak self] in self?.queue.async { self?.live[id] = nil } }
        s.onAssociate = { [weak self] on in self?.queue.async { self?.associate(ip, on) } }
        s.queue.async { s.start() }
    }

    private func associate(_ ip: NWEndpoint.Host, _ on: Bool) {
        let n = (associations[ip] ?? 0) + (on ? 1 : -1)
        associations[ip] = n > 0 ? n : nil
        if n <= 0 { udp.drop(ip) }
    }

    /// Called only while the UI is visible (never wakes the main thread in background).
    private func report() {
        let n = live.count, b = bytes.withLock { $0 }
        onStats?(n, b)
    }
    func pollStats() { queue.async { [weak self] in self?.report() } }
}

/// Destinations the proxy refuses to reach: any address of the iPhone itself, loopback, link-local and multicast.
enum Destination {
    static func isForbidden(_ h: NWEndpoint.Host) -> Bool {
        switch h {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b[0] == 0 || b[0] == 127 || (b[0] == 169 && b[1] == 254) || b[0] >= 224 || Hotspot.isOwnAddress(h)
        case .ipv6(let a):
            if let v4 = a.asIPv4 { return isForbidden(.ipv4(v4)) }
            return a.isLoopback || a.isLinkLocal || a.isMulticast || a == .any || Hotspot.isOwnAddress(h)
        default:
            return false   // names are checked again on the resolved endpoint
        }
    }

    /// The host to dial. On IPv6-only cellular (NAT64) Network.framework refuses IPv4 literals with
    /// "No network route", so IPv4 is first translated through the system's NAT64 synthesis.
    /// getaddrinfo returns the IPv4 address itself on networks that have IPv4. Nil when it fails.
    static func dialable(_ h: NWEndpoint.Host) -> NWEndpoint.Host? {
        guard case .ipv4(let v4) = h else { return h }
        var hints = addrinfo()
        hints.ai_flags = AI_V4MAPPED_CFG | AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("\(v4)", nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        switch first.pointee.ai_family {
        case AF_INET:
            return h
        case AF_INET6:
            let bytes = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Data($0) }
            }
            return IPv6Address(bytes).map { .ipv6($0) }
        default:
            return nil
        }
    }

    /// Resolved endpoint check; anything that is not a concrete address is refused.
    static func isForbidden(resolved e: NWEndpoint?) -> Bool {
        guard case .hostPort(let h, _)? = e else { return true }
        switch h {
        case .ipv4, .ipv6: return isForbidden(h)
        default: return true
        }
    }
}

/// Client authentication (SOCKS5 username/password, HTTP Basic) and the proxy identity proof for the Mac.
struct ProxyAuth: Sendable {
    static let username = "hotspot"
    static let identifyPath = "/hotspot-proxy/identify?n="
    let password: String
    private let basic: Data

    init(password: String) {
        self.password = password
        basic = Data(("Basic " + Data("\(Self.username):\(password)".utf8).base64EncodedString()).utf8)
    }

    func accepts(user: Data, pass: Data) -> Bool {
        // Evaluate both so timing does not reveal which half was wrong.
        let u = Self.equal(user, Data(Self.username.utf8)), p = Self.equal(pass, Data(password.utf8))
        return u && p
    }

    func accepts(proxyAuthorization value: String) -> Bool { Self.equal(Data(value.utf8), basic) }

    /// HMAC-SHA256(password, "hotspot-proxy-identify:" + nonce) in lowercase hex.
    func identify(nonce: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("hotspot-proxy-identify:\(nonce)".utf8),
                                                  using: SymmetricKey(data: Data(password.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant time for equal lengths; the length itself is not secret.
    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum Tcp {
    static func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        return NWParameters(tls: nil, tcp: tcp)
    }
    static let chunk = 128 * 1024
    /// A client must finish auth and its request within this window.
    static let handshakeTimeout: DispatchTimeInterval = .seconds(10)
}

final class Session {
    let client: NWConnection
    let auth: ProxyAuth
    var upstream: NWConnection?
    let queue: DispatchQueue
    var buf = Data()
    var closed = false
    private var established = false
    private var associated = false
    private var finished = 0   // directions that hit EOF; session closes at 2
    var onBytes: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onAssociate: ((Bool) -> Void)?

    init(client: NWConnection, auth: ProxyAuth, queue: DispatchQueue) {
        self.client = client; self.auth = auth; self.queue = queue
    }

    func start() {
        var began = false
        client.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                guard !began else { return }
                began = true
                // Only clients that reached us through a Personal Hotspot interface are served.
                if Hotspot.arrivedOnHotspot(self.client.currentPath?.localEndpoint) { self.begin() } else { self.close() }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Tcp.handshakeTimeout) { [weak self] in
            if let self, !self.established { self.close() }
        }
    }

    private func begin() {
        need(1) { [weak self] in
            guard let self else { return }
            if self.buf.first == 0x05 { self.socksGreeting() } else { self.readHttpHeader() }
        }
    }

    // MARK: buffered reading
    private func need(_ n: Int, _ then: @escaping () -> Void) {
        if buf.count >= n { then(); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buf.append(data) }
            if err != nil || (done && self.buf.count < n) { self.close(); return }
            self.need(n, then)
        }
    }

    private func take(_ n: Int) -> Data {
        let d = buf.prefix(n); buf.removeFirst(n); return Data(d)
    }

    /// Sends `d`, then closes once it has been handed to the network.
    private func sendThenClose(_ d: Data) {
        client.send(content: d, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    // MARK: SOCKS5
    /// Only username/password (RFC 1929) is offered; "no auth" clients get 0xFF.
    private func socksGreeting() {
        need(2) { [self] in
            let nm = Int(buf[buf.startIndex + 1])
            need(2 + nm) { [self] in
                let methods = take(2 + nm).dropFirst(2)
                guard methods.contains(0x02) else { sendThenClose(Data([5, 0xFF])); return }
                client.send(content: Data([5, 2]), completion: .contentProcessed { _ in })
                socksLogin()
            }
        }
    }

    /// VER(1)=1 ULEN(1) UNAME PLEN(1) PASSWD
    private func socksLogin() {
        need(2) { [self] in
            guard buf[buf.startIndex] == 1 else { sendThenClose(Data([1, 1])); return }
            let ulen = Int(buf[buf.startIndex + 1])
            need(2 + ulen + 1) { [self] in
                let plen = Int(buf[buf.startIndex + 2 + ulen])
                need(3 + ulen + plen) { [self] in
                    let r = take(3 + ulen + plen)
                    let user = r.subdata(in: r.startIndex + 2 ..< r.startIndex + 2 + ulen)
                    let pass = r.subdata(in: r.startIndex + 3 + ulen ..< r.endIndex)
                    guard auth.accepts(user: user, pass: pass) else { sendThenClose(Data([1, 1])); return }
                    client.send(content: Data([1, 0]), completion: .contentProcessed { _ in })
                    socksRequest()
                }
            }
        }
    }

    private func socksRequest() {
        need(5) { [self] in
            let b = Array(buf.prefix(5))
            guard b[0] == 5, b[1] == 1 || b[1] == 3 else { sendThenClose(reply(7)); return }
            let cmd = b[1]
            let atyp = b[3]
            let addrLen: Int
            switch atyp {
            case 1: addrLen = 4
            case 3: addrLen = 1 + Int(b[4])
            case 4: addrLen = 16
            default: sendThenClose(reply(8)); return
            }
            need(4 + addrLen + 2) { [self] in
                let r = Array(take(4 + addrLen + 2))
                let a = Array(r[4..<(4 + addrLen)])
                let host: String
                switch atyp {
                case 1: host = a.map(String.init).joined(separator: ".")
                case 3: host = String(decoding: a[1...], as: UTF8.self)
                default: host = stride(from: 0, to: 16, by: 2).map { String(format: "%x", (UInt16(a[$0]) << 8) | UInt16(a[$0 + 1])) }.joined(separator: ":")
                }
                let port = (UInt16(r[4 + addrLen]) << 8) | UInt16(r[5 + addrLen])
                if cmd == 3 { udpAssociate(); return }
                connect(host: host, port: port) { [self] ok in
                    guard ok else { sendThenClose(reply(5)); return }
                    client.send(content: reply(0), completion: .contentProcessed { _ in })
                    pipe()
                }
            }
        }
    }

    /// UDP ASSOCIATE: reply with the UDP relay on the same IP/port and hold until the TCP control connection closes.
    /// A link-local address is useless without the client's zone, so it is answered as unspecified (client reuses the server address).
    private func udpAssociate() {
        var resp = reply(0)
        if case .hostPort(let h, let p)? = client.currentPath?.localEndpoint {
            let port = Data([UInt8(p.rawValue >> 8), UInt8(p.rawValue & 0xff)])
            switch h {
            case .ipv4(let v4): resp = Data([5, 0, 0, 1]) + v4.rawValue + port
            case .ipv6(let v6) where !v6.isLinkLocal: resp = Data([5, 0, 0, 4]) + v6.rawValue + port
            case .ipv6: resp = Data([5, 0, 0, 4]) + Data(count: 16) + port
            default: break
            }
        }
        established = true
        associated = true
        onAssociate?(true)
        client.send(content: resp, completion: .contentProcessed { _ in })
        holdOpen()
    }

    private func holdOpen() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            if done || err != nil { self?.close() } else { self?.holdOpen() }
        }
    }

    private func reply(_ code: UInt8) -> Data { Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]) }

    // MARK: HTTP
    private func readHttpHeader() {
        if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
            buf.removeSubrange(buf.startIndex..<r.upperBound)
            handleHttp(head)
            return
        }
        if buf.count > 64 * 1024 { close(); return }
        need(buf.count + 1) { [weak self] in self?.readHttpHeader() }
    }

    private func httpStatus(_ status: String, extra: String = "") -> Data {
        Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private func handleHttp(_ head: String) {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { close(); return }
        let method = parts[0], target = parts[1], version = parts[2]

        if method == "GET", target.hasPrefix(ProxyAuth.identifyPath) {
            identify(nonce: String(target.dropFirst(ProxyAuth.identifyPath.count)))
            return
        }

        let credentials = lines.dropFirst().first { $0.lowercased().hasPrefix("proxy-authorization:") }
            .map { $0.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces) }
        guard let credentials, auth.accepts(proxyAuthorization: credentials) else {
            sendThenClose(httpStatus("407 Proxy Authentication Required", extra: "Proxy-Authenticate: Basic realm=\"hotspot\"\r\n"))
            return
        }

        if method.uppercased() == "CONNECT" {
            let (h, p) = splitHostPort(target, defaultPort: 443)
            connect(host: h, port: p) { [self] ok in
                guard ok else { sendThenClose(httpStatus("502 Bad Gateway")); return }
                client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                pipe()
            }
            return
        }

        guard let url = URL(string: target), let host = url.host else {
            sendThenClose(httpStatus("400 Bad Request"))
            return
        }
        let port = UInt16(url.port ?? 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        lines[0] = "\(method) \(path) \(version)"
        lines = lines.filter {
            let k = $0.lowercased()
            return !(k.hasPrefix("proxy-connection:") || k.hasPrefix("connection:") || k.hasPrefix("keep-alive:") || k.hasPrefix("proxy-authorization:"))
        }
        lines.append("Connection: close")
        let newHead = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connect(host: host, port: port) { [self] ok in
            guard ok else { sendThenClose(httpStatus("502 Bad Gateway")); return }
            upstream?.send(content: newHead, completion: .contentProcessed { _ in })
            pipe()
        }
    }

    /// Unauthenticated on purpose: lets the Mac verify this is its own proxy before it sends any credentials.
    private func identify(nonce: String) {
        guard (32...128).contains(nonce.count), nonce.allSatisfy(\.isHexDigit) else {
            sendThenClose(httpStatus("400 Bad Request")); return
        }
        let body = auth.identify(nonce: nonce)
        sendThenClose(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8))
    }

    private func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16) {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            let h = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            return (h, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        if let i = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: i)...]) { return (String(s[..<i]), p) }
        return (s, defaultPort)
    }

    // MARK: upstream + relay
    /// Connects to the destination; refuses forbidden literals up front and forbidden resolved addresses at ready.
    private func connect(host: String, port: UInt16, _ done: @escaping (Bool) -> Void) {
        let h = NWEndpoint.Host(host)
        guard let p = NWEndpoint.Port(rawValue: port), port != 0, !Destination.isForbidden(h),
              let target = Destination.dialable(h) else { done(false); return }
        let up = NWConnection(host: target, port: p, using: Tcp.params())
        upstream = up
        var fired = false
        up.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                guard !fired else { break }
                fired = true
                if Destination.isForbidden(resolved: up.currentPath?.remoteEndpoint) {
                    up.stateUpdateHandler = nil; up.cancel(); self?.upstream = nil; done(false)
                } else {
                    self?.established = true
                    done(true)
                }
            case .failed, .waiting:
                if !fired { fired = true; done(false) } else { self?.close() }
            case .cancelled: if fired { self?.close() }
            default: break
            }
        }
        up.start(queue: queue)
    }

    private func pipe() {
        guard let up = upstream else { close(); return }
        if !buf.isEmpty { let d = buf; buf = Data(); up.send(content: d, completion: .contentProcessed { _ in }) }
        relay(from: client, to: up)
        relay(from: up, to: client)
    }

    /// On EOF in one direction, forward only a FIN (half-close) and keep relaying the other direction.
    private func relay(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: Tcp.chunk) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if err != nil { self.close(); return }
            let payload = (data?.isEmpty == false) ? data : nil
            if let payload { self.onBytes?(payload.count) }
            if payload == nil && !done { self.relay(from: from, to: to); return }
            to.send(content: payload, contentContext: done ? .finalMessage : .defaultMessage, isComplete: done,
                    completion: .contentProcessed { [weak self] e in
                guard let self, !self.closed else { return }
                if e != nil { self.close(); return }
                if done {
                    self.finished += 1
                    if self.finished == 2 { self.close() }
                } else {
                    self.relay(from: from, to: to)
                }
            })
        }
    }

    func close() {
        if closed { return }
        closed = true
        client.cancel(); upstream?.cancel()
        if associated { onAssociate?(false) }
        onClose?()
    }
}
