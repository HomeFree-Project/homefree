"""
Abuse-blocking observability + control.

Surfaces the state of three layers wired up in modules/abuse-blocking.nix
+ profiles/router.nix:

  1. fail2ban (three jails: caddy-oauth-hammer, caddy-404-storm,
     caddy-error-flood) — server status, per-jail counters, currently
     banned IPs, unban action.
  2. nftables sets: abusive_nets4 (static, populated at activation),
     f2b_banned4 / f2b_banned6 (dynamic, populated by fail2ban with
     per-entry timeouts).
  3. Caddy per-service JSON access logs at /var/log/caddy/access-*.log
     — parsed to compute "top-N traffic sources" over a recent window.
     The UI calls these "traffic sources" rather than "attackers"
     because the same code surfaces both abuse (Alibaba scrapers
     hitting /user/oauth2/*) and benign-but-chatty traffic (the
     Vaultwarden browser extension long-polling, z-wave-js-ui
     websocket reconnects, etc.).

Read paths use `nft -j list ...` / `fail2ban-client status ...` shelled
out as root (admin-api runs as root, see services/admin-web.nix).

Write paths: unban only — fail2ban-client set <jail> unbanip <ip>. The
jail name is allowlist-validated and the IP is parsed via ipaddress
before reaching the shell to keep arbitrary-arg footguns shut.
"""

import ipaddress
import json
import logging
import os
import re
import socket
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    import geoip2.database
    import geoip2.errors
    _HAVE_GEOIP2 = True
except ImportError:
    ## geoip2 should be in the admin-api python env (see
    ## services/admin-web/default.nix) — but tolerate its absence so
    ## the rest of the resolver still works on a partial deploy.
    _HAVE_GEOIP2 = False

logger = logging.getLogger(__name__)

## Hard-coded — these are the jails declared in modules/abuse-blocking.nix.
## If you add another jail there, add it here too. Used as the allowlist
## for the unban endpoint (any other name is rejected before the shell).
KNOWN_JAILS = (
    "caddy-oauth-hammer",
    "caddy-404-storm",
    "caddy-error-flood",
)

## Comment-text-to-source mapping for nftables counter rules
## (declared in profiles/router.nix). Both input and forward chains
## carry these — the "(fwd)" suffix distinguishes them. We sum both
## when reporting a single packet-count per source.
COUNTER_COMMENT_SOURCES: Tuple[Tuple[str, str], ...] = (
    ("Static abuse block", "static"),
    ("Static abuse block (fwd)", "static"),
    ("Static abuse block v6", "static"),
    ("Static abuse block v6 (fwd)", "static"),
    ("fail2ban v4", "fail2ban_v4"),
    ("fail2ban v4 (fwd)", "fail2ban_v4"),
    ("fail2ban v6", "fail2ban_v6"),
    ("fail2ban v6 (fwd)", "fail2ban_v6"),
)

CADDY_LOG_DIR = Path("/var/log/caddy")
## Cap how much of each log we read when computing top-N. Each log can
## be tens of MB. Reading the last N bytes is a coarse 'recent traffic'
## proxy — Caddy writes line-by-line in ts-sorted order so the tail is
## the newest. 4 MB/file × ~50 services ≈ 200 MB peak; tune down if
## that's too much.
TOP_TRAFFIC_TAIL_BYTES = 4 * 1024 * 1024

## "Internal" networks the top-traffic view suppresses by default.
## Anything originating here is by definition not bannable — fail2ban's
## ignoreIP list (declared in modules/abuse-blocking.nix) excludes the
## same ranges. Keeping these two lists in sync is a manual chore;
## if you change one, change the other.
##
## A typical home server's "top traffic" without this filter is its
## own LAN client apps long-polling (Vaultwarden notification hub,
## Z-Wave dashboard websocket reconnects, UniFi controller, …) —
## informative but not actionable. The UI exposes an "Include LAN /
## internal networks" toggle for when the user does want to see them.
_INTERNAL_NETWORKS = tuple(
    ipaddress.ip_network(cidr) for cidr in (
        "127.0.0.0/8",       # loopback v4
        "::1/128",           # loopback v6
        "10.0.0.0/8",        # RFC1918
        "172.16.0.0/12",     # RFC1918
        "192.168.0.0/16",    # RFC1918
        "100.64.0.0/10",     # CGNAT (tailscale uses this for its tailnet)
        "fc00::/7",          # ULA v6 (covers tailscale / netbird v6)
        "fe80::/10",         # link-local v6
    )
)


