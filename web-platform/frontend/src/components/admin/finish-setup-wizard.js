import { LitElement, html, css } from 'lit';
import { themeVars } from '../../shared/theme.js';
import { confirmDialog } from '../shared/confirm-dialog.js';
import {
  addAuthorizedKey,
  getSecretsStatus,
  setSecret,
  saveConfigChanges,
  applyConfigChanges,
  getRebuildStatus,
  getRebuildStatusWithHistory,
  getCurrentConfig,
  markFinishSetupComplete,
} from '../../api/client.js';

// SOPS service labels — must match dns-module.js and the backend's
// write_secret_files() output paths under /var/lib/homefree-secrets/.
const DNS_CERT_SECRET_LABEL = 'dns';
const DNS_CERT_SECRET_KEY = 'api-token';
const DDNS_SECRET_LABEL = 'ddclient';

/**
 * Finish-Setup Wizard
 *
 * Shown as a full-screen overlay by admin-app whenever GET /api/mode reports
 * `setup_incomplete: true`. The ISO installer cannot collect secret-bearing
 * config (the kiosk has no way to paste keys/tokens), so a freshly-installed
 * box reaches the admin UI — over plain HTTP on the LAN, since admin.<domain>
 * has no cert yet — with three things still missing:
 *
 *   1. SSH authorized key  — required; gates ALL secret encryption.
 *   2. DNS-01 provider     — unblocks the wildcard cert for admin.<domain>.
 *   3. ddclient zones      — optional; only needed for public pages.
 *
 * The wizard collects them in that order, then applies a rebuild. Each step
 * uses plain input fields: the wizard holds the values in memory and saves
 * everything for that step (SSH key, DNS token, ddclient passwords) when the
 * user clicks Continue — there is no per-field Save button.
 */
class FinishSetupWizard extends LitElement {
  static properties = {
    // ['ssh-key', 'dns-01'] — which required items the backend still wants.
    pendingItems: { type: Array },
    // Step to start on, supplied by admin-app so navigating away from and
    // back to the wizard restores where the user left off. -1 = let the
    // wizard pick its own start step (first mount).
    initialStep: { type: Number },
    step: { type: Number, state: true },        // 0=ssh 1=dns01 2=ddclient 3=apply
    sshKeyInput: { type: String, state: true },
    sshKeySaved: { type: Boolean, state: true },
    dnsProvider: { type: String, state: true },
    dnsToken: { type: String, state: true },     // collected in memory, saved on Next
    dnsTokenSet: { type: Boolean, state: true },
    // [{zone,protocol,username,domains,key,password}] — password collected in
    // memory, saved on Next.
    ddnsZones: { type: Array, state: true },
    secretsStatus: { type: Object, state: true },
    busy: { type: Boolean, state: true },
    error: { type: String, state: true },
    applyState: { type: String, state: true },   // 'idle'|'running'|'done'|'failed'
    rebuildOutput: { type: String, state: true },
    reconnecting: { type: Boolean, state: true }, // poll lost the backend, retrying
  };

