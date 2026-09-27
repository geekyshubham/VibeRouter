/* ============================================================================
   ModelsTab — model routing policy:
     - which models may be served at all (disabled-models)
     - the order they are preferred in (model-priority)
     - the fallback chain: when every account of the requested model is out,
       the next model in the chain (any provider) answers instead
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
import ProviderModelPicker, { providersOf } from '../components/ProviderModelPicker';
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

  // Adder: enabled models not already in the chain. Keeps the last pick while it
  // is still addable, otherwise falls back to the first provider and model.
  const [add, setAdd] = useState({ provider: '', model: '' });
  const addable = useMemo(() => catalog.filter((m) => !m.disabled && !priority.includes(m.id)), [catalog, priority]);
  const addProviders = providersOf(addable);
  const addProvider = addProviders.some((p) => p.id === add.provider) ? add.provider : addProviders[0]?.id ?? '';
  const inAddProvider = addable.filter((m) => asArray<string>(m.providers).includes(addProvider)).map((m) => m.id).sort();
  const addModel = inAddProvider.includes(add.model) ? add.model : inAddProvider[0] ?? '';

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
      "Couldn't save the fallback chain",
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
          {inPriority && (
            <span className="tag accent" aria-label={`Step ${index + 1}`}>
              {index + 1}
            </span>
          )}
          <ProviderLogo provider={m.providers[0]} size={28} />
          <div className="row-info">
            <div className="row-title">
              <span className="mono" style={{ fontSize: 'var(--text-sm)' }}>{m.id}</span>
            </div>
            <div className="row-meta">
              {m.known
                ? (m.providers.map((p) => providerMeta(p).label).join(' · ') || 'No active account') +
                  (inPriority ? (index === 0 ? ' · tried first' : ' · when the step above runs out') : '')
                : 'No longer offered by any account — safe to remove'}
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
                  aria-label={`Remove ${m.id} from the fallback chain`}
                  title="Remove from chain"
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
                aria-label={`Add ${m.id} to the fallback chain`}
              >
                <Icon.Plus />
                Chain
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
        sub={`${enabledCount} of ${catalog.length} models are served. Turn off the ones you never want used, and chain models across providers for when one runs out.`}
      />

      {q.isLoading ? (
        <LoadingBlock rows={6} />
      ) : q.isError ? (
        <QueryError what="models" onRetry={() => void q.refetch()} />
      ) : (
        <>
          <section className="glass panel" aria-labelledby="chain-title">
            <SectionHeader
              id="chain-title"
              Glyph={Icon.List}
              title="Fallback chain"
              sub={
                failover
                  ? 'A request uses every ready account of the model it asks for. When all of them are out, it tries this chain from the top.'
                  : 'Off: a request that runs out of accounts returns an error. The chain below is kept for when you turn it on.'
              }
              actions={
                <Switch
                  checked={failover}
                  label="Fall back down the chain when a model runs out"
                  disabled={busy}
                  onChange={(v) =>
                    void write((d) => ({ ...d, 'model-failover': v }), () => apiClient.patch('/routing/model-failover', { value: v }), "Couldn't change failover")
                  }
                />
              }
            />
            {prioritized.length === 0 ? (
              <EmptyState Glyph={Icon.List} title="No fallbacks yet">
                Pick a provider and a model below, for example Kiro’s claude-opus-5.5 first and then Codex’s gpt-5.5.
              </EmptyState>
            ) : (
              <ol className={`chain ${failover ? '' : 'dim'}`} aria-label="Fallback chain, tried top to bottom">
                {prioritized.map((m, i) => (
                  <li key={m.id} className="chain-step">
                    <Row m={m} index={i} />
                  </li>
                ))}
              </ol>
            )}
            <form
              className="chain-add"
              onSubmit={(e) => {
                e.preventDefault();
                if (addModel) void putPriority([...priority, addModel]);
              }}
            >
              <ProviderModelPicker idPrefix="chain" models={addable} provider={addProvider} model={addModel} onChange={(p, m) => setAdd({ provider: p, model: m })} />
              <button type="submit" className="btn btn-primary" disabled={busy || !addModel}>
                <Icon.Plus />
                Add to chain
              </button>
            </form>
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
