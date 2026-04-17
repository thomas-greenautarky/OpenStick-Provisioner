#!/bin/bash
#
# setup-host.sh — One-time setup for the provisioning host machine.
#
# Safely prepares the machine to run provision.sh without disturbing any
# existing network configuration:
#
#   1. Detects the current network stack (ifupdown / dhcpcd / systemd-networkd
#      / NetworkManager) and how interfaces are currently managed.
#   2. If NetworkManager is missing, installs it AFTER writing a strict
#      `unmanaged-devices=except:driver:rndis_host` config, so on first
#      start NM only touches USB dongle interfaces — everything else
#      (eth0, VLANs, macvlans, tailscale, wireguard, docker, etc.) is
#      left alone.
#   3. Creates the "dongle-local" NetworkManager profile (DHCP, no default
#      route, no DNS, no IPv6) so flashed dongles can never hijack the
#      host's internet.
#   4. Checks the rest of the provisioning toolchain (edl, adb, fastboot,
#      sgdisk, sshpass, curl, psql, mtools) and offers to install anything
#      missing — or prints exactly what to run.
#
# Usage:
#   sudo bash setup-host.sh          # interactive
#   sudo bash setup-host.sh --yes    # non-interactive (accept all installs)
#
# Works on: Debian (bookworm/trixie), Ubuntu, Raspberry Pi OS.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

ASSUME_YES=false
[ "${1:-}" = "--yes" ] && ASSUME_YES=true

confirm() {
    $ASSUME_YES && return 0
    echo -ne "${YELLOW}[?]${NC} $1 [y/N] "
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# ─── Step 0: Require root for package installs + NM config writes ───────────

if [ "$(id -u)" -ne 0 ]; then
    err "Must run as root (use sudo): sudo bash $0"
fi

# ─── Step 1: Analyze current network state ─────────────────────────────────

log "=== Step 1: Network stack analysis ==="
OS_PRETTY=$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
log "  OS:                    $OS_PRETTY"

has_nm=$(command -v nmcli >/dev/null 2>&1 && echo yes || echo no)
nm_active=$(systemctl is-active NetworkManager 2>/dev/null || echo inactive)
dhcpcd_active=$(systemctl is-active dhcpcd 2>/dev/null || echo inactive)
networkd_active=$(systemctl is-active systemd-networkd 2>/dev/null || echo inactive)
ifupdown_active=$(systemctl is-active networking 2>/dev/null || echo inactive)

log "  NetworkManager:        installed=$has_nm active=$nm_active"
log "  dhcpcd:                active=$dhcpcd_active"
log "  systemd-networkd:      active=$networkd_active"
log "  ifupdown (networking): active=$ifupdown_active"

# Show current default route so we can verify later we didn't break it
CURRENT_DEFAULT=$(ip route show default 2>/dev/null | head -1)
log "  Default route:         ${CURRENT_DEFAULT:-<none>}"

# ─── Step 2: Install NetworkManager safely if missing ───────────────────────

if [ "$has_nm" = "no" ]; then
    log "=== Step 2: Install NetworkManager ==="
    warn "NetworkManager is not installed. It will be configured to manage ONLY"
    warn "RNDIS USB dongles (match driver=rndis_host). Every existing interface"
    warn "(eth*, wlan*, vlan*, tailscale*, wt*, docker*, veth*) stays untouched."
    if ! confirm "Install network-manager now?"; then
        err "Aborted. Install manually later, then rerun this script."
    fi

    # Write the strict config BEFORE installing so NM picks it up on first start.
    # This is critical on hosts with complex ifupdown/tailscale/docker setups —
    # without it, NM would try to manage everything and likely disrupt routing.
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-only-rndis.conf <<'EOF'
[keyfile]
# Leave everything alone except RNDIS USB gadgets (our flashed dongles).
# Installed by OpenStick-Provisioner setup-host.sh to keep NetworkManager
# from disturbing existing eth0/VLAN/macvlan/tailscale/docker/etc. setups.
unmanaged-devices=except:driver:rndis_host
EOF
    log "  Wrote /etc/NetworkManager/conf.d/99-only-rndis.conf"

    log "  Installing network-manager package..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager

    log "  Enabling + starting NetworkManager..."
    systemctl enable --now NetworkManager

    # Verify the unmanaged exception applied
    sleep 3
    unmanaged_count=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -c unmanaged || true)
    managed_count=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -cE "connected|activated" || true)
    log "  nmcli: $unmanaged_count interfaces unmanaged, $managed_count externally managed"

    # Verify default route still there
    NEW_DEFAULT=$(ip route show default 2>/dev/null | head -1)
    if [ "$NEW_DEFAULT" != "$CURRENT_DEFAULT" ]; then
        warn "Default route CHANGED: was '$CURRENT_DEFAULT', now '$NEW_DEFAULT'"
        warn "If you lost connectivity, rollback: systemctl disable --now NetworkManager"
    else
        log "  Default route unchanged — host connectivity preserved."
    fi
