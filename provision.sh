#!/bin/bash
#
# provision.sh — Flash and provision an OpenStick dongle for fleet deployment
#
# Wraps USB-Dongle-OpenStick flash + adds fleet-specific configuration:
# WiFi PSK derivation, APN, NetBird VPN, hostname, credentials.
#
# Usage:
#   bash provision.sh                              # interactive (QR scan prompt + flash)
#   bash provision.sh --qr-code SIM-WIN-00000001   # skip QR prompt, use value directly
#   bash provision.sh --prep                         # prep mode: flash + base config (no SIM needed)
#   bash provision.sh --skip-flash                   # skip flash, only configure
#   bash provision.sh --skip-flash --qr-code XXX     # combine flags
#   bash provision.sh --firmware-version v1.1         # override version (default from provision.conf)
#   bash provision.sh --test-only                     # only run test suite
#
# Prerequisites:
#   - .env file with secrets (copy from .env.example)
#   - USB-Dongle-OpenStick repo built (auto-copies images to flash/files/)
#   - "dongle-local" NM profile installed on host (see README)
#   - Dongle in EDL mode (for flash) or booted (for configure-only)

set -e

# Ensure pipx binaries (edl) are in PATH
export PATH="$HOME/.local/bin:$PATH"

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
TEST_PROVISION=false
PREP_MODE=false
QR_CODE=""
FW_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-flash)        SKIP_FLASH=true; shift ;;
        --test-only)         TEST_ONLY=true; shift ;;
        --test-provision)    TEST_PROVISION=true; shift ;;
        --prep)              PREP_MODE=true; shift ;;
        --qr-code)           QR_CODE="$2"; shift 2 ;;
        --firmware-version)  FW_VERSION="$2"; shift 2 ;;
        *) err "Unknown option: $1" ;;
    esac
done

FIRMWARE_VERSION="${FW_VERSION:-${FIRMWARE_VERSION:-v1.0}}"

# ─── Test only ───────────────────────────────────────────────────────────────

if $TEST_ONLY; then
    log "Running hardware test suite..."
    bash "$OPENSTICK_DIR/flash/test-dongle.sh" "$DONGLE_IP" "$DONGLE_PASS"
    exit $?
fi

if $TEST_PROVISION; then
    log "Running provisioning test suite..."
    bash "$SCRIPT_DIR/test-provision.sh" "$DONGLE_IP" "$DONGLE_PASS"
    exit $?
fi

# ─── Step 0: QR code ────────────────────────────────────────────────────────

if [ -z "$QR_CODE" ]; then
    log "=== Step 0: QR Code ==="
    echo -ne "${GREEN}[+]${NC} Scan QR code (or type manually): "
    read -r QR_CODE
    QR_CODE=$(echo "$QR_CODE" | tr -d '[:space:]')
    [ -n "$QR_CODE" ] || err "No QR code provided."
fi

# Validate QR code format: SIM-WIN-XXXXXXXX (8 digits)
if ! echo "$QR_CODE" | grep -qE '^SIM-WIN-[0-9]{8}$'; then
    err "Invalid QR code format: '$QR_CODE'
  Expected: SIM-WIN-XXXXXXXX (e.g. SIM-WIN-00000001)
  Got:      $QR_CODE
  Please re-scan or type the correct code."
fi
log "  QR Code: $QR_CODE"

# ─── Route Guard: verify permanent NM profile exists ─────────────────────────
# A permanent NM profile "dongle-local" must exist on the host to prevent
# USB ethernet (enx*) from becoming the default route. Install once with:
#   nmcli connection add type ethernet con-name "dongle-local" \
#       match.interface-name "enx*" ipv4.never-default yes ipv4.dns-priority 200 \
#       ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100

if nmcli connection show dongle-local >/dev/null 2>&1; then
    log "Route guard: permanent NM profile 'dongle-local' active"
else
    warn "Route guard: 'dongle-local' NM profile not found!"
    warn "Host internet may be disrupted. Install with:"
    warn "  nmcli connection add type ethernet con-name dongle-local \\"
    warn "    match.interface-name 'enx*' ipv4.never-default yes ipv4.dns-priority 200 \\"
    warn "    ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100"
fi

# ─── Step 1: Flash base image ───────────────────────────────────────────────

