---
title: "Storage — HomeFree Manual"
permalink: "/manual/storage/index.html"
---

# Storage

The **Storage** page in the admin UI lists every drive attached to the box and lets you turn unused drives into volumes for your photos, videos, files, and backups. This page explains what each control does, when to use which, and what's destructive vs. reversible.

## Volumes vs. drives vs. mounts

A bit of vocabulary up front, because the buttons make more sense once these are clear:

- **Drive** — a physical disk plugged into the box (SATA, NVMe, USB).
- **Volume** — a HomeFree-managed filesystem built on one or more drives. Creating a volume formats the chosen drives as `btrfs` and records the volume in HomeFree's config so it mounts on every boot. Volumes are what your apps store data on.
- **Mount** — anything mounted into the box's filesystem tree at a specific path (e.g. `/mnt/external`). Volumes are mounts. So are drives you've added via the **Add custom device** flow (an existing NTFS, ext4, or FAT drive you want available on the box). So are NFS/SMB shares pulled in from another machine on the LAN via **Add Network Mount**.

## Creating a volume

Click **+ Create volume** in the Volumes header. The wizard walks you through:

1. **Pick drives** — only unassigned drives appear. The OS drive and any drive currently in use are filtered out automatically.
2. **Pick a RAID profile** — `single` (one drive, no protection), `RAID1` (mirror, survives one failure), `RAID5` (single parity, survives one failure), `RAID6` (double parity, survives two failures), or `RAID10` (stripe + mirror).
3. **Name it and confirm** — the drives are erased and formatted on Apply. For four or more large drives, RAID6 gives the best balance of usable space and safety.

Parity volumes (RAID5/RAID6) build on Linux `md` with btrfs on top and resync in the background after creation — the volume is usable immediately, performance is reduced until the resync finishes.

## Mounting an existing drive

If you plug in a drive that already has data on it (an external NTFS drive, an ext4 USB stick, an NFS export from another machine), use **+ Add custom device** to mount it without erasing it. The drive shows up as a card in the Volumes list with **Mount** / **Unmount** / **Unmanage** buttons.

## Unmount vs. Unmanage vs. Erase

This trio is the source of most confusion. They are not the same:

- **Unmount** — Set the mount to *disabled*. The row stays in HomeFree's config; on the next Apply the box stops mounting it. Reversible — click **Mount** to bring it back. Use this when you want the drive available but temporarily detached (e.g. you'll move it to another machine for a day).
- **Unmanage** — Drop the mount/volume entirely from HomeFree's config. The drive is left exactly as it is on disk — the filesystem is untouched, the data is preserved. Use this when you want the box to stop touching the drive, but you don't want to wipe it. You can re-add it later with **+ Add custom device** or **Mount existing filesystem**.
- **Erase** — Wipe the drive(s). All data is permanently destroyed. The drives become unassigned and selectable for a new volume. Use this when you want to reuse drives that already belong to another array or volume (e.g. an imported NAS). Erase is gated behind a typed confirmation phrase.

If you want to *replace* what's on a drive, the typical flow is **Unmanage** → **Erase** → **Create volume**. If the drive is currently mounted, **Erase** will unmount it and remove it from config in one step.

## NFS and SMB shares

**Shared Folders** (a separate page under System in the sidebar) is for exporting volumes from this box *out* to other machines on your LAN — the opposite direction from Add Network Mount.

NFS shares use host/subnet trust (no per-user login) — anything matching an allowed CIDR or IP can mount the share. New shares default to your LAN subnet; remove that and add individual IPs to lock a share down.

## Encryption

HomeFree supports encrypting data volumes with LUKS. Encrypted volumes are unlocked late in boot using a master passphrase stored under `/etc/nixos/secrets/` — the same passphrase used for system-disk recovery. This means a volume re-attached on a fresh install can be unlocked with the recovery passphrase you wrote down at install time.

The system disk itself is encrypted by default (auto-unlocked by TPM2 when present, with the recovery passphrase as fallback at the boot prompt).

## What stays after an Apply

A useful mental model: every button on this page either touches **config** (reversible until Apply, becomes effective on Apply) or **disk** (immediate, irreversible). Mount, Unmount, Unmanage, and Add custom device all touch config — until you click Apply, you can Undo them. Create volume and Erase touch disk — they happen immediately when you confirm, and the Apply that follows just wires the result into the system.
