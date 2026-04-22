#!/bin/bash
#
# provision-arrow.sh — Configure ARROW-type 4G dongles via their stock web UI.
#
# ARROW is a ZTE-style "4G Modem" stock firmware (observed on UZ801 hardware
# at fwversion UZ801-V2.3.13) that exposes a JSON API at POST /ajax on
# http://192.168.100.1. We do NOT flash these — we configure them in place so
# they become SSID/PSK-compatible with the OpenStick-provisioned fleet (same
# GA-<IMEI-last-4> naming + HMAC-derived PSK) and get the Vodafone IoT APN.
#
# Scope vs. provision.sh (by design):
#   ✓ WiFi SSID      — GA-<IMEI-last-4>            (same scheme → Kibu compatible)
#   ✓ WiFi PSK       — HMAC(OPENSTICK_WIFI_SECRET, SSID) | head -c 16
#   ✓ APN            — from provision.conf (default: inetd.vodafone.iot)
#   ✓ Admin password — from .env ROOT_PASSWORD (instead of admin/admin)
#   ✗ Flash / SSH / NetBird / modem firmware / LED / RNDIS — N/A on ARROW
#
# Usage:
#   bash provision-arrow.sh                              # interactive (QR prompt)
#   bash provision-arrow.sh --qr-code SIM-WIN-00000001   # skip QR prompt
#   bash provision-arrow.sh --skip-admin-pwd             # leave admin/admin
#
# Prerequisites:
#   - .env with OPENSTICK_WIFI_SECRET + ROOT_PASSWORD
#   - provision.conf with APN
#   - ARROW plugged in (RNDIS iface gets 192.168.100.x/24 via DHCP)
#   - jq installed
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Load configuration ─────────────────────────────────────────────────────

[ -f "$SCRIPT_DIR/.env" ]            || err ".env not found."
[ -f "$SCRIPT_DIR/provision.conf" ]  || err "provision.conf not found."
source "$SCRIPT_DIR/.env"
source "$SCRIPT_DIR/provision.conf"

[ -n "$OPENSTICK_WIFI_SECRET" ] || err "OPENSTICK_WIFI_SECRET not set in .env"
[ -n "$APN" ]                   || err "APN not set in provision.conf"
which jq >/dev/null 2>&1        || err "jq not installed (apt install jq)"

# ARROW admin password policy: must be set and must not be a known-default.
# Keeps operators from accidentally leaving the UI reachable with 'admin/admin'
# or pushing the OpenStick SSH default ('openstick') to it.
: "${ARROW_ADMIN_PASSWORD:=}"
if [ -z "$ARROW_ADMIN_PASSWORD" ] || [ "$ARROW_ADMIN_PASSWORD" = "changeme-arrow" ]; then
    err "ARROW_ADMIN_PASSWORD not set (or still placeholder) in .env — required for ARROW provisioning."
fi
case "$ARROW_ADMIN_PASSWORD" in
    admin|openstick)
        err "ARROW_ADMIN_PASSWORD must not be 'admin' or 'openstick' — pick a real secret."
        ;;
esac

# ─── ARROW web API constants ────────────────────────────────────────────────
ARROW_IP="192.168.100.1"
ARROW_URL="http://${ARROW_IP}/ajax"
ARROW_DEFAULT_USER="admin"
ARROW_DEFAULT_PASS="admin"
# ZTE 4G Modem funcNo codes (reverse-engineered from /js/*.js)
FN_LOGIN=1000
FN_GET_WIFI=1006
FN_SET_SSID=1007
FN_GET_SEC=1009
FN_SET_SEC=1010
FN_GET_APN=1016
FN_SET_APN=1017
FN_ACT_APN=1018
FN_SET_ADMIN_PWD=1020
FN_WAN_STATUS=1002         # returns IP, mask, dns1, dns2, ssid, wlan_ip (LAN), IP (WAN)
FN_SIM_INFO=1015           # returns imsi, iccid, sim_status
FN_DEV_INFO=1029           # returns imei, fwversion, manufacture, dbm (signal)
# encryp_type=4 is WPA2-PSK in this UI (same as the stock default)
WPA2_PSK=4

# ─── LTE probe settings (overridable from provision.conf) ───────────────────
#
# The Vodafone IoT APN (inetd.vodafone.iot) enforces an **FQDN allow-list**:
# raw-IP ICMP/TCP to 8.8.8.8 is silently blackholed, so the classic `ping`
# probe gives false negatives on otherwise-working SIMs. We probe HTTPS to a
# whitelisted FQDN (same rationale as test-provision.sh on the OpenStick side).
#
# The probe is run THROUGH the ARROW: the USB iface binding + a /32 host route
# force just this one test request to egress via the ARROW's LTE, without
# touching the host's default route. The /32 is removed even on early exit.
LTE_PROBE_URL_ARROW="${LTE_PROBE_URL_ARROW:-${LTE_PROBE_URL:-https://ghcr.io/}}"

# ─── Logging setup (mirrors provision.sh: logs/provision_arrow_<imei>_<ts>.log) ─
# IMEI is read only after login, so we stage to a temp log and rename once
# we know it — that way an early failure (no dongle reachable) still leaves
# a file, just named with "unknown" as the IMEI.
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_TS=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/provision_arrow_unknown_${LOG_TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ─── Parse arguments ────────────────────────────────────────────────────────
QR_CODE=""
SKIP_ADMIN_PWD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --qr-code)         QR_CODE="$2"; shift 2 ;;
        --skip-admin-pwd)  SKIP_ADMIN_PWD=true; shift ;;
        *) err "Unknown option: $1" ;;
    esac
