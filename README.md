# OpenStick Provisioner

Internal provisioning wrapper for [USB-Dongle-OpenStick](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick) dongles.

Handles fleet-specific configuration: WiFi PSK derivation, APN, NetBird VPN,
hostname, and credentials. The base firmware (Debian 12 + kernel 6.6 + LTE)
is built and flashed by the OpenStick repo.

## Quick Start

```bash
# 1. Clone both repos
git clone https://github.com/thomas-greenautarky/USB-Dongle-OpenStick.git
git clone https://github.com/thomas-greenautarky/OpenStick-Provisioner.git

# 2. Build the base image (once)
cd USB-Dongle-OpenStick
docker build -t openstick-builder build/
docker run --rm --privileged -v $(pwd)/build/output:/output openstick-builder
simg2img build/output/rootfs.img flash/files/rootfs.raw
cp build/output/boot.img flash/files/boot.img

# 3. Set up secrets
cd ../OpenStick-Provisioner
cp .env.example .env
# Edit .env with real values

# 4. Flash + provision a dongle
#    - Enter EDL: hold reset button while plugging in USB
bash provision.sh
```

## What It Does

```
┌──────────────────────────────────────────────────┐
│  provision.sh                                     │
│                                                   │
│  1. Flash base image (calls OpenStick flash)      │
│  2. Wait for boot + SSH                           │
│  3. Copy device NV storage (IMEI/RF cal)          │
│  4. Configure:                                    │
│     - Hostname (GA-XXXX from IMEI)                │
│     - APN (from provision.conf)                   │
│     - Timezone                                    │
│     - Root password                               │
│     - WiFi hotspot (SSID + derived PSK)           │
│     - NetBird VPN (setup key from .env)           │
│     - RNDIS enable/disable                        │
│  5. Verify all settings:                          │
│     ✓ Hostname matches                            │
│     ✓ APN config correct                          │
│     ✓ Timezone set                                │
│     ✓ WiFi AP active with correct SSID            │
│     ✓ NetBird connected + IP                      │
│     ✓ RNDIS state matches config                  │
│     ✓ LTE connected                               │
│  6. Run 48-test system test suite                 │
└──────────────────────────────────────────────────┘
```

## WiFi PSK Derivation

Each dongle gets a **deterministic WiFi password** derived from its IMEI:

```
SSID = "GA-" + last_4_digits_of_IMEI
PSK  = HMAC-SHA256(OPENSTICK_WIFI_SECRET, SSID)[:16]
```

This allows KiBu devices to auto-connect to any dongle without per-device pairing.
The shared secret is in `.env` (never committed).

## Configuration

| Setting | Source | Example | Verified |
|---------|--------|---------|----------|
| APN | `provision.conf` | `internet.telekom` | ✓ |
| Timezone | `provision.conf` | `Europe/Berlin` | ✓ |
| Disable RNDIS | `provision.conf` | `no` / `yes` | ✓ |
| WiFi secret | `.env` | 256-bit hex key | — |
| NetBird key | `.env` | Setup key from dashboard | ✓ connected |
| Root password | `.env` | Chosen per fleet | — |
| Hostname | Auto-derived | `ga-3112` (from IMEI) | ✓ |
| WiFi SSID | Auto-derived | `GA-3112` | ✓ active |
| WiFi PSK | Auto-derived | HMAC-SHA256 output | — |
| LTE | Auto-connect | `connected` | ✓ |

## File Structure

```
├── .env.example        # Template for secrets
├── .env                # Actual secrets (gitignored)
├── provision.sh        # Main provisioning script
├── provision.conf      # Fleet configuration (APN, timezone, etc.)
└── README.md
```

## Prerequisites

- [USB-Dongle-OpenStick](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick) cloned and built
- `sshpass` installed (`apt install sshpass`)
- `edl` installed (`pipx install edlclient`)
- Dongle in EDL mode (reset button + USB plug)

## CE/RED Compliance

Each dongle's factory IMEI and RF calibration data is preserved during provisioning.
The flash script auto-backups the device-specific modem partitions (modemst1, modemst2,
fsg) before flashing and restores them afterwards. No RF parameters are modified.
