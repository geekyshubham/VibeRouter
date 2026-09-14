/* ============================================================================
   ModelsTab — model routing policy for the proxy:
     - which models may be served at all (disabled-models)
     - the order they are preferred in (model-priority; drag-free reorder)
     - whether an exhausted model falls back to the next preferred one
   All state lives in GET /routing/models; every mutation PUTs the full list
   back (the backend normalizes + persists to config.yaml).
   ========================================================================== */
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { asArray, pluckArray } from '../lib/apiClient';
import type { ModelCatalogEntry, ModelRoutingResponse } from '../lib/types';
import { providerMeta } from '../lib/providers';
import Icon from '../lib/icons';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import { useToast } from '../context/ToastContext';

interface RoutedModel {
  id: string;
  providers: string[];
  available: number;
  disabled: boolean;
  prioritized: boolean;
}

export default function ModelsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const q = useManagementQuery<ModelRoutingResponse>('/routing/models');
  const [busy, setBusy] = useState<string | null>(null);

  const catalog = pluckArray<ModelCatalogEntry>(q.data, 'models');
  const priority = pluckArray<string>(q.data, 'model-priority');
  const failover = Boolean(q.data?.['model-failover']);

  const byID = new Map(catalog.map((m) => [m.id, m]));
  const known = new Set(catalog.map((m) => m.id));

  // Prioritized models in list order (stale IDs kept visible so the operator
  // can prune them), then every unprioritized catalog model alphabetically.
  const prioritized: RoutedModel[] = priority.map((id) => {
    const entry = byID.get(id);
    return {
      id,
      providers: asArray<string>(entry?.providers),
      available: entry?.available ?? 0,
      disabled: entry?.disabled ?? false,
      prioritized: true,
    };
  });
  const rest: RoutedModel[] = catalog
    .filter((m) => !m.prioritized)
    .map((m) => ({
      id: m.id,
      providers: asArray<string>(m.providers),
      available: m.available,
      disabled: m.disabled,
      prioritized: false,
    }))
    .sort((a, b) => a.id.localeCompare(b.id));

  async function reload(note?: string) {
    await qc.invalidateQueries({ queryKey: ['mgmt', '/routing/models'] });
    if (note) toast(note, 'ok');
  }

  async function putPriority(next: string[], note: string) {
    setBusy('priority');
    try {
      await apiClient.put('/routing/model-priority', { value: next });
      await reload(note);
    } catch {
      toast('Could not update model order', 'bad');
    } finally {
      setBusy(null);
    }
  }

  async function putDisabled(nextDisabled: string[], note: string) {
    setBusy('disabled');
    try {
      await apiClient.put('/routing/disabled-models', { value: nextDisabled });
      await reload(note);
    } catch {
      toast('Could not update models', 'bad');
    } finally {
      setBusy(null);
    }
  }

  async function toggleFailover() {
    setBusy('failover');
    try {
      await apiClient.patch('/routing/model-failover', { value: !failover });
      await reload(`Failover ${failover ? 'off' : 'on'}`);
    } catch {
      toast('Could not update failover', 'bad');
    } finally {
      setBusy(null);
    }
  }

  function toggleModel(model: RoutedModel) {
    const disabledSet = new Set(catalog.filter((m) => m.disabled).map((m) => m.id));
    if (model.disabled) {
      disabledSet.delete(model.id);
    } else {
      disabledSet.add(model.id);
    }
    void putDisabled([...disabledSet], model.disabled ? `${model.id} enabled` : `${model.id} disabled`);
  }

  function prioritize(model: RoutedModel) {
    void putPriority([...priority, model.id], `${model.id} added to priority`);
  }

  function deprioritize(model: RoutedModel) {
    void putPriority(priority.filter((id) => id !== model.id), `${model.id} removed from priority`);
  }

  function move(model: RoutedModel, delta: number) {
    const idx = priority.indexOf(model.id);
    const target = idx + delta;
    if (idx < 0 || target < 0 || target >= priority.length) return;
    const next = [...priority];
    [next[idx], next[target]] = [next[target], next[idx]];
    void putPriority(next, 'Model order saved');
  }

  const renderRow = (model: RoutedModel, index: number, section: 'priority' | 'rest') => {
    const knownModel = known.has(model.id);
    return (
      <div className="prov glass" key={`${section}-${model.id}`} style={model.disabled ? { opacity: 0.55 } : undefined}>
        {section === 'priority' ? (
          <span className="tag" title="Priority position">{index + 1}</span>
        ) : (
          <span className="tag" style={{ opacity: 0.5 }}>—</span>
        )}
        <div className="info">
          <div className="n">
            {model.id}
            {model.disabled && <span className="pill mut">Disabled</span>}
          </div>
          <div className="m">
            {knownModel
              ? model.providers.map((p) => providerMeta(p).label).join(' · ') || 'no active account'
              : 'not currently registered (stale entry)'}
          </div>
        </div>
        <div className="row">
          {knownModel && (
            <span className={`pill ${model.available > 0 ? 'ok' : 'warn'}`}>
              <span className={`dot ${model.available > 0 ? 'ok' : 'warn'}`} />
              {model.available > 0 ? `${model.available} ready` : 'exhausted'}
            </span>
          )}
          {section === 'priority' && (
            <>
              <button
                className="btn-icon"
                title="Move up"
                aria-label={`Move ${model.id} up`}
                disabled={busy !== null || index === 0}
                onClick={() => move(model, -1)}
              >
                ↑
              </button>
              <button
                className="btn-icon"
                title="Move down"
                aria-label={`Move ${model.id} down`}
                disabled={busy !== null || index === prioritized.length - 1}
                onClick={() => move(model, 1)}
              >
                ↓
              </button>
              <button
                className="btn-icon"
                title="Remove from priority order"
                aria-label={`Remove ${model.id} from priority`}
                disabled={busy !== null}
                onClick={() => deprioritize(model)}
              >
                <Icon.X />
              </button>
            </>
          )}
          {section === 'rest' && (
            <button
              className="btn-icon"
              title="Add to priority order"
              aria-label={`Prioritize ${model.id}`}
              disabled={busy !== null}
              onClick={() => prioritize(model)}
            >
              <Icon.Plus />
            </button>
          )}
          {knownModel && (
            <button
              className={`sw ${model.disabled ? '' : 'on'}`}
              role="switch"
              aria-checked={!model.disabled}
              aria-label={`Toggle ${model.id}`}
              disabled={busy !== null}
              onClick={() => toggleModel(model)}
            />
          )}
        </div>
      </div>
    );
  };

  return (
    <section className="view">
      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.Activity}
          title="Model routing"
          sub="Choose which models VibeRouter serves and in what order"
        />
        <div className="cfg-row">
          <div className="cfg-label">
            <div className="ct">Failover to next model when exhausted</div>
            <div className="cd">
              When the requested model has no working account left (quota exhausted everywhere),
              fall back to the next model in the priority list instead of failing the request.
            </div>
          </div>
          <div className="cfg-ctl">
            <button
              className={`sw ${failover ? 'on' : ''}`}
              role="switch"
              aria-checked={failover}
              aria-label="Toggle model failover"
              disabled={busy !== null}
              onClick={toggleFailover}
            />
          </div>
        </div>
      </div>

      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.List}
          title="Priority order"
          sub="First match is used first; on exhaustion the next one takes over (with failover on)"
          trail={
            <button
              className="btn btn-soft btn-sm"
              disabled={q.isFetching}
              onClick={() => void reload()}
            >
              <Icon.Refresh />
              <span>Refresh</span>
            </button>
          }
        />
        {q.isLoading ? (
          <LoadingBlock rows={4} />
        ) : prioritized.length === 0 ? (
          <EmptyState Glyph={Icon.List} title="No priority order set">
            Add models below with + to build the fallback order. Without an order every enabled
            model is served normally.
          </EmptyState>
        ) : (
          <div className="stack">
            {prioritized.map((model, index) => renderRow(model, index, 'priority'))}
          </div>
        )}
      </div>

      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.Server}
          title="All models"
          sub="Every model the connected accounts can serve. + adds it to the priority order."
        />
        {q.isLoading ? (
          <LoadingBlock rows={4} />
        ) : rest.length === 0 ? (
          <EmptyState Glyph={Icon.Server} title="No other models">
            Every registered model is already in the priority list.
          </EmptyState>
        ) : (
          <div className="stack">
            {rest.map((model, index) => renderRow(model, index, 'rest'))}
          </div>
        )}
      </div>
    </section>
  );
}
