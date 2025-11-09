import { LitElement, html, css } from 'lit';

/**
 * Configuration section container
 * Provides consistent styling for config sections
 */
class ConfigSection extends LitElement {
  static properties = {
    title: { type: String },
    description: { type: String },
    collapsible: { type: Boolean },
    collapsed: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
      margin-bottom: 24px;
    }

    .section {
      background: white;
      border-radius: 12px;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
      overflow: hidden;
    }

    .section-header {
      padding: 20px 24px;
      border-bottom: 1px solid #f5f5f7;
      cursor: default;
    }

    .section-header.collapsible {
      cursor: pointer;
      user-select: none;
      transition: background 0.2s;
    }

    .section-header.collapsible:hover {
      background: #fafafa;
    }

    .section-header-content {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .section-title {
      margin: 0;
      font-size: 18px;
      font-weight: 600;
      color: #1d1d1f;
    }

    .section-description {
      margin: 6px 0 0 0;
      font-size: 14px;
      color: #86868b;
    }

    .collapse-icon {
      font-size: 20px;
      color: #86868b;
      transition: transform 0.3s;
    }

    .collapse-icon.collapsed {
      transform: rotate(-90deg);
    }

    .section-content {
      padding: 24px;
    }

    .section-content.collapsed {
      display: none;
    }
  `;

  constructor() {
    super();
    this.title = '';
    this.description = '';
    this.collapsible = false;
    this.collapsed = false;
  }

  toggleCollapse() {
    if (this.collapsible) {
      this.collapsed = !this.collapsed;
    }
  }

  render() {
    return html`
      <div class="section">
        <div
          class="section-header ${this.collapsible ? 'collapsible' : ''}"
          @click=${this.toggleCollapse}
        >
          <div class="section-header-content">
            <div>
              <h2 class="section-title">${this.title}</h2>
              ${this.description ? html`
                <p class="section-description">${this.description}</p>
              ` : ''}
            </div>
            ${this.collapsible ? html`
              <span class="collapse-icon ${this.collapsed ? 'collapsed' : ''}">
                ▼
              </span>
            ` : ''}
          </div>
        </div>

        <div class="section-content ${this.collapsed ? 'collapsed' : ''}">
          <slot></slot>
        </div>
      </div>
    `;
  }
}

customElements.define('config-section', ConfigSection);
