/* ============================================================================
   ActivityChart — requests across all accounts in the recent 10-minute
   windows the backend reports. Stacked bars (succeeded / failed) with a 2px
   gap, a hover/focus tooltip per window, a legend, and a screen-reader
   summary. One axis, recessive grid.
   ========================================================================== */
import { useState } from 'react';
import { mergeBuckets } from '../lib/health';
import { num } from '../lib/format';
import type { AuthFile } from '../lib/types';

export default function ActivityChart({ files }: { files: AuthFile[] }) {
  const buckets = mergeBuckets(files);
  const [hover, setHover] = useState<number | null>(null);
  if (buckets.length === 0) return null;

  const totals = buckets.map((b) => b.success + b.failed);
  const max = Math.max(...totals, 1);
  const sum = totals.reduce((a, b) => a + b, 0);
  const failed = buckets.reduce((a, b) => a + b.failed, 0);
  const first = buckets[0]?.time.split('-')[0];
  const last = buckets[buckets.length - 1]?.time.split('-')[1];
  const minutes = buckets.length * 10;

  return (
    <div className="activity">
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <div>
          <div className="kpi-val" style={{ fontSize: 'var(--text-2xl)' }}>{num(sum)}</div>
          <div className="small">
            requests in the last {minutes >= 60 ? `${Math.floor(minutes / 60)}h${minutes % 60 ? ` ${minutes % 60}m` : ''}` : `${minutes} minutes`}
            {failed > 0 && ` · ${num(failed)} failed`}
          </div>
        </div>
        <div className="chart-legend" aria-hidden>
          <span>
            <i style={{ background: 'var(--chart-ok)' }} />
            Succeeded
          </span>
          <span>
            <i style={{ background: 'var(--chart-bad)' }} />
            Failed
          </span>
        </div>
      </div>
      <div
        className="activity-chart"
        role="img"
        aria-label={`${num(sum)} requests over the last ${minutes} minutes, ${num(failed)} failed. Busiest window: ${num(max === 1 && sum === 0 ? 0 : max)} requests.`}
        onMouseLeave={() => setHover(null)}
      >
        {buckets.map((b, i) => {
          const total = b.success + b.failed;
          const hOk = (b.success / max) * 100;
          const hBad = (b.failed / max) * 100;
          const edge = i < 2 ? 'edge-l' : i > buckets.length - 3 ? 'edge-r' : '';
          return (
            <div
              key={i}
              className={`activity-col ${total === 0 ? 'empty' : ''}`}
              tabIndex={0}
              aria-label={`${b.time || `window ${i + 1}`}: ${num(b.success)} succeeded, ${num(b.failed)} failed`}
              onMouseEnter={() => setHover(i)}
              onFocus={() => setHover(i)}
              onBlur={() => setHover(null)}
            >
              {b.failed > 0 && <div className="seg-bad seg-top" style={{ height: `${hBad}%` }} />}
              {b.success > 0 && (
                <div className={`seg-ok ${b.failed > 0 ? '' : 'seg-top'}`} style={{ height: `${hOk}%` }} />
              )}
              {hover === i && (
                <div className={`tooltip ${edge}`} role="presentation">
                  <b>{b.time || `Window ${i + 1}`}</b>
                  <div className="tt-row">
                    <i style={{ background: 'var(--chart-ok)' }} />
                    <span>Succeeded</span>
                    <span>{num(b.success)}</span>
                  </div>
                  <div className="tt-row">
                    <i style={{ background: 'var(--chart-bad)' }} />
                    <span>Failed</span>
                    <span>{num(b.failed)}</span>
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
      <div className="activity-axis" aria-hidden>
        <span>{first}</span>
        <span>{last}</span>
      </div>
    </div>
  );
}