done

# ─── API helper ─────────────────────────────────────────────────────────────
# POST a JSON body to /ajax. Echoes raw response to stdout. Exit non-zero on
# network error. Response format:
#   {"results":[{...}],"error_info":"none","flag":"1"}
# flag=="1" means success; anything else is a failure.
CURL_COOKIE="$(mktemp -t arrow-cookies-XXXXXX)"
trap 'rm -f "$CURL_COOKIE"' EXIT

api_call() {
    local body="$1"
    curl -sS -m 15 \
        -c "$CURL_COOKIE" -b "$CURL_COOKIE" \
        -H 'Content-Type: application/json' \
        -H "Referer: http://${ARROW_IP}/" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "$body" "$ARROW_URL"
}

api_ok() {
    local resp="$1"
    # The ZTE firmware is inconsistent: success responses are JSON
    # ({"flag":"1",...}) but some failure responses are plain text
    # ("flag:0", 6 bytes). Parse JSON if it looks like JSON, otherwise
    # treat as failure without crashing jq.
    case "$resp" in
        '{'*) [ "$(echo "$resp" | jq -r '.flag // empty' 2>/dev/null)" = "1" ] ;;
        *)    return 1 ;;
    esac
}

# Wait until the web UI responds 200 again — used after writes that make the
# firmware restart LTE / hostapd (1007 set-SSID, 1010 set-pwd, 1017 set-APN,
# 1018 activate-APN). Without this, back-to-back writes race with the restart
# and the later one returns the plain-text "flag:0" failure.
wait_ui_ready() {
    local timeout="${1:-15}"  # seconds
    local i
    for i in $(seq 1 "$timeout"); do
        curl -sS -m 2 -o /dev/null "http://${ARROW_IP}/" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# Run a POST-style write with up to MAX_ATTEMPTS retries. If the first
# attempt comes back non-ok (common after the UI restarts hostapd/LTE),
# wait for the UI, sleep a beat, try again. Args: label, json_body.
# Echoes the final response to stdout, returns 0 on ok / 1 otherwise.
#
# Note: all diagnostic output inside MUST go to STDERR (>&2). Otherwise
# it contaminates the captured stdout and the caller sees our log lines
# in place of the server response — that bug 2026-04-22 had us chasing
# "flag:0" when the real response was a curl Connection-reset.
api_write_retry() {
    local label="$1" body="$2" resp
    local max_attempts=3
    local i
    for i in $(seq 1 "$max_attempts"); do
        resp=$(api_call "$body" 2>/dev/null)
        if api_ok "$resp"; then
            [ "$i" -gt 1 ] && log "  $label: succeeded on attempt $i" >&2
            echo "$resp"
            return 0
        fi
        if [ "$i" -lt "$max_attempts" ]; then
            log "  $label: attempt $i returned '${resp:-<empty>}' — waiting for UI + retrying" >&2
            wait_ui_ready 25 >&2 || true
            sleep 2
        fi
    done
    echo "$resp"
    return 1
}

# ─── LTE internet probe ─────────────────────────────────────────────────────
#
# Two-part check, in order:
#   (1) Ask the ARROW via funcNo:1002 whether it has a WAN IP distinct from
#       its LAN IP. No SIM / no attach → IP == wlan_ip == 192.168.100.1. When
#       LTE is really up, IP becomes the carrier-assigned address (10.x / 100.x
#       on Vodafone). This is cheap and doesn't send any traffic. If the
#       first attempt times out, we force a reattach by cycling the APN
#       profile (funcNo:1018 0→1) — this reliably un-sticks units that
#       detached from the carrier (e.g. Vodafone Active.Test idle timeout).
#   (2) Do a real HTTPS GET to LTE_PROBE_URL_ARROW bound to the ARROW's USB
#       interface, with a temporary /32 route so only this one IP goes through
#       the ARROW. Proves: DNS → TCP → TLS → cert validity → carrier ACL pass.
#
# Returns 0 on full success, 1 on LTE-not-attached, 2 on HTTPS failure.
# Arg 1: USB interface name (e.g. enx025304016362).

# wait_for_wan_ip TIMEOUT — poll funcNo:1002 until WAN IP != LAN IP, up to
# TIMEOUT seconds. Echoes the attached WAN IP on success. Returns 1 on
# timeout, 2 on a hard API error (status query failed).
wait_for_wan_ip() {
    local timeout="${1:-60}"
    local resp ip wlan_ip polled=0
    while :; do
        resp=$(api_call "$(jq -cn --argjson fn "$FN_WAN_STATUS" '{funcNo:$fn}')")
        api_ok "$resp" || return 2
        ip=$(echo "$resp"     | jq -r '.results[0].IP // empty')
        wlan_ip=$(echo "$resp"| jq -r '.results[0].wlan_ip // empty')
        if [ -n "$ip" ] && [ "$ip" != "$wlan_ip" ] && [ "$ip" != "192.168.100.1" ]; then
            echo "$ip"
            [ "$polled" -gt 0 ] && log "  (attach took ${polled}s)" >&2
            return 0
        fi
        [ "$polled" -ge "$timeout" ] && return 1
        [ "$polled" = 0 ] && log "  LTE probe: waiting for carrier attach (WAN IP)..." >&2
        sleep 3
        polled=$((polled + 3))
    done
}

# force_reattach — cycles the APN profile to force the modem to disconnect
# and re-attach to the carrier. This recovers units whose LTE session has
# been terminated by the carrier (e.g. Vodafone Active.Test idle timeout)
# — conn_mode=0 alone does not trigger auto-retry in this firmware.
force_reattach() {
    log "  Force re-attach: cycling APN profile (1018 0→1)..." >&2
    api_call "$(jq -cn --argjson fn "$FN_ACT_APN" --arg p "0" \
        '{funcNo:$fn, profile_num:$p}')" >/dev/null 2>&1
    sleep 5
    api_call "$(jq -cn --argjson fn "$FN_ACT_APN" --arg p "1" \
        '{funcNo:$fn, profile_num:$p}')" >/dev/null 2>&1
}

probe_lte() {
    local usb_iface="$1"
    local ip wlan_ip host probe_ip http_code
    local probe_host_port rc

    # (1a) First attempt — normal attach window.
    ip=$(wait_for_wan_ip 60); rc=$?
    if [ "$rc" -eq 2 ]; then
        warn "  LTE probe: status query failed"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        # No attach within 60s. Could be a stale carrier session from an
        # earlier provisioning — try forcing a re-attach, then poll again.
        warn "  LTE probe: no WAN IP after 60s — attempting force re-attach"
        force_reattach
        ip=$(wait_for_wan_ip 60); rc=$?
        if [ "$rc" -ne 0 ]; then
            warn "  LTE probe: still no WAN IP after force re-attach."
            warn "  Possible causes: no SIM / SIM not registered / APN wrong / Active.Test idle-barred."
            return 1
        fi
        log "  LTE probe: recovered via force re-attach"
    fi

    # Re-read LAN IP for the log line below.
    local resp=$(api_call "$(jq -cn --argjson fn "$FN_WAN_STATUS" '{funcNo:$fn}')")
    wlan_ip=$(echo "$resp" | jq -r '.results[0].wlan_ip // empty')
    log "  LTE probe: ARROW has WAN IP $ip (distinct from LAN $wlan_ip) ✓"

    # (2) Real HTTPS probe through the ARROW.
    host=$(echo "$LTE_PROBE_URL_ARROW" | awk -F/ '{print $3}' | cut -d: -f1)
    [ -n "$host" ] || { warn "  LTE probe: invalid URL $LTE_PROBE_URL_ARROW"; return 2; }

    # Resolve the probe host. We deliberately resolve on the PROVISIONING host
    # (not via the ARROW) because the ARROW has no on-device dig/nslookup. The
    # resulting IP is then forced via a /32 route through the ARROW so the
    # TCP handshake itself goes via LTE — proving carrier reachability to
    # exactly the IP a real Kibu would hit.
    probe_ip=$(getent ahosts "$host" 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ {print $1; exit}')
    [ -n "$probe_ip" ] || { warn "  LTE probe: DNS resolution of $host failed on host"; return 2; }

    # Temporary /32 route — cleaned up unconditionally, even on Ctrl-C.
    # We deliberately do NOT touch the default route: the host's normal
    # internet stays on WiFi throughout.
    log "  LTE probe: GET $LTE_PROBE_URL_ARROW (→ $probe_ip via $usb_iface/$ARROW_IP)"
    if ! sudo -n ip route replace "$probe_ip/32" via "$ARROW_IP" dev "$usb_iface" 2>/dev/null; then
        warn "  LTE probe: couldn't add /32 route (sudo not passwordless)."
        warn "            Real HTTPS probe skipped — LTE attach is confirmed via API only."
        warn "            Fix: drop this in /etc/sudoers.d/openstick-provisioner:"
        warn "              $USER ALL=(root) NOPASSWD: /usr/sbin/ip route replace *, /usr/sbin/ip route del *"
        return 3  # distinct exit code → caller sets status 'api_only'
    fi
    trap 'sudo -n ip route del '"$probe_ip"'/32 2>/dev/null || true' EXIT INT TERM

    probe_host_port="${host}:443:${probe_ip}"
    http_code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
        --interface "$usb_iface" \
        --resolve "$probe_host_port" \
        "$LTE_PROBE_URL_ARROW" 2>/dev/null || echo "000")

    sudo -n ip route del "$probe_ip/32" 2>/dev/null || true
    trap 'rm -f "$CURL_COOKIE"' EXIT  # restore original trap

    # Any HTTP response (even 401/403/404) proves the full chain worked.
    # Only 000 (curl failed) or 52/000-family indicates a carrier-level block.
    if [ "$http_code" = "000" ]; then
        warn "  LTE probe: curl failed reaching $host (HTTP 000). Probable APN ACL block or no LTE data."
        return 2
    fi
    log "  LTE probe: $host reachable via LTE (HTTP $http_code) ✓"
    return 0
}

# Find the USB interface the ARROW is on. NetworkManager names RNDIS
# interfaces enx<mac>. We pick whichever one currently has a 192.168.100.x IP.
find_arrow_iface() {
    ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.100\./ {print $2; exit}'
}

# ─── Step 0: Wait for ARROW on USB + DHCP + web UI ──────────────────────────
# Operator workflow:
#   1. Plug the ARROW into USB (SIM already inserted).
#   2. Run this script.
# The script waits for all three conditions in order:
#   a) A Qualcomm 05c6:f00e device appears in lsusb                 (USB enum)
#   b) An enx* interface gets an address on 192.168.100.0/24        (DHCP)
#   c) http://192.168.100.1/ responds 200                           (web UI ready)
# This lets the operator chain plug → run with no external polling.
log "=== Step 0: Waiting for ARROW ==="

WAIT_USB_TIMEOUT=30   # seconds — USB enumeration is near-instant; this only catches "not plugged in"
WAIT_DHCP_TIMEOUT=45  # seconds — RNDIS + NetworkManager DHCP round-trip can be slow on cold plug
WAIT_UI_TIMEOUT=30    # seconds — web UI comes up shortly after DHCP

# (a) USB enumeration
for i in $(seq 1 "$WAIT_USB_TIMEOUT"); do
    lsusb 2>/dev/null | grep -q '05c6:f00e' && break
    [ "$i" = "$WAIT_USB_TIMEOUT" ] && err "No ARROW on USB after ${WAIT_USB_TIMEOUT}s (expected Qualcomm 05c6:f00e). Plug in the dongle + re-run."
    sleep 1
done
log "  USB enumerated (05c6:f00e)"

# (b) DHCP lease on 192.168.100.0/24
for i in $(seq 1 "$WAIT_DHCP_TIMEOUT"); do
    iface=$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.100\./ {print $2; exit}')
    [ -n "$iface" ] && break
    [ "$i" = "$WAIT_DHCP_TIMEOUT" ] && err "No host interface on 192.168.100.0/24 after ${WAIT_DHCP_TIMEOUT}s. Check nmcli device show enx*"
    sleep 1
done
log "  DHCP lease on $iface"

# (c) Web UI responds
for i in $(seq 1 "$WAIT_UI_TIMEOUT"); do
    HTTP_CODE=$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://${ARROW_IP}/" 2>/dev/null || echo "000")
    [ "$HTTP_CODE" = "200" ] && break
    [ "$i" = "$WAIT_UI_TIMEOUT" ] && err "ARROW web UI at http://${ARROW_IP}/ not reachable after ${WAIT_UI_TIMEOUT}s (last HTTP $HTTP_CODE)"
    sleep 1
done
log "  Web UI reachable (HTTP 200)"

# ─── Step 1: QR code ────────────────────────────────────────────────────────
if [ -z "$QR_CODE" ]; then
    log "=== Step 1: QR Code ==="
    echo -ne "${GREEN}[+]${NC} Scan QR code (or type manually): "
    read -r QR_CODE
    QR_CODE=$(echo "$QR_CODE" | tr -d '[:space:]')
    [ -n "$QR_CODE" ] || err "No QR code provided."
fi
if ! echo "$QR_CODE" | grep -qE '^SIM-WIN-[0-9]{8}$'; then
    err "Invalid QR code format: '$QR_CODE' (expected SIM-WIN-XXXXXXXX)"
fi
log "  QR Code: $QR_CODE"

# ─── Step 2: Login ──────────────────────────────────────────────────────────
# Try the stock default first (admin/admin). If that fails, the unit may have
# already been provisioned — fall back to ROOT_PASSWORD so re-runs succeed.
log "=== Step 2: Login ==="

login_as() {
    local pwd="$1"
    api_call "$(jq -cn --arg u "$ARROW_DEFAULT_USER" --arg p "$pwd" \
        '{funcNo: 1000, username: $u, password: $p}')"
}

RESP=$(login_as "$ARROW_DEFAULT_PASS")
if api_ok "$RESP"; then
    LOGIN_PWD_USED="$ARROW_DEFAULT_PASS"
    log "  Login OK (default admin/admin — factory-fresh unit)"
else
    # Default failed — try ARROW_ADMIN_PASSWORD (unit already provisioned before).
    RESP=$(login_as "$ARROW_ADMIN_PASSWORD")
    if api_ok "$RESP"; then
        LOGIN_PWD_USED="$ARROW_ADMIN_PASSWORD"
        log "  Login OK (fleet ARROW_ADMIN_PASSWORD — unit already provisioned)"
    else
        err "Login failed with both admin/admin and ARROW_ADMIN_PASSWORD. Factory-reset the dongle."
    fi
fi

IMEI=$(echo "$RESP" | jq -r '.results[0].imei // empty')
FW=$(echo "$RESP" | jq -r '.results[0].fwversion // empty')
[ -n "$IMEI" ] && [ "$IMEI" != "null" ] || err "IMEI not returned by login"

# Rename log to the real IMEI now that we know it.
NEW_LOG="$LOG_DIR/provision_arrow_${IMEI}_${LOG_TS}.log"
mv "$LOG_FILE" "$NEW_LOG" 2>/dev/null && LOG_FILE="$NEW_LOG"

# ─── Step 3: Derive identifiers ─────────────────────────────────────────────
# Identical scheme to provision.sh so a Kibu paired with an OpenStick dongle
# pairs with an ARROW that has the same last-4 IMEI digits, no reconfiguration.
derive_wifi_psk() {
    local ssid="$1"
    echo -n "$ssid" | openssl dgst -sha256 -hmac "$OPENSTICK_WIFI_SECRET" \
        | awk '{print $NF}' | cut -c1-16
}
LAST4="${IMEI: -4}"
SSID="GA-${LAST4}"
PSK=$(derive_wifi_psk "$SSID")
HOSTNAME="ga-${LAST4}"
# brand = firmware/provisioning flavor. dongle_type = hardware variant.
# ARROW units are UZ801 hardware (fwversion string starts with "UZ801-")
# running vendor-shipped ZTE firmware, so we separate the two.
BRAND="ARROW"
DONGLE_TYPE="UZ801"
case "$FW" in
    UZ801*|uz801*)        DONGLE_TYPE="UZ801" ;;
    JZ0145*|jz01-45*)     DONGLE_TYPE="JZ0145-v33" ;;
