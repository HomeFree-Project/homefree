import { LitElement, html, css } from 'lit';
import {
  getTimezones, getLocales, getCountries, getCurrencies, getLanguages,
  setLocation, lookupElevation,
} from '../api/client.js';
import './shared/dropdown-select.js';
import './shared/lat-lng-picker.js';

/**
 * Installer "Location & Region" step.
 *
 * Required (always visible): timezone, locale, country.
 * Optional (collapsed under "Advanced"): latitude, longitude,
 * elevation, unit system, currency, UI language.
 *
 * All dropdown lists come from the backend (zoneinfo for timezones,
 * babel for the rest) so the picker is the same on the installer and
 * the admin System page.
 */
class LocationStep extends LitElement {
  static properties = {
    data: { type: Object },
    timezones: { type: Array },
    locales: { type: Array },
    countries: { type: Array },
    currencies: { type: Array },
    languages: { type: Array },
    selectedTimezone: { type: String },
    selectedLocale: { type: String },
    selectedCountry: { type: String },
    selectedLanguage: { type: String },
    selectedCurrency: { type: String },
    selectedUnitSystem: { type: String },
    elevation: { type: Number },
    latitude: { type: Number },
    longitude: { type: Number },
    advancedOpen: { type: Boolean, state: true },
    elevationLookupBusy: { type: Boolean, state: true },
    elevationLookupError: { type: String, state: true },
    loading: { type: Boolean },
    error: { type: String },
  };

  static styles = css`
    :host { display: block; }

    .location-container {
      max-width: 700px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 24px;
    }

    .form-group { margin-bottom: 24px; }

    label {
      display: block;
      margin-bottom: 8px;
      font-weight: 500;
      color: #333;
    }

    input[type="number"] {
      width: 100%;
      padding: 12px 16px;
      font-size: 14px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
      box-sizing: border-box;
    }

    .description {
      font-size: 13px;
      color: #666;
      margin-top: 4px;
    }

    details.advanced {
      margin-top: 16px;
      border: 1px solid #e0e0e0;
      border-radius: 6px;
      padding: 0;
      overflow: hidden;
    }

    details.advanced > summary {
      padding: 14px 18px;
      cursor: pointer;
      font-weight: 500;
      color: #333;
      user-select: none;
      list-style: none;
      background: #fafafa;
    }

    details.advanced > summary::after {
      content: '▾';
      float: right;
      transition: transform 0.15s;
    }

    details.advanced[open] > summary::after {
      transform: rotate(180deg);
    }

    .advanced-body {
      padding: 18px;
      border-top: 1px solid #e0e0e0;
    }

    .field-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
    }

    @media (max-width: 600px) {
      .field-row { grid-template-columns: 1fr; }
    }

    .info-box {
      background: #e3f2fd;
      border: 1px solid #2196f3;
      border-radius: 6px;
      padding: 16px;
      margin-top: 24px;
      color: #1565c0;
      font-size: 13px;
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
    this.locales = [];
    this.countries = [];
    this.currencies = [];
    this.languages = [];
    this.selectedTimezone = 'America/Los_Angeles';
    this.selectedLocale = 'en_US.UTF-8';
    this.selectedCountry = '';
    this.selectedLanguage = '';
    this.selectedCurrency = '';
    this.selectedUnitSystem = 'metric';
    this.elevation = null;
    this.latitude = null;
    this.longitude = null;
    this.advancedOpen = true;
    this.elevationLookupBusy = false;
    this.elevationLookupError = '';
    this.loading = false;
    this.error = '';
  }

  async _lookupElevation() {
    if (typeof this.latitude !== 'number' || typeof this.longitude !== 'number') {
      this.elevationLookupError = 'Set latitude and longitude first.';
      return;
    }
    this.elevationLookupError = '';
    this.elevationLookupBusy = true;
    try {
      this.elevation = await lookupElevation(this.latitude, this.longitude);
      this.notifyParent();
    } catch (e) {
      this.elevationLookupError = `Lookup failed: ${e.message || e}`;
    } finally {
      this.elevationLookupBusy = false;
    }
  }

  async connectedCallback() {
    super.connectedCallback();
    await this._loadLists();
    this.notifyParent();
  }

  async _loadLists() {
    const [tz, loc, ctry, cur, lang] = await Promise.allSettled([
      getTimezones(), getLocales(), getCountries(),
      getCurrencies(), getLanguages(),
    ]);

    if (tz.status === 'fulfilled') {
      // The API returns [{region, zones}, ...]; flatten to a
      // grouped dropdown-select options array (the dropdown
      // understands `{group: 'name'}` separator entries).
      this.timezones = tz.value.flatMap(region => [
        { group: region.region },
        ...region.zones.map(z => ({ value: z, label: z })),
      ]);
    } else {
      this.error = 'Failed to load timezones.';
    }

    if (loc.status === 'fulfilled') this.locales = loc.value;
    if (ctry.status === 'fulfilled') this.countries = ctry.value;
    if (cur.status === 'fulfilled') this.currencies = cur.value;
    if (lang.status === 'fulfilled') this.languages = lang.value;
  }

  notifyParent() {
    const detail = {
      timezone: this.selectedTimezone,
      locale: this.selectedLocale,
      country_code: this.selectedCountry || null,
      language: this.selectedLanguage || null,
      currency: this.selectedCurrency || null,
      unit_system: this.selectedUnitSystem,
      elevation: this.elevation,
      latitude: this.latitude,
      longitude: this.longitude,
    };
    this.dispatchEvent(new CustomEvent('data-changed', {
      bubbles: true,
      composed: true,
      detail,
    }));
    this._debouncedSave(detail);
  }

  _debouncedSave(detail) {
    // Debounce backend writes to avoid POSTing on every keystroke or
    // every dropdown re-render. 500 ms is short enough that the
    // server has fresh data by the time Next is clicked.
    if (this._saveTimer) clearTimeout(this._saveTimer);
    this._saveTimer = setTimeout(() => {
      setLocation(detail.timezone, detail.locale, {
        country_code: detail.country_code,
        language: detail.language,
        currency: detail.currency,
        unit_system: detail.unit_system,
        elevation: detail.elevation,
        latitude: detail.latitude,
        longitude: detail.longitude,
      }).catch((err) => {
        console.warn('setLocation failed:', err);
      });
    }, 500);
  }

  _onCoords(e) {
    this.latitude = e.detail.latitude;
    this.longitude = e.detail.longitude;
    this.notifyParent();
  }

  render() {
    return html`
      <div class="location-container">
        <h2>Location & Region</h2>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="form-group">
          <label for="timezone">Timezone</label>
          <dropdown-select
            .options=${this.timezones}
            .value=${this.selectedTimezone}
            @change=${(e) => {
              this.selectedTimezone = e.detail.value;
              this.notifyParent();
            }}
          ></dropdown-select>
          <div class="description">
            Select your timezone for accurate time settings.
          </div>
        </div>

