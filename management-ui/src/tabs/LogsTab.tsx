/* ============================================================================
   LogsTab — recent request log lines with search and level filtering. The
   backend returns {"error":"logging to file disabled"} when file logging is
   off, and a logs array otherwise; we detect the error envelope and render a
   notice + toggle instead of calling .map on a non-array.
   ========================================================================== */
import { useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { asArray, errorMessageOf } from '../lib/apiClient';
import type { BackendConfig, LogLine } from '../lib/types';
import { timeAgo } from '../lib/format';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import SectionHeader from '../components/SectionHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import { useToast } from '../context/ToastContext';

function normalizeLogs(data: unknown): LogLine[] {
  // Backend (GetLogs) returns {lines: string[], line-count, latest-timestamp}
  // when logging is on. Also tolerate a bare array or {logs:[...]}.
  const raw: unknown =
    Array.isArray(data)
      ? data
      : data && typeof data === 'object'
        ? ((data as Record<string, unknown>).lines ?? (data as Record<string, unknown>).logs)
        : undefined;

  const arr = asArray<unknown>(raw);
  return arr.map((item): LogLine => {
    if (typeof item === 'string') return { message: item };
    if (item && typeof item === 'object') return item as LogLine;
    return { message: String(item) };
  });
}

function levelOf(line: LogLine): string {
  return (line.level ?? '').toString().toLowerCase() || 'info';
}

export default function LogsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const cfg = useManagementQuery<BackendConfig>('/config');
  const loggingOn = Boolean(cfg.data?.['logging-to-file']);
  const [filter, setFilter] = useState('');
  const [level, setLevel] = useState('all');
  const [follow, setFollow] = useState(true);

  const logsQ = useManagementQuery<unknown>('/logs', {
    enabled: loggingOn && follow,
    refetchInterval: follow && loggingOn ? 5000 : undefined,
  });

  const disabledMsg = errorMessageOf(logsQ.data);
  const allLines = useMemo(() => normalizeLogs(logsQ.data), [logsQ.data]);

  const lines = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    return allLines
      .filter((l) => level === 'all' || levelOf(l) === level)
      .filter(
        (l) =>
          !needle ||
          `${l.message ?? ''} ${l.model ?? ''} ${l.status ?? ''}`.toLowerCase().includes(needle),
      );
  }, [allLines, filter, level]);

  async function toggleLogging(next: boolean) {
    try {
      await apiClient.patch('/logging-to-file', { value: next });
      await qc.invalidateQueries({ queryKey: ['mgmt', '/config'] });
      await qc.invalidateQueries({ queryKey: ['mgmt', '/logs'] });
      toast(next ? 'File logging enabled' : 'File logging disabled', 'ok');
    } catch {
      toast('Could not change logging', 'bad');
    }
  }

  return (
    <section className="view">
      <PageHeader
        title="Logs"
        sub="Recent calls proxied through VibeRouter."
        trail={
          <>
            <label className="search">
              <Icon.Search />
              <input
                className="inp"
                placeholder="Search logs…"
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                aria-label="Search logs"
              />
            </label>
            <select
              className="inp"
              style={{ width: 'auto' }}
              value={level}
              onChange={(e) => setLevel(e.target.value)}
              aria-label="Filter by level"
            >
              <option value="all">All levels</option>
              <option value="info">Info</option>
              <option value="warning">Warning</option>
              <option value="error">Error</option>
              <option value="debug">Debug</option>
            </select>
            <div className="row">
              <span className="small">Follow</span>
              <button
                className={`sw ${follow ? 'on' : ''}`}
                role="switch"
                aria-checked={follow}
                aria-label="Toggle live refresh"
                onClick={() => setFollow((f) => !f)}
              />
            </div>
          </>
        }
      />

      <div className="glass-panel card">
        {cfg.isLoading ? (
          <LoadingBlock rows={4} />
        ) : !loggingOn || disabledMsg ? (
          <div>
            <SectionHeader Glyph={Icon.List} title="Request logs" sub="File logging is off" />
            <EmptyState
              Glyph={Icon.List}
              title="File logging is off"
              action={
                <button className="btn btn-primary" onClick={() => toggleLogging(true)}>
                  <Icon.Power />
                  <span>Enable logging</span>
                </button>
              }
            >
              {disabledMsg ?? 'Turn on file logging to capture request lines here.'}
            </EmptyState>
          </div>
        ) : logsQ.isLoading ? (
          <LoadingBlock rows={4} />
        ) : lines.length === 0 ? (
          <EmptyState Glyph={Icon.List} title={allLines.length === 0 ? 'No log lines yet' : 'No matches'}>
            {allLines.length === 0
              ? 'Logging is on, but nothing has been recorded yet. Make a request through the proxy.'
              : `Nothing matches “${filter || level}”.`}
          </EmptyState>
        ) : (
          <table className="tbl">
            <thead>
              <tr>
                <th>Time</th>
                <th>Level</th>
                <th>Model</th>
                <th>Status</th>
                <th>Message</th>
              </tr>
            </thead>
            <tbody>
              {lines.slice(0, 200).map((l, i) => {
                const lvl = levelOf(l);
                return (
                  <tr key={i}>
                    <td className="mono">{timeAgo(l.time || l.timestamp)}</td>
                    <td>
                      <span
                        className={`pill ${lvl.includes('err') ? 'bad' : lvl.includes('warn') ? 'warn' : 'mut'}`}
                      >
                        {l.level ?? 'info'}
                      </span>
                    </td>
                    <td className="mono">{l.model ?? '—'}</td>
                    <td>{l.status ?? '—'}</td>
                    <td>{l.message ?? '—'}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}
