/* ============================================================================
   LogsTab — the proxy's log file, newest first, with level filters, search
   highlighting, live follow, and clear. The backend returns
   {"error":"logging to file disabled"} when file logging is off; that case
   renders a one-click enable instead of an empty table.
   Line format (global_logger.go): [YYYY-MM-DD HH:MM:SS] [reqid] [level] [file:line] msg
   ========================================================================== */
import { useMemo, useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useManagementQuery } from '../lib/useManagementQuery';
import apiClient, { asArray, errorMessageOf } from '../lib/apiClient';
import type { BackendConfig } from '../lib/types';
import { num } from '../lib/format';
import Icon from '../lib/icons';
import PageHeader from '../components/PageHeader';
import EmptyState from '../components/EmptyState';
import LoadingBlock from '../components/LoadingBlock';
import Switch from '../components/Switch';
import { useToast } from '../context/ToastContext';
import { useConfirm } from '../context/ConfirmContext';

interface ParsedLine {
  raw: string;
  time: string;
  date: string;
  level: 'info' | 'warn' | 'error' | 'debug' | 'other';
  message: string;
}

const LINE = /^\[(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\]\s+\[[^\]]*\]\s+\[\s*([a-z]+)\s*\]\s+(?:\[[^\]]+:\d+\]\s+)?(.*)$/i;
const LEVELS = [
  { id: 'all', label: 'All' },
  { id: 'error', label: 'Errors' },
  { id: 'warn', label: 'Warnings' },
  { id: 'info', label: 'Info' },
  { id: 'debug', label: 'Debug' },
] as const;
const LIMIT = 500;

function parse(raw: string): ParsedLine {
  const m = LINE.exec(raw);
  if (!m) return { raw, time: '', date: '', level: 'other', message: raw };
  const lvl = m[3].toLowerCase();
  const level = lvl.startsWith('err') || lvl === 'fatal' || lvl === 'panic' ? 'error' : lvl.startsWith('warn') ? 'warn' : lvl === 'debug' || lvl === 'trace' ? 'debug' : 'info';
  return { raw, date: m[1], time: m[2], level, message: m[4] };
}

function linesOf(data: unknown): string[] {
  // GetLogs returns {lines: string[]}; tolerate a bare array or {logs:[...]}.
  const raw = Array.isArray(data)
    ? data
    : data && typeof data === 'object'
      ? ((data as Record<string, unknown>).lines ?? (data as Record<string, unknown>).logs)
      : undefined;
  return asArray<unknown>(raw).map((l) => (typeof l === 'string' ? l : JSON.stringify(l)));
}

function highlight(text: string, needle: string): ReactNode {
  if (!needle) return text;
  const i = text.toLowerCase().indexOf(needle);
  if (i < 0) return text;
  return (
    <>
      {text.slice(0, i)}
      <mark>{text.slice(i, i + needle.length)}</mark>
      {text.slice(i + needle.length)}
    </>
  );
}

