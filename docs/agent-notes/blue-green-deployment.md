# Zero-downtime blue/green deployment

## High-level summary

Some services sit directly in a live request path — if they restart, a
user sees an outage. The admin UI is the worst case: a `nixos-rebuild`
that touched **admin-api** (the backend) or **oauth2-proxy** (the SSO
gate) would restart that unit, and the Admin/Home dashboard would go
dark for 10–50 s.

`lib/blue-green.nix` fixes this generically. A service covered by it
runs as **two identical units on two ports** — "blue" and "green". Only
one serves traffic at a time. When a rebuild changes the service, an
activation script:

1. starts the *standby* colour (the one not currently serving),
2. waits until it answers a health check,
3. rewrites a Caddy snippet to point at the standby's port and
   **reloads** Caddy (Caddy reloads config without dropping
   connections),
4. stops the old colour.

The swap is invisible — old colour keeps serving every request until the
instant Caddy is pointed at the new one. Zero downtime.

A rebuild that does **not** change the service does nothing — the flip
script detects "unchanged" and exits immediately, so blue/green adds no
cost to routine rebuilds.

Two services use it today: **admin-api** (a plain systemd process) and
**oauth2-proxy** (a podman container). Any future critical service can
opt in with one function call.

## The flow

```
          ┌─────────┐
 browser ─┤  Caddy  ├─ reverse_proxy / forward_auth
          └────┬────┘   via a runtime snippet:
               │        import /run/homefree/<name>-upstream.caddy
               │        (the snippet's port is rewritten on each flip)
               ▼
   ┌───────────────────────┐
   │  ACTIVE colour only   │      STANDBY colour
   │  e.g. admin-api-blue  │      admin-api-green
   │      :8000  ▲         │          :8001   (dormant)
   └────────────│──────────┘
                │
   active-color pointer = "blue"   (/var/lib/<svc>/active-color)


A rebuild that CHANGES the service runs <name>-flip:

  daemon-reload
        │
        ▼
  closure changed?  ──no──►  clear stale marker, exit (no-op)
        │ yes
        ▼
  start  admin-api-green   (standby)
        │
        ▼
  health-gate  :8001/health   (poll ~30 s, bail if the unit dies)
        │ ok                    │ fail
        ▼                       ▼
  rewrite snippet → :8001   stop green, write failure marker, exit 0
  systemctl reload caddy        (old colour keeps serving)
        │ ok                    │ reload fails
        ▼                       ▼
  stop admin-api-blue       roll snippet back to :8000,
  active-color = "green"    stop green, write marker, exit 0
  (flip committed)
```

## Why each piece is the way it is

### Two ports — fully owned by the flip

Both colour units exist permanently in the config. `lib/blue-green.nix`
forces **both** `restartIfChanged = false` **and** `stopIfChanged =
false` on every colour unit (the caller cannot opt out). The flip
script owns all start/stop decisions. This is the single most important
correctness property.

`restartIfChanged = false` alone is **not** enough. A changed unit that
cannot reload — every podman container has `CanReload=no` — and still
has the default `stopIfChanged = true` gets *stopped* by
`switch-to-configuration` on a rebuild that touches its definition.
Forcing `stopIfChanged = false` too makes the colour unit invisible to
`switch-to-configuration`'s *change* handling.

### The active-colour supervisor — keeping the live colour up

`stopIfChanged = false` still does not cover everything. A
`nixos-rebuild` cycles `local-fs.target` / `remote-fs.target`, and that
stops **every** podman container (an ordering/dependency consequence,
not a change-detection one). An ordinary `autoStart = true` container
is then re-pulled by `multi-user.target`. A colour unit is `autoStart =
false` / `wantedBy` nothing — so once stopped this way it never comes
back, and the service goes permanently dark. This bit oauth2-proxy live
more than once.