## The host's own IP addresses. A box with a public IPv6 prefix
## (common — ISPs hand out a /56 or /64) has globally-routable v6
## addresses on its own interfaces. Traffic logged with the server's
## own address as the source is NOT an external attacker — it's the
## box talking to itself (health checks, a service reaching another
## service through the public hostname, etc.). Those addresses don't
## fall in any private range, so _INTERNAL_NETWORKS alone won't catch
## them; we enumerate the live interface addresses and add them.
##
## Cached with a TTL — interface addresses change rarely (DHCPv6
## lease renewals, prefix changes) but not never, so we refresh
## occasionally rather than pinning at import time.
_HOST_ADDRS: set = set()
_HOST_ADDRS_AT = 0.0
_HOST_ADDRS_TTL = 300.0
_HOST_ADDRS_LOCK = threading.Lock()


def _host_addresses() -> set:
    """Set of IP-address strings bound to this host's interfaces.
    Refreshed at most every _HOST_ADDRS_TTL seconds."""
    global _HOST_ADDRS, _HOST_ADDRS_AT
    now = time.time()
    with _HOST_ADDRS_LOCK:
        if _HOST_ADDRS and (now - _HOST_ADDRS_AT) < _HOST_ADDRS_TTL:
            return _HOST_ADDRS
        addrs: set = set()
        try:
            import psutil
            for if_addrs in psutil.net_if_addrs().values():
                for a in if_addrs:
                    if a.family in (socket.AF_INET, socket.AF_INET6):
                        ## v6 addresses can carry a %scope suffix —
                        ## strip it so it matches the logged form.
                        addrs.add(a.address.split("%", 1)[0])
        except Exception as e:
            logger.debug("could not enumerate host addresses: %s", e)
        _HOST_ADDRS = addrs
        _HOST_ADDRS_AT = now
        return _HOST_ADDRS


def _is_internal(ip_str: str) -> bool:
    """True if `ip_str` is 'internal' for top-traffic-source
    filtering: a private/loopback/link-local range, OR one of this
    host's own interface addresses (covers a public IPv6 the box
    holds itself). Bad input → False (we'd rather show a weird-
    looking value than hide it)."""
    if ip_str in _host_addresses():
        return True
    try:
        addr = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    return any(addr in net for net in _INTERNAL_NETWORKS)


## ──────────────────────────────────────────────────────────────────────
## IP enrichment — reverse DNS + GeoIP, with an in-memory cache.
##
## The Abuse Blocking page polls every 30s and the same source IPs
## recur constantly. A reverse-DNS PTR lookup is a network round-trip
## (10-100ms, up to a multi-second timeout for IPs with no PTR), so
## doing it per-poll per-IP would make the page sluggish. We cache:
##   - rDNS with a TTL (PTR records do change, but slowly)
##   - geo with no practical expiry (an IP's country/city is stable
##     for the lifetime of this process; a restart re-warms it)
## The cache is size-bounded so a flood of unique IPs can't grow it
## without limit.
## ──────────────────────────────────────────────────────────────────────

## Path written by modules/geoip.nix's geoip-update.service.
GEOIP_DB_PATH = "/var/lib/geoip/dbip-city-lite.mmdb"

_RDNS_TTL_SECONDS = 3600          # re-resolve a PTR at most hourly
_IP_CACHE_MAX = 4000              # hard cap on cache entries

