#!/bin/bash
# Usage: sudo bash uninstall.sh
[ "$EUID" -eq 0 ] || { echo "Run as: sudo bash uninstall.sh"; exit 1; }
REAL_USER="${SUDO_USER:-}"
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != root ]; then
  REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | awk '{print $2}')
  REAL_UID=$(id -u "$REAL_USER")
  launchctl bootout "gui/$REAL_UID/local.hotspot-tun.agent" 2>/dev/null || true
  rm -f "$REAL_HOME/Library/LaunchAgents/local.hotspot-tun.agent.plist"
fi
launchctl bootout system/local.hotspot-tun.watch 2>/dev/null || true
launchctl bootout system/local.hotspot-tun.singbox 2>/dev/null || true
# Undo the hotspot kill switch and Wi-Fi DNS override if they are active.
/sbin/pfctl -a com.apple/hotspot-tun -F rules 2>/dev/null || true
T=/usr/local/var/hotspot-tun/pf-token
[ -s "$T" ] && /sbin/pfctl -X "$(cat "$T")" 2>/dev/null || true
D=/usr/local/var/hotspot-tun/dns-saved
if [ -f "$D" ]; then
  SVC=$(networksetup -listallhardwareports | awk -F': ' '/Hardware Port: Wi-Fi/{print $2}')
  if grep -q "aren't any" "$D"; then SAVED=Empty; else SAVED=$(tr '\n' ' ' < "$D"); fi
  # shellcheck disable=SC2086  # one argument per saved server
  networksetup -setdnsservers "$SVC" $SAVED
fi
launchctl bootout system/local.hotspot-tun.tailscaled 2>/dev/null || true
rm -f /Library/LaunchDaemons/local.hotspot-tun.tailscaled.plist /usr/local/libexec/tailscaled-wrapper.sh
rm -f /Library/LaunchDaemons/local.hotspot-tun.*.plist \
  /usr/local/libexec/hotspot-tun.sh /usr/local/libexec/hotspot-lib.sh \
  /usr/local/libexec/hotspot-agent.sh /usr/local/libexec/hotspot-agent-install.sh \
  /etc/sudoers.d/hotspot-tun
rm -rf /usr/local/etc/hotspot-tun /usr/local/var/hotspot-tun /var/run/hotspot-tun.json
echo "Uninstalled"
