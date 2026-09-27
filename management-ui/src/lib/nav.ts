/* nav — the console's destinations, shared by the rail and the ⌘K palette. */
import Icon from './icons';

export interface NavItem {
  to: string;
  label: string;
  hint: string;
  Glyph: typeof Icon.Gauge;
  keywords?: string;
}

export const NAV_GROUPS: { label: string; items: NavItem[] }[] = [
  {
    label: 'Workspace',
    items: [
      { to: '/overview', label: 'Overview', hint: 'Status, usage, and setup', Glyph: Icon.Gauge, keywords: 'home dashboard usage spend cost' },
      { to: '/playground', label: 'Playground', hint: 'Send a test request', Glyph: Icon.Sparkles, keywords: 'chat test try prompt' },
    ],
  },
  {
    label: 'Routing',
    items: [
      { to: '/accounts', label: 'Accounts', hint: 'Signed-in providers', Glyph: Icon.Users, keywords: 'oauth login providers credentials' },
      { to: '/models', label: 'Models', hint: 'What is served, and in what order', Glyph: Icon.Boxes, keywords: 'priority failover disable' },
      { to: '/keys', label: 'API keys', hint: 'Client access and upstream keys', Glyph: Icon.Key, keywords: 'auth token secret bearer' },
    ],
  },
  {
    label: 'System',
    items: [
      { to: '/logs', label: 'Logs', hint: 'Recent proxy log lines', Glyph: Icon.Terminal, keywords: 'errors debug trace' },
      { to: '/settings', label: 'Settings', hint: 'Routing, retries, logging', Glyph: Icon.Settings, keywords: 'config proxy retry debug' },
    ],
  },
];

export const NAV_ITEMS: NavItem[] = NAV_GROUPS.flatMap((g) => g.items);