## Total wall-time budget for the rDNS lookups triggered by one
## request. socket.gethostbyaddr can hang for the *system* resolver
## timeout (often 5s+) on IPs with no PTR, and socket.setdefaulttimeout
## does NOT bound it (that only affects Python-level socket ops, not
## the C getnameinfo path). So instead of relying on a per-lookup
## timeout, we run lookups in a shared background pool and only WAIT
## up to this budget. Anything not resolved in time stays None for
## this response and lands in the cache for the next 30s poll. Net
## effect: the endpoint never blocks more than ~1.5s on DNS, and the
## table fills in within a poll or two.
_RDNS_WAIT_BUDGET_SECONDS = 1.5

## cache: ip -> {"rdns": str|None, "rdns_at": float,
##               "geo": {...}|None, "geo_done": bool}
_ip_cache: Dict[str, Dict[str, Any]] = {}
_ip_cache_lock = threading.Lock()

## Shared, long-lived pool for rDNS lookups. Daemon threads so a
## stuck gethostbyaddr can't block process exit. Sized for the
## typical top-N table width.
_rdns_pool = ThreadPoolExecutor(max_workers=12, thread_name_prefix="rdns")
## In-flight lookups, so overlapping requests for the same IP don't
## each spawn their own job. ip -> Future.
_rdns_inflight: Dict[str, Any] = {}
_rdns_inflight_lock = threading.Lock()

## geoip2 Reader is opened lazily and reused. Readers are documented
## thread-safe for concurrent .city() calls. None until first use or
## if the DB file is missing.
_geo_reader = None
_geo_reader_lock = threading.Lock()
_geo_reader_mtime = 0.0


def _get_geo_reader():
    """Return an open geoip2 Reader, or None if the DB is unavailable.
    Re-opens automatically if the mmdb file has been replaced on disk
    (the weekly geoip-update.service swaps it in place)."""
    global _geo_reader, _geo_reader_mtime
    if not _HAVE_GEOIP2:
        return None
    try:
        mtime = os.path.getmtime(GEOIP_DB_PATH)
    except OSError:
        return None
    with _geo_reader_lock:
        if _geo_reader is not None and mtime == _geo_reader_mtime:
            return _geo_reader
        ## Stale or not-yet-open — (re)open.
        if _geo_reader is not None:
            try:
                _geo_reader.close()
            except Exception:
                pass
            _geo_reader = None
        try:
            _geo_reader = geoip2.database.Reader(GEOIP_DB_PATH)
            _geo_reader_mtime = mtime
        except Exception as e:
            logger.warning("could not open GeoIP DB %s: %s", GEOIP_DB_PATH, e)
            _geo_reader = None
        return _geo_reader


def _lookup_geo(ip: str) -> Optional[Dict[str, Any]]:
    """Country + city + approximate lat/long for an IP from the local
    DB-IP database. Returns a dict or None.

    lat/long are the DB-IP "approximate" coordinates — good enough to
    plot a city-level dot on a world map, not for anything precise.
    They can be absent even when country/city resolve, so they're
    None-tolerant downstream."""
    reader = _get_geo_reader()
    if reader is None:
        return None
    try:
        resp = reader.city(ip)
    except (geoip2.errors.AddressNotFoundError, ValueError):
        return None
    except Exception as e:
        logger.debug("geo lookup failed for %s: %s", ip, e)
        return None
    loc = resp.location
    return {
        "country": resp.country.name or None,
        "country_code": resp.country.iso_code or None,
        "city": resp.city.name or None,
        "lat": loc.latitude if loc and loc.latitude is not None else None,
        "lon": loc.longitude if loc and loc.longitude is not None else None,
    }


def _lookup_rdns(ip: str) -> Optional[str]:
    """Reverse-DNS (PTR) for an IP. Runs on a background thread (see
    _rdns_pool). May block for the system resolver's timeout on IPs
    with no PTR — that's why callers wait on it with a budget rather
    than inline."""
    try:
        host, _, _ = socket.gethostbyaddr(ip)
        return host
    except (socket.herror, socket.gaierror, OSError):
        return None


