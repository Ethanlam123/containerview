// Pure-ish render functions: given a DOM root element id and a data slice,
// stamp the panel. No fetching here - app.js owns the poll loop and hands
// rendered state to these. Sparkline history is kept in module state.
import { formatBytes, formatPercent, shortHash } from './api.js';

const els = {
  statusBadge:    () => document.getElementById('status-badge'),
  pollDot:        () => document.getElementById('poll-dot'),
  lastRefresh:    () => document.getElementById('last-refresh'),
  errorBanner:    () => document.getElementById('error-banner'),
  warningsBanner: () => document.getElementById('warnings-banner'),
  containersBody: () => document.getElementById('containers-tbody'),
  containersEmpty:() => document.getElementById('containers-empty'),
  containersCount:() => document.getElementById('containers-count'),
  resContainers:  () => document.getElementById('res-containers'),
  resMemory:      () => document.getElementById('res-memory'),
  resNetworks:    () => document.getElementById('res-networks'),
  sparkCpu:       () => document.getElementById('spark-cpu'),
  sparkMem:       () => document.getElementById('spark-mem'),
  sparkCpuVal:    () => document.getElementById('spark-cpu-val'),
  sparkMemVal:    () => document.getElementById('spark-mem-val'),
  builderState:   () => document.getElementById('builder-state'),
  builderCpus:    () => document.getElementById('builder-cpus'),
  builderMemory:  () => document.getElementById('builder-memory'),
  builderId:      () => document.getElementById('builder-id'),
  diskRows:       () => document.getElementById('disk-rows'),
  imagesGrid:     () => document.getElementById('images-grid'),
  imagesEmpty:    () => document.getElementById('images-empty'),
  imagesStorage:  () => document.getElementById('images-storage-fill'),
  machinesList:   () => document.getElementById('machines-list'),
  machinesEmpty:  () => document.getElementById('machines-empty'),
  footerCli:      () => document.getElementById('footer-cli'),
  footerApi:      () => document.getElementById('footer-apiserver'),
  footerMacos:    () => document.getElementById('footer-macos'),
  footerBuild:    () => document.getElementById('footer-build'),
};

// Sparkline history (aggregated per tick). Capped ring buffer.
const SPARK_N = 60;
const sparkHistory = { cpu: [], mem: [] };

export function resetSparklines() {
  sparkHistory.cpu = [];
  sparkHistory.mem = [];
}

/// Status badge + last-refresh stamp.
export function renderHeader(state, ok) {
  const badge = els.statusBadge();
  const label = badge.querySelector('.label');
  badge.className = 'badge';
  if (!ok) {
    badge.classList.add('badge-stopped');
    label.textContent = 'System Stopped';
  } else if (state && state.health && state.health.status === 'ok') {
    badge.classList.add('badge-running');
    label.textContent = 'System Running';
  } else {
    badge.classList.add('badge-unknown');
    label.textContent = state ? 'Degraded' : 'No data';
  }
  els.lastRefresh().textContent = new Date().toLocaleTimeString();
}

export function setPolling(active) {
  els.pollDot().classList.toggle('active', active);
}

/// Banners: CLI-missing error + per-section warnings.
export function renderBanners(err, warnings) {
  const eb = els.errorBanner();
  if (err) {
    let html = escape(err.message || 'Connection error');
    if (err.kind === 'cli-missing') {
      html = `container CLI not found. Install from <a class="footer-link" href="https://github.com/apple/container" target="_blank" rel="noopener">apple/container</a>.`;
    }
    eb.innerHTML = html;
    eb.classList.remove('hidden');
  } else {
    eb.classList.add('hidden');
  }
  const wb = els.warningsBanner();
  if (warnings && warnings.length) {
    wb.textContent = warnings.map((w) => `${w.section}: ${w.message}`).join(' - ');
    wb.classList.remove('hidden');
  } else {
    wb.classList.add('hidden');
  }
}

