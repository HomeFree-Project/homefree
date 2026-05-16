#!/usr/bin/env bash
#
# backup-canary writer.
#
# Refreshes the canary "marker" - an ISO timestamp plus a random token -
# in both the data directory and the Postgres table. Run on a timer so
# the canary's state genuinely changes over time; a restore of an older
# snapshot must visibly revert it.
#
# Environment:
#   CANARY_DATA_DIR   data directory (default /var/lib/backup-canary)
#   CANARY_DB         Postgres database name (default backup_canary)

set -euo pipefail

DATA_DIR="${CANARY_DATA_DIR:-/var/lib/backup-canary}"
DB_NAME="${CANARY_DB:-backup_canary}"
MARKER_FILE="$DATA_DIR/marker.txt"

# Run psql as the `postgres` role regardless of who runs this script.
# The writer is invoked both by its systemd service (as the postgres
# user) and by the self-test (as root); peer auth only works for a real
# Postgres role, so re-exec psql via `postgres` whenever we are not
# already that user. `runuser` needs no setuid wrapper (unlike sudo),
# so it works in a minimal systemd service environment.
canary_psql() {
    if [[ "$(id -un)" == "postgres" ]]; then
        psql "$@"
    else
        runuser -u postgres -- psql "$@"
    fi
}

mkdir -p "$DATA_DIR"

# Build a fresh marker: <UTC ISO timestamp>:<random hex token>.
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
token="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
marker="${timestamp}:${token}"

# Write the marker to the data directory (atomic). Keep it owned by
# postgres so the canary web service (which runs as postgres) and a
# later writer run can both read/replace it, even when this run is root.
tmp="$(mktemp "$DATA_DIR/.marker.XXXXXX")"
printf '%s\n' "$marker" > "$tmp"
mv "$tmp" "$MARKER_FILE"
if [[ "$(id -un)" != "postgres" ]]; then
    chown postgres "$MARKER_FILE" 2>/dev/null || true
fi

# Append the marker as a new row in the canary table. The table is
# created on first run; the row count growing over time is itself
# something a restore should visibly roll back.
canary_psql -v ON_ERROR_STOP=on "$DB_NAME" <<SQL
CREATE TABLE IF NOT EXISTS canary (
    id          BIGSERIAL PRIMARY KEY,
    marker      TEXT NOT NULL,
    written_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO canary (marker) VALUES ('$marker');
SQL

echo "backup-canary marker updated: $marker"
