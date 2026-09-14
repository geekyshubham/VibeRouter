/* ============================================================================
   router — hash router so the SPA works when served statically from the backend
   at /management.html with no server-side rewrites. Five tabs under the Shell.
   ========================================================================== */
import { createHashRouter, Navigate } from 'react-router-dom';
import Shell from './components/layout/Shell';
import OverviewTab from './tabs/OverviewTab';
import AccountsTab from './tabs/AccountsTab';
import ModelsTab from './tabs/ModelsTab';
import KeysTab from './tabs/KeysTab';
import LogsTab from './tabs/LogsTab';
import ConfigTab from './tabs/ConfigTab';

export const router = createHashRouter([
  {
    path: '/',
    element: <Shell />,
    children: [
      { index: true, element: <Navigate to="/overview" replace /> },
      { path: 'overview', element: <OverviewTab /> },
      { path: 'accounts', element: <AccountsTab /> },
      { path: 'models', element: <ModelsTab /> },
      { path: 'keys', element: <KeysTab /> },
      { path: 'logs', element: <LogsTab /> },
      { path: 'config', element: <ConfigTab /> },
      { path: '*', element: <Navigate to="/overview" replace /> },
    ],
  },
]);
