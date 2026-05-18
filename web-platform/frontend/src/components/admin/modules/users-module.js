import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/password-input.js';
import {
  listUsers, createUser, deleteUser, setUserAdmin,
  getCurrentUser, updateUser, setUserPassword, changeOwnPassword,
} from '../../../api/client.js';
import { validatePassword, loadPasswordPolicy, DEFAULT_POLICY } from '../../../shared/password-policy.js';

/**
 * Users admin module — wraps the Zitadel management API behind the
 * FastAPI backend. The backend holds the Zitadel admin PAT; this
 * module never sees a secret.
 *
 * Capabilities:
 *   - List human users (machine users filtered out).
 *   - Create a user with policy-validated password.
 *   - Edit a user (name, email, admin flag, optional password change).
 *   - Delete a user — EXCEPT the HomeFree admin user, which is
 *     protected because it's tied to the OS account and PAM bridge.
 *   - Toggle admin (IAM_OWNER) inline from the table.
 *
 * Password rules:
 *   - All password fields use <password-input> which shows a strength
 *     meter and validates against the shared policy.
 *   - "Confirm password" required for create AND for password change
 *     during edit.
 *   - When the *current* user changes their own password, the form
 *     requires their current password (proof of possession). The
 *     backend's /api/users/me/password verifies it against Zitadel.
 */
class UsersModule extends LitElement {
  static properties = {
    users: { type: Array, state: true },
    me: { type: Object, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    showCreate: { type: Boolean, state: true },
    creating: { type: Boolean, state: true },
    form: { type: Object, state: true },
    editingId: { type: String, state: true },
    editForm: { type: Object, state: true },
    saving: { type: Boolean, state: true },
    policy: { type: Object, state: true },
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; }

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

    /* Canonical list-table shell — matches the shared table-editor:
       bordered box, table scrolls horizontally inside it, add control
       is an attached footer button below the scroll area. */
    .table-editor {
      border: 1px solid var(--hf-border);
      border-radius: 8px;
      overflow: hidden;
      background: var(--hf-surface);
    }
    .table-scroll { overflow-x: auto; }
    .add-row-btn {
      display: block;
      width: 100%;
      padding: 11px;
      background: var(--hf-surface-2);
      border: none;
      border-top: 1px solid var(--hf-border);
      color: var(--hf-accent);
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
      cursor: pointer;
      transition: background 0.15s;
    }
    .add-row-btn:hover { background: var(--hf-surface-3); }

    table { width: 100%; border-collapse: collapse; min-width: max-content; }
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
    .username .you-tag {
      font-size: 11px;
      color: var(--hf-text-muted);
      margin-left: 6px;
      font-weight: 400;
    }
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
    .pill.protected {
      background: rgba(168,85,247,0.12);
      color: #c084fc;
      margin-left: 6px;
    }

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
    .toggle.disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }

