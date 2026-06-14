# NetBird remote-access auto-provisioning (REST, no wizard)

`apps/netbird/default.nix` auto-provisions "Remote Network Access" so the
operator never touches NetBird's dashboard onboarding wizard. The
non-obvious, repeatable gotchas behind that design:

## `/api/setup` is unusable here — it needs NetBird's *embedded* IDP

NetBird's only **non-interactive** owner+PAT bootstrap, `POST /api/setup`
(gated by `NB_SETUP_PAT_ENABLED`), returns `500 "embedded IDP is not
enabled"` when the management server is configured against an **external**
IDP. HomeFree uses Zitadel as an external IDP and is SSO-only (no local
accounts), so `/api/setup` is off the table. Don't reach for it.

## The account is created lazily on first SSO login — so we FABRICATE it

With an external IDP there is **no account row until a user authenticates once**,
and **no token we can mint headlessly is accepted** (a machine-user JWT's `aud`
is the machine user / project id, never the netbird client_id NetBird checks —
verified; the accepted-audience list isn't config-extensible either). To stay
fully headless (no SSO login, no wizard), `netbird-provision` step 2 **fabricates
the account directly in `store.db`** when none exists, mirroring NetBird's
`newAccountWithId`:

- **5 tables only**: `accounts` (ONE wide row — all settings are columns, no
  separate settings/dns tables), `users` (owner), `groups` (`All`), `policies`
  + `policy_rules` (default All→All), `account_onboardings`. (`domains` unused.)
- **Named-column INSERTs, never positional** — the `accounts` column order
  differs across NetBird versions (`network_net_v6` moved to position 9 in a
  fresh 0.72.4 DB vs the end in an older migrated one); a positional insert
  silently misaligns (`Scan error … network_serial`, "warmed up … 0 accounts").
- **Owner = the admin's Zitadel user id** (zitadel-provision writes it to
  `${secretsDir}/owner-user-id`), so the admin is owner on first login (matched
  by `sub`). No fabrication runs until that file exists.
- **Blank `name`/`email` are safe**: `User.{Encrypt,Decrypt}SensitiveData`
  short-circuit on `""` (no field-encryption to replicate); the IdP cache fills
  them from Zitadel on login.
- **`account_onboardings.onboarding_flow_pending = 0`** ⇒ the dashboard never
  shows the onboarding wizard, independent of the network objects.
- After the INSERTs, **restart `podman-netbird-management`** (it cached "no
  account" at startup) and re-probe readiness before continuing.
- The SQL lives in a Nix `''` block, so SQL empty-string literals are emitted as
  `'$Q'` (Q="") — two adjacent single-quotes would end the Nix string.

Runs from a TIMER (`netbird-provision.timer`, not `wantedBy multi-user.target`)
so `nixos-rebuild` never blocks/fails on it; exits 0 on any not-ready condition
and retries. A `.netbird-provisioned` sentinel in `/var/lib/netbird` (next to
`store.db`, so a DB wipe re-provisions) + `ConditionPathExists` makes it a no-op
once done. The version-coupling (account schema) must be re-verified on every
NetBird image bump — same posture as the PAT/REST coupling below.

## REST credential = a SQL-inserted PAT, reproducing NetBird's token exactly

The REST API takes `Authorization: Token <pat>` or a JWT whose `aud` is the
netbird client_id (unobtainable for a machine user). So we mint a PAT the one
way that works with an external IDP: insert a `personal_access_tokens` row for
the owner. The token must be byte-exact because **the CRC32 checksum is
verified on use** (`extractPATFromToken` in `management/server/auth/manager.go`):

- `nbp_` + 30 random base62 chars (secret) + 6-char checksum, **total len 40**.
- checksum = `base62(crc32.ChecksumIEEE(secret))` left-padded to 6 with `0`,
  using NetBird's own alphabet `0-9A-Za-z` (`github.com/netbirdio/netbird/base62`).
- stored `hashed_token` = `base64.StdEncoding(sha256(full-token))`.
- lookup is a **direct DB transaction** (`GetPATByHashedToken`), so a
  SQL-inserted PAT works **with no management restart**.

The shell does crc32 via gzip's trailer (`gzip -c | tail -c8 | head -c4`).

## REST writes are live immediately (no cache restart)

Unlike the old SQL-surgery approach (which `INSERT`ed into `routes` /
`name_server_groups` and then had to `systemctl restart
podman-netbird-management` to reload the in-memory cache), REST writes
(`/api/networks`, `.../resources`, `.../routers`, `/api/policies`,
`/api/setup-keys`, `/api/dns/nameservers`) take effect at once.

## Objects provisioned (mirrors the wizard's new "Networks" model)

Group `Routing Peers`; reusable setup-key `homefree-router`
(`auto_groups`→Routing Peers, `expires_in` max 31536000 = 1y); network
`HomeFree LAN`; subnet resource (`address` = LAN CIDR — `type` is
auto-derived: a `/24` → `subnet`); router with `peer_groups`→Routing Peers
(the box auto-joins that group via the setup-key, so no peer-id lookup);
policy `HomeFree LAN access` (source `All` group → `destinationResource`
{id,type}); LAN nameserver group. The legacy `POST /api/routes` table is
*not* used — the dashboard wizard checks the Networks model, so writing only
legacy routes left the wizard nagging.

## Version coupling

The PAT format and REST schema are pinned to the NetBird image version
(`managementTag` etc., kept in lockstep). On a version bump, re-verify the
token format and the REST payloads against the new image (see the live-box
recon in the commit that introduced this).

## Reset / restore

Wipe `/var/lib/netbird` (+ `/var/lib/netbird-signal`) to reset — the sentinel
goes with it and provisioning re-runs. Self-healing: a stale on-disk PAT /
setup-key under `/var/lib/homefree-secrets/netbird` (not wiped with the DB) is
detected (PAT re-validated, setup-key re-minted) and pre-existing REST objects
are reused. Anchoring is intentionally skipped — the generate→anchor model
does not fit these DB-coordinated secrets ([[secrets-anchoring]]).
