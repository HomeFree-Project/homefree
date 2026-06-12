#!/usr/bin/env bash
#
# forgejo.sh — thin helper for the HomeFree backlog on git.homefree.host.
#
# Targets the homefree/homefree Forgejo repo's issue API. Reads work without
# a token (the repo is public); create/update/comment need a Personal Access
# Token (scopes: read:issue, write:issue) supplied via $FORGEJO_TOKEN or the
# 0600 file ~/.config/homefree/forgejo-token.
#
# The token is sent only as an Authorization header, fed to curl via a stdin
# config (`-K -`) so it never lands in argv / `ps` / shell history.
#
# Usage:
#   forgejo.sh labels
#   forgejo.sh list   [--state open|closed|all] [--labels A,B] [--q TEXT] [--limit N]
#   forgejo.sh get    N
#   forgejo.sh create --title T (--body B | --body-file F) [--labels A,B] [--milestone M]
#   forgejo.sh update N [--state open|closed] [--title T] [--body B] [--add-labels A,B]
#   forgejo.sh comment N (--body B | --body-file F)
set -euo pipefail

API_BASE="https://git.homefree.host/api/v1/repos/homefree/homefree"

TOKEN="${FORGEJO_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -r "$HOME/.config/homefree/forgejo-token" ]; then
  TOKEN="$(tr -d '\n' < "$HOME/.config/homefree/forgejo-token")"
fi

die() { echo "forgejo.sh: $*" >&2; exit 1; }
need_token() {
  [ -n "$TOKEN" ] || die "no token. Set FORGEJO_TOKEN or write ~/.config/homefree/forgejo-token (chmod 600). Scopes: read:issue, write:issue."
}

# curl wrapper. When a token is present, the auth header is passed through a
# stdin config file so it stays out of the process args.
_curl() {
  if [ -n "$TOKEN" ]; then
    printf 'header = "Authorization: token %s"\n' "$TOKEN" | curl -sS --fail-with-body -K - "$@"
  else
    curl -sS --fail-with-body "$@"
  fi
}

# Resolve a comma-separated list of label NAMES to a JSON array of label IDs
# (Forgejo's create/add-labels endpoints take integer IDs, not names).
_label_ids() {
  _curl "$API_BASE/labels?limit=200" | python3 -c '
import sys, json
want = [n.strip() for n in sys.argv[1].split(",") if n.strip()]
have = {l["name"]: l["id"] for l in json.load(sys.stdin)}
missing = [n for n in want if n not in have]
if missing:
    sys.stderr.write("unknown label(s): %s\n" % ", ".join(missing))
    sys.exit(3)
print(json.dumps([have[n] for n in want]))
' "$1"
}

cmd_labels() {
  _curl "$API_BASE/labels?limit=200" | python3 -c '
import sys, json
for l in sorted(json.load(sys.stdin), key=lambda x: x["name"]):
    print("%-32s id=%d" % (l["name"], l["id"]))
'
}

cmd_list() {
  local state="open" labels="" q="" limit="30"
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift 2;;
      --labels) labels="$2"; shift 2;;
      --q) q="$2"; shift 2;;
      --limit) limit="$2"; shift 2;;
      *) die "list: unknown arg $1";;
    esac
  done
  local url="$API_BASE/issues?type=issues&state=$state&limit=$limit"
  [ -n "$labels" ] && url="$url&labels=$labels"
  if [ -n "$q" ]; then
    url="$url&q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$q")"
  fi
  _curl "$url" | python3 -c '
import sys, json
for i in json.load(sys.stdin):
    labs = ",".join(l["name"] for l in i.get("labels", []))
    print("#%-4d [%s] %s" % (i["number"], labs, i["title"]))
'
}

