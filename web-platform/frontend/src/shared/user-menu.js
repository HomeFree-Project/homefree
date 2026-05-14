import { html, css } from 'lit';
import { handleSignOut } from './auth.js';

// Shared user-menu used by admin-app and user-app. A small popover
// triggered by the avatar circle in the top-right corner of every
// authenticated surface.
//
// Usage:
//   1. Add a `userMenuOpen` boolean state property to the host
//      component, defaulting to false.
//   2. Spread userMenuStyles into the host's `static styles` array.
//   3. Inside render(), call:
//        renderUserMenu({
//          currentUser: this.currentUser,
//          open: this.userMenuOpen,
//          onToggle: () => this.toggleUserMenu(),
//          profileUrl: 'https://home.<domain>/#/profile',  // optional
//        })
//
// Profile link points at the per-user dashboard's profile page.
// Same target on every surface so admin's "Profile" lands at the
// same place home's "Profile" does — single source of truth for
// per-user settings.

export const userMenuStyles = css`
  .user-menu-wrap {
    position: relative;
  }
  .user-menu-trigger {
    width: 36px;
    height: 36px;
    border-radius: 50%;
    border: 1px solid var(--hf-border-2);
    background: var(--hf-surface);
    color: var(--hf-text);
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    transition: background 0.15s, border-color 0.15s;
  }
  .user-menu-trigger:hover,
  .user-menu-trigger.open {
    background: var(--hf-surface-2);
    border-color: var(--hf-accent);
  }
  .user-menu-popover {
    position: absolute;
    top: calc(100% + 6px);
    right: 0;
    min-width: 200px;
    background: var(--hf-surface);
    border: 1px solid var(--hf-border-2);
    border-radius: 8px;
    box-shadow: var(--hf-shadow-lg);
    z-index: 100;
    overflow: hidden;
  }
  .user-menu-header {
    padding: 12px 14px;
    border-bottom: 1px solid var(--hf-border);
    font-size: 13px;
  }
  .user-menu-header .user-name {
    color: var(--hf-text);
    font-weight: 500;
  }
  .user-menu-header .user-role {
    color: var(--hf-text-muted);
    font-size: 11px;
    margin-top: 2px;
  }
  .user-menu-item {
    display: block;
    padding: 10px 14px;
    color: var(--hf-text);
    text-decoration: none;
    font-size: 14px;
    background: none;
    border: none;
    width: 100%;
    text-align: left;
    cursor: pointer;
    font-family: inherit;
  }
  .user-menu-item:hover {
    background: var(--hf-surface-2);
  }
  .user-menu-sep {
    height: 1px;
    background: var(--hf-border);
    margin: 4px 0;
  }
  /* Items marked mobileOnly only appear when the inline topbar nav
     has been collapsed — i.e. on small viewports. Matching breakpoint
     (720px) lives in each calling component's topbar styles. */
  @media (min-width: 721px) {
    .user-menu-item.mobile-only { display: none; }
    /* Hide the separator on desktop too if every preceding item is
       mobile-only — otherwise we'd leave a floating divider above
       Profile/Sign-out. CSS can't condition on "all previous siblings
       hidden", so just hide the separator when its *immediately
       preceding* sibling is mobile-only. This works because the
       calling code groups all extraItems together and separators
       follow immediately. */
    .user-menu-item.mobile-only + .user-menu-sep { display: none; }
  }
`;

// `extraItems` is an array of { label, href, target?, mobileOnly? }.
// They render above the standard "Profile & password" / "Sign out"
// entries inside the popover. `mobileOnly: true` hides the item at
// viewports wider than the mobile breakpoint (matches the same
// breakpoint as the inline topbar nav on the calling page) — used
// to collapse top-bar nav into the user-menu on small screens
// without duplicating links on desktop.
export function renderUserMenu({
  currentUser,
  open,
  onToggle,
  profileUrl,
  extraItems = [],
}) {
  const u = currentUser || {};
  const username = u.username || '';
  const initial = username ? username[0].toUpperCase() : '?';
  // is_admin_role beats is_admin_user — the former reflects the
  // active Zitadel project role (what actually gates admin UI
  // access), the latter is the legacy "this is the OS admin user"
  // marker. Either signal qualifies for the "HomeFree admin" label.
  const isAdmin = !!(u.is_admin_role || u.is_admin_user);
  const role = isAdmin ? 'HomeFree admin' : 'Signed in';

  return html`
    <div class="user-menu-wrap">
      <button
        class="user-menu-trigger ${open ? 'open' : ''}"
        @click=${onToggle}
        title=${username ? `Signed in as ${username}` : 'Account menu'}
        aria-haspopup="true"
        aria-expanded=${open}
      >${initial}</button>

      ${open ? html`
        <div class="user-menu-popover">
          <div class="user-menu-header">
            <div class="user-name">${username || 'Account'}</div>
            <div class="user-role">${role}</div>
          </div>
          ${extraItems.map(it => html`
            <a class="user-menu-item ${it.mobileOnly ? 'mobile-only' : ''}"
               href="${it.href}"
               target="${it.target || '_self'}"
               rel="${it.target === '_blank' ? 'noopener' : ''}">
              ${it.label}
            </a>
          `)}
          ${extraItems.length > 0 ? html`<div class="user-menu-sep"></div>` : ''}
          ${profileUrl ? html`
            <a class="user-menu-item" href="${profileUrl}">
              Profile &amp; password
            </a>
          ` : ''}
          <a class="user-menu-item" href="#" @click=${handleSignOut}>
            Sign out
          </a>
        </div>
      ` : ''}
    </div>
  `;
}

// Helper that computes the canonical profile URL for the current
// box. On admin.<domain> it points at home.<domain>/#/profile;
// on home.<domain> it's just /#/profile (same origin).
//
// Strips a single leading admin./home./manual. prefix from the
// current hostname to get the apex domain, then prefixes "home."
// onto it. Falls back to "/#/profile" if the hostname doesn't
// start with a recognised surface prefix (dev / unknown).
export function profileUrlForCurrentBox() {
  const host = window.location.hostname;
  const stripped = host.replace(/^(admin|home|manual)\./, '');
  if (stripped === host) {
    // Not on a recognised surface — best we can do is a relative
    // hash. If we're on home.* it's already same-origin; for
    // anything else the link will be broken but visible.
    return '/#/profile';
  }
  return `${window.location.protocol}//home.${stripped}/#/profile`;
}
