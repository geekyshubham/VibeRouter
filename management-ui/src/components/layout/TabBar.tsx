/* ============================================================================
   TabBar — pill tab strip with the animated glider behind the active tab
   (.tabs / .tab / .glider). Uses NavLink so the active route drives selection.
   ========================================================================== */
import { NavLink } from 'react-router-dom';
import Icon from '../../lib/icons';
import type { ComponentType, SVGProps } from 'react';

interface Tab {
  to: string;
  label: string;
  Glyph: ComponentType<SVGProps<SVGSVGElement>>;
}

const TABS: Tab[] = [
  { to: '/overview', label: 'Overview', Glyph: Icon.Gauge },
  { to: '/accounts', label: 'Accounts', Glyph: Icon.Users },
  { to: '/models', label: 'Models', Glyph: Icon.Activity },
  { to: '/keys', label: 'Keys', Glyph: Icon.Key },
  { to: '/logs', label: 'Logs', Glyph: Icon.List },
  { to: '/config', label: 'Config', Glyph: Icon.Settings },
];

export default function TabBar() {
  return (
    <nav className="tabs" aria-label="Console sections">
      {TABS.map(({ to, label, Glyph }) => (
        <NavLink
          key={to}
          to={to}
          className="tab"
          role="tab"
          aria-selected={undefined}
        >
          {({ isActive }) => (
            <>
              {isActive && <span className="glider" aria-hidden />}
              <Glyph />
              <span>{label}</span>
            </>
          )}
        </NavLink>
      ))}
    </nav>
  );
}
