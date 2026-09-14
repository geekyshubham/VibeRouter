/* ============================================================================
   Shell — the authenticated layout frame: sidebar rail + scrolling content
   column. UsageDayProvider spans the frame so any page can read or change the
   reported-on day.
   ========================================================================== */
import { Outlet } from 'react-router-dom';
import Sidebar from './Sidebar';
import OfflineBanner from './OfflineBanner';
import { useOnline } from '../../context/OnlineContext';
import { UsageDayProvider } from '../../context/UsageDayContext';

export default function Shell() {
  const { online } = useOnline();
  return (
    <UsageDayProvider>
      <div className="app">
        <Sidebar />
        <div className="content">
          {!online && <OfflineBanner />}
          <main className="tabpanel" role="tabpanel">
            <Outlet />
          </main>
        </div>
      </div>
    </UsageDayProvider>
  );
}
