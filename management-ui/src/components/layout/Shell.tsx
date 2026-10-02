/* ============================================================================
   Shell — the authenticated frame: glass rail + scrolling content column, the
   mobile top bar and drawer, the ⌘K palette, and focus management on route
   change so keyboard and screen-reader users land at the page heading.
   ========================================================================== */
import { useEffect, useRef, useState } from 'react';
import { Outlet, useLocation } from 'react-router-dom';
import Sidebar, { Brand } from './Sidebar';
import OfflineBanner from './OfflineBanner';
import CommandPalette from './CommandPalette';
import { useOnline } from '../../context/OnlineContext';
import { usePalette } from '../../context/PaletteContext';
import { UsageDayProvider } from '../../context/UsageDayContext';
import { useMediaQuery } from '../../lib/useMediaQuery';
import { NAV_ITEMS } from '../../lib/nav';
import Icon from '../../lib/icons';

export default function Shell() {
  const { online } = useOnline();
  const { setOpen: setPaletteOpen } = usePalette();
  const location = useLocation();
  const narrow = useMediaQuery('(max-width: 900px)');
  const [drawer, setDrawer] = useState(false);
  const mainRef = useRef<HTMLElement>(null);
  const firstRender = useRef(true);

  // Title + focus follow the route.
  useEffect(() => {
    const page = NAV_ITEMS.find((n) => location.pathname.startsWith(n.to));
    document.title = page ? `${page.label} · VibeRouter` : 'VibeRouter';
    setDrawer(false);
    if (firstRender.current) {
      firstRender.current = false;
      return;
    }
    mainRef.current?.focus({ preventScroll: true });
    window.scrollTo({ top: 0 });
  }, [location.pathname]);

  useEffect(() => {
    if (location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView({ block: 'start' });
  }, [location.pathname, location.hash]);

  useEffect(() => {
    if (!drawer) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setDrawer(false);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [drawer]);

  return (
    <UsageDayProvider>
      <div className="backdrop" aria-hidden />
      <a className="skip-link" href="#main" onClick={(e) => { e.preventDefault(); mainRef.current?.focus(); }}>
        Skip to content
      </a>
      <div className="app">
        <Sidebar open={!narrow || drawer} onNavigate={() => setDrawer(false)} />
        {narrow && drawer && <div className="scrim" onClick={() => setDrawer(false)} />}
        <div className="content">
          <header className="topbar">
            <button
              className="icon-btn"
              aria-label="Open navigation"
              aria-expanded={drawer}
              aria-controls="rail"
              onClick={() => setDrawer(true)}
            >
              <Icon.Menu />
            </button>
            <Brand />
            <button className="icon-btn" aria-label="Search" onClick={() => setPaletteOpen(true)}>
              <Icon.Search />
            </button>
          </header>
          {!online && <OfflineBanner />}
          <main className="main" id="main" ref={mainRef} tabIndex={-1}>
            <Outlet />
          </main>
        </div>
      </div>
      <CommandPalette />
    </UsageDayProvider>
  );
}
