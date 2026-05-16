import { LitElement, html, css } from 'lit';
import { themeVars } from '../../shared/theme.js';
import {
  addAuthorizedKey,
  getSecretsStatus,
  saveConfigChanges,
  applyConfigChanges,
  getRebuildStatus,
  getCurrentConfig,
  markFinishSetupComplete,
} from '../../api/client.js';
import './secrets-input.js';

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
 * The wizard collects them in that order, then applies a rebuild. It reuses
 * <secrets-input> (which talks to /api/secrets directly) so there is no
 * duplicated secret-handling logic.
 */
class FinishSetupWizard extends LitElement {
  static properties = {
    // ['ssh-key', 'dns-01'] — which required items the backend still wants.
    pendingItems: { type: Array },
    step: { type: Number, state: true },        // 0=ssh 1=dns01 2=ddclient 3=apply
    sshKeyInput: { type: String, state: true },
    sshKeySaved: { type: Boolean, state: true },
    dnsProvider: { type: String, state: true },
    dnsTokenSet: { type: Boolean, state: true },
    ddnsZones: { type: Array, state: true },     // [{zone,protocol,username,domains,key}]
    secretsStatus: { type: Object, state: true },
    busy: { type: Boolean, state: true },
    error: { type: String, state: true },
    applyState: { type: String, state: true },   // 'idle'|'running'|'done'|'failed'
  };

