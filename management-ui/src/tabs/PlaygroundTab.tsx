/* ============================================================================
   PlaygroundTab — chat with any served model through the running proxy, as a
   real conversation (history is sent each turn). The reply reports latency and
   token usage, so this doubles as a routing and health check. Uses the first
   access key when one exists.
   ========================================================================== */
import { useEffect, useMemo, useRef, useState } from 'react';
import { BASE } from '../lib/apiClient';
import { num } from '../lib/format';
import { providerMeta } from '../lib/providers';
import { useAccessKeys, useRouting } from '../lib/useConsoleData';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import CopyButton from '../components/CopyButton';

interface ChatResponse {
  choices?: { message?: { content?: string } }[];
  usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
  error?: { message?: string };
}
interface Turn {
  role: 'user' | 'assistant' | 'error';
  text: string;
  model?: string;
  meta?: string;
}

const MODEL_KEY = 'vr_pg_model';
const SUGGESTIONS = ['Say hello in five words.', 'Which model are you?', 'Write a haiku about routers.'];

export default function PlaygroundTab() {
  const routing = useRouting();
  const { keys } = useAccessKeys();
  const models = useMemo(() => (routing.data?.models ?? []).filter((m) => !m.disabled).sort((a, b) => a.id.localeCompare(b.id)), [routing.data]);

  const [model, setModel] = useState(() => {
    try {
      return localStorage.getItem(MODEL_KEY) ?? '';
    } catch {
      return '';
    }
  });
  const [system, setSystem] = useState('');
  const [prompt, setPrompt] = useState('');
  const [busy, setBusy] = useState(false);
  const [turns, setTurns] = useState<Turn[]>([]);
  const logRef = useRef<HTMLDivElement>(null);
  const abortRef = useRef<AbortController | null>(null);

  const selected = models.some((m) => m.id === model) ? model : models[0]?.id ?? '';

  useEffect(() => {
    logRef.current?.scrollTo({ top: logRef.current.scrollHeight, behavior: 'smooth' });
  }, [turns, busy]);

  useEffect(() => () => abortRef.current?.abort(), []);

  function pickModel(id: string) {
    setModel(id);
    try {
      localStorage.setItem(MODEL_KEY, id);
    } catch {
      /* storage unavailable — selection just won't persist */
    }
  }

  async function send(text?: string) {
    const question = (text ?? prompt).trim();
    if (!question || !selected || busy) return;
    setBusy(true);
    setPrompt('');
    const history = turns.filter((t) => t.role !== 'error');
    setTurns((t) => [...t, { role: 'user', text: question }]);

    const controller = new AbortController();
    abortRef.current = controller;
    const started = performance.now();
    try {
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      if (keys.length > 0) headers.Authorization = `Bearer ${keys[0]}`;
      const response = await fetch(`${BASE}/v1/chat/completions`, {
        method: 'POST',
        headers,
        signal: controller.signal,
        body: JSON.stringify({
          model: selected,
          stream: false,
          messages: [
            ...(system.trim() ? [{ role: 'system', content: system.trim() }] : []),
            ...history.map((t) => ({ role: t.role, content: t.text })),
            { role: 'user', content: question },
          ],
        }),
      });
      const latency = Math.round(performance.now() - started);
      const data = (await response.json().catch(() => ({}))) as ChatResponse;
      if (!response.ok) {
        setTurns((t) => [...t, { role: 'error', text: data.error?.message ?? `The proxy answered with HTTP ${response.status}.`, meta: `${latency} ms` }]);
      } else {
        const u = data.usage;
        const meta = [`${num(latency)} ms`, u?.total_tokens ? `${num(u.prompt_tokens ?? 0)} in · ${num(u.completion_tokens ?? 0)} out` : undefined].filter(Boolean).join(' · ');
        setTurns((t) => [...t, { role: 'assistant', text: data.choices?.[0]?.message?.content || '(empty response)', model: selected, meta }]);
      }
    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        setTurns((t) => [...t, { role: 'error', text: 'Stopped.' }]);
      } else {
        setTurns((t) => [...t, { role: 'error', text: "Couldn't reach the proxy. Is it running?" }]);
      }
    } finally {
      abortRef.current = null;
      setBusy(false);
    }
  }

  return (
    <section className="view" aria-labelledby="page-title">
      <PageHeader
        title="Playground"
        sub="Send a real request through the proxy to check a model, an account, or your keys."
        actions={
          turns.length > 0 && (
            <button className="btn btn-glass" onClick={() => setTurns([])} disabled={busy}>
              <Icon.Refresh />
              New chat
            </button>
          )
        }
      />

      <div className="pg">
        <div className="glass chat">
          <div className="chat-log" ref={logRef} aria-live="polite">
            {turns.length === 0 ? (
              <div className="chat-empty">
                <h3>Try a model</h3>
                <p>Pick a model on the right, then ask something. You'll see the reply, how long it took, and the tokens used.</p>
                <div className="suggestions">
                  {SUGGESTIONS.map((s) => (
                    <button key={s} className="chip" onClick={() => void send(s)} disabled={!selected}>
                      {s}
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              turns.map((t, i) => (
                <div className={`msg ${t.role}`} key={i}>
                  <div className="msg-meta">
                    {t.role === 'user' ? 'You' : t.role === 'error' ? (<><Icon.Alert /> Error</>) : (<><Icon.Sparkles /> <span className="mono">{t.model}</span></>)}
                    {t.meta && <span>· {t.meta}</span>}
                    {t.role === 'assistant' && <CopyButton value={t.text} label="Copy reply" toastText="Reply copied" />}
                  </div>
                  <div className="msg-body">{t.text}</div>
                </div>
              ))
            )}
            {busy && (
              <div className="msg assistant pending" aria-label="Waiting for reply">
                <div className="msg-body">
                  <i />
                  <i />
                  <i />
                </div>
              </div>
            )}
          </div>
          <form
            className="composer"
            onSubmit={(e) => {
              e.preventDefault();
              void send();
            }}
          >
            <textarea
              className="inp"
              placeholder={selected ? `Message ${selected}` : 'No models are being served'}
              value={prompt}
              rows={1}
              onChange={(e) => {
                setPrompt(e.target.value);
                e.target.style.height = 'auto';
                e.target.style.height = `${Math.min(e.target.scrollHeight, 200)}px`;
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  void send();
                }
              }}
              aria-label="Message"
              disabled={!selected}
            />
            {busy ? (
              <button type="button" className="btn btn-glass" aria-label="Stop" onClick={() => abortRef.current?.abort()}>
                <Icon.Stop />
              </button>
            ) : (
              <button type="submit" className="btn btn-primary" aria-label="Send" disabled={!prompt.trim() || !selected}>
                <Icon.Send />
              </button>
            )}
          </form>
        </div>

        <aside className="glass panel stack" style={{ gap: 'var(--s-4)' }} aria-label="Request settings">
          <SectionHeader Glyph={Icon.Settings} title="Request" />
          <div className="field">
            <label htmlFor="pg-model">Model</label>
            <select id="pg-model" className="inp mono" value={selected} onChange={(e) => pickModel(e.target.value)} disabled={!models.length}>
              {models.length === 0 && <option value="">No models served</option>}
              {models.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.id}
                </option>
              ))}
            </select>
            {selected && (
              <span className="hint">
                Served by {(models.find((m) => m.id === selected)?.providers ?? []).map((p) => providerMeta(p).label).join(', ') || 'no account'}
              </span>
            )}
          </div>
          <div className="field">
            <label htmlFor="pg-system">System prompt</label>
            <textarea id="pg-system" className="inp" rows={4} placeholder="Optional" value={system} onChange={(e) => setSystem(e.target.value)} />
          </div>
          <p className="hint">
            Enter to send · Shift+Enter for a new line. {keys.length ? 'Uses your first access key.' : 'No access key needed.'}
          </p>
        </aside>
      </div>
    </section>
  );
}
