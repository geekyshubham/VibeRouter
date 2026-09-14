/* ============================================================================
   main — React root. Loads the global stylesheet once, then wraps <App/> in the
   provider stack: QueryClientProvider → OnlineProvider → ToastProvider →
   AuthProvider → App. (AuthProvider depends on OnlineProvider; ToastProvider
   supplies the toast element.)
   ========================================================================== */
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

import './styles/app.css';

import App from './App';
import { OnlineProvider } from './context/OnlineContext';
import { ToastProvider } from './context/ToastContext';
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
            <AuthProvider>
              <App />
            </AuthProvider>
          </ToastProvider>
        </OnlineProvider>
      </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
);