  static styles = [themeVars, css`
    /* Rendered inline as an admin module (not a full-screen overlay).
       The admin shell provides the page chrome and scrolling. */
    :host {
      display: block;
      color: var(--hf-text);
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }
    .wizard {
      width: 100%;
      max-width: 720px;
      padding: 8px 0 32px;
    }
    h1 { font-size: 24px; margin: 0 0 6px; }
    .subtitle { color: var(--hf-text-muted); font-size: 14px; margin: 0 0 28px; }
    .steps {
      display: flex;
      gap: 8px;
      margin-bottom: 28px;
    }
    .step-pip {
      flex: 1;
      height: 4px;
      border-radius: 2px;
      background: var(--hf-border-2);
    }
    .step-pip.done { background: var(--hf-accent); }
    .step-pip.active { background: var(--hf-accent-hover); }
    .card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 24px;
    }
    .card h2 { font-size: 18px; margin: 0 0 4px; }
    .card .consequence {
      background: rgba(245, 191, 66, 0.08);
      border-left: 4px solid #f5bf42;
      padding: 12px 16px;
      border-radius: 8px;
      font-size: 13px;
      color: var(--hf-text-muted);
      margin: 14px 0 18px;
      line-height: 1.5;
    }
    /* Beginner help — collapsible so experienced users can skip it. */
    details.help {
      margin: 14px 0 18px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      background: var(--hf-surface-2);
    }
    details.help summary {
      cursor: pointer;
      padding: 12px 16px;
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-accent);
      list-style: none;
    }
    details.help summary::-webkit-details-marker { display: none; }
    details.help summary::before { content: "▸ "; }
    details.help[open] summary::before { content: "▾ "; }
    details.help .help-body {
      padding: 0 16px 14px;
      font-size: 13px;
      color: var(--hf-text-muted);
      line-height: 1.6;
    }
    details.help .help-body h4 {
      color: var(--hf-text);
      font-size: 13px;
      margin: 14px 0 4px;
    }
    details.help .help-body pre {
      background: var(--hf-bg);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      padding: 8px 10px;
      overflow-x: auto;
      font-size: 12px;
      color: var(--hf-text);
    }
    details.help .help-body code {
      background: var(--hf-bg);
      padding: 1px 5px;
      border-radius: 3px;
      font-size: 12px;
    }
    details.help .help-body a { color: var(--hf-accent); }
    details.help .help-body .url {
      color: var(--hf-text-subtle);
      font-size: 12px;
    }
    /* Per-platform collapsible sub-sections inside the help body. */
    details.platform {
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      margin: 8px 0;
      background: var(--hf-surface-3, var(--hf-surface));
    }
    details.platform summary {
      cursor: pointer;
      padding: 9px 12px;
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-text);
      list-style: none;
    }
    details.platform summary::-webkit-details-marker { display: none; }
    details.platform summary::before { content: "▸ "; color: var(--hf-accent); }
    details.platform[open] summary::before { content: "▾ "; color: var(--hf-accent); }
    details.platform .platform-body { padding: 0 12px 10px; }
    label { display: block; font-size: 13px; font-weight: 500; margin: 14px 0 6px; }
    textarea, input[type=text], input[type=password] {
      width: 100%;
      box-sizing: border-box;
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      color: var(--hf-text);
      padding: 10px 12px;
      font-size: 13px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    textarea { min-height: 72px; resize: vertical; }
    .zone-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
    }
    .zone-block {
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      padding: 14px;
      margin-bottom: 14px;
      background: var(--hf-surface-2);
    }
    .actions {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      margin-top: 24px;
    }
    button {
      padding: 10px 20px;
      border-radius: 8px;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2);
      color: var(--hf-text);
    }
    button.primary {
      background: var(--hf-accent);
      border-color: var(--hf-accent);
      color: #06281c;
    }
    button.link {
      background: none;
      border: none;
      color: var(--hf-text-subtle);
      text-decoration: underline;
    }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
    .error {
      color: var(--hf-err, #f87171);
      font-size: 13px;
      margin-top: 12px;
    }
    .ok { color: var(--hf-accent); font-size: 13px; margin-top: 8px; }
    .log {
      background: #06080a;
      border: 1px solid var(--hf-border);
      border-radius: 8px;
      padding: 12px;
      font-family: ui-monospace, monospace;
      font-size: 12px;
      color: var(--hf-text-muted);
      max-height: 280px;
      overflow-y: auto;
      white-space: pre-wrap;
      margin-top: 14px;
    }
  `];

  constructor() {
    super();
    this.pendingItems = [];
    this.initialStep = -1;
    this.step = 0;
    this.sshKeyInput = '';
    this.sshKeySaved = false;
    this.dnsProvider = 'hetzner';
    this.dnsToken = '';
    this.dnsTokenSet = false;
    this.ddnsZones = [];
    this.secretsStatus = {};
    this.busy = false;
    this.error = '';
    this.applyState = 'idle';
    this.rebuildOutput = '';
    this.reconnecting = false;
  }

  async connectedCallback() {
    super.connectedCallback();
    // The wizard component is destroyed and recreated whenever the user
    // navigates away from and back to the Finish-setup page. admin-app
    // holds the last step in `initialStep` so we can resume there instead
    // of snapping back to step 0.
    //
    // Synchronous best-guess from the props we already have, so the first
    // paint isn't step 0 (refined below once saved state has loaded).
    if (this.initialStep >= 0) {
      this.step = this.initialStep;
    } else if (!this.pendingItems.includes('ssh-key')) {
      // First mount, and the box already has an authorized key (e.g. only
      // DNS-01 is pending) — skip straight past the SSH step.
      this.sshKeySaved = true;
      this.step = 1;
    }
    await this.refreshSecretsStatus();
    await this.seedZonesFromConfig();
    // Now that saved state is loaded (secret presence + seeded zones),
    // resume at the first step that still needs attention — landing on the
    // Apply step when SSH, DNS-01 and ddclient are all already saved.
    // Without this, reloading a fully-entered-but-not-yet-applied setup
    // always dumped the user back on the DNS step (and, with the ddclient
    // Continue fix, still forced a needless click through each step).
    // Only on a fresh mount — never override an explicit nav-restored
    // initialStep, and never override a rebuild recovery (handled below).
    if (this.initialStep < 0) {
      this.step = this.computeResumeStep();
    }
    // Recover an in-flight (or just-finished) rebuild. The finish-setup
    // rebuild restarts admin-api, so the user may have reloaded — or the
    // poll lost contact — while it was still running. The backend tracks
    // the transient rebuild unit independently and persists its last
    // status, so on mount we can reattach instead of restarting at step 0
    // and stranding a rebuild whose result nobody is watching.
    await this.recoverRebuildIfAny();
  }

