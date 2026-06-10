# oauth2-proxy readiness gate must probe Zitadel discovery, not just secrets

## The trap

oauth2-proxy runs blue/green (`lib/blue-green.nix`), so the flip and the
active-colour supervisor only start a colour when the descriptor's
`readinessGate` passes. The gate used to be *secrets-exist only*
(`oauth2ProxySecretsCheck` — the three OIDC secret files). On any box
past first-install those secrets are already present, so the gate passed
**instantly**.

But a colour starting is not the same as Zitadel being able to serve it.
On a steady-state rebuild Zitadel's container restarts; until it finishes
initialising, Caddy answers its `https://sso.<domain>` vhost with a
**502**. oauth2-proxy performs OIDC discovery at startup
(`/.well-known/openid-configuration`, a loopback self-call —
`--network=host` + `--add-host sso:127.0.0.1`) and **exits 1 on that
502**. With `Restart=on-failure` (`StartLimitBurst=5` / `1 min`,
`RestartSec=10s`) five fast exits trip `start-limit-hit`, leaving a
FAILED unit — which makes `switch-to-configuration` exit non-zero and
fails the whole rebuild.

Symptom: `podman-oauth2-proxy-blue.service ... Result: start-limit-hit`
during a rebuild, with `[main.go:59] ERROR: Failed to initialise OAuth2
Proxy: ... error while discovery OIDC configuration: ... unexpected
status "502"` in the journal a few seconds earlier. It **self-heals** —
the supervisor polls every 3 s and starts the colour cleanly once Zitadel
converges — so by the time you look, the colour is `active` and serving;
only the rebuild failed.

## The fix

The `readinessGate` (`apps/zitadel/default.nix`,
`oauth2ProxyReadinessGate`) must be strictly broader than the colour's
ExecStartPre secrets check: it ALSO probes that Zitadel actually answers
OIDC discovery (HTTP 200), using the same loopback-pinned, skip-verify
self-call oauth2-proxy makes:

```
curl -fsk --max-time 3 --resolve sso.<domain>:443:127.0.0.1 \
  https://sso.<domain>/.well-known/openid-configuration
```

Because both the flip (`lib/blue-green.nix`, steady-state path) and the
supervisor treat a false gate as **"defer, current colour keeps
serving"** — not a failure — a 502 now defers cleanly and the colour
comes up the instant Zitadel is ready. No `start-limit`, no failed
rebuild.

Keep the gate (flip/supervisor "should I start?") and the colour's
ExecStartPre (the unit's own hard precondition) separate: ExecStartPre
stays the cheap local secrets check — a curl there would *fail the unit*
on a 502 instead of deferring, which is the bug, not the fix.

## Residual window

If Zitadel passes the gate and *then* 502s in the sub-second before
oauth2-proxy dials, the old fast-fail path can still trigger. The window
is tiny. If it ever bites, the next lever is restart-budget tolerance on
the colour unit (`StartLimitBurst`/`RestartSec`) — a symptom-level knob,
deliberately left untouched.
