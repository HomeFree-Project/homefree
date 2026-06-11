# App-platform primitive — `homefree.containers`

`modules/app-platform.nix` declares a registry, `homefree.containers.<name>`,
consumed by a generator that emits the per-CONTAINER skeleton every app used to
hand-roll: a dedicated system user/group, the marker-gated data-dir `chown`, the
CA-bundle synthesis (system roots + Caddy local CA) for in-container OIDC
discovery, the `oci-containers` declaration, and the `podman-<name>` unit ordered
after `dns-ready`.

**The unit of duplication is the CONTAINER, not the app.** So an app declares one
entry per container:
- single-container app (`apps/homebox`) → 1 entry
- multi-container app (`apps/immich` ×3, `apps/netbird` ×5, `apps/nextcloud` ×4)
  → several entries (use `dependsOn` for ordering)
- non-container app (`apps/headscale`, mediawiki/minecraft which generate
  containers per-instance) → 0 entries; it does its own thing

An app's INGRESS / backup / SSO / admin-catalog presence stays in its
`homefree.service-config` entry — that is workload-agnostic (a 3-container app
still has ONE service-config entry; a host-service app has one with 0 containers).

## Adding / migrating an app

Replace the hand-rolled `virtualisation.oci-containers.containers.<c>` +
`systemd.services.podman-<c>` + `users.users/groups.<name>` + the preStart with
one `homefree.containers.<c> = lib.mkIf <enable> { … }` per container. Keep the
option declarations and the `service-config` entry. Descriptor fields:

| field | meaning |
|---|---|
| `image` / `imageFile` | registry ref / locally-built tarball (`apps/radicle`) |
| `runAs` | `{ mode = "rootless"|"linuxserver"|"root"; uid; gid; reason; createUser; }` |
| `dataDir` | dir to `mkdir -p` + (rootless) chown via a `.chowned-<uid>` marker |
| `chownDir` | chown/marker target when it differs from `dataDir` (e.g. `apps/webdav` mkdir's `.../data` but chowns the parent) |
| `caBundle` | synthesize+mount the CA bundle; `caBundleEnvVar` (null ⇒ mount-OVER the in-container path, no env, e.g. `/etc/ssl/certs/ca-certificates.crt`) + `caBundleContainerPath` |
| `ports`/`volumes`/`environment`/`environmentFiles`/`extraOptions`/`cmd`/`dependsOn`/`autoStart` | passed through to the oci-container |
| `capNetBind` | add `--cap-add=CAP_NET_BIND_SERVICE` (privileged port) instead of `--privileged` |
| `dnsReady` | order the podman unit after `dns-ready` (default true) |
| `preStartInit` | app preStart fragment AFTER mkdir, BEFORE the chown marker |
| `preStartFinal` | app preStart fragment AFTER CA-bundle synthesis (e.g. OIDC env synthesis) |

### `runAs` modes (rule 13)
- `rootless` — drops to `uid:gid` via podman `user=`, chowns the data dir, and a
  dedicated `users.users.<name>` (HomeFree range 800–899) is created.
- `linuxserver` — LSIO/s6 images: emits `PUID`/`PGID` env (no `user=`), and a
  dedicated user is created — UNLESS `createUser = false`, for images whose
  PUID/PGID point at a GENERIC uid (e.g. 1000, `apps/lidarr`/`apps/nzbget`) that
  must not get a new system user (would collide with the host admin).
- `root` — documented-skip; record why in `reason`.

### Idioms / gotchas
- If the app's preStart does its OWN mkdir/ordering or sets `set -eu` first, use
  `dataDir = null` and put the WHOLE preStart in `preStartInit` so the generator
  doesn't prepend a reordering `mkdir` (`apps/radicle`, `apps/freshrss`).
- Bespoke `ExecStartPost`/postStart (OIDC provisioning, `occ`, SQL bootstrap),
  extra unit `after`/`requires`/`partOf`, shutdown tuning, etc. stay as a SEPARATE
  `systemd.services.podman-<name>` declaration ALONGSIDE the descriptor — it
  merges with the generated unit and is snapshot-invisible. The bespoke-heavy apps
  (immich/nextcloud/netbird/forgejo/home-assistant/matrix) migrated their container
  SHELLS this way.
- `--device` / `--user=`/`--network=host` that an app sets directly ride in
  `extraOptions` (do NOT convert host-net `--user=` to `runAs.rootless` — that
  would set the podman `user=` field; see `apps/zitadel`'s `zitadel-login`).

## Safety net
Behaviour preservation is gated by the app-config and app-prestart snapshots —
see [snapshot-test-net.md](snapshot-test-net.md). A migration is correct iff both
stay byte-identical (zero drift). 31 container apps are on the primitive.
