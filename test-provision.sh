#!/bin/bash
#
# test-provision.sh — Verify fleet-specific provisioning of an OpenStick dongle
#
# Checks that all provisioning settings were applied correctly:
# device identity, SIM card, WiFi hotspot (SSID + PSK), APN, timezone,
# NetBird VPN, RNDIS state, and database record.
#
# Requires provision.conf + .env to know the expected values.
#
# Usage:
#   bash test-provision.sh                              # defaults
#   bash test-provision.sh 192.168.68.1 openstick       # custom host + pass
#
# Exit codes:
#   0 = all passed (with optional skips)
#   1 = one or more failures

HOST="${1:-192.168.68.1}"
PASS="${2:-openstick}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

ssh_cmd() { SSHPASS="$PASS" sshpass -e ssh $SSH_OPTS "root@$HOST" "$1" 2>/dev/null; }

which sshpass >/dev/null 2>&1 || { echo "Install sshpass: apt install sshpass"; exit 1; }

# ─── Load configuration ─────────────────────────────────────────────────────

[ -f "$SCRIPT_DIR/.env" ] || { echo ".env not found"; exit 1; }
[ -f "$SCRIPT_DIR/provision.conf" ] || { echo "provision.conf not found"; exit 1; }

source "$SCRIPT_DIR/.env"
source "$SCRIPT_DIR/provision.conf"

derive_wifi_psk() {
    local ssid="$1"
    echo -n "$ssid" | openssl dgst -sha256 -hmac "$OPENSTICK_WIFI_SECRET" | awk '{print $NF}' | cut -c1-16
}

# ─── Test framework ─────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1 — $2"; FAILED=$((FAILED + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}  $1 — $2"; SKIPPED=$((SKIPPED + 1)); }

echo ""
echo "╔═══════════════════════════════════════╗"
echo "║   Provisioning Verification Suite     ║"
echo "╚═══════════════════════════════════════╝"

# ─── Pre-check: SSH ─────────────────────────────────────────────────────────

if ! ssh_cmd "echo OK" | grep -q OK; then
    echo -e "  ${RED}FAIL${NC}  SSH login — aborting"
    exit 1
fi

# ─── 1. Device Identity ────────────────────────────────────────────────────

echo ""
echo "── 1. Device Identity ──"

IMEI=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.3gpp.imei | awk -F': ' '{print \$2}' | xargs")
if [ -n "$IMEI" ] && [ "$IMEI" != "--" ]; then
    pass "IMEI: $IMEI"
else
    fail "IMEI" "not readable"
    # Many tests depend on IMEI — abort
    echo -e "\n  ${RED}Cannot derive expected values without IMEI — aborting${NC}"
    exit 1
fi

EXPECTED_LAST4="${IMEI: -4}"
EXPECTED_HOSTNAME="ga-${EXPECTED_LAST4}"
EXPECTED_SSID="GA-${EXPECTED_LAST4}"

ACTUAL_HOSTNAME=$(ssh_cmd "hostname")
if [ "$ACTUAL_HOSTNAME" = "$EXPECTED_HOSTNAME" ]; then
    pass "Hostname: $ACTUAL_HOSTNAME"
else
    fail "Hostname" "expected $EXPECTED_HOSTNAME, got $ACTUAL_HOSTNAME"
fi

SERIAL=$(ssh_cmd "cat /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\0'" || true)
[ -z "$SERIAL" ] && SERIAL=$(ssh_cmd "grep -i '^Serial' /proc/cpuinfo 2>/dev/null | awk '{print \$3}'" || true)
[ -z "$SERIAL" ] && SERIAL=$(ssh_cmd "cat /sys/block/mmcblk0/device/cid 2>/dev/null | tr -d '\0'" || true)
if [ -n "$SERIAL" ]; then
    pass "Hardware serial: $SERIAL"
else
    skip "Hardware serial" "not available from device tree, cpuinfo, or eMMC"
fi

# ─── 2. SIM + Phone ────────────────────────────────────────────────────────

