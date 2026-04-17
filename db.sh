#!/bin/bash
#
# db.sh — PostgreSQL helper functions for dongle inventory tracking
#
# Source this file from provision.sh:
#   source "$SCRIPT_DIR/db.sh"
#
# Requires: psql (apt install postgresql-client)

# ─── Configuration ──────────────────────────────────────────────────────────

DB_HOST="" DB_PORT="" DB_NAME="" DB_USER="" DB_PASS="" DB_SCHEMA=""

db_load_config() {
    local config_file="${1:-$SCRIPT_DIR/database.conf}"
    [ -f "$config_file" ] || { warn "database.conf not found — DB tracking disabled"; return 1; }

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        case "$key" in
            host)     DB_HOST="$value" ;;
            port)     DB_PORT="$value" ;;
            dbname)   DB_NAME="$value" ;;
            user)     DB_USER="$value" ;;
            password) DB_PASS="$value" ;;
            schema)   DB_SCHEMA="$value" ;;
        esac
    done < "$config_file"

    DB_PORT="${DB_PORT:-5432}"
    DB_SCHEMA="${DB_SCHEMA:-dongle_flasher}"

    [ -n "$DB_HOST" ] && [ -n "$DB_NAME" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ] || {
        warn "Incomplete database.conf — need host, dbname, user, password"
        return 1
    }

    which psql >/dev/null 2>&1 || { warn "psql not installed — DB tracking disabled"; return 1; }
    return 0
}

# ─── Query helper ───────────────────────────────────────────────────────────

db_query() {
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -v ON_ERROR_STOP=1 -q -t -A -c "$1" 2>/dev/null
}

# ─── Schema + table init (idempotent) ──────────────────────────────────────

db_init() {
    db_query "CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};" || true
    db_query "
        CREATE TABLE IF NOT EXISTS ${DB_SCHEMA}.devices (
            id              SERIAL PRIMARY KEY,
            imei            TEXT UNIQUE NOT NULL,
            serial_number   TEXT,
            qr_code         TEXT,
            firmware_version TEXT NOT NULL,
            phone_number    TEXT,
            netbird_ip      TEXT,
            netbird_hostname TEXT,
            hostname        TEXT,
            dongle_type     TEXT,
            hwid            TEXT,
            msm_id          TEXT,
            emmc_sectors    BIGINT,
            dt_model        TEXT,
            dt_compatible   TEXT,
            provisioned_at  TIMESTAMPTZ DEFAULT NOW()
        );
    " || { warn "Failed to init DB schema"; return 1; }
    # Add new columns to pre-existing deployments (idempotent)
    db_query "ALTER TABLE ${DB_SCHEMA}.devices
        ADD COLUMN IF NOT EXISTS dongle_type   TEXT,
        ADD COLUMN IF NOT EXISTS hwid          TEXT,
        ADD COLUMN IF NOT EXISTS msm_id        TEXT,
        ADD COLUMN IF NOT EXISTS emmc_sectors  BIGINT,
        ADD COLUMN IF NOT EXISTS dt_model      TEXT,
        ADD COLUMN IF NOT EXISTS dt_compatible TEXT;" || true
}

# ─── Record device (UPSERT on imei) ────────────────────────────────────────

db_record_device() {
    local imei="$1" serial="$2" qr_code="$3" fw_version="$4" phone="$5" nb_ip="$6" nb_hostname="$7" hostname="$8"
    local dongle_type="${9:-unknown}"
    local hwid="${10:-}" msm_id="${11:-}" emmc_sectors="${12:-0}" dt_model="${13:-}" dt_compatible="${14:-}"

    db_query "
        INSERT INTO ${DB_SCHEMA}.devices
            (imei, serial_number, qr_code, firmware_version, phone_number, netbird_ip, netbird_hostname, hostname,
             dongle_type, hwid, msm_id, emmc_sectors, dt_model, dt_compatible, provisioned_at)
        VALUES
            ('${imei}', '${serial}', '${qr_code}', '${fw_version}', '${phone}', '${nb_ip}', '${nb_hostname}', '${hostname}',
             '${dongle_type}', '${hwid}', '${msm_id}', NULLIF('${emmc_sectors}','0')::BIGINT, '${dt_model}', '${dt_compatible}', NOW())
        ON CONFLICT (imei) DO UPDATE SET
            serial_number    = EXCLUDED.serial_number,
            qr_code          = EXCLUDED.qr_code,
            firmware_version = EXCLUDED.firmware_version,
            phone_number     = EXCLUDED.phone_number,
            netbird_ip       = EXCLUDED.netbird_ip,
            netbird_hostname = EXCLUDED.netbird_hostname,
            hostname         = EXCLUDED.hostname,
            dongle_type      = EXCLUDED.dongle_type,
            hwid             = COALESCE(NULLIF(EXCLUDED.hwid, ''),          ${DB_SCHEMA}.devices.hwid),
            msm_id           = COALESCE(NULLIF(EXCLUDED.msm_id, ''),        ${DB_SCHEMA}.devices.msm_id),
            emmc_sectors     = COALESCE(EXCLUDED.emmc_sectors,              ${DB_SCHEMA}.devices.emmc_sectors),
            dt_model         = COALESCE(NULLIF(EXCLUDED.dt_model, ''),      ${DB_SCHEMA}.devices.dt_model),
            dt_compatible    = COALESCE(NULLIF(EXCLUDED.dt_compatible, ''), ${DB_SCHEMA}.devices.dt_compatible),
            provisioned_at   = NOW();
    " || { warn "Failed to record device in DB"; return 1; }
}
