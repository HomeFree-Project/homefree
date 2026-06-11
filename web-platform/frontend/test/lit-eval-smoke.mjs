// Lit module-EVAL gate — the catch the `node --check` syntax gate can't.
//
// The repeat white-screen bug in this repo is a stray backtick inside a
// `css`...`` / `html`...`` tagged template (see AGENTS.md "Lit tagged-template
// backticks"). It fails one of two ways: a SyntaxError (parse time — caught by
// the frontend-syntax `node --check` gate) OR a TypeError at module-EVALUATION
// time (the module parses, but the tagged template is mis-closed so `css`/`html`
// is called with truncated args — `… is not a function`). `node --check` does
// NOT catch that second variant; only importing/evaluating the module does.
//
// So this imports EVERY component module under a minimal DOM shim (Lit's `css``
// is DOM-free, so the shim only needs the class hierarchy + a stub document for
// the parts of Lit that touch the DOM at import). Any module that throws while
// loading — a backtick TypeError, a bad import, any module-eval error — fails
// the gate. Browser-free, so it runs in the offline `nix flake check`.

import { register } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve as pathResolve } from 'node:path';

// ── minimal DOM shim ────────────────────────────────────────────────
class El {}
const doc = {
  createElement: () => ({ style: {}, setAttribute() {}, appendChild() {}, content: {}, cloneNode() { return this; } }),
  createElementNS: () => ({ style: {}, setAttribute() {}, appendChild() {} }),
  createTextNode: () => ({}),
  createComment: () => ({}),
  createTreeWalker: () => ({ nextNode() { return null; } }),
  createDocumentFragment: () => ({}),
  adoptedStyleSheets: [],
  head: { appendChild() {} },
  body: {},
  importNode: (n) => n,
  querySelector: () => null,
  addEventListener() {},
};
Object.assign(globalThis, {
  HTMLElement: El, Element: El, Node: El, DocumentFragment: class {}, ShadowRoot: class {},
  Document: class {}, Text: class {}, Comment: class {}, CharacterData: class {},
  Event: class {}, CustomEvent: class {}, EventTarget: class {},
  MutationObserver: class { observe() {} disconnect() {} },
  CSSStyleSheet: class { replaceSync() {} },
  customElements: { define() {}, get() {}, whenDefined() { return Promise.resolve(); } },
  window: globalThis, document: doc, self: globalThis,
  requestAnimationFrame: (cb) => setTimeout(cb, 0),
});

const here = dirname(fileURLToPath(import.meta.url));
register('./lit-eval-loader.mjs', pathToFileURL(here + '/'));

const componentsDir = pathResolve(here, '..', 'src', 'components');

function walk(d) {
  let out = [];
  for (const e of readdirSync(d)) {
    const p = join(d, e);
    if (statSync(p).isDirectory()) out = out.concat(walk(p));
    else if (e.endsWith('.js')) out.push(p);
  }
  return out;
}

const files = walk(componentsDir).sort();
let ok = 0;
const failures = [];
for (const f of files) {
  try {
    await import(pathToFileURL(f).href);
    ok++;
  } catch (e) {
    failures.push([f, (e.stack || e.message || String(e)).split('\n').slice(0, 3).join('\n      ')]);
  }
}

if (failures.length) {
  console.error(`lit-eval-smoke: ${failures.length}/${files.length} component module(s) FAILED to evaluate`);
  console.error('(a backtick inside a css`…`/html`…` template, a bad import, or any module-eval error)\n');
  for (const [f, msg] of failures) console.error(`  ✗ ${f}\n      ${msg}\n`);
  process.exit(1);
}
console.log(`lit-eval-smoke: all ${ok} component modules import + evaluate cleanly.`);
