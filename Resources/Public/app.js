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
// The `toggle` event fires on <details> and does not bubble, so the listener
// must live on the <details> element (not its <summary> child).
document.querySelector('details.advanced')?.addEventListener('toggle', loadAdvanced);

document.addEventListener('visibilitychange', onVisibility);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { closeModal(); closeCreate(); } });

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
    renderBanners(err, lastState?.warnings || []);
    if (lastState) paint(lastState, false);   // keep showing last-known-good (paint renders the header)
    else renderHeader(null, false);
  } finally {
    inFlight = false;
    setPolling(false);
  }
}

function paint(state, ok) {
  renderHeader(state, ok);
  // onOrphaned closes the logs stream + clears `expanded` for any container
  // that vanished this tick (renderContainers drops its detail row).
  renderContainers(state, expanded, toggleExpand, (id) => { expanded.delete(id); closeLogs(id); });
  renderBuilder(state);
  renderDiskUsage(state, onPrune);
  renderImages(state, $('image-search').value, openImageModal);
  renderMachines(state, onCopyMachine, onStopMachine);
  renderFooter(state);
}

// ---------- row expansion + logs ----------

// Detail rows are managed here (toggle) and preserved by renderContainers
// (snapshotted + re-attached across the per-tick rebuild), so an open drawer
// and its live SSE `pre` survive polling.
async function toggleExpand(id) {
  const row = document.querySelector(`tr.row[data-id="${api.cssEscape(id)}"]`);
  if (expanded.has(id)) {
    expanded.delete(id);
    closeLogs(id);
    const d = document.querySelector(`tr.row-detail[data-detail="${api.cssEscape(id)}"]`);
    if (d) d.remove();
    setCaret(row, false);
    return;
  }
  expanded.add(id);
  setCaret(row, true);
  insertDetailPlaceholder(id, row);
  try {
    const detail = await api.inspectContainer(id);
    renderContainerDetail(detail, id);
    openLogs(id);
  } catch (err) {
    const root = document.querySelector(`[data-detail-body="${api.cssEscape(id)}"]`);
    if (root) root.innerHTML = `<div class="row-error">detail unavailable: ${api.esc(err.message)}</div>`;
  }
}

function insertDetailPlaceholder(id, row) {
  const tr = document.createElement('tr');
  tr.className = 'row-detail';
  tr.dataset.detail = id;
  tr.innerHTML = `<td colspan="9"><div class="detail-inner" data-detail-body="${api.esc(id)}">loading...</div></td>`;
  if (row) row.after(tr);
}

function setCaret(row, open) {
  if (!row) return;
  const caret = row.querySelector('.expand-caret');
  if (caret) { caret.classList.toggle('open', open); caret.innerHTML = open ? '&#9662;' : '&#9656;'; }
}

function openLogs(id) {
  if (logsStreams.has(id)) return;
  // Cache the `pre` element; the detail node is preserved across ticks, so the
  // ref stays valid and the SSE callback avoids a per-line DOM query.
  const pre = document.querySelector(`[data-detail-body="${api.cssEscape(id)}"] [data-logs-pre]`);
  const entry = { paused: false, buffer: [], pre };
  const root = document.querySelector(`[data-logs="${api.cssEscape(id)}"]`);
  if (root) {
    root.querySelector('[data-logs-toggle]')?.addEventListener('click', (e) => {
      entry.paused = !entry.paused;
      e.target.textContent = entry.paused ? 'Resume' : 'Pause';
    });
    root.querySelector('[data-logs-clear]')?.addEventListener('click', () => {
      entry.buffer = [];
      if (entry.pre) entry.pre.textContent = '';
    });
  }
  entry.handle = api.openLogs(
    id,
    (line) => {
      if (entry.paused) return;
      entry.buffer.push(line);
      if (entry.buffer.length > 1000) entry.buffer.shift();
      if (entry.pre) { entry.pre.textContent = entry.buffer.join('\n'); entry.pre.scrollTop = entry.pre.scrollHeight; }
    },
    null
  );
  logsStreams.set(id, entry);
}

function closeLogs(id) {
  const entry = logsStreams.get(id);
  if (entry) { entry.handle.close(); logsStreams.delete(id); }
}

// ---------- optimistic actions ----------

const ACTIONS = {
  'builder-start': () => api.startBuilder(),
  'builder-stop':  () => api.stopBuilder(),
  stop:  (id) => api.stopContainer(id),
  start: (id) => api.startContainer(id),
  kill:  (id) => api.killContainer(id),
};

async function act(kind, id) {
  const btn = findActionBtn(kind, id);
  const prev = btn ? btn.textContent : '';
  if (btn) { btn.disabled = true; btn.textContent = '...'; }
  try {
    await ACTIONS[kind]?.(id);
    await poll(true);   // confirm with a fresh payload
  } catch (err) {
    flashError(btn, prev, err.message);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = prev; }
  }
}

