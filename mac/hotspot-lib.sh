# Shared by hotspot-tun.sh and tailscaled-wrapper.sh (sourced, root only).
SECRET=/usr/local/etc/hotspot-tun/secret
PORT=8080
wifi_dev() { /usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '/Hardware Port: Wi-Fi/{getline; print $2}'; }
# Possible phone addresses on Wi-Fi: the IPv4 hotspot gateway (IPv4 hotspots) and the Wi-Fi IPv6
# default router (IPv6-only hotspots, link-local with zone, e.g. fe80::1%en0).
candidates() {
  local dev; dev=$(wifi_dev)
  /sbin/ifconfig "$dev" 2>/dev/null | grep -q "inet 172\.20\.10\." && echo 172.20.10.1
  /usr/sbin/ndp -rn | /usr/bin/awk -v d="if=$dev," '$2 == d && $1 ~ /^fe80::/ {print $1}'
}
# URL host form: 172.20.10.1 or [fe80::1%25en0]
url_host() { case "$1" in *:*) echo "[${1/\%/%25}]";; *) echo "$1";; esac; }
# True only if $1 proves it knows our password (HMAC over a fresh nonce), so a stranger's
# iPhone hotspot never receives our traffic or credentials. The key is read from the file, never argv.
verified() {
  [ -r "$SECRET" ] || return 1
  local n got want
  n=$(/usr/bin/openssl rand -hex 16) || return 1
  got=$(/usr/bin/curl -fs --noproxy '*' --max-time 3 "http://$(url_host "$1"):$PORT/hotspot-proxy/identify?n=$n") || return 1
  # System perl (core Digest::SHA); /usr/bin/python3 is an xcrun shim that stalls for root under launchd.
  want=$(/usr/bin/perl -MDigest::SHA=hmac_sha256_hex -e 'open my $f, "<", $ARGV[0] or exit 1; my $k = <$f>; chomp $k; print hmac_sha256_hex("hotspot-proxy-identify:$ARGV[1]", $k)' "$SECRET" "$n") || return 1
  [ -n "$got" ] && [ "$got" = "$want" ]
}
# True only if the phone can reach the internet on our behalf. Identity alone is not enough: a phone
# whose app cannot get out answers identify but rejects every request (SOCKS code 5), and turning the
# TUN on then takes the whole Mac offline. Credentials go to curl on stdin, never argv.
egress_ok() {
  [ -r "$SECRET" ] || return 1
  local got
  got=$(printf 'proxy-user = "hotspot:%s"\n' "$(tr -d '\n' < "$SECRET")" | /usr/bin/curl -fs -K - --noproxy '' --max-time 8 \
    --proxy "socks5h://$(url_host "$1"):$PORT" http://captive.apple.com/hotspot-detect.html) || return 1
  case "$got" in *Success*) return 0;; esac
  return 1
}
# Prints the verified phone address, or fails when we are not on our own hotspot.
find_proxy() {
  local h
  for h in $(candidates); do verified "$h" && { echo "$h"; return 0; }; done
  return 1
}
