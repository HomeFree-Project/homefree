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
    systemHealth: { type: String }
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
      background: white;
      border-radius: 12px;
      margin-bottom: 24px;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
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
      background: #d1fae5;
      color: #065f46;
    }

    .status-indicator.unhealthy {
      background: #fee2e2;
      color: #991b1b;
    }

    .status-indicator.warning {
      background: #fef3c7;
      color: #92400e;
    }

    .status-indicator.building {
      background: #dbeafe;
      color: #1e40af;
    }

    .status-info {
      flex: 1;
    }

    .status-title {
      font-size: 20px;
      font-weight: 600;
      margin: 0 0 4px 0;
      color: #1d1d1f;
    }

    .status-message {
      font-size: 14px;
      color: #86868b;
      margin: 0;
    }

    .spinner {
      width: 24px;
      height: 24px;
      border: 3px solid #e5e7eb;
      border-top-color: #667eea;
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .logs-container {
      background: white;
      border-radius: 12px;
      padding: 24px;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
      max-width: 1200px;
    }

    .logs-header {
      font-size: 18px;
      font-weight: 600;
      margin: 0 0 16px 0;
      color: #1d1d1f;
    }

    .logs-content {
      background: #1d1d1f;
      color: #f5f5f7;
      padding: 16px;
      border-radius: 8px;
      font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
      font-size: 13px;
      line-height: 1.6;
      max-height: 600px;
      overflow-y: auto;
      white-space: pre-wrap;
      word-wrap: break-word;
    }

    .logs-content::-webkit-scrollbar {
      width: 8px;
    }

    .logs-content::-webkit-scrollbar-track {
      background: #2d2d2d;
      border-radius: 4px;
    }

    .logs-content::-webkit-scrollbar-thumb {
      background: #667eea;
      border-radius: 4px;
    }

    .logs-content::-webkit-scrollbar-thumb:hover {
      background: #5568d3;
    }

    .empty-logs {
      color: #86868b;
      font-style: italic;
      text-align: center;
      padding: 32px;
    }

    .log-line {
      margin: 2px 0;
    }

    .log-line.error {
      color: #ef4444;
    }

    .log-line.warning {
      color: #f59e0b;
    }

    .log-line.success {
      color: #10b981;
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
  }

  updated(changedProperties) {
    super.updated(changedProperties);

    // Auto-scroll to bottom when logs change
    if (changedProperties.has('buildLogs') && this.buildLogs.length > 0) {
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
          <h3 class="logs-header">Build Logs</h3>
          <div class="logs-content">
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
