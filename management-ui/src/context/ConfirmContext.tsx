/* ============================================================================
   ConfirmContext — an in-app replacement for window.confirm(). Destructive
   actions await confirm({...}) and get a glass dialog with a clear, specific
   title, a safe default focus (Cancel), Esc to back out, and focus restored to
   the trigger afterwards.
   ========================================================================== */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import Icon from '../lib/icons';

interface ConfirmOptions {
  title: string;
  body?: ReactNode;
  confirmLabel?: string;
  danger?: boolean;
}
type Confirm = (opts: ConfirmOptions) => Promise<boolean>;

const Ctx = createContext<Confirm | null>(null);

export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [pending, setPending] = useState<(ConfirmOptions & { resolve: (v: boolean) => void }) | null>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLDivElement>(null);

  const confirm = useCallback<Confirm>((opts) => {
    returnFocus.current = document.activeElement as HTMLElement | null;
    return new Promise<boolean>((resolve) => setPending({ ...opts, resolve }));
  }, []);

  const close = useCallback(
    (result: boolean) => {
      pending?.resolve(result);
      setPending(null);
      requestAnimationFrame(() => returnFocus.current?.focus());
    },
    [pending],
  );

  useEffect(() => {
    if (!pending) return;
    cancelRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        close(false);
      }
      // Keep Tab inside the dialog.
      if (e.key === 'Tab' && dialogRef.current) {
        const focusables = dialogRef.current.querySelectorAll<HTMLElement>('button');
        const first = focusables[0];
        const last = focusables[focusables.length - 1];
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [pending, close]);

  const value = useMemo(() => confirm, [confirm]);

  return (
    <Ctx.Provider value={value}>
      {children}
      {pending && (
        <>
          <div className="scrim" onClick={() => close(false)} />
          <div className="dialog-wrap">
            <div
              className="dialog glass"
              role="alertdialog"
              aria-modal="true"
              aria-labelledby="confirm-title"
              aria-describedby="confirm-body"
              ref={dialogRef}
            >
              {pending.danger && (
                <div className="dialog-icon">
                  <Icon.Trash />
                </div>
              )}
              <h2 id="confirm-title">{pending.title}</h2>
              {pending.body && <p id="confirm-body">{pending.body}</p>}
              <div className="dialog-actions">
                <button className="btn btn-glass" ref={cancelRef} onClick={() => close(false)}>
                  Cancel
                </button>
                <button className={`btn ${pending.danger ? 'btn-danger' : 'btn-primary'}`} onClick={() => close(true)}>
                  {pending.confirmLabel ?? 'Confirm'}
                </button>
              </div>
            </div>
          </div>
        </>
      )}
    </Ctx.Provider>
  );
}

export function useConfirm(): Confirm {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useConfirm must be used within ConfirmProvider');
  return ctx;
}
