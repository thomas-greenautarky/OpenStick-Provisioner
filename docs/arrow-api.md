# ARROW Dongle — ZTE "4G Modem" Web API Reference

Reverse-engineered reference for the stock firmware exposed by **ARROW**-type
dongles (vendor-shipped UZ801 hardware running a ZTE-style "4G Modem" stock UI
instead of OpenStick). This is what `provision-arrow.sh` speaks.

Confirmed on firmware build `UZ801-V2.3.13` (April 2026). If we encounter a
different firmware revision, re-verify against the live unit before trusting
these funcNo values.

## Transport

- **Base URL:** `http://192.168.100.1/`
- **API endpoint:** `POST /ajax`
- **Request body:** JSON, `Content-Type: application/json`
- **Auth:** session cookie issued by `funcNo:1000` (login). Send cookie back on
  every subsequent request.
- **Required headers** (empirically — the UI sends these, server accepts
  requests with them; some funcNos reject requests without the Referer):
  - `Content-Type: application/json`
  - `Referer: http://192.168.100.1/`
  - `X-Requested-With: XMLHttpRequest`

## Response envelope

All calls return the same shape on success:

```json
{
  "results": [ {...} ],
  "error_info": "none",
  "flag": "1"
}
```

- `flag == "1"` — success. `results[0]` carries the payload.
- Any other value of `flag` — failure. `error_info` carries the reason.
- `flag` is always a **string** in responses, even though funcNo is a number
  in requests.

**Inconsistency wart:** some failure responses are **NOT JSON** — the firmware
returns 6 literal bytes `flag:0` (no quotes, no braces), with `Content-Type:
text/json;charset=UTF-8` still claimed in the header. Parsers must treat any
response not starting with `{` as a failure. Observed when parameter types are
wrong (see below).

**Strict typing:** numeric-looking parameters (like `no`, `profile_num`, `auth`)
must be sent as **strings** (`"1"`, `"0"`), not JSON numbers (`1`, `0`). The
UI reads them from DOM attributes / radio-button IDs and never casts. Sending
a number returns the plain-text `flag:0` response above.

## Function codes

Discovered by reading the UI's own JavaScript (`/js/index.js`,
`/js/wifiSetting.js`, `/js/wifiSecurity.js`, `/js/wwanConfig.js`,
`/js/modifyPwd.js`). No vendor docs exist.

### `1000` — Login

**Request**

```json
{"funcNo": 1000, "username": "admin", "password": "admin"}
```

**Response `results[0]`**

| Field | Example | Notes |
|---|---|---|
| `imei` | `"860018046015369"` | 15-digit IMEI — primary device identifier |
| `fwversion` | `"UZ801-V2.3.13"` | Vendor firmware label |
| `conn_mode` | `"1"` | `1` = auto-connect, `0` = manual |
| `net_mode` | `0` | `0`=Auto, `1`=3G only, `2`=4G only |

Sets a session cookie (name varies by jetty build — just use the cookie jar).

Factory-default credentials: `admin` / `admin`.

### `1006` — Get WiFi SSID settings

**Request:** `{"funcNo": 1006}`

**Response `results[0]`**

| Field | Example | Notes |
|---|---|---|
| `ssid` | `"4G-UFI-230"` | Current SSID |
| `maxSta` | `10` | Max WiFi clients (1-10) |
| `client_num` | `0` | Currently connected clients |
| `mac` | `"a0:8d:f8:68:e2:30"` | AP MAC |
| `wifi_status` | `"1"` | `1` = on |
| `channel` | `6` | 2.4 GHz channel |
| `mode` | `"n"` | 802.11 mode |
| `ssid_flag` | `"1"` | `1` = broadcast, `0` = hidden |
| `ip` | `"192.168.100.1"` | AP gateway IP |

### `1007` — Set WiFi SSID

**Request**

```json
{"funcNo": 1007, "ssid": "GA-5369", "maxSta": 10}
```

**Constraints**
- SSID length 4–32 characters (UI enforces via `ssidVal.length < 4 || > 32`).
- `maxSta` must match one of the UI's pre-defined options (1..10).

### `1009` — Get WiFi security settings

**Request:** `{"funcNo": 1009}`

**Response `results[0]`**

| Field | Example | Notes |
|---|---|---|
| `pwd` | `"1234567890"` | Current WPA-PSK (plaintext) |
| `encryp_type` | `4` | see below |

### `1010` — Set WiFi security

**Request**

```json
{"funcNo": 1010, "encryp_type": 4, "pwd": "abcd1234efgh5678"}
```

