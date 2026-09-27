/* useCopy — clipboard write with toast feedback on success and failure. */
import { useCallback } from 'react';
import { useToast } from '../context/ToastContext';

export function useCopy() {
  const { toast } = useToast();
  return useCallback(
    async (value: string, what = 'Copied to clipboard') => {
      try {
        await navigator.clipboard.writeText(value);
        toast(what, 'ok');
        return true;
      } catch {
        toast('Copy failed — select the text and copy it manually', 'bad');
        return false;
      }
    },
    [toast],
  );
}