  // Whenever the step changes, report it up to admin-app so it survives a
  // nav-away / nav-back cycle (which destroys and recreates this component).
  updated(changed) {
    if (changed.has('step')) {
      this.dispatchEvent(new CustomEvent('wizard-step-change', {
        detail: { step: this.step },
        bubbles: true,
        composed: true,
      }));
    }
  }

  // If a rebuild is running, jump to the apply step and reattach the
  // poller. (We only do this for a *running* rebuild — a stale finished
  // status from some earlier rebuild must not auto-complete setup.)
  async recoverRebuildIfAny() {
    try {
      // include_history so we get the WHOLE log so far, not just the
      // increment — the user reloaded mid-build and has no prior log.
      const s = await getRebuildStatusWithHistory();
      if (s && s.running) {
        this.step = 3;
        this.applyState = 'running';
        this.rebuildOutput = s.output || '';
        this.pollRebuild({ preserveLog: true });
      }
    } catch (e) {
      // Backend unreachable on mount — nothing to recover; the normal
      // wizard flow still works.
    }
  }

  // Pre-populate the ddclient step with one zone for the box's own domain
  // (collected by the ISO installer and stored as system.domain). Saves the
  // user re-typing it. Skipped if the config already has zones — e.g. the
  // user is returning to a partially-finished setup.
  async seedZonesFromConfig() {
    if (this.ddnsZones.length > 0) return;
    try {
      const config = await getCurrentConfig();
      console.log('[finish-setup] seedZonesFromConfig: config =', config);
      const existing = config?.dns?.['dynamic-dns']?.zones;
      if (Array.isArray(existing) && existing.length > 0) {
        // Config already carries zones — show those instead of a fresh seed.
        this.ddnsZones = existing.map((z) => ({
          zone: z.zone || '',
          protocol: z.protocol || 'hetzner',
          username: z.username || '',
          domains: Array.isArray(z.domains) ? z.domains.join(' ') : '@ *',
          key: z['password-secret-key'] || 'password',
          password: '',
        }));
        return;
      }
      const domain = config?.system?.domain;
      console.log('[finish-setup] seedZonesFromConfig: system.domain =', domain);
      if (domain) {
        this.ddnsZones = [
          { zone: domain, protocol: 'hetzner', username: '',
            domains: '@ *', key: 'password', password: '' },
        ];
      }
    } catch (e) {
      // Non-fatal — the user can still add a zone by hand — but surface it
      // so a silent failure isn't mistaken for "feature doesn't work".
      console.warn('[finish-setup] seedZonesFromConfig failed:', e);
    }
  }

  async refreshSecretsStatus() {
    try {
      const res = await getSecretsStatus();
      this.secretsStatus = res.secrets || {};
      this.dnsTokenSet = !!(this.secretsStatus[DNS_CERT_SECRET_LABEL] || {})[DNS_CERT_SECRET_KEY];
    } catch (e) {
      // Non-fatal — the wizard still works, badges just won't pre-fill.
    }
  }

  secretExists(label, key) {
    return !!((this.secretsStatus[label] || {})[key]);
  }

