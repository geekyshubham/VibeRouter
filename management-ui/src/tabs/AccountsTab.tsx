/* ============================================================================
   AccountsTab — OAuth credentials under ~/.cli-proxy-api, grouped by provider.
   Filter by state (all / active / needs attention / disabled) or search. Each
   account can be switched on or off in place (optimistic, with Undo), have its
   path copied, or be removed after an explicit confirmation.
   Endpoints: GET /auth-files · PATCH /auth-files/status · DELETE /auth-files
   ========================================================================== */
import { useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import apiClient from '../lib/apiClient';
import type { AuthFile } from '../lib/types';
import { plural, timeAgo } from '../lib/format';
import { providerMeta } from '../lib/providers';
import { accountState, STATE_LABEL, STATE_TONE, type AccountState } from '../lib/health';
import { useAuthFiles } from '../lib/useConsoleData';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import QueryError from '../components/QueryError';
import ProviderLogo from '../components/ProviderLogo';
import Sparkline from '../components/Sparkline';
import Switch from '../components/Switch';
import CopyButton from '../components/CopyButton';
import { useToast } from '../context/ToastContext';
import { useConfirm } from '../context/ConfirmContext';

type Filter = 'all' | AccountState;
const FILTERS: { id: Filter; label: string }[] = [
  { id: 'all', label: 'All' },
  { id: 'active', label: 'Active' },
  { id: 'issue', label: 'Needs attention' },
  { id: 'disabled', label: 'Disabled' },
];
const KEY = ['mgmt', '/auth-files'];

export default function AccountsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const confirm = useConfirm();
  const q = useAuthFiles();
  const [params, setParams] = useSearchParams();
  const [busy, setBusy] = useState<string | null>(null);

  const search = params.get('q') ?? '';
  const filter = (params.get('state') as Filter) || 'all';
  const setParam = (key: string, value: string) => {
    const next = new URLSearchParams(params);
    if (value && value !== 'all') next.set(key, value);
    else next.delete(key);
    setParams(next, { replace: true });
  };

  const files = q.files;
  const counts = useMemo(() => {
    const c: Record<Filter, number> = { all: files.length, active: 0, issue: 0, disabled: 0 };
    files.forEach((f) => c[accountState(f)]++);
    return c;
  }, [files]);

  const groups = useMemo(() => {
    const needle = search.trim().toLowerCase();
    const matching = files.filter((f) => {
      if (filter !== 'all' && accountState(f) !== filter) return false;
      if (!needle) return true;
      const meta = providerMeta(f.provider || f.type);
      return `${f.label ?? ''} ${f.name} ${meta.label}`.toLowerCase().includes(needle);
    });
    const map = new Map<string, AuthFile[]>();
    for (const f of matching) {
      const key = providerMeta(f.provider || f.type || f.name).label;
      map.set(key, [...(map.get(key) ?? []), f]);
    }
    return [...map.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  }, [files, search, filter]);

  const setDisabled = async (file: AuthFile, disabled: boolean, undoable = true) => {
    setBusy(file.name);
    const previous = qc.getQueryData(KEY);
    // Optimistic: flip in the cache now; roll back on failure.
    qc.setQueryData<{ files: AuthFile[] | null }>(KEY, (old) =>
      old ? { ...old, files: (old.files ?? []).map((f) => (f.name === file.name ? { ...f, disabled } : f)) } : old,
    );
    try {
      // PatchAuthFileStatus reads both fields from the JSON body; a name in the
      // query string alone is rejected with 400.
      await apiClient.patch('/auth-files/status', { name: file.name, disabled });
      if (undoable) {
        toast(`${file.label || file.name} ${disabled ? 'disabled' : 'enabled'}`, 'ok', {
          action: { label: 'Undo', run: () => void setDisabled({ ...file, disabled }, !disabled, false) },
        });
      }
    } catch {
      qc.setQueryData(KEY, previous);
      toast(`Couldn't ${disabled ? 'disable' : 'enable'} ${file.label || file.name}`, 'bad');
    } finally {
      setBusy(null);
      void qc.invalidateQueries({ queryKey: KEY });
    }
  };

  const remove = async (file: AuthFile) => {
    const ok = await confirm({
      title: `Remove ${file.label || file.name}?`,
      body: 'This deletes the saved sign-in from disk. You can add the account again from the menu bar.',
      confirmLabel: 'Remove account',
      danger: true,
    });
    if (!ok) return;
    setBusy(file.name);
    try {
      await apiClient.del(`/auth-files?name=${encodeURIComponent(file.name)}`);
      toast('Account removed', 'ok');
      await qc.invalidateQueries({ queryKey: KEY });
    } catch {
      toast("Couldn't remove the account", 'bad');
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="view" aria-labelledby="page-title">
      <PageHeader
        title="Accounts"
        sub="Signed-in providers VibeRouter rotates through. Turn one off to take it out of rotation without signing out."
        actions={
          <button className="btn btn-glass" onClick={() => void q.refetch()} disabled={q.isFetching}>
            <Icon.Refresh />
            Refresh
          </button>
        }
      />

      <div className="glass panel">
        <div className="toolbar">
          <label className="search">
            <Icon.Search />
            <input
              className="inp"
              placeholder="Search accounts"
              value={search}
              onChange={(e) => setParam('q', e.target.value)}
              aria-label="Search accounts"
            />
          </label>
          <div className="chips" role="group" aria-label="Filter by state">
            {FILTERS.map((f) => (
              <button
                key={f.id}
                className="chip"
                aria-pressed={filter === f.id}
                onClick={() => setParam('state', f.id)}
                disabled={f.id !== 'all' && counts[f.id] === 0 && filter !== f.id}
              >
                {f.label}
                <span className="n">{counts[f.id]}</span>
              </button>
            ))}
          </div>
        </div>

        {q.isLoading ? (
          <LoadingBlock rows={5} />
        ) : q.isError ? (
          <QueryError what="accounts" onRetry={() => void q.refetch()} />
        ) : files.length === 0 ? (
          <EmptyState Glyph={Icon.Users} title="No accounts yet">
            Open the VibeRouter menu bar and sign in to a provider. Accounts appear here as soon as the sign-in finishes.
          </EmptyState>
        ) : groups.length === 0 ? (
          <EmptyState
            Glyph={Icon.Search}
            title="No matching accounts"
            action={
              <button className="btn btn-glass btn-sm" onClick={() => setParams({}, { replace: true })}>
                Clear filters
              </button>
            }
          >
            Nothing matches {search ? `“${search}”` : 'this filter'}.
          </EmptyState>
        ) : (
          groups.map(([label, list]) => (
            <div className="pgroup" key={label}>
              <div className="pgroup-head">
                <ProviderLogo provider={list[0].provider || list[0].type} size={26} />
                <span className="pgroup-name">{label}</span>
                <span className="pgroup-count">{plural(list.length, 'account')}</span>
              </div>
              <div className="list">
                {list.map((file) => {
                  const state = accountState(file);
                  return (
                    <div className={`list-row ${state === 'disabled' ? 'dim' : ''}`} key={file.name}>
                      <div className="row-main">
                        <ProviderLogo provider={file.provider || file.type} />
                        <div className="row-info">
                          <div className="row-title">
                            <span>{file.label || file.name}</span>
                          </div>
                          <div className="row-meta mono" title={file.status_message || file.name}>
                            {state === 'issue' && file.status_message ? file.status_message : file.name}
                          </div>
                        </div>
                      </div>
                      <div className="row-aside">
                        <Sparkline values={file.recent_requests} />
                        <span className={`pill ${STATE_TONE[state]}`}>
                          <span className={`dot ${STATE_TONE[state] === 'mut' ? '' : STATE_TONE[state]}`} aria-hidden />
                          {state === 'issue' && file.status && file.status.toLowerCase() !== 'error'
                            ? file.status
                            : STATE_LABEL[state]}
                        </span>
                        <span className="small tnum" style={{ minWidth: 56, textAlign: 'right' }} title="Last updated">
                          {timeAgo(file.updated_at || file.modtime)}
                        </span>
                        <div className="row-actions">
                          <Switch
                            checked={!file.disabled}
                            onChange={(on) => void setDisabled(file, !on)}
                            label={`${file.label || file.name} in rotation`}
                            disabled={busy === file.name}
                          />
                          <CopyButton value={file.path || file.name} label="Copy file path" toastText="Path copied" />
                          <button
                            className="icon-btn danger"
                            aria-label={`Remove ${file.label || file.name}`}
                            title="Remove account"
                            disabled={busy === file.name}
                            onClick={() => void remove(file)}
                          >
                            <Icon.Trash />
                          </button>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          ))
        )}
      </div>
    </section>
  );
}
