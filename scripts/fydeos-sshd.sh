#!/bin/bash
# ============================================================
# fydeos-sshd.sh
#
# Boot hook entry point. Brings up:
#   1. the WiFi scan feeder (5GHz fix)
#   2. sshd, so the machine is reachable over the network
#
# Everything here is idempotent: each step guards itself with a pidfile
# or pgrep, so this script is safe to run repeatedly.
#
# INSTALL
#   /usr/local/bin/fydeos-sshd.sh          (persistent: /usr/local is on
#                                           the stateful partition)
#
# CALLED BY
#   The hwtuner wrapper, which is invoked at boot by the
#   fydeos-collect-log job. See hwtuner-wrapper.sh and README.
# ============================================================

SD=/mnt/stateful_partition/etc/ssh
CFG=$SD/sshd_config
LOG=/mnt/stateful_partition/unencrypted/fydeos_persist/sshd.log
PDIR=/mnt/stateful_partition/unencrypted/fydeos_persist
mkdir -p "$PDIR" 2>/dev/null

echo "--- $(date '+%F %T') attempt ---" >> "$LOG"

# === 1. WiFi scan feeder for 5GHz (BCM4360 / wl) ===
# Self-guarded by its own pidfile.
if [ -x /usr/local/bin/fydeos-wifi-keepalive.sh ]; then
  /usr/bin/setsid /bin/bash /usr/local/bin/fydeos-wifi-keepalive.sh \
    >/dev/null 2>&1 < /dev/null &
  echo "wifi-keepalive spawned" >> "$LOG"
fi

# === 2. sshd ===
if [ ! -f "$CFG" ]; then
  echo "no ssh config, skip sshd" >> "$LOG"
  exit 0
fi

# /var is a tmpfs, so the privilege-separation directory has to be
# recreated on every boot.
if [ ! -d /var/empty ]; then
  mkdir -p /var/empty 2>>"$LOG" || echo "mkdir /var/empty FAILED" >> "$LOG"
fi
chown root:root /var/empty 2>>"$LOG"
chmod 755 /var/empty 2>>"$LOG"

if pgrep -x sshd >/dev/null 2>&1; then
  echo "sshd already running" >> "$LOG"
  exit 0
fi

/usr/sbin/sshd -f "$CFG" 2>>"$LOG"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "sshd FAILED rc=$RC" >> "$LOG"
  exit "$RC"
fi

iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>>"$LOG"

echo "sshd started pid=$(pgrep -x sshd | head -1)" >> "$LOG"