if ! $SKIP_FLASH; then
    log "=== Step 1: Flash base image ==="

    # Auto-detect dongle type and choose flash script
    if lsusb 2>/dev/null | grep -q "05c6:f00e\|05c6:90b6"; then
        # Stock Android dongle (UZ801 type) — use lk2nd-based flash
        log "  Detected: UZ801 (Stock Android)"
        FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-uz801.sh"
        DONGLE_TYPE="UZ801"
        [ -f "$FLASH_SCRIPT" ] || err "flash-uz801.sh not found at $FLASH_SCRIPT"
    elif lsusb 2>/dev/null | grep -q "05c6:9008"; then
        # EDL mode — could be either type. Check if uz801 files exist.
        if [ -f "$OPENSTICK_DIR/flash/files/uz801/aboot.mbn" ]; then
            log "  Detected: EDL mode (using UZ801 flash with lk2nd)"
            FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-uz801.sh"
            DONGLE_TYPE="UZ801"
        else
            log "  Detected: EDL mode (using JZ0145-v33 flash)"
            FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-openstick.sh"
            DONGLE_TYPE="JZ0145-v33"
        fi
    elif lsusb 2>/dev/null | grep -q "18d1:d00d"; then
        # Fastboot/lk2nd — already has lk2nd, use uz801 flash
        log "  Detected: Fastboot/lk2nd"
        FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-uz801.sh"
        DONGLE_TYPE="UZ801"
    else
        # No dongle detected — wait for one
        warn "No dongle detected. Please plug in a dongle now."
        warn "  UZ801:     Plug in normally (boots to Stock Android in ~15s)"
        warn "  JZ0145-v33: Hold reset pin + plug in USB (hold 10-15s)"
        echo ""
        echo -ne "${GREEN}[+]${NC} Waiting for dongle..."
        for i in $(seq 1 30); do
            if lsusb 2>/dev/null | grep -q "05c6:f00e\|05c6:90b6"; then
                echo " UZ801 detected!"
                FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-uz801.sh"
                DONGLE_TYPE="UZ801"
                break
            elif lsusb 2>/dev/null | grep -q "05c6:9008"; then
                echo " EDL detected!"
                if [ -f "$OPENSTICK_DIR/flash/files/uz801/aboot.mbn" ]; then
                    FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-uz801.sh"
                    DONGLE_TYPE="UZ801"
                else
                    FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-openstick.sh"
                    DONGLE_TYPE="JZ0145-v33"
                fi
                break
            elif lsusb 2>/dev/null | grep -q "18d1:d00d"; then
                echo " Fastboot/lk2nd detected!"
                FLASH_SCRIPT="$OPENSTICK_DIR/flash/flash-uz801.sh"
                DONGLE_TYPE="UZ801"
                break
            fi
            echo -n "."
            sleep 2
        done
        [ -n "$FLASH_SCRIPT" ] || err "No dongle detected after 60s."
    fi

    [ -f "$FLASH_SCRIPT" ] || err "Flash script not found: $FLASH_SCRIPT"
    log "  Flash script: $(basename $FLASH_SCRIPT)"

    # Pass a probe-file path so flash-uz801.sh writes chipset/emmc info we can record
    PROBE_FILE=$(mktemp -t openstick-probe-XXXXXX.env)
    cd "$OPENSTICK_DIR/flash"
    if [[ "$FLASH_SCRIPT" == *flash-uz801.sh ]]; then
        bash "$FLASH_SCRIPT" --probe-file "$PROBE_FILE"
    else
        bash "$FLASH_SCRIPT"
    fi
    cd "$SCRIPT_DIR"

    # Load probe info into environment for later DB record
    if [ -f "$PROBE_FILE" ] && [ -s "$PROBE_FILE" ]; then
        log "  Probe info:"
        while IFS='=' read -r key value; do
            [ -z "$key" ] && continue
            case "$key" in
                hwid)         DONGLE_HWID="$value" ;;
                msm_id)       DONGLE_MSM_ID="$value" ;;
                pk_hash)      DONGLE_PK_HASH="$value" ;;
                memory)       DONGLE_MEMORY="$value" ;;
                emmc_sectors) DONGLE_EMMC_SECTORS="$value" ;;
                emmc_size_mb) DONGLE_EMMC_SIZE_MB="$value" ;;
            esac
            log "    $key=$value"
        done < "$PROBE_FILE"
        rm -f "$PROBE_FILE"
    fi
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

# Try to enable modem first (may need a kick after boot)
ssh_cmd "mmcli -m 0 --enable 2>/dev/null" || true
sleep 3

# Try multiple IMEI sources: 3gpp.imei (enabled modem) or equipment-identifier (always available)
IMEI=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.3gpp.imei | awk -F': ' '{print \$2}' | xargs")
if [ -z "$IMEI" ] || [ "$IMEI" = "--" ]; then
    IMEI=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.generic.equipment-identifier | awk -F': ' '{print \$2}' | xargs")
fi

