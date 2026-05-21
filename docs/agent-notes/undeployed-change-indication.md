# Config source-of-truth & "undeployed change" indication

The admin UI treats `/etc/nixos/homefree-config.json` as the single source
of truth and visually flags everything that differs from the **deployed**
(last-built) config. This touches a lot of moving parts; the invariants below
are easy to break and several were learned the hard way.

## The model

```
/etc/nixos/homefree-config.json   ← THE source of truth (+ flake.nix/
        │  (+ flake files for          custom-flakes.nix/flake.lock for the
        │   Custom Flakes)             Custom Flakes section)
        ▼
/var/lib/homefree-admin/applied-config.json      ← the DEPLOYED snapshot,
/var/lib/homefree-admin/applied-build-inputs.json   written by
        ▲                                            NixOperations._mark_config_applied()
        │                                            on each *successful* rebuild
   "undeployed change" = current config differs from this baseline
```

- **Apply is build-only against disk.** `POST /api/config/apply` IGNORES its
  request body, reads the on-disk config, validates it, writes it back through
  `ConfigWriter` (for the SOPS secret side-effects), then rebuilds. It never
  trusts a client snapshot — that was the original "Apply reverts my hand-edit"
  bug. The UI must flush pending edits to disk (auto-save) BEFORE Apply.
- **Disk ⇄ UI both ways.** admin-app polls `/api/config/current` (~5s) and
  reflects external edits. `ConfigReader.read_config_strict()` makes the
  endpoint return **422** on a parse error so the UI shows a modal and keeps
  its last-good config instead of blanking (the recovery surface must never
  white-screen). `ConfigWriter.write_config` writes **atomically** (temp +
  `os.replace`) because the poll reads it concurrently.
- **`/api/config/dirty` compares SEMANTICALLY** (parsed dicts), never raw text.
  Returns `{dirty, reason, changedPaths}`. A no-op round-trip (key reorder,
  re-serialization, add-then-remove a row) must NOT read as dirty. Do not
  revert to text comparison.

## Frontend change-detection (admin-app.js)

- `recomputeUndeployedPaths()` computes `undeployedPaths` = dotted leaf paths
  where the **merged UI config** differs from `appliedConfig` (the deployed
  snapshot, fetched via `/api/config/applied`). This is authoritative AND
  immediate — reverting a field to its deployed value clears its highlight at
  once, with no backend round-trip. Only reassign the Set when it actually
  changed, or the 5s poll re-renders focused inputs and the cursor jumps.
- **`getMergedConfig()` is an explicit allowlist.** It merges only named
  sections (`services`, `network`, `service-config`, `mounts`,
  `proxied-domains`, …) from `pendingConfig` over `serverConfig`. **If you add
  a new editable config section, you MUST add it here** — otherwise edits land
  in `pendingConfig`, never reach the rendered/merged config, and silently
  vanish on save (this was the "Add Mount / Add Proxied-Domain does nothing"
  bug). Legacy form modules (System/DNS/Backups/SSO) instead rely on in-place
  aliased mutation of `serverConfig` (their `handleFieldChange` mutates its
  nested objects in place, and the merge depends on it). So any code that
  REASSIGNS `serverConfig` — e.g. the disk→UI poll — must be gated on "no
  unsaved edits" (`dirtyModules`/save state) or it reverts the field being
  edited.

## Wiring indication for a NEW control

There is no catch-all per element; **enumerate every interactive control, not
every element _type_** — bespoke one-offs (e.g. the Backup Self-Test toggle)
slip through if you only wire the common widgets. Per pattern:

- **`form-field`** → set `?undeployed=${this._undeployed('dotted.path')}`
  (amber title + field). The path must equal the one in its `@field-change`.
- **`table-editor`** (lists) → pass `.appliedData` (deployed rows, mapped
  through the SAME display transform as `.data`) for per-row amber + ghost
  rows, AND `.rowKey="<identity col>"` (e.g. `label`, `mount-point`, `zone`)
  so a MODIFIED row reads as *changed*, not remove+add. Without `rowKey` an
  edit looks like the old row removed + a new one added.
- **service cards / options** → `app-card` and `service-option-input` take an
  `?undeployed` boolean.
- **custom list UIs** (abuse-blocking CIDRs, lan-clients reservations) → diff
  each entry against the applied list by a stable key yourself.
- **left-nav badge** → `admin-app.pathOwnerModuleId(path)` maps a dotted path
  to a nav module id. It's **sub-path aware**: `network.*` is split across
  Network / LAN Clients (`network.static-ips`) / Network Traffic
  (`network.abuseBlockCidrs`); `services.*` across App Configuration and
  Backups (`services.backup-canary`). Keep it in sync when paths move.
- **Convention:** amber (`--hf-warn` / `--hf-warn-soft`) = pending/undeployed;
  green stays the Apply action. Static treatment on fields/rows; motion only
  on the Apply button.

## External Proxies are "services" without being toggleable services

`ServicesResolver.get_services()` builds the App Configuration list in two
passes: pass 1 = real toggleable services (`/run/homefree/admin/all-services.json`);
pass 2 = everything else from the **deployed** catalog
(`/etc/homefree/service-config.json`), which includes External-Proxy vhosts.

- An External Proxy (top-level catalog entry, **no systemd units**) is flagged
  `ServiceStatus.external = True`.
- **Its enable/public live in its `service-config` entry — NOT
  `services.<label>`.** `reverse-proxy.enable` gates Caddy + Unbound
  (`services/caddy/default.nix`, `services/unbound/default.nix`); the
  submodule's top-level `enable` drives the catalog/restart-policy. The
  install.py template maps the flat entry's `enable` to BOTH (one toggle).
- `get_services` must read an external entry's enable/public from the **live
  on-disk `service-config[]`** (in `homefree-config.json`), not the deployed
  catalog — the catalog only updates on rebuild, so reading it makes a pending
  toggle revert on reload.
- The App Configuration enable/public toggles for an external service route
  through the `external-proxy-toggle` event → `admin-app.handleExternalProxyToggle`,
  which edits the matching `service-config[]` row. **Never write
  `services.<label>` for an external proxy** — the catalog ignores it, so it's
  dead config that shows up as a phantom undeployed diff.
- **Default-strip list-entry fields** (store `enable` only when `false`,
  `public` only when `true`) in BOTH the External Proxies form and the
  App-Config toggle, so toggling back to a default doesn't leave an explicit
  value that reads as a change. Keep the two paths in the same representation.

## Key files

- `web-platform/backend/simple_main.py` — `/api/config/{current,apply,dirty,applied}`
- `services/config_reader.py` (`read_config_strict`), `services/config_writer.py`
  (atomic write), `services/nix_operations.py` (`_mark_config_applied`,
  `compute_changed_paths`, `build_inputs_dirty`)
- `resolvers/services.py` — `get_services` two-pass + `disk_service_config`;
  `models.py` `ServiceStatus.external`; `install.py` service-config template
- `components/admin/admin-app.js` — `getMergedConfig`, `recomputeUndeployedPaths`,
  `pathOwnerModuleId`, `handleExternalProxyToggle`, `refreshConfigFromDisk`
- `components/shared/{form-field,table-editor,app-card}.js`,
  `components/admin/service-option-input.js`, and the per-module wiring
