/* ============================================================================
   AccountsTab — lists OAuth token files under ~/.cli-proxy-api with live
   health, request-activity sparklines (recent_requests), and a search filter.
   Operator can toggle a file disabled (PATCH /auth-files/status), delete it
   (DELETE /auth-files?name=), or copy its path.
   ========================================================================== */
import { useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { pluckArray } from '../lib/apiClient';
import type { AuthFile } from '../lib/types';
import { timeAgo } from '../lib/format';
import { providerMeta, providerTint } from '../lib/providers';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import Sparkline from '../components/Sparkline';
import { useToast } from '../context/ToastContext';

export default function AccountsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const q = useManagementQuery<{ files: AuthFile[] | null }>('/auth-files');
  const [busy, setBusy] = useState<string | null>(null);
  const [filter, setFilter] = useState('');

  const files = pluckArray<AuthFile>(q.data, 'files').filter((f) => f && f.name);
  const filtered = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    if (!needle) return files;
    return files.filter((f) =>
      `${f.label ?? ''} ${f.name} ${f.provider ?? ''}`.toLowerCase().includes(needle),
    );
  }, [files, filter]);

  const healthyCount = files.filter(
    (f) => !f.disabled && !f.unavailable && f.status?.toLowerCase() !== 'error',
  ).length;

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['mgmt', '/auth-files'] });
    toast('Accounts refreshed', 'ok');
  }

  async function toggleDisabled(file: AuthFile) {
    setBusy(file.name);
    try {
      await apiClient.patch(`/auth-files/status?name=${encodeURIComponent(file.name)}`, {
        disabled: !file.disabled,
      });
      toast(file.disabled ? 'Account enabled' : 'Account disabled', 'ok');
      await refresh();
    } catch {
      toast('Could not update account', 'bad');
    } finally {
      setBusy(null);
    }
  }

  async function remove(file: AuthFile) {
    if (!confirm(`Delete ${file.name}? This removes the token file.`)) return;
    setBusy(file.name);
    try {
      await apiClient.del(`/auth-files?name=${encodeURIComponent(file.name)}`);
      toast('Account removed', 'ok');
      await refresh();
    } catch {
      toast('Could not remove account', 'bad');
    } finally {
      setBusy(null);
    }
  }

  async function copyPath(file: AuthFile) {
    try {
      await navigator.clipboard.writeText(file.path || file.name);
      toast('Path copied', 'ok');
    } catch {
      toast('Copy failed', 'bad');
    }
  }

  return (
    <section className="view">
      <PageHeader
        title="Accounts"
        sub="OAuth credentials the proxy rotates through — health, activity, and availability."
        trail={
          <>
            <label className="search">
              <Icon.Search />
              <input
                className="inp"
                placeholder="Filter accounts…"
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                aria-label="Filter accounts"
              />
            </label>
            <button className="btn btn-soft btn-sm" onClick={refresh} disabled={q.isFetching}>
              <Icon.Refresh />
              <span>Refresh</span>
            </button>
          </>
        }
      />

      <div className="glass-panel card">
        <SectionHeader
          Glyph={Icon.Users}
          title={`${filtered.length} account${filtered.length === 1 ? '' : 's'}`}
          sub={`${healthyCount} healthy · ${files.length - healthyCount} off or degraded`}
        />

        {q.isLoading ? (
          <LoadingBlock rows={4} />
        ) : filtered.length === 0 ? (
          <EmptyState Glyph={Icon.Users} title={files.length === 0 ? 'No accounts yet' : 'No matches'}>
            {files.length === 0
              ? 'Sign in to a provider from the VibeRouter menu bar. OAuth token files will appear here.'
              : `Nothing matches “${filter}”.`}
          </EmptyState>
        ) : (
          <div className="stack">
            {filtered.map((file) => {
              const meta = providerMeta(file.provider || file.type || file.name);
              const healthy = !file.unavailable && file.status?.toLowerCase() !== 'error';
              return (
                <div className="prov" key={file.name}>
                  <span
                    className="plogo"
                    aria-hidden
                    style={{
                      width: 30,
                      height: 30,
                      background: `color-mix(in srgb, ${providerTint(file.provider || file.type)} 16%, transparent)`,
                      color: providerTint(file.provider || file.type),
                    }}
                  >
                    {meta.short}
                  </span>
                  <div className="info">
                    <div className="n">{file.label || meta.label}</div>
                    <div className="m">{file.name}</div>
                  </div>
                  <Sparkline values={file.recent_requests} />
                  <span className={`pill ${file.disabled ? 'mut' : healthy ? 'ok' : 'warn'}`}>
                    <span className={`dot ${file.disabled ? '' : healthy ? 'ok' : 'warn'}`} />
                    {file.disabled ? 'Disabled' : healthy ? 'Active' : file.status || 'Degraded'}
                  </span>
                  <span className="small">{timeAgo(file.updated_at || file.modtime)}</span>
                  <div className="row">
                    <button
                      className={`sw ${file.disabled ? '' : 'on'}`}
                      role="switch"
                      aria-checked={!file.disabled}
                      aria-label="Toggle account"
                      disabled={busy === file.name}
                      onClick={() => toggleDisabled(file)}
                    />
                    <button
                      className="btn-icon"
                      title="Copy credential path"
                      onClick={() => copyPath(file)}
                    >
                      <Icon.Copy />
                    </button>
                    <button
                      className="btn-icon btn-danger"
                      title="Delete account"
                      disabled={busy === file.name}
                      onClick={() => remove(file)}
                    >
                      <Icon.Trash />
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </section>
  );
}
