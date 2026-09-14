/* ============================================================================
   OverviewTab — the health hero: is the proxy serving, what is it serving, and
   how busy has it been. Combines the account inventory (health + per-account
   request sparklines from recent_requests), the served-model count from the
   routing catalog, today's usage totals, and the day breakdown.
   ========================================================================== */
import { useQueryClient } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { useManagementQuery } from '../lib/useManagementQuery';
import { pluckArray } from '../lib/apiClient';
import type { AuthFile, BackendConfig, ModelRoutingResponse } from '../lib/types';
import { num, usd, tokens as fmtTokens, todayKey } from '../lib/format';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import LoadingBlock from '../components/LoadingBlock';
import Sparkline from '../components/Sparkline';
import UsageByDatePanel from '../components/UsageByDatePanel';
import UsageDayPicker from '../components/UsageDayPicker';
import { providerTint } from '../lib/providers';

interface StatProps {
  Glyph: typeof Icon.Users;
  label: string;
  value: string;
  sub?: string;
  subOk?: boolean;
}

function Stat({ Glyph, label, value, sub, subOk }: StatProps) {
  return (
    <div className="stat">
      <div className="lbl">
        <Glyph />
        <span>{label}</span>
      </div>
      <div className="val">{value}</div>
      {sub && <div className={`sub ${subOk === false ? 'bad' : subOk ? 'ok' : ''}`}>{sub}</div>}
    </div>
  );
}

/** One OAuth account row: provider logo, health pill, activity sparkline. */
function AccountRow({ file }: { file: AuthFile }) {
  const healthy = !file.disabled && !file.unavailable && file.status?.toLowerCase() !== 'error';
  return (
    <div className="lrow">
      <span className="swatch" style={{ background: providerTint(file.provider || file.type) }} />
      <div className="info">
        <div className="n">{file.label || file.name}</div>
        <div className="m">{file.name}</div>
      </div>
      <Sparkline values={file.recent_requests} />
      <span className={`pill ${file.disabled ? 'mut' : healthy ? 'ok' : 'warn'}`}>
        <span className={`dot ${file.disabled ? '' : healthy ? 'ok' : 'warn'}`} />
        {file.disabled ? 'Disabled' : healthy ? 'Healthy' : file.status || 'Degraded'}
      </span>
    </div>
  );
}

export default function OverviewTab() {
  const qc = useQueryClient();
  const cfg = useManagementQuery<BackendConfig>('/config');
  const authFiles = useManagementQuery<{ files: AuthFile[] | null }>('/auth-files');
  const routing = useManagementQuery<ModelRoutingResponse>('/routing/models');
  const dayUsage = useManagementQuery<{
    totalTokens: number;
    totalCostUSD: number;
    totalRequests: number;
  }>(`/usage-daily?date=${todayKey()}`);

  if (cfg.isLoading || authFiles.isLoading || routing.isLoading) {
    return (
      <section className="view">
        <LoadingBlock rows={2} height={92} />
      </section>
    );
  }

  const files = pluckArray<AuthFile>(authFiles.data, 'files');
  const healthy = files.filter((f) => !f.disabled && !f.unavailable && f.status?.toLowerCase() !== 'error');
  const degraded = files.filter((f) => !f.disabled && (f.unavailable || f.status?.toLowerCase() === 'error'));
  const models = (routing.data?.models ?? []).filter((m) => !m.disabled);
  const apiKeys = pluckArray<string>(cfg.data, 'api-keys');

  const activeProviders = new Set(
    files
      .filter((f) => !f.disabled)
      .map((f) => f.provider || f.type || '')
      .filter(Boolean),
  );

  async function refreshAll() {
    await qc.invalidateQueries();
  }

  return (
    <section className="view">
      <PageHeader
        title="Overview"
        sub="What the proxy is serving right now, and how busy it has been."
        trail={
          <>
            <UsageDayPicker />
            <button className="btn btn-soft btn-sm" onClick={refreshAll}>
              <Icon.Refresh />
              <span>Refresh</span>
            </button>
          </>
        }
      />

      <div className="grid g-stats">
        <Stat
          Glyph={Icon.Zap}
          label="Proxy status"
          value="Live"
          sub="management API responding"
          subOk
        />
        <Stat
          Glyph={Icon.Users}
          label="Accounts"
          value={num(files.length)}
          sub={
            degraded.length > 0
              ? `${healthy.length} healthy · ${degraded.length} degraded`
              : `${healthy.length} healthy`
          }
          subOk={healthy.length > 0 && degraded.length === 0}
        />
        <Stat
          Glyph={Icon.Boxes}
          label="Models served"
          value={num(models.length)}
          sub={`${activeProviders.size} provider${activeProviders.size === 1 ? '' : 's'} connected`}
          subOk={models.length > 0}
        />
        <Stat
          Glyph={Icon.Key}
          label="Access keys"
          value={num(apiKeys.length)}
          sub={apiKeys.length ? 'auth required' : 'open on localhost'}
          subOk={apiKeys.length > 0}
        />
      </div>

      <div className="grid g-2">
        <div className="glass-panel card">
          <SectionHeader
            Glyph={Icon.Activity}
            title="Usage today"
            sub={dayUsage.data ? undefined : 'loading…'}
            trail={
              <span className="pill accent">
                <Icon.Clock />
                {dayUsage.data ? `${num(dayUsage.data.totalRequests)} requests` : '—'}
              </span>
            }
          />
          {dayUsage.data ? (
            <div className="uday-stats" style={{ borderBottom: 'none', paddingBottom: 0 }}>
              <div className="uday-stat">
                <div className="uday-stat-lbl">Tokens</div>
                <div className="uday-stat-val">{fmtTokens(dayUsage.data.totalTokens)}</div>
              </div>
              <div className="uday-stat">
                <div className="uday-stat-lbl">Spend</div>
                <div className="uday-stat-val accent">{usd(dayUsage.data.totalCostUSD)}</div>
              </div>
              <div className="uday-stat">
                <div className="uday-stat-lbl">Requests</div>
                <div className="uday-stat-val">{num(dayUsage.data.totalRequests)}</div>
              </div>
            </div>
          ) : (
            <LoadingBlock rows={1} height={40} />
          )}
        </div>

        <div className="glass-panel card">
          <SectionHeader
            Glyph={Icon.Users}
            title="Account health"
            sub="Live request activity, last few minutes"
            trail={
              <Link to="/accounts" className="btn btn-ghost btn-sm">
                <span>Manage</span>
                <Icon.ChevronDown style={{ transform: 'rotate(-90deg)' }} />
              </Link>
            }
          />
          {files.length === 0 ? (
            <p className="small">No accounts yet — add one from the VibeRouter menu bar.</p>
          ) : (
            <div className="stack-sm">
              {files.slice(0, 6).map((f) => (
                <AccountRow key={f.name} file={f} />
              ))}
            </div>
          )}
        </div>
      </div>

      <UsageByDatePanel />
    </section>
  );
}
