#!/bin/bash
#
# arrow-check-all.sh — Batch LTE-attach check + recovery over every ARROW
# currently reachable on 192.168.100.0/24.
#
# Use case: after plugging N ARROWs into a USB hub, verify each one's LTE
# session is alive, and force-reattach any that detached (e.g. after a
# Vodafone Active.Test idle timeout).
#
# Runs in parallel (one job per interface) — a detach + re-attach cycle
# takes ~35s per unit, so 14 units ≈ 40s total instead of ~8 min sequential.
#
# Requires:
#   - .env with ARROW_ADMIN_PASSWORD
#   - NetworkManager `dongle-local` profile with connection.multi-connect=multiple
#     so every enx* gets its own 192.168.100.x lease (see README)
#   - jq, curl
#
# Usage:
#   bash arrow-check-all.sh                # check + revive any offline
#   bash arrow-check-all.sh --check-only   # check, don't revive
#   bash arrow-check-all.sh --force-cycle  # always cycle, even units that look online

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

[ -f "$SCRIPT_DIR/.env" ] || err ".env not found."
source "$SCRIPT_DIR/.env"
: "${ARROW_ADMIN_PASSWORD:=}"
[ -n "$ARROW_ADMIN_PASSWORD" ] || err "ARROW_ADMIN_PASSWORD not set in .env."
which jq >/dev/null 2>&1 || err "jq not installed."

CHECK_ONLY=false
FORCE_CYCLE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only)  CHECK_ONLY=true; shift ;;
        --force-cycle) FORCE_CYCLE=true; shift ;;
        *) err "Unknown option: $1" ;;
    esac
done

