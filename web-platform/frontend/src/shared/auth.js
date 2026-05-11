/**
 * SSO sign-out helper.
 *
 * oauth2-proxy serves /oauth2/sign_out on its own host (auth.<domain>),
 * NOT on the per-app subdomain. Caddy on admin.<domain> sends every
 * path including /oauth2/* through forward_auth, which 302s an
 * unauthenticated /oauth2/sign_out request back to /oauth2/start —
 * which then immediately re-authenticates and the user appears to
 * not have signed out at all.
 *
 * The correct target is auth.<domain>/oauth2/sign_out with an
 * optional `rd` (return destination) query param so the user lands
 * somewhere sensible after the cookie is cleared.
 *
 * Derives the auth host from the current hostname:
 *   admin.example.com  -> auth.example.com
 *   admin.foo.bar.com  -> auth.foo.bar.com
 *
 * Falls back to /oauth2/sign_out (current host) if the hostname
 * doesn't have a leading subdomain — that's almost never the right
 * answer, but it'll at least make a request that someone can debug.
 */
export function ssoSignOutUrl(returnTo) {
  const host = window.location.hostname;
  const parts = host.split('.');
  let authHost;
  if (parts.length >= 2) {
    // Drop the first label, prepend "auth".
    authHost = ['auth', ...parts.slice(1)].join('.');
  } else {
    authHost = host;
  }
  const rd = returnTo || window.location.origin + '/';
  return `https://${authHost}/oauth2/sign_out?rd=${encodeURIComponent(rd)}`;
}
