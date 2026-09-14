/* ============================================================================
   ConfigTab — backend configuration:
     - boolean toggles (debug, request-log, usage-statistics, logging-to-file)
     - proxy-url + request-retry scalars
     - OpenAI-compatible providers list (read + enable/disable)
   Each toggle PATCHes its own endpoint. Collections normalized via pluckArray.
   ========================================================================== */
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { asArray, pluckArray } from '../lib/apiClient';
import type { BackendConfig, CompatProvider } from '../lib/types';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import ProviderLogo from '../components/ProviderLogo';
import { useToast } from '../context/ToastContext';

interface ToggleDef {
  path: string;
  field: string;
  title: string;
  desc: string;
}

const TOGGLES: ToggleDef[] = [
  { path: '/debug', field: 'debug', title: 'Debug logging', desc: 'Verbose backend logs for troubleshooting' },
  { path: '/request-log', field: 'request-log', title: 'Request log', desc: 'Record per-request metadata' },
  {
    path: '/usage-statistics-enabled',
    field: 'usage-statistics-enabled',
    title: 'Usage statistics',
    desc: 'Track token usage per provider',
  },
  {
    path: '/logging-to-file',
    field: 'logging-to-file',
    title: 'File logging',
    desc: 'Persist request logs to disk',
  },
];

export default function ConfigTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const cfg = useManagementQuery<BackendConfig>('/config');
  const compat = useManagementQuery<{ 'openai-compatibility': CompatProvider[] | null }>(
    '/openai-compatibility',
  );

  const providers = pluckArray<CompatProvider>(compat.data, 'openai-compatibility').filter(
    (p) => p && p.name,
  );

  async function setToggle(def: ToggleDef, next: boolean) {
    try {
      // Backend setters take {"value": <typed>} (updateBoolField in handler.go),
      // NOT {"field-name": ...}. Route is PATCH.
      await apiClient.patch(def.path, { value: next });
      await qc.invalidateQueries({ queryKey: ['mgmt', '/config'] });
      await qc.invalidateQueries({ queryKey: ['mgmt', def.path] });
      toast(`${def.title} ${next ? 'on' : 'off'}`, 'ok');
    } catch {
      toast(`Could not update ${def.title}`, 'bad');
    }
  }

  return (
    <section className="view">
      <PageHeader
        title="Config"
        sub="Runtime flags, upstream proxy, and OpenAI-compatible providers."
      />
      <div className="glass-panel card">
        <SectionHeader Glyph={Icon.Settings} title="Backend settings" sub="Runtime configuration flags" />

        {cfg.isLoading ? (
          <LoadingBlock rows={4} />
        ) : (
          <div className="stack">
            {TOGGLES.map((def) => {
              const on = Boolean(cfg.data?.[def.field]);
              return (
                <div className="cfg-row" key={def.path}>
                  <div className="cfg-label">
                    <div className="ct">{def.title}</div>
                    <div className="cd">{def.desc}</div>
                  </div>
                  <div className="cfg-ctl">
                    <button
                      className={`sw ${on ? 'on' : ''}`}
                      role="switch"
                      aria-checked={on}
                      aria-label={`Toggle ${def.title}`}
                      onClick={() => setToggle(def, !on)}
                    />
                  </div>
                </div>
              );
            })}

            <ProxyUrlRow value={cfg.data?.['proxy-url'] ?? ''} />
            <RetryRow value={cfg.data?.['request-retry'] ?? 0} />
          </div>
        )}
      </div>

      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.Server}
          title="Compatible providers"
          sub="OpenAI-compatible upstreams configured in config.yaml"
          trail={
            <button
              className="btn btn-soft btn-sm"
              onClick={async () => {
                await qc.invalidateQueries({ queryKey: ['mgmt', '/openai-compatibility'] });
                toast('Providers refreshed', 'ok');
              }}
            >
              <Icon.Refresh />
              <span>Refresh</span>
            </button>
          }
        />

        {compat.isLoading ? (
          <LoadingBlock rows={2} />
        ) : providers.length === 0 ? (
          <EmptyState Glyph={Icon.Server} title="No compatible providers">
            OpenAI-compatible providers configured in config.yaml appear here.
          </EmptyState>
        ) : (
          <div className="grid g-prov">
            {providers.map((p) => {
              const models = asArray(p.models).length;
              return (
                <div className="prov glass" key={p.name}>
                  <ProviderLogo provider={p.name} />
                  <div className="info">
                    <div className="n">{p['display-name'] || p.name}</div>
                    <div className="m">{p['base-url']}</div>
                  </div>
                  <span className={`pill ${p.disabled ? 'mut' : 'ok'}`}>
                    {p.disabled ? 'Off' : `${models} models`}
                  </span>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </section>
  );
}

function ProxyUrlRow({ value }: { value: string }) {
  const qc = useQueryClient();
  const { toast } = useToast();
  async function save(v: string) {
    try {
      // String setter takes {"value": ...}; DELETE clears it.
      if (v.trim()) await apiClient.patch('/proxy-url', { value: v.trim() });
      else await apiClient.del('/proxy-url');
      await qc.invalidateQueries({ queryKey: ['mgmt', '/config'] });
      toast('Proxy URL saved', 'ok');
    } catch {
      toast('Could not save proxy URL', 'bad');
    }
  }
  return (
    <div className="cfg-row">
      <div className="cfg-label">
        <div className="ct">Upstream proxy URL</div>
        <div className="cd">Optional HTTP(S) proxy for provider requests</div>
      </div>
      <div className="cfg-ctl">
        <input
          className="inp mono"
          defaultValue={value}
          placeholder="http://…"
          onBlur={(e) => e.target.value !== value && save(e.target.value)}
        />
      </div>
    </div>
  );
}

function RetryRow({ value }: { value: number }) {
  const qc = useQueryClient();
  const { toast } = useToast();
  async function save(v: number) {
    try {
      // Int setter takes {"value": <int>} (updateIntField).
      await apiClient.patch('/request-retry', { value: v });
      await qc.invalidateQueries({ queryKey: ['mgmt', '/config'] });
      toast('Retry count saved', 'ok');
    } catch {
      toast('Could not save retry count', 'bad');
    }
  }
  return (
    <div className="cfg-row">
      <div className="cfg-label">
        <div className="ct">Request retries</div>
        <div className="cd">How many times to retry a failed upstream call</div>
      </div>
      <div className="cfg-ctl">
        <input
          className="inp mono"
          type="number"
          min={0}
          max={10}
          defaultValue={value}
          style={{ width: 72 }}
          onBlur={(e) => {
            const n = Number(e.target.value);
            if (!Number.isNaN(n) && n !== value) save(n);
          }}
        />
      </div>
    </div>
  );
}