if [ -z "$IMEI" ] || [ "$IMEI" = "--" ]; then
    warn "IMEI not available yet. Waiting 30s for modem..."
    sleep 30
    IMEI=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.generic.equipment-identifier | awk -F': ' '{print \$2}' | xargs")
fi

if [ -z "$IMEI" ] || [ "$IMEI" = "--" ]; then
    if $PREP_MODE; then
        # In prep mode: try to recover IMEI from the ADB backup (saved during flash)
        warn "IMEI not readable from modem (no SIM → ModemManager fails on some boards)"
        BACKUP_IMEI=""
        for info_file in "$OPENSTICK_DIR"/backup/stock_uz801_*/device_info.txt; do
            [ -f "$info_file" ] || continue
            CANDIDATE=$(grep -oP 'IMEI: \K[0-9]+' "$info_file" 2>/dev/null | tail -1)
            # Match by checking if this backup was created today (most recent flash)
            if [ -n "$CANDIDATE" ] && echo "$info_file" | grep -q "$(date +%Y%m%d)"; then
                BACKUP_IMEI="$CANDIDATE"
            fi
        done
        if [ -n "$BACKUP_IMEI" ]; then
            IMEI="$BACKUP_IMEI"
            log "  IMEI recovered from ADB backup: $IMEI"
        else
            err "IMEI not readable and no backup found. Cannot identify device."
        fi
    else
        echo ""
        err "IMEI not readable. Possible causes:
  - No SIM card inserted (required for full provisioning)
  - Modem firmware not restored (check flash log for errors)
  - Use --prep mode for provisioning without SIM

  Diagnostics (run on dongle via SSH):
    mmcli -m 0                          # modem status
    ls /lib/firmware/modem.mdt          # modem firmware
    systemctl status rmtfs              # remote filesystem service"
    fi
fi

LAST4="${IMEI: -4}"
SSID="GA-${LAST4}"
PSK=$(derive_wifi_psk "$SSID")
HOSTNAME="ga-${LAST4}"

# Read hardware serial number (try device tree, then cpuinfo, then eMMC CID)
SERIAL_NUMBER=$(ssh_cmd "cat /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\0'" || true)
if [ -z "$SERIAL_NUMBER" ]; then
    SERIAL_NUMBER=$(ssh_cmd "grep -i '^Serial' /proc/cpuinfo 2>/dev/null | awk '{print \$3}'" || true)
fi
if [ -z "$SERIAL_NUMBER" ]; then
    SERIAL_NUMBER=$(ssh_cmd "cat /sys/block/mmcblk0/device/cid 2>/dev/null | tr -d '\0'" || true)
fi

# Determine dongle type — prefer device-tree model (authoritative after boot),
# otherwise keep what Step 1 detected via USB ID.
DT_MODEL=$(ssh_cmd "cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0'" || true)
DT_COMPATIBLE=$(ssh_cmd "cat /sys/firmware/devicetree/base/compatible 2>/dev/null | tr '\0' ','" || true)
DT_COMPATIBLE="${DT_COMPATIBLE%,}"
case "$DT_MODEL" in
    *UZ801*|*uz801*|*Yiming*)  DONGLE_TYPE="UZ801" ;;
    *JZ0145*|*jz01-45*)        DONGLE_TYPE="JZ0145-v33" ;;
esac
DONGLE_TYPE="${DONGLE_TYPE:-unknown}"

# Read SIM phone number
PHONE_NUMBER=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep 'modem.generic.own-numbers.value' | awk -F': ' '{print \$2}' | xargs" || true)
[ -z "$PHONE_NUMBER" ] || [ "$PHONE_NUMBER" = "--" ] && PHONE_NUMBER=""

log "  IMEI:     $IMEI"
log "  Serial:   ${SERIAL_NUMBER:-unknown}"
log "  Type:     $DONGLE_TYPE${DT_MODEL:+ ($DT_MODEL)}"
log "  HWID:     ${DONGLE_HWID:-unknown}"
log "  eMMC:     ${DONGLE_EMMC_SIZE_MB:-?} MB (${DONGLE_EMMC_SECTORS:-?} sectors)"
log "  Phone:    ${PHONE_NUMBER:-unknown}"
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
ssh_cmd "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && echo '$TIMEZONE' > /etc/timezone"
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

# NetBird VPN (requires internet — skip in prep mode)
if $PREP_MODE; then
    log "  NetBird: skipped (prep mode, no internet)"
elif [ -n "$NETBIRD_SETUP_KEY" ] && [ "$NETBIRD_SETUP_KEY" != "nb-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" ]; then
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
elif [ "${RNDIS_MODE:-gateway}" = "local" ]; then
    log "  RNDIS mode: local (SSH only, no internet sharing)"
    # Remove default gateway and DNS from dnsmasq DHCP options so the host
    # does not re-route its traffic through the dongle.
    ssh_cmd "
        # Override dnsmasq config for usb0: hand out IP only, no gateway/DNS
        cat > /etc/dnsmasq.d/usb-local.conf <<'DNSMASQ'
