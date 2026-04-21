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

# run_with_tick LABEL -- CMD [ARGS...]
#
# Runs CMD and emits a single-line heartbeat every 10s after the first 5s
# so the operator can tell whether a silent long-running step is making
# progress or is stuck. The tick prints elapsed wall-clock time.
# Returns CMD's exit code untouched.
#
# Typical silent phases: `netbird up` (can take 10-60s while it retries
# Management + Signal), mmcli `--simple-connect` (2-10s), SSH-over-LTE
# copies, etc. Without a tick, these phases look indistinguishable from
# a deadlocked daemon.
run_with_tick() {
    local label="$1"; shift
    [ "$1" = "--" ] && shift
    local start=$SECONDS
    "$@" &
    local pid=$!
    (
        sleep 5
        while kill -0 "$pid" 2>/dev/null; do
            sleep 5
            kill -0 "$pid" 2>/dev/null && \
                printf '  [%s] still working... %ds elapsed\n' "$label" "$((SECONDS - start))"
        done
    ) &
    local tick_pid=$!
    wait "$pid"; local rc=$?
    kill "$tick_pid" 2>/dev/null; wait "$tick_pid" 2>/dev/null || true
    return "$rc"
}
# ssh_bash: pipe a local script to the dongle via stdin (no escape-hell for
# multi-line remote snippets). Arguments after the function name become $1..
# inside the script.
ssh_bash() { SSHPASS="$DONGLE_PASS" sshpass -e ssh $SSH_OPTS "$DONGLE_USER@$DONGLE_IP" "bash -s -- $*" 2>/dev/null; }
scp_cmd() { SSHPASS="$DONGLE_PASS" sshpass -e scp $SSH_OPTS "$1" "$DONGLE_USER@$DONGLE_IP:$2" 2>/dev/null; }

# ─── sync_dongle_time ───────────────────────────────────────────────────────
# The UZ801 has no RTC battery — on every cold boot its clock resets to the
# rootfs build timestamp. With a clock in the past, TLS handshakes to any
# HTTPS endpoint fail with "certificate is not yet valid" (because the server
# cert was issued *after* the dongle thinks "now" is). That kills `netbird up`
# and any NTP-over-HTTPS time-sync.
#
# The rootfs ships a `clock-sync.service`, but it needs working internet —
# which itself needs `netbird up` — which itself needs correct time. Chicken
# & egg. So we break the loop here by pushing the host clock into the dongle
# right after SSH is reachable, before we do anything that needs TLS.
sync_dongle_time() {
    local now_utc remote
    now_utc=$(date -u +'%Y-%m-%d %H:%M:%S')
    remote=$(ssh_cmd "date -u -s '$now_utc' >/dev/null 2>&1; hwclock -w 2>/dev/null; date -u +%Y-%m-%dT%H:%M:%SZ")
    if [ -n "$remote" ]; then
        log "  Time synced: dongle is now $remote (host: ${now_utc}Z)"
    else
        warn "  Time sync failed — TLS calls to NetBird may fail ('cert not yet valid')"
    fi
}

