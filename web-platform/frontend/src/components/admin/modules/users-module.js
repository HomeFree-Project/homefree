import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import { listUsers, createUser, deleteUser, setUserAdmin } from '../../../api/client.js';

/**
 * Users admin module — wraps the Zitadel management API exposed by
 * the FastAPI backend at /api/users[/...]. The backend holds the
 * Zitadel admin PAT and is the only thing that talks to Zitadel
 * directly; this module just renders state and dispatches actions.
 *
 * Capabilities:
 *   - List human users (machine users like homefree-provisioner are
 *     filtered out by the backend).
 *   - Add a user with username, name, email, password, admin flag.
 *   - Delete a user.
 *   - Toggle admin on/off (maps to IAM_OWNER instance member role).
 */
class UsersModule extends LitElement {
  static properties = {
    users: { type: Array, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    showCreate: { type: Boolean, state: true },
    creating: { type: Boolean, state: true },
    form: { type: Object, state: true },
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; max-width: 1000px; }

    .info-box {
      background: var(--hf-accent-soft);
      border-left: 4px solid var(--hf-accent);
      padding: 16px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-accent);
    }
    .info-box strong { display: block; margin-bottom: 8px; }

    .error {
      background: rgba(248,113,113,0.08);
      border: 1px solid rgba(248,113,113,0.3);
      color: #fca5a5;
      padding: 12px 16px;
      border-radius: 6px;
      margin-bottom: 16px;
    }

