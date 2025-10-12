import { LitElement, html, css } from 'lit';
import './components/installer-app.js';

class HomeFreeInstaller extends LitElement {
  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
    }
  `;

  render() {
    return html`<installer-app></installer-app>`;
  }
}

customElements.define('homefree-installer', HomeFreeInstaller);

// Mount the app after custom elements are defined
customElements.whenDefined('installer-app').then(() => {
  const app = document.getElementById('app');
  app.innerHTML = '<homefree-installer></homefree-installer>';
});
