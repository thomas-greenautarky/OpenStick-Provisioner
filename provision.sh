#!/bin/bash
#
# provision.sh — Flash and provision an OpenStick dongle for fleet deployment
#
# Wraps USB-Dongle-OpenStick flash + adds fleet-specific configuration:
# WiFi PSK derivation, APN, NetBird VPN, hostname, credentials.
#
# Usage:
#   bash provision.sh                    # interactive (prompts for EDL)
#   bash provision.sh --skip-flash       # skip flash, only configure (dongle already running)
#   bash provision.sh --test-only        # only run test suite
#
# Prerequisites:
#   - .env file with secrets (copy from .env.example)
#   - USB-Dongle-OpenStick repo built (rootfs.raw + boot.img ready)
#   - Dongle in EDL mode (for flash) or booted (for configure-only)

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

[ -f "$SCRIPT_DIR/.env" ] || err ".env not found. Copy from .env.example and fill in secrets."
[ -f "$SCRIPT_DIR/provision.conf" ] || err "provision.conf not found."

source "$SCRIPT_DIR/.env"
source "$SCRIPT_DIR/provision.conf"

[ -n "$OPENSTICK_WIFI_SECRET" ] || err "OPENSTICK_WIFI_SECRET not set in .env"
[ -n "$APN" ] || err "APN not set in provision.conf"

OPENSTICK_DIR="$(cd "$SCRIPT_DIR/$OPENSTICK_REPO" 2>/dev/null && pwd)" || \
    err "OpenStick repo not found at $OPENSTICK_REPO"

which sshpass >/dev/null 2>&1 || err "sshpass not installed (apt install sshpass)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
ssh_cmd() { SSHPASS="$DONGLE_PASS" sshpass -e ssh $SSH_OPTS "$DONGLE_USER@$DONGLE_IP" "$1" 2>/dev/null; }
scp_cmd() { SSHPASS="$DONGLE_PASS" sshpass -e scp $SSH_OPTS "$1" "$DONGLE_USER@$DONGLE_IP:$2" 2>/dev/null; }

derive_wifi_psk() {
    local ssid="$1"
    echo -n "$ssid" | openssl dgst -sha256 -hmac "$OPENSTICK_WIFI_SECRET" | awk '{print $NF}' | cut -c1-16
}

# ─── Parse arguments ─────────────────────────────────────────────────────────

SKIP_FLASH=false
TEST_ONLY=false

case "${1:-}" in
    --skip-flash) SKIP_FLASH=true ;;
    --test-only)  TEST_ONLY=true ;;
esac

# ─── Test only ───────────────────────────────────────────────────────────────

if $TEST_ONLY; then
    log "Running test suite..."
    bash "$OPENSTICK_DIR/flash/test-dongle.sh"
    exit $?
fi

# ─── Step 1: Flash base image ───────────────────────────────────────────────

if ! $SKIP_FLASH; then
    log "=== Step 1: Flash base image ==="
    [ -f "$OPENSTICK_DIR/flash/files/rootfs.raw" ] || err "rootfs.raw not found. Build first: cd $OPENSTICK_DIR && docker run ..."
    [ -f "$OPENSTICK_DIR/flash/files/boot.img" ] || err "boot.img not found."

    cd "$OPENSTICK_DIR/flash"
    bash flash-openstick.sh
    cd "$SCRIPT_DIR"
fi

# ─── Step 2: Wait for SSH ────────────────────────────────────────────────────

log "=== Step 2: Waiting for SSH ==="
for i in $(seq 1 24); do
    if ssh_cmd "echo OK" | grep -q OK; then
        log "SSH connected."
        break
    fi
    sleep 5
done
ssh_cmd "echo OK" | grep -q OK || err "SSH not reachable after 120s"

# Remove old host key
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$DONGLE_IP" 2>/dev/null || true

# ─── Step 3: Read IMEI + derive identifiers ─────────────────────────────────

log "=== Step 3: Device identification ==="
IMEI=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.3gpp.imei | awk -F': ' '{print \$2}' | xargs")

