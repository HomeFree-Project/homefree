import { LitElement, html, css } from 'lit';
import { rebootSystem } from '../api/client.js';
import { confirmDialog, alertDialog } from './shared/confirm-dialog.js';
import './welcome-step.js';
import './network-step.js';
import './wiring-step.js';
import './location-step.js';
import './keyboard-step.js';
import './partition-step.js';
import './users-step.js';
import './summary-step.js';
import './install-step.js';
import './finished-step.js';

class InstallerApp extends LitElement {
  static properties = {
    currentStep: { type: Number },
    installData: { type: Object },
    installationComplete: { type: Boolean },
  };

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      height: 100%;
      color-scheme: light;
      background: var(--hf-bg);
      color: var(--hf-text);

      --hf-bg:           #ffffff;
      --hf-surface:      #ffffff;
      --hf-surface-2:    #f5f5f7;
      --hf-surface-3:    #ebebeb;
      --hf-border:       #e0e0e0;
      --hf-border-2:     #d0d0d0;
      --hf-text:         #333333;
      --hf-text-muted:   #666666;
      --hf-text-subtle:  #999999;
      --hf-accent:       #6366f1;
      --hf-accent-hover: #5558e0;
      --hf-accent-soft:  rgba(99, 102, 241, 0.1);
      --hf-ok:           #10b981;
      --hf-warn:         #f59e0b;
      --hf-err:          #ef4444;
      --hf-focus-ring:   rgba(99, 102, 241, 0.3);
      --hf-shadow:       0 1px 3px rgba(0, 0, 0, 0.08);
      --hf-shadow-lg:    0 8px 32px rgba(0, 0, 0, 0.15);
    }

    .header {
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      padding: 24px 32px;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
    }

    h1 {
      font-size: 24px;
      font-weight: 600;
      margin: 0;
    }

    .progress-bar {
      height: 4px;
      background: rgba(255, 255, 255, 0.3);
      margin-top: 16px;
      border-radius: 2px;
      overflow: hidden;
    }

    .progress-fill {
      height: 100%;
      background: white;
      transition: width 0.3s ease;
    }

    .step-indicators {
      display: flex;
      justify-content: space-between;
      margin-top: 12px;
      font-size: 12px;
      opacity: 0.9;
    }

    .main-content {
      flex: 1;
      overflow-y: auto;
      padding: 32px;
    }

    .footer {
      display: flex;
      justify-content: space-between;
      padding: 20px 32px;
      border-top: 1px solid #e0e0e0;
      background: #f8f9fa;
    }

    button {
      padding: 12px 32px;
      border: none;
      border-radius: 6px;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .btn-back {
      background: #e0e0e0;
      color: #333;
    }

    .btn-back:hover:not(:disabled) {
      background: #d0d0d0;
    }

    .btn-next {
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
    }

    .btn-next:hover:not(:disabled) {
      transform: translateY(-1px);
      box-shadow: 0 4px 12px rgba(102, 126, 234, 0.4);
    }
  `;

  constructor() {
    super();
    this.currentStep = 0;
    this.installationComplete = false;
    this.installData = {
      hostname: '',
      wanInterface: '',
      lanInterface: '',
      timezone: '',
      locale: 'en_US.UTF-8',
      country_code: null,
      language: null,
      currency: null,
      unit_system: 'metric',
      elevation: null,
      latitude: null,
      longitude: null,
      keymap: 'us',
      vconsole: 'us',
      username: '',
      fullname: '',
      password: '',
      confirmPassword: '',
      partitioning: null,
    };
    this.steps = [
      { name: 'Welcome', component: 'welcome-step' },
      { name: 'Network', component: 'network-step' },
      { name: 'Wiring', component: 'wiring-step' },
      { name: 'Location', component: 'location-step' },
      { name: 'Keyboard', component: 'keyboard-step' },
      { name: 'Partitioning', component: 'partition-step' },
      { name: 'Users', component: 'users-step' },
      { name: 'Summary', component: 'summary-step' },
      { name: 'Install', component: 'install-step' },
      { name: 'Finished', component: 'finished-step' },
    ];

    // Listen for data-changed events from child components
    this.addEventListener('data-changed', (e) => {
      this.updateData(e.detail);
    });

    // Listen for installation-complete event from install-step
    this.addEventListener('installation-complete', () => {
      this.installationComplete = true;
      this.requestUpdate();
    });
  }

  get progress() {
    return ((this.currentStep + 1) / this.steps.length) * 100;
  }

  nextStep() {
    if (this.currentStep < this.steps.length - 1) {
      this.currentStep++;
    }
  }

  previousStep() {
    if (this.currentStep > 0) {
      this.currentStep--;
    }
  }

  updateData(data) {
    this.installData = { ...this.installData, ...data };
  }

  handleStepComplete(event) {
    this.updateData(event.detail);
    this.nextStep();
  }

  async handleReboot() {
    const ok = await confirmDialog({
      title: 'Reboot system?',
      message: 'Are you sure you want to reboot? Make sure to remove the installation media.',
      confirmText: 'Reboot',
      variant: 'danger',
    });
    if (ok) {
      try {
        // Trigger reboot via backend API
        await rebootSystem();
        // Show a message since the connection will be lost
        await alertDialog({
          message: 'System is rebooting. Please remove the installation media and wait for the system to restart.',
        });
      } catch (err) {
        await alertDialog({
          title: 'Error',
          message: 'Failed to trigger reboot: ' + err.message,
          variant: 'danger',
        });
      }
    }
  }

  isNextDisabled() {
    const step = this.currentStep;

    // Welcome step - no validation needed
    if (step === 0) return false;

    // Network step - require both interfaces to be selected
    if (step === 1) {
      return !this.installData.wanInterface || !this.installData.lanInterface;
    }

    // Wiring step - informational only, no validation
    if (step === 2) return false;

    // Location step - require timezone and locale
    if (step === 3) {
      return !this.installData.timezone || !this.installData.locale;
    }

    // Keyboard step - require keymap
    if (step === 4) {
      return !this.installData.keymap;
    }

    // Partition step - require partitioning config
    if (step === 5) {
      return !this.installData.partitioning;
    }

    // Users step - require all user fields and password match
    if (step === 6) {
      const data = this.installData;
      return !data.username || data.username.length < 3 ||
             !data.fullname || data.fullname.length < 2 ||
             !data.password || data.password.length < 8 ||
             data.password.length > 128 ||
             /[\x00-\x1F\x7F]/.test(data.password) ||
             !data.confirmPassword ||
             data.password !== data.confirmPassword ||
             !data.hostname || data.hostname.length < 2 ||
             !/^[a-z][a-z0-9-]*$/.test(data.username) ||
             !/^[a-z][a-z0-9-]*$/.test(data.hostname);
    }

    // Summary step - no validation, just review
    if (step === 7) return false;

    // Install step - disabled until installation completes
    if (step === 8) return !this.installationComplete;

    // Finished step - enable reboot button
    if (step === 9) return false;

    return false;
  }

  render() {
    const currentStepInfo = this.steps[this.currentStep];
    const isFirstStep = this.currentStep === 0;
    const isLastStep = this.currentStep === this.steps.length - 1;
    const isInstallStep = this.currentStep === 8; // Install step
    const isInstalling = isInstallStep && !this.installationComplete;
    const isFinished = this.currentStep === 9; // Finished step

    return html`
      <div class="header">
        <h1>HomeFree Self-Hosting Platform - Installation</h1>
        <div class="progress-bar">
          <div class="progress-fill" style="width: ${this.progress}%"></div>
        </div>
        <div class="step-indicators">
          ${this.steps.map((step, index) => html`
            <span style="font-weight: ${index === this.currentStep ? 'bold' : 'normal'}">
              ${step.name}
            </span>
          `)}
        </div>
      </div>

      <div class="main-content">
        ${this.renderCurrentStep()}
      </div>

      <div class="footer">
        <button
          class="btn-back"
          @click="${this.previousStep}"
          ?disabled="${isFirstStep || isInstalling || isFinished}"
        >
          Back
        </button>
        <button
          class="btn-next"
          @click="${(isInstallStep && this.installationComplete) || isFinished ? this.handleReboot : this.nextStep}"
          ?disabled="${this.isNextDisabled()}"
        >
          ${isInstalling ? 'Installing...' : (isInstallStep && this.installationComplete) ? 'Reboot' : isFinished ? 'Reboot' : 'Next'}
        </button>
      </div>
    `;
  }

  renderCurrentStep() {
    switch (this.currentStep) {
      case 0:
        return html`<welcome-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></welcome-step>`;
      case 1:
        return html`<network-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></network-step>`;
      case 2:
        return html`<wiring-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></wiring-step>`;
      case 3:
        return html`<location-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></location-step>`;
      case 4:
        return html`<keyboard-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></keyboard-step>`;
      case 5:
        return html`<partition-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></partition-step>`;
      case 6:
        return html`<users-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></users-step>`;
      case 7:
        return html`<summary-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></summary-step>`;
      case 8:
        return html`<install-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></install-step>`;
      case 9:
        return html`<finished-step .data="${this.installData}" @step-complete="${this.handleStepComplete}"></finished-step>`;
      default:
        return html`<div>Unknown step</div>`;
    }
  }
}

customElements.define('installer-app', InstallerApp);