  // Decide which step to open on a fresh mount, from what is already saved.
  // Returns the first step still needing attention, or the Apply step (3)
  // when SSH, DNS-01 and ddclient are all satisfied. Each clause mirrors
  // that step's own Continue gate so "resume" and "can advance" agree.
  // Apply never auto-runs — the user still clicks Finish setup — so landing
  // there on an already-complete setup is safe.
  computeResumeStep() {
    // Step 0 — SSH authorized key.
    if (this.pendingItems.includes('ssh-key')) return 0;
    this.sshKeySaved = true;
    // Step 1 — DNS-01: provider saved in config AND the API token secret
    // present (pendingItems carries 'dns-01' only until the provider is
    // saved; the token is a secret, tracked separately).
    const dnsReady = !this.pendingItems.includes('dns-01') && this.dnsTokenSet;
    if (!dnsReady) return 1;
    // Step 2 — ddclient: at least one zone with a saved password secret.
    if (!this.ddnsStepReady()) return 2;
    // Step 3 — everything saved, open on Apply.
    return 3;
  }

  // --- Step 1: SSH authorized key ------------------------------------------
  async saveSshKey() {
    this.error = '';
    const key = this.sshKeyInput.trim();
    if (!key) {
      this.error = 'Paste an SSH public key to continue.';
      return;
    }
    this.busy = true;
    try {
      await addAuthorizedKey(key);
      this.sshKeySaved = true;
      this.step = 1;
    } catch (e) {
      this.error = e.message || 'Failed to add the SSH key.';
    } finally {
      this.busy = false;
    }
  }

  // --- Step 2: DNS-01 ------------------------------------------------------
  // Persist the provider into homefree-config.json AND store the API token as
  // a SOPS secret in one go. Called when the user clicks Continue. Returns
  // true on success so the caller can advance the step.
  async saveDnsStep() {
    this.error = '';
    this.busy = true;
    try {
      await saveConfigChanges({
        dns: {
          'cert-management': {
            provider: this.dnsProvider.trim() || null,
            resolvers: ['1.1.1.1'],
          },
        },
      });
      const token = this.dnsToken.trim();
      if (token) {
        await setSecret(DNS_CERT_SECRET_LABEL, DNS_CERT_SECRET_KEY, token);
      }
      return true;
    } catch (e) {
      this.error = e.message || 'Failed to save the DNS-01 settings.';
      return false;
    } finally {
      this.busy = false;
    }
  }

  // --- Step 3: ddclient zones ----------------------------------------------
  addZone() {
    this.ddnsZones = [
      ...this.ddnsZones,
      { zone: '', protocol: 'hetzner', username: '', domains: '@ *',
        key: 'password', password: '' },
    ];
  }

  updateZone(i, field, value) {
    const zones = [...this.ddnsZones];
    zones[i] = { ...zones[i], [field]: value };
    this.ddnsZones = zones;
  }

  removeZone(i) {
    this.ddnsZones = this.ddnsZones.filter((_, idx) => idx !== i);
  }

  // Write zone metadata into config AND store each zone's password as a SOPS
  // secret under the ddclient label. Called when the user clicks Continue.
  async saveZones() {
    this.error = '';
    if (this.ddnsZones.length === 0) return true;
    this.busy = true;
    try {
      await saveConfigChanges({
        dns: {
          'dynamic-dns': {
            zones: this.ddnsZones.map((z) => ({
              zone: z.zone.trim(),
              protocol: z.protocol.trim() || 'hetzner',
              username: z.username.trim(),
              domains: z.domains.split(/\s+/).filter(Boolean),
              'password-secret-key': z.key.trim() || 'password',
              disable: false,
            })),
          },
        },
      });
      for (const z of this.ddnsZones) {
        const pw = (z.password || '').trim();
        if (pw) {
          await setSecret(DDNS_SECRET_LABEL, z.key.trim() || 'password', pw);
        }
      }
      return true;
    } catch (e) {
      this.error = e.message || 'Failed to save ddclient zones.';
      return false;
    } finally {
      this.busy = false;
    }
  }

  // True when the ddclient step has enough to save: at least one zone with
  // a name and a password — EITHER typed now OR already saved as a secret
  // on a previous visit. Used to enable Continue. The saved-secret check
  // mirrors the DNS step's tokenAlreadySet: passwords are never sent back
  // to the frontend, so after a reload the field is empty even though the
  // secret exists on disk — without this, Continue stayed permanently
  // disabled on a returning, already-configured setup.
  ddnsStepReady() {
    return this.ddnsZones.some(
      (z) => z.zone.trim()
        && ((z.password || '').trim()
            || this.secretExists(DDNS_SECRET_LABEL, (z.key || 'password').trim())));
  }

  // --- Step 4: Apply -------------------------------------------------------
  async applyAndRebuild() {
    this.error = '';
    this.applyState = 'running';
    try {
      // Apply with the current on-disk config — everything has been saved by
      // the earlier steps. Passing {} triggers a rebuild without re-merging.
      const current = await getCurrentConfig();
      await applyConfigChanges(current);
      this.pollRebuild();
    } catch (e) {
      this.error = e.message || "Couldn't finish setup. Please try again.";
      this.applyState = 'failed';
    }
  }

