import { css } from 'lit';

// Shared app-shell CSS used by admin-app and user-app. The shell is:
//
//   ┌───────────────────────────────────────┐
//   │ topbar:  ☰  Page Title       avatar │
//   ├──────────┬────────────────────────────┤
//   │ sidebar  │                            │
//   │  -Item   │   content                  │
//   │  -Item   │                            │
//   │  -Item   │                            │
//   └──────────┴────────────────────────────┘
//
// Sidebar holds intra-site navigation (admin: modules / home: pages).
// Topbar holds the current page title on the left and the user-menu
// on the right. The user-menu carries cross-SITE links — Admin,
// Manual — plus Profile & password and Sign out.
//
// Usage from a host LitElement:
//   1. Include shellStyles in static styles (plus themeVars,
//      userMenuStyles).
//   2. Wire `sidebarCollapsed` + `isMobile` state, a matchMedia
//      listener at 768px (see admin-app for the canonical setup),
//      a toggleSidebar() that flips collapsed.
//   3. Render the shell with this markup pattern:
//        <div class="app-container">
//          <div class="sidebar ${this.sidebarCollapsed ? 'collapsed' : ''}">
//            <div class="sidebar-header">
//              <h1>HomeFree</h1>
//              <button class="collapse-btn" @click=...>←</button>
//            </div>
//            <nav class="nav-menu">
//              <div class="nav-section-title">Section</div>
//              <div class="nav-item active">
//                <span class="nav-item-icon">⚙</span>
//                <span class="nav-item-text">Label</span>
//              </div>
//              ...
//            </nav>
//          </div>
//          <div class="sidebar-backdrop" @click=...></div>
//          <div class="main-content">
//            <div class="top-bar">
//              <div class="top-bar-title">
//                <button class="hamburger-btn" @click=...>☰</button>
//                <h2>Page Title</h2>
//              </div>
//              <div class="top-bar-actions">${renderUserMenu(...)}</div>
//            </div>
//            <div class="content-area">${...}</div>
//          </div>
//        </div>
//
// Sized + colored from theme.js — every var must already be in
// scope on the host (the themeVars import handles that).
export const shellStyles = css`
  .app-container {
    display: flex;
    height: 100%;
  }

  /* Sidebar */
  .sidebar {
    width: 260px;
    background: var(--hf-surface);
    border-right: 1px solid var(--hf-border);
    color: var(--hf-text);
    display: flex;
    flex-direction: column;
    transition: width 0.3s ease;
    overflow-x: hidden;
    flex-shrink: 0;
  }
  .sidebar.collapsed {
    width: 70px;
  }
  .sidebar-header {
    height: 64px;
    padding: 0 20px;
    border-bottom: 1px solid var(--hf-border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-shrink: 0;
  }
  .sidebar.collapsed .sidebar-header h1 {
    display: none;
  }
  .sidebar-header h1 {
    margin: 0;
    font-size: 20px;
    font-weight: 600;
    white-space: nowrap;
    color: var(--hf-text);
    letter-spacing: -0.01em;
  }
  .collapse-btn {
    background: var(--hf-surface-2);
    border: 1px solid var(--hf-border);
    color: var(--hf-text-muted);
    width: 32px;
    height: 32px;
    border-radius: 6px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
  }
  .collapse-btn:hover {
    background: var(--hf-surface-3);
    color: var(--hf-text);
  }
  .nav-menu {
    flex: 1;
    padding: 16px 0;
    overflow-y: auto;
  }
  .nav-item {
    display: flex;
    align-items: center;
    padding: 10px 20px;
    color: var(--hf-text-muted);
    text-decoration: none;
    cursor: pointer;
    transition: all 0.15s;
    border-left: 2px solid transparent;
    white-space: nowrap;
  }
  .nav-item:hover {
    background: var(--hf-surface-2);
    color: var(--hf-text);
  }
  .nav-item.active {
    background: var(--hf-surface-2);
    color: var(--hf-text);
    border-left-color: var(--hf-accent);
  }
  .nav-item-icon {
    width: 20px;
    margin-right: 12px;
    font-size: 16px;
    flex-shrink: 0;
    filter: grayscale(0.4);
  }
  .nav-item.active .nav-item-icon {
    filter: none;
  }
  .sidebar.collapsed .nav-item-text {
    display: none;
  }
  .nav-section-title {
    padding: 20px 20px 8px 20px;
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--hf-text-subtle);
    white-space: nowrap;
    overflow: hidden;
  }
  .sidebar.collapsed .nav-section-title {
    color: transparent;
    padding: 20px 12px 8px 12px;
    position: relative;
  }
  .sidebar.collapsed .nav-section-title::after {
    content: '';
    position: absolute;
    left: 12px;
    right: 12px;
    top: 50%;
    height: 1px;
    background: var(--hf-border);
  }

  /* Main content + top-bar */
  .main-content {
    flex: 1;
    display: flex;
    flex-direction: column;
    background: var(--hf-bg);
    overflow: hidden;
    min-width: 0;
  }
  .top-bar {
    height: 64px;
    background: var(--hf-surface);
    border-bottom: 1px solid var(--hf-border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 24px;
    flex-shrink: 0;
  }
  .top-bar-title {
    display: flex;
    align-items: center;
    gap: 16px;
    min-width: 0;
  }
  .top-bar h2 {
    margin: 0;
    font-size: 20px;
    font-weight: 600;
    color: var(--hf-text);
    letter-spacing: -0.01em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .top-bar-actions {
    display: flex;
    gap: 8px;
    align-items: center;
  }
  .content-area {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    /* Extra bottom padding so the last row of content clears mobile
       browser chrome (iOS Safari's URL bar, Chrome's nav bar) — the
       visible viewport shrinks when those bars appear and content
       flush against the edge gets clipped. Combined with 100dvh on
       the host, this keeps the last tile/card fully visible. */
    padding: 24px 24px 96px;
    background: var(--hf-bg);
  }

  /* Hamburger + backdrop (mobile) */
  .hamburger-btn {
    display: none;
    background: var(--hf-surface-2);
    border: 1px solid var(--hf-border);
    color: var(--hf-text);
    width: 40px;
    height: 40px;
    border-radius: 6px;
    cursor: pointer;
    align-items: center;
    justify-content: center;
    font-size: 18px;
    flex-shrink: 0;
  }
  .hamburger-btn:hover {
    background: var(--hf-surface-3);
  }
  .sidebar-backdrop {
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    z-index: 99;
  }

  @media (max-width: 768px) {
    .hamburger-btn {
      display: inline-flex;
    }
    /* On mobile the sidebar slides out from the left as an overlay,
       rather than being a flex sibling. Always full-label width
       when open (no collapsed-rail variant on mobile — pure shown
       vs hidden). */
    .sidebar {
      position: fixed;
      top: 0;
      left: 0;
      z-index: 100;
      height: 100%;
      width: 280px;
      max-width: 85vw;
      transform: translateX(0);
      transition: transform 0.25s ease;
    }
    .sidebar.collapsed {
      width: 280px;
      max-width: 85vw;
      transform: translateX(-100%);
    }
    .sidebar.collapsed .nav-item-text,
    .sidebar.collapsed .sidebar-header h1 {
      display: initial;
    }
    .sidebar.collapsed .nav-section-title {
      color: var(--hf-text-subtle);
      padding: 20px 20px 8px 20px;
    }
    .sidebar.collapsed .nav-section-title::after {
      display: none;
    }
    .sidebar:not(.collapsed) ~ .sidebar-backdrop {
      display: block;
    }
    .sidebar .collapse-btn {
      display: none;
    }
    .top-bar {
      padding: 0 12px;
    }
    .content-area {
      padding: 16px;
    }
  }
`;
