import { html, css } from 'lit';
import { navIcon } from './icons.js';

// Shared surface switcher used by admin-app and user-app. It lives in
// the top bar (in .top-bar-actions, before the user-menu avatar) and
// carries the cross-SURFACE links — the navigations that LEAVE the
// current app for a sibling subdomain:
//
//   Admin surface  ->  Home, Manual
//   Home surface   ->  Admin (admin role only), Manual
//
// This is deliberately separate from the left nav (which is in-site
// only) and from the account/avatar menu — the canonical app-switcher
// pattern, so "leaves this surface" is signalled by placement, not by a
// subtle arrow buried in the nav rail.
//
// Manual opens in a new tab (the manual site has no nav back here), so
// it keeps a trailing ↗. Home/Admin are same-tab surface switches and
// get no arrow — the ↗ means exactly "opens a new tab".
//
// Responsive: destinations render as inline link buttons on a wide top
// bar, and on mobile too when there are two or fewer (they fit). Only
// when space is tight (mobile, the host's <=768px isMobile flag) AND
// there are three or more do they fold into a single switcher icon that
// opens a "Switch to" popover. In practice there are at most two today
// (a sibling surface + Manual), so the fold is headroom for later.
//
// Usage from a host LitElement:
//   1. Spread surfaceSwitcherStyles into static styles.
//   2. Add a `switcherOpen` boolean state, a toggleSwitcher() that flips
//      it and wires an outside-click close (mirror toggleUserMenu()).
//   3. In .top-bar-actions, before the user-menu, call:
//        renderSurfaceSwitcher({
//          currentSurface: 'admin' | 'home',
//          isAdmin: <bool>,
//          isMobile: this.isMobile,
//          open: this.switcherOpen,
//          onToggle: () => this.toggleSwitcher(),
//        })

export const surfaceSwitcherStyles = css`
  .surface-switcher-wrap {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 8px;
  }

  /* Inline link button (wide top bar) — a text link, no border or
     background. Muted by default, brightens on hover. */
  .surface-link {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 8px;
    border: none;
    background: none;
    color: var(--hf-text-muted);
    font-size: 13px;
    font-weight: 500;
    font-family: inherit;
    text-decoration: none;
    cursor: pointer;
    white-space: nowrap;
    transition: color 0.15s;
  }
  .surface-link:hover {
    color: var(--hf-text);
  }
  .surface-link .surface-ico {
    display: inline-flex;
    width: 16px;
    height: 16px;
  }
  .surface-link .surface-ico svg {
    width: 16px;
    height: 16px;
    display: block;
  }
  .surface-link .surface-arrow {
    font-size: 12px;
    opacity: 0.6;
  }

  /* Folded trigger (narrow top bar). Reuses the .icon-action look,
     sized to 36px to align with the avatar circle beside it. */
  .surface-switcher-trigger {
    width: 36px;
    height: 36px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 8px;
    border: 1px solid var(--hf-border-2);
    background: var(--hf-surface);
    color: var(--hf-text);
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }
  .surface-switcher-trigger:hover,
  .surface-switcher-trigger.open {
    background: var(--hf-surface-2);
    border-color: var(--hf-accent);
  }
  .surface-switcher-trigger svg {
    width: 18px;
    height: 18px;
    display: block;
  }

  /* Popover (narrow). Mirrors user-menu-popover. */
  .surface-switcher-popover {
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
  .surface-switcher-header {
    padding: 12px 14px;
    border-bottom: 1px solid var(--hf-border);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--hf-text-subtle);
  }
  .surface-switcher-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    color: var(--hf-text);
    text-decoration: none;
    font-size: 14px;
    cursor: pointer;
  }
  .surface-switcher-item:hover {
    background: var(--hf-surface-2);
  }
  .surface-switcher-item .surface-ico {
    display: inline-flex;
    width: 18px;
    height: 18px;
    flex-shrink: 0;
  }
  .surface-switcher-item .surface-ico svg {
    width: 18px;
    height: 18px;
    display: block;
  }
  .surface-switcher-item .surface-arrow {
    margin-left: auto;
    font-size: 13px;
    opacity: 0.55;
  }
`;

// Strip a single leading surface prefix to get the apex domain, then
// re-prefix for the requested surface. Matches the regex previously
// duplicated in admin-app / user-app / user-menu. `kind` is one of
// 'home' | 'admin' | 'manual'.
export function surfaceUrl(kind) {
  const apex = window.location.hostname.replace(/^(admin|home|manual)\./, '');
  return `${window.location.protocol}//${kind}.${apex}/`;
}

// Destinations that LEAVE the current surface, in display order.
function destinations(currentSurface, isAdmin) {
  const list = [];
  if (currentSurface !== 'home') {
    list.push({ id: 'home', label: 'Home', icon: 'home', url: surfaceUrl('home'), newTab: false });
  }
  if (currentSurface !== 'admin' && isAdmin) {
    list.push({ id: 'admin', label: 'Admin', icon: 'admin', url: surfaceUrl('admin'), newTab: false });
  }
  // Manual always available; opens in a new tab.
  list.push({ id: 'manual', label: 'Manual', icon: 'manual', url: surfaceUrl('manual'), newTab: true });
  return list;
}

function inlineLink(d) {
  return html`
    <a
      class="surface-link"
      href="${d.url}"
      target=${d.newTab ? '_blank' : ''}
      rel=${d.newTab ? 'noopener' : ''}
    >
      <span class="surface-ico">${navIcon(d.icon)}</span>
      <span>${d.label}</span>
      ${d.newTab ? html`<span class="surface-arrow">↗</span>` : ''}
    </a>
  `;
}

function popoverItem(d) {
  return html`
    <a
      class="surface-switcher-item"
      href="${d.url}"
      target=${d.newTab ? '_blank' : ''}
      rel=${d.newTab ? 'noopener' : ''}
    >
      <span class="surface-ico">${navIcon(d.icon)}</span>
      <span>${d.label}</span>
      ${d.newTab ? html`<span class="surface-arrow">↗</span>` : ''}
    </a>
  `;
}

export function renderSurfaceSwitcher({ currentSurface, isAdmin, isMobile, open, onToggle }) {
  const dests = destinations(currentSurface, isAdmin);
  if (dests.length === 0) return '';

  // Inline link buttons on a wide top bar, and on mobile when there are
  // two or fewer destinations (they fit, and a one/two-item popover
  // would be pointless). Only fold when space is tight AND there's a
  // real list to manage.
  if (!isMobile || dests.length <= 2) {
    return html`
      <div class="surface-switcher-wrap">
        ${dests.map(inlineLink)}
      </div>
    `;
  }

  // Mobile with 3+ destinations: fold into a switcher icon.
  return html`
    <div class="surface-switcher-wrap">
      <button
        class="surface-switcher-trigger ${open ? 'open' : ''}"
        @click=${onToggle}
        title="Switch to another HomeFree area"
        aria-label="Switch to another HomeFree area"
        aria-haspopup="true"
        aria-expanded=${open}
      >${navIcon('switch')}</button>

      ${open ? html`
        <div class="surface-switcher-popover">
          <div class="surface-switcher-header">Switch to</div>
          ${dests.map(popoverItem)}
        </div>
      ` : ''}
    </div>
  `;
}
