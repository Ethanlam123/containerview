// App orchestrator. Owns the poll loop, optimistic actions, logs drawers, the
// image modal, the Advanced disclosure, and the last-known-good localStorage
// cache shown when the system is stopped.
import * as api from './api.js';
import {
  renderHeader, renderBanners, renderContainers, renderContainerDetail,
  renderBuilder, renderDiskUsage, renderImages, renderMachines, renderFooter,
  setPolling, resetSparklines,
} from './render.js';

const CACHE_KEY = 'containerDashboard:lastState';
const expanded = new Set();            // expanded container ids
const logsStreams = new Map();         // id -> { paused, buffer, handle }
let lastState = null;                  // most recent successful payload
let pollTimer = null;
let inFlight = false;
let autoRefresh = true;
let intervalSec = 5;

// ---------- bootstrap ----------

const $ = (id) => document.getElementById(id);

$('refresh-btn').addEventListener('click', () => poll(true));
$('auto-toggle').addEventListener('change', (e) => { autoRefresh = e.target.checked; scheduleNext(); });
$('interval-input').addEventListener('change', (e) => {
  intervalSec = Math.max(1, Math.min(60, Number(e.target.value) || 5));
  scheduleNext();
});
$('builder-start').addEventListener('click', () => act('builder-start'));
$('builder-stop').addEventListener('click', () => act('builder-stop'));
$('image-search').addEventListener('input', (e) => renderImages(lastState, e.target.value, openImageModal));
$('modal-close').addEventListener('click', closeModal);
$('modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeModal(); });
$('advanced-toggle').addEventListener('toggle', loadAdvanced);

document.addEventListener('visibilitychange', onVisibility);

// Render last-known-good immediately (before first poll resolves) so a stopped
// system still shows something.
try {
  const cached = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
  if (cached) { lastState = cached; paint(cached, true); }
} catch { /* ignore malformed cache */ }

poll(true);   // kick the first tick immediately
scheduleNext();

// ---------- poll loop ----------

function onVisibility() {
  if (document.hidden) {
    setPolling(false);
    clearTimeout(pollTimer);
  } else if (autoRefresh) {
    poll(true);
    scheduleNext();
  }
}

function scheduleNext() {
  clearTimeout(pollTimer);
  if (!autoRefresh || document.hidden) return;
  pollTimer = setTimeout(() => { poll(); scheduleNext(); }, intervalSec * 1000);
}

async function poll(manual) {
  if (inFlight) return;          // debounce: skip tick if previous still in-flight
  inFlight = true;
  if (manual || !document.hidden) setPolling(true);
  try {
    const state = await api.fetchState();
    lastState = state;
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(state)); } catch { /* quota */ }
    paint(state, true);
    renderBanners(null, state.warnings);
  } catch (err) {
    renderHeader(lastState, false);
    renderBanners(err, lastState?.warnings || []);
    if (lastState) paint(lastState, false);   // keep showing last-known-good
  } finally {
    inFlight = false;
    setPolling(false);
  }
}

function paint(state, ok) {
  renderHeader(state, ok);
  renderContainers(state, expanded, toggleExpand);
  renderBuilder(state);
  renderDiskUsage(state, onPrune);
  renderImages(state, $('image-search').value, openImageModal);
  renderMachines(state, onCopyMachine, onStopMachine);
  renderFooter(state);
}

// ---------- row expansion + logs ----------

async function toggleExpand(id) {
  if (expanded.has(id)) {
    expanded.delete(id);
    closeLogs(id);
  } else {
    expanded.add(id);
    // Render the row detail body via inspect, then open the SSE logs drawer.
    try {
      const detail = await api.inspectContainer(id);
      renderContainerDetail(detail, id);
      openLogs(id);
    } catch (err) {
      const root = document.querySelector(`[data-detail-body="${cssEscape(id)}"]`);
      if (root) root.innerHTML = `<div class="row-error">detail unavailable: ${esc(err.message)}</div>`;
    }
  }
  renderContainers(lastState, expanded, toggleExpand);
  // After re-render, re-stamp any open detail bodies + restart their logs.
  for (const openId of expanded) ensureDetailRendered(openId);
}

function ensureDetailRendered(id) {
  // The table innerHTML rewrite drops the detail body; re-fetch is avoided by
  // keeping nothing - the click handler re-runs inspect. For logs, only open
  // streams for rows whose detail is currently in the DOM.
  const detailBody = document.querySelector(`[data-detail-body="${cssEscape(id)}"]`);
  if (detailBody && !logsStreams.has(id)) openLogs(id);
  if (!detailBody && logsStreams.has(id)) closeLogs(id);
}

