#!/bin/bash
#
# setup-host.sh — One-time setup for the provisioning host machine
#
# Configures NetworkManager to handle USB dongles safely:
# - Static IP on USB ethernet (enx*) — no DHCP, no DNS, no default route
# - Prevents the dongle from disrupting the host's internet connection
#
# Works on: Laptop (Debian/Ubuntu), Raspberry Pi (with NetworkManager)
#
# Usage:
#   sudo bash setup-host.sh
#   # or without sudo if user has NM permissions

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# Check NetworkManager
which nmcli >/dev/null 2>&1 || err "NetworkManager (nmcli) not found. Install: apt install network-manager"

# Remove old profiles
for old in "dongle-no-route" "dongle-unmanaged" "dongle-local" "dongle-provision"; do
    nmcli connection delete "$old" 2>/dev/null && log "Removed old profile: $old" || true
done

# Create the USB dongle profile
log "Creating NM profile 'dongle-local' for USB dongle interfaces..."
# Match by driver 'rndis_host' (= RNDIS USB gadget from flashed dongles)
# This avoids matching real USB ethernet adapters (r8152, asix, etc.)
nmcli connection add type ethernet con-name "dongle-local" \
    match.driver "rndis_host" \
    ipv4.method auto \
    ipv4.never-default yes \
    ipv4.dns "" \
    ipv4.dns-priority 999 \
    ipv4.ignore-auto-dns yes \
    ipv6.method disabled \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 2>/dev/null

log "Profile 'dongle-local' created:"
log "  Match:      driver=rndis_host (RNDIS dongles only, not real ethernet)"
log "  IP:         DHCP (works for both Stock Android and flashed dongles)"
log "  DNS:        ignored (host DNS untouched)"
log "  Route:      never-default (host internet untouched)"

# Check dependencies
log ""
log "Checking provisioning dependencies..."
MISSING=0
for cmd in edl adb fastboot sgdisk sshpass curl psql; do
    if which "$cmd" >/dev/null 2>&1; then
        log "  $cmd: $(which $cmd)"
    else
        warn "  $cmd: NOT FOUND"
        MISSING=$((MISSING + 1))
    fi
done

if [ "$MISSING" -gt 0 ]; then
    echo ""
    warn "Install missing dependencies:"
    warn "  apt install adb fastboot gdisk sshpass curl postgresql-client mtools"
    warn "  pipx install edlclient"
fi

log ""
log "Host setup complete!"
log "Provisioning: ./provision.sh --qr-code SIM-WIN-XXXXXXXX"
