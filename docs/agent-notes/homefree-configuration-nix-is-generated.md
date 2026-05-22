# Per-instance config: homefree-config.json → homefree.* (no generated Nix file)

**Historical note retitled.** There USED to be a generated
`/etc/nixos/homefree-configuration.nix` that mapped `homefree-config.json`
into `homefree.*`. It was rendered from a string-literal template
(`HOMEFREE_CONFIG_TEMPLATE`) inside
`web-platform/backend/services/install.py` by `scripts/sync-template.py`,
and only on "proper" rebuilds (the project build script / admin UI Apply).
That generated file went stale on a bare `nixos-rebuild switch` (the sync
never ran), and it duplicated mapping logic that belongs with the code —
which caused a real boot failure when new `homefree.storage` bindings
never reached the box.

**That model is gone.** The mapping now lives in the SHARED repo as a
proper, versioned Nix module — it can never go stale because it is always
the current shared code.

## The new model

```
/etc/nixos/  (per-instance config — ONLY these, no generated Nix file)
├── flake.nix              reads homefree-config.json, wires the loader
├── homefree-config.json   single source of truth for homefree.* + admin pw hash
├── configuration.nix      instance overrides (hardware, bootloader, extra modules)
├── disko.nix              filesystem / LUKS / swap layout
├── hardware-configuration.nix
├── custom-flakes.nix      (optional) developer flakes
└── secrets/               encrypted, backed up

flake.nix
  ├─ homefreeConfigJson = builtins.fromJSON (builtins.readFile ./homefree-config.json);
  └─ nixosSystem {
       modules = [
         homefree.nixosModules.homefree            # the platform
         homefree.nixosModules.homefree-config-loader   # << the mapping
         ./configuration.nix
       ] ++ customFlakeModules;
       specialArgs = {
         homefreeConfigJson;          # parsed JSON, passed to the loader
         homefreeInstanceDir = ./.;   # the /etc/nixos path (for mediawiki logo)
         ...
       };
     }
                       │
                       ▼
homefree-repo: modules/homefree-config-loader.nix   (SHARED, versioned)
  - reads `homefreeConfigJson` (specialArg) and sets homefree.*
  - all the old `or`-default tolerance preserved verbatim
  - orphaned-services filtering uses `options.homefree.services ? <name>`
  - mediawiki logo-path string→path uses `homefreeInstanceDir + "/..."`
                       │
                       ▼
homefree-repo: configuration.nix
  - sets users.users.<adminUsername>.hashedPassword from
    config.homefree.system.hashedPassword (loaded from JSON)
```

## Where each old concern moved

- **HOMEFREE_CONFIG_TEMPLATE** → `modules/homefree-config-loader.nix`
  (deleted from install.py). Add new JSON→Nix bindings HERE, in shared
  code — they reach every box on the next rebuild automatically.
- **`scripts/sync-template.py`** → deleted. `scripts/sync-config.sh` no
  longer renders any Nix file (it still reconciles homefree-config.json
  against the module.nix schema via `sync-config.py`).
- **`./.` resolving to /etc/nixos** (mediawiki logo-path import): the
  loader can't use its own `./.` (that's a /nix/store path; the user's
  logos under /etc/nixos/images/ are outside it and pure eval rejects the
  import). flake.nix passes its own `./.` as `homefreeInstanceDir`, and
  the loader builds the path from that — exactly what the old generated
  file did implicitly.
- **DNS / dynamic-dns secret file paths** (`/var/lib/homefree-secrets/...`)
  are absolute paths, unchanged — they don't depend on the file location.
- **Admin username + password hash** (the old `@@username@@` /
  `@@hashed_password@@` placeholders): username comes from
  `system.adminUsername` in the JSON (already present). The password hash
  now lives in the JSON too, under `system.hashedPassword` (it is a crypt
  hash, not plaintext — same security posture as the world-private,
  git-tracked /etc/nixos files that carried it before). The loader sets
  `homefree.system.hashedPassword`; shared `configuration.nix` applies it
  to the admin account via `users.users.<name>.hashedPassword` (overrides
  the empty `initialHashedPassword`). `or null` tolerance: an older JSON
  without the key leaves the account password unset.

## Backward compatibility

- No JSON schema change is REQUIRED for deployed boxes. Every new binding
  keeps its `or`-default, so a pre-storage / pre-localization /
  pre-hashedPassword homefree-config.json still evaluates.
- `system.hashedPassword` is the one key a migrating box should add (copy
  it out of the old generated homefree-configuration.nix's
  `users.users.<name>.hashedPassword`). Until then the account password
  is whatever it already was at runtime; the rebuild won't fail.

## Migrating an existing box

1. Add `system.hashedPassword` to `/etc/nixos/homefree-config.json` (copy
   the hash from the old `homefree-configuration.nix`).
2. Rewrite `/etc/nixos/flake.nix` to the new model (read the JSON, add
   `homefree.nixosModules.homefree-config-loader`, pass `homefreeConfigJson`
   + `homefreeInstanceDir = ./.` via specialArgs, drop the
   `./homefree-configuration.nix` module entry).
3. Remove the `./homefree-configuration.nix` import from
   `/etc/nixos/configuration.nix`.
4. The stale `homefree-configuration.nix` file can stay on disk (now
   unused) or be deleted.
5. On a dev box that pins `homefree` to a local checkout
   (`git+file://`/`path:`), re-lock that input so the new loader module is
   picked up (strip its node from flake.lock + `nix flake lock
   --allow-dirty-locks`; a plain `flake update <input>` no-ops on a dirty
   tree — see flake-lock-local-input-refresh.md).

## Rule

**Any new JSON→Nix binding belongs in
`modules/homefree-config-loader.nix`** (shared, versioned). There is no
generated file to keep in sync anymore, and no install.py template to
patch. Verify with `nixos-rebuild dry-build --flake /etc/nixos#<host>`.
