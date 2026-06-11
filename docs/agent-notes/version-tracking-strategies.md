# Per-app version-tracking strategies (the App Versions "Source Code" page)

The admin **Source Code** page (`<app-versions-module>`) shows every app's
current pin vs. the latest upstream. The detection engine is
`web-platform/backend/resolvers/app_versions.py`; per rule 8 only the backend
talks to upstream, the frontend renders a cache.

## The model

Core owns a **named-strategy catalog**; each app *selects + parameterises* one
via a `version-tracking` descriptor on its `homefree.service-config` entry
(declared in `module.nix`, projected by `services/service-config-json`). Per
rule 1 nothing app-specific lives in core — plugin apps carry their descriptor
in their own repo.

- **Default `strategy = "image"`** (all params empty) is the *pre-existing*
  behaviour: infer the lookup from the OCI image's registry host
  (`_REGISTRY_FETCHERS`) + the ghcr→GitHub-Releases fallback. An app that sets
  nothing is byte-for-byte unchanged — the regression guard is
  `test_app_versions_strategies.py::test_image_strategy_delegates_unchanged`
  plus the all-default rows in the snapshot golden.
- **Explicit strategies**: `github-releases`, `github-tags`, `docker-hub`,
  `ghcr`, `oci-v2`, `gitlab`, `forgejo`/`gitea`, `nixpkgs` (host apps),
  `url-regex` + `command` (generic escape hatches), `none` (opt-out → a
  distinct `untracked` status, never a scary `unknown`).
- **Params**: `repo`, `registry`, `tag-pattern` (regex filter), `channel`
  (`stable`|`prerelease`|`any`), `current-version`, `url`/`regex`, `command`.

## Non-obvious bits (the gotchas)

- **`channel` distinguishes a pre-release from a flavour.** `33.0.5-apache` is a
  flavour stream (`_tag_shape` keeps it separate); `v0.108.0-b.88` is a
  pre-release. `channel="stable"` drops pre-releases AND **reshapes the anchor**
  (strips `-b.88` so a beta pin can compare to the stable line). Each beta
  *build* is its own `_tag_shape` (the build number is in the suffix), so the
  strict picker can't advance `b.88 → b.90` — `channel="prerelease"` switches to
  the **shape-agnostic loose picker** to track a beta line (adguard).
- **A declared `current-version` uses the loose, tuple-only comparison**, because
  its shape is decoupled from the upstream tags (headscale's nixpkgs `0.28.0` vs
  the GitHub `v0.28.0`). Without that, `_pick_latest`/`_same_release`'s
  same-shape guard rejects every candidate. A declared `current-version` may also
  sit *above* the latest upstream RELEASE (a box on a nixpkgs build past the last
  stable tag) — that reads **up-to-date** (`current >= latest`), not unknown. The
  image-tag pre-release anchor keeps the no-downgrade guard (a below-anchor max
  there is the registry page-cap, not the operator being ahead).