esac

# SIM info — funcNo 1015 exposes IMSI + ICCID + sim_status. Matches what
# provision.sh gets from mmcli on the OpenStick side.
#
# Race seen in the field (2026-04-22, unit #6): on fast-attaching SIMs,
# 1015 returns {flag:"1", imsi:"", iccid:""} right after login — the SIM
# is present and about to work but the UI hasn't populated its fields yet.
# Poll up to ~20s for IMSI to appear, then give up and record what we have
# (no-SIM units legitimately return empty forever, so we can't wait longer).
IMSI=""; ICCID=""; SIM_STATUS="unknown"
for i in $(seq 1 10); do
    RESP=$(api_call "$(jq -cn --argjson fn "$FN_SIM_INFO" '{funcNo:$fn}')")
    if api_ok "$RESP"; then
        IMSI=$(echo       "$RESP" | jq -r '.results[0].imsi // empty')
        ICCID=$(echo      "$RESP" | jq -r '.results[0].iccid // empty')
        SIM_STATUS=$(echo "$RESP" | jq -r '.results[0].sim_status // empty')
    fi
    # Accept the result once we have either IMSI+ICCID, or a definitive
    # "Absent" status — otherwise retry. Empty-but-not-Absent = still populating.
    if [ -n "$IMSI" ] && [ -n "$ICCID" ]; then
        [ "$i" -gt 1 ] && log "  SIM info populated after ${i}x2s poll"
        break
    fi
    if [ "$SIM_STATUS" = "Absent" ]; then
        break
    fi
    sleep 2
