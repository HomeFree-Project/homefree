# Stale DNS after a rebuild — switch restart bookkeeping is not a guarantee

## Symptom

A newly added/enabled app's subdomain gets "Server Not Found" (NXDOMAIN /
NODATA) on LAN clients, while everything else looks perfect: the podman
units are running, `/etc/caddy/caddy_config` has the vhost, and
`/etc/unbound/unbound.conf` contains all the `local-data` /
`local-zone` lines for the new subdomain. Classic first reaction is to
suspect the rebuild didn't deploy — it did (rule 4: the conf on disk is
proof). The running unbound just never loaded it.

Diagnosis fingerprint: compare
`systemctl show unbound --property=ExecMainStartTimestamp` against the
switch timestamps in `journalctl -t nixos`; a DNS process older than the
switch that changed `unbound.conf` is the tell.

## Two distinct ways the restart goes missing (both observed 2026-06-10)

1. **Failed switch + retry skips restarts.** `switch-to-configuration`
   installs `/etc` + unit files FIRST, then (re)starts units. If the
   switch FAILS (journal: `switching to system configuration … failed
   (status 4)`) the new unit files are already on disk; a subsequent
   successful switch sees **no unit diff** (the `X-Restart-Triggers`
   hash on disk already matches) and skips the restarts the failed
   attempt never performed. The observed status-4 cause was
   **`fwupd-refresh.service`** — a network-dependent oneshot re-run
   mid-switch because its unit changed; one LVFS hiccup failed the whole
   switch. Fixed class-level: `systemd.services.fwupd-refresh
   .restartIfChanged = false` in `profiles/common.nix`. (The
   `mnt-external.mount` device-timeout that *looked* guilty was a red
   herring — fstab mounts from `modules/mounts.nix` already carry
   `nofail` + a bounded device-timeout, and the same timeout fired in
   switches that succeeded.)

2. **A successful switch's restart can be silently ineffective.** The
   switch that introduced the new `unbound.conf` printed
   `stopping/starting the following units: podman-adguardhome.service,
   unbound.service, …` and reported success — yet unbound's
   `ExecMainStartTimestamp` (and PID) survived from two days earlier.
   Root cause inside systemd/s-t-c not pinned down; the lesson is that
   "the switch said it restarted it" is bookkeeping, not observed state.

## The cache layers that prolong it

- **AdGuardHome fronts unbound on :53** (LAN IPv4, `127.0.0.1`, and the
  ULA `fd01::1` — check `ss -lnup 'sport = 53'`) and keeps its OWN
  cache of the stale answers, often asymmetrically: a fresh A lookup
  refreshes while AAAA via `fd01::1` stays NODATA. A successful
  `dig` A-record spot-check therefore does NOT prove the browser's
  AAAA/IPv6 path works — verify all four (A/AAAA × v4/v6 listener).
- **Client stub resolvers** (systemd-resolved etc.) negative-cache on
  top; `resolvectl flush-caches` before declaring anything fixed.

## The shared-code guard: `dns-conf-coherence`

`services/unbound/default.nix` asserts coherence from observed state
instead of trusting the switch: unbound's `ExecStartPre` records the
sha256 of the conf it actually loaded (`/run/unbound/
loaded-conf.sha256`); a timer-driven oneshot (`dns-conf-coherence`,
5 min after boot, then every 10 min) compares that marker against the
current `/etc/unbound/unbound.conf` and, only on mismatch, restarts
unbound + (if active) `podman-adguardhome`. dns-ready re-arms via its
existing `partOf` wiring. Any stale-DNS drift therefore self-heals
within ~10 minutes regardless of which switch pathology caused it.

Manual remediation (when you can't wait for the timer):

```
systemctl start dns-conf-coherence    # or:
systemctl restart unbound podman-adguardhome
```

## Limits

The watchdog only proves UNBOUND's conf. An ineffective restart of
`podman-adguardhome` alone (its conf seldom changes per-app, but it
carries a restart trigger on unbound's settings) or of any OTHER unit
the switch skipped is not detected — if a service behaves as if a
rebuild "didn't take", check its `ExecMainStartTimestamp` against the
switch time before blaming the config.
