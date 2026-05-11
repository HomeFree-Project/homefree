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
 *   2. sso.<domain>/oidc/v1/end_session?post_logout_redirect_uri=...
 *      → Zitadel ends the SSO session, then redirects to the
 *        post-logout URI.
 *   3. Final landing: oauth2-proxy's /sign_out_landing on auth.<domain>
 *      shows a static "you have been signed out" page that does NOT
 *      itself require auth (so we don't bounce back into the SSO
 *      flow).
 *
 * If we can't construct the full chain (e.g., we don't know Zitadel's
 * host), fall back to plain oauth2-proxy sign_out — broken but at
 * least clears the local cookie.
 */
export function ssoSignOutUrl(returnTo) {
  const host = window.location.hostname;
  const parts = host.split('.');
  if (parts.length < 2) {
    // Single-label host: nothing sensible to derive.
    return `/oauth2/sign_out`;
  }
  const rest = parts.slice(1).join('.');
  const authHost = `auth.${rest}`;
  const ssoHost = `sso.${rest}`;

  // Where to land after BOTH sessions are killed. We want a page
  // that doesn't require auth (otherwise we bounce right back in).
  // The simplest such page is auth.<domain>/ — oauth2-proxy serves
  // a tiny "Sign in" landing there with no auth required.
  const postLogout = returnTo || `https://${authHost}/`;

  const endSession =
    `https://${ssoHost}/oidc/v1/end_session` +
    `?post_logout_redirect_uri=${encodeURIComponent(postLogout)}`;

  return `https://${authHost}/oauth2/sign_out` +
         `?rd=${encodeURIComponent(endSession)}`;
}
