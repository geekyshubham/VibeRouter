/* ============================================================================
   UsageByDatePanel — what was used on the selected day: totals, then spend by
   provider and by model as horizontal bars.

   Ranking is by cost, never by volume, because volumes arrive in unlike units
   (Kiro reports millicredits, everyone else tokens) and ordering those against
   each other would be meaningless. Cost is the one basis comparable across all
   providers. Totals arrive precomputed from the server for the same reason.
   Bars are one hue (magnitude); the provider swatch beside the name carries
   identity, and every bar has its value written next to it.
   ========================================================================== */
import { useState } from 'react';
import { asArray } from '../lib/apiClient';
import { dayLabel, tokens, usd, volume } from '../lib/format';
import type { UsageDailyModelRow, UsageDailyProviderRow } from '../lib/types';
import { useUsageDay } from '../context/UsageDayContext';
import { useUsageDaily } from '../lib/useUsageDaily';
import { providerTint } from '../lib/providers';
import Icon from '../lib/icons';
import LoadingBlock from './LoadingBlock';
import SectionHeader from './SectionHeader';
import UsageDayPicker from './UsageDayPicker';
import QueryError from './QueryError';

const MAX_MODEL_ROWS = 10;

function BarRow({ name, tint, cost, vol, max }: { name: string; tint: string; cost: number; vol: string; max: number }) {
  const pct = max > 0 ? Math.max((cost / max) * 100, cost > 0 ? 2 : 0) : 0;
  return (
    <div className="bar-row">
      <div className="bar-name">
        <span className="bar-swatch" style={{ background: tint }} aria-hidden />
        <span title={name}>{name}</span>
      </div>
      <div className="bar-figs">
        <span className="mono">{vol}</span>
        {cost > 0 && <b>{usd(cost)}</b>}
      </div>
      <div className="bar-track" aria-hidden>
        <div className="bar-fill" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

export default function UsageByDatePanel() {
  const { day } = useUsageDay();
  const usage = useUsageDaily(day);
  const [by, setBy] = useState<'provider' | 'model'>('provider');
  const [showAll, setShowAll] = useState(false);

  const data = usage.data;
  const models = asArray<UsageDailyModelRow>(data?.models);
  const providers = asArray<UsageDailyProviderRow>(data?.providers);
  const caveats = asArray<string>(data?.caveats);
  const rows = by === 'provider' ? providers : models;
  const shown = showAll ? rows : rows.slice(0, MAX_MODEL_ROWS);
  const maxCost = Math.max(...rows.map((r) => r.estimatedCostUSD), 0);

  return (
    <section className="glass panel" aria-labelledby="usage-title">
      <SectionHeader
        id="usage-title"
        Glyph={Icon.Activity}
        title={`Usage · ${dayLabel(day)}`}
        sub={
          models.length
            ? `${providers.length} provider${providers.length === 1 ? '' : 's'} · ${models.length} model${models.length === 1 ? '' : 's'} · estimated at API list prices`
            : 'From your local CLI sessions'
        }
        actions={<UsageDayPicker />}
      />

      {usage.isLoading ? (
        <LoadingBlock rows={3} height={44} />
      ) : usage.isError ? (
        <QueryError what="usage history" onRetry={() => usage.refetch()} />
      ) : !models.length ? (
        <div className="empty" style={{ padding: 'var(--s-6) var(--s-4)' }}>
          <div className="empty-icon" aria-hidden>
            <Icon.Activity />
          </div>
          <h3>No usage recorded for {dayLabel(day).toLowerCase() === 'today' ? 'today yet' : 'this day'}</h3>
          <p>
            {/* History starts when tracking starts — an empty older date is expected. */}
            {data?.earliestDay
              ? `Recorded history starts ${dayLabel(data.earliestDay)}. The VibeRouter app fills this in as it scans your CLI sessions.`
              : 'The VibeRouter app fills this in as it scans your CLI sessions.'}
          </p>
        </div>
      ) : (
        <>
          <div className="usage-totals">
            <div className="usage-total">
              <div className="lbl">Estimated spend</div>
              <div className="val">{usd(data?.totalCostUSD)}</div>
            </div>
            <div className="usage-total">
              <div className="lbl">Tokens</div>
              <div className="val">{tokens(data?.totalTokens)}</div>
            </div>
            <div className="usage-total">
              <div className="lbl">Requests</div>
              <div className="val">{tokens(data?.totalRequests)}</div>
            </div>
          </div>

          <div className="toolbar" style={{ justifyContent: 'space-between' }}>
            <div className="label">Spend by {by}</div>
            <div className="seg" role="tablist" aria-label="Group usage by">
              <button role="tab" aria-selected={by === 'provider'} onClick={() => setBy('provider')}>
                Provider
              </button>
              <button role="tab" aria-selected={by === 'model'} onClick={() => setBy('model')}>
                Model
              </button>
            </div>
          </div>

          <div className="bars">
            {shown.map((row) => {
              const isModel = 'model' in row;
              const name = isModel ? (row as UsageDailyModelRow).model : row.providerName || row.providerID;
              return (
                <BarRow
                  key={`${row.providerID}:${name}`}
                  name={name}
                  tint={providerTint(row.providerID)}
                  cost={row.estimatedCostUSD}
                  vol={volume(row.totalVolume, row.volumeUnit)}
                  max={maxCost}
                />
              );
            })}
          </div>
          {rows.length > MAX_MODEL_ROWS && (
            <button className="btn btn-ghost btn-sm" style={{ marginTop: 'var(--s-3)' }} onClick={() => setShowAll((s) => !s)}>
              {showAll ? 'Show fewer' : `Show all ${rows.length}`}
            </button>
          )}

          {/* Grok pins a whole session to its last-activity day and Copilot keeps no
              per-model split, so those days are labelled rather than presented as exact. */}
          {caveats.map((note) => (
            <div className="caveat" key={note}>
              <Icon.Info />
              <span>{note}</span>
            </div>
          ))}
        </>
      )}
    </section>
  );
}
