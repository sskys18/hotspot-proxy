<p align="center">
  <img src="design/icon/preview.png" width="420" alt="Hotspot Proxy app icon in light, dark, and tinted variants">
</p>

<h1 align="center">Hotspot Proxy</h1>

<p align="center">
  An iOS app that lets devices on your iPhone's Personal Hotspot use <b>the iPhone's own cellular connection as a proxy</b>.<br>
  HTTP, HTTPS (CONNECT), and SOCKS5 (TCP + UDP ASSOCIATE) on a single port.
</p>

<p align="center">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0B8A7D">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5-F05138">
  <img alt="SwiftUI + WidgetKit" src="https://img.shields.io/badge/SwiftUI-WidgetKit-33D6C2">
</p>

---

## Why

Some carriers and plans classify tethered hotspot traffic separately and throttle or cap it. Hotspot Proxy runs a proxy server inside the iPhone. When devices on the hotspot (Mac, iPad, laptop) go through it, their traffic leaves as the iPhone app's own traffic.

## Screenshots

| Main (running) | Hotspot off | Settings | Welcome |
|---|---|---|---|
| <img src="docs/screenshots/main-light.png" width="200"> | <img src="docs/screenshots/nohotspot-light.png" width="200"> | <img src="docs/screenshots/settings-light.png" width="200"> | <img src="docs/screenshots/onboarding-light.png" width="200"> |
| <img src="docs/screenshots/main-dark.png" width="200"> | <img src="docs/screenshots/nohotspot-dark.png" width="200"> | <img src="docs/screenshots/settings-dark.png" width="200"> | <img src="docs/screenshots/onboarding-dark.png" width="200"> |

<img src="docs/screenshots/home-icon.png" width="300" alt="App icon on the Home Screen">

### Lock Screen and Home Screen widgets

<img src="docs/screenshots/widgets.png" width="420" alt="Lock Screen circular, rectangular, and inline widgets plus the small Home Screen widget">

- **Lock Screen** has three widgets:
  - Circular shows the status and connection count.
  - Rectangular shows the status, `IP:port`, connections, and data transferred.
  - Inline shows a one-line status.
- **Home Screen** has a small widget with a status chip, the proxy address, stats, and when it last updated.
- Tapping a widget opens the app. The app reloads widgets only when the state changes, so they cost almost no battery.

## Features

- **Status hero.** A "signal ring" shows the current state: green while running, amber when the hotspot is off, grey when stopped, and red on error.
- **One-tap start and stop**, with haptic feedback.
- **Copy the address.** One tap copies `172.20.10.1:8080` to enter on other devices.
- **Live stats** for active connections, data transferred, and uptime. Stats update only while the screen is visible.
- **Connection guides** for iPhone/iPad, macOS, Android, and Windows.
- **Mac auto-TUN guide.** The `mac/` scripts route all system traffic through the proxy automatically.
- **Welcome flow** that covers turning on the hotspot, local network permission, and how background keep-alive works.
- **Accessibility:** Dark Mode, Dynamic Type (including accessibility sizes), VoiceOver labels, and Reduce Motion.

## Usage

1. On the iPhone, turn on **Settings › Personal Hotspot › Allow Others to Join**.
2. Open the app and tap **Start Proxy**. By default it starts automatically on launch.
3. Join the hotspot from another device and set its proxy manually:
   - Server: the address shown in the app (`172.20.10.1` on IPv4 hotspots; on IPv6-only carrier hotspots an IPv6 link-local address such as `fe80::...`)
   - Port: `8080`
   - HTTP, HTTPS, and SOCKS5 all use the same port.
   - Username `hotspot`, password from **Settings › Authentication** (generated on first launch, stored in the Keychain).

### Security

- Only connections that arrive on the Personal Hotspot interface (`bridge*`) are accepted, for both IPv4 (`172.20.10.0/28`) and IPv6-only hotspots, and every client must authenticate (SOCKS5 username/password, HTTP `Proxy-Authorization: Basic`).
- The proxy refuses to reach any of the iPhone's own addresses, loopback, link-local and multicast, checked again on the resolved address.
- UDP is relayed only while the client holds an authenticated SOCKS5 UDP ASSOCIATE connection.
- Clients get 10 seconds to authenticate; sessions and UDP flows are capped.
- `GET /hotspot-proxy/identify?n=<hex>` returns `HMAC-SHA256(password, "hotspot-proxy-identify:" + n)` without authentication, so the Mac can prove it reached its own phone before sending credentials.

