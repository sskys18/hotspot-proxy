#!/bin/bash
# Runs on network changes (and every 30s). Turns the TUN on when on our own iPhone hotspot with the proxy app up, off otherwise.
# System DNS is never touched: lookups keep going to the hotspot's own resolver (outside the TUN), and
# the resulting connections enter the TUN by route. Pointing DNS at an address inside the TUN breaks
# every resolver that binds to Wi-Fi directly (Tailscale's MagicDNS forwarder does), so names stop resolving.
. /usr/local/libexec/hotspot-lib.sh
LABEL=local.hotspot-tun.singbox
PLIST=/Library/LaunchDaemons/$LABEL.plist
ETC=/usr/local/etc/hotspot-tun
VAR=/usr/local/var/hotspot-tun
PROBE=1.1.1.1        # any public address outside route_exclude_address
FAIL_FILE=$VAR/failed-host
running() { /bin/launchctl print system/$LABEL >/dev/null 2>&1; }
note() { /usr/bin/logger -t hotspot-tun "$*"; }
probe_if() { /sbin/route -n get "$PROBE" 2>/dev/null | /usr/bin/awk '/interface:/{print $2}'; }
# True once public traffic enters the TUN. sing-box installs split routes around
# route_exclude_address, so the literal default route stays on Wi-Fi; probe a real destination.
tun_routed() {
  local i=0
  while [ "$i" -lt 10 ]; do
    [ "$(probe_if)" = utun199 ] && return 0
    i=$((i + 1))
    /bin/sleep 1
  done
  return 1
}
tun_off() { running && /bin/launchctl bootout system/$LABEL; }
# World-readable result of this run, for status displays such as DockAwake. Rewritten every run,
# so a stale "updated" means the watcher itself has stopped.
STATUS=/var/run/hotspot-tun.json
write_status() {
  printf '{"state":"%s","phone":"%s","updated":%s}\n' "$1" "$2" "$(/bin/date +%s)" > "$STATUS.new" &&
    /bin/chmod 644 "$STATUS.new" && /bin/mv "$STATUS.new" "$STATUS"
}

if HOST=$(find_proxy); then MODE=hotspot; else MODE=normal; fi
if [ "$MODE" = hotspot ] && [ "$(cat "$FAIL_FILE" 2>/dev/null)" = "$HOST" ]; then
  # Already failed on this hotspot. Retrying on every network event loops: each teardown is
  # itself a network change, so the link would drop every few seconds. Retry after rejoining.
  tun_off
  MODE=normal
  STATE=route-failed
elif [ "$MODE" = hotspot ] && ! egress_ok "$HOST"; then
  # The phone answers but cannot reach the internet for us. Stay on the plain hotspot. This
  # changes nothing on the network, so it is safe to re-check every interval until it recovers.
  note "proxy at $HOST answers but its upstream fails; staying direct"
  tun_off
  MODE=normal
  STATE=upstream-failed
elif [ "$MODE" = hotspot ]; then
  # Render the live config (phone address + password) root-only; restart sing-box when it changed.
  umask 077
  # 172.20.10.0/28 keeps the phone (172.20.10.1) outside the TUN. Without it the SOCKS
  # connection to the phone is captured by the tunnel it feeds and every connection dies.
  # IPv6 link-local is already excluded as fe80::/10.
  /usr/bin/jq --arg h "$HOST" --rawfile pw "$SECRET" \
    '(.outbounds[] | select(.tag=="proxy")) |= (.server = $h | .password = ($pw | rtrimstr("\n")))' \
    "$ETC/config.template.json" > "$ETC/config.json.new" || exit 1
  if cmp -s "$ETC/config.json.new" "$ETC/config.json"; then rm -f "$ETC/config.json.new"
  else mv "$ETC/config.json.new" "$ETC/config.json"; running && /bin/launchctl kickstart -k system/$LABEL; fi
  was_on=no; running && was_on=yes
  [ "$was_on" = yes ] || /bin/launchctl bootstrap system "$PLIST"
  if tun_routed; then
    rm -f "$FAIL_FILE"
    [ "$was_on" = yes ] || note "TUN on via $HOST"
    STATE=proxied
  else
    note "TUN failed via $HOST: $PROBE routes via $(probe_if), sing-box log follows"
    /usr/bin/tail -n 20 "$VAR/sing-box.log" 2>/dev/null | /usr/bin/logger -t hotspot-tun
    echo "$HOST" > "$FAIL_FILE"
    tun_off
    MODE=normal
    STATE=route-failed
  fi
else
  rm -f "$FAIL_FILE"
  tun_off
  STATE=off
  HOST=
fi
write_status "$STATE" "$HOST"
# When hotspot mode flips, restart tailscaled so it picks up the right proxy env
MODE_FILE=$VAR/mode
if [ "$(cat $MODE_FILE 2>/dev/null)" != "$MODE" ]; then
  echo "$MODE" > $MODE_FILE
  note "mode $MODE"
  /bin/launchctl print system/local.hotspot-tun.tailscaled >/dev/null 2>&1 && /bin/launchctl kickstart -k system/local.hotspot-tun.tailscaled
fi
exit 0