def _submit_rdns(ip: str):
    """Get-or-create the in-flight rDNS Future for `ip`. Dedupes so
    overlapping requests don't each spawn a lookup for the same IP.

    The done-callback writes the result straight into the cache —
    crucial for slow IPs whose lookup overruns a request's wait
    budget: the foreground call gives up and returns None, but when
    the background lookup finally finishes, THIS callback still
    records it, so the next poll is a cache hit instead of yet
    another re-dispatch."""
    with _rdns_inflight_lock:
        fut = _rdns_inflight.get(ip)
        if fut is not None:
            return fut
        fut = _rdns_pool.submit(_lookup_rdns, ip)
        _rdns_inflight[ip] = fut

        def _on_done(f, _ip=ip):
            with _rdns_inflight_lock:
                _rdns_inflight.pop(_ip, None)
            try:
                rdns = f.result()
            except Exception:
                return  # lookup raised — leave entry stale, retry later
            with _ip_cache_lock:
                entry = _ip_cache.get(_ip)
                if entry is not None:
                    entry["rdns"] = rdns
                    entry["rdns_at"] = time.time()
        fut.add_done_callback(_on_done)
        return fut


def _enrich_ips(ips: List[str]) -> Dict[str, Dict[str, Any]]:
    """Return {ip: {"rdns": ..., "geo": {...}}} for a list of IPs.

    Geo is resolved inline — local mmdb lookups are microseconds.
    rDNS misses/stale entries are dispatched to a background pool and
    waited on only up to _RDNS_WAIT_BUDGET_SECONDS total; whatever
    doesn't finish in time stays None for this response and is picked
    up from the cache on the next poll once the background lookup
    completes."""
    now = time.time()
    result: Dict[str, Dict[str, Any]] = {}
    need_rdns: List[str] = []

    with _ip_cache_lock:
        for ip in ips:
            entry = _ip_cache.get(ip)
            if entry is None:
                entry = {"rdns": None, "rdns_at": 0.0,
                         "geo": None, "geo_done": False}
                _ip_cache[ip] = entry
            ## Geo: resolve once, then cached for the process lifetime.
            if not entry["geo_done"]:
                entry["geo"] = _lookup_geo(ip)
                entry["geo_done"] = True
            ## rDNS: resolve if never done or past TTL.
            if entry["rdns_at"] == 0.0 or (now - entry["rdns_at"]) > _RDNS_TTL_SECONDS:
                need_rdns.append(ip)
            result[ip] = {"rdns": entry["rdns"], "geo": entry["geo"]}

    if need_rdns:
        ## Dispatch all misses to the background pool, then wait on
        ## the batch with a single shared deadline. The cache write
        ## happens in each Future's done-callback (see _submit_rdns),
        ## so here we only need to surface whatever finished in time
        ## into THIS response.
        futures = {ip: _submit_rdns(ip) for ip in need_rdns}
        deadline = time.time() + _RDNS_WAIT_BUDGET_SECONDS
        for ip, fut in futures.items():
            remaining = deadline - time.time()
            if remaining <= 0:
                break  # budget spent — the rest land in cache async
            try:
                result[ip]["rdns"] = fut.result(timeout=remaining)
            except Exception:
                pass  # timeout / error — cache fills via the callback

        ## Trim the cache if it has grown past the cap. Drop oldest
        ## rDNS entries first (rough LRU by rdns_at).
        with _ip_cache_lock:
            if len(_ip_cache) > _IP_CACHE_MAX:
                victims = sorted(
                    _ip_cache.items(), key=lambda kv: kv[1]["rdns_at"]
                )[: len(_ip_cache) - _IP_CACHE_MAX]
                for ip, _ in victims:
                    _ip_cache.pop(ip, None)

    return result


