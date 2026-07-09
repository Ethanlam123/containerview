// App orchestrator. Owns the poll loop, optimistic actions, logs drawers, the
// image modal, the Advanced disclosure, and the last-known-good localStorage
// cache shown when the system is stopped.
import * as api from './api.js';
import {
  renderHeader, renderBanners, renderContainers, renderContainerDetail,
  renderBuilder, renderDiskUsage, renderImages, renderMachines, renderFooter,
  setPolling, resetSparklines,
} from './render.js';
import { openTerminal } from './terminal.js';

const CACHE_KEY = 'containerDashboard:lastState';
const expanded = new Set();            // expanded container ids
const logsStreams = new Map();         // id -> { paused, buffer, handle }
let lastState = null;                  // most recent successful payload
let pollTimer = null;
let inFlight = false;
let autoRefresh = true;
let intervalSec = 5;
let execEnabled = false;               // from /api/capabilities; gates the Terminal button

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
document.addEventListener('keydown', onKeydown);
function onKeydown(e) {
  if (e.key === 'Escape') {
    // The shell owns Esc while the terminal has focus (vim, readline, abort);
    // otherwise Esc dismisses the topmost surface in priority order: image
    // modal, then create modal, then the terminal tab (back to Logs).
    if (document.activeElement?.classList.contains('xterm-helper-textarea')) return;
    if (!$('modal').classList.contains('hidden')) { closeModal(); return; }
    if (!$('create-modal').classList.contains('hidden')) { closeCreate(); return; }
    if (currentTerminal) { activateTab(currentTerminal.id, 'logs'); return; }
  }
  // "/" focuses the image filter (common dashboard convention); passthrough
  // when the user is already typing in an input / terminal.
  if (e.key === '/' && !isTypingTarget(e.target)) {
    e.preventDefault();
    $('image-search').focus();
  }
}
function isTypingTarget(el) {
  if (!el || !el.tagName) return false;
  const tag = el.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT'
    || el.isContentEditable || el.classList.contains('xterm-helper-textarea');
}

// Render last-known-good immediately (before first poll resolves) so a stopped
// system still shows something.
try {
  const cached = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
  if (cached) { lastState = cached; paint(cached, true); }
} catch { /* ignore malformed cache */ }

poll(true);   // kick the first tick immediately
scheduleNext();

// Feature flags (exec opt-in). Fetched once; re-paint so the Terminal button
// appears as soon as the flag resolves (the poll loop also carries it).
api.fetchCapabilities().then((caps) => {
  execEnabled = !!caps.exec;
  if (lastState) paint(lastState, true);
});

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
  renderContainers(state, expanded, execEnabled, toggleExpand, (id) => { expanded.delete(id); closeLogs(id); closeTerminalIfId(id); });
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
    closeTerminalIfId(id);
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
    renderContainerDetail(detail, id, execEnabled);
    openLogs(id);
    wireDetailTabs(id);
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
  restoreCreateForm();
  setTimeout(() => $('create-form').querySelector('input[name="image"]').focus(), 0);
}

function closeCreate(opts) {
  // On cancel (X / background / Esc) persist the in-progress edits so reopening
  // resumes where the user left off. A successful submit saves the submitted
  // body explicitly and passes { submitted: true } to skip re-saving the now
  // reset (empty) form.
  if (!opts?.submitted) saveCreateForm(gatherCreate());
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
    // ponytail: no shell-quote parsing in v1; lands after `image` as init argv.
    args: val('args').split(/\s+/).filter(Boolean),
  };
  const name = val('name'); if (name) body.name = name;
  const cpus = val('cpus'); if (cpus) body.cpus = Number(cpus);
  const memory = val('memory'); if (memory) body.memory = memory;
  if (form.querySelector('input[name="rm"]').checked) body.rm = true;
  return body;
}

async function onCreateSubmit(e) {
  e.preventDefault();
  const errEl = $('create-error');
  errEl.textContent = '';
  const body = gatherCreate();
  const btn = $('create-submit');
  btn.disabled = true;
  btn.textContent = 'Creating...';
  try {
    await api.createContainer(body);
    saveCreateForm(body);
    $('create-form').reset();
    document.querySelectorAll('.repeat-item').forEach((x) => x.remove());
    closeCreate({ submitted: true });
    await poll(true);   // confirm the new row appears
  } catch (err) {
    // The server is the validation authority; it returns a field label (never
    // the offending value) on 4xx, a generic message on 5xx.
    errEl.textContent = err.message || 'create failed';
  } finally {
    btn.disabled = false;
    btn.textContent = 'Create & start';
  }
}

// ---------- persist create-form values ----------

const FORM_KEY = 'containerDashboard:createForm';

function saveCreateForm(data) {
  try { localStorage.setItem(FORM_KEY, JSON.stringify(data)); } catch { /* quota */ }
}

