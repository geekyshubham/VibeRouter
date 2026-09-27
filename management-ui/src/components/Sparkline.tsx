/* ============================================================================
   Sparkline — per-account request activity over the last windows the backend
   reports (recent_requests). Bars scale to the account's own max; failed
   requests tint the bar. The label spells the totals out, so the bars are
   never the only carrier of the number.
   ========================================================================== */
import { requestBuckets } from '../lib/health';
import { num } from '../lib/format';

export default function Sparkline({ values, width = 12 }: { values: unknown; width?: number }) {
  const buckets = requestBuckets(values).slice(-width);
  if (buckets.length === 0) return null;
  const totals = buckets.map((b) => b.success + b.failed);
  const max = Math.max(...totals, 1);
  const sum = totals.reduce((a, b) => a + b, 0);
  const failed = buckets.reduce((a, b) => a + b.failed, 0);
  return (
    <div
      className="spark"
      role="img"
      aria-label={`${num(sum)} requests recently${failed ? `, ${num(failed)} failed` : ''}`}
      title={`${num(sum)} requests in the last ${buckets.length * 10} min${failed ? ` · ${num(failed)} failed` : ''}`}
    >
      {buckets.map((b, i) => {
        const t = b.success + b.failed;
        return (
          <i
            key={i}
            className={t === 0 ? '' : b.failed > b.success ? 'bad' : 'on'}
            style={{ height: t === 0 ? 2 : `${Math.max((t / max) * 100, 14)}%` }}
          />
        );
      })}
    </div>
  );
}