/// Containers table + resource overview + sparklines.
export function renderContainers(state, expanded, onToggle) {
  const tbody = els.containersBody();
  const containers = (state && state.containers) || [];
  const statsById = indexStats(state);
  els.containersCount().textContent = containers.length ? `${containers.length}` : '';
  els.containersEmpty().classList.toggle('hidden', containers.length > 0);

  if (containers.length === 0) {
    tbody.innerHTML = '';
  } else {
    tbody.innerHTML = containers.map((c) => rowHtml(c, statsById[c.id], expanded.has(c.id))).join('');
    tbody.querySelectorAll('tr.row').forEach((tr) => {
      tr.addEventListener('click', (e) => {
        if (e.target.closest('button, .expand-caret')) return;
        onToggle(tr.dataset.id);
      });
    });
  }

  // Resource overview cards.
  const running = containers.filter((c) => /running/i.test(c.status?.state || ''));
  const memAlloc = running.reduce((a, c) => a + (c.configuration?.resources?.memoryInBytes || 0), 0);
  els.resContainers().textContent = `${running.length} / ${containers.length}`;
  els.resMemory().textContent = formatBytes(memAlloc);
  els.resNetworks().textContent = (state && state.networks?.length) ?? '-';

  // Sparkline: aggregate CPU% + memory across running containers' stats.
  const aggStats = (state && state.stats) || [];
  const agg = aggStats.reduce(
    (a, s) => {
      a.cpu += s.cpuPercent || 0;
      a.mem += s.stats?.memoryUsageBytes || 0;
      return a;
    },
    { cpu: 0, mem: 0 }
  );
  pushSpark(agg.cpu, agg.mem);
  drawSpark(els.sparkCpu(), sparkHistory.cpu, els.sparkCpuVal(), formatPercent(agg.cpu));
  drawSpark(els.sparkMem(), sparkHistory.mem, els.sparkMemVal(), formatBytes(agg.mem));
}

function indexStats(state) {
  const map = {};
  for (const s of (state && state.stats) || []) map[s.stats?.id || s.id] = s;
  return map;
}

function rowHtml(c, st, isOpen) {
  const cfg = c.configuration || {};
  const state = (c.status?.state || 'unknown').toLowerCase();
  const net0 = c.status?.networks?.[0];
  const ip = net0?.ipv4Address || net0?.ipv6Address || '-';
  const cpu = st ? formatPercent(st.cpuPercent) : '-';
  const mem = st ? formatBytes(st.stats?.memoryUsageBytes) : '-';
  const arch = cfg.platform?.architecture || '-';
  return `
    <tr class="row" data-id="${esc(c.id)}">
      <td><span class="expand-caret ${isOpen ? 'open' : ''}">${isOpen ? '&#9662;' : '&#9656;'}</span></td>
      <td class="row-name">${esc(cfg.id || c.id)}</td>
      <td class="row-img">${esc(cfg.image?.reference || '-')}</td>
      <td><span class="pill pill-${pillClass(state)}">${esc(state)}</span></td>
      <td class="row-arch">${esc(ip)}</td>
      <td class="num">${cpu}</td>
      <td class="num">${mem}</td>
      <td class="row-arch">${esc(arch)}</td>
      <td class="row-actions" data-actions="${esc(c.id)}">
        <button class="btn btn-sm btn-ghost" data-act="start">Start</button>
        <button class="btn btn-sm btn-ghost" data-act="stop">Stop</button>
        <button class="btn btn-sm btn-ghost btn-danger" data-act="kill">Kill</button>
      </td>
    </tr>
    ${isOpen ? `<tr class="row-detail" data-detail="${esc(c.id)}"><td colspan="9"><div class="detail-inner" data-detail-body="${esc(c.id)}">loading...</div></td></tr>` : ''}
  `;
}

function pillClass(state) {
  if (/running/.test(state)) return 'running';
  if (/created/.test(state)) return 'created';
  if (/stopped|exited/.test(state)) return 'stopped';
  return '';
}

