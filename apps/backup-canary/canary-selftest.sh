#!/usr/bin/env bash
#
# backup-canary self-test.
#
# Proves the backup/restore pipeline works, end to end, without ever
# touching a real service:
#
#   1. record the current canary marker (file + DB)
#   2. back up the canary repository
#   3. mutate the marker to a new value
#   4. restore the canary from the snapshot taken in step 2
#   5. assert the marker reverted to the step-1 value (file + DB + rows)
#   6. write a PASS/FAIL result the admin UI can surface
#
# SAFETY: every backup/restore command in this script is hardcoded to the
# literal service name "backup-canary". It is structurally incapable of
# backing up or restoring any other service. It also runs the real
# backup/restore units, which take the backup subsystem lock, so it
# serialises against genuine backups.
#
# Environment:
#   CANARY_DATA_DIR     data directory (default /var/lib/backup-canary)
#   CANARY_DB           Postgres database (default backup_canary)
#   CANARY_SELFTEST_SOURCE   local | backblaze | both  (default local)
#   RESTORE_CLI         path to restore-cli (default: from PATH)

set -uo pipefail

# --- The one and only service this script may ever act on. -------------
readonly CANARY_SERVICE="backup-canary"

# The backup subsystem's mutual-exclusion lock. The admin backend takes
# this flock around every backup/restore job; the self-test runs real
# backup + restore operations, so it must hold it too - otherwise it
# could collide with a manually-triggered backup or restore.
readonly BACKUP_LOCK="/var/lib/homefree-admin/backup.lock"

DATA_DIR="${CANARY_DATA_DIR:-/var/lib/backup-canary}"
DB_NAME="${CANARY_DB:-backup_canary}"
SELFTEST_SOURCE="${CANARY_SELFTEST_SOURCE:-local}"
RESTORE_CLI="${RESTORE_CLI:-restore-cli}"

MARKER_FILE="$DATA_DIR/marker.txt"
RESULT_FILE="$DATA_DIR/selftest-result.json"
WRITER="${CANARY_WRITER:-canary-writer}"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# JSON-escape a string for safe interpolation into the result file. Handles
# backslash, double-quote, and ASCII control characters - including newlines
# from captured journal/restore-cli output, which are collapsed to spaces so
# the result remains a single-line JSON string.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    s="$(printf '%s' "$s" | tr -d '\000-\037')"
    printf '%s' "$s"
}

