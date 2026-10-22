#!/bin/bash
# tailscaled binds directly to the physical interface (en0), bypassing the TUN,
# so on our hotspot we pass the phone proxy via env to route control/DERP (HTTPS) through it.
. /usr/local/libexec/hotspot-lib.sh
if HOST=$(find_proxy); then
  url="http://hotspot:$(tr -d '\n' < "$SECRET")@$(url_host "$HOST"):$PORT"
  export HTTPS_PROXY=$url HTTP_PROXY=$url
fi
exec /opt/homebrew/bin/tailscaled
