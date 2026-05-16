import { LitElement, html, css } from 'lit';
import './shared/dropdown-select.js';

class KeyboardStep extends LitElement {
  static properties = {
    data: { type: Object },
    selectedLayout: { type: String },
    testInput: { type: String },
  };

  static styles = css`
    :host {
      display: block;
    }

    .keyboard-container {
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

    .test-area {
      margin-top: 32px;
      padding: 24px;
      background: #f8f9fa;
      border-radius: 8px;
    }

    .test-area h3 {
      margin-bottom: 12px;
      color: #333;
    }

    input[type="text"] {
      width: 100%;
      padding: 12px 16px;
      font-size: 14px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
    }

    input[type="text"]:focus {
      outline: none;
      border-color: #667eea;
    }

    .description {
      font-size: 14px;
      color: #666;
      margin-top: 4px;
    }
  `;

  constructor() {
    super();
    this.selectedLayout = 'us';
    this.testInput = '';
  }

  connectedCallback() {
    super.connectedCallback();
    // Notify parent of initial value
    this.notifyParent();
  }

  notifyParent() {
    this.dispatchEvent(new CustomEvent('data-changed', {
      bubbles: true,
      composed: true,
      detail: {
        keymap: this.selectedLayout,
        vconsole: this.selectedLayout,
      }
    }));
  }

  render() {
    return html`
      <div class="keyboard-container">
        <h2>Keyboard Layout</h2>

        <div class="form-group">
          <label for="layout">Keyboard Layout</label>
          <dropdown-select
            .options=${[
              { value: 'us', label: 'English (US)' },
              { value: 'uk', label: 'English (UK)' },
              { value: 'de', label: 'German' },
              { value: 'fr', label: 'French' },
              { value: 'es', label: 'Spanish' },
              { value: 'it', label: 'Italian' },
              { value: 'pt', label: 'Portuguese' },
              { value: 'ru', label: 'Russian' },
              { value: 'jp', label: 'Japanese' },
              { value: 'dvorak', label: 'Dvorak' },
              { value: 'colemak', label: 'Colemak' },
            ]}
            .value=${this.selectedLayout || 'us'}
            @change=${(e) => {
              this.selectedLayout = e.detail.value;
              this.notifyParent();
            }}
          ></dropdown-select>
          <div class="description">
            Select your keyboard layout for the console and desktop
          </div>
        </div>

        <div class="test-area">
          <h3>Test Your Keyboard</h3>
          <input
            type="text"
            placeholder="Type here to test your keyboard layout..."
            @input="${(e) => this.testInput = e.target.value}"
            .value="${this.testInput}"
          />
          <div class="description">
            Test special characters: @ # $ % ^ & * ( ) - _ = +
          </div>
        </div>
      </div>
    `;
  }
}

customElements.define('keyboard-step', KeyboardStep);
