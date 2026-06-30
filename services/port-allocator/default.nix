## Host-side port allocator for HomeFree first-party apps.
##
## ──────────────────────────────────────────────────────────────────
## Why this exists
##
## Pre-allocator, every app in `~/homefree/apps/*/default.nix`
## hardcoded its host port in a `let port = NNNN;` block. Adding a
## new app meant grepping every other app to avoid collisions, and
## there was no source of truth — the TODO at
## `~/homefree/apps/minecraft/default.nix:5-6` ("@TODO: Need to manage
## these ports to avoid conflicts") was the on-record acknowledgement.
##
## ──────────────────────────────────────────────────────────────────
## How it works
##
## Two passes over `config.homefree.service-config`, keyed by
## `service-config[].label`:
##
##   Pass 1 — `port-request` is a specific integer.
##     Each pinned entry claims its requested port. Collision between
##     two pinned entries on the same number fails the build with a
##     clear error.
##
##   Pass 2 — `port-request` is `null`.
##     An auto-requester whose label is in the `STABLE` map (below) gets
##     its canonical fixed port REGARDLESS of which other apps are
##     enabled — so enabling/disabling one app never reshuffles another's
##     port (and never churns its container / Caddy upstream). Any
##     auto-requester NOT in `STABLE` gets the next free port from
##     `AUTO_POOL` (labels sorted alphabetically); all `STABLE` values
##     are reserved out of that pool so a fallback never lands on one.
##
## ──────────────────────────────────────────────────────────────────
## Migration status: COMPLETE
##
## Every first-party HomeFree app is migrated to the allocator (the
## final `let port = NNNN;` blocks across `apps/` are gone). With
## `AUTO_POOL` populated below, apps that don't need a specific
## number set `port-request = null` (the schema default) and get the
## next free slot. Labels that DO need a specific port — well-known
## protocols (DNS 53, SSH-family, RTSP), P2P announce ports, and
## anything mobile/desktop clients dial directly — keep their
## explicit `port-request = <int>` pin.
##
## Adding a new HomeFree app:
##   * Declare a `homefree.service-config` entry with a unique label.
##   * Read your host port via `config.homefree.allocPort "<label>"`.
##   * Leave `port-request` unset (the default `null` will auto-allocate
##     from `AUTO_POOL`); pin it only if a client hardcodes the number.

{ config, lib, pkgs, ... }:

