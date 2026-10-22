import Network
import SwiftUI
import UIKit
import WidgetKit

@MainActor
final class ProxyModel: ObservableObject {
    @AppStorage("port") var port: Int = 8080
    @AppStorage("autoStart") var autoStart: Bool = true
    @Published var running = false
    @Published var connections = 0
    @Published var bytes: UInt64 = 0
    @Published var error: String?
    @Published var addresses: [Hotspot.InterfaceAddress] = []
    @Published var startedAt: Date?
    /// Nil only when the Keychain failed; the proxy refuses to start without a password.
    @Published private(set) var password: String?

    private let server = ProxyServer()
    private let keepAlive = KeepAlive()
    private var timer: Timer?
    private var lastPublished: ProxySnapshot?
    /// -uiDemo / -uiDemoNoHotspot: screenshot QA mode, never starts the real server.
    let demo: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        demo = args.contains("-uiDemo") || args.contains("-uiDemoNoHotspot")
        server.onStats = { [weak self] n, b in Task { @MainActor in self?.connections = n; self?.bytes = b } }
        server.onState = { [weak self] e in
            Task { @MainActor in
                guard let self else { return }
                self.error = e
                if e != nil { self.running = false; self.startedAt = nil }
                self.publishSnapshot()
            }
        }
        if args.contains("-uiDemoNoHotspot") {
            running = true; startedAt = .now.addingTimeInterval(-412)
            addresses = [Self.demo("pdp_ip0", "10.44.1.7")]
        } else if args.contains("-uiDemo") {
            running = true; connections = 3; bytes = 48_300_000
            startedAt = .now.addingTimeInterval(-3725)
            addresses = [Self.demo("bridge100", "172.20.10.1"), Self.demo("en0", "192.168.0.12"), Self.demo("pdp_ip0", "10.44.1.7")]
        } else {
            do { password = try Credentials.loadOrCreate() } catch { self.error = "Could not load the proxy password: \(error)" }
            refreshAddresses()
            if autoStart { start() }
        }
        publishSnapshot()
    }

    var hotspotIP: String? { Hotspot.preferredAddress(addresses) }
    var endpoint: String? { snapshot.endpoint }

    private static func demo(_ interface: String, _ ip: String) -> Hotspot.InterfaceAddress {
        Hotspot.InterfaceAddress(interface: interface, host: NWEndpoint.Host(ip), text: ip)
    }

    var status: ProxySnapshot.Status {
        if error != nil { return .error }
        if !running { return .stopped }
        if hotspotIP == nil { return .noHotspot }
        return .running
    }

    var snapshot: ProxySnapshot {
        ProxySnapshot(status: status, hotspotIP: hotspotIP, port: port, connections: connections,
                      bytes: bytes, errorMessage: error, updatedAt: .now)
    }

    func setVisible(_ visible: Bool) {
        timer?.invalidate(); timer = nil
        guard visible else { publishSnapshot(force: true); return }
        guard !demo else { return }
        refreshAddresses(); server.pollStats()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAddresses(); self?.server.pollStats(); self?.publishSnapshot() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func start() {
        if !demo {
            guard let password else { publishSnapshot(); return }
            error = nil
            server.start(port: UInt16(clamping: port), auth: ProxyAuth(password: password))
            keepAlive.start()
        }
        running = true
        startedAt = .now
        publishSnapshot()
    }

    func stop() {
        if !demo {
            server.stop()
            keepAlive.stop()
        }
        running = false
        startedAt = nil
        publishSnapshot()
    }

    func toggle() { running ? stop() : start() }

    /// New password; every connected device and the Mac must be updated afterwards.
    func regeneratePassword() {
        guard !running, !demo else { return }
        do { password = try Credentials.regenerate(); error = nil } catch { self.error = "Could not save the proxy password: \(error)" }
    }

    @discardableResult
    func setPort(_ value: Int) -> Bool {
        guard !running, (1024...65535).contains(value) else { return false }
        port = value
        publishSnapshot()
        return true
    }

    func copyEndpoint() -> Bool {
        guard let endpoint else { return false }
        UIPasteboard.general.string = endpoint
        return true
    }

    func handle(_ link: DeepLink) {
        switch link {
        case .open: break
        case .start: if !running { start() }
        case .stop: if running { stop() }
        case .toggle: toggle()
        case .copy: _ = copyEndpoint()
        }
    }

    /// Reloads widget timelines only when status/endpoint/port change, never per byte tick (battery).
    func publishSnapshot(force: Bool = false) {
        let s = snapshot
        SharedStore.save(s)
        let changed = lastPublished.map { $0.status != s.status || $0.endpoint != s.endpoint || $0.port != s.port } ?? true
        if changed || force {
            WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
        }
        lastPublished = s
    }

    func refreshAddresses() {
        addresses = Hotspot.addresses().sorted { ($0.isHotspot ? 0 : 1) < ($1.isHotspot ? 0 : 1) }
    }
}
