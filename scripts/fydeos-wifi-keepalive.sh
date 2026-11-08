#!/bin/bash
# ============================================================
# fydeos-wifi-keepalive.sh
#
# Fix: Broadcom BCM4360 (wl driver) on FydeOS / ChromeOS cannot see
#      or auto-connect to 5GHz networks.
#
# ROOT CAUSE
#   The `wl` driver advertises max_scan_ie_len = 0.
#   wpa_supplicant 2.11 always appends a 22-byte extra IE to its scan
#   request (Extended Capabilities + MBO/OCE). The kernel's
#   nl80211_trigger_scan() rejects this with -EINVAL because
#   ie_len > max_scan_ie_len.
#   Result: the supplicant's own scan never succeeds, so it never
#   learns any BSS, so shill never sees 5GHz APs and never
#   auto-connects to a saved 5GHz network.
#
# WHY THIS WORKS
#   `iw dev wlan0 scan` sends a scan request with ie_len = 0, which the
#   driver accepts. The scan succeeds, and the results land in the BSS
#   table that wpa_supplicant and shill both read from.
#   So all we have to do is keep feeding the supplicant with scan
#   results from `iw`. shill then finds the saved 5GHz profile and
#   connects on its own -- no need to patch wpa_supplicant, no need
#   for ap_scan=2, no need for oce=0.
#
# NOTES
#   - `iw` lives in /usr/sbin and `ip` in /bin. The minimal PATH during
#     early boot does NOT include /usr/sbin, so absolute paths are
#     mandatory here.
#   - Single instance enforced via a pidfile in /tmp.
#   - /usr/local is on the persistent partition, /tmp is not.
#
# ADAPT
#   Change IFACE below if your wireless interface is not wlan0.
# ============================================================

IFACE=wlan0
IW=/usr/sbin/iw
IP=/bin/ip
LOG=/mnt/stateful_partition/unencrypted/fydeos_persist/wifi-keepalive.log
PIDFILE=/tmp/fydeos-wifi-keepalive.pid

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# ---------- single instance ----------
if [ -f "$PIDFILE" ]; then
  OLD=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && exit 0
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

mkdir -p "$(dirname "$LOG")" 2>/dev/null

# log rotation
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 300000 ]; then
  mv -f "$LOG" "$LOG.1"
fi

log "=== keepalive start (pid $$) ==="

# ---------- phase 1: first 3 minutes, feed aggressively ----------
# Right after boot shill is still enumerating services, so scan often.
END=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "$END" ]; do
  "$IP" link set "$IFACE" up 2>/dev/null
  "$IW" dev "$IFACE" scan >/dev/null 2>&1
  A=$("$IP" -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}')
  [ -n "$A" ] && log "phase1 ok $IFACE=$A"
  sleep 15
done

# ---------- phase 2: steady state ----------
while :; do
  "$IP" link set "$IFACE" up 2>/dev/null
  "$IW" dev "$IFACE" scan >/dev/null 2>&1
  A=$("$IP" -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}')
  if [ -n "$A" ]; then
    log "steady ok $IFACE=$A"
    sleep 45
  else
    log "steady no-ip, retry"
    sleep 20
  fi
done
