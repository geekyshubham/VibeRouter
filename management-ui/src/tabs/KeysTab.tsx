/* ============================================================================
   KeysTab — two sections:
     1. Proxy access keys (GET/PUT /api-keys) — the Bearer keys clients present.
     2. Provider API keys (GET/PUT /{gemini,claude,codex,vertex}-api-key) — keys
        the proxy uses upstream.
   Every list is normalized via pluckArray. Keys are masked; full value copyable.
   ========================================================================== */
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { pluckArray } from '../lib/apiClient';
import { maskKey } from '../lib/format';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import { useToast } from '../context/ToastContext';

/** Provider api-key entry shape: the backend stores objects, not raw strings. */
interface ProviderKeyEntry {
  'api-key': string;
  'auth-index'?: string;
}

const PROVIDER_KEYS = [
  { path: '/gemini-api-key', field: 'gemini-api-key', label: 'Gemini' },
  { path: '/claude-api-key', field: 'claude-api-key', label: 'Claude' },
  { path: '/codex-api-key', field: 'codex-api-key', label: 'Codex' },
  { path: '/vertex-api-key', field: 'vertex-api-key', label: 'Vertex AI' },
] as const;

function KeyRow({ value, onCopy, onDelete }: { value: string; onCopy: () => void; onDelete: () => void }) {
  const [revealed, setRevealed] = useState(false);
  return (
    <div className="lrow">
      <span className="swatch" />
      <div className="info">
        <div className="m">{revealed ? value : maskKey(value, 6)}</div>
      </div>
      <div className="row">
        <button className="btn-icon" title="Reveal" onClick={() => setRevealed((r) => !r)}>
          <Icon.Eye />
        </button>
        <button className="btn-icon" title="Copy" onClick={onCopy}>
          <Icon.Copy />
        </button>
        <button className="btn-icon btn-danger" title="Delete" onClick={onDelete}>
          <Icon.Trash />
        </button>
      </div>
    </div>
  );
}

export default function KeysTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const proxyKeys = useManagementQuery<{ 'api-keys': string[] | null }>('/api-keys');
  const [adding, setAdding] = useState('');

  const keys = pluckArray<string>(proxyKeys.data, 'api-keys');

  async function copy(v: string) {
    try {
      await navigator.clipboard.writeText(v);
      toast('Copied to clipboard', 'ok');
    } catch {
      toast('Copy failed', 'bad');
    }
  }

  async function saveProxyKeys(next: string[]) {
    // putStringList tries a RAW array first, then {"items":[...]} — but the items
    // wrapper rejects an empty list (400). Send the raw array so clearing the last
    // key works too (a raw [] is accepted).
    await apiClient.put('/api-keys', next);
    await qc.invalidateQueries({ queryKey: ['mgmt', '/api-keys'] });
  }

  async function addProxyKey() {
    const v = adding.trim();
    if (!v) return;
    if (keys.includes(v)) {
      toast('Key already exists', 'bad');
      setAdding('');
      return;
    }
    try {
      await saveProxyKeys([...keys, v]);
      setAdding('');
      toast('Key added', 'ok');
    } catch {
      toast('Could not add key', 'bad');
    }
  }

  // Remove by index so a single row is dropped even if a duplicate slipped in.
  async function removeProxyKeyAt(i: number) {
    try {
      await saveProxyKeys(keys.filter((_, idx) => idx !== i));
      toast('Key removed', 'ok');
    } catch {
      toast('Could not remove key', 'bad');
    }
  }

  return (
    <section className="view">
      <PageHeader
        title="Keys"
        sub="Who can call the proxy, and what it uses upstream."
      />
      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.Key}
          title="Proxy access keys"
          sub="Bearer keys clients present to reach the proxy"
        />

        <div className="row" style={{ marginBottom: 'var(--s-lg)' }}>
          <input
            className="inp mono"
            placeholder="New access key…"
            value={adding}
            onChange={(e) => setAdding(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && addProxyKey()}
          />
          <button className="btn btn-primary" onClick={addProxyKey} disabled={!adding.trim()}>
            <Icon.Plus />
            <span>Add</span>
          </button>
        </div>

        {proxyKeys.isLoading ? (
          <LoadingBlock rows={2} />
        ) : keys.length === 0 ? (
          <EmptyState Glyph={Icon.Key} title="No access keys">
            Without an access key the proxy accepts any Bearer token on localhost. Add one to require
            authentication.
          </EmptyState>
        ) : (
          <div className="stack">
            {keys.map((k, i) => (
              <KeyRow key={`${k}-${i}`} value={k} onCopy={() => copy(k)} onDelete={() => removeProxyKeyAt(i)} />
            ))}
          </div>
        )}
      </div>

      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.Server}
          title="Provider API keys"
          sub="Keys the proxy uses to reach upstream providers"
        />
        <ProviderKeyGroups onCopy={copy} />
      </div>
    </section>
  );
}