# RNDIS local mode — DHCP without gateway or DNS
# Clients get an IP but keep their own default route and DNS
dhcp-option=usb0,3
dhcp-option=usb0,6
DNSMASQ
        # NOTE: We keep MASQUERADE rules — they are needed for WiFi hotspot
        # clients to reach the internet via LTE. Local mode only prevents the
        # USB host from routing through the dongle (no gateway/DNS + no forwarding).

        # Disable IP forwarding for usb0 (blocks USB→LTE routing)
        echo 0 > /proc/sys/net/ipv4/conf/usb0/forwarding
        # Make forwarding change persistent via sysctl
        mkdir -p /etc/sysctl.d
        echo 'net.ipv4.conf.usb0.forwarding=0' > /etc/sysctl.d/90-rndis-local.conf
        # Restart dnsmasq to pick up new config
        systemctl restart dnsmasq 2>/dev/null || true
    "
    log "  RNDIS local mode configured (no gateway/DNS/NAT on USB)"
else
    log "  RNDIS mode: gateway (default — internet sharing enabled)"
fi

# ─── Step 5: Verify provisioning (full mode only) ──────────────────────────

VERIFY_FAIL=0
DB_STATUS="skipped"

if $PREP_MODE; then
    log "=== Step 5: Verify — skipped (prep mode) ==="
    log "=== Step 6: DB — skipped (prep mode) ==="
else
    log "=== Step 5: Verify provisioning ==="
    # Wait for SSH to come back (dnsmasq restart in RNDIS local mode briefly drops USB network)
    for i in $(seq 1 12); do
        ssh_cmd "echo OK" 2>/dev/null | grep -q OK && break
        sleep 5
    done
    bash "$SCRIPT_DIR/test-provision.sh" "$DONGLE_IP" "$DONGLE_PASS" && VERIFY_FAIL=0 || VERIFY_FAIL=$?

    # ─── Record to database (only on success) ───────────────────────────────
    if [ "$VERIFY_FAIL" -eq 0 ]; then
        source "$SCRIPT_DIR/db.sh"
        if db_load_config; then
            db_init && \
            db_record_device "$IMEI" "${SERIAL_NUMBER:-}" "$QR_CODE" "$FIRMWARE_VERSION" \
                "${PHONE_NUMBER:-}" "${NB_IP:-}" "$HOSTNAME" "$HOSTNAME" "$DONGLE_TYPE" \
                "${DONGLE_HWID:-}" "${DONGLE_MSM_ID:-}" "${DONGLE_EMMC_SECTORS:-0}" \
                "${DT_MODEL:-}" "${DT_COMPATIBLE:-}" && \
                DB_STATUS="recorded" || DB_STATUS="failed"
        else
            DB_STATUS="no config"
        fi
        [ "$DB_STATUS" = "recorded" ] && log "DB: device recorded" || warn "DB: $DB_STATUS"
    else
        warn "DB: skipped (provisioning verification failed)"
    fi
fi

# ─── Step 7: Restart services + run test suite ───────────────────────────────

log "=== Step 7: System test ==="
ssh_cmd "systemctl restart modem-autoconnect 2>/dev/null || true"
sleep 10
bash "$OPENSTICK_DIR/flash/test-dongle.sh" "$DONGLE_IP" "$DONGLE_PASS"

echo ""
log "═══════════════════════════════════════"
log "  Provisioning complete!"
log "  Device:    $HOSTNAME ($IMEI)"
log "  Type:      $DONGLE_TYPE"
log "  Serial:    ${SERIAL_NUMBER:-unknown}"
log "  QR Code:   $QR_CODE"
log "  Phone:     ${PHONE_NUMBER:-unknown}"
log "  Firmware:  $FIRMWARE_VERSION"
log "  WiFi:      $SSID"
log "  RNDIS:    ${DISABLE_RNDIS:-no} (mode: ${RNDIS_MODE:-gateway})"
log "  SSH:       ssh root@$DONGLE_IP"
log "  APN:       $APN"
log "  DB:        $DB_STATUS"
if $PREP_MODE; then
    log "  Status:    PREP (flash + base config, no SIM)"
    log "═══════════════════════════════════════"
    echo ""
    log "Next steps:"
    log "  1. Insert SIM card"
    log "  2. Run: ./provision.sh --skip-flash --qr-code $QR_CODE"
else
    log "═══════════════════════════════════════"
fi