echo ""
echo "── 2. SIM + Phone ──"

SIM_PATH=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.generic.sim | head -1 | awk -F': ' '{print \$2}' | xargs")
if [ -n "$SIM_PATH" ] && [ "$SIM_PATH" != "--" ]; then
    pass "SIM card detected"
else
    fail "SIM card" "not detected"
fi

PHONE=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep 'modem.generic.own-numbers.value' | awk -F': ' '{print \$2}' | xargs" || true)
if [ -n "$PHONE" ] && [ "$PHONE" != "--" ]; then
    pass "Phone number: $PHONE"
else
    skip "Phone number" "carrier does not provide own-number"
fi

# ─── 3. WiFi Hotspot ───────────────────────────────────────────────────────

echo ""
echo "── 3. WiFi Hotspot ──"

WIFI_ACTIVE=$(ssh_cmd "nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | grep hotspot")
if [ -n "$WIFI_ACTIVE" ]; then
    pass "Hotspot connection active"
else
    fail "Hotspot connection" "not active"
fi

ACTUAL_SSID=$(ssh_cmd "nmcli -t -f 802-11-wireless.ssid connection show hotspot 2>/dev/null" | sed 's/802-11-wireless.ssid://')
if [ "$ACTUAL_SSID" = "$EXPECTED_SSID" ]; then
    pass "SSID: $ACTUAL_SSID"
else
    fail "SSID" "expected $EXPECTED_SSID, got $ACTUAL_SSID"
fi

if [ -n "$OPENSTICK_WIFI_SECRET" ]; then
    EXPECTED_PSK=$(derive_wifi_psk "$EXPECTED_SSID")
    ACTUAL_PSK=$(ssh_cmd "nmcli -s -t -f 802-11-wireless-security.psk connection show hotspot 2>/dev/null" | sed 's/802-11-wireless-security.psk://')
    if [ "$ACTUAL_PSK" = "$EXPECTED_PSK" ]; then
        pass "PSK matches HMAC derivation"
    else
        fail "PSK" "does not match HMAC-derived value"
    fi
else
    skip "PSK verification" "OPENSTICK_WIFI_SECRET not set"
fi

ACTUAL_CHANNEL=$(ssh_cmd "nmcli -t -f 802-11-wireless.channel connection show hotspot 2>/dev/null" | sed 's/802-11-wireless.channel://')
if [ "$ACTUAL_CHANNEL" = "${WIFI_CHANNEL:-6}" ]; then
    pass "WiFi channel: $ACTUAL_CHANNEL"
else
    fail "WiFi channel" "expected ${WIFI_CHANNEL:-6}, got $ACTUAL_CHANNEL"
fi

# ─── 4. Network Config ─────────────────────────────────────────────────────

echo ""
echo "── 4. Network Config ──"

ACTUAL_APN=$(ssh_cmd "cat /etc/default/lte-apn 2>/dev/null | grep -v '^#' | head -1")
if [ "$ACTUAL_APN" = "$APN" ]; then
    pass "APN: $ACTUAL_APN"
else
    fail "APN" "expected $APN, got $ACTUAL_APN"
fi

ACTUAL_TZ=$(ssh_cmd "cat /etc/timezone 2>/dev/null || readlink /etc/localtime | sed 's|.*/zoneinfo/||'")
if echo "$ACTUAL_TZ" | grep -q "$TIMEZONE"; then
    pass "Timezone: $ACTUAL_TZ"
else
    fail "Timezone" "expected $TIMEZONE, got $ACTUAL_TZ"
fi

# ─── 5. LTE Connectivity ───────────────────────────────────────────────────

echo ""
echo "── 5. LTE Connectivity ──"

LTE_STATE=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep 'modem.generic.state ' | awk -F': ' '{print \$2}' | xargs | awk '{print \$1}'")
if [ "$LTE_STATE" = "connected" ]; then
    pass "Modem state: connected"
else
    fail "Modem state" "got $LTE_STATE"
fi

