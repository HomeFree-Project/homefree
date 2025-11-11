import { LitElement, html, css } from 'lit';

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
          <select
            id="layout"
            @change="${(e) => {
              this.selectedLayout = e.target.value;
              this.notifyParent();
            }}"
          >
            <option value="us" selected>English (US)</option>
            <option value="uk">English (UK)</option>
            <option value="de">German</option>
            <option value="fr">French</option>
            <option value="es">Spanish</option>
            <option value="it">Italian</option>
            <option value="pt">Portuguese</option>
            <option value="ru">Russian</option>
            <option value="jp">Japanese</option>
            <option value="dvorak">Dvorak</option>
            <option value="colemak">Colemak</option>
          </select>
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
