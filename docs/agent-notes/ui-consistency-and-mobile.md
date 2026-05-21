# UI changes: reuse the existing pattern, and check mobile

Two rules for any change under `web-platform/frontend/` (the admin UI,
the user portal, the landing page) or any other web surface in this repo.

## 1. Every layout/UI change must work on mobile

The admin UI and user portal are used on phones. A change that only looks
right on a wide desktop is not done. Before considering UI work complete:

- Picture the component at a phone width (~360–414px) as well as desktop.
  Cards go one-per-row and narrow; header strips wrap; fixed-width rows
  blow out horizontally.
- Add a `@media (max-width: 600px)` (or the breakpoint already used in
  that file) block when the desktop layout doesn't fold gracefully —
  e.g. stack a right-aligned control cluster left-justified, force
  full-width rows, shrink modal gutters toward fullscreen.
- Modals: a phone needs a thin gutter and near-full height
  (`max-height: calc(100vh - 24px)`), not a centred fixed-width card.
- Truncate (`overflow: hidden; text-overflow: ellipsis`) or wrap long
  text so it can't widen a flex/grid item past the viewport.

The services-module App Configuration cards are the worked example:
header strip stacks left-justified on mobile, toggles drop to their own
full-width lines, the config modal goes near-fullscreen.

## 2. Reuse the established pattern — don't invent a new one per task

The UI already has canonical patterns. Match them instead of hand-rolling
a one-off:

- **Buttons** — the canonical admin button is `padding: 9px 16px; font-size:
  13px; border-radius: 6px` with `.btn-primary` / `.btn-secondary` /
  `.btn-danger` variants (see `shared/progress-modal.js`). Compact chips
  (icon-actions, the details button) follow the smaller chip style already
  in `services-module.js`.
- **Modals** — overlay is `position: fixed; inset: 0; background: rgba(0,0,0,0.7);
  backdrop-filter: blur(2px); z-index: 1000`, dismissed by clicking the
  backdrop (with `@click=${e => e.stopPropagation()}` on the box) and by
  Escape, body scrolls with `overflow-y: auto` + `max-height: 90vh`. See
  `users-module.js` (fixed-width) and `services-module.js` (the
  section-width variant capped at `--hf-content-max`). Pick the closest
  existing variant rather than a new structure.
- **Widths** — content caps at `--hf-content-max` (theme.js). Don't
  hard-code pixel widths that duplicate it.
- **Fonts / colours / spacing** — use the `--hf-*` design tokens
  (`shared/theme.js`): `--hf-text`, `--hf-text-muted`, `--hf-surface*`,
  `--hf-border*`, `--hf-accent`, `--hf-ok/warn/err`. Never hard-code a hex
  colour or a font-family when a token exists; `font-family: inherit` on
  form controls.
- **Icons** — `actionIcon(name)` / `navIcon(name)` from `shared/icons.js`,
  never an inline ad-hoc SVG or a CDN icon font.

If a genuinely new pattern is needed, that's a design decision — surface
it to the maintainer rather than quietly introducing a second way to do
the same thing. A divergent one-off is tech debt: it makes the UI look
assembled by many hands and multiplies the surfaces to restyle later.