if [ -z "$IMEI" ] || [ "$IMEI" = "--" ]; then
    warn "IMEI not available yet. Waiting 60s for modem..."
    sleep 60
    IMEI=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.3gpp.imei | awk -F': ' '{print \$2}' | xargs")
fi

[ -n "$IMEI" ] && [ "$IMEI" != "--" ] || err "Cannot read IMEI. Is modem firmware + NV storage copied?"

LAST4="${IMEI: -4}"
SSID="GA-${LAST4}"
PSK=$(derive_wifi_psk "$SSID")
HOSTNAME="ga-${LAST4}"

log "  IMEI:     $IMEI"
log "  Hostname: $HOSTNAME"
log "  WiFi:     $SSID / $PSK"

# ─── Step 4: Configure dongle ───────────────────────────────────────────────

log "=== Step 4: Configure ==="

# Hostname
ssh_cmd "echo '$HOSTNAME' > /etc/hostname && hostname '$HOSTNAME'"
log "  Hostname set: $HOSTNAME"

# APN
ssh_cmd "echo '$APN' > /etc/default/lte-apn"
log "  APN set: $APN"

# Timezone
ssh_cmd "timedatectl set-timezone '$TIMEZONE' 2>/dev/null || ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime"
log "  Timezone: $TIMEZONE"

# Root password
if [ -n "$ROOT_PASSWORD" ]; then
    ssh_cmd "echo 'root:$ROOT_PASSWORD' | chpasswd"
    DONGLE_PASS="$ROOT_PASSWORD"
    log "  Root password changed"
fi

# WiFi hotspot
ssh_cmd "
nmcli connection delete hotspot 2>/dev/null || true
nmcli connection add type wifi ifname wlan0 con-name hotspot \
    wifi.mode ap wifi.ssid '$SSID' wifi.channel ${WIFI_CHANNEL:-6} wifi.band ${WIFI_BAND:-bg} \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk '$PSK' \
    ipv4.method shared ipv4.addresses 192.168.4.1/24 \
    autoconnect yes 2>/dev/null
" && log "  WiFi: $SSID (PSK derived)" || warn "  WiFi config failed (wcnss firmware missing?)"

# NetBird VPN
if [ -n "$NETBIRD_SETUP_KEY" ] && [ "$NETBIRD_SETUP_KEY" != "nb-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" ]; then
    if ssh_cmd "which netbird" >/dev/null 2>&1; then
        ssh_cmd "netbird up --setup-key '$NETBIRD_SETUP_KEY'" 2>/dev/null
        NB_IP=$(ssh_cmd "netbird status 2>/dev/null | grep 'NetBird IP' | awk '{print \$NF}'" 2>/dev/null)
        log "  NetBird VPN: connected ($NB_IP)"
    else
        warn "  NetBird not installed — rebuild base image"
    fi
else
    log "  NetBird: skipped (no setup key in .env)"
fi

# Disable RNDIS if configured (dongle only reachable via LTE/NetBird after this)
if [ "${DISABLE_RNDIS:-no}" = "yes" ]; then
    warn "  Disabling RNDIS USB gadget (dongle only via LTE/NetBird!)"
    ssh_cmd "systemctl disable usb-gadget.service 2>/dev/null && systemctl stop usb-gadget.service 2>/dev/null"
    log "  RNDIS disabled — will not start on next boot"
fi

# ─── Step 5: Restart services ───────────────────────────────────────────────

log "=== Step 5: Restart services ==="
ssh_cmd "systemctl restart modem-autoconnect 2>/dev/null || true"
sleep 10

# ─── Step 6: Run test suite ──────────────────────────────────────────────────

log "=== Step 6: Verification ==="
bash "$OPENSTICK_DIR/flash/test-dongle.sh" "$DONGLE_IP" "$DONGLE_PASS"

echo ""
log "═══════════════════════════════════════"
log "  Provisioning complete!"
log "  Device:    $HOSTNAME ($IMEI)"
log "  WiFi:      $SSID"
log "  SSH:       ssh root@$DONGLE_IP"
log "  APN:       $APN"
log "═══════════════════════════════════════"
