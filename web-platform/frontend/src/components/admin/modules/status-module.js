import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';

/**
 * Status module
 * Shows system build status and logs
 */
class StatusModule extends LitElement {
  static properties = {
    rebuildStatus: { type: Object },
    buildLogs: { type: Array },
    systemHealth: { type: String },
    logsCollapsed: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .status-header {
      display: flex;
      align-items: center;
      gap: 16px;
      padding: 24px;
      background: var(--hf-surface);
      border-radius: 12px;
      margin-bottom: 24px;
      box-shadow: var(--hf-shadow);
      max-width: 1200px;
    }

    .status-indicator {
      width: 48px;
      height: 48px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 24px;
    }

    .status-indicator.healthy {
      background: rgba(16, 185, 129, 0.12);
      color: var(--hf-ok);
    }

    .status-indicator.unhealthy {
      background: rgba(239, 68, 68, 0.1);
      color: var(--hf-err);
    }

    .status-indicator.warning {
      background: rgba(245, 158, 11, 0.1);
      color: var(--hf-warn);
    }

    .status-indicator.building {
      background: var(--hf-accent-soft);
      color: var(--hf-accent);
    }

    .status-info {
      flex: 1;
    }

    .status-title {
      font-size: 20px;
      font-weight: 600;
      margin: 0 0 4px 0;
      color: var(--hf-text);
    }

    .status-message {
      font-size: 14px;
      color: var(--hf-text-muted);
      margin: 0;
    }

    .spinner {
      width: 24px;
      height: 24px;
      border: 3px solid var(--hf-border);
      border-top-color: var(--hf-accent);
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .logs-container {
      background: var(--hf-surface);
      border-radius: 12px;
      padding: 24px;
      box-shadow: var(--hf-shadow);
      max-width: 1200px;
    }

    .logs-header {
      font-size: 18px;
      font-weight: 600;
      margin: 0 0 16px 0;
      color: var(--hf-text);
      display: flex;
      align-items: center;
      justify-content: space-between;
      cursor: pointer;
      user-select: none;
      transition: color 0.2s ease;
    }

    .logs-header:hover {
      color: var(--hf-accent);
    }

    .logs-header-text {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .chevron {
      font-size: 14px;
      transition: transform 0.3s ease;
      color: var(--hf-text-muted);
    }

    .chevron.collapsed {
      transform: rotate(-90deg);
    }

    .logs-content {
      background: var(--hf-surface);
      color: var(--hf-text);
      padding: 16px;
      border-radius: 8px;
      font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
      font-size: 13px;
      line-height: 1.6;
      max-height: 600px;
      overflow-y: auto;
      white-space: pre-wrap;
      word-wrap: break-word;
      transition: opacity 0.2s ease;
    }

    .logs-content.collapsed {
      display: none;
    }

    .logs-content::-webkit-scrollbar {
      width: 8px;
    }

    .logs-content::-webkit-scrollbar-track {
      background: var(--hf-surface-2);
      border-radius: 4px;
    }

    .logs-content::-webkit-scrollbar-thumb {
      background: var(--hf-accent);
      border-radius: 4px;
    }

    .logs-content::-webkit-scrollbar-thumb:hover {
      background: var(--hf-accent-hover);
    }

    .empty-logs {
      color: var(--hf-text-muted);
      font-style: italic;
      text-align: center;
      padding: 32px;
    }

    .log-line {
      margin: 2px 0;
    }

    .log-line.error {
      color: var(--hf-err);
    }

    .log-line.warning {
      color: var(--hf-warn);
    }

    .log-line.success {
      color: var(--hf-ok);
    }
  `;

  constructor() {
    super();
    // Initialize properties with defaults
    // These will be overridden by parent via property binding
    this.rebuildStatus = {
      running: false,
      message: 'System is healthy',
      lastUpdate: { success: true }
    };
    this.buildLogs = [];
    this.systemHealth = 'healthy';
    this.logsCollapsed = true; // Default to collapsed
  }

  toggleLogsCollapsed() {
    this.logsCollapsed = !this.logsCollapsed;
    // Once the user has explicitly toggled, stop auto-expanding on log
    // changes — they've taken ownership of the panel state.
    this._userHasToggledLogs = true;
  }

  // True if we should follow the tail of the log on new lines. Starts on,
  // turns off when the user scrolls up, turns back on when they scroll
  // back to the bottom.
  _logsFollowTail = true;

  handleLogsScroll(e) {
    const el = e.currentTarget;
    // Treat "within 8px of bottom" as pinned — scrollHeight is fractional
    // on hidpi screens, and a strict equality would never re-arm.
    const distanceFromBottom = el.scrollHeight - el.clientHeight - el.scrollTop;
    this._logsFollowTail = distanceFromBottom < 8;
  }

  updated(changedProperties) {
    super.updated(changedProperties);

    // Auto-expand when build starts or fails
    if (changedProperties.has('systemHealth')) {
      if (this.systemHealth === 'building' || this.systemHealth === 'unhealthy') {
        this.logsCollapsed = false;
      }
      // Don't auto-collapse on success - let user control
    }

    // Auto-expand once logs first arrive — covers the page-reload case
    // where we hydrate buildLogs from the backend's persisted log and the
    // user otherwise wouldn't see them without clicking to expand.
    if (changedProperties.has('buildLogs')) {
      const prev = changedProperties.get('buildLogs') || [];
      if (prev.length === 0 && this.buildLogs.length > 0 && !this._userHasToggledLogs) {
        this.logsCollapsed = false;
      }
      // Re-arm tail-following when fresh logs first show up so the new
      // build starts pinned to the bottom by default.
      if (prev.length === 0 && this.buildLogs.length > 0) {
        this._logsFollowTail = true;
      }
    }

    // Auto-scroll only while the user is pinned to the tail. If they've
    // scrolled up, leave their viewport alone — they're reading something.
    if (changedProperties.has('buildLogs') && this.buildLogs.length > 0
        && !this.logsCollapsed && this._logsFollowTail) {
      const logsContent = this.shadowRoot.querySelector('.logs-content');
      if (logsContent) {
        logsContent.scrollTop = logsContent.scrollHeight;
      }
    }
  }

  getStatusIcon() {
    switch (this.systemHealth) {
      case 'healthy':
        return '✓';
      case 'unhealthy':
        return '✗';
      case 'warning':
        return '⚠';
      case 'building':
        return html`<div class="spinner"></div>`;
      default:
        return '?';
    }
  }

  getStatusTitle() {
    switch (this.systemHealth) {
      case 'healthy':
        return 'System Healthy';
      case 'unhealthy':
        return 'System Unhealthy';
      case 'warning':
        return 'System Warning';
      case 'building':
        return 'Building System';
      default:
        return 'Unknown Status';
    }
  }

  classifyLogLine(line) {
    const lowerLine = line.toLowerCase();
    if (lowerLine.includes('error') || lowerLine.includes('failed')) {
      return 'error';
    } else if (lowerLine.includes('warning')) {
      return 'warning';
    } else if (lowerLine.includes('success') || lowerLine.includes('done')) {
      return 'success';
    }
    return '';
  }

  render() {
    return html`
      <div class="module-container">
        <!-- Status Header -->
        <div class="status-header">
          <div class="status-indicator ${this.systemHealth}">
            ${this.getStatusIcon()}
          </div>
          <div class="status-info">
            <h2 class="status-title">${this.getStatusTitle()}</h2>
            <p class="status-message">${this.rebuildStatus.message}</p>
          </div>
        </div>

        <!-- Build Logs -->
        <div class="logs-container">
          <h3 class="logs-header" @click=${this.toggleLogsCollapsed}>
            <span class="logs-header-text">
              <span class="chevron ${this.logsCollapsed ? 'collapsed' : ''}">▼</span>
              Build Logs
            </span>
          </h3>
          <div
            class="logs-content ${this.logsCollapsed ? 'collapsed' : ''}"
            @scroll=${this.handleLogsScroll}
          >
            ${this.buildLogs.length > 0 ? html`
              ${this.buildLogs.map(line => html`<div class="log-line ${this.classifyLogLine(line)}">${line}</div>`)}
            ` : html`
              <div class="empty-logs">
                No build logs available. Logs will appear here when a build is running.
              </div>
            `}
          </div>
        </div>
      </div>
    `;
  }
}

customElements.define('status-module', StatusModule);
