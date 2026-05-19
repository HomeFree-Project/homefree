# Refreshing a local working-tree flake input

## The setup

On a dev box the system flake (`/etc/nixos/flake.nix`) overrides the
`homefree` input to point at the local checkout:

```
homefree-alt.url = "git+file:///home/erahhal/homefree";
```

`flake.lock` pins every input — including this one — by `narHash`.
When `homefree-alt` points at a **dirty** git tree (the normal dev
state: staged/unstaged edits, no fresh commit), Nix locks it by
`narHash` + a `dirtyRev` marker.

## The trap

Editing files in `~/homefree` does **not** make a `nixos-rebuild` pick
them up. The rebuild evaluates the **locked** snapshot. The lock must be
refreshed first — and the obvious refresh command does not work:

```
nix flake lock --update-input homefree-alt   # NO-OP on a dirty tree
nix flake update homefree-alt                # same — its successor
```

On Nix 2.34, when the input already has a **dirty-lock** entry,
`--update-input` / `flake update <input>` sees that entry, treats it as
already satisfied, and does **not** re-hash the working tree. It exits 0
with only warnings. The lock keeps the old hash; the rebuild builds
stale code. Symptom: "I changed a file, applied, and nothing happened" —
or worse, a fix appears not to work and you chase a phantom bug.

`--allow-dirty-locks` is required to *write* a lock for a dirty input at
all, but it does not make `--update-input` re-resolve.

## What actually works

Delete the input's node from `flake.lock` (and scrub every dangling
reference to it from the other nodes' `inputs` maps — a lock that
references a missing node is rejected), then run a plain
`nix flake lock --allow-dirty --allow-dirty-locks`. With the node gone,
Nix has nothing to treat as satisfied and **must** re-evaluate the input
from `flake.nix`, re-hashing the live tree.

The admin UI does this automatically before every rebuild —
`web-platform/backend/services/nix_operations.py`,
`_refresh_local_inputs()`. It identifies local inputs by lock `type`
(`path`, or `git` with a `file://` URL — see `_input_is_local_working_tree`),
so it is fork/rename-agnostic and a no-op on production installs (whose
inputs are all remote).

## Manual equivalent

```
cd /etc/nixos
# strip the local input node + refs, then:
sudo nix flake lock --allow-dirty --allow-dirty-locks /etc/nixos
```

`scripts/build.sh` does the command-line version of the same refresh.

## Don't

- Don't `git checkout flake.lock` to "restore" it — `flake.lock` is not
  necessarily committed in `/etc/nixos`; the index can hold an empty
  staged copy and the checkout will truncate the file to 0 bytes.
- Don't compare a flake's `narHash` to `nix hash path .` — they hash
  different file sets (the flake narHash excludes `.git` and untracked
  files). A mismatch there is expected, not a stale lock.
