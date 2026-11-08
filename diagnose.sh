#!/bin/bash
# ============================================================
# diagnose.sh -- read-only check of the 5GHz problem
#
# Confirms whether your machine actually has the max_scan_ie_len=0
# problem before you install anything. Changes nothing.
#
#     sudo bash diagnose.sh
# ============================================================

IFACE=${1:-wlan0}
IW=/usr/sbin/iw
IP=/bin/ip

hr(){ echo "------------------------------------------------------------"; }

echo "MacBook WiFi / 5GHz diagnostic"
echo "interface: $IFACE"
hr

# ---------- 1. hardware + driver ----------
echo "[1] hardware / driver"
if [ -d "/sys/class/net/$IFACE" ]; then
  echo "    driver   : $(basename "$(readlink -f /sys/class/net/$IFACE/device/driver 2>/dev/null)")"
  echo "    modalias : $(cat /sys/class/net/$IFACE/device/modalias 2>/dev/null)"
  echo "    mac      : $(cat /sys/class/net/$IFACE/address 2>/dev/null)"
else
  echo "    !! $IFACE not found"
fi
hr

# ---------- 2. the smoking gun ----------
echo "[2] scan IE limits  <-- the important part"
for f in max_scan_ie_len max_sched_scan_ie_len; do
  p="/sys/class/net/$IFACE/device/$f"
  if [ -e "$p" ]; then
    v=$(cat "$p" 2>/dev/null)
    printf "    %-22s = %s" "$f" "$v"
    [ "$v" = "0" ] && echo "   <-- THIS IS THE BUG" || echo
  fi
done
# Some drivers expose it only through debugfs / iw
echo "    (if both are 0, wpa_supplicant's scan requests will be rejected)"
hr

# ---------- 3. does iw scan work? ----------
echo "[3] can iw scan?  (iw sends ie_len=0)"
$IP link set "$IFACE" up 2>/dev/null
sleep 1
$IW dev "$IFACE" scan > /tmp/iwscan.txt 2>/tmp/iwscan.err
RC=$?
echo "    iw rc = $RC"
if [ "$RC" -eq 0 ]; then
  echo "    BSS found        : $(grep -c '^BSS' /tmp/iwscan.txt 2>/dev/null)"
  echo "    5GHz BSS found   : $(grep -oE 'freq: [0-9]+' /tmp/iwscan.txt 2>/dev/null | awk '{if($2>=4900) c++} END{print c+0}')"
  echo "    distinct SSIDs   : $(grep -E '^[[:space:]]+SSID:' /tmp/iwscan.txt 2>/dev/null | sed 's/^[[:space:]]*//' | sort -u | wc -l)"
  echo
  echo "    5GHz frequencies seen:"
  grep -oE 'freq: [0-9]+' /tmp/iwscan.txt 2>/dev/null | awk '{if($2>=4900) print "      "$2}' | sort -un | head -20
else
  echo "    iw scan FAILED -- this is a different problem:"
  head -3 /tmp/iwscan.err 2>/dev/null | sed 's/^/      /'
fi
hr

# ---------- 4. supplicant view ----------
echo "[4] wpa_supplicant's own BSS table"
if command -v wpa_cli >/dev/null 2>&1; then
  N=$(timeout -k 2 10 wpa_cli -i "$IFACE" -p /run/wpa_supplicant scan_results 2>/dev/null | grep -c $'\t')
  echo "    scan_results entries : ${N:-0}"
  [ "${N:-0}" -eq 0 ] && echo "    (0 entries while iw found APs == the bug is confirmed)"
else
  echo "    wpa_cli not available, skipped"
fi
hr

# ---------- 5. shill view ----------
echo "[5] shill services (what the UI shows)"
if command -v gdbus >/dev/null 2>&1; then
  timeout -k 2 15 gdbus call --system \
    --dest org.chromium.flimflam --object-path / \
    --method org.chromium.flimflam.Manager.GetServices 2>/dev/null \
    | tr ',' '\n' | grep -oE "/service/[0-9]+" | wc -l \
    | sed 's/^/    service objects: /'
else
  echo "    gdbus not available, skipped"
fi
hr

echo "Interpretation:"
echo "  max_scan_ie_len = 0  AND  iw scan works  AND  supplicant sees 0"
echo "  => you have this exact bug. Run install.sh."
echo
echo "  If max_scan_ie_len is not 0, this fix does not apply to you."
