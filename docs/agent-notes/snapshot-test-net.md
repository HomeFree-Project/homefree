# Snapshot test net (the refactor's safety net)

The repo went from zero tests to a layered net. Everything here is offline +
sandbox-safe and runs under `nix flake check` (the one exception, the KVM boot
smoke, is a package outside the gate). web-platform owns the frontend/backend
checks (`web-platform/flake.nix`); homefree re-exports them via
`flake-modules/checks.nix`. The snapshot machinery lives in
`checks/app-snapshot.nix` and is wired in `checks/default.nix`.

## The snapshots (golden-master tests)

Each captures a deterministic, hash-stripped view of an ALL-apps-enabled config as
a golden file under `tests/`; the check re-evaluates and diffs. **Drift = a
behaviour change.** These were the oracle that made the app-platform sweep, the
SSO decomposition, and the fan-out agents trustworthy (a green snapshot is a
proof, so even cold-agent work is verifiable).

| check | golden | captures |
|---|---|---|
| `app-config-snapshot` | `tests/app-config-snapshot.json` | every container's spec (image/imageFile/user/ports/volumes/env/...), app users+groups (uid 800–899), the full `service-config`, and the SSO `resolved-clients` set |
| `app-prestart-snapshot` | `tests/app-prestart-snapshot.txt` | every `podman-*` `ExecStartPre` script body, normalised: de-indented, comments stripped, store hashes stripped (so re-indent/comment churn is tolerated; a real command change still diffs) |
| `caddy-config-snapshot` | `tests/caddy-config-snapshot.txt` | the generated, `caddy fmt`-canonical Caddyfile — the byte-identical oracle for `services/caddy` (the directive-ordering footgun file) |

Store-path hashes are stripped on both sides (`/nix/store/<32hash>-` → `/nix/store/`)
so a pure rebuild doesn't churn the golden, but a real package swap / version bump
still shows.

### The frozen-golden discipline
Two cases, opposite actions:

- **Behaviour-preserving refactor → goldens are FROZEN.** Never regenerate; the
  migration is correct iff the snapshot stays green untouched.
- **Any INTENDED change that alters rendered output → regenerate the golden IN THE
  SAME COMMIT as the source change**, after reviewing the drift to confirm it's
  exactly what you meant. Triggers (non-exhaustive): an image **version bump**;
  adding/removing/editing a container's `ports`/`volumes`/`environment`/
  `extraOptions`/`user`; a `preStart` change; **adding or removing an app**; a
  `service-config` / Caddy-vhost change; **adding/removing an SSO client**
  (`homefree.sso.clients`). If you changed any of those and didn't touch a golden,
  you almost certainly have a stale golden.

The regeneration commands are in the header of `checks/app-snapshot.nix` (build the
`…Text` derivation / eval `snapshotJson`, jq-sort, hash-strip).

> ⚠️ **Stale goldens are SILENT — `nixos-rebuild` does NOT run `nix flake check`.**
> A change that should have regenerated a golden but didn't will **still build and
> deploy fine** on the box; the only thing that catches it is `nix flake check` (or
> CI), which most rebuilds never run. So a missed regen sits invisibly until someone
> runs the checks, then shows up as a confusing "`main`'s snapshot net is red" with
> the drift being old version bumps. This has bitten the repo: a batch of version
> bumps + an oauth2-proxy `--add-host` merged into `main` without regenerating the
> goldens, leaving the net red while the deploy was perfectly healthy. **The fix is
> always the same:** regenerate against current source and commit (a pure
> re-baseline if the source change was already merged). The cure for the silence is
> discipline at write time — golden and source in one commit — plus running
> `nix flake check` before declaring a snapshot-affecting change done.

> Gotcha: golden regeneration uses an `--impure builtins.getFlake (toString ./.)`,
> which COPIES the whole working tree and chokes on a live VM's
> `vm-state/swtpm/swtpm-sock` socket. If the dev VM is running, regenerate from a
> clean `git clone … /tmp/x` of the committed tree instead (the clone has no
> `vm-state`); `git+file:` getFlake is NOT reliable here (it served a stale cache).

## `frontend-eval` — the Lit module-eval gate

`node --check` (the `frontend-syntax` gate) catches the SyntaxError variant of the
Lit tagged-template backtick bug (a stray backtick mis-closing a `css`…`/`html`…`
template) but NOT the TypeError variant, where the module PARSES but blows up when
the template is EVALUATED ("… is not a function") — the repeat white-screen bug.

`frontend-eval` (`web-platform/frontend/test/lit-eval-smoke.mjs`) imports +
EVALUATES every component module in Node under a minimal DOM shim, honouring
`index.html`'s import map (so the vendored-Lit bare specifiers resolve). `css``
is DOM-free, so the shim is tiny and no browser is needed — it runs in the offline
gate. Any module that throws while loading fails it.

## Full offline gate list
`frontend-syntax`, `frontend-imports`, `frontend-eval`, `backend-imports`,
`python-unit` (web-platform) · `homefree-python-unit`, `nix-eval` (5 configs),
`loader-mapping`, `app-config-snapshot`, `app-prestart-snapshot`,
`caddy-config-snapshot` (homefree). Plus the `vm-admin-boot` KVM smoke
(`nix build .#packages.x86_64-linux.vm-admin-boot`, needs KVM, outside flake check).