  // Poll the rebuild to completion. A rebuild ROUTINELY restarts admin-api
  // (the very process answering this poll), so the fetch fails for a few
  // seconds every time — that is expected, NOT an error. We therefore:
  //   - retry FAST (1s) while failing, so we reattach the instant admin-api
  //     is back, and only give up after a sustained outage no restart can
  //     explain (MAX_RECONNECT_FAILURES);
  //   - show a "Reconnecting…" message during the outage instead of a
  //     frozen "Starting…", so the user knows it's still working;
  //   - REPLACE the log buffer each poll — the backend returns the
  //     complete log every time, so the log is gapless across a restart
  //     (the first poll after reconnect carries everything);
  //   - judge success on `exit_code` (0 = success), since the status
  //     payload has no `success` field.
  pollRebuild(opts = {}) {
    if (this._rebuildPoll) clearTimeout(this._rebuildPoll);
    this._rebuildFailures = 0;
    this.rebuildOutput = '';

    const MAX_RECONNECT_FAILURES = 90;  // ~90s of sustained outage
    const tick = async () => {
      let s;
      try {
        s = await getRebuildStatus();
      } catch (e) {
        // Transient — admin-api is most likely mid-restart. Keep the
        // spinner up, tell the user we're reconnecting, retry fast.
        this._rebuildFailures += 1;
        if (this._rebuildFailures <= MAX_RECONNECT_FAILURES) {
          this.reconnecting = true;
          this.requestUpdate();
          this._rebuildPoll = setTimeout(tick, 1000);
          return;
        }
        // Sustained outage — surface it instead of spinning forever.
        this.applyState = 'failed';
        this.error = 'Lost the connection to HomeFree while finishing setup. '
          + 'The rebuild may still be running on the box — wait a minute, '
          + 'then reload this page to check.';
        this._rebuildPoll = null;
        return;
      }

      this._rebuildFailures = 0;
      this.reconnecting = false;
      if (s.output) {
        // Backend returns the COMPLETE log every poll — replace, never
        // append. Gapless across an admin-api/Caddy restart.
        this.rebuildOutput = s.output;
      }
      this.requestUpdate();

      if (s.running) {
        this._rebuildPoll = setTimeout(tick, 3000);
        return;
      }

      // Rebuild finished.
      this._rebuildPoll = null;
      const succeeded = s.exit_code === 0 || s.partial_success === true;
      if (succeeded) {
        // Mark setup complete ONLY now — after a successful rebuild. This
        // writes the .setup-complete sentinel, which closes the auth bypass
        // and the captive portal, and arms the HTTP->HTTPS redirect. A
        // failure here is non-fatal (the box still works); log and continue.
        try {
          await markFinishSetupComplete();
        } catch (e) {
          console.warn('Failed to mark setup complete:', e);
        }
        this.applyState = 'done';
      } else {
        this.applyState = 'failed';
        this.error = s.exit_code == null
          ? "The rebuild finished but HomeFree couldn't read its result. "
            + 'Check the log below.'
          : "Setup didn't complete successfully. Details are below.";
      }
    };
    tick();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._rebuildPoll) clearTimeout(this._rebuildPoll);
  }

  finishWizard() {
    // Drop the #/finish-setup fragment BEFORE reloading. The wizard is
    // rendered purely off currentModule === 'finish-setup', which the
    // router restores from the hash on load — so a plain reload that kept
    // #/finish-setup would re-open the (now finished) wizard. Clearing the
    // hash lands the post-reload router on the dashboard; the reload also
    // re-fetches /api/mode (now setup-complete).
    window.location.hash = '#/';
    window.location.reload();
  }

  // --- Render --------------------------------------------------------------
  render() {
    return html`
      <div class="wizard">
        <h1>Finish setting up HomeFree</h1>
        <p class="subtitle">
          Almost done — just a few last steps to secure your HomeFree and
          make it reachable. This takes a couple of minutes.
        </p>
        <div class="steps">
          ${[0, 1, 2, 3].map((i) => html`
            <div class="step-pip ${i < this.step ? 'done' : i === this.step ? 'active' : ''}"></div>
          `)}
        </div>
        ${this.step === 0 ? this.renderSshStep()
          : this.step === 1 ? this.renderDnsStep()
          : this.step === 2 ? this.renderDdnsStep()
          : this.renderApplyStep()}
      </div>
    `;
  }

  renderSshStep() {
    return html`
      <div class="card">
        <h2>1. SSH authorized key <span style="color:var(--hf-err)">(required)</span></h2>
        <div class="consequence">
          <strong>Required.</strong> HomeFree encrypts every secret to this
          key plus the system host key. Without it, no other credential on
          this box can be saved — and you would have no SSH access.
        </div>

        <details class="help" open>
          <summary>What is this, and how do I get one? (click to collapse)</summary>
          <div class="help-body">
            <p>
              An <strong>SSH key</strong> is a pair of files: a
              <strong>private key</strong> (kept secret, never shared) and a
              <strong>public key</strong> (safe to share). You paste the
              <strong>public</strong> key below. HomeFree uses it to encrypt
              your settings and to let you log in to the box securely.
            </p>
            <p>
              If you use GitHub, GitLab, a work server, or have set up SSH
              before, you probably <strong>already have a key</strong> — reuse
              it, no need to make a new one. On GitHub you can see your public
              keys at:<br/>
              <a href="https://github.com/settings/keys" target="_blank"
                 rel="noopener">github.com/settings/keys</a>
              <span class="url">(https://github.com/settings/keys)</span>
            </p>
            <p>Open the section for your computer:</p>

            <details class="platform">
              <summary>🍎 macOS / Linux</summary>
              <div class="platform-body">
                <p><strong>Check for an existing key first.</strong> Open the
                  Terminal app and run:</p>
                <pre>cat ~/.ssh/id_ed25519.pub</pre>
                <p>
                  If that says "No such file", try the older RSA name many
                  people have:
                </p>
                <pre>cat ~/.ssh/id_rsa.pub</pre>
                <p>
                  If either prints a line starting with
                  <code>ssh-ed25519</code> or <code>ssh-rsa</code>, that's
                  your public key — copy the whole line and paste it below.
                </p>
                <p><strong>No key yet?</strong> Create one (replace the email
                  with your own — it's just a label):</p>
                <pre>ssh-keygen -t ed25519 -C "you@example.com"</pre>
                <p>
                  Press Enter to accept the default location. Setting a
                  passphrase when asked is recommended — it protects the key
                  if your computer is lost or stolen. Then run
                  <code>cat ~/.ssh/id_ed25519.pub</code> and copy the line.
                </p>
              </div>
            </details>

            <details class="platform">
              <summary>🪟 Windows</summary>
              <div class="platform-body">
                <p><strong>Check for an existing key first.</strong> Open
                  PowerShell and run:</p>
                <pre>type $env:USERPROFILE\\.ssh\\id_ed25519.pub</pre>
                <p>If that errors, try the older RSA name:</p>
                <pre>type $env:USERPROFILE\\.ssh\\id_rsa.pub</pre>
                <p>
                  If either prints a line starting with
                  <code>ssh-ed25519</code> or <code>ssh-rsa</code>, that's
                  your public key — copy the whole line and paste it below.
                </p>
                <p><strong>No key yet?</strong> Create one in PowerShell:</p>
                <pre>ssh-keygen -t ed25519 -C "you@example.com"</pre>
                <p>
                  Press Enter for the default location; set a passphrase when
                  asked. Then run
                  <code>type $env:USERPROFILE\\.ssh\\id_ed25519.pub</code>
                  to print the public key.
                </p>
              </div>
            </details>

            <p style="margin-top:12px;">
              Prefer screenshots? GitHub's guide works for all systems:<br/>
              <a href="https://docs.github.com/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent"
                 target="_blank" rel="noopener">
                GitHub — "Generating a new SSH key"</a>
              <span class="url">(https://docs.github.com/en/authentication/
              connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)</span>
            </p>

            <h4>Don't lose your key</h4>
            <p>
              The <strong>private</strong> key — the file
              <em>without</em> <code>.pub</code> (e.g.
              <code>id_ed25519</code> or <code>id_rsa</code>) — is the one
              that matters. If you lose it you lose secure access to this box.
            </p>
            <ul>
              <li>Keep it in <code>~/.ssh/</code> (or
                <code>%USERPROFILE%\\.ssh\\</code> on Windows) on a computer
                you control — don't delete that folder.</li>
              <li>Back up the private key <em>and</em> its <code>.pub</code>
                somewhere safe — a password manager (1Password, Bitwarden)
                stores files, or an encrypted USB drive.</li>
              <li><strong>Never</strong> paste the private key anywhere online
                or share it. Only the <code>.pub</code> file is shared — that's
                what goes in the box below.</li>
            </ul>
          </div>
        </details>

        <label>Your SSH public key</label>
        <textarea
          placeholder="ssh-ed25519 AAAA... you@example.com"
          .value=${this.sshKeyInput}
          @input=${(e) => { this.sshKeyInput = e.target.value; }}
        ></textarea>
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}
        <div class="actions">
          <span></span>
          <button class="primary"
            ?disabled=${this.busy || !this.sshKeyInput.trim()}
            @click=${this.saveSshKey}>
            ${this.busy ? 'Saving…' : 'Continue'}
          </button>
        </div>
      </div>
    `;
  }

  renderDnsStep() {
    const tokenEntered = !!this.dnsToken.trim();
    const tokenAlreadySet = this.secretExists(DNS_CERT_SECRET_LABEL, DNS_CERT_SECRET_KEY);
    // Continue is enabled once there's something to save: a token typed now,
    // or one already stored on a previous visit.
    const canContinue = tokenEntered || tokenAlreadySet;
    return html`
      <div class="card">
        <h2>2. Wildcard certificate (DNS-01)</h2>
        <div class="consequence">
          <strong>Skip → admin.&lt;domain&gt; stays HTTPS-unreachable.</strong>
          DNS-01 lets HomeFree issue a <code>*.&lt;domain&gt;</code>
          certificate. Until it's set, this admin UI is reachable only over
          plain HTTP on your LAN (the address you're using now).
        </div>
        <label>DNS provider</label>
        <input
          type="text"
          placeholder="hetzner"
          .value=${this.dnsProvider}
          @input=${(e) => { this.dnsProvider = e.target.value; }}
        />
        <label>DNS provider API token${tokenAlreadySet
          ? html` <span class="ok" style="font-weight:400;">(already saved — leave blank to keep)</span>`
          : ''}</label>
        <input
          type="password"
          autocomplete="off"
          placeholder=${tokenAlreadySet ? '••••••••' : 'paste your API token'}
          .value=${this.dnsToken}
          @input=${(e) => { this.dnsToken = e.target.value; }}
        />
        <p style="font-size:12px;color:var(--hf-text-subtle);margin:6px 0 0;">
          Used for the ACME DNS-01 challenge that issues
          <code>*.&lt;domain&gt;</code> certificates.
        </p>
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}
        <div class="actions">
          <button class="link" @click=${() => { this.step = 0; }}>Back</button>
          <div>
            <button ?disabled=${this.busy} @click=${this.skipDnsStep}>
              Skip for now
            </button>
            <button class="primary" ?disabled=${this.busy || !canContinue}
              @click=${async () => { if (await this.saveDnsStep()) this.step = 2; }}>
              ${this.busy ? 'Saving…' : 'Continue'}
            </button>
          </div>
        </div>
      </div>
    `;
  }

  // Skipping DNS-01 leaves admin.<domain> HTTPS-unreachable — confirm before
  // moving on. Nothing is saved.
  async skipDnsStep() {
    const ok = await confirmDialog({
      title: 'Skip the wildcard certificate?',
      message:
        'Without DNS-01, HomeFree cannot issue an HTTPS certificate for '
        + 'admin.<domain>. The admin page will stay reachable only over plain '
        + 'HTTP on your LAN. You can finish this later from the Finish setup '
        + 'page.',
      confirmText: 'Skip',
      variant: 'danger',
    });
    if (ok) {
      this.error = '';
      this.step = 2;
    }
  }

  renderDdnsStep() {
    return html`
      <div class="card">
        <h2>3. Dynamic DNS (ddclient) — optional</h2>
        <div class="consequence">
          <strong>Skip → public pages won't resolve from the internet.</strong>
          ddclient keeps public DNS records pointed at this box's WAN IP.
          HomeFree runs its own internal DNS, so you only need this for pages
          you want reachable from outside your network.
        </div>
        ${this.ddnsZones.map((z, i) => html`
          <div class="zone-block">
            <div class="zone-row">
              <div>
                <label>Zone</label>
                <input type="text" placeholder="example.com" .value=${z.zone}
                  @input=${(e) => this.updateZone(i, 'zone', e.target.value)} />
              </div>
              <div>
                <label>Protocol</label>
                <input type="text" placeholder="hetzner" .value=${z.protocol}
                  @input=${(e) => this.updateZone(i, 'protocol', e.target.value)} />
              </div>
              <div>
                <label>Username</label>
                <input type="text" .value=${z.username}
                  @input=${(e) => this.updateZone(i, 'username', e.target.value)} />
              </div>
              <div>
                <label>Domains (space-separated)</label>
                <input type="text" placeholder="@ *" .value=${z.domains}
                  @input=${(e) => this.updateZone(i, 'domains', e.target.value)} />
              </div>
            </div>
            <label>Password file key</label>
            <input type="text" placeholder="password" .value=${z.key}
              @input=${(e) => this.updateZone(i, 'key', e.target.value)} />
            <label>Password / API token${
              this.secretExists(DDNS_SECRET_LABEL, z.key || 'password')
                ? html` <span class="ok" style="font-weight:400;">(already saved — leave blank to keep)</span>`
                : ''}</label>
            <input type="password" autocomplete="off"
              placeholder=${this.secretExists(DDNS_SECRET_LABEL, z.key || 'password')
                ? '••••••••' : 'paste the credential ddclient uses for this zone'}
              .value=${z.password || ''}
              @input=${(e) => this.updateZone(i, 'password', e.target.value)} />
            <div style="margin-top:10px;">
              <button class="link" @click=${() => this.removeZone(i)}>Remove zone</button>
            </div>
          </div>
        `)}
        <button @click=${this.addZone}>+ Add zone</button>
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}
        <div class="actions">
          <button class="link" @click=${() => { this.step = 1; }}>Back</button>
          <div>
            <button ?disabled=${this.busy} @click=${this.skipDdnsStep}>
              Skip for now
            </button>
            <button class="primary" ?disabled=${this.busy || !this.ddnsStepReady()}
              @click=${async () => { if (await this.saveZones()) this.step = 3; }}>
              ${this.busy ? 'Saving…' : 'Continue'}
            </button>
          </div>
        </div>
      </div>
    `;
  }

  // Skipping ddclient leaves public pages unresolvable from the internet —
  // confirm before moving on. Nothing is saved.
  async skipDdnsStep() {
    const ok = await confirmDialog({
      title: 'Skip dynamic DNS?',
      message:
        'Without ddclient, any pages you want reachable from the public '
        + 'internet won\'t resolve to this box. Your LAN and internal DNS are '
        + 'unaffected. You can add this later from the Finish setup page.',
      confirmText: 'Skip',
      variant: 'danger',
    });
    if (ok) {
      this.error = '';
      this.step = 3;
    }
  }

  renderApplyStep() {
    return html`
      <div class="card">
        <h2>4. Finish setup</h2>
        <p style="color:var(--hf-text-muted);font-size:13px;line-height:1.5;">
          This applies everything you just entered. When it's done, HomeFree
          will be secured and your admin page will be reachable. This usually
          takes a few minutes — you can leave this page open while it works.
        </p>
        ${this.applyState === 'idle' ? html`
          <div class="actions">
            <button class="link" @click=${() => { this.step = 2; }}>Back</button>
            <button class="primary" @click=${this.applyAndRebuild}>
              Finish setup
            </button>
          </div>
        ` : ''}
        ${this.applyState === 'running' ? html`
          ${this.reconnecting ? html`
            <div class="ok" style="color:#f5bf42;">
              Reconnecting… HomeFree restarts itself partway through setup,
              so this page briefly loses contact — that's normal. Keep this
              page open; it will pick back up on its own.
            </div>
          ` : html`
            <div class="ok">Setting things up — this can take a few minutes…</div>
          `}
          <p style="font-size:12px;color:var(--hf-text-subtle);margin:8px 0 0;">
            Don't close this page. If contact is lost for good, just reload
            it once HomeFree is back to see the result.
          </p>
          <div class="log">${this.rebuildOutput || 'Starting…'}</div>
        ` : ''}
        ${this.applyState === 'done' ? html`
          <div class="ok">✓ All done! HomeFree is set up and ready.</div>
          <div class="actions">
            <span></span>
            <button class="primary" @click=${this.finishWizard}>
              Go to the admin dashboard
            </button>
          </div>
        ` : ''}
        ${this.applyState === 'failed' ? html`
          <div class="error">${this.error}</div>
          <div class="log">${this.rebuildOutput || ''}</div>
          <div class="actions">
            <button @click=${() => { this.applyState = 'idle'; }}>Try again</button>
            <span></span>
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('finish-setup-wizard', FinishSetupWizard);
