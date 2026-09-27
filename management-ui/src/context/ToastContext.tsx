/* ============================================================================
   ToastContext — stacked, auto-dismissing toasts in the bottom-right corner.
   toast('Saved', 'ok') for feedback; pass { action } for an inline control such
   as Undo. Toasts live in a polite live region and never take focus.
   ========================================================================== */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import Icon from '../lib/icons';

type ToastKind = 'ok' | 'bad' | 'info';
interface ToastAction {
  label: string;
  run: () => void;
}
interface ToastItem {
  id: number;
  msg: string;
  kind: ToastKind;
  action?: ToastAction;
}
interface ToastCtx {
  toast: (msg: string, kind?: ToastKind, opts?: { action?: ToastAction; duration?: number }) => void;
}

const Ctx = createContext<ToastCtx | null>(null);
const MAX_VISIBLE = 3;

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const timers = useRef(new Map<number, ReturnType<typeof setTimeout>>());
  const seq = useRef(0);

  const dismiss = useCallback((id: number) => {
    const t = timers.current.get(id);
    if (t) clearTimeout(t);
    timers.current.delete(id);
    setItems((list) => list.filter((i) => i.id !== id));
  }, []);

  const toast = useCallback<ToastCtx['toast']>(
    (msg, kind = 'info', opts) => {
      const id = ++seq.current;
      setItems((list) => [...list, { id, msg, kind, action: opts?.action }].slice(-MAX_VISIBLE));
      // Actions (Undo) stay long enough to be reachable; plain feedback is brief.
      const duration = opts?.duration ?? (opts?.action ? 6000 : kind === 'bad' ? 4500 : 2600);
      timers.current.set(
        id,
        setTimeout(() => dismiss(id), duration),
      );
    },
    [dismiss],
  );

  useEffect(() => {
    const map = timers.current;
    return () => map.forEach((t) => clearTimeout(t));
  }, []);

  const value = useMemo(() => ({ toast }), [toast]);

  return (
    <Ctx.Provider value={value}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {items.map((item) => {
          const KindIcon = item.kind === 'ok' ? Icon.Check : item.kind === 'bad' ? Icon.Alert : Icon.Info;
          return (
            <div className={`toast ${item.kind}`} key={item.id}>
              <KindIcon />
              <span>{item.msg}</span>
              {item.action && (
                <button
                  className="btn btn-glass btn-sm"
                  onClick={() => {
                    item.action?.run();
                    dismiss(item.id);
                  }}
                >
                  {item.action.label}
                </button>
              )}
              <button className="icon-btn" aria-label="Dismiss notification" onClick={() => dismiss(item.id)}>
                <Icon.X />
              </button>
            </div>
          );
        })}
      </div>
    </Ctx.Provider>
  );
}

export function useToast(): ToastCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useToast must be used within ToastProvider');
  return ctx;
}
