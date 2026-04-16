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
log "Creating NM profile 'dongle-local' for USB dongle interfaces (enx*)..."
nmcli connection add type ethernet con-name "dongle-local" \
    match.interface-name "enx*" \
    ipv4.method manual \
    ipv4.addresses "192.168.68.100/24" \
    ipv4.never-default yes \
    ipv4.dns "" \
    ipv4.dns-priority 999 \
    ipv6.method disabled \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 2>/dev/null

log "Profile 'dongle-local' created:"
log "  Interface:  enx* (any USB ethernet)"
log "  IP:         192.168.68.100/24 (static, no DHCP)"
log "  DNS:        none (host DNS untouched)"
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
