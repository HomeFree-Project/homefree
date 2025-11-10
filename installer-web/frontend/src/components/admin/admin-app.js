import { LitElement, html, css } from 'lit';
import { getCurrentConfig, validateConfig, previewConfigChanges, applyConfigChanges } from '../../api/client.js';
import './modules/system-module.js';
import './modules/network-module.js';
import './modules/dns-module.js';
import './modules/services-module.js';
import './modules/backups-module.js';
import './modules/status-module.js';
import '../shared/progress-modal.js';

class AdminApp extends LitElement {
  static properties = {
    config: { type: Object },
    currentModule: { type: String },
    loading: { type: Boolean },
    error: { type: String },
    sidebarCollapsed: { type: Boolean },
    rebuildStatus: { type: Object }
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
      width: 70px;
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
      padding: 0 24px;
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

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .spinner-tiny {
      width: 10px;
      height: 10px;
      border: 2px solid rgba(255, 255, 255, 0.3);
      border-top-color: white;
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    .status-badge {
      margin-left: auto;
      width: 10px;
      height: 10px;
      border-radius: 50%;
      flex-shrink: 0;
    }

    .status-badge.healthy {
      background: #10b981;
    }

    .status-badge.unhealthy {
      background: #ef4444;
    }

    .status-badge.warning {
      background: #f59e0b;
    }

    .status-badge.building {
      background: transparent;
      width: auto;
      height: auto;
    }

    .sidebar.collapsed .status-badge {
      display: none;
    }

    .content-area {
      flex: 1;
      overflow-y: auto;
      padding: 24px;
    }

    .loading-overlay {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
      font-size: 18px;
      color: #86868b;
    }

    /* Full-screen loading overlay for initial load */
    .fullscreen-loading {
      position: fixed;
      top: 0;
      left: 0;
      width: 100vw;
      height: 100vh;
      background: #f5f5f7;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      z-index: 9999;
    }

    .loading-spinner {
      width: 48px;
      height: 48px;
      border: 4px solid rgba(102, 126, 234, 0.1);
      border-top-color: #667eea;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin-bottom: 16px;
    }

    .loading-text {
      font-size: 16px;
      color: #86868b;
      font-weight: 500;
    }

    .error-message {
      background: #fff3cd;
      color: #856404;
      padding: 16px;
      border-radius: 8px;
      border-left: 4px solid #ffc107;
      margin: 32px;
    }

    .module-content {
      background: white;
      border-radius: 0;
      padding: 24px;
      box-shadow: none;
      min-height: 100%;
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
    this.systemHealth = 'healthy';
    this.rebuildStatus = {
      running: false,
      message: '',
      lastUpdate: null
    };

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
      },
      {
        id: 'status',
        title: 'Status',
        icon: '📊',
        section: 'System'
      }
    ];
  }

  async connectedCallback() {
    super.connectedCallback();

    // Read initial route from hash
    this.loadRouteFromHash();

    // Listen for hash changes (back/forward buttons)
    window.addEventListener('hashchange', () => {
      this.loadRouteFromHash();
    });

    await this.loadConfig();

    // Check if a rebuild is already in progress
    await this.checkRebuildStatus();
  }

