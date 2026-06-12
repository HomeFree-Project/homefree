---
name: forgejo-backlog
description: Read, triage, and update the HomeFree backlog (issues) on the self-hosted Forgejo at git.homefree.host, repo homefree/homefree. Use when the user asks to list, search, view, create, label, comment on, or close issues — or to "file", "groom", or "move something into" the backlog.
---

# HomeFree backlog on Forgejo

The HomeFree backlog lives in the self-hosted Forgejo instance at
**git.homefree.host**, repo **`homefree/homefree`** (Forgejo 15.0.3,
Gitea-1.22-compatible REST API). Drive it with the bundled helper
`forgejo.sh`, which wraps the issue endpoints.

## Auth

- **Reading** (`list`, `get`, `labels`) works with **no token** — the repo is
  public.
- **Writing** (`create`, `update`, `comment`) needs a Forgejo **Personal
  Access Token** with scopes `read:issue` + `write:issue`. Provide it via
  either:
  - `export FORGEJO_TOKEN=…`, or
  - `~/.config/homefree/forgejo-token` (single line, `chmod 600`).

  Mint one in the Forgejo UI → *Settings → Applications → Generate New Token*
  (select the two issue scopes), or via the box's admin path
  (`podman exec forgejo …`) per the plugin-PR workflow. The helper sends the
  token only as an `Authorization` header through a curl stdin-config, so it
  never appears in `ps`/argv/shell history. **Never** print, log, echo, or
  commit the token.

## Commands

Run from anywhere; path is `.claude/skills/forgejo-backlog/forgejo.sh`.

```
forgejo.sh labels
forgejo.sh list   [--state open|closed|all] [--labels A,B] [--q TEXT] [--limit N]
forgejo.sh get    N
forgejo.sh create --title T (--body B | --body-file F) [--labels "A,B"] [--milestone M]
forgejo.sh update N [--state open|closed] [--title T] [--body B] [--add-labels "A,B"]
forgejo.sh comment N (--body B | --body-file F)
```

`--labels`/`--add-labels` take label **names** (the helper resolves them to
IDs); pass long bodies with `--body-file` to avoid shell-quoting pain.

## Label taxonomy

Issues are organized by families — pick one+ from each relevant family:

- `Component/*` — Adblock, Apps, Auth, Backup, DHCP, DNS, Decentralization,
  Deployment, Firewall, GUI, IPS-IDP, Proxy, Reporting-Monitoring, Secrets,
  VPN
- `Kind/*` — Bug, Documentation, Enhancement, Feature, Future,
  Infrastructure, Investigation, Security, Testing
- `Priority/*` — Critical, High, Medium, Low
- `Compat/Breaking` — changes a config/output format or on-disk shape
- `Reviewed/*` — Confirmed, Duplicate, Invalid, Won't Fix
- `Status/*` — Abandoned, Blocked, Need More Info

Run `forgejo.sh labels` for the live list.

## Convention for agent-actionable work

An issue is a candidate for semi-automated work when its body is a
self-contained spec. The intended loop: pick such an issue, branch,
implement, and open a PR via the repo's jj-push + scoped-token flow (AGit is
disabled on this Forgejo, so push a branch and open the PR with a scoped
token, then revoke it). Keep `homefree`'s rules in force — notably never
commit/rebuild without an explicit ask, and regenerate snapshot goldens in
the same change.
