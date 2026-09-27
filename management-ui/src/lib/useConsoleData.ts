/* ============================================================================
   useConsoleData — the shared queries the shell and several pages read. Every
   caller uses the same query keys, so the rail badges, Overview, and the
   palette share one cache entry and one request per resource.
   ========================================================================== */
import { useManagementQuery } from './useManagementQuery';
import { pluckArray } from './apiClient';
import type { AuthFile, ModelRoutingResponse } from './types';

export function useAuthFiles() {
  const q = useManagementQuery<{ files: AuthFile[] | null }>('/auth-files', { refetchInterval: 30_000 });
  return { ...q, files: pluckArray<AuthFile>(q.data, 'files').filter((f) => f && f.name) };
}

export function useRouting() {
  const q = useManagementQuery<ModelRoutingResponse>('/routing/models', { refetchInterval: 30_000 });
  return q;
}

export function useAccessKeys() {
  const q = useManagementQuery<{ 'api-keys': string[] | null }>('/api-keys');
  return { ...q, keys: pluckArray<string>(q.data, 'api-keys') };
}