  loadRouteFromHash() {
    const hash = window.location.hash.slice(2); // Remove '#/'
    if (hash && this.modules.find(m => m.id === hash)) {
      this.currentModule = hash;
    } else if (!hash) {
      // Default to system if no hash
      this.currentModule = 'system';
    }
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

  async checkRebuildStatus() {
    try {
      const response = await fetch('/api/config/rebuild-status');
      const status = await response.json();

      // If rebuild is running, restore state and start polling
      if (status.running) {
        this.systemHealth = 'building';
        this.rebuildStatus = {
          running: true,
          message: 'Rebuild in progress...',
          lastUpdate: null
        };

        // Start polling to show live updates
        this.pollRebuildStatus();
      } else if (status.exit_code !== null && status.exit_code !== undefined) {
        // Build has finished - restore final state
        const success = status.exit_code === 0;
        const partialSuccess = status.partial_success || false;

        // Set systemHealth based on exit code (same logic as status-module)
        if (success) {
          this.systemHealth = 'healthy';
        } else if (partialSuccess) {
          this.systemHealth = 'warning';
        } else {
          this.systemHealth = 'unhealthy';
        }

        this.rebuildStatus = {
          running: false,
          message: success
            ? 'Rebuild completed successfully'
            : partialSuccess
              ? `Rebuild completed with warnings (exit code ${status.exit_code})`
              : `Rebuild failed (exit code ${status.exit_code})`,
          lastUpdate: {
            success: success || partialSuccess,
            warning: partialSuccess
          }
        };
      }
    } catch (error) {
      console.error('Error checking rebuild status:', error);
      // Don't throw - just continue with normal loading
    }
  }

  handleModuleClick(moduleId) {
    this.currentModule = moduleId;
    // Update URL hash to maintain state
    window.location.hash = `#/${moduleId}`;
  }

  toggleSidebar() {
    this.sidebarCollapsed = !this.sidebarCollapsed;
  }

  getCurrentModuleTitle() {
    const module = this.modules.find(m => m.id === this.currentModule);
    return module ? module.title : 'HomeFree Admin';
  }

  getStatusBadgeClass() {
    // Use systemHealth directly (same as status-module.js)
    // This ensures left nav badge matches status page title
    if (this.rebuildStatus.running) {
      return 'building';
    }
    return this.systemHealth || 'healthy';
  }

  handleConfigChange(e) {
    // Update local config when module changes it
    this.config = e.detail.config;
  }

  async handleSaveChanges() {
    const modal = this.shadowRoot.querySelector('progress-modal');

    try {
      // Show modal and start validation
      modal.show('Saving Configuration', 'Validating configuration...', 'progress');

      // Validate configuration
      const validation = await validateConfig(this.config);

      if (!validation.valid) {
        modal.updateStatus('error', 'Validation Failed',
          validation.errors.map(e => ({ message: e, type: 'error' }))
        );
        return;
      }

      // Show warnings if any (using modal, not browser alert)
      if (validation.warnings && validation.warnings.length > 0) {
        const warningsHtml = validation.warnings.map(w => `⚠️ ${w}`).join('<br>');
        modal.updateStatus('warning', 'Configuration Warnings',
          [{ message: warningsHtml }, { message: 'Continue anyway?' }]
        );
        // TODO: Add modal buttons for Continue/Cancel instead of relying on modal close
        // For now, just show warnings and continue after 3 seconds
        await new Promise(resolve => setTimeout(resolve, 3000));
      }

      // Apply changes (skip preview/dry-activate step)
      modal.updateStatus('progress', 'Saving configuration and starting rebuild...');
      const result = await applyConfigChanges(this.config);

      if (!result.success) {
        modal.updateStatus('error', 'Failed to Apply Configuration',
          [{ message: result.message || 'Unknown error', type: 'error' }]
        );
        return;
      }

      // Close modal and show status in header
      modal.updateStatus('success', 'Rebuild Started',
        [{ message: 'Configuration saved and rebuild started in background' },
         { message: 'You can close this dialog and continue working' }]
      );

      // Set rebuild status
      this.rebuildStatus = {
        running: true,
        message: 'Starting system rebuild...',
        lastUpdate: null
      };

      // Start background polling
      this.pollRebuildStatus();

    } catch (error) {
      console.error('Error saving changes:', error);
      modal.updateStatus('error', 'An Error Occurred',
        [{ message: error.message || 'Unknown error', type: 'error' }]
      );
    }
  }

  async pollRebuildStatus() {
    let allOutput = []; // Accumulate all output lines

    const checkStatus = async () => {
      try {
        const response = await fetch('/api/config/rebuild-status');
        const status = await response.json();

        if (status.output) {
          // Accumulate output (trim to remove leading/trailing whitespace)
          const newLines = status.output.trim().split('\n').filter(l => l.trim());
          allOutput.push(...newLines);

          // Update header status with last line
          const lastLine = newLines[newLines.length - 1] || 'Building...';
          this.systemHealth = 'building';
          this.rebuildStatus = {
            running: true,
            message: lastLine.substring(0, 50) + (lastLine.length > 50 ? '...' : ''),
            lastUpdate: { success: null }
          };
        }

        if (!status.running) {
          // Rebuild finished
          const success = status.exit_code === 0;
          const partialSuccess = status.partial_success || false;

          if (success) {
            this.systemHealth = 'healthy';
            this.rebuildStatus = {
              running: false,
              message: 'Rebuild completed successfully',
              lastUpdate: { success: true }
            };

            // Reload config after success
            setTimeout(() => {
              this.loadConfig();
            }, 2000);
          } else if (partialSuccess) {
            this.systemHealth = 'warning';
            // Partial success: generation activated but services failed
            this.rebuildStatus = {
              running: false,
              message: `Rebuild completed with warnings (exit code ${status.exit_code}) - Click to view logs`,
              lastUpdate: { success: true, warning: true }
            };

            // Reload config after partial success
            setTimeout(() => {
              this.loadConfig();
            }, 2000);
          } else {
            this.systemHealth = 'unhealthy';
            // Show error status
            const errorLines = allOutput.slice(-20);
            this.rebuildStatus = {
              running: false,
              message: `Rebuild failed (exit code ${status.exit_code}) - Click to view logs`,
              lastUpdate: { success: false, output: errorLines.join('\n') }
            };
          }
          // Don't stop polling - keep syncing with status-module
        }

        // Continue polling every 2 seconds
        setTimeout(checkStatus, 2000);
      } catch (error) {
        console.error('Error polling rebuild status:', error);
        this.rebuildStatus = {
          running: false,
          message: 'Lost connection to rebuild process',
          lastUpdate: { success: false }
        };
      }
    };

    // Start polling
    checkStatus();
  }

  renderModule() {
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

      case 'network':
        return html`
          <network-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></network-module>
        `;

      case 'dns':
        return html`
          <dns-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></dns-module>
        `;

      case 'services':
        return html`
          <services-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></services-module>
        `;

      case 'backups':
        return html`
          <backups-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></backups-module>
        `;

      case 'advanced':
        return html`
          <div class="module-content">
            <h3>Advanced Configuration</h3>
            <p>Advanced configuration options will be available in a future update.</p>

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

      case 'status':
        return html`
          <status-module></status-module>
        `;

      default:
        return html`
          <div class="module-content">
            <h3>${this.getCurrentModuleTitle()} Configuration</h3>
            <p>This module is under construction.</p>
          </div>
        `;
    }
  }

  render() {
    // Show full-screen loading spinner on initial load
    if (this.loading) {
      return html`
        <div class="fullscreen-loading">
          <div class="loading-spinner"></div>
          <div class="loading-text">Loading configuration...</div>
        </div>
      `;
    }

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
                  ${module.id === 'status' ? html`
                    <span class="status-badge ${this.getStatusBadgeClass()}">
                      ${this.rebuildStatus.running ? html`<div class="spinner-tiny"></div>` : ''}
                    </span>
                  ` : ''}
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

      <!-- Progress Modal -->
      <progress-modal></progress-modal>
    `;
  }
}

customElements.define('admin-app', AdminApp);
