/* ============================================================================
   LoginGate — the locked screen. Takes the management key and validates it via
   AuthContext.login (which probes GET /config). Errors say what to do next.
   ========================================================================== */
import { useState, type FormEvent } from 'react';
import { useAuth } from '../context/AuthContext';
import { AuthError, NetworkError, hostLabel } from '../lib/apiClient';
import { BrandMark } from './BrandMark';
import Icon from '../lib/icons';

export default function LoginGate() {
  const { login } = useAuth();
  const [value, setValue] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [show, setShow] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!value.trim() || busy) return;
    setBusy(true);
    setError('');
    try {
      await login(value);
    } catch (err) {
      if (err instanceof AuthError) setError('That key was rejected. Copy it again from the menu bar and retry.');
      else if (err instanceof NetworkError) setError("Can't reach the proxy. Start it from the VibeRouter menu bar.");
      else setError('Something went wrong. Try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="gate">
      <div className="backdrop" aria-hidden />
      <form className="gate-card glass" onSubmit={submit}>
        <div className="brand-mark">
          <BrandMark size={28} />
        </div>
        <div>
          <h1>Unlock VibeRouter</h1>
          <p className="lede" style={{ marginTop: 'var(--s-1)' }}>
            Paste the management key. The menu bar copies it for you when you open the console.
          </p>
        </div>

        <div className="field">
          <label htmlFor="mgmt-key">Management key</label>
          <div className="pw-wrap">
            <input
              id="mgmt-key"
              className="inp mono"
              type={show ? 'text' : 'password'}
              autoComplete="current-password"
              placeholder="Paste your key"
              value={value}
              onChange={(e) => setValue(e.target.value)}
              aria-invalid={Boolean(error)}
              aria-describedby="gate-err"
              autoFocus
            />
            <button type="button" className="icon-btn" aria-label={show ? 'Hide key' : 'Show key'} onClick={() => setShow((s) => !s)}>
              {show ? <Icon.EyeOff /> : <Icon.Eye />}
            </button>
          </div>
          <div className="gate-err" id="gate-err" role="alert">
            {error}
          </div>
        </div>

        <button className={`btn btn-primary btn-block ${busy ? 'is-busy' : ''}`} type="submit" disabled={busy || !value.trim()}>
          {busy ? <Icon.Refresh /> : <Icon.Lock />}
          {busy ? 'Checking…' : 'Unlock console'}
        </button>

        <div className="gate-foot">
          Connected to <span className="mono">{hostLabel()}</span>
        </div>
      </form>
    </div>
  );
}