The fix is the **`<name>-active` supervisor** — a `Restart=always`
service, `wantedBy = multi-user.target`, whose `ExecStart` is a poll
loop. It has **no dependency coupling to the colour units at all**.
It is deliberately **start-only**: every few seconds it reads the
`active-color` pointer and `systemctl start`s that colour if it is not
running. That is its entire job. A colour killed by `local-fs.target`
cycling — or by a crash, OOM, anything — is noticed within the poll
interval and restarted.

> **Why not couple the supervisor to the colour with `Requires=`?**
> That was the first design and a live kill-test proved it wrong.
> `Restart=` only restarts a service that exited *on its own*. When
> the colour was stopped, `Requires=` stopped the supervisor as a
> deliberate **dependency cascade** — a clean stop, for which
> `Restart=` is suppressed. The supervisor went down and stayed down;
> the colour was never resurrected. A polling supervisor with **no**
> dependency edge avoids this entirely: the colour stopping cannot
> touch the supervisor, so there is no cascade and nothing to
> resurrect *it* — it just notices the colour is down and restarts it.

> **Why start-only — why not also stop the standby?** A reconciler
> that also "stops whatever isn't `active-color`" *seems* tidier, but
> it races the flip: a flip deliberately runs **both** colours during
> its handover (start standby → health-gate → reload Caddy → only then
> retire the old colour). A flip-lock file was tried to make such a
> reconciler stand down, but the supervisor's check-lock-then-stop is
> not atomic — a flip can create the lock and start the standby in the
> gap between the supervisor's lock check and its `stop`, so the
> supervisor stops the colour the flip just started (observed live: a
> flip's health-gate timed out because the supervisor killed the
> standby under it). A **start-only** supervisor has no such conflict
> — it never touches the standby, so there is nothing to race and no
> lock is needed. Stopping is wholly the flip's job: step 7 retires
> the old colour at commit, and every failure path stops the standby.
> A standby left running by a crashed flip merely idles on its port
> (nothing routes to it) until the next flip — harmless.

**`active-color` is the single source of truth, written FIRST on
commit.** The supervisor and the `<name>-snippet` oneshot both derive
from it, and that oneshot re-runs later in the same rebuild during
`switch-to-configuration`. If the flip wrote `active-color` last, that
re-run would read the stale colour and point the Caddy snippet at the
now-dead old port (observed live: 502s `dial tcp :<oldport>:
connection refused`). Commit order: `active-color` → `active-closure` →
stop old colour.

The standby colour is named nowhere — not by `multi-user.target`, not
by the supervisor — so it stays dormant.

### Caddy is reloaded, never restarted

Caddy points at the active colour through a runtime-generated snippet,
`/run/homefree/<name>-upstream.caddy`, imported at Caddy's file scope.
The flip rewrites the port in that snippet and runs `systemctl reload
caddy`. Caddy applies new config gracefully — in-flight requests finish,
no socket is dropped. The flip never restarts Caddy.

**`--force` must NOT be in Caddy's `ExecReload`.** The upstream NixOS
caddy module defaults `ExecReload` to `caddy reload … --force`, and
`--force` makes Caddy rebuild the *full* server on every reload —
tearing down and recreating the `:443` listener, a brief
connection-refused gap each time. A rebuild issues 2-3 reloads
(`switch-to-configuration` plus each blue/green flip); stacked, that was
~9s of `caddy=000` on the admin path. `services/caddy/default.nix`
overrides `ExecReload` to drop `--force` — Caddy then diffs the adapted
config and keeps unchanged listeners (a true graceful reload). It still
picks up content changes; `--force` only bypasses the "adapted JSON
identical" short-circuit.

### "Did the service change?" — the no-op fast path

The flip records a fingerprint of the deployed definition in
`/var/lib/<svc>/active-closure`:

- **admin-api** (`closure.kind = "store-path"`): the `/nix/store` path
  of the backend package.
- **oauth2-proxy** (`closure.kind = "unit-file"`): the resolved path of
  the *blue* colour's generated systemd unit file. Its hash changes iff
  the container definition changes.
  **Invariant:** the `mkContainer` factory must differ between blue and
  green *only by the port* — otherwise this fingerprint is unstable.