function openLogs(id) {
  if (logsStreams.has(id)) return;
  const entry = { paused: false, buffer: [] };
  entry.handle = api.openLogs(
    id,
    (line) => {
      if (entry.paused) return;
      entry.buffer.push(line);
      if (entry.buffer.length > 1000) entry.buffer.shift();
      const pre = document.querySelector(`[data-detail-body="${cssEscape(id)}"] [data-logs-pre]`);
      if (pre) { pre.textContent = entry.buffer.join('\n'); pre.scrollTop = pre.scrollHeight; }
    },
    null
  );
  logsStreams.set(id, entry);
  // Wire pause/clear on the freshly rendered controls.
  setTimeout(() => {
    const root = document.querySelector(`[data-logs="${cssEscape(id)}"]`);
    if (!root) return;
    root.querySelector('[data-logs-toggle]').addEventListener('click', (e) => {
      entry.paused = !entry.paused;
      e.target.textContent = entry.paused ? 'Resume' : 'Pause';
    });
    root.querySelector('[data-logs-clear]').addEventListener('click', () => {
      entry.buffer = [];
      const pre = root.querySelector('[data-logs-pre]');
      if (pre) pre.textContent = '';
    });
  }, 0);
}

function closeLogs(id) {
  const entry = logsStreams.get(id);
  if (entry) { entry.handle.close(); logsStreams.delete(id); }
}

// ---------- optimistic actions ----------

async function act(kind, id) {
  const btn = findActionBtn(kind, id);
  const prev = btn ? btn.textContent : '';
  if (btn) { btn.disabled = true; btn.textContent = '...'; }
  try {
    if (kind === 'builder-start') await api.startBuilder();
    else if (kind === 'builder-stop') await api.stopBuilder();
    else if (kind === 'stop' && id) await api.stopContainer(id);
    else if (kind === 'start' && id) await api.startContainer(id);
    else if (kind === 'kill' && id) await api.killContainer(id);
    await poll(true);   // confirm with a fresh payload
  } catch (err) {
    flashError(btn, prev, err.message);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = prev; }
  }
}

function findActionBtn(kind, id) {
  if (kind.startsWith('builder')) return $(kind);
  const cell = document.querySelector(`[data-actions="${cssEscape(id)}"]`);
  return cell ? cell.querySelector(`[data-act="${kind}"]`) : null;
}

function flashError(btn, prev, msg) {
  if (!btn) return;
  btn.textContent = 'failed';
  btn.classList.add('btn-danger');
  setTimeout(() => { btn.textContent = prev; btn.classList.remove('btn-danger'); }, 1500);
  // Surface inline next to the row actions.
  const cell = btn.closest('.row-actions, .panel-actions');
  if (cell) {
    let err = cell.querySelector('.row-error');
    if (!err) { err = document.createElement('span'); err.className = 'row-error'; cell.appendChild(err); }
    err.textContent = msg;
    setTimeout(() => err.remove(), 4000);
  }
}

// Delegate container row Start/Stop/Kill clicks (rows are re-rendered each tick).
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-act]');
  if (!b) return;
  const cell = b.closest('[data-actions]');
  if (!cell) return;
  e.stopPropagation();
  act(b.dataset.act, cell.dataset.actions);
});

async function onPrune(category) {
  if (!confirm(`Prune ${category}? This removes unused ${category}.`)) return;
  try {
    await api.prune(category);
    await poll(true);
  } catch (err) {
    alert(`Prune failed: ${err.message}`);
  }
}

function onCopyMachine(name) {
  const cmd = `container machine run -n ${name}`;
  navigator.clipboard.writeText(cmd).then(
    () => toast(`Copied: ${cmd}`),
    () => toast('Clipboard blocked by browser')
  );
}

function onStopMachine(id) {
  // Machines have no stop endpoint in the backend; the spec calls out the copy
  // command as the primary action. Surface the command to run instead.
  toast('Stop machines via: container machine stop ' + id);
}

// ---------- image modal ----------

async function openImageModal(name) {
  $('modal-title').textContent = name;
  $('modal-body').textContent = 'loading...';
  $('modal').classList.remove('hidden');
  try {
    const data = await api.inspectImage(name);
    $('modal-body').textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    $('modal-body').textContent = `failed: ${err.message}`;
  }
}

function closeModal() {
  $('modal').classList.add('hidden');
}

// ---------- advanced disclosure ----------

async function loadAdvanced() {
  if (!$('advanced-toggle').parentElement.open) return;
  $('advanced-properties').textContent = 'loading...';
  $('advanced-dns').textContent = 'loading...';
  try { $('advanced-properties').textContent = JSON.stringify(await api.fetchJson('/api/system/properties'), null, 2); }
  catch (e) { $('advanced-properties').textContent = `unavailable: ${e.message}`; }
  try { $('advanced-dns').textContent = JSON.stringify(await api.fetchJson('/api/system/dns'), null, 2); }
  catch (e) { $('advanced-dns').textContent = `unavailable: ${e.message}`; }
}

// ---------- misc ----------

function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function cssEscape(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c); }

let toastTimer = null;
function toast(msg) {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    el.style.cssText = 'position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#1b1b29;border:1px solid #2a2a3a;color:#e6e6f0;padding:8px 14px;border-radius:8px;font-family:ui-monospace,monospace;font-size:12px;z-index:60;';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.remove(); }, 2500);
}