class AbuseBlockingResolver:
    @staticmethod
    def get_status() -> Dict[str, Any]:
        """Return fail2ban server overall + per-jail summary.

        Shape:
            {
              "server_up": bool,
              "jails": [
                {"name": "...", "currently_failed": N,
                 "total_failed": N, "currently_banned": N,
                 "total_banned": N, "banned_ips": [...]},
                ...
              ],
              "error": "optional human message if server_up=False"
            }
        """
        ok, out = _run(["fail2ban-client", "status"])
        if not ok:
            return {
                "server_up": False,
                "jails": [],
                "error": out.strip() or "fail2ban-client status failed",
            }

        jails: List[Dict[str, Any]] = []
        for jail_name in KNOWN_JAILS:
            j_ok, j_out = _run(["fail2ban-client", "status", jail_name])
            if not j_ok:
                ## Jail might be in the unit config but not yet active —
                ## report what we can and keep going.
                jails.append({
                    "name": jail_name,
                    "available": False,
                    "error": j_out.strip()[:200],
                })
                continue
            jails.append(_parse_jail_status(jail_name, j_out))

        return {"server_up": True, "jails": jails}

    @staticmethod
    def get_banned_ips() -> Dict[str, Any]:
        """Merge the three nftables ban sets into a single table.

        For dynamic bans (f2b_banned4/6) each entry carries a timeout
        we surface as `remaining_seconds`. For static (abusive_nets4)
        entries we surface the prefix and source="static".

        Shape:
            {
              "entries": [
                {"address": "1.2.3.4",
                 "source": "fail2ban_v4" | "fail2ban_v6" | "static",
                 "remaining_seconds": 1234 | None,
                 "jail": "caddy-oauth-hammer" | None},
                ...
              ]
            }

        Note: fail2ban-client doesn't tell us which jail an nftables
        entry came from (all our jails share one set). We cross-
        reference by re-running `fail2ban-client status <jail>` and
        marking matches; ties go to the first jail listing the IP.
        """
        entries: List[Dict[str, Any]] = []

        ## Build a jail-lookup map: ip -> jail_name (first match wins).
        ## fail2ban-client status <jail> emits a "Banned IP list:" line.
        ip_to_jail: Dict[str, str] = {}
        for jail_name in KNOWN_JAILS:
            ok, out = _run(["fail2ban-client", "status", jail_name])
            if not ok:
                continue
            for ip in _extract_banned_ip_list(out):
                ip_to_jail.setdefault(ip, jail_name)

        ## Dynamic sets — fail2ban-populated, per-entry timeouts.
        for set_name, source in (
            ("f2b_banned4", "fail2ban_v4"),
            ("f2b_banned6", "fail2ban_v6"),
        ):
            for addr, remaining in _list_nft_set_with_timeout(set_name):
                entries.append({
                    "address": addr,
                    "source": source,
                    "remaining_seconds": remaining,
                    "jail": ip_to_jail.get(addr),
                })

        ## Static sets (v4 + v6) — interval/prefix elements, no timeout.
        for set_name in ("abusive_nets4", "abusive_nets6"):
            for prefix in _list_nft_set_prefixes(set_name):
                entries.append({
                    "address": prefix,
                    "source": "static",
                    "remaining_seconds": None,
                    "jail": None,
                })

        return {"entries": entries}

    @staticmethod
    def get_drop_counters() -> Dict[str, Any]:
        """Walk `nft -j list ruleset` and pick out the counter rules
        whose `comment` matches one of our drop rules. Sum packets +
        bytes across the input/forward variants per source. Returns:

            {
              "static":      {"packets": N, "bytes": N},
              "fail2ban_v4": {"packets": N, "bytes": N},
              "fail2ban_v6": {"packets": N, "bytes": N}
            }
        """
        out: Dict[str, Dict[str, int]] = {
            "static":      {"packets": 0, "bytes": 0},
            "fail2ban_v4": {"packets": 0, "bytes": 0},
            "fail2ban_v6": {"packets": 0, "bytes": 0},
        }
        ok, raw = _run(["nft", "-j", "list", "ruleset"])
        if not ok:
            return out
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as e:
            logger.warning("nft ruleset json decode failed: %s", e)
            return out

        comment_to_source = dict(COUNTER_COMMENT_SOURCES)
        for item in data.get("nftables", []):
            rule = item.get("rule")
            if not rule:
                continue
            comment = rule.get("comment", "")
            source = comment_to_source.get(comment)
            if not source:
                continue
            ## Walk the expr list looking for a "counter" object.
            for expr in rule.get("expr", []):
                counter = expr.get("counter")
                if counter:
                    out[source]["packets"] += counter.get("packets", 0)
                    out[source]["bytes"] += counter.get("bytes", 0)
                    break
        return out

    @staticmethod
    def get_top_traffic_sources(
        window_seconds: int = 3600,
        filter_kind: Optional[str] = None,
        limit: int = 20,
        include_internal: bool = False,
    ) -> Dict[str, Any]:
        """Tail each /var/log/caddy/access-*.log, parse the last hour
        of requests, group by request.client_ip, return the top-N.

        filter_kind:
            None / "" / "all" — count everything
            "oauth"           — only URIs starting with /user/oauth2/
            "4xx"             — only status 400-499
            "5xx"             — only status 500-599

        include_internal:
            False (default) — drop entries whose source IP is in
                              _INTERNAL_NETWORKS (LAN, tailnet, ULA,
                              loopback). These are by definition not
                              bannable and the top-N usually drowns in
                              your own browser/extension long-polling
                              otherwise.
            True            — count everything regardless of source.

        Shape:
            {
              "window_seconds": N,
              "filter": "all" | "oauth" | "4xx" | "5xx",
              "include_internal": bool,
              "total_requests": N,            # post-filter, post-internal
              "internal_suppressed": N,       # how many we hid (0 if include_internal)
              "geo_available": bool,          # False if the GeoIP DB is missing
              "sources": [
                {"ip": "1.2.3.4", "count": N,
                 "sample_uri": "https://host/path" (full URL; bare
                               path only for hostless raw-IP probes),
                 "internal": bool, "rdns": "host"|None,
                 "country": "..."|None, "country_code": "US"|None,
                 "city": "..."|None,
                 "lat": float|None, "lon": float|None},
                ...
              ]
            }

        rDNS + geo come from _enrich_ips, which caches aggressively —
        only the final top-N IPs are looked up and repeat polls are
        almost entirely cache hits.

        Cost-bounded by TOP_TRAFFIC_TAIL_BYTES per log file (we read
        from the tail). Older entries past that window are dropped.
        """
        empty = {
            "window_seconds": window_seconds,
            "filter": filter_kind or "all",
            "include_internal": include_internal,
            "total_requests": 0,
            "internal_suppressed": 0,
            "geo_available": _get_geo_reader() is not None,
            "sources": [],
        }
        if not CADDY_LOG_DIR.is_dir():
            return empty

        cutoff = time.time() - window_seconds
        counts: Dict[str, int] = {}
        samples: Dict[str, str] = {}
        total = 0
        suppressed = 0

        ## Only the live, uncompressed per-service logs. Rotated/gzipped
        ## files are out of scope — fail2ban doesn't read them and
        ## 'recent' is fundamentally the live tail.
        for log_path in sorted(CADDY_LOG_DIR.glob("access-*.log")):
            try:
                for record in _tail_jsonl(log_path, TOP_TRAFFIC_TAIL_BYTES):
                    ts = record.get("ts")
                    if not isinstance(ts, (int, float)) or ts < cutoff:
                        continue
                    if not _filter_matches(record, filter_kind):
                        continue
                    req = record.get("request") or {}
                    ip = req.get("client_ip") or req.get("remote_ip")
                    if not ip:
                        continue
                    if not include_internal and _is_internal(ip):
                        suppressed += 1
                        continue
                    counts[ip] = counts.get(ip, 0) + 1
                    if ip not in samples:
                        uri = req.get("uri") or ""
                        ## HomeFree is HTTPS-only behind Caddy; the box
                        ## serves many subdomains, so the bare path is
                        ## ambiguous. Build the full URL from request.host.
                        ## Hostless raw-IP probes fall back to the path.
                        host = req.get("host") or ""
                        sample = f"https://{host}{uri}" if host else uri
                        samples[ip] = sample[:300]
                    total += 1
            except OSError as e:
                logger.debug("skipping unreadable %s: %s", log_path, e)
                continue

        ranked = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:limit]

        ## Enrich only the final top-N — bounded to `limit` lookups,
        ## almost all served from cache after the first page load.
        enrichment = _enrich_ips([ip for ip, _ in ranked])

        sources = []
        for ip, count in ranked:
            info = enrichment.get(ip, {})
            geo = info.get("geo") or {}
            sources.append({
                "ip": ip,
                "count": count,
                "sample_uri": samples.get(ip, ""),
                "internal": _is_internal(ip),
                "rdns": info.get("rdns"),
                "country": geo.get("country"),
                "country_code": geo.get("country_code"),
                "city": geo.get("city"),
                "lat": geo.get("lat"),
                "lon": geo.get("lon"),
            })

        return {
            "window_seconds": window_seconds,
            "filter": filter_kind or "all",
            "include_internal": include_internal,
            "total_requests": total,
            "internal_suppressed": suppressed,
            ## Tells the UI whether to render the Location column or
            ## an attribution-only placeholder. False = DB missing.
            "geo_available": _get_geo_reader() is not None,
            "sources": sources,
        }

    @staticmethod
    def unban(jail: str, ip: str) -> Tuple[bool, str]:
        """Run fail2ban-client set <jail> unbanip <ip> after validating
        both arguments. Returns (ok, message). Caller is responsible
        for the HTTP-status mapping.
        """
        if jail not in KNOWN_JAILS:
            return False, f"unknown jail: {jail!r}"
        try:
            ipaddress.ip_address(ip)
        except ValueError:
            return False, f"invalid IP: {ip!r}"

        ok, out = _run(["fail2ban-client", "set", jail, "unbanip", ip])
        if not ok:
            return False, out.strip()[:300]
        return True, out.strip()[:300]


