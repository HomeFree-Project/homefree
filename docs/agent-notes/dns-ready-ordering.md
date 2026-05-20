# `dns-ready` ordering and container image pulls

`dns-ready.service` (defined in `services/unbound/default.nix`) is the
gate every container app orders itself `after`/`requires` so it can
resolve names and pull its image.

## The trap

`dns-ready` is a `oneshot` with `RemainAfterExit = true` — it proves
DNS once at boot and then stays `active` forever. But enabling any
service rewrites unbound's proxied zone, which restarts `unbound` and
(via a `restartTrigger` on unbound's settings) `podman-adguardhome`.
During that restart window DNS resolution fails. A stale-green
`dns-ready` does not re-check, so podman units ordered after it start
mid-outage and fail their image pull with `no such host`.

## The fix (already applied)

`dns-ready` is `partOf` the DNS units (`unbound.service`,
`podman-adguardhome.service`). A restart of a DNS unit propagates a
restart to `dns-ready`, re-running its wait loop; a podman unit started
in the same rebuild transaction is then ordered after the *re-run*.

- `partOf`, **not** `bindsTo` — `bindsTo` would also tear `dns-ready`
  down (cascade-stopping every container that `requires` it) the
  instant the adguard *container* merely crashed.
- The real adguard unit is `podman-adguardhome.service`; there is no
  `adguardhome.service`.
- The wait loop probes both the local zone and an **external** name
  (recursion must be up for registry pulls), but the external probe is
  **bounded** (~45 s) and then falls through — an offline rebuild must
  still succeed.

## When adding a container app

Just `after`/`requires` `dns-ready.service` — the re-arming is handled
centrally. Do not re-implement a per-app DNS wait.

## When adding a non-container service that does outbound name lookups on start

Same gate. `headscale.service` is the canonical example: it fetches
`https://controlplane.tailscale.com/derpmap/default` synchronously at
startup, and without the gate it races AdGuard's first-boot image-pull
window (~90 s on a cold cache), fails 5× in 31 s, and hits
`start-limit-hit` permanently. Container vs. non-container is
irrelevant — the gate is about any startup path that needs working
external DNS. Use `wants` + `after`, not `requires`, so a later DNS
restart doesn't cascade-stop a long-running daemon.
