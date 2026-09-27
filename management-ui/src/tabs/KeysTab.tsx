/* ============================================================================
   KeysTab — two kinds of key, kept visually apart:
     1. Access keys (GET/PUT /api-keys): what your tools send to reach the
        proxy. None configured = any local client is accepted.
     2. Upstream provider keys (GET/PUT/DELETE /{gemini,claude,codex,vertex}-api-key):
        keys the proxy itself uses, as an alternative to signing in.
   "Generate" creates a strong random key so nobody has to invent one.
   ========================================================================== */
import { useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { pluckArray } from '../lib/apiClient';
import { maskKey, plural } from '../lib/format';
import { useAccessKeys } from '../lib/useConsoleData';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import LoadingBlock from '../components/LoadingBlock';
import QueryError from '../components/QueryError';
import CopyButton from '../components/CopyButton';
import ProviderLogo from '../components/ProviderLogo';
import { useToast } from '../context/ToastContext';
import { useConfirm } from '../context/ConfirmContext';

/** Provider api-key entry shape: the backend stores objects, not raw strings. */
interface ProviderKeyEntry {
  'api-key': string;
  'auth-index'?: string;
}

const PROVIDER_KEYS = [
  { path: '/claude-api-key', field: 'claude-api-key', label: 'Anthropic (Claude)', provider: 'claude' },
  { path: '/codex-api-key', field: 'codex-api-key', label: 'OpenAI (Codex)', provider: 'codex' },
  { path: '/gemini-api-key', field: 'gemini-api-key', label: 'Google Gemini', provider: 'gemini' },
  { path: '/vertex-api-key', field: 'vertex-api-key', label: 'Vertex AI', provider: 'vertex' },
] as const;

/** 32 random bytes → "vr-" + base64url. Uses the Web Crypto CSPRNG. */
function generateKey(): string {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  const b64 = btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `vr-${b64}`;
}

function SecretRow({ value, onRemove, label }: { value: string; onRemove: () => void; label: string }) {
  const [revealed, setRevealed] = useState(false);
  return (
    <div className="list-row">
      <div className="row-main">
        <div className="sec-icon" style={{ width: 30, height: 30 }} aria-hidden>
          <Icon.Key />
        </div>
        <span className="secret" aria-label={revealed ? undefined : `${label} ending ${value.slice(-4)}`}>
          {revealed ? value : maskKey(value, 6)}
        </span>
      </div>
      <div className="row-actions">
        <button
          className="icon-btn"
          aria-label={revealed ? `Hide ${label}` : `Show ${label}`}
          aria-pressed={revealed}
          onClick={() => setRevealed((r) => !r)}
        >
          {revealed ? <Icon.EyeOff /> : <Icon.Eye />}
        </button>
        <CopyButton value={value} label={`Copy ${label}`} toastText="Key copied" />
        <button className="icon-btn danger" aria-label={`Remove ${label}`} onClick={onRemove}>
          <Icon.Trash />
        </button>
      </div>
    </div>
  );
}

export default function KeysTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const confirm = useConfirm();
  const q = useAccessKeys();
  const [params, setParams] = useSearchParams();
  const [draft, setDraft] = useState('');
  const [saving, setSaving] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const keys = q.keys;

  // Deep link from the palette / setup checklist: /keys?new=1
  useEffect(() => {
    if (params.get('new')) {
      setDraft((d) => d || generateKey());
      inputRef.current?.focus();
      const next = new URLSearchParams(params);
      next.delete('new');
      setParams(next, { replace: true });
    }
  }, [params, setParams]);

  async function saveKeys(next: string[]) {
    // A raw array is accepted even when empty (the {"items":[...]} wrapper
    // rejects []), so clearing the last key works too.
    await apiClient.put('/api-keys', next);
    await qc.invalidateQueries({ queryKey: ['mgmt', '/api-keys'] });
  }

  async function add() {
    const v = draft.trim();
    if (!v) return;
    if (keys.includes(v)) {
      toast('That key already exists', 'bad');
      return;
    }
    setSaving(true);
    try {
      await saveKeys([...keys, v]);
      setDraft('');
      toast(keys.length === 0 ? 'Key added — clients now need it to connect' : 'Key added', 'ok');
    } catch {
      toast("Couldn't add the key", 'bad');
    } finally {
      setSaving(false);
    }
  }

  async function removeAt(i: number) {
    const last = keys.length === 1;
    const ok = await confirm({
      title: 'Remove this access key?',
      body: last
        ? 'This is the last key. Afterwards any local client can use the proxy without one.'
        : 'Tools still using this key will be refused until you give them another one.',
      confirmLabel: 'Remove key',
      danger: true,
    });
    if (!ok) return;
    try {
      // Remove by index so one row is dropped even if a duplicate slipped in.
      await saveKeys(keys.filter((_, idx) => idx !== i));
      toast('Key removed', 'ok');
    } catch {
      toast("Couldn't remove the key", 'bad');
    }
  }

  return (
    <section className="view" aria-labelledby="page-title">
      <PageHeader title="API keys" sub="Control who can use the proxy, and optionally give it provider keys to use upstream." />

      <section className="glass panel" aria-labelledby="access-title">
        <SectionHeader
          id="access-title"
          Glyph={Icon.Shield}
          title="Access keys"
          sub="Your tools send one of these as their API key"
          actions={<span className={`pill ${keys.length ? 'ok' : ''}`}>{keys.length ? 'Required' : 'Not required'}</span>}
        />

        {!q.isLoading && keys.length === 0 && (
          <div className="callout" style={{ marginBottom: 'var(--s-4)' }}>
            <Icon.Info />
            <div>
              <b>No key needed right now.</b> Any client on this Mac can use the proxy with any API key value. Add a key if
              other devices on your network can reach it.
            </div>
          </div>
        )}

        <form
          className="field"
          style={{ marginBottom: 'var(--s-4)' }}
          onSubmit={(e) => {
            e.preventDefault();
            void add();
          }}
        >
          <label htmlFor="new-key">New access key</label>
          <div className="input-row">
            <input
              id="new-key"
              ref={inputRef}
              className="inp mono"
              placeholder="Paste a key or generate one"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
            <button type="button" className="btn btn-glass" onClick={() => setDraft(generateKey())}>
              <Icon.Wand />
              Generate
            </button>
            <button type="submit" className="btn btn-primary" disabled={!draft.trim() || saving}>
              <Icon.Plus />
              Add key
            </button>
          </div>
          <span className="hint">Copy the key before you leave — you can reveal it again here any time.</span>
        </form>

        {q.isLoading ? (
          <LoadingBlock rows={2} />
        ) : q.isError ? (
          <QueryError what="access keys" onRetry={() => void q.refetch()} />
        ) : keys.length > 0 ? (
          <div className="list">
            {keys.map((k, i) => (
              <SecretRow key={`${k}-${i}`} value={k} label={`access key ${i + 1}`} onRemove={() => void removeAt(i)} />
            ))}
          </div>
        ) : null}
      </section>

      <section className="glass panel" aria-labelledby="upstream-title">
        <SectionHeader
          id="upstream-title"
          Glyph={Icon.Server}
          title="Provider API keys"
          sub="Optional. Used alongside signed-in accounts when you'd rather pay per token."
        />
        <div className="stack" style={{ gap: 'var(--s-4)' }}>
          {PROVIDER_KEYS.map((p) => (
            <ProviderKeyBlock key={p.path} {...p} />
          ))}
        </div>
      </section>
    </section>
  );
}

