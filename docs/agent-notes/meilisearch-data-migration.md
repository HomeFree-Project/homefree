# Meilisearch data-migration on minor-version bumps

How to bump the meilisearch image pin in `apps/linkwarden/default.nix`
without bricking the running container, and what to do when the bump
has already been deployed and the container is in a restart loop.

## What goes wrong

Meilisearch refuses to read a `data.ms` written by an older minor
version. A bump from e.g. v1.43.0 to v1.45.2 produces a hard error on
startup:

```
ERROR meilisearch: error=Your database version (1.43.0) is incompatible
                   with your current engine version (1.45.2).
```

The container exits 1, systemd auto-restarts it, the next start hits
the same error — restart-loop until the operator intervenes. No data
is mutated by the failed start (meilisearch refuses to touch the DB
when the version marker disagrees), so recovery is fully reversible.

The upstream guidance for minor bumps is dump-and-import: spin the OLD
engine, `--export-dump-to <file>`, swap to the NEW engine, `--import-dump`.
HomeFree doesn't have a migration framework today (AGENTS.md rule 11
defers introducing one), so for now the playbook is per-event manual.

## Which apps are affected

Today: only `apps/linkwarden/default.nix` ships a meilisearch
container (`version-meili` binding). If a future app adds a meilisearch
sidecar this note still applies; if multiple apps ever share a
meilisearch instance, the dump/import path is the only choice
(re-indexing one app would orphan the others' indices).

## Why "drop the data and re-index" is the correct recovery for Linkwarden

Linkwarden uses meilisearch as a SEARCH INDEX over its bookmarks. The
authoritative store is the linkwarden postgres database (`linkwarden`
DB owned by the `linkwarden` role). Meilisearch's `data.ms` is
**derived state** — linkwarden re-pushes bookmark records into the
index, and there is an admin "Re-index" action in Linkwarden's UI that
walks the postgres table and rebuilds the index from scratch.

So losing the meili index is recoverable from postgres in seconds (the
data dir was ~320 KB at the time of writing). Compare to the dump/import
path: dump+import works but requires having BOTH engine versions
available locally as podman images at recovery time, plus a brief
window where meilisearch is mid-migration. For Linkwarden specifically,
re-index is simpler and equally lossless.

**Don't generalise.** If meilisearch were ever the system-of-record for
some HomeFree app (an unusual choice — meilisearch isn't a primary
store), the re-index path would be data-destructive. The "is the
source-of-truth elsewhere" check is per-app.

## The recovery dance (data-is-rebuildable case)

The data dir layout on a HomeFree box that has previously been
upgraded is recognisable — every prior recovery leaves a
`data.ms.old-<version>` snapshot beside the live `data.ms`. The dance
below adds another snapshot rather than deleting:

```bash
# 1. Stop the failing container so meilisearch lets go of the data dir.
sudo systemctl stop podman-meilisearch

# 2. Rename the v<old>-format data dir aside. Pick a name that records
#    the engine version the data was written by — that's the format the
#    file refuses to upgrade, NOT the version you tried to bump to.
sudo mv /var/lib/linkwarden-podman/meili/data.ms \
        /var/lib/linkwarden-podman/meili/data.ms.old-<OLD_VERSION>

# 3. Start the new engine. It creates a fresh empty data.ms on the
#    next boot, comes up cleanly on :7700.
sudo systemctl start podman-meilisearch

# 4. Confirm it's actually serving (not in another restart loop):
sudo systemctl is-active podman-meilisearch
sudo journalctl -u podman-meilisearch -n 30 --no-pager \
  | grep -E 'listening on|incompatible|ERROR'
```

Expected: `starting service: "actix-web-service-0.0.0.0:7700"`. If
you still see the `incompatible` error, the new engine is somehow
reading from an unmoved data dir — verify the mount in
`apps/linkwarden/default.nix`'s `meilisearch.volumes` lines up with
where you `mv`d.

5. In Linkwarden's web UI (Settings → Admin), click "Re-index" so
   linkwarden re-pushes every bookmark into the empty index. For small
   instances this completes in seconds.

The renamed `data.ms.old-<OLD_VERSION>` snapshot is the rollback path
— stop the new engine, swap the dirs back, downgrade the
`version-meili` pin, rebuild. Don't delete the snapshots; they're
cheap on disk and the pattern across boxes suggests at least one
per past upgrade is kept (`data.ms.old-1.12.8` was still around
when v1.43.0 → v1.45.2 hit).

## The other recovery dance (dump/import — when the index is the system of record)

Future-proof reference, not used today:

```bash
sudo systemctl stop podman-meilisearch

# Spin the OLD engine one-shot to dump.
sudo podman run --rm \
  -v /var/lib/linkwarden-podman/meili:/meili_data \
  getmeili/meilisearch:v<OLD_VERSION> \
  meilisearch --import-dump=/dev/null --export-dump=/meili_data/dumps/migrate.json

# Move the data dir aside, leave the dumps subdir in place.
sudo mv /var/lib/linkwarden-podman/meili/data.ms \
        /var/lib/linkwarden-podman/meili/data.ms.old-<OLD_VERSION>

# Bump the pin in apps/linkwarden/default.nix to v<NEW_VERSION>, rebuild.

# On the next start, point the new engine at the dump (the import-dump
# env var or --import-dump arg makes the engine ingest then proceed).
# Apps/linkwarden's container declaration would need a one-shot
# MEILI_IMPORT_DUMP wiring; not currently shipped.
```

The dump approach needs both OLD and NEW engine images present on
the box, AND a wiring path in apps/linkwarden to ingest the dump on
the first start after the bump. None of that exists today; introducing
it is the migration-system work AGENTS.md rule 11 calls out.

## Why the upgrade-apps.py safety guard doesn't catch this

`scripts/upgrade-apps.py:is_unsafe_bump` only refuses numeric
downgrades and tag-prefix scheme changes. A v1.43.0 → v1.45.2 step
ascends numerically and keeps the `v` prefix, so the bumper writes it.
The DB-incompat is an upstream behaviour the bumper has no signal
about. Until a migration framework lands, treat any meilisearch bump
as "manual recovery may be needed" — and consider passing
`--skip linkwarden` (or reverting the meili pin specifically) until
you're ready to run the dance above.