    button.btn {
      padding: 6px 12px;
      background: var(--hf-surface);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      font-size: 13px;
    }
    button.btn:hover:not(:disabled) { background: var(--hf-surface-2); }
    button.btn.danger { color: #fca5a5; border-color: rgba(248,113,113,0.3); }
    button.btn.primary {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
    }
    button.btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .actions { display: flex; gap: 8px; }
    .row-actions { display: flex; gap: 6px; }

    .edit-form, .create-form {
      display: grid;
      /* minmax(0, …) so fields shrink instead of overflowing. */
      grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
      gap: 12px;
      padding: 16px;
      background: var(--hf-surface);
      border-radius: 8px;
      border: 1px solid var(--hf-border-2);
      margin-bottom: 16px;
    }
    .edit-form label, .create-form label {
      display: block;
      font-size: 12px;
      font-weight: 600;
      color: var(--hf-text-muted);
      margin-bottom: 4px;
    }
    .edit-form input[type="text"],
    .edit-form input[type="email"],
    .create-form input[type="text"],
    .create-form input[type="email"] {
      width: 100%;
      padding: 8px 10px;
      font-size: 14px;
      background: var(--hf-bg);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 4px;
      box-sizing: border-box;
    }
    .edit-form .full, .create-form .full { grid-column: 1 / -1; }
    .edit-form .form-actions, .create-form .form-actions {
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

    .edit-form .section-title {
      grid-column: 1 / -1;
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-text);
      margin-top: 8px;
      padding-top: 12px;
      border-top: 1px solid var(--hf-border-2);
    }
    .edit-form .section-title.first {
      margin-top: 0; padding-top: 0; border-top: none;
    }
    .pw-confirm-status {
      font-size: 12px;
      margin-top: 6px;
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .pw-confirm-status.match    { color: #7cb342; }
    .pw-confirm-status.mismatch { color: #fca5a5; }
    .pw-confirm-status .check {
      display: inline-flex;
      width: 14px;
      height: 14px;
      align-items: center;
      justify-content: center;
      border-radius: 50%;
      font-size: 9px;
      font-weight: bold;
    }
    .pw-confirm-status.match .check {
      background: rgba(124, 179, 66, 0.2);
    }
    .pw-confirm-status.mismatch .check {
      background: rgba(248, 113, 113, 0.2);
    }
  `;

  constructor() {
    super();
    this.users = [];
    this.me = null;
    this.loading = true;
    this.error = '';
    this.showCreate = false;
    this.creating = false;
    this.form = this._blankCreateForm();
    this.editingId = null;
    this.editForm = null;
    this.saving = false;
    this.policy = DEFAULT_POLICY;
  }

  _blankCreateForm() {
    return {
      username: '',
      first_name: '',
      last_name: '',
      email: '',
      password: '',
      confirm_password: '',
      is_admin: false,
    };
  }

  _blankEditForm(user) {
    return {
      id: user.id,
      username: user.username,
      first_name: user.first_name || '',
      last_name: user.last_name || '',
      email: user.email || '',
      is_admin: !!user.is_admin,
      // Password change is optional within edit. All three blank
      // means "don't touch the password".
      change_password: false,
      current_password: '',
      new_password: '',
      confirm_password: '',
    };
  }

  async connectedCallback() {
    super.connectedCallback();
    // Load the live Zitadel policy in parallel with the user list.
    // password-input fetches it too but caches at the module level,
    // so this just makes sure the policy is in our local state for
    // submit-time validation, even before the user opens a form.
    loadPasswordPolicy().then((p) => { this.policy = p; });
    await this.refresh();
  }

  async refresh() {
    this.loading = true;
    this.error = '';
    try {
      const [users, me] = await Promise.all([
        listUsers(),
        getCurrentUser().catch(() => null),
      ]);
      this.users = users.users || [];
      this.me = me;
    } catch (e) {
      this.error = `Failed to load users: ${this._errMsg(e)}`;
    } finally {
      this.loading = false;
    }
  }

  _errMsg(e) {
    if (!e) return 'Unknown error';
    if (typeof e === 'string') return e;
    return e.detail || e.message || JSON.stringify(e);
  }

  /** Is this user the one currently logged in? */
  _isMe(user) {
    return !!(this.me && this.me.username === user.username);
  }

  /** Is this user the HomeFree admin (OS-side, set during install)?
   *  We protect them from deletion regardless of who's looking. */
  _isProtectedAdmin(user) {
    return !!(this.me && this.me.admin_username
              && user.username === this.me.admin_username);
  }

  async _toggleAdmin(user) {
    if (this._isProtectedAdmin(user)) {
      // Revoking admin from the protected admin user would leave
      // the system with no admin. Refuse.
      this.error = `Cannot revoke admin from the HomeFree admin user.`;
      return;
    }
    const next = !user.is_admin;
    this.users = this.users.map(u =>
      u.id === user.id ? { ...u, is_admin: next } : u
    );
    try {
      await setUserAdmin(user.id, next);
    } catch (e) {
      this.error = `Failed to update admin: ${this._errMsg(e)}`;
      this.users = this.users.map(u =>
        u.id === user.id ? { ...u, is_admin: !next } : u
      );
    }
  }

  async _delete(user) {
    if (this._isProtectedAdmin(user)) return;
    if (!confirm(
      `Delete user "${user.username}"? This is permanent. They will be ` +
      `signed out of all integrated services on next session refresh.`
    )) return;
    try {
      await deleteUser(user.id);
      this.users = this.users.filter(u => u.id !== user.id);
    } catch (e) {
      this.error = `Failed to delete user: ${this._errMsg(e)}`;
    }
  }

  _startEdit(user) {
    this.editingId = user.id;
    this.editForm = this._blankEditForm(user);
    this.showCreate = false;
    this.error = '';
  }

  _cancelEdit() {
    this.editingId = null;
    this.editForm = null;
  }

  _updateEditField(field, value) {
    this.editForm = { ...this.editForm, [field]: value };
  }

  _updateCreateField(field, value) {
    this.form = { ...this.form, [field]: value };
  }

  async _submitEdit(e) {
    e.preventDefault();
    if (!this.editForm) return;
    const f = this.editForm;

    // Password change branch — validate up front so we don't make
    // half the API calls and then fail.
    if (f.change_password) {
      const v = validatePassword(f.new_password, this.policy);
      if (!v.ok) {
        this.error = v.error;
        return;
      }
      if (f.new_password !== f.confirm_password) {
        this.error = 'New passwords do not match.';
        return;
      }
      if (this._isMe({ username: f.username }) && !f.current_password) {
        this.error = 'Current password is required when changing your own password.';
        return;
      }
    }

    this.saving = true;
    this.error = '';
    try {
      // Profile updates (name/email).
      const patch = {};
      const orig = this.users.find(u => u.id === f.id) || {};
      if (f.first_name !== (orig.first_name || '')) patch.first_name = f.first_name;
      if (f.last_name !== (orig.last_name || ''))   patch.last_name = f.last_name;
      if (f.email !== (orig.email || ''))           patch.email = f.email;
      if (Object.keys(patch).length > 0) {
        await updateUser(f.id, patch);
      }

      // Admin flag.
      if (f.is_admin !== !!orig.is_admin) {
        await setUserAdmin(f.id, f.is_admin);
      }

      // Password change.
      if (f.change_password) {
        if (this._isMe({ username: f.username })) {
          await changeOwnPassword(f.current_password, f.new_password);
        } else {
          await setUserPassword(f.id, f.new_password);
        }
      }

      this._cancelEdit();
      await this.refresh();
    } catch (e) {
      this.error = `Failed to save: ${this._errMsg(e)}`;
    } finally {
      this.saving = false;
    }
  }

  async _submitCreate(e) {
    e.preventDefault();
    const f = this.form;
    if (!f.username || !f.email) {
      this.error = 'Username and email are required.';
      return;
    }
    const v = validatePassword(f.password, this.policy);
    if (!v.ok) {
      this.error = v.error;
      return;
    }
    if (f.password !== f.confirm_password) {
      this.error = 'Passwords do not match.';
      return;
    }
    this.creating = true;
    this.error = '';
    try {
      const r = await createUser({
        username: f.username,
        first_name: f.first_name,
        last_name: f.last_name,
        email: f.email,
        password: f.password,
        is_admin: f.is_admin,
      });
      if (r.warning) this.error = r.warning;
      this.form = this._blankCreateForm();
      this.showCreate = false;
      await this.refresh();
    } catch (e) {
      this.error = `Failed to create user: ${this._errMsg(e)}`;
    } finally {
      this.creating = false;
    }
  }

  /** Should the Save Changes button be enabled? When change_password
   *  is checked, the new password must validate AND match the confirm
   *  field, AND if it's a self password change, the current-password
   *  field must be populated. Without change_password the button is
   *  always enabled (profile-only edits — name/email/admin — don't
   *  have separate validation here). */
  _canSaveEdit() {
    const f = this.editForm;
    if (!f) return false;
    if (this.saving) return false;
    if (!f.change_password) return true;

    const v = validatePassword(f.new_password, this.policy);
    if (!v.ok) return false;
    if (f.new_password !== f.confirm_password) return false;
    if (this._isMe({ username: f.username }) && !f.current_password) {
      return false;
    }
    return true;
  }

  /** Same gate, for the Create button. */
  _canCreate() {
    const f = this.form;
    if (this.creating) return false;
    if (!f.username || !f.email) return false;
    const v = validatePassword(f.password, this.policy);
    if (!v.ok) return false;
    if (f.password !== f.confirm_password) return false;
    return true;
  }

  /** Inline confirm-match indicator. Shows nothing if the confirm
   *  field is empty (no nag while still typing), green check + text
   *  when the two match, red × + text when they don't. */
  _renderMatchStatus(pw, confirm) {
    if (!confirm) return '';
    if (pw === confirm) {
      return html`
        <div class="pw-confirm-status match">
          <span class="check">✓</span><span>Passwords match</span>
        </div>`;
    }
    return html`
      <div class="pw-confirm-status mismatch">
        <span class="check">×</span><span>Passwords do not match</span>
      </div>`;
  }

  render() {
    return html`
      <div class="module-container">
        <div class="info-box">
          <strong>Users</strong>
          Add and remove users for all HomeFree services. Authentication
          flows through Zitadel; the same credentials work for every
          integrated app.
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
          </div>

          ${this.showCreate ? this._renderCreateForm() : ''}
          ${this.editingId ? this._renderEditForm() : ''}

          ${this.loading && this.users.length === 0
            ? html`<p class="muted">Loading users…</p>`
            : this._renderTable()}
        </config-section>
      </div>
    `;
  }

  _renderTable() {
    const addBtn = html`
      <button class="add-row-btn"
        @click=${() => {
          this.showCreate = !this.showCreate;
          this.editingId = null;
          this.error = '';
        }}
      >${this.showCreate ? 'Cancel' : '+ Add user'}</button>
    `;
    if (this.users.length === 0) {
      return html`
        <div class="table-editor">
          <p class="muted" style="padding: 24px; margin: 0; text-align: center;">
            No users yet. Click "Add user" to create one.
          </p>
          ${addBtn}
        </div>
      `;
    }
    return html`
      <div class="table-editor">
        <div class="table-scroll">
        <table>
        <thead>
          <tr>
            <th>Username</th>
            <th>Name</th>
            <th>Email</th>
            <th>Role</th>
            <th>Admin</th>
            <th style="text-align: right;">Actions</th>
          </tr>
        </thead>
        <tbody>
          ${this.users.map(u => {
            const isMe = this._isMe(u);
            const isProtected = this._isProtectedAdmin(u);
            return html`
              <tr>
                <td class="username">
                  ${u.username}
                  ${isMe ? html`<span class="you-tag">(you)</span>` : ''}
                  ${isProtected
                    ? html`<span class="pill protected" title="Set during install — cannot be deleted">HomeFree admin</span>`
                    : ''}
                </td>
                <td>${u.display_name || ''}</td>
                <td class="muted">${u.email}</td>
                <td>
                  ${u.is_admin
                    ? html`<span class="pill admin">Admin</span>`
                    : html`<span class="pill user">User</span>`}
                </td>
                <td>
                  <div
                    class="toggle ${u.is_admin ? 'on' : ''} ${isProtected ? 'disabled' : ''}"
                    @click=${() => isProtected ? null : this._toggleAdmin(u)}
                    title=${isProtected
                      ? 'The HomeFree admin must remain an admin'
                      : (u.is_admin ? 'Click to revoke admin' : 'Click to grant admin')}
                  ></div>
                </td>
                <td>
                  <div class="row-actions" style="justify-content: flex-end;">
                    <button class="btn" @click=${() => this._startEdit(u)}>
                      Edit
                    </button>
                    <button class="btn danger"
                      @click=${() => this._delete(u)}
                      ?disabled=${isProtected}
                      title=${isProtected
                        ? 'The HomeFree admin user cannot be deleted from the UI'
                        : 'Delete this user'}
                    >Delete</button>
                  </div>
                </td>
              </tr>
            `;
          })}
        </tbody>
        </table>
        </div>
        ${addBtn}
      </div>
    `;
  }

  _renderCreateForm() {
    const f = this.form;
    return html`
      <form class="create-form" @submit=${this._submitCreate}>
        <div class="section-title first full">New user</div>
        <div>
          <label>Username</label>
          <input type="text" required autofocus
            .value=${f.username}
            @input=${(e) => this._updateCreateField('username', e.target.value)}
          />
        </div>
        <div>
          <label>Email</label>
          <input type="email" required
            .value=${f.email}
            @input=${(e) => this._updateCreateField('email', e.target.value)}
          />
        </div>
        <div>
          <label>First name</label>
          <input type="text"
            .value=${f.first_name}
            @input=${(e) => this._updateCreateField('first_name', e.target.value)}
          />
        </div>
        <div>
          <label>Last name</label>
          <input type="text"
            .value=${f.last_name}
            @input=${(e) => this._updateCreateField('last_name', e.target.value)}
          />
        </div>
        <div class="full">
          <label>Password</label>
          <password-input
            withStrength
            .policy=${this.policy}
            .value=${f.password}
            @input=${(e) => this._updateCreateField('password', e.detail.value)}
          ></password-input>
        </div>
        <div class="full">
          <label>Confirm password</label>
          <password-input
            .value=${f.confirm_password}
            @input=${(e) => this._updateCreateField('confirm_password', e.detail.value)}
          ></password-input>
          ${this._renderMatchStatus(f.password, f.confirm_password)}
        </div>
        <label class="checkbox-row full">
          <input type="checkbox"
            .checked=${f.is_admin}
            @change=${(e) => this._updateCreateField('is_admin', e.target.checked)}
          />
          <span>Grant admin privileges (IAM_OWNER in Zitadel)</span>
        </label>
        <div class="form-actions">
          <button type="button" class="btn"
            @click=${() => {
              this.showCreate = false;
              this.form = this._blankCreateForm();
            }}
          >Cancel</button>
          <button type="submit" class="btn primary"
            ?disabled=${!this._canCreate()}
            title=${!this._canCreate()
              ? 'Fill in username, email, and a matching password that meets requirements'
              : ''}
          >
            ${this.creating ? 'Creating…' : 'Create user'}
          </button>
        </div>
      </form>
    `;
  }

  _renderEditForm() {
    const f = this.editForm;
    if (!f) return '';
    const isMe = this._isMe({ username: f.username });
    const isProtected = this._isProtectedAdmin({ username: f.username });
    return html`
      <form class="edit-form" @submit=${this._submitEdit}>
        <div class="section-title first full">
          Edit ${f.username}${isMe ? ' (you)' : ''}
        </div>
        <div>
          <label>First name</label>
          <input type="text"
            .value=${f.first_name}
            @input=${(e) => this._updateEditField('first_name', e.target.value)}
          />
        </div>
        <div>
          <label>Last name</label>
          <input type="text"
            .value=${f.last_name}
            @input=${(e) => this._updateEditField('last_name', e.target.value)}
          />
        </div>
        <div class="full">
          <label>Email</label>
          <input type="email"
            .value=${f.email}
            @input=${(e) => this._updateEditField('email', e.target.value)}
          />
        </div>

        <label class="checkbox-row full">
          <input type="checkbox"
            .checked=${f.is_admin}
            ?disabled=${isProtected}
            @change=${(e) => this._updateEditField('is_admin', e.target.checked)}
          />
          <span>
            Admin privileges
            ${isProtected ? html`<span class="muted">— required for the HomeFree admin</span>` : ''}
          </span>
        </label>

        <label class="checkbox-row full">
          <input type="checkbox"
            .checked=${f.change_password}
            @change=${(e) => this._updateEditField('change_password', e.target.checked)}
          />
          <span>Change password</span>
        </label>

        ${f.change_password ? html`
          ${isMe ? html`
            <div class="full">
              <label>Current password (required to change your own password)</label>
              <password-input
                autocomplete="current-password"
                .value=${f.current_password}
                @input=${(e) => this._updateEditField('current_password', e.detail.value)}
              ></password-input>
            </div>
          ` : ''}
          <div class="full">
            <label>New password</label>
            <password-input
              withStrength
              .policy=${this.policy}
              .value=${f.new_password}
              @input=${(e) => this._updateEditField('new_password', e.detail.value)}
            ></password-input>
          </div>
          <div class="full">
            <label>Confirm new password</label>
            <password-input
              .value=${f.confirm_password}
              @input=${(e) => this._updateEditField('confirm_password', e.detail.value)}
            ></password-input>
            ${this._renderMatchStatus(f.new_password, f.confirm_password)}
          </div>
        ` : ''}

        <div class="form-actions">
          <button type="button" class="btn" @click=${this._cancelEdit}>
            Cancel
          </button>
          <button type="submit" class="btn primary"
            ?disabled=${!this._canSaveEdit()}
            title=${!this._canSaveEdit() && this.editForm?.change_password
              ? 'Password must meet requirements and match confirm field'
              : ''}
          >
            ${this.saving ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </form>
    `;
  }
}

customElements.define('users-module', UsersModule);