- **`_tag_shape` normalises a leading `v`** so `0.17.1` (frigate's image pin) and
  `v0.17.1` (its GitHub release) are one stream — the most common image-vs-tag
  mismatch, and what makes the ghcr→GitHub fallback actually match. `version-`/
  `release-` prefixes stay distinct (grocy's `4.6.0` vs `version-v4.6.0`).
- **`command` runs as root in the sandboxed refresher** — so the resolver
  refuses anything that isn't a `/nix/store` path. The command is an eval-time
  store path declared in the app module (immutable, reviewed), NEVER runtime
  input. Don't add an API surface that can set it.
- **Keying: descriptors are declared per LABEL, rows are keyed per CONTAINER.**
  `services/admin-web` aliases the service metadata under every container that
  shares the entry's **primary** (first `podman-*`) container's **image**. That
  one rule covers both name≠label (unifi's container `unifi-os` → label `unifi`)
  AND blue/green pairs that share one image (`oauth2-proxy-blue` +
  `oauth2-proxy-green` both resolve the `oauth2proxy` entry's descriptor).
  Matching on *image* (not "all containers") keeps a genuine sidecar with a
  DIFFERENT image (immich-redis, postgres-vectorchord) OUT of the alias, so it
  stays on the default `image` strategy instead of inheriting the app's upstream.
  A sidecar that needs its own descriptor would have to carry it per-container —
  not supported today (see residuals below).
- **Host (non-container) apps** (headscale, opensprinkler, backup-canary) ship no
  image, so they appear in neither image catalog. `services/admin-web` emits
  `host-apps.json` for any non-container entry that declares a non-`image`
  strategy; the resolver merges those as rows with `current` from
  `current-version`. An app on the default `image` strategy with no image is
  deliberately omitted (genuinely untrackable) rather than shown as a perpetual
  unknown.
- **No `release-tracking` shim.** The legacy `release-tracking {type,project}`
  field stays declared (rule 11) but is still inert — wiring it to
  `github-releases` would REGRESS nextcloud (image tag `33.0.5-apache` has no
  same-shape match in `nextcloud/server`'s `vNN` releases). immich/nextcloud
  resolve fine on the default `image` strategy; leave them there.

## Flavour-heavy Docker Hub repos (redis/postgres) — the name-filter

Official flavour-heavy repos (redis, postgres) publish many variant tags
(`-alpine`, `-bookworm`, …) per release, so the plain `X.Y.Z` tag of the current
line gets pushed off the recent-100 window by later backport variants — the
default picker then finds nothing comparable. `_fetch_docker_hub_tags` takes the
`current_tag` and, when it knows one, fires a SECOND request filtered by its
`<major>.<minor>` (Hub's `name=` substring filter) and merges the results — that
resurfaces the buried line (grampsweb-redis's `8.8.x`). The fetcher signature is
uniform (`repo, registry, current_tag=""`) across all registries; only Docker Hub
uses the filter.

## More hard-won edge cases

- **All-pre-release release windows** (headscale mid-beta-cycle): releases.atom
  can list ONLY `v0.XX.0-beta.*` entries, so `channel=stable` empties the
  candidate set entirely. In loose mode (declared `current-version`) the picker
  then returns the stable anchor itself as latest — the box runs the newest
  known stable → up-to-date, not perpetual unknown. A pre-release anchor does
  NOT get this promotion.
- **Bare flavour aliases are floating**: `redis:alpine` / `:slim` /
  `:bookworm` roll forward like `latest` — they're in `_FLOATING_TAGS`, so the
  row reads "Floating tag", not a failed lookup. Versioned flavours
  (`8.8.0-alpine`) still parse as versions. (grampsweb's plugin pins
  `redis:alpine` — that's the plugin's hygiene to fix, in its own repo.)
- **External (plugin) provenance**: containers defined OUTSIDE this repo's tree
  (detected via `definitionsWithLocations` on both `virtualisation.
  oci-containers.containers` AND `homefree.containers` — the generator would
  otherwise mask registry apps) are emitted with `external: true` in
  `container-images.json`. The frontend shows a "Plugin" pill, hides the
  per-row Update button (`upgrade-apps.py` can only edit THIS repo's checkout),
  and the pending-rebuild overlay skips them (a plugin sharing a base image —
  grampsweb's redis vs the repo's redis pin — otherwise produces a false
  "Pending rebuild").
- **`updatable` gates the per-row Update button**: one-click bumping runs
  `upgrade-apps.py`, which rewrites IMAGE pins in this repo — so a row is
  updatable only when it has an image, isn't external, AND its `current` comes
  from the pin itself. A declared `current-version` marks the version as living
  elsewhere (opensprinkler's vendored `ui/`, headscale's nixpkgs build) — or
  marks "latest" as a source tag that is NOT a valid image tag (nzbget's GitHub
  `v26.1` vs its LSIO `version-v24.8` pin). Such outdated rows show a muted
  "Manual" pill in the button slot instead of a button that silently no-ops.
- **Custom per-app updater — `version-tracking.update-command`**: the update
  side of the same inversion. A /nix/store script declared IN the app module;
  the per-row Update button runs it as `script <checkout-root> <target-version>`
  (cwd = the writable local alternate-base checkout, 300s budget, last stdout
  line = reported new value) INSTEAD of upgrade-apps.py. Declaring it makes the
  row one-click updatable regardless of how its version is tracked — the app
  owns translation/safety (nzbget translates the GitHub `v26.1` into LSIO's
  `version-v26.1` and rewrites its own pin). Only the per-app path runs it; the
  bulk "Update apps" stays pins-only. Store-path-only, never API input.
- **Suffix ordering is numeric** (`_suffix_key`): `-b.9` < `-b.88` < `-b.90`.
  A plain string compare picked adguard's build NINE as "latest", which
  upgrade-apps then refused as a numeric downgrade — a dead Update button.
  Plain releases still sort above any pre-release of the same base.
- **Capture-group `tag-pattern`**: a pattern WITH a capture group compares on
  the captured sub-version but recommends the FULL pullable tag — how immich's
  postgres (`18-vectorchord0.5.3-pgvector0.8.1`) is tracked (pattern derives
  the pg major from the pin, so a pg bump retunes it).
- **Instance/colour collapse** (`_collapse_instance_rows`): enabled containers
  whose repo maps to exactly ONE source app collapse into a single row tracking
  the SOURCE pin — minecraft's per-instance containers (instance `image-tag`
  overrides are App-Configuration config, not source pins) and the
  oauth2-proxy blue/green pair. Shared base images (library/redis pinned by
  several apps) are ambiguous and deliberately stay per-container.
- **`guarded` = the SSO-lockout guard, surfaced**: `upgrade-apps.py` skips every
  pin in `apps/zitadel/default.nix` (zitadel + login UI + **oauth2-proxy**, all
  pinned in that one file) unless `--include-zitadel` — a bad identity-core bump
  locks every login out, including the admin UI. The resolver mirrors that
  (`_SSO_GUARDED_APP_DIRS`, rows attributed to their apps/<dir> via a source-scan
  repo map) and outdated guarded rows show an amber "SSO guard" pill instead of a
  button the script would refuse. Deliberate path: read release notes →
  `scripts/upgrade-apps.py --include-zitadel` → rebuild.

## Residuals (genuinely unresolved, on purpose)

- **lidarr** is pinned `8.1.2135` — a version string that matches NO real
  `linuxserver/lidarr` tag (the repo's stream is `3.1.0` / `version-3.1.0.4875`;
  there is no major 8). It's a broken/stale pin, not a tracking gap — flagged to
  the maintainer; correcting the pin is a deploy-affecting decision, not done
  here. Once the pin is a real tag, the default strategy resolves it.
- The "sidecar" cases turned out NOT to need a per-container mechanism:
  immich's `postgres-vectorchord` is its OWN service (`services/postgres-
  vectorchord`), so it carries `version-tracking.strategy = "none"` directly (its
  `18-vectorchord…-pgvector…` tag is a non-semver compound — nothing to compare).
  A genuinely app-internal sidecar needing its own descriptor would still have
  nowhere to put it — revisit a per-container map only if such a case appears.

## Snapshot golden

Adding/changing a `version-tracking` descriptor alters
`tests/app-config-snapshot.json` (it captures the full `service-config`).
Regenerate it **in the same commit** (header of `checks/app-snapshot.nix`) — see
[snapshot-test-net.md](snapshot-test-net.md). Backend unit tests live in
`web-platform/backend/tests/test_app_versions_strategies.py` (web-platform
flake's `python-unit`, not `homefree-python-unit`).
