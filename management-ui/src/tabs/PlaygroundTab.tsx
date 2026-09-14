/* ============================================================================
   PlaygroundTab — talk to any served model through the running proxy. Picks a
   model from the routing catalog, sends a chat completion to /v1 (same origin
   the console is served from), and reports the reply with latency and token
   usage. Authenticates with the first configured access key when one exists.
   ========================================================================== */
import { useState } from 'react';
import { useManagementQuery } from '../lib/useManagementQuery';
import { BASE, pluckArray } from '../lib/apiClient';
import type { ModelCatalogEntry, ModelRoutingResponse } from '../lib/types';
import { num } from '../lib/format';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';

interface ChatResponse {
  choices?: { message?: { content?: string } }[];
  usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
}

interface Turn {
  role: 'user' | 'assistant' | 'error';
  text: string;
  meta?: string;
}

export default function PlaygroundTab() {
  const routing = useManagementQuery<ModelRoutingResponse>('/routing/models');
  const keys = useManagementQuery<{ 'api-keys': string[] | null }>('/api-keys');

  const models = (routing.data?.models ?? []).filter((m) => !m.disabled);
  const [model, setModel] = useState('');
  const [system, setSystem] = useState('');
  const [prompt, setPrompt] = useState('');
  const [busy, setBusy] = useState(false);
  const [turns, setTurns] = useState<Turn[]>([]);

  const selected = model || models[0]?.id || '';

  async function send() {
    const question = prompt.trim();
    if (!question || !selected || busy) return;
    setBusy(true);
    setPrompt('');
    setTurns((t) => [...t, { role: 'user', text: question }]);

    const started = performance.now();
    try {
      const accessKeys = pluckArray<string>(keys.data, 'api-keys');
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      if (accessKeys.length > 0) headers.Authorization = `Bearer ${accessKeys[0]}`;

      const body: Record<string, unknown> = {
        model: selected,
        messages: [
          ...(system.trim() ? [{ role: 'system', content: system.trim() }] : []),
          { role: 'user', content: question },
        ],
        stream: false,
      };

      const response = await fetch(`${BASE}/v1/chat/completions`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });
      const latency = Math.round(performance.now() - started);
      const data = (await response.json()) as ChatResponse;

      if (!response.ok) {
        const detail =
          (data as { error?: { message?: string } }).error?.message ?? `HTTP ${response.status}`;
        setTurns((t) => [...t, { role: 'error', text: detail, meta: `${latency} ms` }]);
      } else {
        const reply = data.choices?.[0]?.message?.content ?? '(empty response)';
        const usage = data.usage;
        const meta = [
          `${latency} ms`,
          usage?.total_tokens
            ? `${num(usage.prompt_tokens ?? 0)} in · ${num(usage.completion_tokens ?? 0)} out`
            : undefined,
        ]
          .filter(Boolean)
          .join(' · ');
        setTurns((t) => [...t, { role: 'assistant', text: reply, meta }]);
      }
    } catch {
      setTurns((t) => [
        ...t,
        { role: 'error', text: 'Could not reach the proxy — is it running?', meta: `${Math.round(performance.now() - started)} ms` },
      ]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="view">
      <PageHeader
        title="Playground"
        sub="Send a real request through the proxy — verify routing, keys, and model health."
      />

      <div className="pg">
        <div className="glass-panel card pg-form">
          <SectionHeader Glyph={Icon.Play} title="Request" sub="Runs against your live accounts" />

          <div className="field">
            <label htmlFor="pg-model">Model</label>
            <select
              id="pg-model"
              className="inp mono"
              value={selected}
              onChange={(e) => setModel(e.target.value)}
            >
              {models.length === 0 && <option value="">No models served</option>}
              {models.map((m: ModelCatalogEntry) => (
                <option key={m.id} value={m.id}>
                  {m.id}
                  {m.providers?.length ? ` — ${m.providers.join(', ')}` : ''}
                </option>
              ))}
            </select>
          </div>

          <div className="field">
            <label htmlFor="pg-system">System prompt (optional)</label>
            <textarea
              id="pg-system"
              className="inp"
              placeholder="You are a helpful assistant…"
              value={system}
              onChange={(e) => setSystem(e.target.value)}
              rows={3}
            />
          </div>

          <div className="field">
            <label htmlFor="pg-prompt">Prompt</label>
            <textarea
              id="pg-prompt"
              className="inp"
              placeholder="Ask anything… (⌘/Ctrl + Enter to send)"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onKeyDown={(e) => {
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') void send();
              }}
              rows={5}
            />
          </div>

          <button
            className="btn btn-primary"
            onClick={send}
            disabled={busy || !prompt.trim() || !selected}
          >
            <Icon.Send />
            <span>{busy ? 'Sending…' : 'Send request'}</span>
          </button>
        </div>

        <div className="glass-panel card pg-out">
          <SectionHeader
            Glyph={Icon.List}
            title="Response"
            sub={selected ? `via ${selected}` : 'pick a model'}
            trail={
              turns.length > 0 ? (
                <button className="btn btn-ghost btn-sm" onClick={() => setTurns([])}>
                  <Icon.X />
                  <span>Clear</span>
                </button>
              ) : undefined
            }
          />
          {turns.length === 0 ? (
            <p className="small">
              Nothing yet. Pick a model, write a prompt, and send — the reply, latency, and token
              usage show up here.
            </p>
          ) : (
            <div className="stack-sm">
              {turns.map((turn, i) =>
                turn.role === 'error' ? (
                  <div className="pg-msg error" key={i}>
                    <span className="role">Error</span>
                    <br />
                    {turn.text}
                  </div>
                ) : (
                  <div className={`pg-msg ${turn.role}`} key={i}>
                    <span className="role">
                      {turn.role === 'user' ? (
                        'You'
                      ) : (
                        <>
                          <Icon.Zap />
                          {selected}
                        </>
                      )}
                      {turn.meta && <span style={{ textTransform: 'none', letterSpacing: 0 }}>· {turn.meta}</span>}
                    </span>
                    <br />
                    {turn.text}
                  </div>
                ),
              )}
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
