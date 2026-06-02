# Podman/netavark shutdown hang

When a HomeFree box reboots while podman containers are running, every
container's pre-stop hook calls netavark to remove its DNS entries.
netavark in turn tries to **start** a transient `aardvark-dns` scope
unit via `systemd-run --scope`. That start request is refused once
`reboot.target` has a `start` job queued (which happens the instant
`systemctl reboot` is invoked), with:

```
Transaction for run-pXXX.scope/start is destructive
(reboot.target has 'start' job queued, but 'stop' is included
in transaction).
```

The cleanup fails, container stops time out and get SIGKILLed, `/home`
unmount fails with `target is busy`, and the box hangs in late shutdown
until the hardware watchdog (or an impatient human) resets it.

We observed 15+ containers failing this way on a single reboot —
every container with a podman pre-stop hook is a victim.

## The shipped mitigation

`services/podman-shutdown-wrapper/default.nix` installs shadow scripts
for `reboot`, `poweroff`, and `halt` via `lib.hiPrio
(pkgs.writeShellScriptBin …)`, so the homefree wrappers win the
filename collision against systemd's symlinks in
`/run/current-system/sw/bin`. Each wrapper runs

```
timeout 30 podman stop -a -t 10
```

first, then `exec`s the real `systemctl reboot|poweroff|halt`. By the
time `reboot.target` gets queued, every container is already gone and
netavark has no cleanup left to attempt — so the
destructive-transaction error never fires.

## What the wrapper does NOT cover

The wrapper is shell-symlink-only. The following paths still hit the
bare behaviour:

- `systemctl reboot|poweroff|halt` invoked directly — deliberate
  escape hatch; if you call systemctl by name you bypass the wrapper.
- `shutdown` (any variant including `shutdown -r now`) — intentionally
  NOT wrapped, because `shutdown +1h` would eagerly stop containers
  an hour early.
- Power-button events — these go through systemd-logind →
  `systemd-reboot.service` directly, never touching the shell symlinks.
- IPMI shutdown, BMC reset, kernel panic.

## Manual procedure for the unwrapped paths

Before triggering shutdown via any of the unwrapped paths, run:

```
podman stop -a -t 10 && systemctl reboot   # or poweroff / halt
```

This is the same logic the wrapper applies; doing it by hand restores
clean shutdown for the bypass cases.

## Upstream context

netavark has no "external aardvark-dns daemon" mode — `aardvark-dns`
is always lifecycle-managed by netavark as a transient scope. A proper
upstream fix would be one of:

- netavark supporting an external `aardvark-dns.service` it talks to
  via IPC, so no transient scope start is ever needed.
- netavark/podman issuing the transient scope with
  `DefaultDependencies=no` (or otherwise not conflicting with
  `shutdown.target`).
- netavark detecting an already-dead aardvark and skipping the
  re-spawn during cleanup.

Revisit the wrapper when upstream addresses any of those — at that
point the shadow scripts become unnecessary and should be removed.

## Why we did NOT take the obvious-looking workarounds

A few alternatives were considered and rejected:

- **systemd oneshot ordered `Before=shutdown.target`** — fails for the
  same reason as the container pre-stop hooks themselves. `reboot.target`
  is queued the moment `systemctl reboot` runs, *before* anything in
  the shutdown sequence (including a `Before=shutdown.target` oneshot)
  gets a chance to execute. The destructive-transaction error fires
  from inside our oneshot too.
- **Pre-spawning aardvark-dns as a managed service** — netavark does
  not support pointing at an external aardvark, and it would respawn
  its own anyway.
- **Disabling `dns_enabled` on the default network** — kills
  container-by-name DNS resolution across the whole fleet of apps;
  too much collateral damage.