export function renderContainerDetail(body, id) {
  const root = document.querySelector(`[data-detail-body="${cssEscape(id)}"]`);
  if (!root) return;
  const c = Array.isArray(body) ? body[0] : body;
  if (!c) { root.textContent = 'no detail'; return; }
  const stEl = document.querySelector(`tr.row[data-id="${cssEscape(id)}"]`);
  // Stats may not be in inspect; reuse row-level is not available here, so show inspect fields.
  const ports = c.configuration?.publishedPorts || [];
  const mounts = c.configuration?.mounts || [];
  root.innerHTML = `
    <div class="detail-kv"><span class="k">Hostname</span><span class="v">${esc(c.configuration?.hostname || c.status?.networks?.[0]?.hostname || '-')}</span></div>
    <div class="detail-kv"><span class="k">OS / Arch</span><span class="v">${esc(c.configuration?.platform?.os || '-')}/${esc(c.configuration?.platform?.architecture || '-')}</span></div>
    <div class="detail-kv"><span class="k">CPUs</span><span class="v">${esc(c.configuration?.resources?.cpus ?? '-')}</span></div>
    <div class="detail-kv"><span class="k">Memory limit</span><span class="v">${formatBytes(c.configuration?.resources?.memoryInBytes)}</span></div>
    <div class="detail-kv"><span class="k">Image digest</span><span class="v">${esc(shortHash(c.configuration?.image?.descriptor?.digest, 24))}</span></div>
    <div class="detail-kv"><span class="k">Started</span><span class="v">${esc(c.status?.startedDate || '-')}</span></div>
    <div class="detail-kv"><span class="k">Ports</span><span class="v">${ports.length ? ports.map((p) => `${p.hostAddress}:${p.hostPort}->${p.containerPort}/${p.proto}`).join(', ') : '-'}</span></div>
    <div class="detail-kv"><span class="k">Mounts</span><span class="v">${mounts.length ? mounts.map((m) => `${m.type?.kind}: ${esc(m.source)} -> ${esc(m.destination)}`).join(', ') : '-'}</span></div>
    <div class="detail-logs" data-logs="${esc(id)}">
      <div class="logs-bar">
        <span class="k dim">Logs</span>
        <button class="btn btn-sm btn-ghost" data-logs-toggle>Pause</button>
        <button class="btn btn-sm btn-ghost" data-logs-clear>Clear</button>
      </div>
      <pre class="logs-pre" data-logs-pre></pre>
    </div>
  `;
}

/// Builder panel.
export function renderBuilder(state) {
  const arr = (state && state.builder) || [];
  const b = arr[0];
  const stateEl = els.builderState();
  if (!b) {
    stateEl.textContent = 'stopped';
    stateEl.className = 'pill pill-stopped';
    els.builderCpus().textContent = '-';
    els.builderMemory().textContent = '-';
    els.builderId().textContent = '-';
    return;
  }
  const st = (b.state || 'unknown').toLowerCase();
  stateEl.textContent = st;
  stateEl.className = `pill pill-${/running/.test(st) ? 'running' : 'stopped'}`;
  els.builderCpus().textContent = b.cpus ?? '-';
  els.builderMemory().textContent = b.memoryInBytes != null ? formatBytes(b.memoryInBytes) : '-';
  els.builderId().textContent = b.containerID ? shortHash(b.containerID, 12) : '-';
}

/// Disk usage widget with per-category Prune.
export function renderDiskUsage(state, onPrune) {
  const df = state && state.diskUsage;
  const root = els.diskRows();
  if (!df) { root.innerHTML = '<p class="empty">No disk-usage data.</p>'; return; }
  const cats = [
    ['Images', df.images, 'images'],
    ['Containers', df.containers, 'containers'],
    ['Volumes', df.volumes, 'volumes'],
  ];
  root.innerHTML = cats.map(([title, c, key]) => `
    <div class="disk-row">
      <div>
        <div class="disk-title">${title}</div>
        <div class="disk-sub">${c.active} active / ${c.total} total - ${formatBytes(c.sizeInBytes)}</div>
      </div>
      <div class="disk-reclaim">
        ${formatBytes(c.reclaimable)} reclaimable
        <button class="btn btn-sm btn-ghost btn-danger" data-prune="${key}">Prune</button>
      </div>
    </div>
  `).join('');
  root.querySelectorAll('[data-prune]').forEach((btn) => {
    btn.addEventListener('click', () => onPrune(btn.dataset.prune));
  });
}