  static styles = [themeVars, css`
    :host {
      position: fixed;
      inset: 0;
      z-index: 1000;
      display: flex;
      align-items: flex-start;
      justify-content: center;
      background: var(--hf-bg);
      overflow-y: auto;
      color: var(--hf-text);
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }
    .wizard {
      width: 100%;
      max-width: 720px;
      padding: 48px 32px 64px;
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
    label { display: block; font-size: 13px; font-weight: 500; margin: 14px 0 6px; }
    textarea, input[type=text] {
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
    this.step = 0;
    this.sshKeyInput = '';
    this.sshKeySaved = false;
    this.dnsProvider = 'hetzner';
    this.dnsTokenSet = false;
    this.ddnsZones = [];
    this.secretsStatus = {};
    this.busy = false;
    this.error = '';
    this.applyState = 'idle';
  }

  async connectedCallback() {
    super.connectedCallback();
    // If the box already has an authorized key (e.g. only DNS-01 is pending),
    // skip straight past the SSH step.
    if (!this.pendingItems.includes('ssh-key')) {
      this.sshKeySaved = true;
      this.step = 1;
    }
    await this.refreshSecretsStatus();
    await this.seedZonesFromConfig();
  }

  // Pre-populate the ddclient step with one zone for the box's own domain
  // (collected by the ISO installer and stored as system.domain). Saves the
  // user re-typing it. Skipped if the config already has zones — e.g. the
  // user is returning to a partially-finished setup.
  async seedZonesFromConfig() {
    if (this.ddnsZones.length > 0) return;
    try {
      const config = await getCurrentConfig();
      const existing = config?.dns?.['dynamic-dns']?.zones;
      if (Array.isArray(existing) && existing.length > 0) {
        // Config already carries zones — show those instead of a fresh seed.
        this.ddnsZones = existing.map((z) => ({
          zone: z.zone || '',
          protocol: z.protocol || 'hetzner',
          username: z.username || '',
          domains: Array.isArray(z.domains) ? z.domains.join(' ') : '@ *',
          key: z['password-secret-key'] || 'password',
        }));
        return;
      }
      const domain = config?.system?.domain;
      if (domain) {
        this.ddnsZones = [
          { zone: domain, protocol: 'hetzner', username: '',
            domains: '@ *', key: 'password' },
        ];
      }
    } catch (e) {
      // Non-fatal — the user can still add a zone by hand.
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
  async saveDnsProvider() {
    // Persist the provider into homefree-config.json. The token itself is
    // saved by the <secrets-input> below straight to /api/secrets.
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
    } catch (e) {
      this.error = e.message || 'Failed to save the DNS provider.';
    } finally {
      this.busy = false;
    }
  }

  // --- Step 3: ddclient zones ----------------------------------------------
  addZone() {
    this.ddnsZones = [
      ...this.ddnsZones,
      { zone: '', protocol: 'hetzner', username: '', domains: '@ *', key: 'password' },
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

  async saveZones() {
    // Write the non-secret zone metadata into config; per-zone passwords are
    // entered through <secrets-input> against the ddclient SOPS label.
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
      return true;
    } catch (e) {
      this.error = e.message || 'Failed to save ddclient zones.';
      return false;
    } finally {
      this.busy = false;
    }
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
      this.error = e.message || 'Failed to start the rebuild.';
      this.applyState = 'failed';
    }
  }

  pollRebuild() {
    if (this._rebuildPoll) clearInterval(this._rebuildPoll);
    this._rebuildPoll = setInterval(async () => {
      try {
        const s = await getRebuildStatus();
        this.rebuildOutput = s.output || '';
        this.requestUpdate();
        if (!s.running) {
          clearInterval(this._rebuildPoll);
          this._rebuildPoll = null;
          if (s.success) {
            // Mark setup complete ONLY now — after a successful rebuild.
            // This writes the .setup-complete sentinel, which closes the
            // auth bypass and the captive portal. Must finish before the
            // user reloads into the dashboard. A failure here is non-fatal
            // (the box still works); log and continue.
            try {
              await markFinishSetupComplete();
            } catch (e) {
              console.warn('Failed to mark setup complete:', e);
            }
            this.applyState = 'done';
          } else {
            this.applyState = 'failed';
            this.error = 'The rebuild did not complete successfully. Check the log below.';
          }
        }
      } catch (e) {
        // Backend may briefly restart mid-rebuild — keep polling.
      }
    }, 3000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._rebuildPoll) clearInterval(this._rebuildPoll);
  }

  finishWizard() {
    // Reload so admin-app re-fetches /api/mode and drops the overlay.
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

            <h4>Already have one? Reuse it.</h4>
            <p>
              If you use GitHub, GitLab, a work server, or have ever set up
              SSH before, you probably already have a key — use it, no need
              to make a new one. Find your public key:
            </p>
            <p><strong>Mac or Linux</strong> — open the Terminal app and run:</p>
            <pre>cat ~/.ssh/id_ed25519.pub</pre>
            <p>
              If that says "No such file", try
              <code>cat ~/.ssh/id_rsa.pub</code>. If both fail, you don't
              have one yet — make one below.
            </p>
            <p>
              <strong>Windows</strong> — open PowerShell and run:
            </p>
            <pre>type $env:USERPROFILE\\.ssh\\id_ed25519.pub</pre>
            <p>
              Whatever it prints — one line starting with
              <code>ssh-ed25519</code> or <code>ssh-rsa</code> — is your
              public key. Copy the whole line and paste it below.
            </p>
            <p>
              On GitHub you can also see your public keys at:<br/>
              <a href="https://github.com/settings/keys" target="_blank"
                 rel="noopener">github.com/settings/keys</a>
              <span class="url">(https://github.com/settings/keys)</span>
            </p>

            <h4>Don't have one? Create one.</h4>
            <p>
              <strong>Mac or Linux</strong> — in the Terminal, run (replace
              the email with your own — it's just a label):
            </p>
            <pre>ssh-keygen -t ed25519 -C "you@example.com"</pre>
            <p>
              Press Enter to accept the default location. You'll be asked for
              a passphrase — setting one is recommended (it protects the key
              if your computer is stolen). Then run
              <code>cat ~/.ssh/id_ed25519.pub</code> and copy the line it
              prints.
            </p>
            <p>
              <strong>Windows</strong> — open PowerShell and run the same
              command:
            </p>
            <pre>ssh-keygen -t ed25519 -C "you@example.com"</pre>
            <p>
              Then <code>type $env:USERPROFILE\\.ssh\\id_ed25519.pub</code>
              to print the public key.
            </p>
            <p>
              Step-by-step guide with screenshots (works for all three
              systems):<br/>
              <a href="https://docs.github.com/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent"
                 target="_blank" rel="noopener">
                GitHub's "Generating a new SSH key" guide</a>
              <span class="url">(https://docs.github.com/en/authentication/
              connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)</span>
            </p>

            <h4>Don't lose your key</h4>
            <p>
              The <strong>private</strong> key — the file
              <em>without</em> <code>.pub</code>, e.g.
              <code>~/.ssh/id_ed25519</code> — is the one that matters. If you
              lose it you lose access to this box.
            </p>
            <ul>
              <li>Keep it in <code>~/.ssh/</code> on a computer you control —
                don't delete that folder.</li>
              <li>Back up <code>id_ed25519</code> <em>and</em>
                <code>id_ed25519.pub</code> somewhere safe — a password
                manager (1Password, Bitwarden) stores files, or an encrypted
                USB drive.</li>
              <li><strong>Never</strong> paste the private key anywhere
                online or share it. Only the <code>.pub</code> file is shared
                — that's what goes in the box below.</li>
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
          <button class="primary" ?disabled=${this.busy} @click=${this.saveSshKey}>
            ${this.busy ? 'Saving…' : 'Add key & continue'}
          </button>
        </div>
      </div>
    `;
  }