done

# Signal + manufacturer — funcNo 1029 returns RSSI (dbm, informational only
# — not stored) and manufacturer string. Used to tell "ZTE/Qualcomm" ARROWs
# from OpenStick Qualcomm.
RESP=$(api_call "$(jq -cn --argjson fn "$FN_DEV_INFO" '{funcNo:$fn}')")
if api_ok "$RESP"; then
    MANUFACTURER=$(echo "$RESP" | jq -r '.results[0].manufacture // empty')
    SIGNAL_DBM=$(echo   "$RESP" | jq -r '.results[0].dbm // empty' | tr -d ' ')
else
    MANUFACTURER=""; SIGNAL_DBM=""
fi

# Sim operator = MCC+MNC. The OpenStick flow reads this from mmcli's
# `sim.properties.operator-code`. On the ZTE UI we derive it from the IMSI
# (first 5 chars = MCC(3) + MNC(2); 2-digit MNC is the common case). If the
# carrier uses a 3-digit MNC (rare for our fleet), the stored value will be
# slightly wrong but still lets us audit "which carrier is this on?". Leave
# empty if no SIM.
SIM_OPERATOR=""
if [ -n "$IMSI" ] && [ "${#IMSI}" -ge 5 ]; then
    SIM_OPERATOR="${IMSI:0:5}"
