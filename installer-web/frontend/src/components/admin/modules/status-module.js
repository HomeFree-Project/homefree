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
    this.rebuildStatus = {
      running: false,
      message: 'System is healthy',
      lastUpdate: { success: true }
    };
    this.buildLogs = [];
    this.systemHealth = 'healthy';
    this.pollInterval = null;
    this.previousRunningState = false;
  }

  connectedCallback() {
    super.connectedCallback();
    this.checkRebuildStatus();
    // Poll for updates every 2 seconds
    this.pollInterval = setInterval(() => this.checkRebuildStatus(), 2000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
    }
  }

  async checkRebuildStatus() {
    try {
      const response = await fetch('/api/config/rebuild-status');

      // Check if response is OK before parsing JSON
      if (!response.ok) {
        console.error('Failed to fetch rebuild status:', response.status);
        return;
      }

      const status = await response.json();

      // Detect new build starting: running changed from false → true
      if (status.running && !this.previousRunningState) {
        // New build starting - reset status
        this.systemHealth = 'building';
        this.rebuildStatus = {
          running: true,
          message: 'Building system...',
          lastUpdate: null
        };
        // Only clear logs if we have new output to replace them with
        // This prevents empty log area during silent evaluation phase
        if (status.output) {
          this.buildLogs = [];
        }
      }
      this.previousRunningState = status.running;

      if (status.output) {
        // Append new output lines (trim to remove leading/trailing whitespace)
        const newLines = status.output.trim().split('\n').filter(l => l.trim());

        // If not running, replace logs (saved state) instead of appending
        // If running, append new logs (streaming)
        if (!status.running) {
          this.buildLogs = newLines;
        } else {
          this.buildLogs = [...this.buildLogs, ...newLines];
        }

        // Auto-scroll to bottom after next render
        await this.updateComplete;
        const logsContent = this.shadowRoot.querySelector('.logs-content');
        if (logsContent) {
          logsContent.scrollTop = logsContent.scrollHeight;
        }
      }

      // Update status
      if (status.running) {
        this.systemHealth = 'building';
        this.rebuildStatus = {
          running: true,
          message: 'Building system...',
          lastUpdate: null
        };
      } else if (status.exit_code !== null && status.exit_code !== undefined) {
        // Build finished - restore final state
        const success = status.exit_code === 0;
        const partialSuccess = status.partial_success || false;

        // Set health: success = healthy, partial = warning, failure = unhealthy
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
            ? 'Build completed successfully'
            : partialSuccess
              ? `Build completed with warnings (exit code ${status.exit_code})`
              : `Build failed (exit code ${status.exit_code})`,
          lastUpdate: { success: success || partialSuccess }
        };
      } else {
        // No exit code and not running - either no rebuild ever ran, or there was an early failure
        // If there's output, it's likely an error
        if (status.output && status.output.trim()) {
          this.systemHealth = 'unhealthy';
          this.rebuildStatus = {
            running: false,
            message: 'Build failed',
            lastUpdate: { success: false }
          };
        } else {
          // No rebuild has run yet - keep healthy default
          this.systemHealth = 'healthy';
          this.rebuildStatus = {
            running: false,
            message: 'System is healthy',
            lastUpdate: { success: true }
          };
        }
      }
    } catch (error) {
      console.error('Error checking rebuild status:', error);
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