# ─── ensure_lte_data_up ─────────────────────────────────────────────────────
# ModemManager's *default-attach* bearer provides only LTE attach (registration)
# — no user data traffic. A separate *default* bearer must be created via
# --simple-connect, and its IPv4 address/gateway/DNS must be applied to wwan0
# manually (there is no DHCP on the modem's raw IP interface).
#
# The rootfs ships a `modem-autoconnect.service` that does exactly this at
# boot, but on first boot it sometimes runs before the modem has registered,
# or times out. In that case wwan0 comes up but has no IP, no default route,
# so `netbird up` hangs (and curl/ping/anything else is blackholed). This
# helper is a belt-and-suspenders: if wwan0 already looks good we skip, else
# we run simple-connect + apply bearer config ourselves.
#
# Idempotent — safe to call multiple times.
ensure_lte_data_up() {
    local apn="$1"
    local result
    result=$(ssh_bash "$apn" <<'REMOTE_LTE_UP'
set -e
apn="$1"

# Fast path: wwan0 has an IPv4 and default route is via wwan0 → done.
if ip -4 addr show wwan0 2>/dev/null | grep -q 'inet ' \
   && ip route show default 2>/dev/null | grep -q 'dev wwan0'; then
    echo "already-up"
    exit 0
fi

# Wait for modem to reach (registered|connected). On a freshly booted
# dongle the modem can be in `searching` / `enabled` for up to ~90s after
# the rootfs comes up, especially right after the APN was changed — calling
# --simple-connect while still `searching` fails hard. We poll every 3s
# up to 90s total.
state=""
for i in $(seq 1 30); do
    state=$(mmcli -m 0 -K 2>/dev/null | awk -F': +' '/^modem\.generic\.state / {print $2; exit}' | xargs)
    case "$state" in
        registered|connected) break ;;
    esac
    sleep 3
done
case "$state" in
    registered|connected) ;;
    *) echo "modem-not-registered:$state"; exit 1 ;;
esac

# Trigger a simple-connect on modem 0 (creates a 'default' bearer if none
# yet, or reuses an existing connected one).
if ! mmcli -m 0 --simple-connect="apn=$apn,ip-type=ipv4" 2>&1 | grep -q "successfully connected"; then
    # It's OK to already be connected — mmcli will say so. Anything else is an error.
    mmcli -m 0 2>&1 | grep -q "state: connected" || { echo "simple-connect-failed"; exit 1; }
fi

# Walk all bearers and pick the one that is (type=default + connected=yes).
# Avoid the default-attach bearer (same APN but no user data).
#
# Note: in ModemManager 1.20 the field is `bearer.type` (not
# `bearer.properties.type` — that sub-tree has apn, ip-type, roaming, etc.
# but NOT the bearer kind). Parse line-anchored to avoid accidental matches.
bearers=$(mmcli -m 0 -K 2>/dev/null | awk -F'[ ,]+' '/bearers/ { for(i=2;i<=NF;i++) if($i~/^\//) print $i }')
for b in $bearers; do
    out=$(mmcli -m 0 --bearer="$b" -K 2>/dev/null)
    btype=$(echo "$out" | awk -F': +' '/^bearer\.type / {print $2; exit}' | xargs)
    bconn=$(echo "$out" | awk -F': +' '/^bearer\.status\.connected / {print $2; exit}' | xargs)
    [ "$btype" = "default" ] || continue
    [ "$bconn" = "yes" ]     || continue

    ip=$(echo "$out"  | awk -F': +' '/bearer\.ipv4-config\.address/ {print $2; exit}' | xargs)
    pfx=$(echo "$out" | awk -F': +' '/bearer\.ipv4-config\.prefix/  {print $2; exit}' | xargs)
    gw=$(echo "$out"  | awk -F': +' '/bearer\.ipv4-config\.gateway/ {print $2; exit}' | xargs)
    dns=$(echo "$out" | awk -F': +' '/bearer\.ipv4-config\.dns\.value\[1\]/ {print $2; exit}' | xargs)

    [ -n "$ip" ] && [ -n "$gw" ] || continue

    ip link set wwan0 up
    ip addr flush dev wwan0 2>/dev/null || true
    ip addr add "$ip/$pfx" dev wwan0
    # Use a higher metric than the RNDIS route so host-originated traffic via
    # usb0 keeps its own gateway; only wwan0-destined traffic uses this route.
    ip route replace default via "$gw" dev wwan0 metric 200
    [ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf
    echo "configured $ip/$pfx via $gw dns=${dns:-<none>}"
    exit 0
done
echo "no-default-bearer"
exit 1
REMOTE_LTE_UP
)
    case "$result" in
        already-up)
            log "  LTE data: wwan0 already up"
            return 0
            ;;
        configured*)
            log "  LTE data: ${result#configured }"
            return 0
            ;;
        modem-not-registered:*)
            # Distinct return code 2 → caller marks the dongle as "parked",
            # skips NetBird + tests, writes a parked row to the DB and exits
            # cleanly. Rationale: no point burning 60s on netbird-up timeouts
            # and producing a wall of cascade-FAIL output when the root cause
            # is known — the SIM hasn't registered with the carrier at all.
            PARKED_DETAIL="modem state after 90s: ${result#modem-not-registered:}"
            warn "  LTE data: modem never registered (${PARKED_DETAIL})"
            return 2
            ;;
        simple-connect-failed|no-default-bearer)
            PARKED_DETAIL="$result"
            warn "  LTE data: $result"
            return 2
            ;;
        *)
            warn "  LTE data bring-up failed: ${result:-<no output>}"
            PARKED_DETAIL="${result:-unknown}"
            return 2
            ;;
    esac
}

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

