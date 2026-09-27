/* QueryError — a failed load, with the reason and a retry. */
import Icon from '../lib/icons';

export default function QueryError({ what, onRetry }: { what: string; onRetry: () => void }) {
  return (
    <div className="error-box" role="alert">
      <Icon.Alert />
      <span>Couldn't load {what}. Check that the proxy is running, then try again.</span>
      <button className="btn btn-glass btn-sm" onClick={onRetry}>
        <Icon.Refresh />
        Retry
      </button>
    </div>
  );
}
