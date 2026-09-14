/* ============================================================================
   Sparkline — tiny bar chart for per-account request activity (recent_requests
   snapshots from /auth-files). Bars scale to the window's max; the newest bars
   tint success-green so "busy recently" reads at a glance.
   ========================================================================== */
import { asArray } from '../lib/apiClient';

export default function Sparkline({ values, width = 10 }: { values: unknown; width?: number }) {
  const raw = asArray<number>(values)
    .map((v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0))
    .slice(-width);
  if (raw.length === 0) return null;

  const max = Math.max(...raw, 1);
  return (
    <div className="spark" aria-hidden>
      {raw.map((v, i) => (
        <i
          key={i}
          className={v === 0 ? 'zero' : v >= max * 0.66 ? 'hot' : ''}
          style={{ height: `${Math.max((v / max) * 100, 8)}%` }}
        />
      ))}
    </div>
  );
}