# ─── Step 2b: Ensure modem firmware is present (auto-heals EDL-only flashes) ─
# On fresh boots the rootfs only ships .mdt metadata files — the actual .b00+
# segments must come from the device's own stock Android (copied via ADB/scp
# during flash). For dongles flashed in EDL-only mode (e.g. no Stock Android
# access), copy from a reference set so LTE works automatically.

REF_FW_DIR="$OPENSTICK_DIR/flash/files/uz801/modem_firmware"
MODEM_B00_PRESENT=$(ssh_cmd "[ -f /lib/firmware/modem.b00 ] && echo yes || echo no" || echo no)
FIRMWARE_HEALED=false
if [ "$MODEM_B00_PRESENT" != "yes" ]; then
    if [ -d "$REF_FW_DIR" ] && [ "$(ls "$REF_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
        warn "Modem firmware segments missing on dongle — copying reference set ($(ls "$REF_FW_DIR" | wc -l) files)"
        SSHPASS="$DONGLE_PASS" sshpass -e scp $SSH_OPTS -r "$REF_FW_DIR"/* "root@$DONGLE_IP:/lib/firmware/" 2>&1 | tail -3 || warn "scp firmware had errors (some files expected to skip)"
        log "  Restarting modem DSP + ModemManager..."
        ssh_cmd "systemctl restart rmtfs 2>/dev/null; echo stop > /sys/class/remoteproc/remoteproc0/state 2>/dev/null; sleep 2; echo start > /sys/class/remoteproc/remoteproc0/state 2>/dev/null; sleep 3; systemctl restart ModemManager"
        sleep 15
        FIRMWARE_HEALED=true
    else
        warn "Modem firmware missing and no reference set at $REF_FW_DIR — LTE will not work"
    fi
fi

# If modem-autoconnect is in failed state (common after firmware heal, or after
# a boot where firmware wasn't ready on time), restart it. systemd won't
# auto-retry failed oneshot services.
#
# Note: on a freshly-flashed dongle this restart will typically FAIL AGAIN
# because the rootfs ships with APN=internet (build default) while the real
# APN (from provision.conf) hasn't been written to /etc/default/lte-apn yet
# — Step 4 does that. On Vodafone IoT SIMs that triggers
# "ServiceOptionNotSubscribed" from the carrier. We accept this failure
# here (|| true) because the real, successful restart happens later in
# Step 4 after the APN is in place, and ensure_lte_data_up() does the
# final bring-up directly via mmcli.
AUTOCONNECT_STATE=$(ssh_cmd "systemctl is-failed modem-autoconnect 2>/dev/null" || echo unknown)
if [ "$AUTOCONNECT_STATE" = "failed" ] || $FIRMWARE_HEALED; then
    log "  Restarting modem-autoconnect (may fail on first boot if APN not yet applied — that's fine, Step 4 retries)"
    ssh_cmd "systemctl reset-failed modem-autoconnect 2>/dev/null; systemctl restart modem-autoconnect 2>/dev/null" || true
    sleep 10
fi

# ─── Step 2c: Install status LED service (cosmetic, safe on any variant) ────
# Newer rootfs builds ship this by default, but existing dongles provisioned
# from older images don't. Copy the service + helper from the OpenStick repo
# if they're missing so the WAN/WLAN indicator LEDs reflect activity
# regardless of which build the dongle is running.

LED_SERVICE_LOCAL="$OPENSTICK_DIR/build/overlay/etc/systemd/system/led-status.service"
LED_SCRIPT_LOCAL="$OPENSTICK_DIR/build/overlay/usr/local/bin/led-status.sh"
LED_SERVICE_PRESENT=$(ssh_cmd "[ -f /etc/systemd/system/led-status.service ] && echo yes || echo no" || echo no)
if [ "$LED_SERVICE_PRESENT" != "yes" ] && [ -f "$LED_SERVICE_LOCAL" ] && [ -f "$LED_SCRIPT_LOCAL" ]; then
    log "  Installing LED status service..."
    SSHPASS="$DONGLE_PASS" sshpass -e scp $SSH_OPTS "$LED_SERVICE_LOCAL" "root@$DONGLE_IP:/etc/systemd/system/led-status.service" 2>/dev/null
    SSHPASS="$DONGLE_PASS" sshpass -e scp $SSH_OPTS "$LED_SCRIPT_LOCAL"  "root@$DONGLE_IP:/usr/local/bin/led-status.sh"        2>/dev/null
    ssh_cmd "chmod +x /usr/local/bin/led-status.sh; systemctl daemon-reload; systemctl enable --now led-status.service"
fi

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

# IMSI identifies the SIM card itself (not the modem). We track it in the
# database so we can tell which SIM is in which dongle — M2M/IoT SIMs
# typically have no MSISDN (phone_number stays empty) and IMSI is the only
# stable SIM identifier. Also useful for fleet audits ("which SIM is where?").
IMSI=$(ssh_cmd "mmcli -i 0 -K 2>/dev/null | awk -F': +' '/sim.properties.imsi/{print \$2; exit}' | xargs")
[ "$IMSI" = "--" ] && IMSI=""
# SIM operator code (MCC+MNC, e.g. 26202 = Vodafone DE) — helps correlate
# IMSIs with carriers without looking up the IMSI prefix manually.
SIM_OPERATOR=$(ssh_cmd "mmcli -i 0 -K 2>/dev/null | awk -F': +' '/sim.properties.operator-code/{print \$2; exit}' | xargs")
[ "$SIM_OPERATOR" = "--" ] && SIM_OPERATOR=""

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
log "  IMSI:     ${IMSI:-<not available>}${SIM_OPERATOR:+ (MCC+MNC $SIM_OPERATOR)}"
log "  Serial:   ${SERIAL_NUMBER:-unknown}"
log "  Type:     $DONGLE_TYPE${DT_MODEL:+ ($DT_MODEL)}"
log "  HWID:     ${DONGLE_HWID:-unknown}"
log "  eMMC:     ${DONGLE_EMMC_SIZE_MB:-?} MB (${DONGLE_EMMC_SECTORS:-?} sectors)"
log "  Phone:    ${PHONE_NUMBER:-unknown}"
log "  Hostname: $HOSTNAME"
log "  WiFi:     $SSID / $PSK"

# ─── Step 4: Configure dongle ───────────────────────────────────────────────

log "=== Step 4: Configure ==="

# Hostname.
#
# CRITICAL: the rootfs ships with a default hostname `ga-3112` (build-time
# default). The netbird.service is started at boot BEFORE we get to set the
# real hostname — so when `netbird up` runs later, the daemon reports itself
# to the NetBird control plane as `ga-3112`. Because the setup-key is
# reusable/ephemeral, EVERY new dongle registers on the same NetBird peer
# entry and overwrites its predecessor. Result: only the last-provisioned
# dongle is reachable, the rest are silently gone from the admin view.
#
# Fix: after changing the hostname, restart netbird so the daemon picks it
# up before we call `netbird up`. The daemon reads the kernel hostname on
# startup.
ssh_cmd "echo '$HOSTNAME' > /etc/hostname && hostname '$HOSTNAME'"
ssh_cmd "systemctl restart netbird 2>/dev/null || true"
log "  Hostname set: $HOSTNAME (+ netbird daemon restart so the next 'netbird up' registers as a new peer, not overwriting ga-3112)"

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
# ─── LED fixes ──────────────────────────────────────────────────────────────
# Two changes here:
#
#   1. Replace /usr/local/bin/led-status.sh with a version that would use the
#      kernel's netdev trigger if present. On the current rootfs kernel,
#      CONFIG_LEDS_TRIGGER_NETDEV is NOT compiled in (we checked) — so that
#      path falls back to leaving the LED under userspace control (trigger=none).
#
#   2. Install a tiny userspace watcher (`led-lte-watcher.service`) that polls
#      ModemManager every 5s and sets the :wan LED brightness from the real
#      LTE connection state. This is the honest status light the user actually
#      wants: LED on iff wwan0 carries data.
#
# Both steps are idempotent — every provisioning run overwrites them. The
# permanent fix is to enable CONFIG_LEDS_TRIGGER_NETDEV in the rootfs kernel
# (tracked in USB-Dongle-OpenStick/TODO.md). When that happens, the watcher
# can be removed and led-status.sh alone will do the job.
ssh_bash <<'REMOTE_LED_FIX'
set -e

# (1) Improved led-status.sh — ready for kernels WITH netdev trigger.
cat > /usr/local/bin/led-status.sh <<'LED_SCRIPT'
#!/bin/sh
# led-status.sh — Configure status LEDs across different MSM8916 dongle variants.
# Updated by OpenStick-Provisioner. On kernels with CONFIG_LEDS_TRIGGER_NETDEV
# the :wan LED is wired directly to wwan0 link state. On kernels without it,
# the LED is left under userspace control — led-lte-watcher.service drives it.
set -eu

set_trigger() {
    led="$1"; preferred="$2"; fallback="$3"
    [ -d "$led" ] || return 0
    echo "$preferred" > "$led/trigger" 2>/dev/null && return 0
    echo "$fallback"  > "$led/trigger" 2>/dev/null || true
}

# Wire LED to netdev interface's link state, if kernel supports it.
# Otherwise leave trigger=none so the userspace watcher can take over.
set_trigger_netdev() {
    led="$1"; dev="$2"
    [ -d "$led" ] || return 0
    if echo netdev > "$led/trigger" 2>/dev/null && [ -f "$led/device_name" ]; then
        echo "$dev" > "$led/device_name" 2>/dev/null || true
        echo 1      > "$led/link"        2>/dev/null || true
        return 0
    fi
    echo none > "$led/trigger" 2>/dev/null || true
}

for led in /sys/class/leds/*; do
    [ -d "$led" ] || continue
    name=$(basename "$led")
    case "$name" in
        *:wan|*:wwan|*:lte|*:mobile) set_trigger_netdev "$led" wwan0 ;;
        *:wlan|*:wifi)               set_trigger "$led" phy0assoc default-on ;;
        *:power)                     echo 1 > "$led/brightness" 2>/dev/null || true ;;
    esac
done
LED_SCRIPT
chmod +x /usr/local/bin/led-status.sh

# (2) Userspace LTE link watcher — drives :wan LED based on real modem state.
cat > /usr/local/bin/led-lte-watcher.sh <<'WATCHER'
#!/bin/sh
# LTE link watcher — polls ModemManager every 5s and sets the *:wan LED
# brightness from the real connection state. Only needed on kernels without
# CONFIG_LEDS_TRIGGER_NETDEV. Remove this service (and this script) once the
# rootfs kernel has the netdev LED trigger compiled in.
set -eu
WAN_LEDS=$(ls -d /sys/class/leds/*:wan /sys/class/leds/*:wwan /sys/class/leds/*:lte /sys/class/leds/*:mobile 2>/dev/null || true)
[ -n "$WAN_LEDS" ] || exit 0
for led in $WAN_LEDS; do echo none > "$led/trigger" 2>/dev/null || true; done
while :; do
    bright=0
    if ip link show wwan0 2>/dev/null | grep -q LOWER_UP; then
        state=$(mmcli -m 0 -K 2>/dev/null | awk -F': +' '/generic.state /{print $2; exit}' | xargs)
        [ "$state" = "connected" ] && bright=1
    fi
    for led in $WAN_LEDS; do echo "$bright" > "$led/brightness" 2>/dev/null || true; done
    sleep 5
done
WATCHER
chmod +x /usr/local/bin/led-lte-watcher.sh

cat > /etc/systemd/system/led-lte-watcher.service <<'UNIT'
[Unit]
Description=LTE link watcher driving :wan LED (userspace fallback for kernels without LEDS_TRIGGER_NETDEV)
After=ModemManager.service

[Service]
Type=simple
ExecStart=/usr/local/bin/led-lte-watcher.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl restart led-status.service
systemctl enable  led-lte-watcher.service
systemctl restart led-lte-watcher.service
REMOTE_LED_FIX
log "  LED: deployed led-status.sh + led-lte-watcher.service (real LTE link state)"

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
        # Pre-requisites for `netbird up`:
        #   1. Correct system time (TLS to api.netbird.io otherwise fails with
        #      "certificate not yet valid" — dongle has no RTC, boots with
        #      the rootfs build date).
        #   2. wwan0 must carry user data (default bearer + IP + default route
        #      — the default-attach bearer alone is not enough).
        #   3. No stale NetBird identity. The rootfs *may* ship with a
        #      pre-enrolled state in /var/lib/netbird/ — if so, every dongle
        #      would register with the same WireGuard key and overwrite each
        #      other on the cloud side. We wipe that state here before the
        #      first `netbird up` so each dongle generates a fresh identity.
        #      This is safe: --setup-key re-enrolls from scratch.
        #   4. NetBird peer hostname = the fleet-wide unique QR code
        #      (SIM-WIN-XXXXXXXX), NOT the local system hostname (ga-XXXX,
        #      where XXXX is the IMEI's last 4 digits and therefore not
        #      guaranteed unique across large fleets). Using the QR makes
        #      the NetBird dashboard instantly identifiable by business
        #      ID and prevents namespace collisions entirely.
        # Both (1) and (2) should be handled by rootfs services
        # (clock-sync.service, modem-autoconnect.service) on subsequent
        # boots, but on first boot they can lose the race with this step.
        sync_dongle_time
        # ensure_lte_data_up returns 2 when the modem fails to register with
        # the carrier (SIM likely in "Stock" state, needs portal activation).
        # In that case we skip netbird-up + downstream tests and park the
        # dongle in the DB — no point waiting on cascading timeouts.
        PARKED=false
        PARKED_REASON=""
        PARKED_DETAIL=""
        if run_with_tick "LTE bring-up" -- ensure_lte_data_up "$APN"; then
            run_with_tick "netbird reset" -- \
                ssh_cmd "systemctl stop netbird 2>/dev/null; rm -rf /var/lib/netbird/* /etc/netbird.conf /etc/netbird/*.conf 2>/dev/null; systemctl start netbird 2>/dev/null; sleep 2"
            run_with_tick "netbird up" -- \
                ssh_cmd "netbird up --setup-key '$NETBIRD_SETUP_KEY' --hostname '$QR_CODE'" 2>/dev/null
        else
            PARKED=true
            PARKED_REASON="parked_sim_inactive"
            warn "  Skipping NetBird enrollment — LTE bring-up failed."
        fi
        # Capture both the peer IP and the NetBird FQDN. The FQDN is the
        # real cloud-side identifier (e.g. `ga-3112-109-63.netbird.cloud`)
        # — distinct from the dongle's local hostname (e.g. `ga-6892`).
        # Both are recorded in the DB so operators can look a device up
        # by either name and know how to SSH into it remotely.
        if ! $PARKED; then
            NB_STATUS=$(ssh_cmd "netbird status 2>/dev/null" 2>/dev/null)
            NB_IP=$(echo   "$NB_STATUS" | awk -F': +' '/NetBird IP/ {print $2; exit}' | awk '{print $1}')
            NB_FQDN=$(echo "$NB_STATUS" | awk -F': +' '/FQDN/        {print $2; exit}' | awk '{print $1}')
            log "  NetBird VPN: connected ($NB_IP, $NB_FQDN)"
        fi
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
elif [ "${PARKED:-false}" = "true" ]; then
    # Parked dongle — SIM didn't register with carrier, no LTE, no point
    # running verify tests (they'd all fail on the LTE/NetBird steps
    # without telling us anything new). Write a parked DB row so fleet
    # audits show the device with its reason, then exit with a clear
    # "parked" status. Exit code 2 is distinct from normal failure (1)
    # so wrapper scripts can distinguish "needs operator action" from
    # "bug in provisioner".
    log "=== Step 5/6/7: skipped (dongle parked: $PARKED_REASON) ==="
    source "$SCRIPT_DIR/db.sh"
    if db_load_config; then
        db_init && \
        db_record_parked "$IMEI" "${SERIAL_NUMBER:-}" "$QR_CODE" "$DONGLE_TYPE" \
            "${IMSI:-}" "${SIM_OPERATOR:-}" "$PARKED_REASON" "$PARKED_DETAIL" && \
            DB_STATUS="parked" || DB_STATUS="failed (parked write)"
    else
        DB_STATUS="no config"
    fi
    echo ""
    warn "═══════════════════════════════════════"
    warn "  DONGLE PARKED — provisioning incomplete"
    warn "  Device:     $HOSTNAME ($IMEI)"
    warn "  IMSI:       ${IMSI:-unknown}"
    warn "  Operator:   ${SIM_OPERATOR:-unknown}"
    warn "  Reason:     $PARKED_REASON"
    warn "  Detail:     $PARKED_DETAIL"
    warn "  DB status:  $DB_STATUS"
    warn ""
    warn "  Action:     check carrier portal for this SIM's status,"
    warn "              then re-provision:"
    warn "                bash provision.sh --qr-code $QR_CODE --skip-flash"
    warn "═══════════════════════════════════════"
    exit 2
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
                "${PHONE_NUMBER:-}" "${NB_IP:-}" "${NB_FQDN:-$HOSTNAME}" "$HOSTNAME" "$DONGLE_TYPE" \
                "${DONGLE_HWID:-}" "${DONGLE_MSM_ID:-}" "${DONGLE_EMMC_SECTORS:-0}" \
                "${DT_MODEL:-}" "${DT_COMPATIBLE:-}" "${IMSI:-}" "${SIM_OPERATOR:-}" && \
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
log "  Phone:     ${PHONE_NUMBER:-unknown} (M2M/IoT SIMs usually have no MSISDN)"
log "  IMSI:      ${IMSI:-unknown}${SIM_OPERATOR:+ (MCC+MNC $SIM_OPERATOR)}"
log "  Firmware:  $FIRMWARE_VERSION"
log "  WiFi:      $SSID"
log "  RNDIS:    ${DISABLE_RNDIS:-no} (mode: ${RNDIS_MODE:-gateway})"
log "  SSH:       ssh root@$DONGLE_IP"
log "  APN:       $APN"
log "  NetBird:   ${NB_IP:-<not assigned>}${NB_FQDN:+ ($NB_FQDN)}"
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