fi

log "=== Step 3: Device identification ==="
log "  IMEI:     $IMEI"
log "  IMSI:     ${IMSI:-<not available>}${SIM_OPERATOR:+ (MCC+MNC $SIM_OPERATOR)}"
log "  ICCID:    ${ICCID:-<not available>}"
log "  SIM:      ${SIM_STATUS:-unknown}"

# Policy (user-set 2026-04-22): provisioning requires a fully-identified
# SIM. If IMSI or ICCID is empty after the Step-3 poll, we can't write a
# meaningful fleet-tracking row, so fail fast before config writes.
if [ -z "$IMSI" ] || [ -z "$ICCID" ]; then
    err "SIM not fully identified (IMSI='${IMSI:-<empty>}', ICCID='${ICCID:-<empty>}', status='${SIM_STATUS:-unknown}').
  Likely causes: SIM not inserted, SIM card defective, or firmware read race.
  Fix: check the SIM is seated firmly + re-run. If it persists, the SIM
       may be faulty (swap in a known-good one and re-run)."
fi
log "  Firmware: $FW"
log "  Mfr:      ${MANUFACTURER:-unknown}"
log "  Signal:   ${SIGNAL_DBM:-unknown}"
log "  SSID:     $SSID"
log "  PSK:      $PSK"
log "  Brand:    $BRAND"
log "  Type:     $DONGLE_TYPE"

