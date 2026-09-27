/* CopyButton — copies a value; the icon flips to a check for a moment. */
import { useEffect, useRef, useState } from 'react';
import Icon from '../lib/icons';
import { useCopy } from '../lib/useCopy';

export default function CopyButton({ value, label, toastText }: { value: string; label: string; toastText?: string }) {
  const copy = useCopy();
  const [done, setDone] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout>>();
  useEffect(() => () => clearTimeout(timer.current), []);
  return (
    <button
      className="icon-btn"
      aria-label={label}
      title={label}
      onClick={async () => {
        if (await copy(value, toastText)) {
          setDone(true);
          clearTimeout(timer.current);
          timer.current = setTimeout(() => setDone(false), 1400);
        }
      }}
    >
      {done ? <Icon.Check /> : <Icon.Copy />}
    </button>
  );
}
