#!/bin/bash
# ============================================================
# hwtuner wrapper -- the actual boot hook
#
# WHY THIS FILE
#   /etc/init is read-only on FydeOS, so you cannot add a normal
#   upstart/systemd unit. But the fydeos-collect-log job runs
#   `hwtuner --info` on every boot, and /usr/bin/hwtuner is a symlink
#   into /usr/share/hwtuner-script/, which IS writable.
#   Replacing that script with a wrapper gives us a reliable boot hook
#   that does not depend on anything in /etc.
#
#   The original binary is preserved as hwtuner.orig next to this file
#   and exec'd at the end, so normal behaviour is unaffected.
#
# CRITICAL: chattr +i
#   fydeos-scripts-updater runs on `shill-connected` and will overwrite
#   this file from a remote copy. You MUST run:
#       chattr +i /usr/share/hwtuner-script/hwtuner
#   Verify with `lsattr` -- it should show `----i---------e-------`.
#
# INSTALL
#   /usr/share/hwtuner-script/hwtuner        (this wrapper)
#   /usr/share/hwtuner-script/hwtuner.orig   (the original, renamed)
# ============================================================

# Directory holding hwtuner.orig (same dir as this script)
D=$(dirname "$(readlink -f "$0")")

# Bring up the WiFi feeder + sshd (idempotent)
if [ -x /usr/local/bin/fydeos-sshd.sh ]; then
  /bin/bash /usr/local/bin/fydeos-sshd.sh >/dev/null 2>&1
fi

# Hand off to the real hwtuner so nothing else breaks
if [ -x "$D/hwtuner.orig" ]; then
  exec /bin/bash "$D/hwtuner.orig" "$@"
fi
exit 0
