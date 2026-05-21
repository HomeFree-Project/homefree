# Admin-UI table column sizing (the two ways a list table breaks on mobile)

Both the hand-rolled tables (e.g. `lan-clients-module.js`) and the
shared `table-editor.js` are wide tables that scroll horizontally inside
a bordered, `overflow-x: auto` box. Two non-obvious sizing traps make
them look fine on a wide desktop and broken at phone width, because the
bug only shows once the viewport is narrower than the table.

## 1. `table-layout: fixed` min-width must include cell padding

With `table-layout: fixed`, the column widths come from the `th` widths,
but each cell still adds its `padding` *on top* (default `box-sizing:
content-box`). If the table's `min-width` only sums the declared column
widths and forgets the padding, the sized columns alone consume the
whole `min-width`, and any **unsized** column is starved to 0px. Its
`white-space: nowrap` header then overflows and overlaps the next
header, and its cell (clipped by `overflow: hidden`) disappears.

Rule: `min-width` ≥ Σ(column content widths) + Σ(per-cell horizontal
padding) over *every* column, including the unsized one's intended
minimum. On a wide desktop the `width:100%` table exceeds this and the
slack hides the bug; it surfaces only when the container is narrower
than that true sum (mobile, or a narrow desktop window).

## 2. `width: %` cells + `min-width: max-content` balloon the table

`table { min-width: max-content }` derives the table width from the
columns. A cell with a **percentage** width (e.g. the old `width: 1%`
"shrink to content" hack on boolean columns) resolves that percentage
against the very max-content width being derived — a feedback loop that
balloons the table to thousands of px wide. It triggers on any table
that has such a column (it's why External Proxies, with four boolean
columns, exploded while the boolean-free 3-column tables were fine).

Rule: under `min-width: max-content`, size "shrink to content" columns
with a **length**, never a percentage. `width: 1px` (a sub-min-content
length) collapses the column to its longest word, which is exactly what
the `1%` was trying to do.

Also: phones want a smaller inter-column gap — add a
`@media (max-width: 600px)` block that roughly halves the horizontal
cell padding.
