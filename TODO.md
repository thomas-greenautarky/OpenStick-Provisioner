# OpenStick-Provisioner — TODO

Items tracked here belong to the **provisioning pipeline** (provision.sh,
provision-arrow.sh, test-provision.sh, db.sh, setup-host.sh). Rootfs-side
TODOs live in `USB-Dongle-OpenStick/TODO.md`.

## ARROW dongles (no-flash variant)

- [ ] **Active verification of the configured ARROW** — today
      `provision-arrow.sh` reads SSID/PSK/APN back via the web API and
      compares, but doesn't prove the **radio is actually beaconing** with
      the new SSID or that the APN change produced a working LTE session.
      Parallels the existing OpenStick "WiFi hotspot: passive vs. active
      verification" TODO below. Probably wants to be folded into the same
      active-test feature when that lands.

- [ ] **Admin password rotation helper** for when `ARROW_ADMIN_PASSWORD` is
      leaked / rotated. Today a rotation requires walking each ARROW unit
      back through `provision-arrow.sh` with the new value in `.env` — the
      script already handles this transparently (re-login falls back to
      the new-but-now-old value), but a batch mode that reads IMEI → unit
      IP mapping from the DB and rotates the lot would be nice for larger
      fleets.

- [ ] **Re-verify funcNo map** on any ARROW firmware other than
      `UZ801-V2.3.13` before trusting [docs/arrow-api.md](docs/arrow-api.md).
      Vendor firmware varies; the funcNo values have been seen to shift on
      unrelated ZTE OEMs.

## Remove after rootfs catches up

- [ ] Once `USB-Dongle-OpenStick` ships with `CONFIG_LEDS_TRIGGER_NETDEV`
      enabled in the kernel, remove the `led-lte-watcher.service`
      deployment from `provision.sh` and let `led-status.sh` handle the
      LED via the kernel trigger alone.
      See: `USB-Dongle-OpenStick/TODO.md` — "Kernel config".

- [ ] Once rootfs `clock-sync.service` is robust (retries, waits for
      network + wwan0 default route), remove the `sync_dongle_time`
      call from `provision.sh`. Manual time push is a bandaid for the
      "no RTC battery + first-boot race" problem.

- [ ] Once rootfs `modem-autoconnect.service` reliably brings up wwan0
      with IP + default route on first boot, remove `ensure_lte_data_up`
      from `provision.sh`. The current implementation is defensive — it
      re-runs `mmcli --simple-connect` and reconfigures wwan0 even if
      the rootfs service already did its job, which is redundant but safe.

## ACL / carrier-side

- [x] Vodafone IoT `EP_GreenAutarky_ACL` audit (15 entries):
      - ✅ NTP: `time.cloudflare.com` IS in the ACL
      - ✅ Tailscale auth: `login.tailscale.com` IS in the ACL
      - ✅ NetBird stack complete: `api.netbird.io`, `*.relay.netbird.io`,
        `signal.netbird.io`
      - ✅ Tailscale stack complete: `controlplane.tailscale.com`,
        `*.derp.tailscale.com`, `login.tailscale.com`, `log.tailscale.com`
      - ✅ Backend: `*.greenautarky.com` (root `greenautarky.com` not in
        list — only matters if direct root-FQDN access is needed)
      - ⚪ Not critical, not in ACL: `deb.debian.org`, `security.debian.org`
        (needed only if `apt upgrade` is run on dongles), `pkgs.tailscale.com`,
        OCSP/CRL (`*.pki.goog`, `*.letsencrypt.org`)
      Bottom line: ACL is sufficient for NetBird (setup-key flow) + Tailscale
      + container workloads + backend access. No blockers.

