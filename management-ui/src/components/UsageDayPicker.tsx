/* ============================================================================
   UsageDayPicker — step through recorded days (‹ date ›) or pick one from the
   native calendar. Native <input type="date"> keeps the single-file build
   free of a date-picker dependency. Bounds come from the usage response
   (earliestDay .. today), so the control never offers a day with no history.
   ========================================================================== */
import { useUsageDay } from '../context/UsageDayContext';
import { useUsageDaily } from '../lib/useUsageDaily';
import { todayKey } from '../lib/format';
import Icon from '../lib/icons';

/** Shift a local YYYY-MM-DD key by whole days without touching UTC. */
function shiftDay(key: string, delta: number): string {
  const [y, m, d] = key.split('-').map(Number);
  const date = new Date(y, m - 1, d + delta);
  return `${date.getFullYear()}-${`${date.getMonth() + 1}`.padStart(2, '0')}-${`${date.getDate()}`.padStart(2, '0')}`;
}

export default function UsageDayPicker() {
  const { day, setDay, resetToToday, isToday } = useUsageDay();
  const usage = useUsageDaily(day);
  const today = todayKey();
  const earliest = usage.data?.earliestDay;
  const min = earliest && earliest < today ? earliest : undefined;

  return (
    <div className="row">
      <div className="day-nav" role="group" aria-label="Usage day">
        <button
          className="icon-btn"
          aria-label="Previous day"
          disabled={Boolean(min && day <= min)}
          onClick={() => setDay(shiftDay(day, -1))}
        >
          <Icon.ChevronDown style={{ transform: 'rotate(90deg)' }} />
        </button>
        <input
          className="inp mono"
          type="date"
          value={day}
          min={min}
          max={today}
          onChange={(e) => setDay(e.target.value)}
          aria-label="Pick a day"
        />
        <button className="icon-btn" aria-label="Next day" disabled={day >= today} onClick={() => setDay(shiftDay(day, 1))}>
          <Icon.ChevronRight />
        </button>
      </div>
      {!isToday && (
        <button className="btn btn-ghost btn-sm" onClick={resetToToday}>
          Today
        </button>
      )}
    </div>
  );
}
