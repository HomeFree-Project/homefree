import { LitElement, html, css } from 'lit';
import { getTimezones, setLocation } from '../api/client.js';
import './shared/dropdown-select.js';

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
          <dropdown-select
            .options=${[
              { group: 'Americas' },
              { value: 'America/New_York', label: 'New York (EST)' },
              { value: 'America/Chicago', label: 'Chicago (CST)' },
              { value: 'America/Denver', label: 'Denver (MST)' },
              { value: 'America/Los_Angeles', label: 'Los Angeles (PST)' },
              { value: 'America/Anchorage', label: 'Anchorage (AKST)' },
              { value: 'America/Toronto', label: 'Toronto' },
              { value: 'America/Mexico_City', label: 'Mexico City' },
              { group: 'Europe' },
              { value: 'Europe/London', label: 'London (GMT)' },
              { value: 'Europe/Paris', label: 'Paris (CET)' },
              { value: 'Europe/Berlin', label: 'Berlin (CET)' },
              { value: 'Europe/Rome', label: 'Rome (CET)' },
              { value: 'Europe/Madrid', label: 'Madrid (CET)' },
              { value: 'Europe/Moscow', label: 'Moscow (MSK)' },
              { group: 'Asia' },
              { value: 'Asia/Dubai', label: 'Dubai' },
              { value: 'Asia/Kolkata', label: 'Kolkata' },
              { value: 'Asia/Singapore', label: 'Singapore' },
              { value: 'Asia/Tokyo', label: 'Tokyo' },
              { value: 'Asia/Shanghai', label: 'Shanghai' },
              { value: 'Asia/Seoul', label: 'Seoul' },
              { group: 'Pacific' },
              { value: 'Australia/Sydney', label: 'Sydney' },
              { value: 'Australia/Melbourne', label: 'Melbourne' },
              { value: 'Pacific/Auckland', label: 'Auckland' },
            ]}
            .value=${this.selectedTimezone || 'America/Los_Angeles'}
            @change=${(e) => {
              this.selectedTimezone = e.detail.value;
              this.notifyParent();
            }}
          ></dropdown-select>
          <div class="description">
            Select your timezone for accurate time settings
          </div>
        </div>

        <div class="form-group">
          <label for="locale">Language & Locale</label>
          <dropdown-select
            .options=${[
              { value: 'en_US.UTF-8', label: 'English (United States)' },
              { value: 'en_GB.UTF-8', label: 'English (United Kingdom)' },
              { value: 'en_CA.UTF-8', label: 'English (Canada)' },
              { value: 'en_AU.UTF-8', label: 'English (Australia)' },
              { value: 'de_DE.UTF-8', label: 'German (Germany)' },
              { value: 'fr_FR.UTF-8', label: 'French (France)' },
              { value: 'es_ES.UTF-8', label: 'Spanish (Spain)' },
              { value: 'it_IT.UTF-8', label: 'Italian (Italy)' },
              { value: 'pt_BR.UTF-8', label: 'Portuguese (Brazil)' },
              { value: 'ja_JP.UTF-8', label: 'Japanese (Japan)' },
              { value: 'zh_CN.UTF-8', label: 'Chinese (Simplified)' },
              { value: 'ko_KR.UTF-8', label: 'Korean (Korea)' },
            ]}
            .value=${this.selectedLocale || 'en_US.UTF-8'}
            @change=${(e) => {
              this.selectedLocale = e.detail.value;
              this.notifyParent();
            }}
          ></dropdown-select>
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
