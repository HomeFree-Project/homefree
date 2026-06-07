# Deferred cleanup — developers → plugins rename

The admin "Plugins" page was renamed from "Developers" (commit landing the
rename: the plugin-directory feature). To keep boxes from losing their
registered plugins across the upgrade, the rename shipped with three
backwards-compatibility surfaces and a one-shot startup migration. **All
four are tagged `TODO(homefree-next)` in the source** and should be
removed in a single follow-up commit once you're confident every
deployed box has booted at least once on the renamed code.

## When it's safe to remove

The startup migration in `simple_main.py` moves
`developers.flakes` → `plugins.flakes` in `homefree-config.json` on the
first admin-api start after upgrade. It's idempotent (re-runs are no-ops).
So as long as every box you care about has come up cleanly at least once
since the rename landed, the migration has done its job and these
fallbacks are dead weight.

Quick verification on a box: `jq '.developers.flakes // "absent",
.plugins.flakes | length' /etc/nixos/homefree-config.json` — should print
`"absent"` then a number. Anything else means that box hasn't migrated.

## What to delete (one commit, mechanical)

Each site below carries the `TODO(homefree-next)` marker. A
`grep -rn 'TODO(homefree-next)'` lists them all.

1. **Startup migration** —
   `web-platform/backend/simple_main.py`
   - The `_migrate_developers_flakes_to_plugins()` call inside the
     `clear_service_restart_flag` startup handler.
   - The two helper functions `_migrate_developers_flakes_to_plugins()`
     and `_write_migrated_config()` themselves.

2. **`/api/developers/flakes*` route aliases** —
   `web-platform/backend/simple_main.py`
   - The `for _legacy_path, _method, _handler in (…)` block that
     registers six legacy paths via `app.add_api_route(...,
     deprecated=True)`.
   - **Do NOT touch `/api/developers/homefree-base*`** — those are
     not aliases; they're the primary routes for the alternate-base
     override, which legitimately lives under `developers.*`.

3. **Tolerant reader fallback** —
   `web-platform/backend/services/plugins.py`, `list_flakes()`
   - Drop the `if not isinstance(flakes, list): … config.get("developers")
     …` fallback block. After cleanup, `list_flakes()` reads only
     `config.get("plugins", {}).get("flakes", [])`.

4. **Frontend export aliases** —
   `web-platform/frontend/src/api/client.js`
   - Delete the six `export const getDeveloperFlakes = getPluginFlakes;`
     (and siblings) at the end of the Plugins section.

5. **Frontend dirty-path fallback** —
   `web-platform/frontend/src/components/admin/admin-app.js`, the legacy
   `case 'developers': return 'plugins';` in `pathOwnerModuleId()`.

6. **Frontend `developers.flakes` fallbacks in `plugins-module.js`** —
   - `_pluginsUndeployed()` line that checks `p === 'developers.flakes'`
   - `_flakeChanged()` lines that read `this.appliedConfig?.developers?.flakes`
     and `this.undeployedPaths?.has('developers.flakes')`

## What stays put

- The `developers.homefree-base` JSON key and the `/api/developers/homefree-base*`
  routes. The alternate-base override is a genuinely developer feature
  that lives on the Source Code page; only the plugins list got renamed.
- The Python class `PluginsService` and the file `services/plugins.py` —
  these are the post-rename targets, not part of the cleanup.

## After deletion

Build + run the admin UI, then on a freshly-migrated box:
- Confirm the Plugins page still lists registered plugins.
- Confirm `/api/developers/flakes` 404s (the alias is gone) but
  `/api/plugins/flakes` works.
- Confirm `/api/developers/homefree-base` still works (it's NOT an alias).
