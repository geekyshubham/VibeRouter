/* ============================================================================
   Sidebar — the glass navigation rail. Brand + host, a ⌘K search trigger,
   grouped destinations with live counts, and a footer with connection state,
   the theme switch, and (when a key is in use) Lock. On narrow screens the
   same rail slides in as a drawer.
   ========================================================================== */
import { NavLink } from 'react-router-dom';
import { hostLabel } from '../../lib/apiClient';
import { useTheme, type ThemeChoice } from '../../lib/theme';
import { useOnline } from '../../context/OnlineContext';
import { useAuth } from '../../context/AuthContext';
import { usePalette } from '../../context/PaletteContext';
import { useAuthFiles, useRouting } from '../../lib/useConsoleData';
import { accountState } from '../../lib/health';
import { NAV_GROUPS } from '../../lib/nav';
import { BrandMark } from '../BrandMark';
import Icon from '../../lib/icons';

const THEMES: { id: ThemeChoice; label: string; Glyph: typeof Icon.Sun }[] = [
  { id: 'light', label: 'Light', Glyph: Icon.Sun },
  { id: 'dark', label: 'Dark', Glyph: Icon.Moon },
  { id: 'system', label: 'Auto', Glyph: Icon.Monitor },
];

const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform);

export function Brand() {
  const { online } = useOnline();
  return (
    <div className="brand">
      <div className="brand-mark">
        <BrandMark />
      </div>
      <div style={{ minWidth: 0 }}>
        <div className="brand-name">VibeRouter</div>
        <div className="brand-host">
          <span className={`dot ${online ? 'ok' : 'bad'}`} aria-hidden />
          <span>{hostLabel()}</span>
        </div>
      </div>
    </div>
  );
}

export function ThemeSwitch() {
  const { choice, setChoice } = useTheme();
  return (
    <div className="seg" role="radiogroup" aria-label="Appearance">
      {THEMES.map(({ id, label, Glyph }) => (
        <button key={id} role="radio" aria-checked={choice === id} onClick={() => setChoice(id)} title={`${label} theme`}>
          <Glyph />
          <span>{label}</span>
        </button>
      ))}
    </div>
  );
}

export default function Sidebar({ open, onNavigate }: { open: boolean; onNavigate: () => void }) {
  const { online } = useOnline();
  const { authRequired, logout } = useAuth();
  const { setOpen } = usePalette();
  const { files } = useAuthFiles();
  const routing = useRouting();

  const issues = files.filter((f) => accountState(f) === 'issue').length;
  const models = (routing.data?.models ?? []).filter((m) => !m.disabled).length;

  const badge: Record<string, { n: number; warn?: boolean } | undefined> = {
    '/accounts': files.length ? { n: issues || files.length, warn: issues > 0 } : undefined,
    '/models': models ? { n: models } : undefined,
  };

  return (
    <aside className="rail" id="rail" data-open={open} aria-label="Main navigation">
      <Brand />

      <button className="search-trigger" onClick={() => setOpen(true)} aria-keyshortcuts="Meta+K Control+K">
        <Icon.Search />
        <span>Search or jump to…</span>
        <span className="kbd">{isMac ? '⌘' : 'Ctrl'} K</span>
      </button>

      {NAV_GROUPS.map((group) => (
        <nav className="nav-group" key={group.label} aria-label={group.label}>
          <div className="nav-label">{group.label}</div>
          {group.items.map(({ to, label, Glyph }) => {
            const b = badge[to];
            return (
              <NavLink key={to} to={to} className="nav-link" onClick={onNavigate}>
                <Glyph />
                <span>{label}</span>
                {b && (
                  <span
                    className={`nav-count ${b.warn ? 'warn' : ''}`}
                    aria-label={b.warn ? `${b.n} need attention` : `${b.n} total`}
                  >
                    {b.n}
                  </span>
                )}
              </NavLink>
            );
          })}
        </nav>
      ))}

      <div className="rail-foot">
        <div className="status-line" role="status">
          <span className={`dot ${online ? 'ok live' : 'bad'}`} aria-hidden />
          <span>{online ? 'Proxy running' : 'Proxy unreachable'}</span>
        </div>
        <ThemeSwitch />
        {authRequired && (
          <button className="btn btn-ghost btn-sm btn-block" onClick={logout} style={{ justifyContent: 'flex-start' }}>
            <Icon.Lock />
            Lock console
          </button>
        )}
      </div>
    </aside>
  );
}
