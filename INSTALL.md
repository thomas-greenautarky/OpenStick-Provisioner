# Installation Guide

How to set up a machine (laptop or Raspberry Pi) to provision dongles.

For code/script structure see [README.md](README.md). This doc is purely
**setup / install / first run**.

---

## 1. Layout

Both repos are expected to sit side-by-side. The example paths use `~/git/`
but any parent directory works — the scripts use relative paths internally.

```
~/git/
├── USB-Dongle-OpenStick/       # flash scripts, rootfs build, overlay, reference firmware
└── OpenStick-Provisioner/      # this repo — provision.sh, .env, DB config
```

```bash
mkdir -p ~/git && cd ~/git
git clone https://github.com/thomas-greenautarky/USB-Dongle-OpenStick.git
git clone https://github.com/thomas-greenautarky/OpenStick-Provisioner.git
```

---

## 2. Run the host setup script

`setup-host.sh` is the single entry point. It's **safe on complex hosts**
(ifupdown + VLANs + macvlans + Tailscale + WireGuard + Docker bridges all
coexist — validated on a production Debian 13 / trixie Pi) because it:

1. Analyzes the current network stack and shows what's active.
2. Only installs NetworkManager if missing, and **before** that install
   writes a strict `unmanaged-devices=except:driver:rndis_host` config so
   NM only ever touches flashed dongle interfaces — never eth0, VLANs,
   Tailscale, Docker, etc.
3. Verifies the default route is unchanged after NM comes up.
4. Creates the `dongle-local` NetworkManager profile (match by
   `driver=rndis_host` — won't collide with real USB ethernet adapters).
5. Checks the provisioning toolchain and offers to install anything missing.

```bash
cd ~/git/OpenStick-Provisioner
sudo bash setup-host.sh              # interactive (asks before installing)
# or:
sudo bash setup-host.sh --yes        # non-interactive — accept all installs
```

### What the script touches

| Location | What | Reversible? |
|---|---|---|
| `/etc/NetworkManager/conf.d/99-only-rndis.conf` | Strict NM config (rndis-only) | Yes — delete + restart NM |
| `/etc/NetworkManager/system-connections/dongle-local.nmconnection` | Dongle profile | Yes — `nmcli connection delete dongle-local` |
| apt packages (network-manager, adb, fastboot, gdisk, sshpass, postgresql-client, mtools) | Standard Debian packages | Yes — apt remove |
| `pipx install git+https://github.com/bkerler/edl.git` | Runs as your user, not root | Yes — `pipx uninstall edlclient` |

Nothing in `/etc/network/interfaces`, `/etc/systemd/network/`, or
`/etc/dhcpcd.conf` is modified.

---

## 3. Verify the host is safe

After `setup-host.sh`, check these three things. All three must still match
their pre-setup state:

```bash
# (a) Your main interfaces must be "unmanaged" (or "connected (externally)"
#     for things like Tailscale, Docker, WireGuard). Only rndis_host-driver
#     dongles should ever become 'connected' under NM control.
nmcli device status

# (b) Default route unchanged.
ip route show default

# (c) Internet still works.
ping -c 2 1.1.1.1
```

**Red flags:**
- `nmcli` shows `eth0` as `connected` (not `unmanaged`) → NM is trying to
  manage it. Fix: verify `/etc/NetworkManager/conf.d/99-only-rndis.conf`
  exists and restart NM.
- Default route gone or changed → something else took over. Roll back:
  `sudo systemctl disable --now NetworkManager`.

---

## 4. Secrets + database config

```bash
cd ~/git/OpenStick-Provisioner
cp .env.example .env
cp database.conf.example database.conf
$EDITOR .env database.conf
```

### `.env` (gitignored)

| Variable | Purpose |
|---|---|
| `OPENSTICK_WIFI_SECRET` | 256-bit hex — HMAC key for WiFi PSK derivation. Generate with `openssl rand -hex 32`. Must be the same on every machine that provisions dongles in the same fleet. |
| `NETBIRD_SETUP_KEY` | NetBird setup key from `https://app.netbird.io → Setup Keys`. Used to auto-join each dongle to your NetBird network. |
| `ROOT_PASSWORD` | Password set on the dongle's Debian root account during provisioning. |

### `database.conf` (gitignored)

```ini
host=10.0.1.154
port=5432
dbname=ga_database
user=root
password=<your_password>
schema=dongle_flasher
```

Optional — if absent, provisioning still runs but the dongle isn't
recorded in the fleet database.

---

## 5. First provisioning run

```bash
# Plug in a dongle (Stock Android boots in ~15 s → RNDIS enumerates)
# Then:
cd ~/git/OpenStick-Provisioner
bash provision.sh --qr-code SIM-WIN-00000042
```

A successful run takes ~5 minutes end-to-end: flash → boot → config →
LTE → NetBird → Verify → DB → System test.

See [README.md](README.md) for the full test matrix and troubleshooting.

---

## Updating

```bash
cd ~/git/USB-Dongle-OpenStick     && git pull
cd ~/git/OpenStick-Provisioner    && git pull
```

No rebuild needed — the OpenStick repo ships the reference modem firmware
(~50 MB in `flash/files/uz801/modem_firmware/`) directly.

---

## Notes for Raspberry Pi

- The setup is validated on **Debian 13 / trixie** (also Pi OS bookworm-based).
- Works alongside **ifupdown** (`/etc/network/interfaces`) — NM doesn't touch it.
- Works alongside **dhcpcd** — NM doesn't touch interfaces dhcpcd manages.
- Works alongside **Tailscale, WireGuard, Docker, VLANs, macvlans** —
  all stay "connected (externally)" in nmcli and untouched.
- `edl` comes from `pipx install git+https://github.com/bkerler/edl.git` — do this **as your normal
  user**, not as root. On a headless Pi:
  ```bash
  sudo apt install pipx
  pipx ensurepath
  pipx install git+https://github.com/bkerler/edl.git
  # Log out + back in, or source ~/.bashrc, so 'edl' is in $PATH.
  ```
