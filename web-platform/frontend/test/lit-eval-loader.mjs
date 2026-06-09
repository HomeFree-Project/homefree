// Node ESM resolve hook that honours the browser <script type="importmap">
// from index.html, so the vendored-Lit components (which import bare 'lit',
// '@lit/reactive-element', etc., and absolute '/src/...' paths) can be
// IMPORTED — and therefore module-EVALUATED — under Node, with no browser.
//
// Used by lit-eval-smoke.mjs (the Lit tagged-template-backtick / module-eval
// gate). Parsing the live import map keeps this in lockstep with the vendored
// paths the box actually serves.

import { pathToFileURL, fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve as pathResolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const frontendRoot = pathResolve(here, '..'); // web-platform/frontend

const html = readFileSync(join(frontendRoot, 'index.html'), 'utf8');
const m = html.match(/<script[^>]*type=["']importmap["'][^>]*>([\s\S]*?)<\/script>/i);
const imports = m ? (JSON.parse(m[1]).imports || {}) : {};

// import-map targets are server-absolute ("/src/vendor/lit/index.js") → resolve
// under the frontend root on disk.
const toFile = (p) => pathToFileURL(join(frontendRoot, p.replace(/^\//, ''))).href;

export async function resolve(spec, ctx, next) {
  if (imports[spec]) return { url: toFile(imports[spec]), shortCircuit: true };
  for (const [k, v] of Object.entries(imports)) {
    if (k.endsWith('/') && spec.startsWith(k)) {
      return { url: toFile(v + spec.slice(k.length)), shortCircuit: true };
    }
  }
  // Absolute, root-relative imports the SPA uses ("/src/..." etc.).
  if (spec.startsWith('/')) return { url: toFile(spec), shortCircuit: true };
  // Everything else (relative "./x.js", "../y.js") → default Node resolution.
  return next(spec, ctx);
}