**Constraints**
- `pwd` must match `/^[a-zA-Z0-9]{8,64}$/` (alphanumeric, 8–64 chars). The
  OpenStick HMAC-derived PSK (`head -c 16` of lowercase hex digest) satisfies
  this by construction.
- `encryp_type` values (inferred from the UI's `<select>`):

  | Value | Meaning |
  |---|---|
  | `0` | Open (no encryption) |
  | `1` | WEP |
  | `2` | WPA-PSK |
  | `3` | WPA2-PSK (TKIP) |
  | `4` | **WPA2-PSK (AES) — use this** |
  | `5` | WPA/WPA2-PSK mixed |

  `provision-arrow.sh` always writes `4` to match the factory default and
  stay consistent with OpenStick's `wpa-psk` mode.

### `1016` — Get APN profile list

**Request:** `{"funcNo": 1016}`

**Response `results[0]`**

| Field | Example | Notes |
|---|---|---|
| `info_arr` | `[]` or `[{no,name,apn,user,pwd,auth},...]` | Custom profiles (1..5) |
| `profile_num` | `0` | Currently active profile: `0` = auto, `1`..`5` = custom |

Factory-fresh units return `info_arr: []` and `profile_num: 0`.

### `1017` — Write APN profile

**Request**

```json
{
  "funcNo": 1017,
  "no": 1,
  "name": "fleet",
  "apn": "inetd.vodafone.iot",
  "user": "",
  "pwd": "",
  "auth": "0"
}
```

**Fields**

| Field | Notes |
|---|---|
| `no` | Profile slot, **must be a string** `"1"`..`"5"` — sending a number returns `flag:0` (plain text) |
| `name` | Human label shown in the UI |
| `apn` | Access Point Name (**required** — UI rejects empty) |
| `user` | PAP/CHAP username (empty string if no auth) |
| `pwd` | PAP/CHAP password (empty string if no auth) |
| `auth` | **string**: `"0"` = None, `"1"` = PAP, `"2"` = CHAP, `"3"` = PAP/CHAP |

For Vodafone IoT (`inetd.vodafone.iot`) use `auth: "0"` with empty user/pwd —
same as `mmcli --simple-connect=apn=...,ip-type=ipv4` with no credentials on
the OpenStick side.

### `1018` — Activate APN profile

**Request**

```json
{"funcNo": 1018, "profile_num": "1"}
```

`profile_num` is also a string — same strict-typing rule as `1017.no`.

`profile_num: 0` activates the auto profile (firmware picks). For the fleet
we always activate `1` right after writing it via `1017` so the APN change
takes effect immediately, not on next reboot.

### `1015` — Get SIM info

**Request:** `{"funcNo": 1015}`

**Response `results[0]`**

| Field | Example | Notes |
|---|---|---|
| `imsi` | `"901289017243109"` | 15-digit IMSI (empty string when no SIM) |
| `iccid` | `"89882390001460821581"` | 19–20 digit ICCID printed on the physical SIM |
| `sim_status` | `"Ready"` | one of `Ready`, `Absent`, `Pin Required`, `PUK Required`, `Network Locked` |

**MCC+MNC derivation:** IMSI prefix = 3-digit MCC + 2–3-digit MNC. For our
Vodafone IoT fleet the IMSIs start with `901 28` (MCC=901 roaming / global,
MNC=28) or `262 02` (MCC=262 Germany, MNC=02 Vodafone). `provision-arrow.sh`
stores `IMSI[0:5]` as `sim_operator` — correct for 2-digit-MNC carriers,
off-by-one for the rare 3-digit-MNC case.

### `1029` — Get device info

**Request:** `{"funcNo": 1029}`

**Response `results[0]`**

| Field | Example | Notes |
|---|---|---|
| `imei` | `"860018046015369"` | Same IMEI that `1000` returns |
| `fwversion` | `"V2.3.13"` | Vendor firmware (short form — `1000` returns the long form `UZ801-V2.3.13`) |
| `manufacture` | `"Qualcomm Technology"` | Manufacturer string reported by the modem |
| `dbm` | `" -105 dBm"` | Current RSSI (signed, dBm, with leading space) — live signal strength |

Mostly informational — `provision-arrow.sh` logs these but only writes
`manufacture` implicitly (via the `ARROW:` prefix in `firmware_version`).

### `1020` — Change admin web-UI password

**Request**

```json
{"funcNo": 1020, "oldpwd": "admin", "newpwd": "gEWbWzbeLHvcWjfzR0yC"}
```

Firmware rejects `oldpwd == newpwd` (returns `flag != "1"` with
`error_info: "cannotSame"`). Session cookie stays valid after a successful
password change — you don't need to re-login unless you explicitly sign out.
Any new browser tab must use the new password.

The UI's JS has a regex `/^[a-zA-Z0-9]$/` for password validation but it's
**commented out** — in practice the server accepts longer strings with
non-alphanumeric characters. We still constrain to alphanumeric in
`provision-arrow.sh` to stay safely within whatever the UI can display.

## Discovered-but-unused funcNos

These appear in the UI JS but `provision-arrow.sh` doesn't call them. Noted
here so a future extension doesn't have to re-discover them.

| funcNo | Page | Purpose |
|---|---|---|
| `1002` | `status.js` | Get WAN IP, mask, DNS (used only for the LTE probe in `provision-arrow.sh`) |
| `1003` | `status.js` | Get data counters (up/down bytes, client count) — useful for a future "data cap" audit |
| `1004` | `status.js` | Set connection mode (auto/manual). Observed: activating a custom APN profile via `1018` flips `conn_mode` from `"1"` (auto) to `"0"` (manual) as a side-effect |
| `1008` | `wifiSetting.js` (commented) | Restart WiFi (not needed — set-SSID applies live) |

## Known firmware quirks

- **Chinese language strings** in error alerts. The UI has an English mode
  (`setCookie("language","English")`), but raw `error_info` strings from the
  server are sometimes Chinese regardless. Don't match against them; match
  against `flag != "1"`.
- **JSON responses are sometimes chunked.** `curl -sS` handles this fine.
- **Jetty 6 / `Powered by Jetty://`** banner on 404s — the backend is not
  something the vendor wrote, so the endpoint list is exactly what the UI
  calls and nothing more. Don't bother probing `/api/*` or `/goform/*`.
- **Session** appears to use cookies set by the Jetty backend. The UI also
  does client-side storage (`jquerysession.js`) for IMEI / conn_mode / etc.
  — that's purely for the UI's own state, the server doesn't read it.
- **Same-value writes hang the firmware.** Calling `1010` (set WiFi PSK)
  with the exact PSK already in place causes the request to block for 8+
  seconds before timing out with no response, and leaves the firmware in
  a state where the next few requests also time out (until it recovers
  ~15s later). `provision-arrow.sh` guards against this by reading current
  values first and skipping no-op writes. `1020` (admin pwd) rejects
  same-value writes cleanly with `error_info: "cannotSame"`; `1017` (APN
  write) and `1018` (activate) have occasional same-value hangs too.
  Always read-before-write.
- **`conn_mode` flips to manual after APN activation.** After calling
  `1018` to activate a custom profile, `conn_mode` in the `1000` login
  response changes from `"1"` (auto) to `"0"` (manual). Doesn't break
  anything — the firmware still brings LTE up automatically — but it's a
  visible side effect.
- **`1017` is strictly typed.** `no` and `auth` must be **strings**
  (`"1"`, `"0"`). Sending numbers returns plain-text `flag:0` (6 bytes,
  not JSON — `Content-Type: text/json` is a lie).

## Live transcript example

Factory-fresh ARROW, then configured by `provision-arrow.sh`:

```
$ curl -c jar -b jar -H 'Content-Type: application/json' \
    -d '{"funcNo":1000,"username":"admin","password":"admin"}' \
    http://192.168.100.1/ajax
{"results":[{"net_mode":0,"fwversion":"UZ801-V2.3.13","conn_mode":"1",
  "imei":"860018046015369"}],"error_info":"none","flag":"1"}

$ curl -b jar -H 'Content-Type: application/json' \
    -d '{"funcNo":1007,"ssid":"GA-5369","maxSta":10}' \
    http://192.168.100.1/ajax
{"results":[{}],"error_info":"none","flag":"1"}

$ curl -b jar -H 'Content-Type: application/json' \
    -d '{"funcNo":1010,"encryp_type":4,"pwd":"deadbeefcafef00d"}' \
    http://192.168.100.1/ajax
{"results":[{}],"error_info":"none","flag":"1"}

$ curl -b jar -H 'Content-Type: application/json' \
    -d '{"funcNo":1017,"no":1,"name":"fleet","apn":"inetd.vodafone.iot",
         "user":"","pwd":"","auth":"0"}' \
    http://192.168.100.1/ajax
{"results":[{}],"error_info":"none","flag":"1"}

$ curl -b jar -H 'Content-Type: application/json' \
    -d '{"funcNo":1018,"profile_num":1}' \
    http://192.168.100.1/ajax
{"results":[{}],"error_info":"none","flag":"1"}
```
