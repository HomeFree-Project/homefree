# /etc/nixos — HomeFree instance state (read before editing)

> This file is **materialized by the HomeFree build** on every
> `nixos-rebuild switch`. Do not edit it here — edit the source in the
> HomeFree repo at `modules/instance-managed-docs/AGENTS.md`.

This directory is a HomeFree box's **instance state**, not source code.
HomeFree owns the files here and re-materializes the managed ones on every
rebuild. **Do not hand-edit these files, and do not drop new `.nix` modules
into `/etc/nixos`.** A `.nix` file added here is invisible to every other
HomeFree box, rots in place, and is flagged as divergence (see below).

## How to extend HomeFree (add an app, service, or config)

Use the **Custom Flake** mechanism — the **Plugins** page of the Admin UI.

1. Put your flake in your home directory, e.g.
   `/home/<user>/my-homefree-extension` (it must be a git repo containing a
   `flake.nix` that exposes `nixosModules.default`).
2. Register it on the **Plugins** page (Local repository → browse to the
   path). HomeFree wires it into the build, applies the right ownership/ACL,
   and regenerates `custom-flakes.nix` for you.

Your module is evaluated alongside HomeFree's own modules, so it can set any
`homefree.*` option (e.g. extend an app's config) or declare a brand-new
service. This is the supported way to keep per-box customization **out of**
`/etc/nixos`.

## How to change HomeFree itself

Don't patch files here — work from a clone of the HomeFree repo:

1. Clone HomeFree to `/home/<user>/homefree` (or use the **Clone & enable**
   button on the **Source Code** page).
2. On the **Source Code** page, point **Alternate HomeFree Repository** at
   that local clone and **enable** it.
3. The box now builds from your clone; edit there and rebuild.

## Files HomeFree manages here

`flake.nix`, `flake.lock`, `homefree-config.json`, `configuration.nix`,
`disko.nix`, `hardware-configuration.nix`, `custom-flakes.nix`, the
`secrets/` directory, and `AGENTS.md` / `CLAUDE.md` (these two). Some boxes
also have `secureboot.nix` (Secure Boot) or `development-overrides.nix`
(dev installs). `configuration.nix` is for **instance hardware/bootloader
overrides only** — putting generic logic or extra module imports here is
divergence.

## Divergence detection

The build detects anything in `/etc/nixos` it does not manage — stray
`.nix` files, extra `configuration.nix` imports, etc. Divergence is surfaced
on the Admin UI's **Build & Logs** page and as a **Config divergence** alert
on the **Alerts** page. Detection is advisory: HomeFree re-materializes its
own managed files but **never deletes or edits files you added** — move them
into a Custom Flake to clear the warning.