function findActionBtn(kind, id) {
  if (kind.startsWith('builder')) return $(kind);
  const cell = document.querySelector(`[data-actions="${api.cssEscape(id)}"]`);
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

// ---------- create container ----------

// The server is the validation authority (each field is a validator-backed
// value type); client checks here are UX hints, not security.
$('new-container-btn').addEventListener('click', openCreate);
$('create-close').addEventListener('click', closeCreate);
$('create-modal').addEventListener('click', (e) => { if (e.target.id === 'create-modal') closeCreate(); });
document.querySelectorAll('.repeat .add-row').forEach((btn) => {
  btn.addEventListener('click', () => addRepeatRow(btn.closest('.repeat')));
});
$('create-form').addEventListener('submit', onCreateSubmit);

function addRepeatRow(group) {
  const rows = group.querySelector('.repeat-rows');
  const proto = rows.querySelector('input');
  const wrap = document.createElement('div');
  wrap.className = 'repeat-item';
  const input = document.createElement('input');
  input.name = proto.name;
  input.placeholder = proto.placeholder;
  wrap.appendChild(input);
  const rm = document.createElement('button');
  rm.type = 'button';
  rm.className = 'btn btn-sm btn-ghost btn-danger remove-row';
  rm.textContent = 'x';
  rm.addEventListener('click', () => wrap.remove());
  wrap.appendChild(rm);
  rows.appendChild(wrap);
  input.focus();
}

function openCreate() {
  const dl = $('image-options');
  const names = (lastState?.images || []).map((i) => i.configuration?.name).filter(Boolean);
  dl.innerHTML = names.map((n) => `<option value="${api.esc(n)}"></option>`).join('');
  $('create-error').textContent = '';
  $('create-modal').classList.remove('hidden');
  setTimeout(() => $('create-form').querySelector('input[name="image"]').focus(), 0);
}

function closeCreate() {
  $('create-modal').classList.add('hidden');
}

function gatherCreate() {
  const form = $('create-form');
  const val = (n) => (form.querySelector(`input[name="${n}"]`)?.value || '').trim();
  const arr = (n) => Array.from(form.querySelectorAll(`input[name="${n}"]`))
    .map((i) => (i.value || '').trim()).filter(Boolean);
  const body = {
    image: val('image'),
    ports: arr('ports'),
    env: arr('env'),
    volumes: arr('volumes'),
    // args are space-separated here (no shell-quote parsing in v1); they land
    // after `image` as the container init argv.
    args: val('args') ? val('args').split(/\s+/).filter(Boolean) : [],
  };
  const name = val('name'); if (name) body.name = name;
  const cpus = val('cpus'); if (cpus) body.cpus = Number(cpus);
  const memory = val('memory'); if (memory) body.memory = memory;
  if (form.querySelector('input[name="rm"]').checked) body.rm = true;
  return body;
}

// Light mirror of the server validators; surfaces format errors before submit.
function clientValidateCreate(b) {
  if (!b.image) return 'image is required';
  if (b.name && !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(b.name)) return 'invalid name';
  if (!/^[A-Za-z0-9][A-Za-z0-9/:._@-]{0,255}$/.test(b.image)) return 'invalid image reference';
  for (const p of b.ports) if (!/^([\d.]+:)?\d+:\d+(\/(tcp|udp|sctp))?$/i.test(p)) return `invalid port: ${p}`;
  for (const e of b.env) if (!/^[A-Za-z_][A-Za-z0-9_]*(=.*)?$/.test(e)) return `invalid env: ${e}`;
  if (b.memory && !/^\d+[KMGTPE]?$/i.test(b.memory)) return `invalid memory: ${b.memory}`;
  return null;
}

async function onCreateSubmit(e) {
  e.preventDefault();
  const errEl = $('create-error');
  errEl.textContent = '';
  const body = gatherCreate();
  const cerr = clientValidateCreate(body);
  if (cerr) { errEl.textContent = cerr; return; }
  const btn = $('create-submit');
  btn.disabled = true;
  btn.textContent = 'Creating...';
  try {
    await api.createContainer(body);
    $('create-form').reset();
    document.querySelectorAll('.repeat-rows').forEach((r) => {
      Array.from(r.querySelectorAll('.repeat-item')).forEach((x) => x.remove());
    });
    closeCreate();
    await poll(true);   // confirm the new row appears
  } catch (err) {
    errEl.textContent = err.message || 'create failed';
  } finally {
    btn.disabled = false;
    btn.textContent = 'Create & start';
  }
}

// ---------- advanced disclosure ----------

async function loadAdvanced() {
  const details = document.querySelector('details.advanced');
  if (!details?.open) return;
  const propsEl = $('advanced-properties');
  const dnsEl = $('advanced-dns');
  propsEl.textContent = 'loading...';
  dnsEl.textContent = 'loading...';
  // Fire each independently and set on resolve/reject, so a slow or hanging
  // endpoint (system properties can stall) never blocks the other.
  const load = async (el, url) => {
    try { el.textContent = JSON.stringify(await api.fetchJson(url), null, 2); }
    catch (e) { el.textContent = `unavailable: ${e.message}`; }
  };
  load(propsEl, '/api/system/properties');
  load(dnsEl, '/api/system/dns');
}

// ---------- misc ----------

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