## ──────────────────────────────────────────────────────────────────────
## Helpers
## ──────────────────────────────────────────────────────────────────────

def _run(cmd: List[str], timeout: int = 10) -> Tuple[bool, str]:
    """Run a command, return (ok, combined-output)."""
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, f"timeout after {timeout}s"
    except FileNotFoundError:
        return False, f"command not found: {cmd[0]}"
    except Exception as e:
        return False, f"error running {cmd[0]}: {e}"
    if r.returncode != 0:
        return False, (r.stderr or r.stdout)
    return True, r.stdout


_JAIL_FIELD_RE = re.compile(r"^\|?\s*[`|]?-\s*(.+?):\s*(.*)$")


def _parse_jail_status(name: str, raw: str) -> Dict[str, Any]:
    """Parse the human-format output of `fail2ban-client status <jail>`.

    The format is stable across versions: tree-prefix lines with a
    "key: value" payload. We pull the four numeric fields plus the
    banned-IP list. Anything we don't recognise is ignored — the
    output is mostly tree drawing characters and section headers.
    """
    fields: Dict[str, Any] = {
        "name": name,
        "available": True,
        "currently_failed": 0,
        "total_failed": 0,
        "currently_banned": 0,
        "total_banned": 0,
        "banned_ips": [],
    }
    for line in raw.splitlines():
        m = _JAIL_FIELD_RE.match(line.rstrip())
        if not m:
            continue
        key = m.group(1).strip().lower()
        value = m.group(2).strip()
        if key == "currently failed":
            fields["currently_failed"] = _int_or_zero(value)
        elif key == "total failed":
            fields["total_failed"] = _int_or_zero(value)
        elif key == "currently banned":
            fields["currently_banned"] = _int_or_zero(value)
        elif key == "total banned":
            fields["total_banned"] = _int_or_zero(value)
        elif key == "banned ip list":
            fields["banned_ips"] = value.split() if value else []
    return fields


