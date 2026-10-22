import Foundation
import Network

/// SOCKS5 UDP ASSOCIATE relay, listening on a UDP socket with the same port number as TCP.
/// One destination NWConnection per client flow; flows idle for 60s are reaped (low power).
/// Only clients with a live, authenticated UDP ASSOCIATE control connection (`isAllowed`) are relayed.
final class UdpRelay {
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var flows: [ObjectIdentifier: Flow] = [:]
    var onBytes: ((Int) -> Void)?
    var isAllowed: ((NWEndpoint.Host) -> Bool)?
    static let maxFlows = 64

    init(queue: DispatchQueue) { self.queue = queue }

    func start(port: UInt16) {
        stop()
        let p = NWParameters.udp
        p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel(); listener = nil
        flows.values.forEach { $0.close() }
        flows.removeAll()
    }

    /// Closes every flow from `ip` once its last UDP ASSOCIATE control connection is gone.
    func drop(_ ip: NWEndpoint.Host) {
        flows.values.filter { $0.ip == ip }.forEach { $0.close() }
    }

    private func accept(_ c: NWConnection) {
        guard case .hostPort(let ip, _) = c.endpoint, isAllowed?(ip) == true, flows.count < Self.maxFlows else {
            c.cancel(); return
        }
        let f = Flow(inbound: c, ip: ip, queue: queue)
        let id = ObjectIdentifier(f)
        flows[id] = f
        f.onBytes = { [weak self] n in self?.onBytes?(n) }
        f.onClose = { [weak self] in self?.flows[id] = nil }
        f.start()
    }

    final class Flow {
        let inbound: NWConnection
        let ip: NWEndpoint.Host
        let queue: DispatchQueue
        var outs: [String: Out] = [:]
        var lastActive = Date()
        var timer: DispatchSourceTimer?
        var closed = false
        var onBytes: ((Int) -> Void)?
        var onClose: (() -> Void)?
        static let maxDestinations = 256
        static let maxPending = 16

        /// Datagrams queue in `pending` until the resolved destination has passed `Destination` checks.
        final class Out {
            let conn: NWConnection
            var ready = false
            var pending: [Data] = []
            init(_ conn: NWConnection) { self.conn = conn }
        }

        init(inbound: NWConnection, ip: NWEndpoint.Host, queue: DispatchQueue) { self.inbound = inbound; self.ip = ip; self.queue = queue }

        func start() {
            var began = false
            inbound.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready:
                    guard !began else { return }
                    began = true
                    if Hotspot.arrivedOnHotspot(self.inbound.currentPath?.localEndpoint) { self.receive() } else { self.close() }
                case .failed: self.close()
                default: break
                }
            }
            inbound.start(queue: queue)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastActive) > 60 { self.close() }
            }
            t.resume()
            timer = t
        }

        private func receive() {
            inbound.receiveMessage { [weak self] data, _, _, err in
                guard let self, !self.closed else { return }
                if let data { self.handle(data) }
                if err == nil { self.receive() } else { self.close() }
            }
        }

        /// RSV(2) FRAG(1) ATYP(1) ADDR PORT(2) DATA
        private func handle(_ d: Data) {
            let b = [UInt8](d)
            guard b.count > 4, b[2] == 0 else { return }
            var i = 4
            let host: NWEndpoint.Host
            switch b[3] {
            case 1:
                guard b.count >= i + 6 else { return }
                host = .ipv4(IPv4Address(Data(b[i..<i + 4]))!); i += 4
            case 4:
                guard b.count >= i + 18 else { return }
                host = .ipv6(IPv6Address(Data(b[i..<i + 16]))!); i += 16
            case 3:
                let n = Int(b[i]); guard b.count >= i + 1 + n + 2 else { return }
                host = NWEndpoint.Host(String(decoding: b[(i + 1)..<(i + 1 + n)], as: UTF8.self)); i += 1 + n
            default: return
            }
            let port = (UInt16(b[i]) << 8) | UInt16(b[i + 1]); i += 2
            let header = Data(b[0..<i])
            let payload = Data(b[i...])
            lastActive = Date()
            onBytes?(payload.count)
            let key = header.base64EncodedString()
            if let o = outs[key] {
                if o.ready { o.conn.send(content: payload, completion: .idempotent) }
                else if o.pending.count < Self.maxPending { o.pending.append(payload) }
                return
            }
            guard port != 0, let p = NWEndpoint.Port(rawValue: port), !Destination.isForbidden(host),
                  let target = Destination.dialable(host), outs.count < Self.maxDestinations else { return }
            let o = Out(NWConnection(host: target, port: p, using: .udp))
            o.pending.append(payload)
            outs[key] = o
            o.conn.stateUpdateHandler = { [weak self, weak o] s in
                guard let self, let o else { return }
                switch s {
                case .ready:
                    guard !o.ready else { return }
                    if Destination.isForbidden(resolved: o.conn.currentPath?.remoteEndpoint) { self.drop(key); return }
                    o.ready = true
                    o.pending.forEach { o.conn.send(content: $0, completion: .idempotent) }
                    o.pending.removeAll()
                    self.pump(o.conn, header: header)
                case .failed: self.drop(key)
                default: break
                }
            }
            o.conn.start(queue: queue)
        }

        private func drop(_ key: String) {
            outs[key]?.conn.stateUpdateHandler = nil
            outs[key]?.conn.cancel()
            outs[key] = nil
        }

        private func pump(_ c: NWConnection, header: Data) {
            c.receiveMessage { [weak self] data, _, _, err in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.lastActive = Date()
                    self.onBytes?(data.count)
                    self.inbound.send(content: header + data, completion: .idempotent)
                }
                if err == nil { self.pump(c, header: header) }
            }
        }

        func close() {
            if closed { return }
            closed = true
            timer?.cancel()
            outs.values.forEach { $0.conn.stateUpdateHandler = nil; $0.conn.cancel() }
            outs.removeAll()
            inbound.cancel()
            onClose?()
        }
    }
}
