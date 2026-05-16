# HomeFree

**A personal server *and* router in one box — your apps, your identity, your connectivity, on hardware you own.**

> Status: technical preview. Production users welcome, but expect some sharp edges.

## What it is

HomeFree is a declarative [NixOS](https://nixos.org/) system that sits between your
internet modem and the rest of your home network. Most self-hosting projects are app
launchers; HomeFree is also your router — firewall, ad-blocking DNS, dynamic DNS,
automatic HTTPS, and a private mesh VPN are built in. On top of that it runs a curated
suite of apps, every one of them behind a single sign-on, with encrypted backups to
local disk, a NAS, or S3. Router, apps, identity, and backups are configured together
and declared in one config — rebuild the whole machine, reproducibly, anywhere.

## What's included

**Infrastructure** — Zitadel SSO + oauth2-proxy (one login, every app), Caddy reverse
proxy with automatic TLS, Unbound DNS, AdGuard ad-blocking, multi-zone dynamic DNS,
headscale mesh VPN, restic backups (local / NAS / S3), nftables abuse-blocking.

**Admin** — a web-based installer and an admin dashboard at `admin.<domain>`, a
per-user app dashboard at `home.<domain>`, backed by a FastAPI service.

**Apps** — all opt-in, all gated by SSO: Nextcloud, Immich, Jellyfin, Matrix/Synapse,
Vaultwarden, Home Assistant, Forgejo, Frigate, CryptPad, FreshRSS, Trilium, Ollama,
and more — see [`apps/`](./apps) for the full catalog.

## Install

The supported path is the guided ISO installer — no command line required:

1. Download the HomeFree ISO from [homefree.host](https://homefree.host/).
2. Write it to an 8 GB+ USB stick — [balenaEtcher](https://www.balena.io/etcher/)
   works on any OS, or use `dd` if you're on Linux/macOS:

   ```sh
   # replace /dev/sdX with your USB device — this erases it
   sudo dd if=homefree-latest.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
3. Boot the HomeFree box from the USB stick and follow the on-screen installer (~20 min).

See the manual for the full walkthrough, including how to wire up the hardware and
set your modem and Wi-Fi to bridge mode:

- [Hardware setup](https://homefree.host/hardware-setup/)
- [Installation](https://homefree.host/installation/)

## Repo layout

| Path | Contents |
|---|---|
| `apps/` | Per-app service modules (Nextcloud, Immich, Zitadel, …) |
| `services/` | Core infrastructure (Caddy, DNS, SSO, admin web, landing page) |
| `modules/` | System modules (abuse-blocking, geoIP, dynamic DNS) |
| `profiles/` | Configuration profiles (boot, networking, router, secrets) |
| `web-platform/` | Web installer + admin UI (Lit frontend, FastAPI backend) |
| `scripts/` | Build and deploy automation |
| `flake.nix` | Flake inputs and outputs — the build entry point |
| `module.nix` | The `homefree.*` NixOS option schema (single source of truth) |
| `configuration.example.nix` | Annotated example system configuration |

## Development

A host is configured through the `homefree.*` options declared in `module.nix`,
supplied per-host via `homefree-configuration.nix` (the installer writes this).

Flake apps:

```sh
nix run .#run-vm           # boot the configuration in a QEMU VM
nix run .#build-iso-image  # build the installer ISO
nix run .#deploy           # build locally and deploy to a remote host
nix run .#flash            # write an ISO to a USB stick
```

`scripts/build.sh` runs a local `nixos-rebuild`; `scripts/deploy.sh` builds locally
and activates the closure on a remote host.

## Documentation

- [Manual](https://homefree.host/manual/) · [FAQ](https://homefree.host/faq/) · [Comparison with other projects](https://homefree.host/comparison/)
- [Backup & restore guide](./docs/BACKUP_RESTORE.md)
- The landing page and manual sources live in [`services/landing-page/`](./services/landing-page).

## License

GPLv3 — see [`LICENSE`](./LICENSE).
