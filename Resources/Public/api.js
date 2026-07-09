// Data access layer. All network goes through here so error handling and the
// "container CLI not installed" signal live in one place.

/// Fetch the composite poll payload. Throws on network failure or non-2xx.
export async function fetchState() {
  const res = await fetch('/api/state', { headers: { Accept: 'application/json' } });
  if (res.status === 503 || res.status === 500) {
    // Server reachable but the container CLI may be missing / system stopped.
    const body = await res.json().catch(() => ({}));
    const err = new Error(body.reason || `server error ${res.status}`);
    err.kind = body.reason && /not.*(installed|found)|missing/i.test(body.reason) ? 'cli-missing' : 'server';
    throw err;
  }
  if (!res.ok) throw new Error(`unexpected status ${res.status}`);
  return res.json();
}

/// POST a write action; resolves true on 2xx, throws with the CLI message otherwise.
export async function postAction(path) {
  const res = await fetch(path, { method: 'POST' });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.reason || `HTTP ${res.status}`);
  }
  return true;
}

/// Create + start a container from a JSON body. Returns { id }. The server is the
/// validation authority (each field is a validator-backed value type); on 4xx/5xx
/// it returns a generic reason that is safe to display (no echoed input).
export async function createContainer(body) {
  const res = await fetch('/api/containers/run', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const b = await res.json().catch(() => ({}));
    throw new Error(b.reason || `HTTP ${res.status}`);
  }
  return res.json();
}

export const stopContainer   = (id) => postAction(`/api/containers/${encodeURIComponent(id)}/stop`);
export const startContainer  = (id) => postAction(`/api/containers/${encodeURIComponent(id)}/start`);
export const killContainer   = (id) => postAction(`/api/containers/${encodeURIComponent(id)}/kill`);
export const startBuilder    = () => postAction('/api/builder/start');
export const stopBuilder     = () => postAction('/api/builder/stop');
export const prune           = (category) => postAction(`/api/prune/${category}`);

/// Pull an image by reference. The server validates the ref and discards output
/// (pull progress would overflow the pipe buffer); resolves on 2xx, throws with
/// a generic server-side reason otherwise. Fire-to-completion (may take minutes).
export async function pullImage(reference) {
  const res = await fetch('/api/images/pull', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ reference }),
  });
  if (!res.ok) {
    const b = await res.json().catch(() => ({}));
    throw new Error(b.reason || `HTTP ${res.status}`);
  }
  return true;
}

/// Lazy `container inspect <id>` for row expansion.
export async function inspectContainer(id) {
  const res = await fetch(`/api/containers/${encodeURIComponent(id)}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

/// Lazy `container image inspect <name>` for the modal.
export async function inspectImage(name) {
  const res = await fetch(`/api/images/inspect?name=${encodeURIComponent(name)}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

/// Feature flags from the backend. Used to gate the Terminal button on the exec
/// opt-in (`CONTAINERDASHBOARD_ENABLE_EXEC=1`, default off). Fail-closed: any
/// error or non-2xx hides the button.
export async function fetchCapabilities() {
  try {
    const res = await fetch('/api/capabilities', { headers: { Accept: 'application/json' } });
    if (!res.ok) return { exec: false };
    return await res.json();
  } catch {
    return { exec: false };
  }
}

/// Raw passthrough JSON (system properties / dns), for the Advanced disclosure.
export async function fetchJson(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

/// Open an SSE logs stream for one container. Returns the EventSource plus a
/// close() that the caller invokes on drawer close. The server caps every
/// connection; EventSource reconnects automatically, so no manual retry here.
export function openLogs(id, onLine, onError) {
  const es = new EventSource(`/api/containers/${encodeURIComponent(id)}/logs`);
  es.onmessage = (ev) => onLine(ev.data);
  es.onerror = (ev) => { if (onError) onError(ev); };
  return { close: () => es.close() };
}

// ---------- formatting helpers ----------

export function formatBytes(n) {
  if (n == null || Number.isNaN(n)) return '-';
  const sign = n < 0 ? '-' : '';
  let v = Math.abs(n);
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${sign}${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}

export function formatPercent(p) {
  if (p == null || Number.isNaN(p)) return '-';
  return `${p.toFixed(p >= 100 ? 0 : 1)}%`;
}

export function shortHash(s, len = 12) {
  if (!s) return '-';
  return s.replace(/^sha256:/, '').slice(0, len);
}

// ---------- DOM helpers (shared by render.js + app.js) ----------

/// HTML-escape a value for safe insertion via innerHTML.
export function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

/// Escape a value for use in a CSS attribute selector ([data-id="..."]).
export function cssEscape(s) {
  if (window.CSS && CSS.escape) return CSS.escape(s);
  return String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c);
}