# ─── Step 3b: Duplicate check against DB ─────────────────────────────────────
# Belt-and-suspenders against operator error — warn if QR/IMSI/ICCID are
# already recorded against a DIFFERENT IMEI. Same IMEI is a normal
# re-provisioning (UPSERT handles it silently).
DUP_STATE="ok"
if [ -f "$SCRIPT_DIR/database.conf" ]; then
    # Source db.sh inside a subshell so its db_load_config doesn't leak
    # global DB_* variables until we actually want to write later.
    # Use `|| DUP_RC=$?` to prevent set -e from killing the script on a
    # soft rc=1 (SIM-moved warning is informational, not fatal).
    DUP_RC=0
    (
        source "$SCRIPT_DIR/db.sh"
        db_load_config >/dev/null 2>&1 || exit 99
        db_init >/dev/null 2>&1
        db_check_duplicates "$IMEI" "$QR_CODE" "$IMSI" "$ICCID"
    ) || DUP_RC=$?
    case "$DUP_RC" in
        0)  log "  DB duplicate check: no collisions" ;;
        1)  DUP_STATE="sim_moved"
            warn "  DB duplicate check: SIM already seen on a different dongle (see above) — proceeding." ;;
        2)  DUP_STATE="qr_collision"
            if [ -z "$FORCE_DUP" ]; then
                err "QR code already recorded for a different IMEI (see above).
  This is almost always an operator error (wrong QR scanned). If you
  really meant to overwrite, re-run with: FORCE_DUP=1 bash provision-arrow.sh ..."
            else
                warn "  DB duplicate check: QR collision — overriding (FORCE_DUP=1)"
            fi ;;
        99) log "  DB duplicate check: skipped (no database.conf)" ;;
        *)  warn "  DB duplicate check: unexpected rc=$DUP_RC — continuing" ;;
    esac
else
    log "  DB duplicate check: skipped (no database.conf)"
fi

# ─── Step 4: Apply configuration ────────────────────────────────────────────
# Order is deliberate:
#   1. SSID + PSK first (if session dies, user can still reach the AP)
#   2. APN profile + activate
#   3. Admin password LAST — after it changes, the current session is still
#      valid (the ZTE firmware doesn't invalidate on pwd change), but any
#      re-login afterwards must use the new password. Doing it last means all
#      previous calls used the same cookie.
#
# Every write is IDEMPOTENT: we read the current value first and skip the
# write if it already matches the target. This matters because the ZTE
# firmware is unstable when asked to overwrite a value with itself:
#   - set-wifi-pwd with the same PSK: request hangs for 8+s then times out,
#     and the firmware sometimes goes into a broken state requiring a power
#     cycle
#   - set-admin-pwd with new==old: returns "cannotSame" error
#   - set-apn / activate with same profile: occasionally hangs too
# Skipping no-op writes avoids all three failure modes and makes re-runs
# safe and fast.
log "=== Step 4: Configure ==="

# 4a. Read current WiFi SSID (need maxSta for the SSID write, and ssid so we
# can skip the write if it's already correct).
RESP=$(api_call "$(jq -cn --argjson fn "$FN_GET_WIFI" '{funcNo:$fn}')")
api_ok "$RESP" || err "get-wifi failed (response: $RESP)"
MAXSTA=$(echo "$RESP" | jq -r '.results[0].maxSta // 10')
CUR_SSID=$(echo "$RESP" | jq -r '.results[0].ssid // empty')
log "  Current SSID: $CUR_SSID (maxSta=$MAXSTA)"

# 4b. Set SSID (skip if already correct).
if [ "$CUR_SSID" = "$SSID" ]; then
    log "  SSID already correct: $SSID (skipping write)"
else
    RESP=$(api_write_retry "set-ssid" "$(jq -cn --argjson fn "$FN_SET_SSID" --arg s "$SSID" --argjson m "$MAXSTA" \
        '{funcNo:$fn, ssid:$s, maxSta:$m}')") || err "set-ssid failed (response: $RESP)"
    log "  SSID set: $SSID"
    # SSID changes restart hostapd — wait for the UI before the next write.
    wait_ui_ready 15 || warn "  UI didn't come back within 15s after SSID write"
fi

# 4c. Set WiFi password (WPA2-PSK). Skip if already correct — the firmware
# hangs on same-value writes here, so this isn't just an optimization.
RESP=$(api_call "$(jq -cn --argjson fn "$FN_GET_SEC" '{funcNo:$fn}')")
api_ok "$RESP" || err "get-wifi-pwd failed (response: $RESP)"
CUR_PSK=$(echo "$RESP"        | jq -r '.results[0].pwd // empty')
CUR_ENC=$(echo "$RESP"        | jq -r '.results[0].encryp_type // empty')
if [ "$CUR_PSK" = "$PSK" ] && [ "$CUR_ENC" = "$WPA2_PSK" ]; then
    log "  WiFi PSK already correct (WPA2-PSK + HMAC-derived) — skipping write"
else
    RESP=$(api_write_retry "set-wifi-pwd" "$(jq -cn --argjson fn "$FN_SET_SEC" --argjson et "$WPA2_PSK" --arg p "$PSK" \
        '{funcNo:$fn, encryp_type:$et, pwd:$p}')") || err "set-wifi-pwd failed (response: $RESP)"
    log "  WiFi PSK set (WPA2-PSK, 16-char HMAC-derived)"
    wait_ui_ready 15 || warn "  UI didn't come back within 15s after PSK write"
fi