function ProviderKeyGroups({ onCopy }: { onCopy: (v: string) => void }) {
  return (
    <div className="stack">
      {PROVIDER_KEYS.map((p) => (
        <ProviderKeyBlock key={p.path} {...p} onCopy={onCopy} />
      ))}
    </div>
  );
}

function ProviderKeyBlock({
  path,
  field,
  label,
  onCopy,
}: {
  path: string;
  field: string;
  label: string;
  onCopy: (v: string) => void;
}) {
  const qc = useQueryClient();
  const { toast } = useToast();
  // Provider keys are OBJECTS {"api-key":"...","auth-index":"..."}, not strings.
  const q = useManagementQuery<Record<string, ProviderKeyEntry[] | null>>(path);
  const [adding, setAdding] = useState('');
  const entries = pluckArray<ProviderKeyEntry>(q.data, field).filter(
    (e) => e && typeof e['api-key'] === 'string',
  );

  // PUT expects {"items":[{"api-key":"..."}]} with at least one item (empty
  // items → 400). Use it only to add. Removal uses DELETE ?api-key= so the last
  // key can be cleared too.
  async function addKey(value: string) {
    const next = [...entries.map((e) => ({ 'api-key': e['api-key'] })), { 'api-key': value }];
    await apiClient.put(path, { items: next });
    await qc.invalidateQueries({ queryKey: ['mgmt', path] });
  }

  async function removeKey(value: string) {
    await apiClient.del(`${path}?api-key=${encodeURIComponent(value)}`);
    await qc.invalidateQueries({ queryKey: ['mgmt', path] });
  }

  return (
    <div className="cfg-row">
      <div className="cfg-label">
        <div className="ct">{label}</div>
        <div className="cd">
          {entries.length ? `${entries.length} key${entries.length > 1 ? 's' : ''}` : 'no keys set'}
        </div>
        {entries.length > 0 && (
          <div className="stack" style={{ marginTop: 'var(--s-sm)' }}>
            {entries.map((entry) => {
              const v = entry['api-key'];
              return (
                <div className="row" key={entry['auth-index'] ?? v}>
                  <span className="tag">{maskKey(v, 6)}</span>
                  <button className="btn-icon btn-sm" title="Copy" onClick={() => onCopy(v)}>
                    <Icon.Copy />
                  </button>
                  <button
                    className="btn-icon btn-sm btn-danger"
                    title="Remove"
                    onClick={async () => {
                      try {
                        await removeKey(v);
                        toast(`${label} key removed`, 'ok');
                      } catch {
                        toast('Could not remove key', 'bad');
                      }
                    }}
                  >
                    <Icon.Trash />
                  </button>
                </div>
              );
            })}
          </div>
        )}
      </div>
      <div className="cfg-ctl">
        <input
          className="inp mono"
          placeholder={`${label} key…`}
          value={adding}
          onChange={(e) => setAdding(e.target.value)}
        />
        <button
          className="btn btn-soft btn-sm"
          disabled={!adding.trim()}
          onClick={async () => {
            const v = adding.trim();
            if (!v) return;
            try {
              await addKey(v);
              setAdding('');
              toast(`${label} key added`, 'ok');
            } catch {
              toast('Could not add key', 'bad');
            }
          }}
        >
          <Icon.Plus />
        </button>
      </div>
    </div>
  );
}
