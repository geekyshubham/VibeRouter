/* ============================================================================
   CommandPalette — ⌘K. Jump to any page, run a common action (copy the
   endpoint, switch theme, refresh), or jump straight to a model or account.
   Arrow keys move, Enter runs, Esc closes; focus returns to the trigger.
   ========================================================================== */
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { usePalette } from '../../context/PaletteContext';
import { useTheme } from '../../lib/theme';
import { clientEndpoints } from '../../lib/apiClient';
import { useCopy } from '../../lib/useCopy';
import { useAuthFiles, useRouting } from '../../lib/useConsoleData';
import { providerMeta } from '../../lib/providers';
import { NAV_ITEMS } from '../../lib/nav';
import Icon from '../../lib/icons';

interface Command {
  id: string;
  group: string;
  label: string;
  hint?: string;
  Glyph: typeof Icon.Gauge;
  keywords?: string;
  run: () => void;
}

export default function CommandPalette() {
  const { open, setOpen } = usePalette();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { setChoice, resolved } = useTheme();
  const copy = useCopy();
  const { files } = useAuthFiles();
  const routing = useRouting();
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);

  const commands = useMemo<Command[]>(() => {
    const ep = clientEndpoints();
    const pages: Command[] = NAV_ITEMS.map((n) => ({
      id: `go:${n.to}`,
      group: 'Go to',
      label: n.label,
      hint: n.hint,
      Glyph: n.Glyph,
      keywords: n.keywords,
      run: () => navigate(n.to),
    }));
    const actions: Command[] = [
      { id: 'copy:anthropic', group: 'Actions', label: 'Copy Anthropic base URL', hint: ep.anthropic, Glyph: Icon.Copy, keywords: 'claude code endpoint', run: () => void copy(ep.anthropic, 'Base URL copied') },
      { id: 'copy:openai', group: 'Actions', label: 'Copy OpenAI base URL', hint: ep.openai, Glyph: Icon.Copy, keywords: 'endpoint v1', run: () => void copy(ep.openai, 'Base URL copied') },
      { id: 'act:try', group: 'Actions', label: 'Send a test request', hint: 'Playground', Glyph: Icon.Send, run: () => navigate('/playground') },
      { id: 'act:key', group: 'Actions', label: 'Create an access key', hint: 'API keys', Glyph: Icon.Key, run: () => navigate('/keys?new=1') },
      { id: 'act:refresh', group: 'Actions', label: 'Refresh all data', Glyph: Icon.Refresh, run: () => void qc.invalidateQueries() },
      {
        id: 'act:theme',
        group: 'Actions',
        label: resolved === 'dark' ? 'Switch to light theme' : 'Switch to dark theme',
        Glyph: resolved === 'dark' ? Icon.Sun : Icon.Moon,
        keywords: 'appearance mode',
        run: () => setChoice(resolved === 'dark' ? 'light' : 'dark'),
      },
    ];
    const models: Command[] = (routing.data?.models ?? []).map((m) => ({
      id: `model:${m.id}`,
      group: 'Models',
      label: m.id,
      hint: (m.providers ?? []).map((p) => providerMeta(p).label).join(', '),
      Glyph: Icon.Boxes,
      run: () => navigate(`/models?q=${encodeURIComponent(m.id)}`),
    }));
    const accounts: Command[] = files.map((f) => ({
      id: `acct:${f.name}`,
      group: 'Accounts',
      label: f.label || f.name,
      hint: providerMeta(f.provider || f.type).label,
      Glyph: Icon.Users,
      run: () => navigate(`/accounts?q=${encodeURIComponent(f.label || f.name)}`),
    }));
    return [...pages, ...actions, ...models, ...accounts];
  }, [navigate, qc, copy, setChoice, resolved, routing.data, files]);

  const results = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return commands.filter((c) => c.group === 'Go to' || c.group === 'Actions');
    const terms = needle.split(/\s+/);
    return commands
      .filter((c) => {
        const hay = `${c.label} ${c.hint ?? ''} ${c.keywords ?? ''} ${c.group}`.toLowerCase();
        return terms.every((t) => hay.includes(t));
      })
      .slice(0, 40);
  }, [commands, query]);

  // Runs before paint: remember where focus was, reset, then focus the input
  // so keystrokes typed right after ⌘K land in the search box.
  useLayoutEffect(() => {
    if (!open) return;
    returnFocus.current = document.activeElement as HTMLElement | null;
    setQuery('');
    setActive(0);
    inputRef.current?.focus();
  }, [open]);

  useEffect(() => setActive(0), [query]);

  useEffect(() => {
    listRef.current?.querySelector<HTMLElement>(`[data-idx="${active}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [active]);

  if (!open) return null;

  const close = () => {
    setOpen(false);
    requestAnimationFrame(() => returnFocus.current?.focus());
  };
  const run = (c: Command | undefined) => {
    if (!c) return;
    setOpen(false);
    c.run();
  };

  let lastGroup = '';
  return (
    <>
      <div className="scrim" onClick={close} />
      <div className="cmdk-wrap">
        <div
          className="cmdk glass"
          role="dialog"
          aria-modal="true"
          aria-label="Command menu"
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              e.preventDefault();
              close();
            } else if (e.key === 'ArrowDown') {
              e.preventDefault();
              setActive((a) => Math.min(a + 1, results.length - 1));
            } else if (e.key === 'ArrowUp') {
              e.preventDefault();
              setActive((a) => Math.max(a - 1, 0));
            } else if (e.key === 'Enter') {
              e.preventDefault();
              run(results[active]);
            } else if (e.key === 'Tab') {
              e.preventDefault();
            }
          }}
        >
          <div className="cmdk-input">
            <Icon.Search />
            <input
              ref={inputRef}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search pages, actions, models, accounts…"
              role="combobox"
              aria-expanded="true"
              aria-controls="cmdk-list"
              aria-activedescendant={results[active] ? `cmdk-${active}` : undefined}
              aria-label="Search commands"
            />
          </div>
          <div className="cmdk-list" id="cmdk-list" role="listbox" ref={listRef}>
            {results.length === 0 && <div className="empty"><p>No matches for “{query}”.</p></div>}
            {results.map((c, i) => {
              const header = c.group !== lastGroup ? c.group : null;
              lastGroup = c.group;
              return (
                <div key={c.id}>
                  {header && <div className="cmdk-group">{header}</div>}
                  <button
                    id={`cmdk-${i}`}
                    data-idx={i}
                    className="cmdk-item"
                    role="option"
                    aria-selected={i === active}
                    onMouseMove={() => setActive(i)}
                    onClick={() => run(c)}
                  >
                    <c.Glyph />
                    <span>{c.label}</span>
                    {c.hint && <span className="hint-r">{c.hint}</span>}
                  </button>
                </div>
              );
            })}
          </div>
          <div className="cmdk-foot" aria-hidden>
            <span><span className="kbd">↑↓</span>move</span>
            <span><span className="kbd">↵</span>open</span>
            <span><span className="kbd">esc</span>close</span>
          </div>
        </div>
      </div>
    </>
  );
}
