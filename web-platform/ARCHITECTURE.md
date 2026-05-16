# HomeFree Web Platform Architecture

The `web-platform/` directory is a single codebase that serves two surfaces from the
same frontend and backend:

1. **Installer mode** — runs on the ISO to install HomeFree on new hardware.
2. **Admin mode** — runs on an installed system to configure every HomeFree setting.

A third, lighter **user dashboard** surface shares the same shell and shows a signed-in
user their profile and the services available to them.

## Mode detection

The backend decides the surface based on whether `/etc/nixos/homefree-configuration.nix`
exists (`backend/services/mode.py`):

- File absent → **installer** → installation wizard.
- File present → **admin** → administration interface.

The frontend root (`frontend/src/app.js`) calls the mode endpoint and dispatches to
`installer-app`, `admin-app`, or `user-app`.

## Backend (Python / FastAPI, REST)

The backend is a FastAPI app exposing a **REST API** (`backend/simple_main.py` is the
entry point used in production; `backend/main.py`/`schema.py` retain an earlier
GraphQL surface). The frontend talks to it exclusively through `frontend/src/api/client.js`.

```
backend/
├── simple_main.py          # FastAPI app, REST routes (production entry point)
├── main.py, schema.py      # earlier GraphQL surface
├── models.py               # data models
├── resolvers/              # per-domain request handlers
│   ├── install.py          # installation orchestration
│   ├── system.py           # hardware / locale detection
│   ├── network.py          # network interface detection
│   ├── config.py           # config CRUD for the admin UI
│   ├── services.py         # service enable/disable/configure
│   ├── backups.py          # backup & restore operations
│   ├── secrets.py          # secret management
│   └── abuse_blocking.py   # abuse detection / IP blocking
├── services/               # business-logic layer
│   ├── mode.py             # installer-vs-admin detection
│   ├── config.py / config_reader.py / config_writer.py
│   ├── validation.py       # multi-layer config validation
│   ├── nix_operations.py   # nixos-rebuild / dry-activate
│   ├── install.py          # partitioning, nixos-install
│   ├── network.py          # interface enumeration
│   ├── backup_operations.py
│   └── secrets_manager.py
└── utils/privileged.py     # privilege-escalation helpers
```

Key admin endpoints: `GET /api/mode`, `GET /api/config/current`,
`POST /api/config/validate`, `GET /api/config/diff`, `POST /api/config/preview`,
`POST /api/config/apply`, `GET /api/config/rebuild-status`.

## Frontend (Lit web components)

Built with [Lit](https://lit.dev) — vendored under `frontend/src/vendor/` so installer
ISO builds work offline. Vite is the build tool.

```
frontend/src/
├── app.js                  # mode router (installer | admin | user)
├── api/client.js           # REST client — the only HTTP interface
├── shared/                 # cross-surface utilities
│   ├── shell.js            # app shell layout (sidebar, top-bar)
│   ├── theme.js            # CSS variables / theming
│   ├── user-menu.js        # header user menu
│   ├── auth.js             # sign-out logic
│   └── password-policy.js
├── components/
│   ├── installer-app.js    # installer orchestrator
│   ├── *-step.js           # 9 wizard steps (welcome → finished)
│   ├── shared/             # reusable inputs/containers
│   │   ├── form-field.js, config-section.js, table-editor.js,
│   │   ├── dropdown-select.js, list-input.js, password-input.js,
│   │   ├── file-browser.js, lat-lng-picker.js, progress-modal.js,
│   │   └── submodule-list-editor.js, toast-notification.js
│   ├── admin/
│   │   ├── admin-app.js    # admin orchestrator: navigation, dirty
│   │   │                   #   state, save & apply, rebuild polling
│   │   ├── secrets-input.js, service-option-input.js
│   │   └── modules/        # one module per config area
│   │       ├── system-module.js, network-module.js, dns-module.js,
│   │       ├── services-module.js, backups-module.js, sso-module.js,
│   │       ├── users-module.js, mounts-module.js, status-module.js,
│   │       ├── proxied-domains-module.js, extra-proxies-module.js,
│   │       └── abuse-blocking-module.js (+ world-map-path.js)
│   └── user/user-app.js    # per-user dashboard
└── ...
```

`admin-app.js` is the central orchestrator: it statically imports every module, owns
the global navigation sidebar and the `pendingConfig` / `dirtyModules` / `saveStatus`
state, and drives the save & apply workflow. Modules never write config directly — they
emit `data-changed` events that `admin-app` merges. Modules do not import each other; the
dependency graph is a star with `admin-app` at the center.

## NixOS integration

| File | Purpose |
|------|---------|
| `web-platform/installer.nix` | Installer ISO only — graphical base, kiosk Firefox, boot branding, backend/browser systemd units |
| `web-platform/shared.nix` | Shared by installer + admin — stages frontend/backend to `/etc/homefree-installer`, runs the FastAPI service, enables Cockpit for disk management, opens firewall ports, polkit rules |
| `web-platform/default.nix` | Backward-compat wrapper re-exporting `shared.nix` |
| `services/admin-web/default.nix` | Admin service on installed systems — Caddy reverse proxy + auth + backend |

## Save & apply workflow (admin mode)

1. User edits config in a module → module emits `data-changed`.
2. `admin-app` merges the change into `pendingConfig`, marks the module dirty.
3. User clicks **Save & Apply**.
4. Frontend validates (types, required fields); backend validates (business logic, safety).
5. Network-change warnings shown if connectivity could be lost.
6. Config written to `/etc/nixos/homefree-configuration.nix` (a backup is taken first).
7. `nixos-rebuild dry-activate` → preview shown to the user.
8. On confirmation, `nixos-rebuild switch`; rebuild progress is polled into the UI.

## Adding a new admin module

1. Create `components/admin/modules/<name>-module.js`, following an existing module.
2. Use the shared components (`form-field`, `config-section`, `table-editor`, …).
3. Emit `data-changed` events; never write config directly.
4. Import the module in `admin-app.js` and add it to the navigation list / render switch.
5. Add a matching resolver under `backend/resolvers/` if the module needs new data.

## Installation flow (installer mode)

1. Boot from ISO → GNOME desktop loads, backend service starts, Firefox opens in kiosk
   mode at the local backend.
2. 9-step wizard: welcome → network (WAN/LAN) → location → keyboard → partitioning
   (Cockpit Storage) → users → summary → install → finished.
3. Backend performs partitioning, `nixos-generate-config`, config generation, git init of
   `/etc/nixos`, `nixos-install`, and post-install finalization.
4. Reboot into the installed system, which then serves admin mode.

See `CALAMARES_REPLACEMENT.md` for why and how the web installer replaced Calamares, and
`DEV_WORKFLOW.md` for the fast SSH-based development loop.
