/* OfflineBanner — shown when the backend stops answering, with a retry. */
import { useQueryClient } from '@tanstack/react-query';
import Icon from '../../lib/icons';
import { hostLabel } from '../../lib/apiClient';

export default function OfflineBanner() {
  const qc = useQueryClient();
  return (
    <div className="banner" role="alert">
      <Icon.WifiOff />
      <span>
        Can't reach the proxy at <span className="mono">{hostLabel()}</span>. Start it from the VibeRouter menu bar —
        you're seeing the last known state.
      </span>
      <button className="btn btn-glass btn-sm" onClick={() => qc.invalidateQueries()}>
        <Icon.Refresh />
        Retry
      </button>
    </div>
  );
}