- [ ] Point the rootfs `clock-sync.service` at `time.cloudflare.com` (now
      that we know it's whitelisted). Once that works reliably on first
      boot, the Provisioner's `sync_dongle_time` bandaid can be removed.
      See `USB-Dongle-OpenStick/TODO.md`.

- [ ] For full Tailscale + Funnel functionality on dongles, the ACL needs:
      - `controlplane.tailscale.com` ✓ (already present)
      - `*.derp.tailscale.com` ✓ (already present)
      - `login.tailscale.com` 🟡 (check if in the 5 invisible entries —
        required for first-auth and periodic re-auth)
      - `log.tailscale.io` 🟢 (optional — telemetry; Tailscale runs fine
        without it)
      - `pkgs.tailscale.com` 🟢 (only if tailscaled is apt-updated on dongles)
      Funnel itself needs no extra outbound ACLs — inbound Funnel traffic
      is received over DERP/Tailscale, not carrier IP, so the APN ACL
      doesn't gate it.

- [ ] Connection resets observed to `api.netbird.io` from the Vodafone IoT
      SIM, even though the FQDN is in the ACL. Root cause not identified
      — possibly IP-range drift in the ACL, possibly TLS-SNI filtering.
      Workaround: `LTE_PROBE_URL` defaults to `https://ghcr.io/` now.
      Long-term: ask Vodafone to investigate, or switch the test to a
      Greenautarky-owned FQDN (once `greenautarky.com` root is resolvable).

## Hardening

- [ ] Consider SSH key-only auth on the dongles once NetBird is stable
      (ship a public key in the rootfs, disable password auth). Today the
      provisioner still uses `openstick` as default password.

- [ ] **Per-dongle root password, deterministically derived from the QR code**
      (DISCUSS before implementing):
      ```
      ROOT_PW = sha256(ROOT_PW_SECRET || QR_CODE)[:16]
      ```
      Today all provisioned dongles share the same `ROOT_PASSWORD` from
      `.env` — a single leak compromises the whole fleet. A per-dongle
      derivation gives us:
      - one compromised dongle ≠ fleet compromise
      - no DB lookup needed to find a specific dongle's password — the
        back office can reconstruct it from the QR + the secret alone
        (same trick as the WiFi PSK derivation already uses)
      - still reproducible (lose the DB? as long as the QR sticker is on
        the device and the secret is in a vault, you can always log in)

      Open questions for the discussion:
      1. Where to store `ROOT_PW_SECRET`? Same `.env` as
         `OPENSTICK_WIFI_SECRET`, or a separate vault entry (it's higher-
         impact than the WiFi PSK secret — compromise = root on every
         dongle)?
      2. Do we still record the *derived* password in the DB for
         operational convenience, or force the back office to derive on
         demand? Storing it is DRY but widens the blast radius of a DB
         breach; deriving on demand keeps the DB useless without the
         secret.
      3. Migration: run a batch `--skip-flash` re-provision on the
         existing fleet to rotate everyone to per-dongle passwords,
         or accept a mixed-mode transition period?
      4. Does this interact with the SSH-key-only hardening above? If we
         go key-only, per-dongle passwords become a defense-in-depth
         nicety rather than the primary auth — still worth it for
         recovery/emergency access.

- [ ] Add `provision.conf` option to select LTE probe URL per fleet —
      currently hardcoded to `api.netbird.io`, but that FQDN is
      carrier-ACL-sensitive. `LTE_PROBE_URL` env override is already
      wired in `test-provision.sh`; expose it in `provision.conf`.

## WiFi hotspot: passive vs. active verification (DISCUSS)

- [ ] Today's WiFi tests (test-provision.sh §3 + test-dongle.sh §7) are
      **purely config-based**: NM connection active, SSID matches, PSK
      matches HMAC derivation, channel set, WCNSS firmware+NV present,
      `wlan0` interface exists. None of these touch the actual radio.

      A dongle that silently **fails to beacon** (e.g. hostapd crashed
      right after start, wlan0 stuck in `dormant`, calibration botched
      but firmware loaded) would still PASS all today's checks. Only a
      customer would notice — when their device can't see the SSID.

      Two escalation levels to discuss:

      **Level 1 — cheap local sanity (5 min to build):**
      ```
      iw dev wlan0 info            # must show type=AP, channel=<WIFI_CHANNEL>
      ip -br link show wlan0       # must be UP (not DOWN/dormant)
      iw dev wlan0 get hostapd-cli # (on some builds) lists running state
      ```
      Runs on the dongle itself, no extra hardware. Catches hostapd
      crashes and interface-down states. Doesn't prove the radio is
      *transmitting*, but rules out the top two failure modes.

      **Level 2 — real end-to-end (heavier):**
      A second device (a dedicated test Kibu, a Raspberry Pi with a
      USB WiFi dongle, or the provisioning laptop's WiFi *if* it's
      free) scans for the SSID, connects with the derived PSK, pulls
      an IP via DHCP, and makes an HTTPS request that has to route
      through the dongle's LTE back to the internet. That proves the
      full chain: radio → AP → DHCP → NAT → LTE.

      Open questions:
      1. Is there a dedicated test device at the provisioning station,
         or would we ask the operator to bring their phone / laptop?
      2. The provisioning laptop's WiFi is normally in use for the
         *uplink* (NM-managed). Adding a scan against the dongle-AP
         requires either a second WiFi dongle on the laptop or
         sharing the iwlwifi radio carefully.
      3. Do we want the active test to block provisioning (FAIL blocks
         DB write) or only log? An active test that depends on external
         hardware shouldn't block the critical path.
      4. Level 2 overlaps with the planned Kibu+Funnel end-to-end test
         (also in this TODO) — probably these should be the same feature,
         not two separate ones.

      **Hard non-goal** (lessons from setup-host.sh's `unmanaged=…`
      disaster earlier this session): any active test MUST NOT touch
      the provisioning laptop's own WiFi uplink. NM-managed primary
      interface stays off-limits. Test hardware lives external to the
      laptop: a dedicated Kibu/Pi, or a second USB WiFi radio with its
      own NM profile scoped to that device only. The laptop-WiFi
      compromise pattern is: if the only option is "borrow the
      laptop's own radio", we don't ship the active test.

## Validation tests

- [ ] End-to-end **Kibu + Tailscale Funnel** validation (optional
      `--test-kibu` flag on `provision.sh`, or separate script).
      Idea: just after Step 7 system tests pass, spin up a mini e2e
      that proves a real downstream workload works through the dongle.

      Steps:
      1. Attach a reference Kibu to the dongle's WiFi hotspot
         (GA-XXXX, PSK from derive_wifi_psk).
      2. On the Kibu: verify it got an IP from 192.168.4.0/24 and
         the gateway is 192.168.4.1 (the dongle).
      3. On the Kibu: `curl https://ghcr.io/` — proves the dongle's
         MASQUERADE path works and the ACL lets the Kibu through.
      4. On the Kibu: `tailscale up --authkey <key>` — proves Tailscale
         enroll works via LTE (ACL has controlplane + login + derp +
         log all whitelisted, plus time.cloudflare.com for NTP).
      5. On the Kibu: `tailscale funnel 8080 on` — exposes a local
         service publicly via Funnel.
      6. From the provisioning host (or external runner): fetch the
         funnel URL, assert HTTP 200 and expected content.
      7. Record latency, bytes-transferred (relevant for IoT SIM
         data cap), and which DERP region was used.

      Why this matters: all 7 post-flash test categories can PASS
      while the real workload — "a Kibu should be reachable from
      outside via Funnel" — still fails for reasons the current
      tests don't cover (Tailscale tag/ACL mismatches, Funnel
      feature not enabled on the tailnet, DERP reachability quirks
      specific to this carrier, etc.). An e2e test catches those.

      Caveats to design for:
      - Data-cap-awareness: limit probe payload size (< few KB).
      - Don't burn a real setup-key per test run: use a short-lived
        OAuth key or a per-fleet reusable key with expiry.
      - Only run when `--test-kibu` is explicitly requested — not
        every provisioning run needs physical Kibu hardware present.

## Observability

- [ ] Stream `provision.sh` output into the DB (per-device log blob) so
      fleet failures can be diagnosed without tailing tmux panes.

- [ ] Record IMSI→dongle moves as history rows instead of overwriting —
      today `db_record_device` does an UPSERT, so we lose the trail when
      a SIM is swapped into a different dongle. A small `sim_history`
      table keyed on (imsi, provisioned_at) would fix this.