# Pick the most informative line(s) from a blob of script/unit output.
# Skips empties + systemd lifecycle noise; prefers lines that look like an
# error; caps the result so it fits the admin UI's single-line detail row.
# Returns an empty string when nothing useful is found.
extract_error_lines() {
    local input="$1"
    local best="" any="" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Skip systemd lifecycle noise. Some messages come bare; others
        # come with a "<unit>.service: " prefix (when systemd itself logs
        # them), so we match the distinctive phrase as a substring.
        case "$line" in
            "Starting "*|"Started "*|"Stopping "*|"Stopped "*) continue ;;
            "Failed to start "*|"Finished "*) continue ;;
            *": Failed with result "*) continue ;;
            *": Control process exited"*) continue ;;
            *": Main process exited"*) continue ;;
            *": Deactivated successfully"*) continue ;;
            *": Finished "*) continue ;;
            *": Consumed "*) continue ;;
            *"See \""*) continue ;;
        esac
        any="$line"
        # Prefer lines that look like a real script-level error. Anchored
        # on the conventional error prefixes - the bare word "Failed"
        # used to live here, but it matched systemd lifecycle messages
        # too, swamping the real ERROR: line.
        case "$line" in
            "ERROR:"*|"Error:"*|"error:"*) best="$line" ;;
            "FATAL:"*|"Fatal:"*|"fatal:"*) best="$line" ;;
            "[ERROR]"*|"[FATAL]"*) best="$line" ;;
            *" ERROR:"*|*" Error:"*|*" error:"*) best="$line" ;;
            *" FATAL:"*|*" Fatal:"*|*" fatal:"*) best="$line" ;;
        esac
    done <<< "$input"
    local result="${best:-$any}"
    if (( ${#result} > 300 )); then
        result="${result:0:299}…"
    fi
    printf '%s' "$result"
}

# Pull recent journal for a systemd unit and extract the failure reason.
# `set -uo pipefail` (no -e) means a missing journal entry returns ""
# rather than aborting the script.
capture_unit_error() {
    local unit="$1"
    local lines=""
    lines="$(journalctl -u "$unit" -n 30 -o cat --no-pager 2>/dev/null)" \
        || return 0
    extract_error_lines "$lines"
}

# Write a result file the canary web page / admin UI reads, then exit.
#   $1  result: pass | fail
#   $2  human-readable detail (may contain captured error output - it is
#       JSON-escaped before being written, so multi-line / quote-bearing
#       error strings are safe here)
finish() {
    local result="$1" detail="$2"
    local finished_at
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$DATA_DIR"
    local escaped_detail
    escaped_detail="$(json_escape "$detail")"
    local tmp
    tmp="$(mktemp "$DATA_DIR/.selftest.XXXXXX")"
    cat > "$tmp" <<JSON
{
  "result": "$result",
  "source": "$SELFTEST_SOURCE",
  "started_at": "$started_at",
  "finished_at": "$finished_at",
  "detail": "$escaped_detail"
}
JSON
    mv "$tmp" "$RESULT_FILE"
    if [[ "$result" == "pass" ]]; then
        echo "backup-canary self-test PASSED ($detail)"
        exit 0
    else
        echo "backup-canary self-test FAILED: $detail" >&2
        exit 1
    fi
}

# Run psql as the `postgres` role. The self-test runs as root (it needs
# root for systemctl + restore-cli), but peer auth only works for a real
# Postgres role, so route DB reads through `postgres` via runuser.
canary_psql() {
    if [[ "$(id -un)" == "postgres" ]]; then
        psql "$@"
    else
        runuser -u postgres -- psql "$@"
    fi
}

db_marker() {
    canary_psql -tAq "$DB_NAME" -c \
        "SELECT marker FROM canary ORDER BY written_at DESC LIMIT 1" \
        2>/dev/null | tr -d '[:space:]'
}

db_rows() {
    canary_psql -tAq "$DB_NAME" -c "SELECT count(*) FROM canary" \
        2>/dev/null | tr -d '[:space:]'
}

file_marker() {
    [[ -f "$MARKER_FILE" ]] && tr -d '[:space:]' < "$MARKER_FILE"
}

# Run one backup + restore + assert cycle against a single source.
#   $1  source: local | backblaze
run_cycle() {
    local source="$1"
    echo "=== self-test cycle: source=$source ==="

    # 1. Record the baseline marker. Two recovery cases run the writer
    #    first to establish a usable baseline:
    #      a) uninitialised — first self-test on a fresh canary, before
    #         the hourly writer has fired; not a backup failure.
    #      b) file/DB out of sync — a previous self-test failed mid-cycle
    #         (e.g. restored the DB but not the file, or vice versa) and
    #         left the marker pair disagreeing. The writer overwrites
    #         both with a fresh, consistent value; the marker's identity
    #         doesn't matter for the test, only that it agrees.
    #    Either way, if the writer cannot produce a consistent baseline,
    #    the test fails — that IS a real backup-pipeline issue.
    local base_file base_db base_rows need_resync=false
    base_file="$(file_marker || true)"
    base_db="$(db_marker || true)"
    if [[ -z "$base_file" || -z "$base_db" ]]; then
        echo "canary not yet initialised - running the writer first ..."
        need_resync=true
    elif [[ "$base_file" != "$base_db" ]]; then
        echo "canary file/DB markers disagree ('$base_file' vs '$base_db') - re-syncing via the writer ..."
        need_resync=true
    fi
    if $need_resync; then
        if ! "$WRITER"; then
            finish fail "writer failed to (re-)initialise canary state"
        fi
        base_file="$(file_marker || true)"
        base_db="$(db_marker || true)"
    fi
    base_rows="$(db_rows || true)"
    if [[ -z "$base_file" || -z "$base_db" ]]; then
        finish fail "baseline marker still missing after writer ran (file='$base_file' db='$base_db')"
    fi
    if [[ "$base_file" != "$base_db" ]]; then
        finish fail "baseline file/DB markers still disagree after writer ran ('$base_file' vs '$base_db')"
    fi
    echo "baseline marker: $base_file ($base_rows rows)"

    # 2. Back up the canary. `systemctl start` of the oneshot blocks
    #    until the restic backup completes.
    local unit="restic-backups-${source}-${CANARY_SERVICE}.service"
    echo "backing up via $unit ..."
    if ! systemctl start "$unit"; then
        # Surface the actual reason the unit failed - the prestart guard
        # message, restic's own error, etc. - so the admin UI shows more
        # than "unit failed".
        local why
        why="$(capture_unit_error "$unit")"
        if [[ -n "$why" ]]; then
            finish fail "backup unit $unit failed: $why"
        else
            finish fail "backup unit $unit failed"
        fi
    fi

    # 3. Mutate the marker so a restore has something to revert.
    echo "mutating marker ..."
    if ! "$WRITER"; then
        finish fail "could not mutate canary marker"
    fi
    local mutated
    mutated="$(file_marker || true)"
    if [[ "$mutated" == "$base_file" ]]; then
        finish fail "marker did not change after mutation - writer broken"
    fi
    echo "mutated marker: $mutated"

    # 4. Restore the canary. HARDCODED to backup-canary - this can never
    #    touch another service.
    #    Capture restore-cli's combined output so we can both stream it to
    #    the journal (cat below) AND extract the most informative error
    #    line for the admin UI on failure.
    echo "restoring $CANARY_SERVICE from $source ..."
    local restore_log restore_rc=0
    restore_log="$(mktemp)"
    "$RESTORE_CLI" restore "$CANARY_SERVICE" --source "$source" --yes \
        >"$restore_log" 2>&1 || restore_rc=$?
    cat "$restore_log"
    if (( restore_rc != 0 )); then
        local why
        why="$(extract_error_lines "$(cat "$restore_log")")"
        rm -f "$restore_log"
        if [[ -n "$why" ]]; then
            finish fail "restore of $CANARY_SERVICE from $source failed: $why"
        else
            finish fail "restore of $CANARY_SERVICE from $source failed"
        fi
    fi
    rm -f "$restore_log"

    # 5. Assert the restore reverted every facet of the canary state.
    local r_file r_db r_rows
    r_file="$(file_marker || true)"
    r_db="$(db_marker || true)"
    r_rows="$(db_rows || true)"

    if [[ "$r_file" != "$base_file" ]]; then
        finish fail "[$source] data-file marker not restored (got '$r_file', expected '$base_file')"
    fi
    if [[ "$r_db" != "$base_db" ]]; then
        finish fail "[$source] database marker not restored (got '$r_db', expected '$base_db')"
    fi
    if [[ "$r_rows" != "$base_rows" ]]; then
        finish fail "[$source] database row count not restored (got '$r_rows', expected '$base_rows')"
    fi
    echo "cycle PASSED for source=$source"
}

# The actual test sequence, run while holding the backup lock.
run_all() {
    case "$SELFTEST_SOURCE" in
        local)      run_cycle local ;;
        backblaze)  run_cycle backblaze ;;
        both)       run_cycle local; run_cycle backblaze ;;
        *)          finish fail "invalid CANARY_SELFTEST_SOURCE: $SELFTEST_SOURCE" ;;
    esac
    finish pass "backup/restore verified for source=$SELFTEST_SOURCE"
}

# --- main --------------------------------------------------------------
# Acquire the backup subsystem lock so the self-test serialises against
# real backups/restores. Wait up to 30 minutes; if the subsystem stays
# busy that long, report a failure rather than running unsynchronised.
mkdir -p "$(dirname "$BACKUP_LOCK")"
exec {lock_fd}>"$BACKUP_LOCK"
if ! flock --timeout 1800 "$lock_fd"; then
    finish fail "backup subsystem busy for 30 min - self-test skipped"
fi

run_all
