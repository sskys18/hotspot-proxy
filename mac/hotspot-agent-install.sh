#!/bin/bash
# Called by the login agent through passwordless sudo after a reboot drops the root jobs.
# Never prompts and never touches the saved proxy password.
set -euo pipefail
[ -s /usr/local/etc/hotspot-tun/secret ] || exit 1
[ -x /usr/local/libexec/hotspot-tun.sh ] || exit 1
[ -f /Library/LaunchDaemons/local.hotspot-tun.watch.plist ] || exit 1
launchctl bootout system/local.hotspot-tun.watch 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.hotspot-tun.watch.plist
