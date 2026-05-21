# systemd unit patterns

## Restart policy is applied centrally

`modules/service-restart-policy.nix` overrides every service registered
via `homefree.service-config` with:

```
Restart=always   RestartSec=10   StartLimitBurst=5   StartLimitIntervalSec=60
```

`Restart=always` (not `on-failure`) is deliberate — a Go/Node runtime
that hits a fatal error and exits **0** would otherwise be treated as a
clean exit and left dead. The burst limit still flips a genuinely-broken
unit to `failed` after 5 fast crashes so it surfaces in the admin UI.

Implications:
- If a catalog service is *stopped* (not `failed`), something stopped it
  deliberately — don't blame the restart policy.
- The policy uses `lib.mkDefault`; a unit that needs different behavior
  (one-shot provisioners, backups) overrides with `lib.mkForce`.
- It reads `config.homefree.service-config`, so new apps are covered
  automatically — no hardcoded list.

### A disabled app must set `service-config.enable`

An app's `homefree.service-config` block is normally emitted
**unconditionally** (so the admin UI can list a disabled service and
offer to turn it on). But when the app is disabled, its *backing* unit
is not generated — the `virtualisation.oci-containers.containers.<name>`
(or `systemd.services.<name>`) block is guarded by the app's `enable`
flag, so no `ExecStart` is ever produced.

The restart policy must therefore **not** declare `systemd.services.<unit>`
for a disabled service: doing so materializes a stub unit with
`Restart=`/`StartLimit*` but no `ExecStart=`, and systemd rejects it —
*"Service has no ExecStart=, ExecStop=, or SuccessAction=. Refusing"* —
which fails `nixos-rebuild switch` with exit 4.

The fix: every `service-config` entry carries a top-level `enable` field
(default `true`). Each app sets it to its own flag,
`enable = config.homefree.service-options.<name>.enable;`, and
`service-restart-policy.nix` filters on it before flattening
`systemd-service-names`. An app that gates its *entire* config block
(`lib.mkIf cfg.enable` / `lib.optionals enabled [ ... ]`, e.g. headscale,
backup-canary) doesn't need the field — its entry simply doesn't exist
when disabled. New unconditional-`[{ ... }]` apps **must** set `enable`.

### Gate a `systemd.services.<name>` with `mkIf`, never `optionalAttrs`

Many apps attach extra attrs (`after`, `wants`, `ExecStartPre`) to the
`podman-<name>` unit that `virtualisation.oci-containers` generates:

```nix
systemd.services.podman-foo = lib.mkIf cfg.enable { ... };   # correct
systemd.services.podman-foo = lib.optionalAttrs cfg.enable { ... };  # BUG
```

`lib.optionalAttrs false { ... }` evaluates to `{}` — but
`systemd.services.podman-foo = {}` **still declares a service**: the
module system materializes a unit file for *any* key present in
`systemd.services`, even an empty one. With the app disabled there is no
oci-container, so no `ExecStart` — the result is the same no-`ExecStart`
stub that fails `nixos-rebuild switch` with exit 4.

`lib.mkIf false { ... }` is a real conditional: it contributes *no
definition* for the key, so the unit never exists. Always use `mkIf`
(not `optionalAttrs`) when the gated value is a whole `systemd.services.<name>`
entry. `optionalAttrs` is still fine for `oci-containers.containers`
(an empty *containers* attrset adds nothing — the hazard is only an empty
value sitting *at a service key*).

## Oneshot bootstrap units: omit `RemainAfterExit`

A oneshot whose job is to **assert filesystem state** (perms, ownership,
rendered config, materialized secrets) that other tooling could perturb
must re-run on every `nixos-rebuild switch`.

`Type=oneshot` + `RemainAfterExit=true` is the **wrong** shape:
switch-to-configuration sees it as still-active and skips it forever
after the first boot. Omit `RemainAfterExit` so the unit returns to
`inactive` after success and re-runs each rebuild. A `requires=` on a
oneshot is satisfied by "last exit was 0", so consumers still gate
correctly.

Belt-and-suspenders: also assert critical mode/ownership in an
`ExecStartPre` on the *consumer*. If the consumer has `User=`/`Group=`
set, prefix that `ExecStartPre` command with `+` so it runs as root —
otherwise chown/chmod on root-owned paths fails with EPERM, silently.

Keep `RemainAfterExit=true` only for genuine first-time provisioning
(key minting on a fresh install); make those idempotent anyway.

## podman readiness ≠ process readiness

systemd considering a `podman-<name>.service` "active" means conmon is
up — **not** that the process inside has bound its listener. A service
that contacts a podman-hosted backend needs both
`after=podman-<name>.service` **and** a runtime HTTP/TCP readiness probe
(poll-curl loop). See `dns-ready-ordering.md` for the DNS case and
`apps/immich` (`dependsOn`) for cross-container ordering.

The same gap applies to **non-container `Type=simple` daemons**.
`headscale.service` is `Type=simple`, so systemd marks it "started" the
instant the process forks — ~11 s *before* it opens its DB and binds its
gRPC/HTTP listener. A oneshot ordered `after headscale.service` that
drives the headscale CLI (`headscale-mint-tailscale-key`,
`headscale-mint-api-key`) races that gap: the CLI hits a not-yet-bound
socket and dies with `context deadline exceeded` (its own 10 s timeout).
At *boot* the oneshot retries and eventually wins, but on a
`nixos-rebuild switch` a failed oneshot makes `switch-to-configuration`
return **exit 4** — a red rebuild for a transient race. Fix: a bounded
readiness poll at the top of the script (poll a cheap read-only CLI call
like `users list` until it answers) — see the shared `waitForHeadscale`
snippet in `apps/headscale/default.nix`. `after`/`requires` alone is not
enough for a `Type=simple` daemon with a slow listener bind.

## `StartLimitBurst` / `StartLimitIntervalSec` belong in `unitConfig`, not `serviceConfig`

In systemd, the `[Unit]` and `[Service]` sections each have their own
directives. `StartLimitBurst`, `StartLimitIntervalSec`,
`StartLimitAction` are **`[Unit]`** directives. `Restart`, `RestartSec`,
`TimeoutStartSec`, `ExecStart*` etc. are `[Service]`.

NixOS routes module fields verbatim: `systemd.services.foo.unitConfig.X`
goes into `[Unit]`, `systemd.services.foo.serviceConfig.Y` goes into
`[Service]`. Putting a `[Unit]`-section key under `serviceConfig`
renders it into the wrong section and systemd **silently** ignores it:

```
Unknown key 'StartLimitIntervalSec' in section [Service], ignoring.
```

The unit then runs with the systemd default (5×10s). This bites because
the override "applied" cleanly (no eval error, the line is in the
generated unit file), but the runtime behaviour is unchanged. Look for
the warning in `journalctl -b -u <name>.service`.

`modules/service-restart-policy.nix` gets this right; ad-hoc overrides
in app modules historically did not. When tuning a service's
start-limit window, always:

- `RestartSec` → `serviceConfig`
- `StartLimitBurst`, `StartLimitIntervalSec` → `unitConfig`