If the fingerprint matches what is already deployed, the flip exits
immediately. A rebuild touching neither service flips neither.

### Failure is contained — a bad flip never fails the rebuild

If the standby fails to start, fails its health check, or Caddy refuses
the new config, the flip:

- rolls the snippet back and stops the standby,
- writes a JSON marker to `/var/lib/<svc>/<name>-flip-failed.json`,
- **returns 0** — the old colour keeps serving, the box stays up.

The admin-api backend reads those markers and surfaces a
`partial_success` rebuild status (see
`web-platform/backend/services/nix_operations.py`,
`FLIP_FAILED_FILES`).

### The two activation-ordering gotchas

NixOS concatenates **every** `system.activationScripts.*` fragment into
one bash script. Two consequences shaped the design:

1. **Never `exit` inside a flip.** A bare `exit` terminates the *whole*
   activation — including any other service's flip ordered after it. So
   each flip body is a function `<name>_flip()` that uses `return`, and
   is invoked as `<name>_flip || true`. A failed flip cannot abort a
   sibling flip or the rebuild.

2. **Snippets must exist before any flip reloads Caddy.** Caddy's
   Caddyfile `import`s *every* blue/green service's snippet at file
   scope. If service A's flip reloads Caddy while service B's snippet
   file does not yet exist, Caddy's adapter fails and A's flip rolls
   back. Fix: a separate `<name>-bg-snippet` activation script (pure
   file I/O) materializes each snippet, and **every flip depends on
   every `*-bg-snippet` script**. Ordering is therefore: all
   `*-bg-snippet` scripts → then all `*-flip` scripts.

### First deploy — the migration branch

The very first rebuild after a service adopts blue/green has no
`active-color` pointer and a legacy single unit still running. The flip
enters a migration branch: stop the legacy unit, start blue, health-gate
it, record the pointers. `migrateRollback` decides what happens if blue
fails to come up — `"restart-legacy"` (admin-api) brings the old unit
back; `"leave-down"` (oauth2-proxy) leaves it down for a CLI re-apply.

## Using it for a new service

From a service module with `lib` and `pkgs` in scope:

```nix
bg = (import ../../lib/blue-green.nix { inherit lib pkgs; }) {
  name        = "my-service";
  stateDir    = "/var/lib/my-service";
  colours     = { blue = 9000; green = 9001; };
  workload    = { kind = "systemd"; mkUnit = colour: port: { ... }; };
  healthCheck = { kind = "http"; path = "/health"; };
  closure     = { kind = "store-path"; path = "${my-package}"; };
  caddySnippets = [ { snippetName = "my_service_proxy";
                      body = "reverse_proxy localhost:__PORT__"; } ];
  migrateFrom     = "my-service.service";
  migrateRollback = "restart-legacy";
  failureMarker   = "my-service-flip-failed.json";
  # order this flip after every OTHER blue/green service's snippet writer
  snippetActivationDeps = [ "admin-api-bg-snippet" "oauth2-proxy-bg-snippet" ];
};
```

Then in the module's `config`:

- merge `bg.config`,
- append `bg.caddyImportLine` to
  `homefree.internal.caddy-file-scope-imports`,
- in the Caddy vhost, `import` the snippet by `snippetName`.

For a podman container, set `workload.kind = "oci-container"` with a
`mkContainer` factory (`autoStart = false`) and an `extraUnitConfig`
that sets `restartIfChanged = false`. See `apps/zitadel/default.nix`
(oauth2-proxy) and `services/admin-web/default.nix` (admin-api) for the
two worked examples.

## Files

- `lib/blue-green.nix` — the mechanism.
- `services/admin-web/default.nix` — admin-api blue/green.
- `apps/zitadel/default.nix` — oauth2-proxy blue/green.
- `services/caddy/default.nix` — file-scope snippet imports.
- `module.nix` — `reverse-proxy.upstream-snippet`,
  `homefree.internal.caddy-file-scope-imports`.
- `web-platform/backend/services/nix_operations.py` — flip-failure
  surfacing in rebuild status.
