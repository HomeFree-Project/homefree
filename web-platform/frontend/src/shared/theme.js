import { css } from 'lit';

// Shared HomeFree dark theme. Used by every authenticated surface
// (admin SPA, home dashboard, future settings panels). Imported into
// each top-level component's `static styles` array so the CSS
// variables are scoped to the host but visible to every descendant
// inside the shadow tree.
//
// Palette is anchored on the public marketing site at apex
// (services/landing-page/site/src/css/main.css) — emerald accent on
// near-black. Keeping all three surfaces (marketing, admin, home)
// on one palette lets visitors who sign in feel like they're inside
// the same product, not a different one.
//
// If you change a variable here, the admin SPA and home dashboard
// both pick it up on next reload — no per-component edits needed.
export const themeVars = css`
  :host {
    --hf-bg:           #0a0c0a;
    --hf-surface:      #11141a;
    --hf-surface-2:    #181b21;
    --hf-surface-3:    #232831;
    --hf-border:       #232831;
    --hf-border-2:     #2d3340;
    --hf-text:         #f5f7fa;
    --hf-text-muted:   #b6bcc4;
    --hf-text-subtle:  #757c87;
    --hf-accent:       #34d399;
    --hf-accent-hover: #10b981;
    --hf-accent-soft:  rgba(52, 211, 153, 0.15);
    --hf-accent-glow:  rgba(52, 211, 153, 0.28);
    --hf-ok:           #34d399;
    --hf-warn:         #f59e0b;
    --hf-err:          #ef4444;
    --hf-focus-ring:   rgba(52, 211, 153, 0.4);
    --hf-shadow:       0 1px 3px rgba(0, 0, 0, 0.4);
    --hf-shadow-lg:    0 8px 32px rgba(0, 0, 0, 0.6);

    color: var(--hf-text);
    background: var(--hf-bg);
    color-scheme: dark;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI',
      Roboto, sans-serif;
  }
`;
