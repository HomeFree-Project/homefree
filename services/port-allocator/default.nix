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
##     Each auto-requester gets the next free port from `AUTO_POOL`.
##     Labels are sorted alphabetically so assignments are stable as
##     long as the set of enabled apps and the pinned list don't move.
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

  ## Pass 2 — assign auto requests from AUTO_POOL, skipping anything
  ## a pin already claimed.
  autoAssignments =
    let
      step = acc: r:
        let
          remaining = lib.subtractLists
            (lib.attrValues acc.byLabel)
            AUTO_POOL;
        in
          if remaining == [] then
            throw ''
              homefree.ports: ran out of auto-pool ports while
              assigning ${r.label}. Either expand the pool in
              services/port-allocator/default.nix `AUTO_POOL` or pin
              ${r.label} via `port-request`.
            ''
          else {
            byLabel = acc.byLabel // { ${r.label} = lib.head remaining; };
            byPort  = acc.byPort  // { ${toString (lib.head remaining)} = r.label; };
          };
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
