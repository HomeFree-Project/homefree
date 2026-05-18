# Container reverse-proxy (header) authentication

When a containerized app authenticates by trusting an identity **header**
injected by Caddy (e.g. Navidrome's externalized auth, AdGuard-style
header injection) and gates that trust with a **source-IP whitelist**,
the whitelist must be the host's `lan-address` — **not** the podman
subnet.

## Why

Caddy's reverse-proxy upstream for a HomeFree service is
`http://<lan-address>:<port>` (`config.homefree.network.lan-address`).
The app's container publishes its port with `-p 0.0.0.0:<port>:<port>`.

The source IP the container sees depends on how the host reaches it:

| Caddy connects to        | Source IP inside the container |
| ------------------------ | ------------------------------ |
| `<lan-address>:<port>`   | `<lan-address>`  ← this is the real case |
| `127.0.0.1:<port>`       | `10.88.0.1` (podman bridge gateway) |
| container-to-container   | `10.88.0.0/16` (the other container's IP) |

Because Caddy uses the **lan-address** upstream, the app sees the
request sourced from `<lan-address>`. A whitelist of `10.88.0.0/16`
silently fails to match — the app then ignores the auth header and
falls back to its own native login form. Every other layer (the Caddy
oauth2-proxy gate, `copy_headers`, the app's header parsing) works
fine; only the whitelist IP is wrong, which makes this hard to spot.

## What to do

Set the app's source-IP whitelist to the lan-address:

```nix
# in the app's container `environment`
ND_REVERSEPROXYWHITELIST = "${config.homefree.network.lan-address}/32";
```

(Variable name varies per app — Navidrome uses `ND_REVERSEPROXYWHITELIST`
/ `ND_REVERSEPROXYUSERHEADER`.)

The header Caddy's oauth2-proxy gate injects after a valid session is
`X-Auth-Request-Preferred-Username` (see the `copy_headers` list in
`services/caddy/default.nix`). Point the app's user-header option at
that.

## How to verify the source IP empirically

Run a throwaway probe container that publishes a port and logs the peer
address, then connect to it the way Caddy would:

```bash
sudo podman run -d --rm --name srcprobe -p 0.0.0.0:9999:9999 \
  docker.io/python:3-alpine python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('0.0.0.0',9999)); s.listen(5)
while True:
    c,a=s.accept(); print('PEER',a[0],flush=True); c.close()"
curl -s -o /dev/null --max-time 2 http://<lan-address>:9999/
sudo podman logs srcprobe   # -> PEER <lan-address>
sudo podman rm -f srcprobe
```

## Related

- Native-client / API traffic that cannot complete an interactive
  OAuth login bypasses the SSO gate via the generic per-service
  `reverse-proxy.sso-bypass-paths` option — the service declares the
  path globs (e.g. Navidrome sets `[ "/rest/*" ]` for the Subsonic
  API). The base distribution stays app-agnostic.
- `docs/agent-notes/caddy-directive-ordering.md` — why the gate itself
  must be a top-level directive.
