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

## Observability

- [ ] Stream `provision.sh` output into the DB (per-device log blob) so
      fleet failures can be diagnosed without tailing tmux panes.

- [ ] Record IMSI→dongle moves as history rows instead of overwriting —
      today `db_record_device` does an UPSERT, so we lose the trail when
      a SIM is swapped into a different dongle. A small `sim_history`
      table keyed on (imsi, provisioned_at) would fix this.
