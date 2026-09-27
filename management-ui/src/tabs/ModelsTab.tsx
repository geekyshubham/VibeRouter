/* ============================================================================
   ModelsTab — model routing policy:
     - which models may be served at all (disabled-models)
     - the order they are preferred in (model-priority)
     - whether an exhausted model falls back to the next preferred one
   All state lives in GET /routing/models; each change PUTs the full list back
   (the backend normalizes + persists to config.yaml). Changes apply
   optimistically and roll back if the write fails.
   ========================================================================== */
import { useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import apiClient, { asArray, pluckArray } from '../lib/apiClient';
import type { ModelCatalogEntry, ModelRoutingResponse } from '../lib/types';
import { providerMeta } from '../lib/providers';
import { plural } from '../lib/format';
import { useRouting } from '../lib/useConsoleData';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import QueryError from '../components/QueryError';
import ProviderLogo from '../components/ProviderLogo';
import Switch from '../components/Switch';
import { useToast } from '../context/ToastContext';

const KEY = ['mgmt', '/routing/models'];

export default function ModelsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const q = useRouting();
  const [params, setParams] = useSearchParams();
  const [busy, setBusy] = useState(false);
  const [provider, setProvider] = useState('all');
  const search = params.get('q') ?? '';

  const catalog = pluckArray<ModelCatalogEntry>(q.data, 'models');
  const priority = pluckArray<string>(q.data, 'model-priority');
  const failover = Boolean(q.data?.['model-failover']);
  const byID = useMemo(() => new Map(catalog.map((m) => [m.id, m])), [catalog]);

  const providerIds = useMemo(() => {
    const counts = new Map<string, number>();
    catalog.forEach((m) => asArray<string>(m.providers).forEach((p) => counts.set(p, (counts.get(p) ?? 0) + 1)));
    return [...counts.entries()].sort((a, b) => b[1] - a[1]);
  }, [catalog]);

  const needle = search.trim().toLowerCase();
  const matches = (m: { id: string; providers: string[] }) =>
    (!needle || m.id.toLowerCase().includes(needle)) && (provider === 'all' || m.providers.includes(provider));

  const prioritized = priority.map((id) => {
    const e = byID.get(id);
    return { id, providers: asArray<string>(e?.providers), available: e?.available ?? 0, disabled: e?.disabled ?? false, known: Boolean(e) };
  });
  const rest = catalog
    .filter((m) => !priority.includes(m.id))
    .map((m) => ({ id: m.id, providers: asArray<string>(m.providers), available: m.available, disabled: m.disabled, known: true }))
    .filter(matches)
    .sort((a, b) => a.id.localeCompare(b.id));

  const enabledCount = catalog.filter((m) => !m.disabled).length;

  /** Optimistic write: patch the cache, send, roll back + toast on failure. */
  const write = async (patch: (d: ModelRoutingResponse) => ModelRoutingResponse, send: () => Promise<unknown>, fail: string) => {
    const previous = qc.getQueryData<ModelRoutingResponse>(KEY);
    if (previous) qc.setQueryData(KEY, patch(previous));
    setBusy(true);
    try {
      await send();
    } catch {
      qc.setQueryData(KEY, previous);
      toast(fail, 'bad');
    } finally {
      setBusy(false);
      void qc.invalidateQueries({ queryKey: KEY });
    }
  };

  const putPriority = (next: string[]) =>
    write(
      (d) => ({ ...d, 'model-priority': next, models: (d.models ?? []).map((m) => ({ ...m, prioritized: next.includes(m.id) })) }),
      () => apiClient.put('/routing/model-priority', { value: next }),
      "Couldn't save the model order",
    );

  const toggleModel = (id: string, enable: boolean) => {
    const disabled = new Set(catalog.filter((m) => m.disabled).map((m) => m.id));
    if (enable) disabled.delete(id);
    else disabled.add(id);
    return write(
      (d) => ({ ...d, models: (d.models ?? []).map((m) => (m.id === id ? { ...m, disabled: !enable } : m)) }),
      () => apiClient.put('/routing/disabled-models', { value: [...disabled] }),
      `Couldn't ${enable ? 'enable' : 'disable'} ${id}`,
    );
  };

  const move = (index: number, delta: number) => {
    const target = index + delta;
    if (target < 0 || target >= priority.length) return;
    const next = [...priority];
    [next[index], next[target]] = [next[target], next[index]];
    void putPriority(next);
  };

  const Row = ({ m, index }: { m: (typeof prioritized)[number]; index?: number }) => {
    const inPriority = index !== undefined;
    return (
      <div className={`list-row ${m.disabled ? 'dim' : ''}`}>
        <div className="row-main">
          {inPriority ? (
            <span className="tag accent" aria-label={`Position ${index + 1}`}>
              {index + 1}
            </span>
          ) : (
            <ProviderLogo provider={m.providers[0]} size={28} />
          )}
          <div className="row-info">
            <div className="row-title">
              <span className="mono" style={{ fontSize: 'var(--text-sm)' }}>{m.id}</span>
            </div>
            <div className="row-meta">
              {m.known ? m.providers.map((p) => providerMeta(p).label).join(' · ') || 'No active account' : 'No longer offered by any account — safe to remove'}
            </div>
          </div>
        </div>
        <div className="row-aside">
          {m.known && (
            <span className={`pill ${m.disabled ? '' : m.available > 0 ? 'ok' : 'warn'}`}>
              {m.disabled ? 'Off' : m.available > 0 ? `${plural(m.available, 'account')} ready` : 'Exhausted'}
            </span>
          )}
          <div className="row-actions">
            {inPriority ? (
              <>
                <button className="icon-btn" aria-label={`Move ${m.id} up`} disabled={busy || index === 0} onClick={() => move(index, -1)}>
                  <Icon.ArrowUp />
                </button>
                <button
                  className="icon-btn"
                  aria-label={`Move ${m.id} down`}
                  disabled={busy || index === priority.length - 1}
                  onClick={() => move(index, 1)}
                >
                  <Icon.ArrowDown />
                </button>
                <button
                  className="icon-btn"
                  aria-label={`Remove ${m.id} from the fallback order`}
                  title="Remove from order"
                  disabled={busy}
                  onClick={() => void putPriority(priority.filter((id) => id !== m.id))}
                >
                  <Icon.X />
                </button>
              </>
            ) : (
              <button
                className="btn btn-ghost btn-sm"
                disabled={busy || m.disabled}
                onClick={() => void putPriority([...priority, m.id])}
                aria-label={`Add ${m.id} to the fallback order`}
              >
                <Icon.Plus />
                Order
              </button>
            )}
            {m.known && (
              <Switch checked={!m.disabled} onChange={(on) => void toggleModel(m.id, on)} label={`Serve ${m.id}`} disabled={busy} />
            )}
          </div>
        </div>
      </div>
    );
  };

  return (
    <section className="view" aria-labelledby="page-title">
      <PageHeader
        title="Models"
        sub={`${enabledCount} of ${catalog.length} models are served. Turn off the ones you never want used, and set a fallback order for when one runs out.`}
      />

      {q.isLoading ? (
        <LoadingBlock rows={6} />
      ) : q.isError ? (
        <QueryError what="models" onRetry={() => void q.refetch()} />
      ) : (
        <>
          <div className="glass panel">
            <div className="setting">
              <div className="setting-text">
                <div className="setting-title">Fall back when a model runs out</div>
                <div className="setting-desc">
                  If every account for the requested model has hit its quota, answer with the next model in the order below
                  instead of returning an error.
                </div>
              </div>
              <div className="setting-ctl">
                <Switch
                  checked={failover}
                  label="Fall back when a model runs out"
                  disabled={busy}
                  onChange={(v) =>
                    void write((d) => ({ ...d, 'model-failover': v }), () => apiClient.patch('/routing/model-failover', { value: v }), "Couldn't change failover")
                  }
                />
              </div>
            </div>
          </div>

          <section className="glass panel" aria-labelledby="order-title">
            <SectionHeader
              id="order-title"
              Glyph={Icon.List}
              title="Fallback order"
              sub={failover ? 'Tried top to bottom when a model is exhausted' : 'Saved, but only used while fallback is on'}
            />
            {prioritized.length === 0 ? (
              <EmptyState Glyph={Icon.List} title="No fallback order yet">
                Use “Order” on any model below to add it. Without an order, every enabled model is served as requested.
              </EmptyState>
            ) : (
              <div className="list">
                {prioritized.map((m, i) => (
                  <Row key={m.id} m={m} index={i} />
                ))}
              </div>
            )}
          </section>

          <section className="glass panel" aria-labelledby="all-title">
            <SectionHeader id="all-title" Glyph={Icon.Boxes} title="All models" sub={plural(rest.length, 'model') + (needle || provider !== 'all' ? ' match' : '')} />
            <div className="toolbar">
              <label className="search">
                <Icon.Search />
                <input
                  className="inp"
                  placeholder="Search models"
                  value={search}
                  onChange={(e) => {
                    const next = new URLSearchParams(params);
                    if (e.target.value) next.set('q', e.target.value);
                    else next.delete('q');
                    setParams(next, { replace: true });
                  }}
                  aria-label="Search models"
                />
              </label>
              <div className="chips" role="group" aria-label="Filter by provider">
                <button className="chip" aria-pressed={provider === 'all'} onClick={() => setProvider('all')}>
                  All
                </button>
                {providerIds.map(([id, n]) => (
                  <button key={id} className="chip" aria-pressed={provider === id} onClick={() => setProvider(id)}>
                    {providerMeta(id).label}
                    <span className="n">{n}</span>
                  </button>
                ))}
              </div>
            </div>
            {rest.length === 0 ? (
              <EmptyState Glyph={Icon.Search} title={catalog.length ? 'No matching models' : 'No models yet'}>
                {catalog.length ? 'Try a different search or provider.' : 'Sign in to a provider on the Accounts page and its models appear here.'}
              </EmptyState>
            ) : (
              <div className="list">
                {rest.map((m) => (
                  <Row key={m.id} m={m} />
                ))}
              </div>
            )}
          </section>
        </>
      )}
    </section>
  );
}
