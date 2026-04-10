# OpenStick Provisioner

Internal provisioning wrapper for [USB-Dongle-OpenStick](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick) dongles.

Handles fleet-specific configuration: WiFi PSK derivation, APN, NetBird VPN,
hostname, credentials, and **inventory tracking** via PostgreSQL.

The base firmware (Debian 12 + kernel 6.6 + LTE) is built and flashed by the
OpenStick repo. This tool orchestrates the full provisioning pipeline and records
each successfully provisioned dongle to the database.

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

# 3. Set up secrets + database config
cd ../OpenStick-Provisioner
cp .env.example .env
cp database.conf.example database.conf
# Edit .env and database.conf with real values

# 4. Install dependencies
sudo apt install sshpass postgresql-client
pipx install edlclient

# 5. Flash + provision a dongle
#    - Enter EDL: hold reset button while plugging in USB
bash provision.sh
```

## Usage

```bash
# Full provisioning (interactive QR scan prompt + flash)
bash provision.sh

# Skip QR prompt — pass QR code directly
bash provision.sh --qr-code SIM-WIN-00000001

# Skip flash — only configure an already-running dongle
bash provision.sh --skip-flash

# Combine flags
bash provision.sh --skip-flash --qr-code SIM-WIN-00000001

# Override firmware version label (default: from provision.conf, initially v1.0)
bash provision.sh --firmware-version v1.1

# Only run provisioning verification tests
bash provision.sh --test-provision

# Only run hardware test suite (from OpenStick repo, no flash, no configure)
bash provision.sh --test-only
```

### CLI Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--qr-code <CODE>` | Set QR code directly, skip interactive scan prompt | _(interactive prompt)_ |
| `--firmware-version <VER>` | Override firmware version label for DB | `FIRMWARE_VERSION` from `provision.conf` |
| `--skip-flash` | Skip EDL flash (Step 1), only configure | `false` |
| `--test-only` | Only run the hardware test suite (OpenStick), skip everything else | `false` |
| `--test-provision` | Only run provisioning verification tests, skip everything else | `false` |

## Provisioning Pipeline

```
┌───────────────────────────────────────────────────────┐
│  provision.sh                                          │
│                                                        │
│  0. QR Code scan (Bluetooth scanner or --qr-code)     │
│  1. Flash base image (calls OpenStick flash)           │
│  2. Wait for boot + SSH                                │
│  3. Device identification:                             │
│     - IMEI (modem, via mmcli)                          │
│     - Hardware serial number (device tree / cpuinfo)   │
│     - SIM phone number (via mmcli)                     │
│     - Derive hostname + WiFi SSID from IMEI            │
│  4. Configure:                                         │
│     - Hostname (ga-XXXX from IMEI)                     │
│     - APN (from provision.conf)                        │
│     - Timezone                                         │
│     - Root password                                    │
│     - WiFi hotspot (SSID + derived PSK)                │
│     - NetBird VPN (setup key from .env)                │
│     - RNDIS enable/disable                             │
│  5. Verify provisioning (test-provision.sh):            │
│     ✓ Device identity (IMEI, serial, hostname)         │
│     ✓ SIM card + phone number                          │
│     ✓ WiFi hotspot (SSID, PSK, channel)                │
│     ✓ Network config (APN, timezone)                   │
│     ✓ LTE connectivity (state + ping)                  │
│     ✓ NetBird VPN (connected + IP)                     │
│     ✓ RNDIS state matches config                       │
│     ✓ Database record exists                           │
│  ── Record to database (only if all checks pass) ──   │
│  6. Run hardware test suite (test-dongle.sh)           │
└───────────────────────────────────────────────────────┘
```

## QR Code Scanning

The provisioner supports two methods for QR code input:

### Bluetooth Barcode Scanner (recommended)

A Bluetooth barcode scanner paired with the provisioning machine acts as a HID
keyboard. When Step 0 prompts `Scan QR code (or type manually):`, scanning a
QR code types the value followed by Enter — the script reads it via `read`.

**Note:** The Bluetooth scanner must be set to **German keyboard layout** to
correctly interpret special characters like `-`.

### CLI Flag

For scripted or automated use, pass the QR code directly:

```bash
bash provision.sh --qr-code SIM-WIN-00000001
```