### Mac: system-wide automatic proxy (optional)

The `mac/` directory has a launchd setup built on [sing-box](https://sing-box.sagernet.org) TUN. It sends all traffic through the iPhone proxy, but **only while the Mac is on the hotspot**.

```bash
brew install sing-box
sudo bash mac/install.sh             # once; then starts at every login
sudo bash mac/uninstall.sh           # remove
sudo bash mac/install-tailscale.sh   # (optional) run Tailscale as a CLI daemon
```

`install.sh` asks for the app password once, stores it root-only (mode 600), and registers a user LaunchAgent. That agent starts at every login and reloads the root watcher if a reboot dropped it, so there is no command to run again. The watcher itself runs on every network change and every 30 seconds. It tries the IPv4 hotspot gateway `172.20.10.1` and the Wi-Fi IPv6 default router (IPv6-only carrier hotspots give clients no `172.20.10.x` address, only link-local plus CLAT). When one of them answers the identify challenge on port 8080 with the right HMAC, it first checks that the phone can actually reach the internet, then turns the TUN on, so joining a stranger's iPhone hotspot never routes traffic or credentials there. System DNS is left alone: lookups go to the hotspot's own resolver and the resulting connections enter the TUN by route. Otherwise the TUN stays off.

Each run writes its result to `/var/run/hotspot-tun.json` (readable by any user), for example `{"state":"proxied","phone":"172.20.10.1","updated":1700000000}`. `state` is `proxied`, `upstream-failed` (on the hotspot, but the phone app cannot reach the internet, so the Mac stays direct), `route-failed` (the tunnel could not take traffic; retried after rejoining), or `off`. An `updated` older than about two minutes means the watcher has stopped. DockAwake shows this in its Network card.

## Background behavior and battery

iOS doesn't keep a background app's sockets alive for long. To stay running, the app loops **silent audio** (8 kHz, in 30-second segments). The audio mixes with other apps (`mixWithOthers`) at zero volume. UI timers run only while the screen is visible, and idle UDP flows are cleaned up after 60 seconds.

> The silent-audio background mode may not pass App Store review. This app is intended for personal sideloading or developer-signed builds.

## Build

```bash
brew install xcodegen
xcodegen generate
open HotspotProxy.xcodeproj
```

- The project has two targets: `HotspotProxy` (the app) and `HotspotProxyWidget` (the WidgetKit extension).
- Signing comes from `Config/Signing.xcconfig`, which commits only placeholders. Put your own `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` in `Config/Signing.local.xcconfig` (git-ignored) and run `xcodegen generate`. The bundle IDs, the App Group `group.<prefix>.hotspotproxy` the targets share, and the Keychain service all derive from that prefix.
- Icon sources are in `design/icon/*.svg`. The design system is in [`DESIGN.md`](DESIGN.md).

## Layout

```
Sources/
  App.swift              App entry, deep-link handling
  Model/ProxyModel.swift Proxy state, widget snapshot publishing
  Views/                 Main, settings, welcome, connection guide, Mac guide
  Design/                Tokens and shared components (SignalRing, StatusHero, ...)
  ProxyServer.swift      HTTP/CONNECT + SOCKS5 server (Network.framework)
  UdpRelay.swift         SOCKS5 UDP ASSOCIATE relay
  KeepAlive.swift        Silent-audio background keep-alive
Widget/                  Lock Screen and Home Screen widgets
Shared/                  App/widget shared snapshot, deep links, color assets
mac/                     macOS sing-box TUN automation scripts
```

## Deep links

| URL | Action |
|---|---|
| `hotspotproxy://open` | Open the app |
| `hotspotproxy://start` / `stop` / `toggle` | Control the proxy |
| `hotspotproxy://copy` | Copy the proxy address |

Use the "Open URLs" action in Shortcuts to automate them.
