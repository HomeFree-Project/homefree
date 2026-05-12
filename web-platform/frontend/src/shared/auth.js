/**
 * SSO sign-out.
 *
 * The naive approach — just hitting oauth2-proxy's /oauth2/sign_out
 * with rd=admin/ — clears oauth2-proxy's cookie but leaves Zitadel's
 * SSO session intact. The browser is then redirected back to admin/,
 * which has no oauth2-proxy cookie, so Caddy 302s to oauth2/start,
 * which 302s to Zitadel /authorize, which sees the still-valid SSO
 * session and silently signs the user right back in. Net effect: the
 * user appears to have NOT signed out.
 *
 * Worse, when the browser arrives back at admin/ in this state, any
 * cached page resources (HTML, JS module scripts) may load partially
 * while ancillary fetches get cross-origin-redirected to auth/, which
 * the browser refuses with CORS errors — you get a half-mounted page
 * stuck on the loading spinner.
 *
 * The proper flow is OIDC RP-Initiated Logout: hit Zitadel's
 * end_session endpoint, which terminates the Zitadel session AND
 * redirects to a post-logout URI we control. We chain:
 *
 *   1. auth.<domain>/oauth2/sign_out?rd=<zitadel-end_session-url>
 *      → oauth2-proxy clears its cookie, then redirects to Zitadel's
 *        end_session.
 *   2. sso.<domain>/oidc/v1/end_session?client_id=...&post_logout_redirect_uri=...
 *      → Zitadel ends the SSO session, then redirects to the
 *        post-logout URI.
 *   3. Final landing: the root domain landing page (no SSO gate).
 *
 * The `client_id` query param on end_session is CRITICAL: without it
 * (and without an `id_token_hint`, which oauth2-proxy discards before
 * forwarding) Zitadel cannot validate the post_logout_redirect_uri
 * against any registered app — and falls back to showing its own
 * "Logout successful" page with no further redirect, stranding the
 * user with no way back. We fetch the oauth2-proxy app's client_id
 * via /api/sso/oauth2-client-id and embed it on the end_session URL.
 *
 * If we can't construct the full chain (no API access, no derivable
 * host), fall back to plain oauth2-proxy sign_out — broken but at
 * least clears the local cookie.
 */
export async function ssoSignOutUrl(returnTo) {
  const host = window.location.hostname;
  const parts = host.split('.');
  if (parts.length < 2) {
    // Single-label host: nothing sensible to derive.
    return `/oauth2/sign_out`;
  }
  const rest = parts.slice(1).join('.');
  const authHost = `auth.${rest}`;
  const ssoHost = `sso.${rest}`;

  // Where to land after BOTH sessions are killed. Default: back to
  // the same site the user signed out FROM (admin.<domain>/,
  // ha.<domain>/, etc.). Once they arrive there with no cookie,
  // Caddy's forward_auth bounces them into auth.<domain>/oauth2/start,
  // which forwards to Zitadel's /authorize — and since we just
  // ended the Zitadel session, Zitadel renders its actual SSO login
  // form rather than silently re-issuing a token. The user sees a
  // proper "sign in to continue" page, which is the right UX.
  //
  // This is correct now because the chain INCLUDES end_session with
  // a registered client_id (see below) — without that, Zitadel would
  // ignore the post_logout_redirect_uri and we'd be stuck. Earlier
  // versions of this code lacked that and so had to land somewhere
  // that didn't require auth at all (e.g. the root landing page),
  // because the user's Zitadel session might still be live and an
  // auth-gated landing would silently sign them right back in.
  const postLogout = returnTo || `https://${host}/`;

  // Fetch the oauth2-proxy app's OIDC client_id. Required for
  // Zitadel to honor post_logout_redirect_uri — see the comment in
  // the function docstring.
  let clientId = '';
  try {
    const r = await fetch('/api/sso/oauth2-client-id', {
      credentials: 'same-origin',
      cache: 'no-store',
    });
    if (r.ok) {
      const body = await r.json();
      clientId = body.client_id || '';
    }
  } catch (e) {
    // Fall through with empty clientId — the chain still attempts
    // logout, just lands on Zitadel's default page.
  }

  const params = new URLSearchParams();
  params.set('post_logout_redirect_uri', postLogout);
  if (clientId) params.set('client_id', clientId);
  const endSession =
    `https://${ssoHost}/oidc/v1/end_session?${params.toString()}`;

  return `https://${authHost}/oauth2/sign_out` +
         `?rd=${encodeURIComponent(endSession)}`;
}

/**
 * Click handler for "Sign out" links/buttons. Awaits the async
 * URL construction (which fetches client_id) then navigates.
 *
 * Use as: @click=${handleSignOut} on an <a> or <button>.
 */
export async function handleSignOut(event) {
  if (event) event.preventDefault();
  const url = await ssoSignOutUrl();
  window.location.href = url;
}
