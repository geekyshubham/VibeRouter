/* ============================================================================
   theme — console color scheme (system / dark / light).

   The design system is dark-first; light mode is a first-class palette, not an
   afterthought. The choice persists in localStorage and is applied as
   data-theme on <html> so every token flips at the root. "system" follows
   prefers-color-scheme live.
   ========================================================================== */
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';

export type ThemeChoice = 'system' | 'dark' | 'light';

const STORAGE_KEY = 'vr_theme';

interface ThemeCtx {
  choice: ThemeChoice;
  setChoice: (c: ThemeChoice) => void;
  /** The palette actually rendering right now ("dark" | "light"). */
  resolved: 'dark' | 'light';
}

const Ctx = createContext<ThemeCtx | null>(null);

function systemPrefersDark(): boolean {
  return typeof window !== 'undefined' && !window.matchMedia('(prefers-color-scheme: light)').matches;
}

function apply(choice: ThemeChoice): 'dark' | 'light' {
  const resolved = choice === 'system' ? (systemPrefersDark() ? 'dark' : 'light') : choice;
  document.documentElement.dataset.theme = resolved;
  return resolved;
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [choice, setChoiceState] = useState<ThemeChoice>(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored === 'dark' || stored === 'light' || stored === 'system' ? stored : 'system';
  });
  const [resolved, setResolved] = useState<'dark' | 'light'>(() => apply(
    (localStorage.getItem(STORAGE_KEY) as ThemeChoice) || 'system',
  ));

  useEffect(() => {
    setResolved(apply(choice));
    localStorage.setItem(STORAGE_KEY, choice);
  }, [choice]);

  useEffect(() => {
    if (choice !== 'system') return;
    const mq = window.matchMedia('(prefers-color-scheme: light)');
    const onChange = () => setResolved(apply('system'));
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, [choice]);

  const setChoice = useCallback((c: ThemeChoice) => setChoiceState(c), []);
  const value = useMemo(() => ({ choice, setChoice, resolved }), [choice, setChoice, resolved]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useTheme(): ThemeCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider');
  return ctx;
}