        <div class="form-group">
          <label for="locale">Language & Locale</label>
          <dropdown-select
            .options=${this.locales}
            .value=${this.selectedLocale}
            placeholder="Select locale..."
            @change=${(e) => {
              this.selectedLocale = e.detail.value;
              this.notifyParent();
            }}
          ></dropdown-select>
          <div class="description">
            This sets the system locale (date, number, and sort formats).
          </div>
        </div>

        <div class="form-group">
          <label for="country">Country</label>
          <dropdown-select
            .options=${this.countries}
            .value=${this.selectedCountry}
            placeholder="Select country..."
            @change=${(e) => {
              this.selectedCountry = e.detail.value;
              this.notifyParent();
            }}
          ></dropdown-select>
          <div class="description">
            Used by Home Assistant and other services for regional defaults.
          </div>
        </div>

        <details class="advanced" ?open=${this.advancedOpen}
          @toggle=${(e) => { this.advancedOpen = e.target.open; }}
        >
          <summary>Advanced (optional)</summary>
          <div class="advanced-body">

            <div class="form-group">
              <label>Geographic coordinates</label>
              <lat-lng-picker
                .latitude=${this.latitude}
                .longitude=${this.longitude}
                @change=${this._onCoords}
              ></lat-lng-picker>
              <div class="description">
                Used by location-aware integrations (Home Assistant sun /
                weather, etc.). Optional — services fall back to the
                country if unset.
              </div>
            </div>

            <div class="field-row">
              <div class="form-group">
                <label for="elevation">Elevation above sea level (meters)</label>
                <input
                  type="number"
                  placeholder="0"
                  .value=${this.elevation == null ? '' : String(this.elevation)}
                  @input=${(e) => {
                    const v = e.target.value;
                    this.elevation = v === '' ? null : parseInt(v, 10);
                    this.notifyParent();
                  }}
                />
                <button
                  type="button"
                  style="margin-top: 8px; padding: 6px 12px; font-size: 12px; border: 1px solid #e0e0e0; background: white; color: #333; border-radius: 6px; cursor: pointer;"
                  ?disabled=${this.elevationLookupBusy ||
                              typeof this.latitude !== 'number' ||
                              typeof this.longitude !== 'number'}
                  @click=${this._lookupElevation}
                >${this.elevationLookupBusy ? 'Looking up…' : 'Look up from coords'}</button>
                ${this.elevationLookupError
                  ? html`<div style="color: #c62828; font-size: 12px; margin-top: 6px;">${this.elevationLookupError}</div>`
                  : ''}
              </div>

              <div class="form-group">
                <label for="unit">Unit system</label>
                <dropdown-select
                  .options=${[
                    { value: 'metric', label: 'Metric' },
                    { value: 'us_customary', label: 'US Customary (Imperial)' },
                  ]}
                  .value=${this.selectedUnitSystem}
                  @change=${(e) => {
                    this.selectedUnitSystem = e.detail.value;
                    this.notifyParent();
                  }}
                ></dropdown-select>
              </div>
            </div>

            <div class="field-row">
              <div class="form-group">
                <label for="currency">Currency</label>
                <dropdown-select
                  .options=${this.currencies}
                  .value=${this.selectedCurrency}
                  placeholder="Select currency..."
                  @change=${(e) => {
                    this.selectedCurrency = e.detail.value;
                    this.notifyParent();
                  }}
                ></dropdown-select>
              </div>

              <div class="form-group">
                <label for="language">UI Language</label>
                <dropdown-select
                  .options=${this.languages}
                  .value=${this.selectedLanguage}
                  placeholder="Select language..."
                  @change=${(e) => {
                    this.selectedLanguage = e.detail.value;
                    this.notifyParent();
                  }}
                ></dropdown-select>
              </div>
            </div>

          </div>
        </details>

        <div class="info-box">
          <strong>ℹ️ Note:</strong>
          All of these settings can be changed later from the admin
          System page.
        </div>
      </div>
    `;
  }
}

customElements.define('location-step', LocationStep);