else
    log "=== Step 2: NetworkManager already installed (skipping install) ==="
    # Still ensure the strict config exists if we didn't install NM ourselves —
    # skip if admin clearly configured NM for broader use already.
    if [ ! -f /etc/NetworkManager/conf.d/99-only-rndis.conf ] \
       && [ "$ifupdown_active" = "active" -o "$dhcpcd_active" = "active" ]; then
        warn "Detected co-existing ifupdown/dhcpcd — installing the strict"
        warn "NM-only-rndis config so we don't fight them."
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/99-only-rndis.conf <<'EOF'
[keyfile]
unmanaged-devices=except:driver:rndis_host
EOF
        systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager
        log "  NM restricted to rndis_host only."
    fi
fi

# ─── Step 3: Install the dongle-local NM profile ───────────────────────────

log "=== Step 3: dongle-local NM profile ==="
# Remove any obsolete profiles from previous setups
for old in "dongle-no-route" "dongle-unmanaged" "dongle-local" "dongle-provision"; do
    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$old"; then
        nmcli connection delete "$old" 2>/dev/null && log "  Removed old profile: $old" || true
    fi
done

log "  Creating NM profile 'dongle-local'..."
# Match by driver 'rndis_host' (= RNDIS USB gadget from flashed dongles).
# This avoids matching real USB ethernet adapters (r8152, asix, etc.).
nmcli connection add type ethernet con-name "dongle-local" \
    match.driver "rndis_host" \
    ipv4.method auto \
    ipv4.never-default yes \
    ipv4.dns "" \
    ipv4.dns-priority 999 \
    ipv4.ignore-auto-dns yes \
    ipv6.method disabled \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 >/dev/null

log "  Match:   driver=rndis_host (RNDIS dongles only, not real ethernet)"
log "  IP:      DHCP (works for Stock Android + flashed dongles)"
log "  DNS:     ignored (host DNS untouched)"
log "  Route:   never-default (host internet untouched)"

# ─── Step 4: Dependency check + optional auto-install ──────────────────────

log "=== Step 4: Provisioning tool dependencies ==="

declare -A APT_PKG=(
    [adb]=adb
    [fastboot]=fastboot
    [sgdisk]=gdisk
    [sshpass]=sshpass
    [curl]=curl
    [psql]=postgresql-client
    [mcopy]=mtools
)

MISSING_APT=()
for cmd in adb fastboot sgdisk sshpass curl psql mcopy; do
    if command -v "$cmd" >/dev/null 2>&1; then
        log "  $cmd: $(command -v $cmd)"
    else
        warn "  $cmd: NOT FOUND (provides: ${APT_PKG[$cmd]})"
        MISSING_APT+=("${APT_PKG[$cmd]}")
    fi
done

if [ ${#MISSING_APT[@]} -gt 0 ]; then
    echo ""
    warn "Missing apt packages: ${MISSING_APT[*]}"
    if confirm "Install them now via apt?"; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_APT[@]}"
        log "  Installed."
    else
        warn "  Skipping. Install later with:"
        warn "    sudo apt install ${MISSING_APT[*]}"
    fi
fi

# edl is a special case — comes from pipx, must be installed as the non-root
# user so it lands in ~/.local/share/pipx/venvs/, not in root's home.
# Note: edlclient was REMOVED from PyPI, so we install from the upstream git
# repo (which is also what flash-uz801.sh's loader-path resolution expects).
ORIG_USER="${SUDO_USER:-$USER}"
ORIG_HOME=$(getent passwd "$ORIG_USER" | cut -d: -f6)

if sudo -u "$ORIG_USER" -i bash -c 'command -v edl' >/dev/null 2>&1 \
   || [ -x "$ORIG_HOME/.local/bin/edl" ]; then
    log "  edl: present (pipx) for user $ORIG_USER"
else
    warn "  edl: NOT FOUND"
    if ! sudo -u "$ORIG_USER" -i bash -c 'command -v pipx' >/dev/null 2>&1; then
        log "  Installing pipx (required for edl)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y pipx
        sudo -u "$ORIG_USER" -i bash -c 'pipx ensurepath' >/dev/null 2>&1 || true
    fi
    if confirm "Install edl now via 'pipx install git+https://github.com/bkerler/edl.git' as user $ORIG_USER?"; then
        log "  Installing edl from upstream git (this can take 2-5 min)..."
        if sudo -u "$ORIG_USER" -i bash -c 'pipx install git+https://github.com/bkerler/edl.git'; then
            log "  edl installed successfully."
        else
            warn "  edl install failed. Install manually:"
            warn "    pipx install git+https://github.com/bkerler/edl.git"
        fi
    else
        warn "  Skipping edl install. Install manually as user $ORIG_USER:"
        warn "    pipx install git+https://github.com/bkerler/edl.git"
    fi
fi

# ─── Done ──────────────────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════════════════════"
log "  Host setup complete!"
log ""
log "  Verify:"
log "    nmcli device status        # eth0/VLANs/etc. must stay 'unmanaged'"
log "    ip route show default      # must still be via your gateway"
log ""
log "  Provision a dongle:"
log "    bash provision.sh --qr-code SIM-WIN-XXXXXXXX"
log "═══════════════════════════════════════════════════════"
