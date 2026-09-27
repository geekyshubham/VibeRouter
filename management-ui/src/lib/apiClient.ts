/* ============================================================================
   apiClient — thin typed fetch wrapper over /v0/management/*.

   SECURITY (localhost-only console): the Bearer key IS the credential; it lives
   in sessionStorage ('vp_mgmt_key'). Acceptable ONLY because the backend binds
   127.0.0.1 with allow-remote:false. Never put response bodies (which may
   contain plaintext api-keys) into thrown error messages.

   NULL-SAFETY: the backend returns `null` for empty collections
   (e.g. {"api-keys":null}) and an error object for disabled features
   (e.g. /logs → {"error":"logging to file disabled"}). Consumers MUST route
   every list through asArray() to avoid `.filter is not a function` crashes.
   ========================================================================== */

/** Base URL detection.
 *  - DEV: '' → use the Vite dev proxy (same-origin), avoids CORS.
 *  - Served over http(s) → location.origin. The console is always served by the
 *    backend it manages (/management.html on :8318, or through the :8317 proxy,
 *    which forwards management paths), so same-origin is the only correct target.
 *    Hard-coding :8318 here would send an isolated test instance's writes to the
 *    live backend.
 *  - Otherwise (file://) → VITE_BACKEND_BASE, defaulting to the local backend. */
export const BASE: string = import.meta.env.DEV
  ? ''
  : /^https?:$/.test(location.protocol)
    ? location.origin
    : (import.meta.env.VITE_BACKEND_BASE ?? 'http://127.0.0.1:8318');

const API_PREFIX = '/v0/management';

/** Human-readable "host:port" label for the topbar / gate footer. */
export function hostLabel(): string {
  const raw = BASE || (import.meta.env.VITE_BACKEND_BASE ?? '');
  const stripped = raw.replace(/^https?:\/\//, '');
  return stripped || '127.0.0.1:8318';
}

/** The endpoints a client (Claude Code, Factory, Cursor…) should point at.
 *  Clients talk to the thinking proxy on :8317, which fronts this backend (:8318)
 *  and adds the thinking/Kiro handling, so :8318 is swapped for :8317. */
export function clientEndpoints(): { anthropic: string; openai: string } {
  let url: URL;
  try {
    url = new URL(BASE || 'http://127.0.0.1:8318');
  } catch {
    url = new URL('http://127.0.0.1:8318');
  }
  if (url.port === '8318') url.port = '8317';
  const host = url.hostname === '127.0.0.1' ? 'localhost' : url.hostname;
  const root = `${url.protocol}//${host}${url.port ? `:${url.port}` : ''}`;
  return { anthropic: root, openai: `${root}/v1` };
}

/* ---------------------------------------------------------------- NORMALIZE */

/** Coerce any backend value into a safe array. The backend returns null for
 *  empty collections and sometimes an object envelope; this guarantees callers
 *  can always .filter()/.map() without a runtime crash. */
export function asArray<T = unknown>(value: unknown): T[] {
  if (Array.isArray(value)) return value as T[];
  return [];
}

/** Pull a named collection out of an envelope object, null-safe.
 *  e.g. pluckArray(res, 'api-keys') on {"api-keys":null} → []. */
export function pluckArray<T = unknown>(envelope: unknown, key: string): T[] {
  if (envelope && typeof envelope === 'object' && !Array.isArray(envelope)) {
    return asArray<T>((envelope as Record<string, unknown>)[key]);
  }
  return asArray<T>(envelope);
}

/** True when a response is a backend error envelope like {"error":"..."}. */
export function errorMessageOf(value: unknown): string | null {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const e = (value as Record<string, unknown>).error;
    if (typeof e === 'string' && e.trim()) return e;
  }
  return null;
}

/* ---------------------------------------------------------------- ERRORS */

/** Thrown on 401 / 403 — the stored key was rejected. */
export class AuthError extends Error {
  status: number;
  constructor(status: number) {
    super('Authentication failed');
    this.name = 'AuthError';
    this.status = status;
  }
}

/** Thrown on fetch reject / TypeError / offline. */
export class NetworkError extends Error {
  constructor(message = 'Network unreachable') {
    super(message);
    this.name = 'NetworkError';
  }
}

/** Generic non-auth API failure carrying status (no secrets in message). */
export class ApiError extends Error {
  status: number;
  body: unknown;
  constructor(status: number, body: unknown) {
    super(`Request failed with status ${status}`);
    this.name = 'ApiError';
    this.status = status;
    this.body = body;
  }
}

/* ------------------------------------------------------------- KEY GETTER */

let keyGetter: () => string = () => '';
export function registerKeyGetter(fn: () => string): void {
  keyGetter = fn;
}
function getKey(): string {
  return keyGetter();
}

/* --------------------------------------------------------- AUTH-ERROR HOOK */

/** Invoked whenever a request gets 401/403 so an authenticated session that
 *  loses its key mid-flight can be routed back to the LoginGate. The handler
 *  itself decides whether to act (e.g. ignore during initial key validation). */
let onAuthError: () => void = () => {};
export function registerAuthErrorHandler(fn: () => void): void {
  onAuthError = fn;
}

/* ------------------------------------------------------------------ CORE */

type Method = 'GET' | 'PUT' | 'POST' | 'DELETE' | 'PATCH';

async function request<T>(method: Method, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${getKey()}`,
  };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }

  let res: Response;
  try {
    res = await fetch(`${BASE}${API_PREFIX}${path}`, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new NetworkError();
  }

  if (res.status === 401 || res.status === 403) {
    onAuthError();
    throw new AuthError(res.status);
  }

  const text = await res.text();
  let parsed: unknown = undefined;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
  }

  if (!res.ok) {
    // A rejected write (400 etc.) must surface as an error so callers show a
    // failure toast instead of a false "saved". The parsed body (which may
    // carry a {"error":"..."} envelope) rides along on ApiError.body for any
    // caller that wants to inspect it from its catch block.
    throw new ApiError(res.status, parsed);
  }

  return parsed as T;
}

export const apiClient = {
  get: <T>(path: string) => request<T>('GET', path),
  put: <T>(path: string, body?: unknown) => request<T>('PUT', path, body ?? {}),
  post: <T>(path: string, body?: unknown) => request<T>('POST', path, body ?? {}),
  patch: <T>(path: string, body?: unknown) => request<T>('PATCH', path, body ?? {}),
  del: <T>(path: string) => request<T>('DELETE', path),
};

export default apiClient;
