#!/bin/bash
# Usage:
#   sudo bash install.sh            once; asks for the proxy password, then starts at every login
#   sudo bash install.sh --ensure   login/boot repair; never prompts, never overwrites the password
set -euo pipefail
cd "$(dirname "$0")"
ENSURE=0
[ "${1:-}" = "--ensure" ] && ENSURE=1
[ "$EUID" -eq 0 ] || { echo "Run as: sudo bash install.sh"; exit 1; }

REAL_USER="${SUDO_USER:-}"
[ -n "$REAL_USER" ] && [ "$REAL_USER" != root ] || { echo "Run with sudo from your own account, not a root shell"; exit 1; }
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | awk '{print $2}')
REAL_UID=$(id -u "$REAL_USER")

umask 077
mkdir -p /usr/local/etc/hotspot-tun /usr/local/var/hotspot-tun /usr/local/libexec
chmod 755 /usr/local/libexec
chmod 700 /usr/local/etc/hotspot-tun /usr/local/var/hotspot-tun
if [ "$ENSURE" -eq 0 ]; then
  read -rsp "Proxy password (Settings > Authentication in the app): " PW; echo
  [[ "$PW" =~ ^[A-Za-z0-9]{24}$ ]] || { echo "Expected the 24-character password from the app"; exit 1; }
  printf '%s\n' "$PW" > /usr/local/etc/hotspot-tun/secret
  chmod 600 /usr/local/etc/hotspot-tun/secret
elif [ ! -s /usr/local/etc/hotspot-tun/secret ]; then
  echo "No saved proxy password. Run: sudo bash install.sh" >&2
  exit 1
fi

install -m 600 config.json /usr/local/etc/hotspot-tun/config.template.json
install -m 644 hotspot-lib.sh /usr/local/libexec/hotspot-lib.sh
install -m 755 hotspot-tun.sh /usr/local/libexec/hotspot-tun.sh
install -m 755 hotspot-agent.sh /usr/local/libexec/hotspot-agent.sh
install -m 644 local.hotspot-tun.singbox.plist /Library/LaunchDaemons/
install -m 644 local.hotspot-tun.watch.plist /Library/LaunchDaemons/

# Passwordless sudo for the login agent, scoped to one fixed script.
install -m 755 hotspot-agent-install.sh /usr/local/libexec/hotspot-agent-install.sh
SUDOERS=/etc/sudoers.d/hotspot-tun
printf '%s\n' "$REAL_USER ALL=(root) NOPASSWD: /usr/local/libexec/hotspot-agent-install.sh, /bin/launchctl print system/local.hotspot-tun.watch" > "$SUDOERS"
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null

AGENT_DIR="$REAL_HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/local.hotspot-tun.agent.plist"
install -m 644 -o "$REAL_USER" -g staff local.hotspot-tun.agent.plist "$AGENT_PLIST"

launchctl bootout system/local.hotspot-tun.watch 2>/dev/null || true
launchctl bootout system/local.hotspot-tun.singbox 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.hotspot-tun.watch.plist

DOMAIN="gui/$REAL_UID"
launchctl bootout "$DOMAIN/local.hotspot-tun.agent" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$AGENT_PLIST"
launchctl enable "$DOMAIN/local.hotspot-tun.agent"

if [ "$ENSURE" -eq 0 ]; then
  sleep 3
  launchctl print system/local.hotspot-tun.singbox >/dev/null 2>&1 && echo "TUN on" || echo "Standing by (TUN stays off until your own hotspot and proxy app are reachable)"
  echo "Starts at every login from now on. No further terminal step."
fi
