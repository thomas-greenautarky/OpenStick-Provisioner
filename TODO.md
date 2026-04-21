# OpenStick-Provisioner — TODO

Items tracked here belong to the **provisioning pipeline** (provision.sh,
test-provision.sh, db.sh, setup-host.sh). Rootfs-side TODOs live in
`USB-Dongle-OpenStick/TODO.md`.

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

- [ ] Add `provision.conf` option to select LTE probe URL per fleet —
      currently hardcoded to `api.netbird.io`, but that FQDN is
      carrier-ACL-sensitive. `LTE_PROBE_URL` env override is already
      wired in `test-provision.sh`; expose it in `provision.conf`.

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