# 4d. Write APN as profile 1. Skip if profile 1 already has the target APN
# + empty user/pwd + auth=0.
#
# IMPORTANT: the ZTE firmware is strict about field types — `no` and `auth`
# MUST be strings ("1", "0"), not numbers. The UI reads them from radio
# button IDs and option values, which are always strings. Sending numbers
# gets you a silent "flag:0" (literal text, not JSON).
APN_PROFILE=1
RESP=$(api_call "$(jq -cn --argjson fn "$FN_GET_APN" '{funcNo:$fn}')")
api_ok "$RESP" || err "get-apn failed (response: $RESP)"
CUR_APN_MATCH=$(echo "$RESP" | jq -r --arg p "$APN_PROFILE" --arg apn "$APN" \
    '.results[0].info_arr[] | select(.no == $p) |
     select(.apn == $apn and .user == "" and .pwd == "" and (.auth|tostring) == "0") |
     "match"' | head -1)
if [ "$CUR_APN_MATCH" = "match" ]; then
    log "  APN profile $APN_PROFILE already correct ($APN) — skipping write"
else
    RESP=$(api_write_retry "set-apn" "$(jq -cn --argjson fn "$FN_SET_APN" --arg no "$APN_PROFILE" \
        --arg name "fleet" --arg apn "$APN" --arg auth "0" \
        '{funcNo:$fn, no:$no, name:$name, apn:$apn, user:"", pwd:"", auth:$auth}')") || err "set-apn failed (response: $RESP)"
    log "  APN profile $APN_PROFILE written: $APN"

    # The firmware restarts the LTE subsystem after an APN profile write,
    # which makes the web API unresponsive for ~5-15s. Poll the UI until
    # it responds again before we fire the activate call — otherwise the
    # next api_call hits curl's 15s timeout and the script dies.
    log "  Waiting for UI to come back after APN write..."
    for i in $(seq 1 12); do
        sleep 2
        curl -sS -m 3 -o /dev/null "http://${ARROW_IP}/" 2>/dev/null && { log "  UI back after ${i}x2s"; break; }
    done
fi

# 4e. Activate the profile. Skip if already active. profile_num is a string
# in the UI — keep consistent.
# (RESP here is stale if we skipped the write above; re-read to be sure.)
RESP=$(api_call "$(jq -cn --argjson fn "$FN_GET_APN" '{funcNo:$fn}')")
CUR_ACTIVE=$(echo "$RESP" | jq -r '.results[0].profile_num // empty')
if [ "$CUR_ACTIVE" = "$APN_PROFILE" ]; then
    log "  APN profile $APN_PROFILE already active — skipping activate"
else
    RESP=$(api_write_retry "activate-apn" "$(jq -cn --argjson fn "$FN_ACT_APN" --arg p "$APN_PROFILE" \
        '{funcNo:$fn, profile_num:$p}')") || err "activate-apn failed (response: $RESP)"
    log "  APN profile $APN_PROFILE activated"
    wait_ui_ready 15 || warn "  UI didn't come back within 15s after APN activate"
fi

# 4f. Change admin password (optional via --skip-admin-pwd).
if $SKIP_ADMIN_PWD; then
    warn "  Admin password: left unchanged (--skip-admin-pwd)"
elif [ "$LOGIN_PWD_USED" = "$ARROW_ADMIN_PASSWORD" ]; then
    log "  Admin password: already matches fleet value (skipping)"
else
    RESP=$(api_write_retry "set-admin-pwd" "$(jq -cn --argjson fn "$FN_SET_ADMIN_PWD" \
        --arg old "$LOGIN_PWD_USED" --arg new "$ARROW_ADMIN_PASSWORD" \
        '{funcNo:$fn, oldpwd:$old, newpwd:$new}')") || err "set-admin-pwd failed (response: $RESP)"
    log "  Admin password changed (admin/admin → ARROW_ADMIN_PASSWORD)"
fi

# ─── Step 5: Verify (read back + compare) ───────────────────────────────────
log "=== Step 5: Verify ==="
VERIFY_FAIL=0

RESP=$(api_call "$(jq -cn --argjson fn "$FN_GET_WIFI" '{funcNo:$fn}')")
READ_SSID=$(echo "$RESP" | jq -r '.results[0].ssid // empty')
if [ "$READ_SSID" = "$SSID" ]; then
    log "  SSID:  $READ_SSID ✓"
else
    warn "  SSID:  got '$READ_SSID', expected '$SSID'"
    VERIFY_FAIL=1
fi

RESP=$(api_call "$(jq -cn --argjson fn "$FN_GET_SEC" '{funcNo:$fn}')")
READ_PWD=$(echo "$RESP" | jq -r '.results[0].pwd // empty')
if [ "$READ_PWD" = "$PSK" ]; then
    log "  PSK:   matches ✓"
else
    warn "  PSK:   mismatch (got '$READ_PWD')"
    VERIFY_FAIL=1
fi

RESP=$(api_call "$(jq -cn --argjson fn "$FN_GET_APN" '{funcNo:$fn}')")
READ_APN=$(echo "$RESP" | jq -r --argjson p "$APN_PROFILE" \
    '.results[0].info_arr[] | select((.no|tonumber) == $p) | .apn' | head -1)
READ_ACTIVE=$(echo "$RESP" | jq -r '.results[0].profile_num // empty')
if [ "$READ_APN" = "$APN" ] && [ "$READ_ACTIVE" = "$APN_PROFILE" ]; then
    log "  APN:   $READ_APN (active profile=$READ_ACTIVE) ✓"
else
    warn "  APN:   got '$READ_APN' (active=$READ_ACTIVE), expected '$APN' (active=$APN_PROFILE)"
    VERIFY_FAIL=1
fi

# ─── Step 5b: LTE internet probe (real traffic through the ARROW) ───────────
# Config verification above proved the ARROW accepted our settings. This
# proves LTE actually carries traffic — the Vodafone IoT APN only allows
# whitelisted FQDNs, so a successful HTTPS hit confirms DNS+TCP+TLS+ACL.
log "=== Step 5b: LTE internet probe ==="
ARROW_IFACE=$(find_arrow_iface)
LTE_PROBE_STATUS="not_attempted"
if [ -z "$ARROW_IFACE" ]; then
    warn "  No host interface on 192.168.100.0/24 — can't probe. Skipping."
    LTE_PROBE_STATUS="skipped_no_iface"
else
    log "  USB interface: $ARROW_IFACE"
    if probe_lte "$ARROW_IFACE"; then
        LTE_PROBE_STATUS="ok_verified"
    else
        case $? in
            1) LTE_PROBE_STATUS="no_wan_ip" ;;
            2) LTE_PROBE_STATUS="https_failed" ;;
            3) LTE_PROBE_STATUS="ok_api_only"
               log "  LTE: API reports up, real probe skipped (no sudo cache)" ;;
            *) LTE_PROBE_STATUS="unknown" ;;
        esac
        # Policy (set by user 2026-04-22): a run that can't verify end-to-end
        # carrier reachability is a FAILURE, not a warning. Even `ok_api_only`
        # counts as fail — the sudoers rule is installed in the fleet setup,
        # so api-only only happens on a misconfigured host and shouldn't be
        # quietly accepted. This forces us to catch real issues (bad APN,
        # dead SIM, ACL change) before the device leaves the bench.
        VERIFY_FAIL=1
        warn "  LTE probe status '$LTE_PROBE_STATUS' → marking run as FAILED."
    fi
