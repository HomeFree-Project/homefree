import { LitElement, html, css } from 'lit';
import { geocodeAddress, ipGeolocate } from '../../api/client.js';

/**
 * Latitude / Longitude picker.
 *
 * Two number inputs plus two prefill helpers:
 *   - "Use my IP"  → calls https://ipapi.co/json/ from the browser
 *   - "From address" → expands an inline search box that proxies to
 *                       OpenStreetMap Nominatim through the backend
 *
 * Emits `change` events with detail { latitude, longitude } whenever
 * either input changes (manually or via a prefill helper). Parents
 * bind the two values into wherever the rest of the form expects them.
 *
 * Used by both the installer Location step and the admin System page,
 * so any UX change to lat/lng entry lives here once.
 */
class LatLngPicker extends LitElement {
  static properties = {
    latitude: { type: Number },
    longitude: { type: Number },
    addressOpen: { type: Boolean, state: true },
    addressQuery: { type: String, state: true },
    addressResults: { type: Array, state: true },
    busy: { type: String, state: true },     // "ip" | "geocode" | ""
    error: { type: String, state: true },
  };

  static styles = css`
    :host { display: block; }

    .row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
    }

    .field {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    label {
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text);
    }

    input[type="number"] {
      padding: 9px 12px;
      font-size: 13px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-bg);
      color: var(--hf-text);
      font-family: inherit;
    }

    .helpers {
      display: flex;
      gap: 8px;
      margin-top: 10px;
      flex-wrap: wrap;
    }

    button.helper {
      padding: 6px 12px;
      font-size: 12px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface);
      color: var(--hf-text);
      border-radius: 6px;
      cursor: pointer;
    }

    button.helper:hover { background: var(--hf-surface-2); }
    button.helper:disabled { opacity: 0.5; cursor: wait; }

    .geocode-panel {
      margin-top: 12px;
      padding: 12px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-surface);
    }

    .geocode-panel input[type="text"] {
      width: 100%;
      padding: 8px 10px;
      font-size: 13px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-bg);
      color: var(--hf-text);
      box-sizing: border-box;
    }

    ul.results {
      list-style: none;
      margin: 8px 0 0 0;
      padding: 0;
      max-height: 200px;
      overflow-y: auto;
    }

    li.result {
      padding: 8px 10px;
      font-size: 13px;
      cursor: pointer;
      border-radius: 4px;
    }

    li.result:hover { background: var(--hf-surface-2); }

    .error {
      color: var(--hf-err);
      font-size: 12px;
      margin-top: 6px;
    }

    .muted {
      color: var(--hf-text-muted);
      font-size: 12px;
      margin-top: 6px;
    }
  `;

  constructor() {
    super();
    this.latitude = null;
    this.longitude = null;
    this.addressOpen = false;
    this.addressQuery = '';
    this.addressResults = [];
    this.busy = '';
    this.error = '';
    this._geocodeTimer = null;
  }

  _emitChange() {
    this.dispatchEvent(new CustomEvent('change', {
      bubbles: true,
      composed: true,
      detail: { latitude: this.latitude, longitude: this.longitude },
    }));
  }

  _onLatInput(e) {
    const v = e.target.value;
    this.latitude = v === '' ? null : parseFloat(v);
    this._emitChange();
  }

  _onLngInput(e) {
    const v = e.target.value;
    this.longitude = v === '' ? null : parseFloat(v);
    this._emitChange();
  }

  async _useMyIp() {
    this.error = '';
    this.busy = 'ip';
    try {
      const r = await ipGeolocate();
      if (typeof r.latitude === 'number' && typeof r.longitude === 'number') {
        this.latitude = r.latitude;
        this.longitude = r.longitude;
        this._emitChange();
      } else {
        this.error = 'IP lookup returned no coordinates.';
      }
    } catch (e) {
      this.error = `IP lookup failed: ${e.message || e}`;
    } finally {
      this.busy = '';
    }
  }

  _toggleAddress() {
    this.addressOpen = !this.addressOpen;
    if (!this.addressOpen) {
      this.addressQuery = '';
      this.addressResults = [];
    }
  }

  _onAddressInput(e) {
    this.addressQuery = e.target.value;
    if (this._geocodeTimer) clearTimeout(this._geocodeTimer);
    this._geocodeTimer = setTimeout(() => this._runGeocode(), 600);
  }

  async _runGeocode() {
    const q = this.addressQuery.trim();
    if (q.length < 3) {
      this.addressResults = [];
      return;
    }
    this.error = '';
    this.busy = 'geocode';
    try {
      this.addressResults = await geocodeAddress(q);
    } catch (e) {
      this.error = `Geocoding failed: ${e.message || e}`;
      this.addressResults = [];
    } finally {
      this.busy = '';
    }
  }

  _pickResult(hit) {
    this.latitude = hit.lat;
    this.longitude = hit.lon;
    this.addressOpen = false;
    this.addressQuery = '';
    this.addressResults = [];
    this._emitChange();
  }

  render() {
    return html`
      <div class="row">
        <div class="field">
          <label>Latitude</label>
          <input
            type="number"
            step="any"
            placeholder="e.g. 37.7749"
            .value=${this.latitude == null ? '' : String(this.latitude)}
            @input=${this._onLatInput}
          />
        </div>
        <div class="field">
          <label>Longitude</label>
          <input
            type="number"
            step="any"
            placeholder="e.g. -122.4194"
            .value=${this.longitude == null ? '' : String(this.longitude)}
            @input=${this._onLngInput}
          />
        </div>
      </div>

      <div class="helpers">
        <button
          class="helper"
          type="button"
          ?disabled=${this.busy === 'ip'}
          @click=${this._useMyIp}
        >${this.busy === 'ip' ? 'Looking up…' : 'Use my IP'}</button>
        <button
          class="helper"
          type="button"
          @click=${this._toggleAddress}
        >${this.addressOpen ? 'Cancel address search' : 'From address'}</button>
      </div>

      ${this.addressOpen ? html`
        <div class="geocode-panel">
          <input
            type="text"
            placeholder="Type a city or full address…"
            .value=${this.addressQuery}
            @input=${this._onAddressInput}
          />
          ${this.busy === 'geocode'
            ? html`<div class="muted">Searching…</div>`
            : (this.addressResults.length
              ? html`
                <ul class="results">
                  ${this.addressResults.map(hit => html`
                    <li class="result" @click=${() => this._pickResult(hit)}>
                      ${hit.display_name}
                    </li>
                  `)}
                </ul>`
              : (this.addressQuery.trim().length >= 3
                ? html`<div class="muted">No matches.</div>`
                : html`<div class="muted">Type at least 3 characters.</div>`))}
        </div>
      ` : ''}

      ${this.error ? html`<div class="error">${this.error}</div>` : ''}
    `;
  }
}

customElements.define('lat-lng-picker', LatLngPicker);
