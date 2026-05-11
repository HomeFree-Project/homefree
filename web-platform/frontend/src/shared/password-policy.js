/**
 * Password policy used everywhere a password is entered in the
 * HomeFree UI (installer admin setup, admin Users page).
 *
 * Source of truth: Zitadel's password complexity policy, exposed at
 * GET /api/sso/password-policy via the FastAPI backend. The static
 * DEFAULT_POLICY here matches Zitadel's defaults so the installer
 * (which runs before Zitadel exists) and any offline UI can fall
 * back to something sensible.
 *
 * Plus the Linux-side rule from the installer (no control chars,
 * max 128 chars) because the installer hands the password to
 * mkpasswd/chpasswd for the OS account, and a control char (newline,
 * tab) silently corrupts those paths.
 *
 * The validator returns a per-requirement breakdown so the UI can
 * show users exactly what's missing, not just "password invalid".
 */

export const DEFAULT_POLICY = {
  min_length: 8,
  max_length: 128,
  has_uppercase: true,
  has_lowercase: true,
  has_number: true,
  has_symbol: true,
  source: 'fallback',
};

let _policyPromise = null;

/** Fetch the live Zitadel policy. Cached per page-load so the
 *  /api/sso/password-policy call only happens once. Returns the
 *  fallback synchronously-on-error to keep callers simple. */
export async function loadPasswordPolicy() {
  if (!_policyPromise) {
    _policyPromise = fetch('/api/sso/password-policy')
      .then(r => r.ok ? r.json() : DEFAULT_POLICY)
      .catch(() => DEFAULT_POLICY);
  }
  return _policyPromise;
}

/**
 * Build the list of per-requirement checks for a candidate password
 * against a given policy.
 *
 * Returns an array of:
 *   { id, label, satisfied: boolean }
 *
 * The label is plain English and is meant to be displayed to the
 * user verbatim ("At least 8 characters", "An uppercase letter", …).
 * Each entry's id is stable so the UI can `repeat`-render with keys.
 */
export function passwordRequirements(pw, policy = DEFAULT_POLICY) {
  const reqs = [
    {
      id: 'length',
      label: `At least ${policy.min_length} characters`,
      satisfied: pw.length >= policy.min_length,
    },
  ];
  if (policy.has_uppercase) {
    reqs.push({
      id: 'upper',
      label: 'An uppercase letter (A-Z)',
      satisfied: /[A-Z]/.test(pw),
    });
  }
  if (policy.has_lowercase) {
    reqs.push({
      id: 'lower',
      label: 'A lowercase letter (a-z)',
      satisfied: /[a-z]/.test(pw),
    });
  }
  if (policy.has_number) {
    reqs.push({
      id: 'number',
      label: 'A number (0-9)',
      satisfied: /[0-9]/.test(pw),
    });
  }
  if (policy.has_symbol) {
    reqs.push({
      id: 'symbol',
      label: 'A symbol (e.g. !@#$%^&*)',
      satisfied: /[^A-Za-z0-9]/.test(pw),
    });
  }
  return reqs;
}

/**
 * Validate a password against the policy (Linux constraints +
 * Zitadel's complexity rules). Returns:
 *   { ok, error, strength: 0..4, requirements }
 *
 * `strength` is a coarse score for the meter:
 *   0 = empty
 *   1 = below min length
 *   2 = meets length but at least one class missing
 *   3 = all classes satisfied
 *   4 = all classes + length >= 12
 *
 * If the password is empty we return ok=false with a specific
 * "Password is required" error so callers can show something
 * sensible instead of "does not meet requirements".
 */
export function validatePassword(pw, policy = DEFAULT_POLICY) {
  const requirements = passwordRequirements(pw || '', policy);

  if (!pw) {
    return {
      ok: false,
      error: 'Password is required.',
      strength: 0,
      requirements,
    };
  }
  if (/[\x00-\x1F\x7F]/.test(pw)) {
    return {
      ok: false,
      strength: 0,
      error:
        'Password contains a control character (newline, tab, etc.) ' +
        'that cannot be used as a Linux password.',
      requirements,
    };
  }
  if (pw.length > policy.max_length) {
    return {
      ok: false,
      strength: 0,
      error: `Password must be at most ${policy.max_length} characters.`,
      requirements,
    };
  }

  const unmet = requirements.filter(r => !r.satisfied);
  if (unmet.length > 0) {
    const missing = unmet.map(r => r.label.toLowerCase()).join('; ');
    return {
      ok: false,
      strength: pw.length < policy.min_length ? 1 : 2,
      error: `Missing: ${missing}.`,
      requirements,
    };
  }

  return {
    ok: true,
    strength: pw.length >= 12 ? 4 : 3,
    error: '',
    requirements,
  };
}

/** Map a strength score to a width % and CSS color used by the bar. */
export function strengthBar(strength) {
  switch (strength) {
    case 0: return { width: '0%',   color: 'transparent', label: '' };
    case 1: return { width: '25%',  color: '#f44336',     label: 'Too short' };
    case 2: return { width: '50%',  color: '#ff9800',     label: 'Weak' };
    case 3: return { width: '75%',  color: '#7cb342',     label: 'Good' };
    case 4: return { width: '100%', color: '#4caf50',     label: 'Strong' };
    default: return { width: '0%',  color: 'transparent', label: '' };
  }
}

/** Plain-English summary of the policy. Used as a static hint
 *  above the password field if the parent doesn't want to render
 *  the live requirement checklist. */
export function policySummary(policy = DEFAULT_POLICY) {
  const parts = [`at least ${policy.min_length} characters`];
  if (policy.has_uppercase) parts.push('uppercase');
  if (policy.has_lowercase) parts.push('lowercase');
  if (policy.has_number) parts.push('a number');
  if (policy.has_symbol) parts.push('a symbol');
  return `Must include ${parts.join(', ')}.`;
}