let
  ## Auto-assignment pool — assigned to any service-config entry whose
  ## `port-request` is `null`. Slots are handed out in label-
  ## alphabetical order (see `requests` below) so assignments are
  ## stable as long as the set of enabled apps + pinned list don't
  ## move.
  ##
  ## The AI app allocator owns 3060–3199 (see
  ## ~/homefree-ai/apps/homefree-ai/app/generator/projects.py
  ## `AI_PORT_RANGE`) — this set is kept disjoint from it.
  ##
  ## 100 slots is ~3× current expected demand (single-digit number of
  ## first-party HTTP-only apps flip to null); bump to `lib.range 9000
  ## 9199` if we ever cross ~80% utilisation.
  AUTO_POOL = lib.range 9000 9099;

  ## ── Canonical fixed assignments ────────────────────────────────────
  ## An auto-requester (`port-request = null`) whose label appears here
  ## is pinned to this exact port no matter which other apps are enabled.
  ## This is what makes a port STABLE across enable/disable: the old
  ## positional fold handed slots out in alphabetical order, so inserting
  ## one app (e.g. enabling netbird) bumped every alphabetically-later
  ## auto app to the next slot — changing its podman publish port
  ## (container restart) and its Caddy upstream (reload). With a fixed
  ## map, each label owns its number independently.
  ##
  ## Scope + rules:
  ##   * Only FIRST-PARTY (apps/*, services/*) apps with a FIXED label
  ##     live here. Instance-named labels (external proxies, per-wiki
  ##     `mediawiki_<n>`, per-server `minecraft_<n>`) and out-of-repo
  ##     plugin flakes intentionally stay on the fallback path — pinning
  ##     an instance identifier in shared code would violate the
  ##     "no instance-specific values in shared code" rule.
  ##   * Every value MUST be inside AUTO_POOL, unique, and must not
  ##     collide with a Pass-1 pin (the Pass-2 byPort check throws if it
  ##     does). All STABLE values are reserved out of the fallback pool
  ##     unconditionally — even for a label that is currently disabled —
  ##     so toggling a mapped app never frees a slot a fallback app could
  ##     drift into.
  ##   * Seeded from the reference deployment's allocation so existing
  ##     boxes do not churn on first rebuild; a box with a different
  ##     enabled set converges to these canonical numbers once, then is
  ##     stable. Add a new first-party app's label here to canonicalise
  ##     its port (otherwise it just draws the next free slot).
  STABLE = {
    adguard = 9000;
    admin = 9001;
    admin-api = 9002;
    azuracast = 9005;
    backup-canary = 9006;
    baikal = 9007;
    cryptpad = 9012;
    forgejo = 9015;
    freshrss = 9016;
    frigate = 9017;
    grocy = 9019;
    headscale-headplane = 9020;
    home = 9021;
    homebox = 9022;
    joplin = 9026;
    landing-page = 9028;
    lidarr = 9029;
    linkwarden = 9030;
    manual = 9031;
    ## matrix is disabled on the reference box, so it had no current
    ## port to seed from — give it the next free canonical slot above the
    ## seeded range so enabling it later is also non-disruptive.
    matrix = 9058;
    ## DLNA media server (modules/media-server.nix). Off the upstream
    ## default 8200 — that port is hardcoded by NOMAD's FlatNotes content
    ## service (apps/nomad/default.nix), and two servers on 8200 left
    ## flatnotes.<domain> proxying into minidlna (HTTP 400). The HTTP port
    ## is location-transparent for DLNA (clients discover it via SSDP).
    minidlna = 9036;
    netbird = 9038;
    nextcloud = 9039;
    nomad = 9040;
    ntfy = 9041;
    nzbget = 9042;
    oauth2proxy = 9043;
    odoo = 9044;
    ollama = 9045;
    opensprinkler = 9046;
    opensprinkler-ui = 9047;
    postgres-vectorchord = 9048;
    radicle-httpd = 9049;
    screeenly = 9051;
    snipe-it = 9052;
    trilium = 9053;
    vaultwarden = 9054;
    zitadel = 9055;
    zitadel-provision = 9056;
    zwave-js-ui = 9057;
  };

  ## All canonical ports, reserved out of the fallback pool regardless of
  ## whether each mapped label is currently present.
  stableReserved = lib.attrValues STABLE;

  ## Defensive: filter out the always-true default `enable = true` on
  ## service-config entries that an app declares but has gated to its
  ## OWN `service-options.<n>.enable` flag (which evaluates true/false
  ## depending on the user's homefree-config.json). The allocator
  ## still wants to see every label so a disabled service's pin is
  ## reserved even while it's off — otherwise toggling it on later
  ## could collide with another app the allocator handed its number
  ## to in the meantime.
  ## Read the generic port-request registry (label + port-request), not
  ## homefree.service-config directly — decoupled from the service-config
  ## schema (module.nix projects it).
  allEntries = config.homefree.internal.port-requests;

  ## Pull (label, port-request) pairs in stable order. Empty labels
  ## (which can show up if an app's submodule is partially populated)
  ## are dropped so they don't shadow real pin checks.
  requests = lib.sort (a: b: a.label < b.label)
    (lib.filter (e: e.label != "")
      (lib.map (e: { label = e.label; request = e.port-request; }) allEntries));

  pinnedRequests = lib.filter (r: r.request != null) requests;
  autoRequests   = lib.filter (r: r.request == null) requests;

  ## During migration we ship AUTO_POOL = [] so individual apps can
  ## opt in at their own pace. While the pool is empty, an app with
  ## `port-request = null` (the schema default — every unmigrated app)
  ## is simply ignored by the allocator: it keeps hardcoding its port
  ## locally, and `config.homefree.ports.<label>` doesn't exist for
  ## it. Only when the pool is non-empty do null-requesters get an
  ## auto-assigned number.
  effectiveAutoRequests = if AUTO_POOL == [] then [] else autoRequests;

  ## Pass 1 — claim pinned ports. Build fails on collision.
  pinnedAssignments =
    let
      step = acc: r:
        let
          port = r.request;
          owner = acc.byPort.${toString port} or null;
        in
          if owner != null then
            throw ''
              homefree.ports: ${r.label} and ${owner} both pinned to
              port ${toString port}. Decide which one keeps it and
              change the other's `port-request` in its service-config
              entry.
            ''
          else {
            byLabel = acc.byLabel // { ${r.label} = port; };
            byPort  = acc.byPort  // { ${toString port} = r.label; };
          };
    in
      lib.foldl' step { byLabel = {}; byPort = {}; } pinnedRequests;

  ## Pass 2 — assign auto requests. A label in STABLE takes its
  ## canonical fixed port; everything else draws the next free slot from
  ## AUTO_POOL with ALL canonical ports reserved out (so a fallback app
  ## never lands on a number that belongs to a mapped app, present or
  ## not). A pin already claimed anything in `acc.byPort`.
  autoAssignments =
    let
      assign = acc: label: port:
        let owner = acc.byPort.${toString port} or null;
        in
          if owner != null && owner != label then
            throw ''
              homefree.ports: ${label} wants port ${toString port} but it
              is already taken by ${owner}. If ${label} is in the STABLE
              map in services/port-allocator/default.nix, its canonical
              port collides with a pinned `port-request` — change one.
            ''
          else {
            byLabel = acc.byLabel // { ${label} = port; };
            byPort  = acc.byPort  // { ${toString port} = label; };
          };
      step = acc: r:
        let
          stablePort = STABLE.${r.label} or null;
        in
          if stablePort != null then
            assign acc r.label stablePort
          else
            let
              remaining = lib.subtractLists
                (lib.attrValues acc.byLabel ++ stableReserved)
                AUTO_POOL;
            in
              if remaining == [] then
                throw ''
                  homefree.ports: ran out of auto-pool ports while
                  assigning ${r.label}. Either expand the pool in
                  services/port-allocator/default.nix `AUTO_POOL` or pin
                  ${r.label} via `port-request`.
                ''
              else
                assign acc r.label (lib.head remaining);
    in
      lib.foldl' step pinnedAssignments effectiveAutoRequests;

  resolved = autoAssignments.byLabel;
in
{
  ## Wire the two consumer-facing surfaces.
  ##
  ## `config.homefree.ports.<label>` — the bare attrset.
  ## `config.homefree.allocPort "<label>"` — sugared lookup with a
  ## clear failure mode if the label doesn't exist (most likely
  ## cause: the app's service-config block hasn't declared
  ## `port-request`, so the allocator never saw it).
  config.homefree.ports = resolved;

  config.homefree.allocPort = label:
    resolved.${label} or (throw ''
      homefree.allocPort: no port assigned to ${label}.
      Add a `port-request` field to its service-config entry (either
      a specific integer or `null` to auto-allocate) so the allocator
      can register it.
    '');
}
