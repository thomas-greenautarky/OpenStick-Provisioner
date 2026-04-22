# OpenStick Provisioner

Internal provisioning wrapper for [USB-Dongle-OpenStick](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick) dongles.

Handles fleet-specific configuration: WiFi PSK derivation, APN, NetBird VPN,
hostname, credentials, and **inventory tracking** via PostgreSQL.

The base firmware (Debian 12 + kernel 6.6 + LTE) is built and flashed by the
OpenStick repo. This tool orchestrates the full provisioning pipeline and records
each successfully provisioned dongle to the database.

**Two provisioning flows:**

| Flow | Script | Applies to | What it does |
|---|---|---|---|
| **Primary** | `provision.sh` | OpenStick-flashed UZ801 / JZ0145 dongles | Full flash + configure + NetBird + DB record |
| **Secondary** | `provision-arrow.sh` | **ARROW** dongles (ZTE "4G Modem" stock firmware on UZ801 hardware) | **No flash.** Configures WiFi SSID/PSK, APN, admin UI password via the stock web API so the unit becomes Kibu-compatible (same `GA-XXXX` SSID + derived PSK scheme) without replacing the firmware |

See [ARROW Dongles (No-Flash Variant)](#arrow-dongles-no-flash-variant) for the
secondary flow and [docs/arrow-api.md](docs/arrow-api.md) for the reverse-engineered
API reference.

## Quick Start

Both repos are expected to live side-by-side (the paths are relative, so any
parent directory works — the examples use `~/git/`):

```
~/git/
├── USB-Dongle-OpenStick/       # flash scripts, rootfs build, overlay, reference firmware
└── OpenStick-Provisioner/      # provisioner (this repo), DB, .env, provision.sh
```

```bash
# 1. Clone both repos
mkdir -p ~/git && cd ~/git
git clone https://github.com/thomas-greenautarky/USB-Dongle-OpenStick.git
git clone https://github.com/thomas-greenautarky/OpenStick-Provisioner.git

# 2. Set up host (one-time per provisioning machine)
cd ~/git/OpenStick-Provisioner
sudo bash setup-host.sh
# Creates NetworkManager profile 'dongle-local' that matches by driver
# (rndis_host) so flashed dongles can't hijack the host's internet.
# Also checks all required tools (edl, adb, fastboot, sgdisk, sshpass, curl,
# psql, mtools) and tells you what to install if anything is missing.

# 3. Configure secrets + database
cp .env.example .env
cp database.conf.example database.conf
# Edit .env       — OPENSTICK_WIFI_SECRET, NETBIRD_SETUP_KEY, ROOT_PASSWORD
# Edit database.conf — PostgreSQL connection (host, dbname, user, password)

# 4. (Optional) Rebuild rootfs — only needed when changing the base image
cd ~/git/USB-Dongle-OpenStick
docker build -t openstick-builder build/
docker run --rm --privileged -v $(pwd)/build/output:/output -v $(pwd)/build:/build openstick-builder

# 5. Provision a dongle: plug it in, scan QR, done
cd ~/git/OpenStick-Provisioner
bash provision.sh --qr-code SIM-WIN-00000042
```

### Updating (routine)

```bash
cd ~/git/USB-Dongle-OpenStick     && git pull
cd ~/git/OpenStick-Provisioner    && git pull
```

The OpenStick repo ships the reference modem firmware (~50 MB bundled in
`flash/files/uz801/modem_firmware/`), so `git pull` is all you need — no
separate firmware download.

### Works on

- **Laptop** (Debian/Ubuntu) — primary development environment
- **Raspberry Pi** (Pi OS bookworm) — deployment target. The scripts are
  Python-version-agnostic (pipx venv path detected via glob) and the host
  setup script detects the platform automatically.

## What runs automatically (no flags, no prompts)

The pipeline is designed to recover from every known quirk without user
intervention. For a full reasoning/history see
[`../USB-Dongle-OpenStick/docs/dongle-compatibility.md`](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick/blob/main/docs/dongle-compatibility.md)
and [`variant-strategy.md`](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick/blob/main/docs/variant-strategy.md).

| Automation | What it does |
|---|---|
| **Pre-flash probe** | Reads HWID, MSM_ID, eMMC sectors from Sahara; written to DB for fleet reporting |
| **Qualcomm factory loader (default)** | Avoids USB Overflow on 014-class dongles without `--loader` flag |
| **`--memory=emmc` everywhere** | Prevents Firehose MaxPayload mis-negotiation |
| **Skip-stock-backup by default** | Avoids USB state corruption from the 64 MB modem read; NV backup (5 reads) still runs |
| **Reference modem firmware fallback** | `flash/files/uz801/modem_firmware/` copied to rootfs if ADB backup unavailable (EDL-only flashes) |
| **Auto-heal `/lib/firmware/modem.b00`** | After SSH up, `provision.sh` checks + copies reference firmware if missing, then restarts rmtfs + remoteproc + ModemManager |
| **Modem-autoconnect reset-failed** | If the oneshot service failed at boot (firmware wasn't ready), re-trigger it post-heal |
| **LED service auto-install** | Variant-agnostic `led-status.service` installed via SSH if absent |
| **Auto-detect replug** | If a Sahara error demands power cycle, poll lsusb for disconnect + reconnect instead of waiting for Enter |
| **DT-model based type detection** | Post-boot type is read from `/sys/firmware/devicetree/base/model` — authoritative even when USB-ID heuristics fail |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `USBError(75, 'Overflow')` on first write | longcheer loader + unlucky USB endpoint | Should not happen with default qualcomm factory loader. If it does, try a different loader: `EDL_LOADER=<path> bash provision.sh …` |
| Red LED always on, blue/green off | LED triggers never configured | Reinstalled automatically on next `provision.sh` run. Manual: `systemctl restart led-status.service` |
| Modem `DeviceNotReady`, signal 0 | `/lib/firmware/modem.b00+` missing | Auto-healed on next `provision.sh --skip-flash` run. Manual: re-copy from `~/git/USB-Dongle-OpenStick/flash/files/uz801/modem_firmware/`, then restart rmtfs+remoteproc+ModemManager |
| Modem registered but no LTE bearer | `modem-autoconnect` stuck in `failed` | Auto-handled by `provision.sh`. Manual: `ssh root@dongle 'systemctl reset-failed modem-autoconnect; systemctl restart modem-autoconnect'` |
| Dongle enumerates only as EDL (`05c6:9008`) | Boot chain broken (failed flash, PBL fallback) | Re-run `provision.sh` — flash-uz801.sh accepts EDL-state dongles and re-flashes |
| Dongle doesn't enumerate at all | Hardware-level brick (sbl1 corrupted) | Needs D+/GND short on USB cable or PCB testpoint — no software recovery possible |
| Host internet drops when dongle boots | Old `enx*`-matching NM profile | Run `sudo bash setup-host.sh` — creates the correct `match.driver=rndis_host` profile |
| `netbird up` hangs forever after flash | Dongle clock in the past (no RTC battery) → TLS to `api.netbird.io` rejected with "certificate not yet valid" | Auto-handled by `provision.sh` (calls `sync_dongle_time` before `netbird up`). Manual: `ssh root@dongle date -u -s "$(date -u +'%Y-%m-%d %H:%M:%S')"` |
| LTE ping test fails on otherwise-working SIM | IoT SIMs (e.g. Vodafone `inetd.vodafone.iot`) run an **FQDN-whitelist ACL** — raw-IP ICMP/TCP to 8.8.8.8 / 1.1.1.1 is blackholed by the carrier, even though HTTPS to allowed hostnames works fine | `test-provision.sh` now probes `https://api.netbird.io/` (whitelisted, and exactly what NetBird actually needs) instead of pinging. Override with `LTE_PROBE_URL` in `provision.conf` if your ACL blocks `api.netbird.io` |
| `wwan0` has no IP, no default route after boot | `modem-autoconnect.service` lost the race on first boot (modem not yet registered) so the default bearer was never created | Auto-handled by `provision.sh` (calls `ensure_lte_data_up "$APN"` before `netbird up`: runs `mmcli --simple-connect`, then applies the bearer's IP/GW/DNS to `wwan0`). Idempotent — fine to re-run |

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
│  0a. Route guard check (dongle-no-route NM profile)   │
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
│     - RNDIS enable/disable + mode (gateway/local)      │
│  5. Verify provisioning (test-provision.sh):            │
│     ✓ Device identity (IMEI, serial, hostname)         │
│     ✓ SIM card + phone number                          │
│     ✓ WiFi hotspot (SSID, PSK, channel)                │
│     ✓ Network config (APN, timezone)                   │
│     ✓ LTE connectivity (state + ping)                  │
│     ✓ NetBird VPN (connected + IP)                     │
│     ✓ RNDIS state + mode matches config                │
│     ✓ Database record exists                           │
│  ── Record to database (only if all checks pass) ──   │
│  6. Run hardware test suite (test-dongle.sh)           │
└───────────────────────────────────────────────────────┘
```

## ARROW Dongles (No-Flash Variant)

**ARROW** is our internal name for a second type of 4G dongle in the fleet:
hardware-identical to UZ801 (same Qualcomm USB IDs, same chassis) but shipped
from the vendor with a **ZTE-style "4G Modem" stock firmware** that exposes a
JSON API on a web UI at `http://192.168.100.1` (login `admin/admin`).

We don't flash ARROWs — for this batch we configure them in place via the stock
UI so they interoperate with the Kibu devices exactly like the OpenStick dongles
do (same SSID + PSK scheme), and set the correct Vodafone IoT APN so the M2M
SIMs can get data.

### What `provision-arrow.sh` does

| Step | Target | API call |
|---|---|---|
| 1 | Login | `POST /ajax {funcNo:1000, username, password}` |
| 2 | Read IMEI, firmware version | returned by login |
| 3 | Set WiFi SSID to `GA-<IMEI-last-4>` | `funcNo:1007 {ssid, maxSta}` |
| 4 | Set WiFi PSK to HMAC-SHA256(`OPENSTICK_WIFI_SECRET`, SSID)[:16] (WPA2-PSK) | `funcNo:1010 {encryp_type:4, pwd}` |
| 5 | Write APN (from `provision.conf`) as profile 1, no user/pwd, auth=0 | `funcNo:1017 {no:1, name, apn, user:"", pwd:"", auth:"0"}` |
| 6 | Activate profile 1 | `funcNo:1018 {profile_num:1}` |
| 7 | Change admin web-UI password from `admin` to `ARROW_ADMIN_PASSWORD` | `funcNo:1020 {oldpwd, newpwd}` |
| 8 | Verify by reading back SSID / PSK / APN | `funcNo:1006, 1009, 1016` |
| 9 | **LTE internet probe:** check the ARROW reports a WAN IP distinct from its LAN IP, then HTTPS GET `LTE_PROBE_URL` through the ARROW's USB interface (temporary `/32` route, binds via `curl --interface`). Proves the Vodafone IoT APN allow-list actually routes to the probe host. | `funcNo:1002` + real traffic |
| 10 | Record to DB (`dongle_type='ARROW'`, `firmware_version='ARROW:<vendor-fw>'`); parked row on verify mismatch | `db_record_device` / `db_record_parked` |

**Skipped (by design — not applicable to ARROW):** flash, SSH, NetBird,
modem-firmware heal, LED service, RNDIS mode, hostname, timezone. The ARROW
firmware handles modem autoconnect itself.

### What doesn't go into the DB (and why)

The stock ZTE UI doesn't expose: hardware serial number, HWID, MSM_ID, eMMC
sectors, device-tree model/compatible, IMSI, SIM operator, MSISDN. Those
columns stay `NULL` for ARROW rows — which is why we store the literal
`firmware_version="ARROW:UZ801-V2.3.13"` (or whatever the vendor reports) so
ARROW rows are obvious in fleet reports.

### Kibu compatibility

An OpenStick dongle and an ARROW dongle with the same last-4-IMEI-digits
produce **identical** SSID + PSK. A Kibu paired with one will pair with the
other without reconfiguration — that's the whole reason for running ARROWs
through this tool.

### Duplicate detection (ARROW)

Before writing to the DB the provisioner checks whether the `qr_code`,
`imsi`, or `iccid` are already recorded **against a different IMEI**:

| Collision | Behavior | Rationale |
|---|---|---|
| Same IMEI (any other field matches) | Silent UPSERT | Normal re-provisioning |
| Different IMEI, **same QR** | **Hard error** — requires `FORCE_DUP=1` | Almost always means the operator scanned the wrong QR sticker |
| Different IMEI, **same IMSI** | Warn + proceed | SIMs can legitimately move between dongles (replacement/RMA) |
| Different IMEI, **same ICCID** | Warn + proceed | Same reason as IMSI |

```bash
# Override a QR collision (rare — only use after verifying the QR sticker):
FORCE_DUP=1 bash provision-arrow.sh --qr-code SIM-WIN-00000045
```

### Quick start (ARROW)

```bash
cd ~/git/OpenStick-Provisioner

# 1. One-time: pick an admin password for the ARROW web UI (static across all
#    ARROWs in the fleet). Must not be 'admin' or 'openstick'.
#    Add to .env:
echo "ARROW_ADMIN_PASSWORD=<pick-a-secret>" >> .env

# 2. Insert the Vodafone IoT SIM into the ARROW BEFORE plugging it in. The
#    LTE probe at the end of provisioning needs the SIM to be present and
#    attached. (SSID/PSK/APN config writes work without a SIM, but then the
#    LTE probe can't confirm carrier reachability — the row will be written
#    as provisioned but the LTE column will read 'no_wan_ip'.)

# 3. Plug the ARROW into USB. It presents an RNDIS interface and hands out a
#    DHCP lease on 192.168.100.0/24 (NOT 192.168.68.0/24 like OpenStick).
nmcli device show enx* | grep IP4.ADDRESS   # expect 192.168.100.xxx

# 4. Refresh sudo so the LTE probe can add/remove its temporary /32 route
#    without a prompt mid-run:
sudo -v

# 5. Provision
bash provision-arrow.sh --qr-code SIM-WIN-00000001

# 6. Re-runs on an already-provisioned ARROW work — the script tries admin/admin
#    first, then falls back to ARROW_ADMIN_PASSWORD for login.
```

### Host-internet isolation during LTE probe

The LTE probe routes **only the single test IP** via the ARROW (using a
`/32` host route + `curl --interface <usb-iface>`). The host's default
route stays on WiFi throughout. The `/32` is removed unconditionally via
a shell trap, even on Ctrl-C.

Combined with the pre-existing `dongle-local` NM profile (`ipv4.never-default`),
there is no path by which the laptop can accidentally route its own traffic
through the ARROW — neither during provisioning nor afterwards.

### CLI flags (ARROW)

| Flag | Description | Default |
|---|---|---|
| `--qr-code <CODE>` | Set QR code directly, skip interactive prompt | _(interactive prompt)_ |
| `--skip-admin-pwd` | Don't change the admin web-UI password (leave it at whatever it is — only useful for debugging) | `false` |

### Environment variables (ARROW)

| Variable | Default | Source | Purpose |
|---|---|---|---|
| `LTE_PROBE_URL_ARROW` | `$LTE_PROBE_URL` or `https://ghcr.io/` | `provision.conf` / env | Target of the LTE probe. Must be a host whitelisted by the APN's ACL (the Vodafone IoT APN blackholes everything else). Falls back to `LTE_PROBE_URL` so both scripts can share a single setting |

### Exit codes (ARROW)

| Code | Meaning |
|---|---|
| 0 | Success (SSID, PSK, APN all verified + DB recorded) |
| 1 | Any step failed (DB row written as `parked_arrow_config_fail` if verification mismatch) |

### Troubleshooting (ARROW)

| Symptom | Cause | Fix |
|---|---|---|
| `HTTP 000` from probe step | Dongle not on `192.168.100.0/24` | `nmcli device show enx*` — if no IPv4, wait ~20s for DHCP. If still nothing, unplug/replug |
| `Login failed with both admin/admin and ARROW_ADMIN_PASSWORD` | Unit has a third password (previously hand-configured) | Factory-reset via the device's reset pinhole, then re-run |
| `verify mismatch on SSID/PSK/APN` | Firmware rejected the write silently | Re-run once — the ZTE firmware is occasionally flaky on the first write after a fresh boot |
| DB row shows `firmware_version='ARROW:'` (empty after the colon) | The login response didn't include `fwversion` (older UI build) | Harmless — the row is still a valid ARROW record |
| `LTE probe: ARROW reports no WAN IP (IP=192.168.100.1, wlan_ip=192.168.100.1)` | No SIM / SIM not registered / APN not applied yet | Insert SIM, wait ~30s for carrier attach, re-run with `--skip-admin-pwd` if admin pwd already changed |
| `LTE probe: curl failed reaching <host> (HTTP 000)` | Probe host is not on the APN ACL | Change `LTE_PROBE_URL_ARROW` in `provision.conf` to a host that IS on the ACL (e.g. `https://api.netbird.io/` for Vodafone IoT) |
| `LTE probe: couldn't add /32 route (sudo not passwordless?)` | `sudo` credential cache expired | Run `sudo -v` before `provision-arrow.sh` to cache credentials. The probe degrades to API-only (the config + WAN-IP check still run) but won't confirm carrier reachability |

## Route Guard

When the dongle boots with RNDIS enabled, it presents a USB ethernet interface
(`enx*`) with a DHCP server that may advertise a default gateway. If the host
accepts this route, all internet traffic gets routed through the dongle's LTE
connection — breaking the provisioning machine's internet.

This is prevented by a **permanent NetworkManager profile** installed once on the
host machine. It matches all USB ethernet interfaces and ensures they never
become the default route:

```bash
# Install once per provisioning machine (survives reboots)
nmcli connection add type ethernet con-name "dongle-no-route" \
    match.interface-name "enx*" \
    ipv4.never-default yes ipv4.dns-priority 200 \
    ipv6.method disabled connection.autoconnect yes \
    connection.autoconnect-priority 100
```

The provisioner checks for this profile at startup and warns if it's missing.
No `sudo` or cleanup required — the profile is persistent and stateless.

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
| `phone_number` | `TEXT` | SIM MSISDN (often empty on M2M/IoT SIMs — use `imsi` instead) |
| `imsi` | `TEXT` (indexed) | SIM IMSI — stable per-SIM identifier; tracks SIM movements between dongles |
| `sim_operator` | `TEXT` | MCC+MNC code from SIM (e.g. `26202` = Vodafone DE) |
| `netbird_ip` | `TEXT` | NetBird VPN IP address |
| `netbird_hostname` | `TEXT` | NetBird peer name (= dongle hostname) |
| `hostname` | `TEXT` | Dongle hostname (e.g. `ga-3112`) |
| `brand` | `TEXT` | Firmware / provisioning flavor: `OpenStick` or `ARROW` (NULL for pre-2026-04 rows) |
| `dongle_type` | `TEXT` | Hardware variant: `UZ801`, `JZ0145-v33`, or `unknown` |
| `iccid` | `TEXT` (indexed) | SIM ICCID (printed on the physical card) — unique per SIM |
| `hwid` | `TEXT` | Full Qualcomm HWID (e.g. `0x007050e100000000`) |
| `msm_id` | `TEXT` | Chip family ID (e.g. `0x007050e1` = MSM8916/APQ8016) |
| `emmc_sectors` | `BIGINT` | eMMC size in 512-byte sectors |
| `dt_model` | `TEXT` | Device-tree model string (`uz801 v3.0 4G Modem Stick`, etc.) |
| `dt_compatible` | `TEXT` | Device-tree compatible string(s) |
| `provisioned_at` | `TIMESTAMPTZ` | Timestamp of successful provisioning |

Re-provisioning the same dongle (same IMEI) updates the existing row (UPSERT).
Chipset fields (HWID, MSM_ID, eMMC sectors) are captured during the pre-flash
EDL probe; DT fields are read from the running Debian post-boot.

The schema auto-migrates — older deployments are extended with
`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` on every run.

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

**Test sections (9 sections, ~25 checks):**

| # | Section | Tests | Description |
|---|---------|-------|-------------|
| 1 | **Device Identity** | IMEI, hostname, hardware serial | IMEI readable, hostname = `ga-XXXX` from IMEI, serial from device tree/cpuinfo/eMMC |
| 2 | **SIM + Phone** | SIM detected, phone number | SIM card present, phone number from carrier (skip if not provided) |
| 3 | **WiFi Hotspot** | Active, SSID, PSK, channel | Hotspot connection active, SSID = `GA-XXXX`, PSK matches HMAC derivation, channel from config |
| 4 | **Network Config** | APN, timezone | APN matches `provision.conf`, timezone set correctly |
| 5 | **LTE Connectivity** | Modem state, ping | Modem connected, ping to 8.8.8.8 succeeds |
| 6 | **NetBird VPN** | Status, IP | Connected + IP assigned (skip if no setup key) |
| 7 | **RNDIS** | State | Matches `DISABLE_RNDIS` from config |
| 7a | **RNDIS Mode** | dnsmasq, iptables, forwarding | `gateway`: NAT + forwarding active; `local`: no gateway/DNS/NAT on USB |
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
| `RNDIS_MODE` | `local` | USB network mode: `gateway` (share LTE internet) or `local` (SSH only, no internet sharing) |
| `FIRMWARE_VERSION` | `v1.0` | Image version label for DB tracking |

### Secrets (`.env`)

| Setting | Used by | Description |
|---------|---------|-------------|
| `OPENSTICK_WIFI_SECRET` | `provision.sh`, `provision-arrow.sh` | 256-bit hex key for WiFi PSK derivation (fleet-wide). Shared so OpenStick and ARROW dongles with the same last-4 IMEI produce identical PSKs |
| `NETBIRD_SETUP_KEY` | `provision.sh` | NetBird VPN setup key (from NetBird dashboard) |
| `ROOT_PASSWORD` | `provision.sh` | SSH root password set during OpenStick provisioning |
| `ARROW_ADMIN_PASSWORD` | `provision-arrow.sh` | Web-UI admin password for ARROW dongles. Static across all ARROWs. Must not be `admin` or `openstick` |

## File Structure

```
├── .env.example          # Template for secrets
├── .env                  # Actual secrets (gitignored)
├── database.conf.example # Template for database connection
├── database.conf         # Actual DB credentials (gitignored)
├── provision.sh          # Primary provisioning script (flash + configure OpenStick dongles)
├── provision-arrow.sh    # Secondary: configure ARROW dongles via stock web API (no flash)
├── provision.conf        # Fleet configuration (APN, timezone, version, etc.)
├── db.sh                 # Database helper functions (sourced by provision.sh / provision-arrow.sh)
├── test-provision.sh     # Provisioning verification test suite
├── docs/
│   └── arrow-api.md      # Reverse-engineered ZTE "4G Modem" web API reference
├── logs/                 # Per-run provisioning logs (gitignored)
└── README.md
```

## Prerequisites

| Dependency | Install | Purpose |
|------------|---------|---------|
| [USB-Dongle-OpenStick](https://github.com/thomas-greenautarky/USB-Dongle-OpenStick) | Clone + build | Base firmware image + flash scripts + test suite |
| `sshpass` | `apt install sshpass` | SSH automation with password |
| `edl` | `pipx install git+https://github.com/bkerler/edl.git` | Qualcomm EDL flash protocol |
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
