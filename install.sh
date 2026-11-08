#!/bin/bash
# ============================================================
# install.sh -- one-shot installer for the 5GHz fix
#
# Run as root on the FydeOS machine, from the directory that contains
# this repo's scripts/ folder:
#
#     cd /path/to/repo
#     sudo bash install.sh
#
# What it does:
#   1. copies the WiFi scan feeder to /usr/local/bin
#   2. copies the boot hook entry point to /usr/local/bin
#   3. installs the hwtuner wrapper + renames the original
#   4. locks the wrapper with chattr +i so the updater can't clobber it
#   5. starts the feeder immediately (no reboot needed)
#
# Uninstall: see uninstall.sh
# ============================================================

set -u

SRC=$(cd "$(dirname "$0")" && pwd)
HWT=/usr/share/hwtuner-script
BIN=/usr/local/bin

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }

echo "==> source: $SRC"

# ---------- sanity checks ----------
if [ ! -d "$HWT" ]; then
  echo "!! $HWT not found -- this does not look like FydeOS"; exit 1
fi
if [ ! -x /usr/sbin/iw ]; then
  echo "!! /usr/sbin/iw missing -- install iw first"; exit 1
fi

# ---------- 1+2: scripts into /usr/local/bin ----------
echo "==> installing /usr/local/bin/fydeos-wifi-keepalive.sh"
cp -f "$SRC/scripts/fydeos-wifi-keepalive.sh" "$BIN/fydeos-wifi-keepalive.sh"
chmod 755 "$BIN/fydeos-wifi-keepalive.sh"

echo "==> installing /usr/local/bin/fydeos-sshd.sh"
cp -f "$SRC/scripts/fydeos-sshd.sh" "$BIN/fydeos-sshd.sh"
chmod 755 "$BIN/fydeos-sshd.sh"

# ---------- 3: hwtuner wrapper ----------
chattr -i "$HWT/hwtuner" 2>/dev/null

if [ -f "$HWT/hwtuner" ] && [ ! -f "$HWT/hwtuner.orig" ]; then
  # First install: the current hwtuner is the original -> preserve it
  echo "==> preserving original hwtuner as hwtuner.orig"
  cp -a "$HWT/hwtuner" "$HWT/hwtuner.orig"
fi

echo "==> installing hwtuner wrapper"
cp -f "$SRC/scripts/hwtuner-wrapper.sh" "$HWT/hwtuner"
chmod 755 "$HWT/hwtuner"

# ---------- 4: lock it ----------
echo "==> locking wrapper with chattr +i"
chattr +i "$HWT/hwtuner" 2>/dev/null
lsattr "$HWT/hwtuner"

# ---------- 5: start now ----------
echo "==> starting WiFi feeder"
if [ -x "$BIN/fydeos-wifi-keepalive.sh" ]; then
  /usr/bin/setsid /bin/bash "$BIN/fydeos-wifi-keepalive.sh" \
    >/dev/null 2>&1 < /dev/null &
fi

sleep 3
echo
echo "==> done. feeder status:"
ps -eo pid,args | grep -E "[f]ydeos-wifi-keepalive" || echo "  (not running?)"
echo
echo "==> log: /mnt/stateful_partition/unencrypted/fydeos_persist/wifi-keepalive.log"
echo "==> reboot to confirm it survives."