function restoreCreateForm() {
  const form = $('create-form');
  // Always start from a clean form: reset scalars + strip repeat rows left from
  // a previous open (the form is only fully reset on a successful submit), so
  // stale rows don't accumulate. Then refill from saved values, if any.
  form.reset();
  for (const name of ['ports', 'env', 'volumes']) clearRepeatGroup(name);
  let data;
  try { data = JSON.parse(localStorage.getItem(FORM_KEY) || 'null'); } catch { /* malformed */ }
  if (!data) return;
  const set = (name, val) => { const el = form.querySelector(`input[name="${name}"]`); if (el) el.value = val ?? ''; };
  set('image', data.image);
  set('name', data.name);
  set('args', (data.args || []).join(' '));
  set('cpus', data.cpus);
  set('memory', data.memory);
  const rm = form.querySelector('input[name="rm"]'); if (rm) rm.checked = !!data.rm;
  restoreRepeat('ports', data.ports || []);
  restoreRepeat('env', data.env || []);
  restoreRepeat('volumes', data.volumes || []);
}

// Strip added rows + clear the seed input so a group is back to one empty row.
function clearRepeatGroup(name) {
  const group = document.querySelector(`.repeat[data-repeat="${name}"]`);
  if (!group) return;
  group.querySelectorAll('.repeat-item').forEach((r) => r.remove());
  const seed = group.querySelector('.repeat-rows > input');
  if (seed) seed.value = '';
}

// Rehydrate one repeatable group: drop added rows, fill the seed row with the
// first value, then append a row per remaining value.
function restoreRepeat(name, values) {
  const group = document.querySelector(`.repeat[data-repeat="${name}"]`);
  if (!group) return;
  const rows = group.querySelector('.repeat-rows');
  rows.querySelectorAll('.repeat-item').forEach((r) => r.remove());
  const first = rows.querySelector('input');
  if (!first) return;
  first.value = values[0] || '';
  for (const v of values.slice(1)) {
    addRepeatRow(group);
    const inputs = rows.querySelectorAll('input');
    inputs[inputs.length - 1].value = v;
  }
}

// ---------- pull image ----------

// The server validates the ref and discards output (pull progress would
// overflow the pipe buffer); it returns a fixed label on 4xx/5xx (never the
// ref). Fire-to-completion, so the button stays "Pulling..." until it resolves.
$('pull-form').addEventListener('submit', onPullSubmit);

async function onPullSubmit(e) {
  e.preventDefault();
  const input = $('pull-reference');
  const ref = (input.value || '').trim();
  const errEl = $('pull-error');
  errEl.textContent = '';
  if (!ref) return;
  const btn = $('pull-submit');
  const prev = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Pulling...';
  try {
    await api.pullImage(ref);
    input.value = '';
    await poll(true);   // confirm the new image appears in the grid
  } catch (err) {
    errEl.textContent = err.message || 'pull failed';
  } finally {
    btn.disabled = false;
    btn.textContent = prev;
  }
}

// ---------- terminal (exec) ----------

// The terminal lives as a tab in the container detail drawer (co-located with
// logs), not a modal. One session at a time: opening a second disposes the
// first. `data-terminal` (not `data-act`) keeps the row button off the
// optimistic-action path. The backend sends binary frames; see terminal.js.
let currentTerminal = null;

document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-terminal]');
  if (!b) return;
  e.stopPropagation();
  openTerminalFor(b.dataset.terminal);
});

// Row "Terminal" button: expand the drawer (if collapsed), then switch to the
// Terminal tab, which lazily opens the ws + xterm.
async function openTerminalFor(id) {
  if (!expanded.has(id)) await toggleExpand(id);
  activateTab(id, 'terminal');
}

// Bind the tab strip after the detail body is stamped (once; the detail node is
// preserved across poll ticks, so the handlers + active tab survive).
function wireDetailTabs(id) {
  const root = document.querySelector(`[data-detail-body="${api.cssEscape(id)}"]`);
  root?.querySelectorAll('.detail-tab').forEach((tab) => {
    tab.addEventListener('click', () => activateTab(id, tab.dataset.tab));
  });
}

function activateTab(id, which) {
  const root = document.querySelector(`[data-detail-body="${api.cssEscape(id)}"]`);
  if (!root) return;
  root.querySelectorAll('.detail-tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === which));
  root.querySelectorAll('.detail-panel').forEach((p) => p.classList.toggle('hidden', p.dataset.panel !== which));
  if (which === 'terminal') openDrawerTerminal(id);
  else closeTerminalIfId(id);   // leaving the terminal tab tears it down
}

function openDrawerTerminal(id) {
  if (currentTerminal?.id === id) return;            // already open in this drawer
  if (currentTerminal) { currentTerminal.handle.dispose(); currentTerminal = null; }
  const mount = document.querySelector(`[data-terminal-mount="${api.cssEscape(id)}"]`);
  if (!mount) return;
  currentTerminal = { id, handle: openTerminal(id, mount) };
}

function closeTerminal() {
  if (!currentTerminal) return;
  currentTerminal.handle.dispose();
  currentTerminal = null;
}

function closeTerminalIfId(id) {
  if (currentTerminal?.id === id) closeTerminal();
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