# LTE data path reachability.
#
# We do NOT ping 8.8.8.8 / 1.1.1.1 anymore. Many IoT APNs (e.g. Vodafone
# inetd.vodafone.iot with an FQDN-whitelist ACL) silently blackhole ICMP
# and raw-IP traffic — only traffic to whitelisted hostnames is allowed.
# A ping to a raw public IP therefore fails on perfectly-working SIMs and
# gives a false negative.
#
# Instead we probe `api.netbird.io` over HTTPS. This single call verifies:
#   • DNS works on the dongle (FQDN resolves)
#   • The data bearer carries TCP (not just LTE attach)
#   • TLS handshake completes (cert chain verifies → DNS + network + CA store)
#   • System clock is correct (otherwise cert "not yet valid")
#   • The ACL permits the NetBird API endpoint (which is what NetBird actually
#     needs to work — we test the real dependency, not a proxy for it)
#
# The default `ghcr.io` was chosen because it is in the Greenautarky fleet's
# Vodafone IoT ACL *and* consistently returns a TLS-verified HTTP response.
# `api.netbird.io` is also in the ACL but occasionally resets the connection
# mid-TLS from this APN (root cause unclear — possibly upstream-IP drift,
# possibly SNI-based filtering), so we don't probe it as a health check.
# Override via `LTE_PROBE_URL` in `provision.conf` for fleets with different
# ACLs.
LTE_PROBE_URL="${LTE_PROBE_URL:-https://ghcr.io/}"
LTE_PROBE=$(ssh_cmd "curl -sS --max-time 10 -o /dev/null -w '%{http_code}|%{ssl_verify_result}|%{time_total}' '$LTE_PROBE_URL' 2>&1")
HTTP_CODE=$(echo "$LTE_PROBE" | awk -F'|' '{print $1}')
SSL_OK=$(echo "$LTE_PROBE"    | awk -F'|' '{print $2}')
RTT_S=$(echo "$LTE_PROBE"     | awk -F'|' '{print $3}')
if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ] && [ "$SSL_OK" = "0" ]; then
    # Round RTT to ms for readability.
    RTT_MS=$(awk -v s="$RTT_S" 'BEGIN{printf "%.0f", s*1000}' 2>/dev/null)
    pass "LTE HTTPS ($LTE_PROBE_URL → HTTP $HTTP_CODE, TLS ok, ${RTT_MS}ms)"
else
    fail "LTE HTTPS" "$LTE_PROBE_URL unreachable (http=${HTTP_CODE:-none}, tls=${SSL_OK:-?})"
fi

# ─── 6. NetBird VPN ────────────────────────────────────────────────────────

echo ""
echo "── 6. NetBird VPN ──"

