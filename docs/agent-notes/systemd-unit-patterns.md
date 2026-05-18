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
