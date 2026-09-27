/* ============================================================================
   health — one definition of "is this account OK", shared by the sidebar,
   Overview, and Accounts so the three never disagree, plus normalization of
   the per-account request windows (recent_requests).
   ========================================================================== */
import { asArray } from './apiClient';
import type { AuthFile, RecentRequestBucket } from './types';

export type AccountState = 'active' | 'issue' | 'disabled';

export function accountState(file: AuthFile): AccountState {
  if (file.disabled) return 'disabled';
  if (file.unavailable || file.status?.toLowerCase() === 'error') return 'issue';
  return 'active';
}

export const STATE_LABEL: Record<AccountState, string> = {
  active: 'Active',
  issue: 'Needs attention',
  disabled: 'Disabled',
};

/** Pill tone per state. Never color alone: every pill also carries its label. */
export const STATE_TONE: Record<AccountState, 'ok' | 'warn' | 'mut'> = {
  active: 'ok',
  issue: 'warn',
  disabled: 'mut',
};

/** recent_requests as buckets. Older backends sent bare numbers (treated as
 *  successes); anything malformed becomes an empty bucket rather than NaN. */
export function requestBuckets(values: unknown): RecentRequestBucket[] {
  return asArray<unknown>(values).map((v) => {
    if (typeof v === 'number' && Number.isFinite(v)) return { time: '', success: v, failed: 0 };
    if (v && typeof v === 'object') {
      const b = v as Partial<RecentRequestBucket>;
      return {
        time: typeof b.time === 'string' ? b.time : '',
        success: Number.isFinite(b.success) ? Number(b.success) : 0,
        failed: Number.isFinite(b.failed) ? Number(b.failed) : 0,
      };
    }
    return { time: '', success: 0, failed: 0 };
  });
}

/** Sum every account's windows position-by-position. The backend reports the
 *  same aligned windows for every file, so index i is the same 10 minutes. */
export function mergeBuckets(files: AuthFile[]): RecentRequestBucket[] {
  const merged: RecentRequestBucket[] = [];
  for (const file of files) {
    requestBuckets(file.recent_requests).forEach((b, i) => {
      const slot = merged[i] ?? (merged[i] = { time: b.time, success: 0, failed: 0 });
      if (!slot.time && b.time) slot.time = b.time;
      slot.success += b.success;
      slot.failed += b.failed;
    });
  }
  return merged;
}
