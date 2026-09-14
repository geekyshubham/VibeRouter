/* ============================================================================
   Sidebar — the console's navigation rail (replaces the old top-bar + pill
   tabs). Brand + connection state, grouped nav with live counts, and a footer
   with the theme control. NavLink drives the active route.
   ========================================================================== */
import { NavLink } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import apiClient from '../../lib/apiClient';
import { useTheme, type ThemeChoice } from '../../lib/theme';
import { hostLabel } from '../../lib/apiClient';
import { useOnline } from '../../context/OnlineContext';
import { useAuth } from '../../context/AuthContext';
import { BrandMark } from '../BrandMark';
import Icon from '../../lib/icons';
import type { AuthFile, ModelRoutingResponse } from '../../lib/types';

interface NavItem {
  to: string;
  label: string;
  Glyph: typeof Icon.Gauge;
  count?: number | string;
}

export default function Sidebar() {
  const { online } = useOnline();
  const { authRequired, logout } = useAuth();
  const { choice, setChoice } = useTheme();

  // Live counts for the rail badges — cheap, cached, refetch on window focus.
  const accounts = useQuery({
    queryKey: ['mgmt', '/auth-files'],
    queryFn: () => apiClient.get<{ files: AuthFile[] | null }>('/auth-files'),
    refetchInterval: 30_000,
  });
  const models = useQuery({
    queryKey: ['mgmt', '/routing/models'],
    queryFn: () => apiClient.get<ModelRoutingResponse>('/routing/models'),
    refetchInterval: 30_000,
  });

  const accountCount = (accounts.data?.files ?? []).length;
  const modelCount = (models.data?.models ?? []).filter((m) => !m.disabled).length;

  const groups: { label: string; items: NavItem[] }[] = [
    {
      label: 'Console',
      items: [
        { to: '/overview', label: 'Overview', Glyph: Icon.Gauge },
        { to: '/playground', label: 'Playground', Glyph: Icon.Play },
      ],
    },
    {
      label: 'Manage',
      items: [
        { to: '/accounts', label: 'Accounts', Glyph: Icon.Users, count: accountCount || undefined },
        { to: '/models', label: 'Models', Glyph: Icon.Boxes, count: modelCount || undefined },
        { to: '/keys', label: 'Keys', Glyph: Icon.Key },
      ],
    },
    {
      label: 'Observability',
      items: [
        { to: '/logs', label: 'Logs', Glyph: Icon.List },
        { to: '/config', label: 'Config', Glyph: Icon.Settings },
      ],
    },
  ];

  const themeOptions: { id: ThemeChoice; label: string; Glyph: typeof Icon.Sun }[] = [
    { id: 'system', label: 'System theme', Glyph: Icon.Monitor },
    { id: 'dark', label: 'Dark theme', Glyph: Icon.Moon },
    { id: 'light', label: 'Light theme', Glyph: Icon.Sun },
  ];

  return (
    <aside className="side">
      <div className="side-brand">
        <div className="brand-mark">
          <BrandMark />
        </div>
        <div>
          <div className="name">VibeRouter</div>
          <div className="host">
            <span className={`dot ${online ? 'ok pulse' : 'bad'}`} />
            <span>{hostLabel()}</span>
          </div>
        </div>
      </div>

      {groups.map((group) => (
        <nav className="side-group" key={group.label} aria-label={group.label}>
          <div className="side-label">{group.label}</div>
          {group.items.map(({ to, label, Glyph, count }) => (
            <NavLink key={to} to={to} className="side-link">
              <Glyph />
              <span>{label}</span>
              {count != null && <span className="count">{count}</span>}
            </NavLink>
          ))}
        </nav>
      ))}

      <div className="side-foot">
        <div className="theme-seg" role="radiogroup" aria-label="Color scheme">
          {themeOptions.map(({ id, label, Glyph }) => (
            <button
              key={id}
              className={choice === id ? 'on' : ''}
              role="radio"
              aria-checked={choice === id}
              aria-label={label}
              title={label}
              onClick={() => setChoice(id)}
            >
              <Glyph />
            </button>
          ))}
        </div>
        <div className="side-status">
          <span className={`dot ${online ? 'ok pulse' : 'bad'}`} />
          <span>{online ? 'Proxy live' : 'Backend offline'}</span>
        </div>
        {authRequired && (
          <button className="btn btn-ghost btn-sm" onClick={logout} title="Sign out of the console">
            <Icon.Lock />
            <span>Lock console</span>
          </button>
        )}
      </div>
    </aside>
  );
}
