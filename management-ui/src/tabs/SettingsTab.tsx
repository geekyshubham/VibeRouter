/* ============================================================================
   SettingsTab — backend configuration in plain-language groups:
     Routing       account rotation strategy, quota fallbacks, retries
     Network       upstream HTTP(S) proxy
     Diagnostics   usage statistics, file logging, request log, debug
     Providers     OpenAI-compatible upstreams (read-only, from config.yaml)
     Appearance    theme
   Each control writes its own endpoint with {"value": …} and confirms inline.
   ========================================================================== */
import { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { asArray, pluckArray } from '../lib/apiClient';
import type { BackendConfig, CompatProvider } from '../lib/types';
import { plural } from '../lib/format';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import QueryError from '../components/QueryError';
import ProviderLogo from '../components/ProviderLogo';
import Switch from '../components/Switch';
import { ThemeSwitch } from '../components/layout/Sidebar';
import { useToast } from '../context/ToastContext';

const CFG = ['mgmt', '/config'];

function Setting({ title, desc, children }: { title: string; desc: string; children: React.ReactNode }) {
  return (
    <div className="setting">
      <div className="setting-text">
        <div className="setting-title">{title}</div>
        <div className="setting-desc">{desc}</div>
      </div>
      <div className="setting-ctl">{children}</div>
    </div>
  );
}

export default function SettingsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const cfg = useManagementQuery<BackendConfig>('/config');
  const compat = useManagementQuery<{ 'openai-compatibility': CompatProvider[] | null }>('/openai-compatibility');
  const providers = pluckArray<CompatProvider>(compat.data, 'openai-compatibility').filter((p) => p && p.name);
  const c = cfg.data;

  /** Optimistic write to /config's cached copy, then the endpoint. */
  async function save(path: string, value: unknown, patch: (d: BackendConfig) => BackendConfig, note: string) {
    const previous = qc.getQueryData<BackendConfig>(CFG);
    if (previous) qc.setQueryData(CFG, patch(previous));
    try {
      await apiClient.patch(path, { value });
      toast(note, 'ok');
    } catch {
      qc.setQueryData(CFG, previous);
      toast("Couldn't save that setting", 'bad');
    } finally {
      void qc.invalidateQueries({ queryKey: CFG });
    }
  }

  const toggle = (path: string, field: keyof BackendConfig & string, label: string) => (next: boolean) =>
    save(path, next, (d) => ({ ...d, [field]: next }), `${label} ${next ? 'on' : 'off'}`);

  const quota = c?.['quota-exceeded'] ?? {};
  const strategy = c?.routing?.strategy === 'fill-first' ? 'fill-first' : 'round-robin';

  return (
    <section className="view" aria-labelledby="page-title">
      <PageHeader title="Settings" sub="How the proxy picks accounts, retries failures, and records what it does. Changes apply immediately." />

      {cfg.isLoading ? (
        <LoadingBlock rows={6} height={64} />
      ) : cfg.isError || !c ? (
        <QueryError what="settings" onRetry={() => void cfg.refetch()} />
      ) : (
        <>
          <section className="glass panel" aria-labelledby="routing-title">
            <SectionHeader id="routing-title" Glyph={Icon.Shuffle} title="Routing" />
            <Setting
              title="Account rotation"
              desc={
                strategy === 'round-robin'
                  ? 'Spread requests evenly across every matching account.'
                  : 'Use one account until it runs out, then move to the next.'
              }
            >
              <div className="seg" role="radiogroup" aria-label="Account rotation">
                {(['round-robin', 'fill-first'] as const).map((s) => (
                  <button
                    key={s}
                    role="radio"
                    aria-checked={strategy === s}
                    onClick={() =>
                      strategy !== s &&
                      void save('/routing/strategy', s, (d) => ({ ...d, routing: { ...(d.routing ?? {}), strategy: s } }), 'Rotation updated')
                    }
                  >
                    {s === 'round-robin' ? 'Spread evenly' : 'Fill first'}
                  </button>
                ))}
              </div>
            </Setting>
            <Setting title="Switch project on quota errors" desc="When a Gemini project hits its quota, retry on another project from the same account.">
              <Switch
                checked={Boolean(quota['switch-project'])}
                label="Switch project on quota errors"
                onChange={(v) =>
                  void save('/quota-exceeded/switch-project', v, (d) => ({ ...d, 'quota-exceeded': { ...d['quota-exceeded'], 'switch-project': v } }), `Project switching ${v ? 'on' : 'off'}`)
                }
              />
            </Setting>
            <Setting title="Fall back to preview models" desc="When a model's quota is exhausted, retry with its preview variant if one exists.">
              <Switch
                checked={Boolean(quota['switch-preview-model'])}
                label="Fall back to preview models"
                onChange={(v) =>
                  void save(
                    '/quota-exceeded/switch-preview-model',
                    v,
                    (d) => ({ ...d, 'quota-exceeded': { ...d['quota-exceeded'], 'switch-preview-model': v } }),
                    `Preview fallback ${v ? 'on' : 'off'}`,
                  )
                }
              />
            </Setting>
            <Setting title="Retries" desc="How many times to retry a failed upstream request before giving up (0–10).">
              <NumberField value={c['request-retry'] ?? 0} onSave={(n) => save('/request-retry', n, (d) => ({ ...d, 'request-retry': n }), 'Retries saved')} />
            </Setting>
          </section>

          <section className="glass panel" aria-labelledby="network-title">
            <SectionHeader id="network-title" Glyph={Icon.Globe} title="Network" />
            <Setting title="Upstream proxy" desc="Send provider traffic through an HTTP(S) or SOCKS proxy. Leave empty to connect directly.">
              <ProxyField value={c['proxy-url'] ?? ''} />
            </Setting>
          </section>

          <section className="glass panel" aria-labelledby="diag-title">
            <SectionHeader id="diag-title" Glyph={Icon.Activity} title="Diagnostics" />
            <Setting title="Usage statistics" desc="Count tokens and requests per provider for the usage views.">
              <Switch checked={Boolean(c['usage-statistics-enabled'])} label="Usage statistics" onChange={toggle('/usage-statistics-enabled', 'usage-statistics-enabled', 'Usage statistics')} />
            </Setting>
            <Setting title="Log to file" desc="Keep proxy logs on disk so they show up on the Logs page.">
              <Switch checked={Boolean(c['logging-to-file'])} label="Log to file" onChange={toggle('/logging-to-file', 'logging-to-file', 'File logging')} />
            </Setting>
            <Setting title="Request log" desc="Record full request and response bodies for troubleshooting. Can grow large.">
              <Switch checked={Boolean(c['request-log'])} label="Request log" onChange={toggle('/request-log', 'request-log', 'Request log')} />
            </Setting>
            <Setting title="Debug output" desc="Verbose logging. Only worth turning on while chasing a problem.">
              <Switch checked={Boolean(c.debug)} label="Debug output" onChange={toggle('/debug', 'debug', 'Debug output')} />
            </Setting>
          </section>
        </>
      )}

      <section className="glass panel" aria-labelledby="compat-title">
        <SectionHeader
          id="compat-title"
          Glyph={Icon.Server}
          title="OpenAI-compatible providers"
          sub="Defined in config.yaml"
          actions={
            <button className="btn btn-ghost btn-sm" onClick={() => void compat.refetch()}>
              <Icon.Refresh />
              Refresh
            </button>
          }
        />
        {compat.isLoading ? (
          <LoadingBlock rows={2} />
        ) : compat.isError ? (
          <QueryError what="providers" onRetry={() => void compat.refetch()} />
        ) : providers.length === 0 ? (
          <EmptyState Glyph={Icon.Server} title="None configured">
            Add an <span className="mono">openai-compatibility</span> entry to config.yaml to route to any OpenAI-style API.
          </EmptyState>
        ) : (
          <div className="list">
            {providers.map((p) => (
              <div className={`list-row ${p.disabled ? 'dim' : ''}`} key={p.name}>
                <div className="row-main">
                  <ProviderLogo provider={p.name} />
                  <div className="row-info">
                    <div className="row-title">
                      <span>{p['display-name'] || p.name}</span>
                    </div>
                    <div className="row-meta mono">{p['base-url']}</div>
                  </div>
                </div>
                <span className={`pill ${p.disabled ? '' : 'ok'}`}>{p.disabled ? 'Off' : plural(asArray(p.models).length, 'model')}</span>
              </div>
            ))}
          </div>
        )}
      </section>

      <section className="glass panel" aria-labelledby="look-title">
        <SectionHeader id="look-title" Glyph={Icon.Sun} title="Appearance" />
        <Setting title="Theme" desc="Auto follows your system setting.">
          <ThemeSwitch />
        </Setting>
      </section>
    </section>
  );
}