cmd_get() {
  [ $# -ge 1 ] || die "get: issue number required"
  _curl "$API_BASE/issues/$1" | python3 -c '
import sys, json
i = json.load(sys.stdin)
print("#%d  %s  [%s]" % (i["number"], i["title"],
      ",".join(l["name"] for l in i.get("labels", []))))
print("state: %s   %s" % (i["state"], i["html_url"]))
print()
print(i.get("body") or "(no body)")
'
}

cmd_create() {
  need_token
  local title="" body="" labels="" milestone=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2;;
      --body) body="$2"; shift 2;;
      --body-file) body="$(cat "$2")"; shift 2;;
      --labels) labels="$2"; shift 2;;
      --milestone) milestone="$2"; shift 2;;
      *) die "create: unknown arg $1";;
    esac
  done
  [ -n "$title" ] || die "create: --title required"

  local label_json="[]"
  [ -n "$labels" ] && label_json="$(_label_ids "$labels")"

  local ms_id=""
  if [ -n "$milestone" ]; then
    ms_id="$(_curl "$API_BASE/milestones?state=all&limit=100" | python3 -c '
import sys, json
m = {x["title"]: x["id"] for x in json.load(sys.stdin)}
print(m.get(sys.argv[1], ""))
' "$milestone")"
    [ -n "$ms_id" ] || die "create: milestone not found: $milestone"
  fi

  local bf; bf="$(mktemp)"
  python3 -c '
import sys, json
title, body, label_json, ms = sys.argv[1:5]
d = {"title": title, "body": body}
labs = json.loads(label_json)
if labs: d["labels"] = labs
if ms:   d["milestone"] = int(ms)
print(json.dumps(d))
' "$title" "$body" "$label_json" "$ms_id" > "$bf"

  _curl -X POST -H "Content-Type: application/json" --data-binary "@$bf" "$API_BASE/issues" \
    | python3 -c 'import sys,json;i=json.load(sys.stdin);print("created #%d: %s\n%s"%(i["number"],i["title"],i["html_url"]))'
  rm -f "$bf"
}

cmd_update() {
  need_token
  [ $# -ge 1 ] || die "update: issue number required"
  local n="$1"; shift
  local state="" title="" body="" add_labels=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift 2;;
      --title) title="$2"; shift 2;;
      --body) body="$2"; shift 2;;
      --body-file) body="$(cat "$2")"; shift 2;;
      --add-labels) add_labels="$2"; shift 2;;
      *) die "update: unknown arg $1";;
    esac
  done

  if [ -n "$add_labels" ]; then
    local lj bf; lj="$(_label_ids "$add_labels")"; bf="$(mktemp)"
    printf '{"labels": %s}' "$lj" > "$bf"
    _curl -X POST -H "Content-Type: application/json" --data-binary "@$bf" "$API_BASE/issues/$n/labels" >/dev/null
    rm -f "$bf"
  fi

  if [ -n "$state$title$body" ]; then
    local bf2; bf2="$(mktemp)"
    python3 -c '
import sys, json
state, title, body = sys.argv[1:4]
d = {}
if state: d["state"] = state
if title: d["title"] = title
if body:  d["body"]  = body
print(json.dumps(d))
' "$state" "$title" "$body" > "$bf2"
    _curl -X PATCH -H "Content-Type: application/json" --data-binary "@$bf2" "$API_BASE/issues/$n" >/dev/null
    rm -f "$bf2"
  fi
  echo "updated #$n"
}

cmd_comment() {
  need_token
  [ $# -ge 1 ] || die "comment: issue number required"
  local n="$1"; shift
  local body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --body) body="$2"; shift 2;;
      --body-file) body="$(cat "$2")"; shift 2;;
      *) die "comment: unknown arg $1";;
    esac
  done
  [ -n "$body" ] || die "comment: --body or --body-file required"
  local bf; bf="$(mktemp)"
  python3 -c 'import sys,json;print(json.dumps({"body":sys.argv[1]}))' "$body" > "$bf"
  _curl -X POST -H "Content-Type: application/json" --data-binary "@$bf" "$API_BASE/issues/$n/comments" \
    | python3 -c 'import sys,json;c=json.load(sys.stdin);print("commented on #%s: %s"%(sys.argv[1],c["html_url"]))' "$n"
  rm -f "$bf"
}

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  labels)  cmd_labels "$@";;
  list)    cmd_list "$@";;
  get)     cmd_get "$@";;
  create)  cmd_create "$@";;
  update)  cmd_update "$@";;
  comment) cmd_comment "$@";;
  ""|-h|--help|help) usage;;
  *) die "unknown subcommand: $sub (try --help)";;
esac
