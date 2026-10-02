/* ============================================================================
   useConsoleData — the shared queries the shell and several pages read. Every
   caller uses the same query keys, so the rail badges, Overview, and the
   palette share one cache entry and one request per resource.
   ========================================================================== */
import { useMemo } from 'react';
import { useManagementQuery } from './useManagementQuery';
import { pluckArray } from './apiClient';
import type { AuthFile, ModelCatalogEntry, ModelRoutingResponse } from './types';

export function useAuthFiles() {
  const q = useManagementQuery<{ files: AuthFile[] | null }>('/auth-files', { refetchInterval: 30_000 });
  return { ...q, files: pluckArray<AuthFile>(q.data, 'files').filter((f) => f && f.name && !f.name.split(/[\\/]/).pop()?.startsWith('.')) };
}

export function useRouting() {
  const q = useManagementQuery<ModelRoutingResponse>('/routing/models', { refetchInterval: 30_000 });
  // Kiro reaches the backend as a claude-api-key bridge (see ConfigComposer.swift),
  // so the backend reports its models as "claude". They are Kiro's.
  const data = useMemo(
    () =>
      q.data && {
        ...q.data,
        models: pluckArray<ModelCatalogEntry>(q.data, 'models').map((m) => (m.id.startsWith('kiro/') ? { ...m, providers: ['kiro'] } : m)),
      },
    [q.data],
  );
  return { ...q, data } as typeof q;
}

export function useAccessKeys() {
  const q = useManagementQuery<{ 'api-keys': string[] | null }>('/api-keys');
  return { ...q, keys: pluckArray<string>(q.data, 'api-keys') };
}
