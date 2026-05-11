/**
 * Password policy used everywhere a password is entered in the
 * HomeFree UI (installer admin setup, admin Users page).
 *
 * Mirrors Zitadel's default password complexity policy:
 *   minLength: 8
 *   hasUppercase, hasLowercase, hasNumber, hasSymbol: all true
 *
 * Plus the Linux-side rule from the installer (no control chars,
 * max 128 chars) because the installer hands the password to
 * mkpasswd/chpasswd for the OS account, and a control char (newline,
 * tab) silently corrupts those paths.
 *
 * Returns { ok, error, strength: 0..4 }:
 *   strength is a coarse score for the UI bar:
 *     0 = empty
 *     1 = below 8 chars
 *     2 = meets length but missing classes
 *     3 = all classes satisfied
 *     4 = all classes + length >= 12
 *
 * Keep this in sync with the backend's validate_password in
 * web-platform/backend/resolvers/config.py.
 */
export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 128;

export function validatePassword(pw) {
  if (!pw) return { ok: false, error: '', strength: 0 };

  if (/[\x00-\x1F\x7F]/.test(pw)) {
    return {
      ok: false,
      strength: 0,
      error:
        'Password contains a control character (newline, tab, etc.) ' +
        'that cannot be used as a Linux password.',
    };
  }
  if (pw.length > PASSWORD_MAX_LENGTH) {
    return {
      ok: false,
      strength: 0,
      error: `Password must be at most ${PASSWORD_MAX_LENGTH} characters.`,
    };
  }
  if (pw.length < PASSWORD_MIN_LENGTH) {
    return {
      ok: false,
      strength: 1,
      error: `Password must be at least ${PASSWORD_MIN_LENGTH} characters.`,
    };
  }

  const hasUpper = /[A-Z]/.test(pw);
  const hasLower = /[a-z]/.test(pw);
  const hasNumber = /[0-9]/.test(pw);
  const hasSymbol = /[^A-Za-z0-9]/.test(pw);

  const missing = [];
  if (!hasUpper) missing.push('an uppercase letter');
  if (!hasLower) missing.push('a lowercase letter');
  if (!hasNumber) missing.push('a number');
  if (!hasSymbol) missing.push('a symbol');

  if (missing.length > 0) {
    return {
      ok: false,
      strength: 2,
      error: `Password must include ${missing.join(', ')}.`,
    };
  }

  return {
    ok: true,
    strength: pw.length >= 12 ? 4 : 3,
    error: '',
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