# ─── per-interface worker ────────────────────────────────────────────────────
# Writes one result line to stdout: "<status> <ssid> <imei> <wan_ip> <dbm>"
# Appends a recovery entry to the per-IMEI log iff we actually cycled.
check_one() {
    local iface="$1"
    local jar status ssid imei wan_ip lan_ip dbm cycled=no
    jar=$(mktemp -t arrow-check-XXXXXX)

    # Login — try fleet password first, fall back to factory admin/admin.
    local login
    login=$(curl -sS -m 5 --interface "$iface" -c "$jar" \
        -H 'Content-Type: application/json' -H "Referer: http://192.168.100.1/" \
        -d "{\"funcNo\":1000,\"username\":\"admin\",\"password\":\"$ARROW_ADMIN_PASSWORD\"}" \
        http://192.168.100.1/ajax 2>/dev/null)
    if ! echo "$login" | grep -q '"flag":"1"'; then
        login=$(curl -sS -m 5 --interface "$iface" -c "$jar" \
            -H 'Content-Type: application/json' -H "Referer: http://192.168.100.1/" \
            -d '{"funcNo":1000,"username":"admin","password":"admin"}' \
            http://192.168.100.1/ajax 2>/dev/null)
    fi
    if ! echo "$login" | grep -q '"flag":"1"'; then
        printf 'LOGIN_FAIL  -          -                 -                 -      %s\n' "$iface"
        rm -f "$jar"; return
    fi
    imei=$(echo "$login" | jq -r '.results[0].imei // "?"')

    check_wan() {
        local r
        r=$(curl -sS -m 5 --interface "$iface" -b "$jar" \
            -H 'Content-Type: application/json' -H "Referer: http://192.168.100.1/" \
            -d '{"funcNo":1002}' http://192.168.100.1/ajax 2>/dev/null)
        wan_ip=$(echo "$r" | jq -r '.results[0].IP // "?"')
        lan_ip=$(echo "$r" | jq -r '.results[0].wlan_ip // "?"')
        ssid=$(echo "$r" | jq -r '.results[0].ssid // "?"')
    }
    check_wan

    local attached=false
    if [ "$wan_ip" != "$lan_ip" ] && [ "$wan_ip" != "192.168.100.1" ] && [ -n "$wan_ip" ] && [ "$wan_ip" != "?" ]; then
        attached=true
    fi

    if [ "$attached" = false ] || [ "$FORCE_CYCLE" = true ]; then
        if [ "$CHECK_ONLY" = true ]; then
            status="OFFLINE"
        else
            # Force re-attach cycle (funcNo:1018 profile 0 → sleep 5 → profile 1)
            curl -sS -m 8 --interface "$iface" -b "$jar" \
                -H 'Content-Type: application/json' -H "Referer: http://192.168.100.1/" \
                -d '{"funcNo":1018,"profile_num":"0"}' http://192.168.100.1/ajax >/dev/null 2>&1
            sleep 5
            curl -sS -m 8 --interface "$iface" -b "$jar" \
                -H 'Content-Type: application/json' -H "Referer: http://192.168.100.1/" \
                -d '{"funcNo":1018,"profile_num":"1"}' http://192.168.100.1/ajax >/dev/null 2>&1
            cycled=yes
            # poll for WAN IP up to 60s
            for i in $(seq 1 20); do
                sleep 3
                check_wan
                if [ "$wan_ip" != "$lan_ip" ] && [ "$wan_ip" != "192.168.100.1" ] && [ -n "$wan_ip" ] && [ "$wan_ip" != "?" ]; then
                    attached=true
                    break
                fi
            done
            status=$([ "$attached" = true ] && echo "RECOVERED" || echo "OFFLINE")
        fi
    else
        status="ONLINE"
    fi

    # Always read signal (once, after any recovery cycle)
    local dev
    dev=$(curl -sS -m 5 --interface "$iface" -b "$jar" \
        -H 'Content-Type: application/json' -H "Referer: http://192.168.100.1/" \
        -d '{"funcNo":1029}' http://192.168.100.1/ajax 2>/dev/null)
    dbm=$(echo "$dev" | jq -r '.results[0].dbm // ""' | tr -d ' ')

    # Log the recovery iff we actually did one and got a WAN IP
    if [ "$cycled" = yes ]; then
        local ts log_file
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        log_file=$(ls -t "${LOG_DIR}/provision_arrow_${imei}_"*.log 2>/dev/null | head -1)
        if [ -n "$log_file" ]; then
            {
                echo ""
                echo "[+] ═══════════════════════════════════════"
                echo "[+] $ts — arrow-check-all recovery"
                echo "[+]   Detected:  WAN IP = LAN IP (LTE session detached)"
                echo "[+]   Action:    funcNo:1018 profile_num=\"0\" → sleep 5 → profile_num=\"1\""
                echo "[+]   Result:    $status  wan=${wan_ip}  signal=${dbm:-n/a}"
                echo "[+] ═══════════════════════════════════════"
            } >> "$log_file"
        fi
    fi

    printf '%-10s  GA-%-7s  %-17s  %-17s  %-8s %s\n' \
        "$status" "${imei: -4}" "$imei" "${wan_ip:--}" "${dbm:--}" "$iface"
    rm -f "$jar"
}

# ─── main ────────────────────────────────────────────────────────────────────
ifaces=$(ip -4 -o addr show | awk '$4 ~ /^192\.168\.100\./ {print $2}')
count=$(echo "$ifaces" | wc -l)
[ "$count" = 0 ] && err "Keine Interfaces auf 192.168.100.0/24 gefunden — Dongles gesteckt? NM 'dongle-local' mit multi-connect=multiple?"

log "Checking $count ARROW(s) in parallel...${FORCE_CYCLE:+ (--force-cycle)}${CHECK_ONLY:+ (--check-only)}"
export -f check_one
export ARROW_ADMIN_PASSWORD CHECK_ONLY FORCE_CYCLE LOG_DIR

printf '\n%-10s  %-10s  %-17s  %-17s  %-8s %s\n' "STATUS" "SSID" "IMEI" "WAN-IP" "dBm" "IFACE"
printf '%-10s  %-10s  %-17s  %-17s  %-8s %s\n'   "------" "----" "----" "------" "---" "-----"
# Parallelism: 7 at a time. Each recovery takes ~35s; 14 units in 2 waves.
echo "$ifaces" | xargs -n1 -P7 -I{} bash -c 'check_one "$@"' _ {} | sort

echo
online=$(echo "$ifaces" | wc -l)
log "Check complete. Re-run with --force-cycle to preemptively reattach everything."
