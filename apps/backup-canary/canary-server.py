#!/usr/bin/env python3
"""
HomeFree backup-canary web server.

The canary is a deliberately tiny service that exists ONLY to verify the
backup/restore pipeline end to end. It owns a data directory and a
Postgres table, both of which carry a "marker" - an ISO timestamp plus a
random token. A separate writer refreshes the marker on a timer.

This server renders a single status page showing the live marker (from
both the file and the DB) and the most recent self-test result, so a
human - or an automated check - can confirm a restore actually reverted
the canary's state.

Environment:
    CANARY_PORT       TCP port to listen on (default 8099)
    CANARY_DATA_DIR   data directory (default /var/lib/backup-canary)
    CANARY_DB         Postgres database name (default backup_canary)
"""

import os
import json
import html
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = os.environ.get("CANARY_DATA_DIR", "/var/lib/backup-canary")
DB_NAME = os.environ.get("CANARY_DB", "backup_canary")
PORT = int(os.environ.get("CANARY_PORT", "8099"))

MARKER_FILE = os.path.join(DATA_DIR, "marker.txt")
SELFTEST_FILE = os.path.join(DATA_DIR, "selftest-result.json")


def read_file_marker():
    """Return the marker recorded in the data directory, or None."""
    try:
        with open(MARKER_FILE) as f:
            return f.read().strip()
    except OSError:
        return None


def read_db_marker():
    """Return (marker, row_count) from the Postgres canary table.

    Returns (None, None) if the DB is unreachable - the canary must
    degrade gracefully so its page still renders during a restore.
    """
    try:
        # Latest marker.
        marker = subprocess.run(
            ["psql", "-tAq", DB_NAME, "-c",
             "SELECT marker FROM canary ORDER BY written_at DESC LIMIT 1"],
            capture_output=True, text=True, timeout=10)
        count = subprocess.run(
            ["psql", "-tAq", DB_NAME, "-c", "SELECT count(*) FROM canary"],
            capture_output=True, text=True, timeout=10)
        if marker.returncode != 0 or count.returncode != 0:
            return (None, None)
        return (marker.stdout.strip() or None,
                count.stdout.strip() or None)
    except Exception:
        return (None, None)


def read_selftest():
    """Return the most recent self-test result dict, or None."""
    try:
        with open(SELFTEST_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def list_data_files():
    """Return the names of files in the canary data directory."""
    try:
        return sorted(
            n for n in os.listdir(DATA_DIR)
            if os.path.isfile(os.path.join(DATA_DIR, n)))
    except OSError:
        return []


def render_page():
    file_marker = read_file_marker()
    db_marker, db_count = read_db_marker()
    selftest = read_selftest()
    files = list_data_files()

    # File and DB markers should agree; a mismatch is itself a signal.
    consistent = (file_marker is not None
                  and file_marker == db_marker)

    if selftest:
        st_state = selftest.get("result", "unknown")
        st_ok = st_state == "pass"
        st_color = "#10b981" if st_ok else "#ef4444"
        st_text = (f"{st_state.upper()} "
                   f"&mdash; {html.escape(str(selftest.get('finished_at','')))}")
        st_detail = html.escape(str(selftest.get("detail", "")))
    else:
        st_color = "#6b7280"
        st_text = "no self-test has run yet"
        st_detail = ""

    rows = "".join(
        f"<li><code>{html.escape(n)}</code></li>" for n in files)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HomeFree Backup Self-Test</title>
<style>
  body {{ font-family: ui-sans-serif, system-ui, sans-serif;
         background: #0b0e14; color: #c9d1d9; margin: 0;
         display: flex; justify-content: center; padding: 40px 16px; }}
  .card {{ background: #11161f; border: 1px solid #1f2630;
          border-radius: 12px; padding: 28px 32px; max-width: 560px;
          width: 100%; }}
  h1 {{ font-size: 20px; margin: 0 0 4px; }}
  .sub {{ color: #6b7280; font-size: 13px; margin-bottom: 24px; }}
  .row {{ display: flex; justify-content: space-between; gap: 16px;
         padding: 10px 0; border-bottom: 1px solid #1f2630;
         font-size: 14px; }}
  .row:last-child {{ border-bottom: none; }}
  .k {{ color: #8b949e; }}
  .v {{ font-family: ui-monospace, Menlo, monospace; text-align: right;
       word-break: break-all; }}
  .pill {{ display: inline-block; padding: 3px 10px; border-radius: 999px;
          font-size: 12px; font-weight: 600; }}
  .selftest {{ margin-top: 20px; padding: 14px 16px; border-radius: 8px;
              background: #0b0e14; border: 1px solid #1f2630; }}
  .files {{ margin: 6px 0 0; padding-left: 20px; font-size: 13px; }}
  code {{ font-family: ui-monospace, Menlo, monospace; }}
</style>
</head>
<body>
  <div class="card">
    <h1>&#129760; Backup Self-Test</h1>
    <div class="sub">A small built-in service whose only job is to prove
      the backup &amp; restore process works. It holds test data only.</div>

    <div class="row">
      <span class="k">Marker (data file)</span>
      <span class="v">{html.escape(file_marker or '&mdash;')}</span>
    </div>
    <div class="row">
      <span class="k">Marker (database)</span>
      <span class="v">{html.escape(db_marker or '&mdash;')}</span>
    </div>
    <div class="row">
      <span class="k">File / DB markers agree</span>
      <span class="v">
        <span class="pill" style="background:{'#10b981' if consistent
          else '#ef4444'};color:#000;">
          {'YES' if consistent else 'NO'}</span>
      </span>
    </div>
    <div class="row">
      <span class="k">Database rows</span>
      <span class="v">{html.escape(str(db_count) if db_count
        is not None else '&mdash;')}</span>
    </div>
    <div class="row">
      <span class="k">Data directory</span>
      <span class="v">{html.escape(DATA_DIR)}</span>
    </div>

    <div class="selftest">
      <div style="font-size:13px;color:#8b949e;margin-bottom:6px;">
        Last automated backup self-test</div>
      <div style="font-weight:600;color:{st_color};">{st_text}</div>
      {f'<div style="font-size:12px;color:#8b949e;margin-top:4px;">'
       f'{st_detail}</div>' if st_detail else ''}
    </div>

    <div style="margin-top:16px;font-size:13px;color:#8b949e;">
      Files in data directory:
      <ul class="files">{rows or '<li>(none)</li>'}</ul>
    </div>
  </div>
</body>
</html>"""


class CanaryHandler(BaseHTTPRequestHandler):
    # Quieter logs - the canary is polled often.
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path in ("/healthz", "/health"):
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        else:
            body = render_page().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), CanaryHandler)
    print(f"backup-canary listening on :{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