/// Images card grid (filtered) + storage progress bar.
export function renderImages(state, filter, onOpen) {
  const images = (state && state.images) || [];
  const root = els.imagesGrid();
  els.imagesEmpty().classList.toggle('hidden', images.length > 0);
  const f = (filter || '').toLowerCase();
  const filtered = images.filter((i) => !f || (i.configuration?.name || '').toLowerCase().includes(f));
  const totalSize = images.reduce((a, i) => {
    const v = i.variants?.find((x) => /arm64/.test(x.platform?.architecture || '')) || i.variants?.[0];
    return a + (v?.size || 0);
  }, 0);
  els.imagesStorage().style.width = Math.min(100, totalSize / (50 * 1024 * 1024 * 1024) * 100) + '%';
  if (filtered.length === 0) {
    root.innerHTML = images.length ? '<p class="empty">No matches.</p>' : '';
    return;
  }
  root.innerHTML = filtered.map((i) => {
    const v = i.variants?.find((x) => /arm64/.test(x.platform?.architecture || '')) || i.variants?.[0];
    return `
      <div class="image-card" data-image="${esc(i.configuration?.name || '')}">
        <div class="image-name">${esc(i.configuration?.name || i.id)}</div>
        <div class="image-meta">
          <span>${esc(v?.platform?.os || '-')}/${esc(v?.platform?.architecture || '-')}</span>
          <span>${formatBytes(v?.size)}</span>
        </div>
      </div>
    `;
  }).join('');
  root.querySelectorAll('[data-image]').forEach((card) => {
    card.addEventListener('click', () => onOpen(card.dataset.image));
  });
}

/// Container machines panel.
export function renderMachines(state, onCopy, onStop) {
  const machines = (state && state.machines) || [];
  const root = els.machinesList();
  els.machinesEmpty().classList.toggle('hidden', machines.length > 0);
  if (!machines.length) { root.innerHTML = ''; return; }
  root.innerHTML = machines.map((m) => {
    const name = m.configuration?.name || m.id || '-';
    const st = (m.status?.state || 'unknown').toLowerCase();
    const img = m.configuration?.image || '-';
    const cpus = m.configuration?.resources?.cpus;
    const mem = m.configuration?.resources?.memoryInBytes;
    return `
      <div class="machine-card" data-machine="${esc(m.id || name)}">
        <div class="machine-head">
          <span class="machine-name">${esc(name)}</span>
          <span class="pill pill-${/running/.test(st) ? 'running' : 'stopped'}">${esc(st)}</span>
        </div>
        <div class="machine-meta">${esc(img)} - ${cpus ?? '?'} cpu${mem != null ? ' - ' + formatBytes(mem) : ''}</div>
        <div class="row-actions" style="margin-top:8px">
          <button class="btn btn-sm btn-ghost" data-copy="${esc(name)}">Copy shell command</button>
          <button class="btn btn-sm btn-ghost btn-danger" data-stop-machine="${esc(m.id || name)}">Stop</button>
        </div>
      </div>
    `;
  }).join('');
  root.querySelectorAll('[data-copy]').forEach((btn) => btn.addEventListener('click', () => onCopy(btn.dataset.copy)));
  root.querySelectorAll('[data-stop-machine]').forEach((btn) => btn.addEventListener('click', () => onStop(btn.dataset.stopMachine)));
}

/// Footer version + macOS + build metadata.
export function renderFooter(state) {
  const v = (state && state.version) || [];
  const cli = v.find((x) => /cli/i.test(x.appName)) || v[0];
  const api = v.find((x) => /api/i.test(x.appName));
  els.footerCli().textContent = cli ? `${cli.version} (${shortHash(cli.commit, 8)})` : '-';
  els.footerApi().textContent = api ? `${api.version} (${shortHash(api.commit, 8)})` : 'unreachable';
  els.footerMacos().textContent = state?.macosVersion || '-';
  els.footerBuild().textContent = cli ? `${cli.buildType || '-'}` : '-';
}

// ---------- sparkline internals ----------

function pushSpark(cpu, mem) {
  sparkHistory.cpu.push(cpu || 0);
  sparkHistory.mem.push(mem || 0);
  if (sparkHistory.cpu.length > SPARK_N) sparkHistory.cpu.shift();
  if (sparkHistory.mem.length > SPARK_N) sparkHistory.mem.shift();
}

function drawSpark(svg, data, valEl, valText) {
  if (!svg) return;
  const poly = svg.querySelector('polyline');
  if (!data.length) { poly.setAttribute('points', ''); valEl.textContent = valText; return; }
  const max = Math.max(...data, 1);
  const step = 100 / Math.max(SPARK_N - 1, 1);
  const offset = (SPARK_N - data.length) * step;
  const pts = data.map((v, i) => `${(offset + i * step).toFixed(2)},${(24 - (v / max) * 22).toFixed(2)}`).join(' ');
  poly.setAttribute('points', pts);
  valEl.textContent = valText;
}

// ---------- escape helpers ----------

function esc(s) { return escape(s == null ? '' : String(s)); }
function escape(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function cssEscape(s) {
  if (window.CSS && CSS.escape) return CSS.escape(s);
  return String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c);
}
