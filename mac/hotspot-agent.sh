#!/bin/bash
# User LaunchAgent. Runs at every login, on network changes, and every 30 seconds.
# The root watcher does the TUN work. This only puts that watcher back if a reboot dropped it.
set -uo pipefail
LABEL=local.hotspot-tun.watch
/bin/launchctl print "system/$LABEL" >/dev/null 2>&1 && exit 0
/usr/bin/sudo -n /bin/launchctl print "system/$LABEL" >/dev/null 2>&1 && exit 0
/usr/bin/sudo -n /usr/local/libexec/hotspot-agent-install.sh || exit 0