def _extract_banned_ip_list(raw: str) -> List[str]:
    """Slim wrapper — just pull the banned-IP-list line. Used when we
    only care about that one piece (the ip-to-jail map builder)."""
    return _parse_jail_status("", raw).get("banned_ips", [])


def _list_nft_set_with_timeout(set_name: str) -> List[Tuple[str, Optional[int]]]:
    """Return [(addr, remaining_seconds_or_None), ...] from a timeout-flagged
    nftables set. nft -j emits each element as either a bare string
    (no timeout) or `{"elem": {"val": "1.2.3.4", "timeout": ..., "expires": ...}}`.
    """
    ok, raw = _run(["nft", "-j", "list", "set", "inet", "filter", set_name])
    if not ok:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    elements: List[Tuple[str, Optional[int]]] = []
    for item in data.get("nftables", []):
        s = item.get("set")
        if not s:
            continue
        for el in s.get("elem", []) or []:
            if isinstance(el, str):
                elements.append((el, None))
                continue
            if isinstance(el, dict):
                inner = el.get("elem") or el
                val = inner.get("val") if isinstance(inner, dict) else None
                expires = inner.get("expires") if isinstance(inner, dict) else None
                if isinstance(val, str):
                    remaining = _to_seconds(expires) if expires is not None else None
                    elements.append((val, remaining))
    return elements


