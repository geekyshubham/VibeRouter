/* ============================================================================
   App — the auth gate switch. A short splash while the boot probe runs, the
   LoginGate when a key is needed, otherwise the routed console.
   ========================================================================== */
import { RouterProvider } from 'react-router-dom';
import { useAuth } from './context/AuthContext';
import LoginGate from './components/LoginGate';
import { BrandMark } from './components/BrandMark';
import { router } from './router';

export default function App() {
  const { authenticated, booting } = useAuth();

  if (booting) {
    return (
      <div className="gate" aria-busy="true">
        <div className="backdrop" aria-hidden />
        <div className="gate-card glass" style={{ alignItems: 'center', textAlign: 'center' }}>
          <div className="brand-mark">
            <BrandMark size={28} />
          </div>
          <p className="lede" style={{ margin: 0 }}>
            Connecting to the proxy…
          </p>
        </div>
      </div>
    );
  }

  if (!authenticated) return <LoginGate />;
  return <RouterProvider router={router} />;
}