export default function LogsTab() {
  const qc = useQueryClient();
  const { toast } = useToast();
  const confirm = useConfirm();
  const cfg = useManagementQuery<BackendConfig>('/config');
  const loggingOn = Boolean(cfg.data?.['logging-to-file']);
  const [search, setSearch] = useState('');
  const [level, setLevel] = useState<(typeof LEVELS)[number]['id']>('all');
  const [follow, setFollow] = useState(true);

  const logsQ = useManagementQuery<unknown>(`/logs?limit=${LIMIT}`, {
    enabled: loggingOn,
    refetchInterval: follow && loggingOn ? 4000 : undefined,
  });

  const disabledMsg = errorMessageOf(logsQ.data);
  const parsed = useMemo(() => linesOf(logsQ.data).map(parse).reverse(), [logsQ.data]);
  const needle = search.trim().toLowerCase();
  const counts = useMemo(() => {
    const c = { all: parsed.length, error: 0, warn: 0, info: 0, debug: 0 } as Record<string, number>;
    parsed.forEach((l) => l.level in c && c[l.level]++);
    return c;
  }, [parsed]);
  const shown = parsed.filter((l) => (level === 'all' || l.level === level) && (!needle || l.raw.toLowerCase().includes(needle)));

  async function setLogging(next: boolean) {
    try {
      await apiClient.patch('/logging-to-file', { value: next });
      await qc.invalidateQueries({ queryKey: ['mgmt', '/config'] });
      toast(next ? 'File logging on' : 'File logging off', 'ok');
    } catch {
      toast("Couldn't change file logging", 'bad');
    }
  }

  async function clear() {
    const ok = await confirm({ title: 'Clear all log files?', body: 'The current log is emptied and rotated logs are deleted.', confirmLabel: 'Clear logs', danger: true });
    if (!ok) return;
    try {
      await apiClient.del('/logs');
      await qc.invalidateQueries({ queryKey: ['mgmt', `/logs?limit=${LIMIT}`] });
      toast('Logs cleared', 'ok');
    } catch {
      toast("Couldn't clear the logs", 'bad');
    }
  }

  const off = !cfg.isLoading && (!loggingOn || disabledMsg);

  return (
    <section className="view" aria-labelledby="page-title">
      <PageHeader
        title="Logs"
        sub="What the proxy has been doing, newest first."
        actions={
          !off && (
            <>
              <label className="row small" style={{ gap: 'var(--s-2)' }}>
                <Switch checked={follow} onChange={setFollow} label="Follow new lines" />
                Follow
              </label>
              <button className="btn btn-glass" onClick={() => void clear()}>
                <Icon.Trash />
                Clear
              </button>
            </>
          )
        }
      />

      <div className="glass panel">
        {cfg.isLoading ? (
          <LoadingBlock rows={6} height={28} />
        ) : off ? (
          <EmptyState
            Glyph={Icon.Terminal}
            title="File logging is off"
            action={
              <button className="btn btn-primary" onClick={() => void setLogging(true)}>
                <Icon.Power />
                Turn on logging
              </button>
            }
          >
            Turn it on to keep a log of proxy activity on disk and read it here. You can switch it off again in Settings.
          </EmptyState>
        ) : (
          <>
            <div className="toolbar">
              <label className="search">
                <Icon.Search />
                <input className="inp" placeholder="Search logs" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search logs" />
              </label>
              <div className="chips" role="group" aria-label="Filter by level">
                {LEVELS.map((l) => (
                  <button key={l.id} className="chip" aria-pressed={level === l.id} onClick={() => setLevel(l.id)}>
                    {l.label}
                    <span className="n">{num(counts[l.id] ?? 0)}</span>
                  </button>
                ))}
              </div>
            </div>
            {logsQ.isLoading ? (
              <LoadingBlock rows={8} height={24} />
            ) : shown.length === 0 ? (
              <EmptyState Glyph={Icon.Terminal} title={parsed.length ? 'No matching lines' : 'Nothing logged yet'}>
                {parsed.length ? 'Try another level or search.' : 'Lines appear here as soon as the proxy handles a request.'}
              </EmptyState>
            ) : (
              <div className="log-list" role="log" aria-live="off" aria-label="Log lines">
                {shown.map((l, i) => (
                  <div className="log-line" key={`${l.raw}-${i}`}>
                    <span className="log-time" title={l.date}>{l.time || '—'}</span>
                    <span className={`log-lvl ${l.level}`}>{l.level === 'other' ? '' : l.level}</span>
                    <span className="log-msg">{highlight(l.message, needle)}</span>
                  </div>
                ))}
              </div>
            )}
            <p className="hint" style={{ marginTop: 'var(--s-2)' }}>
              Showing the latest {num(Math.min(parsed.length, LIMIT))} lines{follow ? ' · refreshing every 4 seconds' : ''}.
            </p>
          </>
        )}
      </div>
    </section>
  );
}