if [ -n "${NETBIRD_SETUP_KEY:-}" ] && [ "$NETBIRD_SETUP_KEY" != "nb-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" ]; then
    NB_STATUS=$(ssh_cmd "netbird status 2>/dev/null | grep -i 'status.*connected\|Management.*Connected' | head -1")
    if echo "$NB_STATUS" | grep -qi "connected"; then
        pass "NetBird: connected"
    else
        fail "NetBird" "not connected"
    fi

    NB_IP=$(ssh_cmd "netbird status 2>/dev/null | grep 'NetBird IP' | awk '{print \$NF}'")
    if [ -n "$NB_IP" ] && [ "$NB_IP" != "N/A" ]; then
        pass "NetBird IP: $NB_IP"
    else
        fail "NetBird IP" "not assigned"
    fi

    # NetBird peer-identity uniqueness check against the inventory DB.
    #
    # A known failure mode: the rootfs can ship with a pre-enrolled NetBird
    # state (/var/lib/netbird/config.json), so every dongle registers with
    # the same WireGuard key and silently overwrites the previous dongle's
    # NetBird peer on the cloud side. The old dongle becomes unreachable
    # without any visible error during provisioning.
    #
    # Catch that here: if any OTHER IMEI in the DB already has this
    # netbird_ip or netbird_hostname, the collision is real and this
    # provisioning must be marked as failed (the DB write is gated on
    # verify success, so a FAIL here prevents us from clobbering an
    # existing row AND surfaces the problem before the dongle ships).
    NB_FQDN_NOW=$(ssh_cmd "netbird status 2>/dev/null | awk -F': +' '/FQDN/{print \$2; exit}' | xargs")
    if [ -n "$NB_IP" ] && [ -f "$SCRIPT_DIR/database.conf" ]; then
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/db.sh" 2>/dev/null
        if db_load_config 2>/dev/null; then
            dupe=$(db_query "
                SELECT imei FROM ${DB_SCHEMA}.devices
                WHERE imei <> '${IMEI}'
                  AND (netbird_ip = '${NB_IP}' OR netbird_hostname = '${NB_FQDN_NOW}')
                LIMIT 1;
            " 2>/dev/null | awk 'NR==3 {print $1}')
            if [ -n "$dupe" ] && [ "$dupe" != "imei" ]; then
                fail "NetBird peer uniqueness" \
                    "collision — $NB_IP / $NB_FQDN_NOW already belongs to IMEI $dupe. \
This dongle has NOT been enrolled as a new peer. Likely cause: rootfs \
shipped pre-enrolled NetBird state, or netbird daemon picked up stale \
identity before hostname was applied. Check /var/lib/netbird/ on both \
dongles, and ensure provision.sh runs 'netbird up --hostname <QR>' \
against a clean state."
            else
                pass "NetBird peer uniqueness (no collision in DB)"
            fi
        else
            skip "NetBird peer uniqueness" "DB not reachable"
        fi
    else
        skip "NetBird peer uniqueness" "no DB configured"
    fi
else
    skip "NetBird" "no setup key in .env"
    skip "NetBird IP" "no setup key in .env"
    skip "NetBird peer uniqueness" "no setup key"
fi

# ─── 7. RNDIS ──────────────────────────────────────────────────────────────

echo ""
echo "── 7. RNDIS ──"

if [ "${DISABLE_RNDIS:-no}" = "yes" ]; then
    GADGET=$(ssh_cmd "systemctl is-enabled usb-gadget 2>/dev/null")
    if [ "$GADGET" = "disabled" ] || [ "$GADGET" = "masked" ]; then
        pass "RNDIS: disabled (as configured)"
    else
        fail "RNDIS" "expected disabled, got $GADGET"
    fi
else
    GADGET=$(ssh_cmd "systemctl is-active usb-gadget 2>/dev/null")
    if [ "$GADGET" = "active" ]; then
        pass "RNDIS: active"
    else
        fail "RNDIS" "expected active, got $GADGET"
    fi

    # ─── 7a. RNDIS Mode ───────────────────────────────────────────────────
    RNDIS_MODE_CFG="${RNDIS_MODE:-gateway}"
    echo ""
    echo "── 7a. RNDIS Mode ($RNDIS_MODE_CFG) ──"

    if [ "$RNDIS_MODE_CFG" = "local" ]; then
        # Local mode: no gateway, no DNS, no NAT on USB

        # Check dnsmasq drop-in exists
        DNSMASQ_LOCAL=$(ssh_cmd "cat /etc/dnsmasq.d/usb-local.conf 2>/dev/null")
        if echo "$DNSMASQ_LOCAL" | grep -q "dhcp-option=usb0,3"; then
            pass "dnsmasq: no gateway option on usb0"
        else
            fail "dnsmasq gateway" "usb-local.conf missing dhcp-option=usb0,3"
        fi

        if echo "$DNSMASQ_LOCAL" | grep -q "dhcp-option=usb0,6"; then
            pass "dnsmasq: no DNS option on usb0"
        else
            fail "dnsmasq DNS" "usb-local.conf missing dhcp-option=usb0,6"
        fi

        # MASQUERADE rules may exist (needed for WiFi hotspot clients).
        # Local mode relies on usb0 forwarding=0 to block USB→LTE routing.
        MASQ=$(ssh_cmd "iptables -t nat -S POSTROUTING 2>/dev/null | grep MASQUERADE")
        if [ -n "$MASQ" ]; then
            pass "iptables: MASQUERADE present (needed for WiFi hotspot)"
        else
            skip "iptables MASQUERADE" "no rules (hotspot may not route to internet)"
        fi

        # Check IP forwarding disabled for usb0
        FWD=$(ssh_cmd "cat /proc/sys/net/ipv4/conf/usb0/forwarding 2>/dev/null")
        if [ "$FWD" = "0" ]; then
            pass "IP forwarding: disabled on usb0"
        else
            fail "IP forwarding" "expected 0 on usb0, got $FWD"
        fi

        # Check sysctl persistence
        SYSCTL=$(ssh_cmd "cat /etc/sysctl.d/90-rndis-local.conf 2>/dev/null")
        if echo "$SYSCTL" | grep -q "net.ipv4.conf.usb0.forwarding=0"; then
            pass "sysctl: usb0 forwarding=0 persisted"
        else
            fail "sysctl persistence" "90-rndis-local.conf missing or wrong"
        fi

    else
        # Gateway mode: NAT + forwarding should be active

        MASQ=$(ssh_cmd "iptables -t nat -S POSTROUTING 2>/dev/null | grep MASQUERADE")
        if [ -n "$MASQ" ]; then
            pass "iptables: MASQUERADE active (gateway mode)"
        else
            fail "iptables MASQUERADE" "expected MASQUERADE rule for gateway mode"
        fi

        FWD=$(ssh_cmd "cat /proc/sys/net/ipv4/conf/usb0/forwarding 2>/dev/null")
        if [ "$FWD" = "1" ]; then
            pass "IP forwarding: enabled on usb0"
        else
            fail "IP forwarding" "expected 1 on usb0, got $FWD"
        fi

        # Verify no local-mode override is present
        if ssh_cmd "test -f /etc/dnsmasq.d/usb-local.conf" 2>/dev/null; then
            fail "dnsmasq config" "usb-local.conf should not exist in gateway mode"
        else
            pass "dnsmasq: no local-mode override (gateway mode)"
        fi
    fi
fi

# ─── 8. Database ───────────────────────────────────────────────────────────

echo ""
echo "── 8. Database ──"

if [ -f "$SCRIPT_DIR/database.conf" ]; then
    source "$SCRIPT_DIR/db.sh"
    if db_load_config 2>/dev/null; then
        # Verify DB is reachable (record is written AFTER this test suite)
        DB_TEST=$(db_query "SELECT 1;" 2>/dev/null)
        if [ -n "$DB_TEST" ]; then
            pass "DB connection"
            # Check if record already exists (re-provisioning)
            DB_RECORD=$(db_query "SELECT imei, qr_code, hostname, firmware_version FROM ${DB_SCHEMA}.devices WHERE imei = '$IMEI' LIMIT 1;" 2>/dev/null)
            if [ -n "$DB_RECORD" ]; then
                pass "DB record exists for IMEI $IMEI (re-provisioning)"
            else
                skip "DB record" "new device — will be written after verification"
            fi
        else
            fail "DB connection" "query failed"
            skip "DB record" "no connection"
        fi
    else
        skip "DB connection" "could not connect"
        skip "DB record" "no connection"
    fi
else
    skip "DB connection" "no database.conf"
    skip "DB record" "no database.conf"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "╔═══════════════════════════════════════╗"
printf "║  ${GREEN}PASS: %-3d${NC}  ${RED}FAIL: %-3d${NC}  ${YELLOW}SKIP: %-3d${NC}  ║\n" $PASSED $FAILED $SKIPPED
echo "╚═══════════════════════════════════════╝"

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Some provisioning checks FAILED${NC}"
    exit 1
elif [ "$SKIPPED" -gt 0 ]; then
    echo -e "${YELLOW}All passed, some skipped${NC}"
    exit 0
else
    echo -e "${GREEN}ALL PROVISIONING CHECKS PASSED${NC}"
    exit 0
fi
