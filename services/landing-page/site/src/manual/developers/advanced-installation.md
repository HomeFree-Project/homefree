---
title: "Advanced installation — Developers"
---

# Advanced installation

This is the **build-from-source / contributor path**. If you just want a working HomeFree, use the [ISO installer](/installation/) — it's faster and there's nothing meaningfully different in the result.

You'd want this page if:

- You're hacking on HomeFree itself and want to deploy your own fork.
- You need to customize the build (extra services, patched modules) beyond what the installer exposes.
- You're already a NixOS user and prefer driving everything from a config file you control.

## What you'll need

- The target HomeFree box, wired up per [Hardware setup](/hardware-setup/).
- A workstation with [Nix installed](https://nixos.org/download/). NixOS is ideal; Nix-on-Linux or Nix-on-macOS also works.
- A USB stick with the standard **minimal NixOS ISO** (not the HomeFree ISO) — download from [nixos.org/download](https://nixos.org/download/).
- An ethernet cable plugged into the target box (Wi-Fi install isn't supported).

## 1. Boot the target from the NixOS minimal ISO

Burn the minimal NixOS ISO to a USB stick (Etcher / Rufus / `dd`), plug it into the target box, and boot from it. Disable Secure Boot in firmware first.

## 2. Find the target's LAN IP

From the booted-NixOS shell on the target:

```
ip addr show
```

Note the IPv4 address on the wired interface — you'll need it shortly.

## 3. Clone the sample config on your workstation

```
git clone https://github.com/HomeFree-Project/sample-config
cd sample-config
```

## 4. Edit the config

Open `configuration.nix` in the sample-config repo. The top section is what you'll touch:

- Your **public domain**.
- The **admin username**.
- The **WAN / LAN interface names** (e.g. `enp1s0`, `enp2s0` — match the names you saw under `ip addr show` on the target).
- Which **services** to enable.

The file is heavily commented; most installs only touch this top section.

## 5. Run the installer script

Back on your workstation, still in the sample-config directory:

```
./install.sh
```

Enter the target's IP when prompted. The script:

1. SSHes into the booted minimal NixOS on the target.
2. Wipes the target disk.
3. Lays down the HomeFree image with your configured services.
4. Reboots the target into the running system.

About 15 minutes end-to-end.

## 6. Sign in

The box defaults to `10.0.0.1` on its LAN side. From a wired client on the LAN:

```
ssh adminuser@10.0.0.1
```

For the web admin UI, visit `https://homefree.lan` (or `https://<your-domain>` once DNS is pointed at the box). You'll be redirected to Zitadel to set the admin password the first time.

## 7. Iterating

Once the system is up, future config changes are deployed from your workstation:

```
# in your sample-config repo, after editing configuration.nix
nixos-rebuild switch \
  --flake .#<hostname> \
  --target-host adminuser@<target> \
  --use-remote-sudo
```

Typical rebuild for a tweak: a couple of minutes. First rebuilds after a fresh clone take longer (Nix is fetching everything).

## What next

- Verify DDNS is updating your registrar (the admin UI's *Network* page shows current status).
- Open the admin UI and enable the services you want.
- Add users in Zitadel — they'll have SSO across every app immediately.
- Configure backups (Backblaze B2 is the default S3 target; any S3 endpoint works).

## Stuck?

- The [FAQ](https://homefree.host/faq) covers common snags.
- [#homefree:homefree.host](https://matrix.to/#/#homefree:homefree.host) on Matrix is where folks hang out.
- The HomeFree repo's `README.md` and `configuration.example.nix` are the source of truth for what options exist.
