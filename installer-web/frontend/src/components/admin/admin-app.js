import { LitElement, html, css } from 'lit';
import { getCurrentConfig, validateConfig, previewConfigChanges, applyConfigChanges } from '../../api/client.js';
import './modules/system-module.js';

class AdminApp extends LitElement {
  static properties = {
    config: { type: Object },
    currentModule: { type: String },
    loading: { type: Boolean },
    error: { type: String },
    sidebarCollapsed: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }

    .admin-container {
      display: flex;
      height: 100%;
    }

    /* Sidebar */
    .sidebar {
      width: 260px;
      background: linear-gradient(180deg, #667eea 0%, #764ba2 100%);
      color: white;
      display: flex;
      flex-direction: column;
      transition: width 0.3s ease;
      overflow-x: hidden;
    }

    .sidebar.collapsed {
      width: 60px;
    }

    .sidebar-header {
      padding: 24px 20px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.1);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .sidebar.collapsed .sidebar-header h1 {
      display: none;
    }

    .sidebar-header h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 600;
      white-space: nowrap;
    }

    .collapse-btn {
      background: rgba(255, 255, 255, 0.1);
      border: none;
      color: white;
      width: 32px;
      height: 32px;
      border-radius: 6px;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: background 0.2s;
    }

    .collapse-btn:hover {
      background: rgba(255, 255, 255, 0.2);
    }

    .nav-menu {
      flex: 1;
      padding: 16px 0;
      overflow-y: auto;
    }

    .nav-item {
      display: flex;
      align-items: center;
      padding: 12px 20px;
      color: rgba(255, 255, 255, 0.8);
      text-decoration: none;
      cursor: pointer;
      transition: all 0.2s;
      border-left: 3px solid transparent;
      white-space: nowrap;
    }

    .nav-item:hover {
      background: rgba(255, 255, 255, 0.1);
      color: white;
    }

    .nav-item.active {
      background: rgba(255, 255, 255, 0.15);
      color: white;
      border-left-color: white;
    }

    .nav-item-icon {
      width: 20px;
      margin-right: 12px;
      font-size: 18px;
      flex-shrink: 0;
    }

    .sidebar.collapsed .nav-item-text {
      display: none;
    }

    .nav-section-title {
      padding: 20px 20px 8px 20px;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      opacity: 0.6;
      white-space: nowrap;
    }

    .sidebar.collapsed .nav-section-title {
      display: none;
    }

    /* Main Content */
    .main-content {
      flex: 1;
      display: flex;
      flex-direction: column;
      background: #f5f5f7;
      overflow: hidden;
    }

    .top-bar {
      height: 64px;
      background: white;
      border-bottom: 1px solid #e5e5e7;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 32px;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05);
    }

    .top-bar h2 {
      margin: 0;
      font-size: 24px;
      font-weight: 600;
      color: #1d1d1f;
    }

    .top-bar-actions {
      display: flex;
      gap: 12px;
    }

    .btn {
      padding: 8px 16px;
      border-radius: 8px;
      border: 1px solid #d2d2d7;
      background: white;
      color: #1d1d1f;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn:hover {
      background: #f5f5f7;
    }

    .btn-primary {
      background: #667eea;
      color: white;
      border-color: #667eea;
    }

    .btn-primary:hover {
      background: #5568d3;
    }

    .content-area {
      flex: 1;
      overflow-y: auto;
      padding: 32px;
    }

    .loading-overlay {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
      font-size: 18px;
      color: #86868b;
    }

    .error-message {
      background: #fff3cd;
      color: #856404;
      padding: 16px;
      border-radius: 8px;
      border-left: 4px solid #ffc107;
    }

    .module-content {
      background: white;
      border-radius: 12px;
      padding: 32px;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
    }

