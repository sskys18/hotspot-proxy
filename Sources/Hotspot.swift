import Darwin
import Foundation
import Network

/// Personal Hotspot interfaces and this device's own addresses.
/// The hotspot may be IPv4 (172.20.10.0/28) or IPv6-only (link-local plus the carrier /64, with CLAT on clients),
/// so membership is decided by the interface a connection arrived on, never by an address range.
enum Hotspot {
    struct InterfaceAddress {
        let interface: String
        let host: NWEndpoint.Host
        /// Address without a zone, for display ("fe80::1", "172.20.10.1").
        let text: String
        var isHotspot: Bool { Hotspot.isHotspotInterface(interface) }
    }

    static func isHotspotInterface(_ name: String) -> Bool { name.hasPrefix("bridge") }

    /// Every IPv4/IPv6 address on every interface except loopback.
    static func addresses() -> [InterfaceAddress] {
        var out: [InterfaceAddress] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let full = String(cString: buf)                       // "fe80::1%bridge100"
            let text = String(full.split(separator: "%").first ?? Substring(full))
            out.append(InterfaceAddress(interface: name, host: NWEndpoint.Host(full), text: text))
        }
        return out
    }

    /// Address bytes of a concrete IP host (zone ignored), nil for names.
    static func bytes(_ h: NWEndpoint.Host) -> Data? {
        switch h {
        case .ipv4(let a): return a.rawValue
        case .ipv6(let a): return a.asIPv4?.rawValue ?? a.rawValue
        default: return nil
        }
    }

    /// True when `local` (our side of an accepted connection) is an address of a Personal Hotspot interface.
    static func arrivedOnHotspot(_ local: NWEndpoint?) -> Bool {
        guard case .hostPort(let h, _)? = local, let b = bytes(h) else { return false }
        return addresses().contains { $0.isHotspot && bytes($0.host) == b }
    }

    /// True when `h` is one of this iPhone's own addresses on any interface.
    static func isOwnAddress(_ h: NWEndpoint.Host) -> Bool {
        guard let b = bytes(h) else { return false }
        return addresses().contains { bytes($0.host) == b }
    }

    /// Best address for other devices to enter: hotspot IPv4, else global IPv6, else link-local IPv6.
    static func preferredAddress(_ list: [InterfaceAddress]) -> String? {
        let hotspot = list.filter(\.isHotspot)
        func rank(_ a: InterfaceAddress) -> Int {
            switch a.host {
            case .ipv4: return 0
            case .ipv6(let v6): return v6.isLinkLocal ? 2 : 1
            default: return 3
            }
        }
        return hotspot.min { rank($0) < rank($1) }?.text
    }
}
