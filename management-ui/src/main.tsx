/* ============================================================================
   main — React root. Loads the global stylesheet once, then wraps <App/> in the
   provider stack: Theme → QueryClient → Online → Toast → Confirm → Palette →
   Auth → App. (AuthProvider depends on OnlineProvider; Toast/Confirm render
   their own overlays.)
   ========================================================================== */
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

import './styles/app.css';

import App from './App';
import { OnlineProvider } from './context/OnlineContext';
import { ToastProvider } from './context/ToastContext';
import { ConfirmProvider } from './context/ConfirmContext';
import { PaletteProvider } from './context/PaletteContext';
import { AuthProvider } from './context/AuthContext';
import { ThemeProvider } from './lib/theme';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: false,
      staleTime: 15_000,
      refetchOnWindowFocus: false,
    },
  },
});

const rootEl = document.getElementById('root');
if (!rootEl) throw new Error('#root mount point not found');

createRoot(rootEl).render(
  <StrictMode>
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <OnlineProvider>
          <ToastProvider>
            <ConfirmProvider>
              <PaletteProvider>
                <AuthProvider>
                  <App />
                </AuthProvider>
              </PaletteProvider>
            </ConfirmProvider>
          </ToastProvider>
        </OnlineProvider>
      </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
);
