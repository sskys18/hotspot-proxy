import SwiftUI

struct ConnectGuideView: View {
    @EnvironmentObject var m: ProxyModel

    var body: some View {
        List {
            Section {
                if let ip = m.hotspotIP {
                    CopyableRow(title: "Server", value: ip)
                } else {
                    LabeledContent("Server", value: "Turn on Personal Hotspot")
                }
                CopyableRow(title: "Port", value: String(m.port))
                CopyableRow(title: "Username", value: ProxyAuth.username)
                if let password = m.password {
                    CopyableRow(title: "Password", value: password, secret: true)
                }
            } header: {
                Text("Values to Enter")
            } footer: {
                Text("HTTP, HTTPS, and SOCKS5 all use the same server and port. Authentication is required.")
            }

            Section("iPhone · iPad") {
                SetupStep(number: 1, title: "Join the Hotspot", detail: "In Settings › Wi-Fi, choose this iPhone’s hotspot.")
                SetupStep(number: 2, title: "Open Network Info", detail: "Tap the (i) button next to the joined network.")
                SetupStep(number: 3, title: "Configure Proxy › Manual", detail: "Enter the server and port, turn on Authentication with the username and password, then Save.")
            }
            Section("macOS") {
                SetupStep(number: 1, title: "System Settings › Network › Wi-Fi", detail: "Click ‘Details…’ on the joined hotspot.")
                SetupStep(number: 2, title: "Proxies Tab", detail: "Enable Web (HTTP), Secure Web (HTTPS), and SOCKS proxies with the server, port, username and password.")
                SetupStep(number: 3, title: "Or Use Auto TUN", detail: "To route every app automatically, follow the ‘Mac Auto-Connect’ guide.")
            }
            Section("Android") {
                SetupStep(number: 1, title: "Long-Press the Wi-Fi Network", detail: "Modify network › Advanced options › Proxy › Manual.")
                SetupStep(number: 2, title: "Enter Host and Port", detail: "Use the server and port above, then Save. Browsers ask for the username and password on first use.")
            }
            Section("Windows") {
                SetupStep(number: 1, title: "Settings › Network & Internet › Proxy", detail: "Under Manual proxy setup, turn on Use a proxy server.")
                SetupStep(number: 2, title: "Enter Address and Port", detail: "Use the server and port above, then Save. Browsers ask for the username and password on first use.")
            }
        }
        .navigationTitle("Connect Devices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MacSetupView: View {
    private let commands: [(String, String)] = [
        ("Install sing-box", "brew install sing-box"),
        ("Install auto TUN (asks for the password)", "sudo bash mac/install.sh"),
        ("Uninstall", "sudo bash mac/uninstall.sh"),
        ("Switch Tailscale to CLI (optional)", "sudo bash mac/install-tailscale.sh"),
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label("How It Works", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                    Text("Join this iPhone’s hotspot and the Mac routes all traffic through the proxy on its own. Leave the hotspot and it turns off. After the one-time install it starts at every login; there is no command to run again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Space.xs)
            }
            Section {
                ForEach(commands, id: \.1) { c in
                    CopyableRow(title: c.0, value: c.1)
                }
            } header: {
                Text("Terminal Commands")
            } footer: {
                Text("Run once from the repo’s mac/ directory. A login agent then starts the watcher at every login and puts it back after a reboot.")
            }
        }
        .navigationTitle("Mac Auto-Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}