function NumberField({ value, onSave }: { value: number; onSave: (n: number) => void }) {
  const [draft, setDraft] = useState(String(value));
  useEffect(() => setDraft(String(value)), [value]);
  const n = Number(draft);
  const valid = Number.isInteger(n) && n >= 0 && n <= 10;
  return (
    <input
      className="inp narrow mono"
      type="number"
      min={0}
      max={10}
      inputMode="numeric"
      value={draft}
      aria-label="Retries"
      aria-invalid={!valid}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => (valid ? n !== value && onSave(n) : setDraft(String(value)))}
      onKeyDown={(e) => e.key === 'Enter' && (e.target as HTMLInputElement).blur()}
    />
  );
}

function ProxyField({ value }: { value: string }) {
  const qc = useQueryClient();
  const { toast } = useToast();
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  const dirty = draft.trim() !== value;
  const valid = !draft.trim() || /^(https?|socks5h?):\/\/\S+$/i.test(draft.trim());

  async function save() {
    try {
      // String setter takes {"value": ...}; DELETE clears it.
      if (draft.trim()) await apiClient.patch('/proxy-url', { value: draft.trim() });
      else await apiClient.del('/proxy-url');
      await qc.invalidateQueries({ queryKey: CFG });
      toast(draft.trim() ? 'Upstream proxy saved' : 'Upstream proxy removed', 'ok');
    } catch {
      toast("Couldn't save the proxy URL", 'bad');
    }
  }

  return (
    <form
      className="input-row"
      style={{ width: '100%' }}
      onSubmit={(e) => {
        e.preventDefault();
        if (valid && dirty) void save();
      }}
    >
      <input
        className="inp mono"
        placeholder="http://127.0.0.1:7890"
        value={draft}
        aria-label="Upstream proxy URL"
        aria-invalid={!valid}
        onChange={(e) => setDraft(e.target.value)}
        spellCheck={false}
      />
      {dirty && (
        <button type="submit" className="btn btn-primary" disabled={!valid}>
          Save
        </button>
      )}
    </form>
  );
}