    table {
      width: 100%;
      border-collapse: collapse;
    }
    th, td {
      padding: 12px;
      text-align: left;
      font-size: 14px;
      border-bottom: 1px solid var(--hf-border-2);
    }
    th {
      color: var(--hf-text-muted);
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    tr:last-child td { border-bottom: none; }

    .username { font-weight: 500; color: var(--hf-text); }
    .muted { color: var(--hf-text-muted); font-size: 13px; }

    .pill {
      display: inline-flex;
      align-items: center;
      padding: 2px 10px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 600;
    }
    .pill.admin { background: rgba(250,204,21,0.12); color: #facc15; }
    .pill.user  { background: rgba(96,165,250,0.12); color: #60a5fa; }

    .toggle {
      width: 36px;
      height: 20px;
      background: var(--hf-surface-2);
      border-radius: 999px;
      position: relative;
      cursor: pointer;
      transition: background 0.15s;
      border: 1px solid var(--hf-border-2);
      display: inline-block;
      vertical-align: middle;
    }
    .toggle.on { background: var(--hf-accent); }
    .toggle::after {
      content: '';
      position: absolute;
      top: 2px;
      left: 2px;
      width: 14px;
      height: 14px;
      background: white;
      border-radius: 50%;
      transition: left 0.15s;
    }
    .toggle.on::after { left: 18px; }

    button.btn {
      padding: 6px 12px;
      background: var(--hf-surface);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      font-size: 13px;
    }
    button.btn:hover { background: var(--hf-surface-2); }
    button.btn.danger { color: #fca5a5; border-color: rgba(248,113,113,0.3); }
    button.btn.primary {
      background: var(--hf-accent);
      color: white;
      border-color: var(--hf-accent);
    }
    button.btn:disabled { opacity: 0.5; cursor: wait; }

    .actions { display: flex; gap: 8px; }

    .create-form {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
      padding: 16px;
      background: var(--hf-surface);
      border-radius: 8px;
      border: 1px solid var(--hf-border-2);
      margin-bottom: 16px;
    }
    .create-form label {
      display: block;
      font-size: 12px;
      font-weight: 600;
      color: var(--hf-text-muted);
      margin-bottom: 4px;
    }
    .create-form input[type="text"],
    .create-form input[type="email"],
    .create-form input[type="password"] {
      width: 100%;
      padding: 8px 10px;
      font-size: 14px;
      background: var(--hf-bg);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 4px;
      box-sizing: border-box;
    }
    .create-form .full { grid-column: 1 / -1; }
    .create-form .form-actions {
      grid-column: 1 / -1;
      display: flex;
      gap: 8px;
      justify-content: flex-end;
      margin-top: 4px;
    }
    .checkbox-row {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 14px;
      color: var(--hf-text);
    }
  `;

  constructor() {
    super();
    this.users = [];
    this.loading = true;
    this.error = '';
    this.showCreate = false;
    this.creating = false;
    this.form = this._blankForm();
  }

  _blankForm() {
    return {
      username: '',
      first_name: '',
      last_name: '',
      email: '',
      password: '',
      is_admin: false,
    };
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.refresh();
  }

  async refresh() {
    this.loading = true;
    this.error = '';
    try {
      const r = await listUsers();
      this.users = r.users || [];
    } catch (e) {
      this.error = `Failed to load users: ${e.message || JSON.stringify(e)}`;
    } finally {
      this.loading = false;
    }
  }

  async _toggleAdmin(user) {
    const next = !user.is_admin;
    // Optimistic update so the toggle feels instant.
    this.users = this.users.map(u =>
      u.id === user.id ? { ...u, is_admin: next } : u
    );
    try {
      await setUserAdmin(user.id, next);
    } catch (e) {
      this.error = `Failed to update admin: ${e.message || JSON.stringify(e)}`;
      // Roll back on failure.
      this.users = this.users.map(u =>
        u.id === user.id ? { ...u, is_admin: !next } : u
      );
    }
  }

  async _delete(user) {
    if (!confirm(
      `Delete user "${user.username}"? This is permanent. They will be ` +
      `signed out of all integrated services on next session refresh.`
    )) return;
    try {
      await deleteUser(user.id);
      this.users = this.users.filter(u => u.id !== user.id);
    } catch (e) {
      this.error = `Failed to delete user: ${e.message || JSON.stringify(e)}`;
    }
  }

  async _submitCreate(e) {
    e.preventDefault();
    if (!this.form.username || !this.form.email || !this.form.password) {
      this.error = 'Username, email, and password are required.';
      return;
    }
    this.creating = true;
    this.error = '';
    try {
      const r = await createUser(this.form);
      if (r.warning) this.error = r.warning;
      this.form = this._blankForm();
      this.showCreate = false;
      await this.refresh();
    } catch (e) {
      this.error = `Failed to create user: ${e.message || JSON.stringify(e)}`;
    } finally {
      this.creating = false;
    }
  }

  _updateField(field, value) {
    this.form = { ...this.form, [field]: value };
  }

  render() {
    return html`
      <div class="module-container">
        <div class="info-box">
          <strong>Users</strong>
          Add and remove users for all HomeFree services. Authentication
          flows through Zitadel; the same credentials work for every
          integrated app (Immich, Nextcloud, Forgejo, Home Assistant…).
        </div>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <config-section
          title="User list"
          description="Human users that can sign in to HomeFree services."
        >
          <div class="actions" style="margin-bottom: 12px;">
            <button class="btn" @click=${this.refresh} ?disabled=${this.loading}>
              ${this.loading ? 'Refreshing…' : 'Refresh'}
            </button>
            <button class="btn primary" @click=${() => { this.showCreate = !this.showCreate; this.error = ''; }}>
              ${this.showCreate ? 'Cancel' : 'Add user'}
            </button>
          </div>

          ${this.showCreate ? html`
            <form class="create-form" @submit=${this._submitCreate}>
              <div>
                <label>Username</label>
                <input type="text" required autofocus
                  .value=${this.form.username}
                  @input=${(e) => this._updateField('username', e.target.value)}
                />
              </div>
              <div>
                <label>Email</label>
                <input type="email" required
                  .value=${this.form.email}
                  @input=${(e) => this._updateField('email', e.target.value)}
                />
              </div>
              <div>
                <label>First name</label>
                <input type="text"
                  .value=${this.form.first_name}
                  @input=${(e) => this._updateField('first_name', e.target.value)}
                />
              </div>
              <div>
                <label>Last name</label>
                <input type="text"
                  .value=${this.form.last_name}
                  @input=${(e) => this._updateField('last_name', e.target.value)}
                />
              </div>
              <div class="full">
                <label>Initial password</label>
                <input type="password" required minlength="8"
                  .value=${this.form.password}
                  @input=${(e) => this._updateField('password', e.target.value)}
                />
              </div>
              <label class="checkbox-row full">
                <input type="checkbox"
                  .checked=${this.form.is_admin}
                  @change=${(e) => this._updateField('is_admin', e.target.checked)}
                />
                <span>Grant admin privileges (IAM_OWNER in Zitadel)</span>
              </label>
              <div class="form-actions">
                <button type="button" class="btn"
                  @click=${() => { this.showCreate = false; this.form = this._blankForm(); }}
                >Cancel</button>
                <button type="submit" class="btn primary" ?disabled=${this.creating}>
                  ${this.creating ? 'Creating…' : 'Create user'}
                </button>
              </div>
            </form>
          ` : ''}

          ${this.loading && this.users.length === 0
            ? html`<p class="muted">Loading users…</p>`
            : this.users.length === 0
              ? html`<p class="muted">No users yet. Click "Add user" to create one.</p>`
              : html`
                <table>
                  <thead>
                    <tr>
                      <th>Username</th>
                      <th>Name</th>
                      <th>Email</th>
                      <th>Role</th>
                      <th>Admin</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    ${this.users.map(u => html`
                      <tr>
                        <td class="username">${u.username}</td>
                        <td>${u.display_name || ''}</td>
                        <td class="muted">${u.email}</td>
                        <td>
                          ${u.is_admin
                            ? html`<span class="pill admin">Admin</span>`
                            : html`<span class="pill user">User</span>`}
                        </td>
                        <td>
                          <div
                            class="toggle ${u.is_admin ? 'on' : ''}"
                            @click=${() => this._toggleAdmin(u)}
                            title=${u.is_admin ? 'Click to revoke admin' : 'Click to grant admin'}
                          ></div>
                        </td>
                        <td>
                          <button class="btn danger" @click=${() => this._delete(u)}>
                            Delete
                          </button>
                        </td>
                      </tr>
                    `)}
                  </tbody>
                </table>
              `}
        </config-section>
      </div>
    `;
  }
}

customElements.define('users-module', UsersModule);
