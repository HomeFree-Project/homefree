# No backticks inside Lit `css` / `html` tagged templates

Every Lit component in `web-platform/` defines its styles inside a
`css\`...\`` tagged template literal, and most render bodies live inside
`html\`...\``. The whole template — selectors, declarations, **and CSS
comments** — sits inside a single JavaScript template literal. The JS
parser does not know what CSS is; it only knows that a backtick ends
the current template.

That means **a stray backtick anywhere in the template body — including
inside a `/* ... */` comment — closes the template early.** Anything
after that backtick parses as JavaScript expressions until the next
backtick is reached.

## Two failure modes (both observed in this repo)

### 1. SyntaxError at parse time

A comment in `services-module.js` once read

```js
static styles = css`
  /* The .toggle slider must not be `static`. */
  ...
`;
```

The parser sees `css\`...must not be \`` as a complete tagged-template
call, then reads `static\`. \` ... `;` as further tokens — `static` is a
reserved word in strict mode, so Node throws
`SyntaxError: Unexpected strict mode reserved word`.
`node --check path/to/file.js` catches it.

### 2. TypeError at runtime (parse looks clean)

A comment in `app-card.js` read

```js
static styles = css`
  /* The legacy `.sub` <p> still flows below the name ... */
  ...
`;
```

The parser sees `css\`...The legacy \`` as a complete tagged-template
call, then reads `.sub\` <p> ... `;` — but `.sub` followed by a backtick
parses as a **member access + a tagged template**: it's calling
`<result>.sub\`...\``. That is syntactically valid JavaScript. `node
--check` passes.

It only blows up when Lit evaluates the static styles at class-init
time — i.e. the first time anything imports the component — with:

```
Uncaught TypeError: (intermediate value)(...).sub is not a function
```

The stack trace points at the line containing the closing-side token
(`.sub`), not the offending backticks in the comment, and the page
half-renders before the error fires, so it looks like a totally
unrelated runtime bug.

## How to apply

- Inside any `css\`...\`` or `html\`...\`` template — including
  comments — **use single quotes or plain words for inline emphasis**:
  `the .sub paragraph`, `must not be 'static'`. Never wrap a CSS
  identifier, class, selector, or keyword in backticks inside the
  template.
- Same rule for `${ ... }` inside the template: only intentional
  interpolations. Don't write `${something}` in a comment as
  pseudo-markdown — it's a real interpolation, and an undefined
  identifier inside a `static` field can throw.
- The same rule applies to other tagged-template literals in the
  codebase (e.g. any `gql\`...\``, `sql\`...\`` if added later).
- After editing CSS-in-JS, `node --check
  web-platform/frontend/src/components/.../file.js` catches the
  SyntaxError mode. The TypeError mode needs a manual reload of the
  admin or user UI — keep a browser console open during UI work.

## Related

- When this kind of "broken from nowhere" error appears, suspect the
  file you just edited, not the line the stack trace lands on. See the
  "search transcript before denying prior work" guidance in the user's
  auto-memory.
