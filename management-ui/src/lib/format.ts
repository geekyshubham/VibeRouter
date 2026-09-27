/* ============================================================================
   format — small pure display helpers. No React, no side effects.
   ========================================================================== */

/** Relative "time ago" for ISO timestamps; falls back to '—'. */
export function timeAgo(iso: string | undefined | null): string {
  if (!iso) return '—';
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return '—';
  const secs = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

/** "1 account" / "3 accounts". */
export function plural(n: number, one: string, many = `${one}s`): string {
  return `${num(n)} ${n === 1 ? one : many}`;
}

/** Human byte size. */
export function bytes(n: number | undefined | null): string {
  if (!n || n < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

/** Mask a secret, showing only the last few chars. */
export function maskKey(key: string | undefined | null, tail = 4): string {
  if (!key) return '';
  if (key.length <= tail) return '••••';
  return `••••${key.slice(-tail)}`;
}

/** Compact integer with thousands separators. */
export function num(n: number | undefined | null): string {
  if (n == null || Number.isNaN(n)) return '0';
  return n.toLocaleString('en-US');
}

/* ------------------------------------------------------- USAGE MAGNITUDES */

/* These mirror src/Sources/UsageNumberFormatter.swift tier-for-tier so the same
   number never reads "3100.0M" in one surface and "3.1B" in the other. Any change
   here needs the same change there (and UsageNumberFormatterSpec.swift covers the
   Swift side's edge cases). */

/** Descending, so the first threshold a value clears is the one used. */
const TIERS: ReadonlyArray<{ threshold: number; suffix: string }> = [
  { threshold: 1e12, suffix: 'T' },
  { threshold: 1e9, suffix: 'B' },
  { threshold: 1e6, suffix: 'M' },
  { threshold: 1e3, suffix: 'K' },
];

/** One decimal below 100 (4.2M, 42.5M), none above (421M) — and never a bare
 *  trailing ".0", so an exact million reads "1M" rather than "1.0M". */
function trimmed(value: number): string {
  const text = value < 100 ? value.toFixed(1) : value.toFixed(0);
  return text.endsWith('.0') ? text.slice(0, -2) : text;
}

/** Picks the largest tier the value clears and renders ~3 significant digits. */
function scaled(value: number): string {
  const magnitude = Math.abs(value);
  const sign = value < 0 ? '-' : '';

  for (let i = 0; i < TIERS.length; i++) {
    const tier = TIERS[i];
    if (magnitude < tier.threshold) continue;
    // Rounding can push a value into four digits (999,951 tokens → "1000K").
    // Promote to the next tier so it reads "1M" instead.
    let chosen = tier;
    let value_ = magnitude / tier.threshold;
    if (value_ >= 999.5 && i > 0) {
      chosen = TIERS[i - 1];
      value_ = magnitude / chosen.threshold;
    }
    return sign + trimmed(value_) + chosen.suffix;
  }

  return sign + magnitude.toFixed(0);
}

/** Compact count that scales up *and* down: "0", "950", "12.4K", "4.2M", "3.1B". */
export function tokens(count: number | undefined | null): string {
  if (count == null || Number.isNaN(count)) return '0';
  return scaled(count);
}

/** Cost in USD: cents-precise where cents matter, scaled once they don't.
 *  "<$0.01", "$0.42", "$18.40", "$1.2K", "$3.4M". */
export function usd(value: number | undefined | null): string {
  if (value == null || Number.isNaN(value)) return '$0.00';
  const magnitude = Math.abs(value);
  const sign = value < 0 ? '-' : '';
  if (magnitude === 0) return '$0.00';
  // Below a cent still means "you spent something", so don't render "$0.00".
  if (magnitude < 0.01) return `${sign}<$0.01`;
  if (magnitude < 1000) return `${sign}$${magnitude.toFixed(2)}`;
  return `${sign}$${scaled(magnitude)}`;
}

/** Kiro plan credits, stored as millicredits for sub-credit precision.
 *  Keeps two decimals below 1 credit so a fractional spend never shows as "0". */
export function credits(millicredits: number | undefined | null): string {
  if (millicredits == null || Number.isNaN(millicredits)) return '0 cr';
  const value = millicredits / 1000;
  if (value >= 1000) return `${scaled(value)} cr`;
  if (value >= 10) return `${value.toFixed(0)} cr`;
  if (value >= 1) return `${value.toFixed(1)} cr`;
  if (value > 0) return `${value.toFixed(2)} cr`;
  return '0 cr';
}

/** Volume in the provider's own unit. Kiro reports millicredits (credits × 1000),
 *  which must never be summed into, or labelled as, tokens. */
export function volume(count: number | undefined | null, unit: string | undefined): string {
  switch (unit) {
    case 'credits':
      return credits(count);
    case 'estimatedTokens':
      return `${tokens(count)} est`;
    default:
      return tokens(count);
  }
}

/* ------------------------------------------------------------- DAY KEYS */

/** Today as YYYY-MM-DD in the *browser's* timezone.
 *  Deliberately not toISOString(): that is UTC and would report the wrong day
 *  for anyone east or west of it, disagreeing with the local-time day keys the
 *  macOS app writes. */
export function todayKey(): string {
  const now = new Date();
  const month = `${now.getMonth() + 1}`.padStart(2, '0');
  const day = `${now.getDate()}`.padStart(2, '0');
  return `${now.getFullYear()}-${month}-${day}`;
}

/** "Today" / "Yesterday" / "Mon, 14 Jul 2026" for a YYYY-MM-DD key. */
export function dayLabel(key: string | undefined | null): string {
  if (!key) return '—';
  if (key === todayKey()) return 'Today';
  const parts = key.split('-').map(Number);
  if (parts.length !== 3 || parts.some(Number.isNaN)) return key;
  // Construct in local time (the Date(y, m, d) form) to stay on the same calendar
  // day the key names.
  const date = new Date(parts[0], parts[1] - 1, parts[2]);
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  if (
    date.getFullYear() === yesterday.getFullYear() &&
    date.getMonth() === yesterday.getMonth() &&
    date.getDate() === yesterday.getDate()
  ) {
    return 'Yesterday';
  }
  return date.toLocaleDateString('en-US', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  });
}
