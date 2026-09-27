/* ============================================================================
   OverviewTab — the home screen, arranged by what an operator asks first:
     1. Is it working, and where do I point my tools?   (hero + endpoints)
     2. What's the headline?                           (KPI tiles → deep links)
     3. What's left to set up?                         (setup checklist, hides when done)
     4. Is traffic flowing?                            (recent request activity)
     5. What did it cost?                              (usage by day)
   ========================================================================== */
import { Link, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { clientEndpoints } from '../lib/apiClient';
import { useManagementQuery } from '../lib/useManagementQuery';
import { useAccessKeys, useAuthFiles, useRouting } from '../lib/useConsoleData';
import { accountState } from '../lib/health';
import { num, plural, todayKey, tokens, usd } from '../lib/format';
import type { UsageDailyResponse } from '../lib/types';
import { useOnline } from '../context/OnlineContext';
import Icon from '../lib/icons';
import SectionHeader from '../components/SectionHeader';
import LoadingBlock from '../components/LoadingBlock';
import CopyButton from '../components/CopyButton';
import ActivityChart from '../components/ActivityChart';
import UsageByDatePanel from '../components/UsageByDatePanel';

function Kpi({
  to,
  Glyph,
  label,
  value,
  sub,
  tone,
}: {
  to: string;
  Glyph: typeof Icon.Users;
  label: string;
  value: string;
  sub: string;
  tone?: 'ok' | 'warn';
}) {
  return (
    <Link to={to} className="kpi glass">
      <div className="kpi-lbl">
        <Glyph />
        <span>{label}</span>
        <Icon.ArrowRight className="go" />
      </div>
      <div className="kpi-val">{value}</div>
      <div className={`kpi-sub ${tone ?? ''}`}>
        {tone === 'warn' && <Icon.Alert />}
        {tone === 'ok' && <Icon.Check />}
        <span>{sub}</span>
      </div>
    </Link>
  );
}

export default function OverviewTab() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const { online } = useOnline();
  const { files, isLoading: filesLoading } = useAuthFiles();
  const routing = useRouting();
  const { keys } = useAccessKeys();
  const today = useManagementQuery<UsageDailyResponse>(`/usage-daily?date=${todayKey()}`);
  const ep = clientEndpoints();

  const active = files.filter((f) => accountState(f) === 'active');
  const issues = files.filter((f) => accountState(f) === 'issue');
  const models = (routing.data?.models ?? []).filter((m) => !m.disabled);
  const providers = new Set(active.map((f) => f.provider || f.type).filter(Boolean));

  const steps = [
    {
      done: files.length > 0,
      title: 'Sign in to a provider',
      desc: 'Add Claude, Codex, Gemini, Copilot and more from the VibeRouter menu bar.',
      to: '/accounts',
    },
    {
      done: models.length > 0,
      title: 'Check which models are served',
      desc: models.length ? `${plural(models.length, 'model')} available` : 'Models appear once an account is signed in.',
      to: '/models',
    },
    {
      done: keys.length > 0,
      title: 'Require an access key',
      desc: 'Optional on localhost. Needed if anything else on your network can reach the proxy.',
      to: '/keys?new=1',
    },
  ];
  const setupDone = steps.every((s) => s.done);

  const healthy = online && issues.length === 0;
  const headline = !online
    ? 'The proxy is not responding'
    : files.length === 0
      ? 'Ready — add an account to start routing'
      : issues.length
        ? `${plural(issues.length, 'account')} need${issues.length === 1 ? 's' : ''} attention`
        : `Routing ${plural(models.length, 'model')} across ${plural(providers.size, 'provider')}`;

  return (
    <section className="view" aria-labelledby="page-title">
      <h1 id="page-title" className="sr-only">
        Overview
      </h1>

      <div className="hero glass">
        <div>
          <div className={`hero-state ${healthy ? '' : 'warn'}`}>
            <span className={`dot ${healthy ? 'ok live' : 'warn'}`} aria-hidden />
            {online ? (healthy ? 'All systems normal' : 'Running with issues') : 'Offline'}
          </div>
          <h2 className="hero-title">{headline}</h2>
          <p className="hero-sub">
            Point Claude Code, Factory, Cursor, or any OpenAI-compatible tool at the endpoint on the right. VibeRouter
            picks a signed-in account for every request.
          </p>
          <div className="hero-actions">
            <button className="btn btn-primary" onClick={() => navigate('/playground')}>
              <Icon.Send />
              Send a test request
            </button>
            {issues.length > 0 ? (
              <button className="btn btn-glass" onClick={() => navigate('/accounts?state=issue')}>
                <Icon.Alert />
                Review accounts
              </button>
            ) : (
              <button className="btn btn-glass" onClick={() => void qc.invalidateQueries()}>
                <Icon.Refresh />
                Refresh
              </button>
            )}
          </div>
        </div>

        <div className="endpoint-card" aria-label="Client endpoints">
          <div className="label">Point your tools here</div>
          <div className="endpoint-row">
            <span className="lbl">Anthropic</span>
            <code title={ep.anthropic}>{ep.anthropic}</code>
            <CopyButton value={ep.anthropic} label="Copy Anthropic base URL" toastText="Base URL copied" />
          </div>
          <div className="endpoint-row">
            <span className="lbl">OpenAI</span>
            <code title={ep.openai}>{ep.openai}</code>
            <CopyButton value={ep.openai} label="Copy OpenAI base URL" toastText="Base URL copied" />
          </div>
          <div className="endpoint-row">
            <span className="lbl">API key</span>
            <code>{keys.length ? 'one of your access keys' : 'any value works'}</code>
            <Link to="/keys" className="icon-btn" aria-label="Manage access keys" title="Manage access keys">
              <Icon.ChevronRight />
            </Link>
          </div>
        </div>
      </div>

      {filesLoading || routing.isLoading ? (
        <div className="grid g-kpi">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="skel" style={{ height: 124, borderRadius: 'var(--r-card)' }} />
          ))}
        </div>
      ) : (
        <div className="grid g-kpi">
          <Kpi
            to="/accounts"
            Glyph={Icon.Users}
            label="Accounts"
            value={num(files.length)}
            sub={issues.length ? `${num(issues.length)} need attention` : files.length ? `${num(active.length)} active` : 'None signed in'}
            tone={issues.length ? 'warn' : active.length ? 'ok' : undefined}
          />
          <Kpi
            to="/models"
            Glyph={Icon.Boxes}
            label="Models served"
            value={num(models.length)}
            sub={`${plural(providers.size, 'provider')}`}
          />
          <Kpi
            to="/overview#usage-title"
            Glyph={Icon.Activity}
            label="Spend today"
            value={today.data ? usd(today.data.totalCostUSD) : '—'}
            sub={today.data ? `${tokens(today.data.totalTokens)} tokens` : 'Loading…'}
          />
          <Kpi
            to="/keys"
            Glyph={Icon.Shield}
            label="Access"
            value={keys.length ? 'Key required' : 'Open'}
            sub={keys.length ? plural(keys.length, 'access key') : 'Local clients need no key'}
            tone={keys.length ? 'ok' : undefined}
          />
        </div>
      )}

      <div className={`grid ${setupDone ? '' : 'g-2'}`}>
        <section className="glass panel" aria-labelledby="activity-title">
          <SectionHeader
            id="activity-title"
            Glyph={Icon.Zap}
            title="Live traffic"
            sub="All accounts, 10-minute windows"
            actions={
              <Link to="/accounts" className="btn btn-ghost btn-sm">
                By account
                <Icon.ArrowRight />
              </Link>
            }
          />
          {filesLoading ? (
            <LoadingBlock rows={1} height={150} />
          ) : files.length ? (
            <ActivityChart files={files} />
          ) : (
            <p className="small">Traffic shows up here once an account is signed in.</p>
          )}
        </section>

        {!setupDone && (
          <section className="glass panel" aria-labelledby="setup-title">
            <SectionHeader
              id="setup-title"
              Glyph={Icon.Wand}
              title="Get set up"
              sub={`${steps.filter((s) => s.done).length} of ${steps.length} done`}
            />
            <div className="checklist">
              {steps.map((s) => (
                <Link key={s.title} to={s.to} className={`check-item ${s.done ? 'done' : 'todo'}`}>
                  <span className="check-mark" aria-hidden>
                    {s.done ? <Icon.Check /> : <Icon.ArrowRight />}
                  </span>
                  <span className="check-text">
                    <span className="check-title">
                      {s.title}
                      <span className="sr-only">{s.done ? ' (done)' : ' (to do)'}</span>
                    </span>
                    <span className="check-desc" style={{ display: 'block' }}>
                      {s.desc}
                    </span>
                  </span>
                  <Icon.ChevronRight />
                </Link>
              ))}
            </div>
          </section>
        )}
      </div>

      <UsageByDatePanel />
    </section>
  );
}
