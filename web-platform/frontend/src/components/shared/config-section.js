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
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      overflow: hidden;
    }

    .section-header {
      padding: 18px 24px;
      border-bottom: 1px solid var(--hf-border);
      cursor: default;
    }

    .section-header.collapsible {
      cursor: pointer;
      user-select: none;
      transition: background 0.15s;
    }

    .section-header.collapsible:hover {
      background: var(--hf-surface-2);
    }

    .section-header-content {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }

    /* Right cluster: optional caller-provided actions (via slot="actions") and
       the collapse icon. Actions click must not toggle a collapsible section. */
    .section-header-right {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .section-header-actions {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .section-title {
      margin: 0;
      font-size: 16px;
      font-weight: 600;
      color: var(--hf-text);
      letter-spacing: -0.005em;
    }

    .section-description {
      margin: 6px 0 0 0;
      font-size: 13px;
      color: var(--hf-text-muted);
    }

    .collapse-icon {
      font-size: 18px;
      color: var(--hf-text-muted);
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

    @media (max-width: 640px) {
      .section-header { padding: 14px 16px; }
      .section-header-content {
        flex-direction: column;
        align-items: stretch;
        gap: 12px;
      }
      .section-header-right { justify-content: flex-start; }
      .section-header-actions { flex-wrap: wrap; }
      .section-content { padding: 16px; }
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
            <div class="section-header-right">
              <span class="section-header-actions"
                    @click=${(e) => e.stopPropagation()}>
                <slot name="actions"></slot>
              </span>
              ${this.collapsible ? html`
                <span class="collapse-icon ${this.collapsed ? 'collapsed' : ''}">
                  ▼
                </span>
              ` : ''}
            </div>
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
