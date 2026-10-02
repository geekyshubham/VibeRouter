/* ============================================================================
   useUsageDaily — one day's usage report.

   The TopBar picker and the Overview breakdown both call this with the same day,
   and useManagementQuery keys on the path, so they share a single cache entry and
   a single network request rather than each fetching their own copy.

   The response carries both the day's totals and the available-day bounds
   (earliestDay / latestDay / availableDays), which is why the picker does not
   need a separate index request.
   ========================================================================== */
import type { UseQueryResult } from '@tanstack/react-query';
import { useManagementQuery } from './useManagementQuery';
import type { UsageDailyResponse } from './types';

export function useUsageDaily(day: string): UseQueryResult<UsageDailyResponse> {
  // encodeURIComponent so a malformed day can never smuggle extra query params
  // into the request; the server validates the format regardless.
  return useManagementQuery<UsageDailyResponse>(`/usage-daily?date=${encodeURIComponent(day)}`, {
    enabled: Boolean(day),
    refetchInterval: 30_000,
  });
}
