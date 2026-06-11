#!/usr/bin/env node
// Frontend import-graph gate (Wave 0a, v1 — RELATIVE imports only).
//
// Walks web-platform/frontend/src/**/*.js (excluding the vendored Lit tree)
// and asserts that every RELATIVE import/export specifier ('./x', '../y')
// resolves to a real file. A dangling relative import is the most common
// white-screen: the browser fetches the missing .js, the ES module graph
// stalls, and the entire SPA dies (not just the new page).
//
// SCOPE (deliberate, v1): bare specifiers (lit, lit-html/..., @lit/...) are
// resolved in the browser via the index.html importmap into src/vendor/.
// Validating those — plus the unmapped @urql/core / graphql / wonka in
// src/graphql/client.js, and the vendor-internal @lit-labs/ssr-dom-shim — is a
// documented follow-up (needs proper importmap longest-prefix resolution).
// Relative resolution is unambiguous and catches the documented failure with
// zero false positives, so it ships first.
//
// Usage: node check-frontend-imports.mjs <frontend-root>
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { dirname, resolve, join } from "node:path";

const root = process.argv[2];
if (!root) {
  console.error("usage: check-frontend-imports.mjs <frontend-root>");
  process.exit(2);
}
const srcDir = join(root, "src");

function walk(dir, acc = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) {
      if (name === "vendor") continue; // third-party; resolved via importmap
      walk(p, acc);
    } else if (name.endsWith(".js")) {
      acc.push(p);
    }
  }
  return acc;
}

// Strip comments before scanning so example imports inside JSDoc blocks (a
// real pattern here — e.g. shared/confirm-dialog.js documents its own usage)
// and `// ...` notes don't register as imports. Not a full tokenizer, but ES
// import statements don't live inside string/template bodies, and we only act
// on relative specifiers, so this is sufficient and false-positive-free.
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "") // block comments (incl. JSDoc)
    .replace(/(^|[^:])\/\/.*$/gm, "$1"); // line comments (preserve `://` in URLs)
}

// `import ... from '<s>'` | `export ... from '<s>'` | `import '<s>'` |
// `import('<s>')`. We only ACT on relative specifiers below, so incidental
// matches inside text (which essentially never start with ./ or ../) are inert.
const specRe =
  /(?:\bimport\b|\bexport\b)[^'"]*?from\s*['"]([^'"]+)['"]|\bimport\s*['"]([^'"]+)['"]|\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g;

function resolves(fromFile, spec) {
  const base = resolve(dirname(fromFile), spec);
  const candidates = [base, base + ".js", join(base, "index.js")];
  return candidates.some((c) => existsSync(c) && statSync(c).isFile());
}

const problems = [];
for (const file of walk(srcDir)) {
  const txt = stripComments(readFileSync(file, "utf8"));
  let m;
  while ((m = specRe.exec(txt)) !== null) {
    const spec = m[1] || m[2] || m[3];
    if (!spec) continue;
    if (spec.startsWith("./") || spec.startsWith("../")) {
      if (!resolves(file, spec)) {
        problems.push(`${file}: unresolved relative import '${spec}'`);
      }
    }
  }
}

if (problems.length) {
  console.error("frontend-imports: unresolved relative imports:");
  for (const p of problems) console.error("  " + p);
  console.error(`\n${problems.length} unresolved import(s)`);
  process.exit(1);
}
console.log("frontend-imports: all relative imports resolve");