function ProviderKeyBlock({ path, field, label, provider }: { path: string; field: string; label: string; provider: string }) {
  const qc = useQueryClient();
  const { toast } = useToast();
  const confirm = useConfirm();
  // Provider keys are OBJECTS {"api-key":"...","auth-index":"..."}, not strings.
  const q = useManagementQuery<Record<string, ProviderKeyEntry[] | null>>(path);
  const [draft, setDraft] = useState('');
  const [open, setOpen] = useState(false);
  const entries = pluckArray<ProviderKeyEntry>(q.data, field).filter((e) => e && typeof e['api-key'] === 'string');

  // PUT needs {"items":[...]} with at least one item (empty → 400), so it's
  // only used to add. Removal uses DELETE ?api-key= so the last key can go too.
  async function add() {
    const v = draft.trim();
    if (!v) return;
    try {
      await apiClient.put(path, { items: [...entries.map((e) => ({ 'api-key': e['api-key'] })), { 'api-key': v }] });
      await qc.invalidateQueries({ queryKey: ['mgmt', path] });
      setDraft('');
      setOpen(false);
      toast(`${label} key added`, 'ok');
    } catch {
      toast("Couldn't add the key", 'bad');
    }
  }

  async function remove(value: string) {
    const ok = await confirm({ title: `Remove this ${label} key?`, confirmLabel: 'Remove key', danger: true });
    if (!ok) return;
    try {
      await apiClient.del(`${path}?api-key=${encodeURIComponent(value)}`);
      await qc.invalidateQueries({ queryKey: ['mgmt', path] });
      toast(`${label} key removed`, 'ok');
    } catch {
      toast("Couldn't remove the key", 'bad');
    }
  }

  return (
    <div>
      <div className="pgroup-head" style={{ padding: '0 0 var(--s-2)' }}>
        <ProviderLogo provider={provider} size={28} />
        <span className="pgroup-name">{label}</span>
        <span className="pgroup-count">{entries.length ? plural(entries.length, 'key') : 'No keys'}</span>
        <span className="grow" />
        {!open && (
          <button className="btn btn-ghost btn-sm" onClick={() => setOpen(true)}>
            <Icon.Plus />
            Add
          </button>
        )}
      </div>
      {entries.length > 0 && (
        <div className="list">
          {entries.map((e, i) => (
            <SecretRow key={e['auth-index'] ?? e['api-key']} value={e['api-key']} label={`${label} key ${i + 1}`} onRemove={() => void remove(e['api-key'])} />
          ))}
        </div>
      )}
      {open && (
        <form
          className="input-row"
          style={{ marginTop: 'var(--s-2)' }}
          onSubmit={(e) => {
            e.preventDefault();
            void add();
          }}
        >
          <input
            className="inp mono"
            placeholder={`${label} API key`}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            aria-label={`${label} API key`}
            autoFocus
            autoComplete="off"
            spellCheck={false}
          />
          <button type="button" className="btn btn-ghost" onClick={() => setOpen(false)}>
            Cancel
          </button>
          <button type="submit" className="btn btn-primary" disabled={!draft.trim()}>
            Save
          </button>
        </form>
      )}
      {entries.length === 0 && !open && q.isError && <QueryError what={`${label} keys`} onRetry={() => void q.refetch()} />}
    </div>
  );
}