  renderDnsStep() {
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
          @change=${this.saveDnsProvider}
        />
        <secrets-input
          .serviceLabel=${DNS_CERT_SECRET_LABEL}
          .secretKey=${DNS_CERT_SECRET_KEY}
          .label=${'DNS provider API token'}
          .description=${'Used for the ACME DNS-01 challenge that issues *.<domain> certificates.'}
          .required=${true}
          .exists=${this.secretExists(DNS_CERT_SECRET_LABEL, DNS_CERT_SECRET_KEY)}
          @secret-updated=${() => this.refreshSecretsStatus()}
        ></secrets-input>
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}
        <div class="actions">
          <button class="link" @click=${() => { this.step = 0; }}>Back</button>
          <div>
            <button @click=${async () => { await this.saveDnsProvider(); this.step = 2; }}>
              Skip for now
            </button>
            <button class="primary" ?disabled=${this.busy}
              @click=${async () => { await this.saveDnsProvider(); this.step = 2; }}>
              Continue
            </button>
          </div>
        </div>
      </div>
    `;
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
            <secrets-input
              .serviceLabel=${DDNS_SECRET_LABEL}
              .secretKey=${z.key || 'password'}
              .label=${`Password / API token (key: ${z.key || 'password'})`}
              .description=${'Credential ddclient uses to update this zone.'}
              .required=${true}
              .exists=${this.secretExists(DDNS_SECRET_LABEL, z.key || 'password')}
              @secret-updated=${() => this.refreshSecretsStatus()}
            ></secrets-input>
            <button class="link" @click=${() => this.removeZone(i)}>Remove zone</button>
          </div>
        `)}
        <button @click=${this.addZone}>+ Add zone</button>
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}
        <div class="actions">
          <button class="link" @click=${() => { this.step = 1; }}>Back</button>
          <button class="primary" ?disabled=${this.busy}
            @click=${async () => { if (await this.saveZones()) this.step = 3; }}>
            Continue
          </button>
        </div>
      </div>
    `;
  }

  renderApplyStep() {
    return html`
      <div class="card">
        <h2>4. Apply & rebuild</h2>
        <p style="color:var(--hf-text-muted);font-size:13px;line-height:1.5;">
          Applying rebuilds the system so HomeFree picks up your SSH key, the
          DNS-01 provider, and any ddclient zones. Once the rebuild finishes,
          HomeFree requests the wildcard certificate and
          <code>https://admin.&lt;domain&gt;</code> becomes reachable.
        </p>
        ${this.applyState === 'idle' ? html`
          <div class="actions">
            <button class="link" @click=${() => { this.step = 2; }}>Back</button>
            <button class="primary" @click=${this.applyAndRebuild}>
              Apply & rebuild
            </button>
          </div>
        ` : ''}
        ${this.applyState === 'running' ? html`
          <div class="ok">Rebuild in progress — this can take several minutes…</div>
          <div class="log">${this.rebuildOutput || 'Starting rebuild…'}</div>
        ` : ''}
        ${this.applyState === 'done' ? html`
          <div class="ok">✓ Setup complete. The system has been rebuilt.</div>
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
