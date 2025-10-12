import { LitElement, html, css } from 'lit';
import { getTimezones, setLocation } from '../api/client.js';

class LocationStep extends LitElement {
  static properties = {
    data: { type: Object },
    timezones: { type: Array },
    selectedTimezone: { type: String },
    selectedLocale: { type: String },
    loading: { type: Boolean },
    error: { type: String },
  };

  static styles = css`
    :host {
      display: block;
    }

    .location-container {
      max-width: 600px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 24px;
    }

    .form-group {
      margin-bottom: 24px;
    }

    label {
      display: block;
      margin-bottom: 8px;
      font-weight: 500;
      color: #333;
    }

    select {
      width: 100%;
      padding: 12px 16px;
      font-size: 14px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
      cursor: pointer;
    }

    select:focus {
      outline: none;
      border-color: #667eea;
    }

    .description {
      font-size: 14px;
      color: #666;
      margin-top: 4px;
    }

    .info-box {
      background: #e3f2fd;
      border: 1px solid #2196f3;
      border-radius: 6px;
      padding: 16px;
      margin-top: 24px;
      color: #1565c0;
    }

    .error {
      background: #ffebee;
      border: 1px solid #f44336;
      color: #c62828;
      padding: 12px;
      border-radius: 6px;
      margin-bottom: 16px;
    }
  `;

  constructor() {
    super();
    this.timezones = [];
    this.selectedTimezone = 'America/Los_Angeles';
    this.selectedLocale = 'en_US.UTF-8';
    this.loading = false;
    this.error = '';
  }

  connectedCallback() {
    super.connectedCallback();
    // Notify parent of initial values
    this.notifyParent();
  }

  notifyParent() {
    this.dispatchEvent(new CustomEvent('data-changed', {
      bubbles: true,
      composed: true,
      detail: {
        timezone: this.selectedTimezone,
        locale: this.selectedLocale,
      }
    }));
  }

  render() {
    return html`
      <div class="location-container">
        <h2>Location & Region</h2>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="form-group">
          <label for="timezone">Timezone</label>
          <select
            id="timezone"
            @change="${(e) => {
              this.selectedTimezone = e.target.value;
              this.notifyParent();
            }}"
          >
            <optgroup label="Americas">
              <option value="America/New_York">New York (EST)</option>
              <option value="America/Chicago">Chicago (CST)</option>
              <option value="America/Denver">Denver (MST)</option>
              <option value="America/Los_Angeles" selected>Los Angeles (PST)</option>
              <option value="America/Anchorage">Anchorage (AKST)</option>
              <option value="America/Toronto">Toronto</option>
              <option value="America/Mexico_City">Mexico City</option>
            </optgroup>
            <optgroup label="Europe">
              <option value="Europe/London">London (GMT)</option>
              <option value="Europe/Paris">Paris (CET)</option>
              <option value="Europe/Berlin">Berlin (CET)</option>
              <option value="Europe/Rome">Rome (CET)</option>
              <option value="Europe/Madrid">Madrid (CET)</option>
              <option value="Europe/Moscow">Moscow (MSK)</option>
            </optgroup>
            <optgroup label="Asia">
              <option value="Asia/Dubai">Dubai</option>
              <option value="Asia/Kolkata">Kolkata</option>
              <option value="Asia/Singapore">Singapore</option>
              <option value="Asia/Tokyo">Tokyo</option>
              <option value="Asia/Shanghai">Shanghai</option>
              <option value="Asia/Seoul">Seoul</option>
            </optgroup>
            <optgroup label="Pacific">
              <option value="Australia/Sydney">Sydney</option>
              <option value="Australia/Melbourne">Melbourne</option>
              <option value="Pacific/Auckland">Auckland</option>
            </optgroup>
          </select>
          <div class="description">
            Select your timezone for accurate time settings
          </div>
        </div>

        <div class="form-group">
          <label for="locale">Language & Locale</label>
          <select
            id="locale"
            @change="${(e) => {
              this.selectedLocale = e.target.value;
              this.notifyParent();
            }}"
          >
            <option value="en_US.UTF-8" selected>English (United States)</option>
            <option value="en_GB.UTF-8">English (United Kingdom)</option>
            <option value="en_CA.UTF-8">English (Canada)</option>
            <option value="en_AU.UTF-8">English (Australia)</option>
            <option value="de_DE.UTF-8">German (Germany)</option>
            <option value="fr_FR.UTF-8">French (France)</option>
            <option value="es_ES.UTF-8">Spanish (Spain)</option>
            <option value="it_IT.UTF-8">Italian (Italy)</option>
            <option value="pt_BR.UTF-8">Portuguese (Brazil)</option>
            <option value="ja_JP.UTF-8">Japanese (Japan)</option>
            <option value="zh_CN.UTF-8">Chinese (Simplified)</option>
            <option value="ko_KR.UTF-8">Korean (Korea)</option>
          </select>
          <div class="description">
            This sets the system language and regional formats
          </div>
        </div>

        <div class="info-box">
          <strong>ℹ️ Note:</strong>
          You can change these settings after installation in the system configuration.
        </div>
      </div>
    `;
  }
}

customElements.define('location-step', LocationStep);
