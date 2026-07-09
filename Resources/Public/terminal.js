// Interactive terminal: mounts xterm.js, opens the exec WebSocket, and wires
// them bidirectionally. The backend (Phase 15) sends BINARY frames; keystrokes
// go back as text. The PTY size is fixed at open time (the container CLI has no
// post-start resize API), so fit() runs once up front to size the display and
// hand cols/rows to the ws query. Closing the drawer disposes the term + closes
// the ws; the backend reaps the child on ws close (Phase 15 gate).

const MONO = 'ui-monospace, "SF Mono", "JetBrains Mono", Menlo, monospace';

/// Open a terminal for `id` inside `mountEl`. Returns `{ dispose }` the caller
/// invokes on close. Idempotent dispose. Reads `window.Terminal` /
/// `window.FitAddon.FitAddon` set by the vendored UMD bundles in index.html.
export function openTerminal(id, mountEl) {
  const TerminalCtor = window.Terminal;
  const FitAddonCtor = window.FitAddon && window.FitAddon.FitAddon;
  if (!TerminalCtor || !FitAddonCtor) {
    mountEl.textContent = 'terminal library failed to load';
    return { dispose() {} };
  }

  const fit = new FitAddonCtor();
  const term = new TerminalCtor({
    cursorBlink: true,
    fontFamily: MONO,
    fontSize: 13,
    scrollback: 2000,
    theme: { background: '#0a0a0f', foreground: '#e6e6f0', cursor: '#e6e6f0' },
    allowProposedApi: true,
  });
  term.loadAddon(fit);
  term.open(mountEl);
  // Size the display to the mount, then read back the agreed cols/rows for the
  // ws query so the PTY and the display agree at open time.
  let cols = 80, rows = 24;
  try { fit.fit(); cols = term.cols; rows = term.rows; } catch { /* defaults */ }

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = `${proto}//${location.host}/api/containers/${encodeURIComponent(id)}/exec?cols=${cols}&rows=${rows}`;
  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';

  // backend -> term (binary frames + any text frames)
  ws.onmessage = (ev) => {
    const d = ev.data;
    if (typeof d === 'string') term.write(d);
    else if (d instanceof ArrayBuffer) term.write(new Uint8Array(d));
    else if (d instanceof Blob) d.arrayBuffer().then((b) => term.write(new Uint8Array(b)));
  };
  // term -> backend (text keystrokes; the server's onText feeds the PTY master)
  term.onData((d) => { if (ws.readyState === WebSocket.OPEN) ws.send(d); });

  let closed = false;
  const markClosed = () => {
    if (closed) return;
    closed = true;
    term.write('\r\n\x1b[31m[disconnected]\x1b[0m\r\n');
  };
  ws.onclose = markClosed;
  ws.onerror = markClosed;

  term.focus();
  return {
    dispose() {
      ws.onclose = null;
      ws.onerror = null;
      try { ws.close(); } catch { /* already gone */ }
      try { term.dispose(); } catch { /* already gone */ }
    },
  };
}