def _list_nft_set_prefixes(set_name: str) -> List[str]:
    """Return list of CIDR strings from an interval/prefix-typed
    nftables set (e.g. abusive_nets4)."""
    ok, raw = _run(["nft", "-j", "list", "set", "inet", "filter", set_name])
    if not ok:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    prefixes: List[str] = []
    for item in data.get("nftables", []):
        s = item.get("set")
        if not s:
            continue
        for el in s.get("elem", []) or []:
            if isinstance(el, dict) and "prefix" in el:
                p = el["prefix"]
                prefixes.append(f"{p.get('addr')}/{p.get('len')}")
            elif isinstance(el, str):
                prefixes.append(el)
    return prefixes


def _to_seconds(value: Any) -> Optional[int]:
    """nft expresses timeouts as either ints (seconds) or strings like
    '1h30m'. Be tolerant of both."""
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        units = {"d": 86400, "h": 3600, "m": 60, "s": 1}
        total = 0
        num = ""
        for ch in value:
            if ch.isdigit():
                num += ch
            elif ch in units and num:
                total += int(num) * units[ch]
                num = ""
        if num.isdigit():
            total += int(num)
        return total or None
    return None


def _int_or_zero(s: str) -> int:
    try:
        return int(s)
    except ValueError:
        return 0


def _tail_jsonl(path: Path, max_bytes: int):
    """Yield parsed JSON objects from the tail of a line-delimited
    JSON log. Seeks to (size - max_bytes), discards the partial first
    line, then yields one record per remaining line.
    """
    try:
        size = path.stat().st_size
    except OSError:
        return
    if size == 0:
        return
    with path.open("rb") as f:
        if size > max_bytes:
            f.seek(size - max_bytes)
            ## Discard the first (likely partial) line so we don't
            ## emit garbage to json.loads.
            f.readline()
        for raw_line in f:
            try:
                line = raw_line.decode("utf-8", errors="replace").rstrip()
            except Exception:
                continue
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _filter_matches(record: Dict[str, Any], kind: Optional[str]) -> bool:
    if not kind or kind == "all":
        return True
    req = record.get("request") or {}
    if kind == "oauth":
        uri = req.get("uri") or ""
        return uri.startswith("/user/oauth2/")
    status = record.get("status")
    if kind == "4xx":
        return isinstance(status, int) and 400 <= status < 500
    if kind == "5xx":
        return isinstance(status, int) and 500 <= status < 600
    return False
