#!/bin/bash
# ============================================================
# uninstall.sh -- revert everything install.sh did
#
#     sudo bash uninstall.sh
# ============================================================

set -u

HWT=/usr/share/hwtuner-script
BIN=/usr/local/bin

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }

# stop the feeder
for p in $(ps -eo pid,args | awk '$2 ~ /bash$/ && $3 == "/usr/local/bin/fydeos-wifi-keepalive.sh" {print $1}'); do
  echo "==> stopping feeder pid $p"
  kill "$p" 2>/dev/null
done
rm -f /tmp/fydeos-wifi-keepalive.pid

# restore hwtuner
if [ -f "$HWT/hwtuner.orig" ]; then
  echo "==> restoring original hwtuner"
  chattr -i "$HWT/hwtuner" 2>/dev/null
  mv -f "$HWT/hwtuner.orig" "$HWT/hwtuner"
  chmod 755 "$HWT/hwtuner"
else
  echo "==> no hwtuner.orig found, leaving hwtuner alone"
fi

# remove scripts
echo "==> removing /usr/local/bin scripts"
rm -f "$BIN/fydeos-wifi-keepalive.sh"
rm -f "$BIN/fydeos-sshd.sh"

echo "==> done. Reboot to fully clear."
echo "    (Logs left in /mnt/stateful_partition/unencrypted/fydeos_persist/)"
