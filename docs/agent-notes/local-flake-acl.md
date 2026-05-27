# Keeping a local-flake `.git` writable after a root-run rebuild

## The setup

A developer registers their fork via the Admin UI's Developers section.
That writes a `homefree-alt.url = "git+file:///home/<user>/homefree";`
override into `/etc/nixos/flake.nix` (or a `custom-flakes.nix` entry for
non-base local flakes). The rebuild then resolves that input from the
developer's working tree.

## The trap

`nixos-rebuild` runs as **root**. To resolve a `git+file:` input Nix
shells out to `git` against the source path — `git rev-parse`,
`git ls-files`, an internal dirty-tree copy, etc. Those invocations
write inside the source `.git`:

- Refreshes `.git/index` (stat-cache update).
- Drops new object subdirs `.git/objects/<xx>/` when packing or copying
  a dirty tree.
- May write `packed-refs`, lockfiles, or temp files under `.git/`.

The new files end up **owned by root**, mode `0644`/`0755`. The
developer (running as their normal user) then can't write into a
`objects/<xx>/` subdir that root created — git's `core.sharedRepository`
default doesn't make it group-writable.

The failure mode is silent and corrupting:

1. Developer runs `git rebase`/`git commit`/`git gc` as themselves.
2. Git updates refs in `.git/refs/` (still user-writable — root never
   replaced those files).
3. Git writes the new commit's loose object into
   `.git/objects/<xx>/<rest>` — *the dir is root-owned* → write fails.
4. Git doesn't always roll back the ref update on a loose-object write
   failure (depends on operation/version). The repo is now in a state
   where a ref points at a commit whose object never landed on disk.

`git fsck` reports `invalid sha1 pointer …`. `nixos-rebuild` then fails
with `error: getting Git object '…': object not found` while updating
the flake lock, because the lock-resolve walks `HEAD`.

The corruption is annoying but recoverable: reset the affected ref to a
commit that does exist (the reflog usually has the pre-operation tip),
then re-do the work. But it shouldn't be a recurring tax on every dev
box, so we prevent it.

## The fix (shared, applied automatically)

`DevelopersService._ensure_writable_for_owner` in
`web-platform/backend/services/developers.py` is called from
`write_flakes` and `write_base_override` whenever a local flake is
registered or updated. For each enabled `git+file://` flake whose `.git`
is owned by a different uid than the running process, it applies:

```
setfacl -R    -m u:<owner>:rwX <path>/.git
setfacl -R -d -m u:<owner>:rwX <path>/.git
```

The first call grants the owning user rwX on every existing entry under
`.git`. The second sets a **default ACL** on the directory tree, so
files created later by root inherit the same ACL — root's incidental
writes from the rebuild are still root-owned, but the developer retains
rwX on them, so `git rebase` can write into a root-created `objects/`
subdir.

Sibling helper `_register_safe_directories` solves the symmetric "root
opens a user-owned repo without complaining about ownership" problem.
The two together cover the read and write halves of the cross-uid case.

### Why ACL and not chown

Chowning `.git` back to the owner only fixes the past — the next
rebuild will create more root-owned files. The default ACL is the only
mechanism that survives future writes without requiring a hook.

### What this does NOT cover

- A developer who hand-edits `/etc/nixos/flake.nix` to add a local
  input, bypassing the Developers UI. They never trigger
  `write_flakes`/`write_base_override`, so the ACL isn't applied. If
  they hit corruption, manual recovery is:
  ```
  sudo chown -R <user>:<group> /home/<user>/homefree/.git
  sudo setfacl -R    -m u:<user>:rwX /home/<user>/homefree/.git
  sudo setfacl -R -d -m u:<user>:rwX /home/<user>/homefree/.git
  ```
- Filesystems without POSIX ACL support (tmpfs, some overlayfs). The
  helper logs a warning and skips; `setfacl` itself errors. ext4/xfs/
  btrfs all support ACLs by default on NixOS.
- An already-corrupted repo — the ACL doesn't synthesize the missing
  commit object. Recover the ref first, then the ACL prevents
  recurrence.

## How to verify it ran

After registering or updating a local flake, on the dev box:

```
getfacl -p /path/to/local/repo/.git | head
# Expect:
#   user:<owner>:rwx
#   default:user:<owner>:rwx
```

Admin-API logs an `Applied owner-rwX ACL to <gitdir> (uid <N>)` line on
success, or a `setfacl` warning on failure.