fi

# ─── Step 6: Record to database ─────────────────────────────────────────────
# Same db_record_device / db_record_parked contract as provision.sh.
# Columns specific to OpenStick (hwid/msm_id/emmc/dt_*/imsi/sim_operator/
# phone_number/netbird_*) are left empty — the ZTE UI doesn't expose them.
log "=== Step 6: Record to DB ==="
DB_STATUS="skipped"
source "$SCRIPT_DIR/db.sh"
if db_load_config; then
    db_init || warn "DB init failed"
    if [ "$VERIFY_FAIL" -eq 0 ]; then
        # Column layout (matches db.sh::db_record_device signature):
        #   imei, serial, qr_code, fw_version, phone, nb_ip, nb_hostname,
        #   hostname, dongle_type, hwid, msm_id, emmc_sectors, dt_model,
        #   dt_compatible, imsi, sim_operator
        # ARROW has no serial/phone/NetBird/HWID/MSM/eMMC/DT access via the
        # web UI — those stay empty. IMSI + sim_operator come from funcNo 1015.
        if db_record_device "$IMEI" "" "$QR_CODE" "ARROW:${FW:-unknown}" \
               "" "" "" "$HOSTNAME" "$DONGLE_TYPE" \
               "" "" "0" "" "" "$IMSI" "$SIM_OPERATOR" "$ICCID" "$BRAND"; then
            DB_STATUS="recorded"
        else
            DB_STATUS="failed"
        fi
    else
        # Distinguish "config didn't stick" from "LTE didn't come up" — the
        # two failure modes need different operator action:
        #   config_fail → firmware rejected a write (re-run fixes most)
        #   lte_fail    → SIM / APN / ACL / carrier — needs SIM or APN review
        local parked_reason parked_detail
        case "${LTE_PROBE_STATUS:-}" in
            ok_verified|"")
                parked_reason="parked_arrow_config_fail"
                parked_detail="verify mismatch on SSID/PSK/APN"
                ;;
            *)
                parked_reason="parked_arrow_lte_fail"
                parked_detail="LTE probe: $LTE_PROBE_STATUS"
                ;;
        esac
        if db_record_parked "$IMEI" "" "$QR_CODE" "$DONGLE_TYPE" \
               "$IMSI" "$SIM_OPERATOR" \
               "$parked_reason" "$parked_detail" \
               "$ICCID" "$BRAND"; then
            DB_STATUS="parked ($parked_reason)"
        else
            DB_STATUS="failed (parked write)"
        fi
    fi
else
    DB_STATUS="no config"
fi
[ "$DB_STATUS" = "recorded" ] && log "  DB: device recorded" || warn "  DB: $DB_STATUS"

# ─── Final summary ──────────────────────────────────────────────────────────
echo ""
if [ "$VERIFY_FAIL" -eq 0 ]; then
    log "═══════════════════════════════════════"
    log "  ARROW provisioning complete — $QR_CODE"
    log "  IMEI:      $IMEI"
    log "  Firmware:  $FW"
    log "  Type:      $DONGLE_TYPE"
    log "  QR Code:   $QR_CODE"
    log "  WiFi:      $SSID / $PSK"
    log "  APN:       $APN (profile $APN_PROFILE)"
    log "  Admin pwd: $($SKIP_ADMIN_PWD && echo unchanged || echo 'set to fleet value')"
    log "  IMSI:      ${IMSI:-unknown}${SIM_OPERATOR:+ (MCC+MNC $SIM_OPERATOR)}"
    log "  ICCID:     ${ICCID:-unknown}"
    log "  Signal:    ${SIGNAL_DBM:-unknown}  Mfr: ${MANUFACTURER:-unknown}"
    log "  LTE:       $LTE_PROBE_STATUS"
    log "  DB:        $DB_STATUS"
    log "  Log:       $LOG_FILE"
    log "═══════════════════════════════════════"
    exit 0
else
    warn "═══════════════════════════════════════"
    warn "  ARROW provisioning FAILED verification"
    warn "  IMEI:   $IMEI"
    warn "  DB:     $DB_STATUS (parked)"
    warn "  Log:    $LOG_FILE"
    warn "═══════════════════════════════════════"
    exit 1
fi
