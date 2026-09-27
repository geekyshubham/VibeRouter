/* ============================================================================
   router — hash router so the SPA works when served statically from the backend
   at /management.html with no server-side rewrites. /config redirects to the
   renamed /settings so old bookmarks keep working.
   ========================================================================== */
import { createHashRouter, Navigate } from 'react-router-dom';
import Shell from './components/layout/Shell';
import OverviewTab from './tabs/OverviewTab';
import PlaygroundTab from './tabs/PlaygroundTab';
import AccountsTab from './tabs/AccountsTab';
import ModelsTab from './tabs/ModelsTab';
import KeysTab from './tabs/KeysTab';
import LogsTab from './tabs/LogsTab';
import SettingsTab from './tabs/SettingsTab';

export const router = createHashRouter([
  {
    path: '/',
    element: <Shell />,
    children: [
      { index: true, element: <Navigate to="/overview" replace /> },
      { path: 'overview', element: <OverviewTab /> },
      { path: 'playground', element: <PlaygroundTab /> },
      { path: 'accounts', element: <AccountsTab /> },
      { path: 'models', element: <ModelsTab /> },
      { path: 'keys', element: <KeysTab /> },
      { path: 'logs', element: <LogsTab /> },
      { path: 'settings', element: <SettingsTab /> },
      { path: 'config', element: <Navigate to="/settings" replace /> },
      { path: '*', element: <Navigate to="/overview" replace /> },
    ],
  },
]);
