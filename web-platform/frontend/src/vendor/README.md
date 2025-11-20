# Vendored Dependencies

This directory contains vendored JavaScript libraries that are served locally instead of from public CDNs.

## Why Vendor Dependencies?

HomeFree is a self-hosting platform that should not depend on external CDNs for core functionality. Vendoring ensures:

1. **Security**: No external code execution from third-party CDNs
2. **Reliability**: Installation works offline or on air-gapped networks
3. **Privacy**: No requests leak to external services
4. **Control**: Exact version pinning and auditability

## Contents

- **lit/** - Lit web components library v3.x
- **lit-element/** - Lit element base class
- **lit-html/** - Lit HTML templating
- **@lit/reactive-element/** - Reactive element base

## Updating Dependencies

To update vendored dependencies:

1. Update version in `package.json`
2. Run `npm install`
3. Copy updated packages: `cp -r node_modules/{lit,lit-element,lit-html,@lit} vendor/`
4. Test the application
5. Commit changes: `git add vendor/`

## Import Map

The vendored libraries are made available via an import map in `index.html`:

```html
<script type="importmap">
{
  "imports": {
    "lit": "/src/vendor/lit/index.js",
    "lit/": "/src/vendor/lit/"
  }
}
</script>
```

This allows source files to import using bare specifiers like `import { LitElement } from 'lit'` without CDN URLs.