    /* Responsive */
    @media (max-width: 768px) {
      .sidebar {
        position: absolute;
        z-index: 100;
        height: 100%;
      }

      .sidebar.collapsed {
        transform: translateX(-100%);
      }
    }
  `;

  constructor() {
    super();
    this.config = null;
    this.currentModule = 'system';
    this.loading = true;
    this.error = null;
    this.sidebarCollapsed = false;

    // Navigation modules
    this.modules = [
      {
        id: 'system',
        title: 'System',
        icon: '⚙️',
        section: 'General'
      },
      {
        id: 'network',
        title: 'Network',
        icon: '🌐',
        section: 'General'
      },
      {
        id: 'dns',
        title: 'DNS',
        icon: '🔍',
        section: 'General'
      },
      {
        id: 'services',
        title: 'Services',
        icon: '📦',
        section: 'Applications'
      },
      {
        id: 'backups',
        title: 'Backups',
        icon: '💾',
        section: 'Data'
      },
      {
        id: 'advanced',
        title: 'Advanced',
        icon: '🔧',
        section: 'System'
      }
    ];
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.loadConfig();
  }

  async loadConfig() {
    try {
      this.config = await getCurrentConfig();
      this.loading = false;
    } catch (error) {
      console.error('Failed to load config:', error);
      this.error = `Failed to load configuration: ${error.message}`;
      this.loading = false;
    }
  }

  handleModuleClick(moduleId) {
    this.currentModule = moduleId;
  }

  toggleSidebar() {
    this.sidebarCollapsed = !this.sidebarCollapsed;
  }

  getCurrentModuleTitle() {
    const module = this.modules.find(m => m.id === this.currentModule);
    return module ? module.title : 'HomeFree Admin';
  }

  handleConfigChange(e) {
    // Update local config when module changes it
    this.config = e.detail.config;
  }

  async handleSaveChanges() {
    if (!confirm('Save and apply configuration changes?')) {
      return;
    }

    try {
      // First validate
      const validation = await validateConfig(this.config);

      if (!validation.valid) {
        alert(`Validation errors:\n${validation.errors.join('\n')}`);
        return;
      }

      // Show warnings if any
      if (validation.warnings && validation.warnings.length > 0) {
        if (!confirm(`Warnings:\n${validation.warnings.join('\n')}\n\nContinue anyway?`)) {
          return;
        }
      }

      // Preview changes
      const preview = await previewConfigChanges(this.config);

      if (!preview.success) {
        alert(`Preview failed:\n${preview.errors.join('\n')}`);
        return;
      }

      // Show preview and confirm
      const confirmMsg = `Changes detected:\n${preview.changes.join('\n')}\n\nApply these changes?`;
      if (!confirm(confirmMsg)) {
        return;
      }

      // Apply changes
      const result = await applyConfigChanges(this.config);

      if (result.success) {
        alert('Configuration applied successfully! System is rebuilding...');
        // Could poll rebuild status here
      } else {
        alert(`Failed to apply configuration: ${result.message}`);
      }

    } catch (error) {
      console.error('Error saving changes:', error);
      alert(`Error: ${error.message}`);
    }
  }

  renderModule() {
    if (this.loading) {
      return html`
        <div class="loading-overlay">
          <div>Loading configuration...</div>
        </div>
      `;
    }

    if (this.error) {
      return html`
        <div class="error-message">
          <strong>Error:</strong> ${this.error}
        </div>
      `;
    }

    // Render appropriate module based on currentModule
    switch (this.currentModule) {
      case 'system':
        return html`
          <system-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></system-module>
        `;

      default:
        return html`
          <div class="module-content">
            <h3>${this.getCurrentModuleTitle()} Configuration</h3>
            <p>This module is under construction.</p>

            ${this.config ? html`
              <details style="margin-top: 20px;">
                <summary style="cursor: pointer; font-weight: 500;">
                  View Current Configuration (Debug)
                </summary>
                <pre style="background: #f5f5f7; padding: 16px; border-radius: 8px; overflow-x: auto; margin-top: 8px; font-size: 12px;">
${JSON.stringify(this.config, null, 2)}
                </pre>
              </details>
            ` : ''}
          </div>
        `;
    }
  }

  render() {
    // Group modules by section
    const sections = {};
    this.modules.forEach(module => {
      if (!sections[module.section]) {
        sections[module.section] = [];
      }
      sections[module.section].push(module);
    });

    return html`
      <div class="admin-container">
        <!-- Sidebar -->
        <div class="sidebar ${this.sidebarCollapsed ? 'collapsed' : ''}">
          <div class="sidebar-header">
            <h1>HomeFree</h1>
            <button class="collapse-btn" @click=${this.toggleSidebar}>
              ${this.sidebarCollapsed ? '→' : '←'}
            </button>
          </div>

          <nav class="nav-menu">
            ${Object.entries(sections).map(([section, modules]) => html`
              <div class="nav-section-title">${section}</div>
              ${modules.map(module => html`
                <div
                  class="nav-item ${this.currentModule === module.id ? 'active' : ''}"
                  @click=${() => this.handleModuleClick(module.id)}
                >
                  <span class="nav-item-icon">${module.icon}</span>
                  <span class="nav-item-text">${module.title}</span>
                </div>
              `)}
            `)}
          </nav>
        </div>

        <!-- Main Content -->
        <div class="main-content">
          <div class="top-bar">
            <h2>${this.getCurrentModuleTitle()}</h2>
            <div class="top-bar-actions">
              <button class="btn" @click=${this.loadConfig}>
                Refresh
              </button>
              <button class="btn btn-primary" @click=${this.handleSaveChanges}>
                Save & Apply
              </button>
            </div>
          </div>

          <div class="content-area">
            ${this.renderModule()}
          </div>
        </div>
      </div>
    `;
  }
}

customElements.define('admin-app', AdminApp);