### QR Code Format

The expected format is `SIM-WIN-XXXXXXXX` (8 digits), but the script accepts
any non-empty string to allow flexibility.

## Device Identification

Three identifiers are read from each dongle during Step 3:

| Identifier | Source | Purpose |
|------------|--------|---------|
| **IMEI** | `mmcli -m 0` (modem) | Primary key in DB, used to derive hostname + WiFi SSID |
| **Serial Number** | `/sys/firmware/devicetree/base/serial-number`, `/proc/cpuinfo`, or eMMC CID | Hardware identifier, independent of SIM/modem |
| **Phone Number** | `mmcli -m 0` (SIM `own-numbers`) | SIM card phone number for reference |

The serial number is read with three fallbacks:

1. **Device tree** — `/sys/firmware/devicetree/base/serial-number` (most reliable)
2. **CPU info** — `grep Serial /proc/cpuinfo` (Qualcomm SoC serial)
3. **eMMC CID** — `/sys/block/mmcblk0/device/cid` (storage chip identifier)

## Database Tracking

Successfully provisioned dongles are recorded in a PostgreSQL database. The
database write only happens when **all verification checks pass** (Step 5).

### Setup

```bash
# Copy the example config and fill in credentials
cp database.conf.example database.conf
```

The provisioner uses the same PostgreSQL instance as
[ga-flasher-py](https://github.com/thomas-greenautarky/ga-flasher-py) but with
its own schema (`dongle_flasher`). The schema and table are created automatically
on first run.

### Configuration (`database.conf`)

```ini
host=10.0.1.154
port=5432
dbname=ga_database
user=root
password=<your_password>
schema=dongle_flasher
```

This file is gitignored. See `database.conf.example` for a template.

### Database Schema

**Table: `dongle_flasher.devices`**

| Column | Type | Description |
|--------|------|-------------|
| `id` | `SERIAL PRIMARY KEY` | Auto-increment ID |
| `imei` | `TEXT UNIQUE NOT NULL` | Modem IMEI (primary identifier) |
| `serial_number` | `TEXT` | Hardware serial (device tree / cpuinfo / eMMC) |
| `qr_code` | `TEXT` | Scanned QR code (e.g. `SIM-WIN-00000001`) |
| `firmware_version` | `TEXT NOT NULL` | Image version label (e.g. `v1.0`) |
| `phone_number` | `TEXT` | SIM card phone number |
| `netbird_ip` | `TEXT` | NetBird VPN IP address |
| `netbird_hostname` | `TEXT` | NetBird peer name (= dongle hostname) |
| `hostname` | `TEXT` | Dongle hostname (e.g. `ga-3112`) |
| `provisioned_at` | `TIMESTAMPTZ` | Timestamp of successful provisioning |

Re-provisioning the same dongle (same IMEI) updates the existing row (UPSERT).

### Querying the Database

```bash
# List all provisioned dongles
psql -h 10.0.1.154 -U root -d ga_database \
  -c "SELECT imei, serial_number, qr_code, firmware_version, phone_number, netbird_ip, hostname, provisioned_at FROM dongle_flasher.devices ORDER BY provisioned_at DESC;"

# Find a specific dongle by QR code
psql -h 10.0.1.154 -U root -d ga_database \
  -c "SELECT * FROM dongle_flasher.devices WHERE qr_code = 'SIM-WIN-00000001';"

# Count provisioned dongles per firmware version
psql -h 10.0.1.154 -U root -d ga_database \
  -c "SELECT firmware_version, COUNT(*) FROM dongle_flasher.devices GROUP BY firmware_version;"
```

### Behavior on DB Errors

If the database is unreachable or the write fails, the provisioner prints a
warning but **does not abort**. The dongle is already provisioned at this point
— the DB record is informational. The summary output shows `DB: no config`,
`DB: failed`, or `DB: recorded` accordingly.

## Test Suites

The provisioner uses **two test suites** at different abstraction levels:

### Provisioning Tests (`test-provision.sh`) — this repo

Fleet-specific verification that all provisioning settings were applied correctly.
Requires `provision.conf` + `.env` to know the expected values (SSID derived from
IMEI, APN from config, etc.).

```bash
# Standalone
bash test-provision.sh                          # defaults (192.168.68.1, openstick)
bash test-provision.sh 192.168.68.1 mypassword  # custom host + pass

# Via provision.sh
bash provision.sh --test-provision
```

**Test sections (8 sections, ~20 checks):**

| # | Section | Tests | Description |
|---|---------|-------|-------------|
| 1 | **Device Identity** | IMEI, hostname, hardware serial | IMEI readable, hostname = `ga-XXXX` from IMEI, serial from device tree/cpuinfo/eMMC |
| 2 | **SIM + Phone** | SIM detected, phone number | SIM card present, phone number from carrier (skip if not provided) |
| 3 | **WiFi Hotspot** | Active, SSID, PSK, channel | Hotspot connection active, SSID = `GA-XXXX`, PSK matches HMAC derivation, channel from config |
| 4 | **Network Config** | APN, timezone | APN matches `provision.conf`, timezone set correctly |
| 5 | **LTE Connectivity** | Modem state, ping | Modem connected, ping to 8.8.8.8 succeeds |
| 6 | **NetBird VPN** | Status, IP | Connected + IP assigned (skip if no setup key) |
| 7 | **RNDIS** | State | Matches `DISABLE_RNDIS` from config |
| 8 | **Database** | Connection, record | DB reachable, record exists for this IMEI (skip if no `database.conf`) |

**Exit codes:**
- `0` = all passed (with optional skips)
- `1` = one or more failures

**When it runs:** Automatically during provisioning as Step 5. The exit code determines
whether the database record is written — only successful verifications are recorded.

### Hardware Tests (`test-dongle.sh`) — OpenStick repo

Low-level hardware and OS verification. Tests the base Debian image, kernel, services,
modem firmware, networking stack, and boot persistence. Works on any dongle regardless
of fleet-specific provisioning.

```bash
# Standalone
bash ../USB-Dongle-OpenStick/flash/test-dongle.sh

# Via provision.sh
bash provision.sh --test-only
```

**Test sections (11 sections, ~48 checks):**

| # | Section | Description |
|---|---------|-------------|
| 1 | USB RNDIS | RNDIS gadget detected, host can ping dongle |
| 2 | SSH Access | SSH login works (aborts if not) |
| 3 | System Basics | Kernel 6.6-msm8916, Debian 12, hostname, systemd, usrmerge |
| 4 | Kernel Modules | nf_nat, nf_conntrack, nf_tables, xt_MASQUERADE, qcom_bam_dmux, rmnet |
| 5 | Services | ssh, dnsmasq, usb-gadget, rmtfs, ModemManager |
| 6 | USB Network | usb0 IP (192.168.68.1/24), IP forwarding |
| 7 | Modem | Firmware files, WiFi NV calibration, NV storage, DSP, QMI, IMEI, SIM, wlan0 |
| 8 | LTE Data | Bearer connected, ping 8.8.8.8, DNS resolution |
| 9 | NAT Gateway | iptables MASQUERADE rule |
| 10 | Boot Persistence | iptables rules.v4, services enabled, clock sync, APN config |
| 11 | Resources | Free disk, available RAM, uptime (informational) |

### Test flow during full provisioning

```
provision.sh
  ├── Step 0-4: QR scan, flash, SSH, identify, configure
  ├── Step 5: bash test-provision.sh  ← provisioning checks (this repo)
  │   └── Exit code 0? → write DB record
  └── Step 6: bash test-dongle.sh     ← hardware checks (OpenStick repo)
```

## WiFi PSK Derivation

Each dongle gets a **deterministic WiFi password** derived from its IMEI:

```
SSID = "GA-" + last_4_digits_of_IMEI
PSK  = HMAC-SHA256(OPENSTICK_WIFI_SECRET, SSID)[:16]
```

This allows KiBu devices to auto-connect to any dongle without per-device pairing.
The shared secret is in `.env` (never committed).

## Configuration Reference

### Fleet Settings (`provision.conf`)

| Setting | Example | Description |
|---------|---------|-------------|
| `APN` | `internet.telekom` | LTE Access Point Name (carrier-specific) |
| `TIMEZONE` | `Europe/Berlin` | Device timezone |
| `OPENSTICK_REPO` | `../USB-Dongle-OpenStick` | Path to OpenStick repo |
| `DONGLE_IP` | `192.168.68.1` | RNDIS USB IP address |
| `DONGLE_USER` | `root` | SSH username |
| `DONGLE_PASS` | `openstick` | SSH password (before root password change) |
| `WIFI_CHANNEL` | `6` | WiFi AP channel |
| `WIFI_BAND` | `bg` | WiFi band (`bg` = 2.4 GHz) |
| `DISABLE_RNDIS` | `no` | Disable USB ethernet gadget after provisioning |
| `FIRMWARE_VERSION` | `v1.0` | Image version label for DB tracking |

### Secrets (`.env`)

| Setting | Description |
|---------|-------------|
| `OPENSTICK_WIFI_SECRET` | 256-bit hex key for WiFi PSK derivation |
| `NETBIRD_SETUP_KEY` | NetBird VPN setup key (from NetBird dashboard) |
| `ROOT_PASSWORD` | Root password set during provisioning |

## File Structure

```
├── .env.example          # Template for secrets
├── .env                  # Actual secrets (gitignored)
├── database.conf.example # Template for database connection
├── database.conf         # Actual DB credentials (gitignored)
├── provision.sh          # Main provisioning script
├── provision.conf        # Fleet configuration (APN, timezone, version, etc.)
├── db.sh                 # Database helper functions (sourced by provision.sh)
├── test-provision.sh     # Provisioning verification test suite
└── README.md
```

## Prerequisites

| Dependency | Install | Purpose |
|------------|---------|---------|
| [USB-Dongle-OpenStick](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick) | Clone + build | Base firmware image + flash scripts + test suite |
| `sshpass` | `apt install sshpass` | SSH automation with password |
| `edl` | `pipx install edlclient` | Qualcomm EDL flash protocol |
| `psql` | `apt install postgresql-client` | Database writes (optional — provisioning works without) |
| `openssl` | _(pre-installed)_ | WiFi PSK derivation (HMAC-SHA256) |

## CE/RED Compliance

Each dongle's factory IMEI and RF calibration data is preserved during provisioning.
The flash script auto-backups the device-specific modem partitions (modemst1, modemst2,
fsg) before flashing and restores them afterwards. No RF parameters are modified.

## Example Output

```
[+] === Step 0: QR Code ===
[+] Scan QR code (or type manually): SIM-WIN-00000001
[+]   QR Code: SIM-WIN-00000001
[+] === Step 1: Flash base image ===
[+] Flashing via EDL...
[+] === Step 2: Waiting for SSH ===
[+] SSH connected.
[+] === Step 3: Device identification ===
[+]   IMEI:     867034059483112
[+]   Serial:   a1b2c3d4e5f6
[+]   Phone:    +4915112345678
[+]   Hostname: ga-3112
[+]   WiFi:     GA-3112 / 8f2a1b3c4d5e6f70
[+] === Step 4: Configure ===
[+]   Hostname set: ga-3112
[+]   APN set: internet.telekom
[+]   Timezone: Europe/Berlin
[+]   Root password changed
[+]   WiFi: GA-3112 (PSK derived)
[+]   NetBird VPN: connected (100.119.45.23)
[+] === Step 5: Verify provisioning ===
[+]   ✓ Hostname: ga-3112
[+]   ✓ APN: internet.telekom
[+]   ✓ Timezone: Europe/Berlin
[+]   ✓ WiFi AP: GA-3112 (active on wlan0)
[+]   ✓ NetBird: connected (100.119.45.23)
[+]   ✓ RNDIS: active
[+]   ✓ LTE: connected
[+]   All verifications passed
[+]   DB: device recorded
[+] === Step 6: System test ===
[+] Running 48 tests...
[+] All tests passed.

[+] ═══════════════════════════════════════
[+]   Provisioning complete!
[+]   Device:    ga-3112 (867034059483112)
[+]   Serial:    a1b2c3d4e5f6
[+]   QR Code:   SIM-WIN-00000001
[+]   Phone:     +4915112345678
[+]   Firmware:  v1.0
[+]   WiFi:      GA-3112
[+]   SSH:       ssh root@192.168.68.1
[+]   APN:       internet.telekom
[+]   DB:        recorded
[+] ═══════════════════════════════════════
```
