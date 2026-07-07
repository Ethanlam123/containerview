# Dashboard: Apple `container` System Monitor

Build a real-time operational dashboard for Apple's `container` project — a macOS-native tool that runs Linux containers as lightweight VMs on Apple Silicon.

## Background Context

Apple's `container` tool (https://github.com/apple/container) runs each Linux container as its own lightweight VM on macOS using Virtualization.framework. The CLI is a thin client that talks to `container-apiserver` — a launchd agent started by `container system start` — via XPC. The API server in turn spawns per-container `container-runtime-linux` helpers and the `container-network-vmnet` and `container-core-images` helpers. The XPC interface is not public, so this dashboard **shells out to the `container` CLI** — the supported public surface.

The system has:

- **Containers**: Each = one lightweight Linux VM (OCI images, per-container runtime)
- **Container Machines**: Persistent Linux environments with user home mounting and init systems
- **Builder**: A dedicated "buildkit" container VM that runs `container build` (Dockerfile builds). Note: the buildkit VM also appears in `container ls` output as a regular container — `container builder status` is the cleaner source.
- **Networking**: Per-container VM with vmnet, DNS, port publishing (--publish), MAC address support
- **Images**: OCI-compatible local image store, push/pull from registries
- **Stats**: Real-time CPU (microseconds), memory, network I/O, disk I/O, process count per container
- **System**: Disk-usage accounting (`system df`), health check (`system status`), service logs, DNS domains, and system properties — all exposed via the CLI

## Goal

Build a single-page, dark-theme web dashboard that provides at-a-glance operational insight into a running `container` system, plus lightweight controls (stop/start/kill). The user runs this locally on their Mac while working with containers. It should feel like a lightweight, Apple-style monitor — clean, monochrome with accent colors, data-dense but readable.

## Architecture

The dashboard is a **local control + monitoring layer** that shells out to the `container` CLI. It is **not** read-only — the UI exposes stop/start/kill actions — but every write action is gated by ID validation and localhost-only binding (see Security).

- **Backend**: Swift Vapor 4 server. Wraps `container` CLI calls via `Process.run` (async), parses JSON, and exposes a small REST + Server-Sent-Events API.
- **Frontend**: Vanilla HTML + JS + CSS (no framework) served as static files from Vapor. Polls JSON endpoints every 5s and consumes one SSE stream for logs. All client-side features (Page Visibility pause, debounce, pulsing polling indicator, sparklines, modals, expandable rows) run in the browser.
- **Served at**: http://127.0.0.1:8080 (bound to loopback only).

## Data Sources

Each UI field is mapped to a concrete CLI command and JSON path. All commands support `--format json` unless noted.

| UI Field / Panel                | CLI Command                                      | JSON Path / Notes                                                            |
| ------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------- |
| System health (status badge)    | `container system status --format json`          | Health-checks the API server directly. Cleaner signal than `container ls`.   |
| Container list                  | `container ls --format json --all`               | Top-level array; each item has `status`, `networks[]`, `configuration.{id,hostname,resources}` |
| Container stats (all running)   | `container stats --format json --no-stream`      | Returns an **array** of stats objects (one per running container). CPU is cumulative µsec — see *Computing CPU%* below. |
| Container detail (arch, ports, mounts) | `container inspect <id>`                  | Per-row lazy load on expand. Also exposes per-network `hostname` (the `.test.` domain). |
| Machine list                    | `container machine ls --format json`             | Note: machine `ls` only supports `table` or `json` (no yaml/toml)            |
| Machine detail                  | `container machine inspect <id>`                 | Lazy load on expand. Does **not** expose live CPU/memory — see Open Questions. |
| Image list                      | `container image list --format json`             |                                                                              |
| Image detail                    | `container image inspect <name>`                 | Lazy load on modal open. Returns `{name, variants:[{platform, config}]}`.    |
| Network list                    | `container network list --format json`           | Used for "Networks" metric                                                   |
| Disk usage (images/containers/volumes) | `container system df --format json`       | Powers the new Disk Usage widget — total/active count, size, reclaimable.    |
| Builder status                  | `container builder status --format json`         | Polled every 5s                                                              |
| Version                         | `container system version --format json`         | Returns an **array** with up to 2 rows: `{appName, version, buildType, commit}` for the CLI and (if reachable) the API server. |
| System properties (optional)    | `container system property list --format json`   | Powers an optional "Advanced" disclosure in the footer.                      |
| DNS domains (optional)          | `container system dns list --format json`        | Optional footer widget.                                                      |

**Field-name note**: `container ls` uses `"status"` (not `"state"`). The UI may display it as "Status" but the backend must read `status`.

**Computing CPU%**: `container stats` reports `cpuUsageUsec` — cumulative CPU microseconds since container start, NOT a percentage and NOT normalized per core. To derive CPU% the dashboard must keep the previous stats snapshot per container and compute:

```
cpuPercent = (cpuUsageUsec_now - cpuUsageUsec_prev) / (wallTimeMs_now - wallTimeMs_prev) / 1000 * 100
```

A container with 4 CPUs fully saturated will report ~400% (matches the CLI's own `container stats` table). First sample after startup shows 0% (no baseline yet).

**Dropped fields** (no reliable CLI source): per-container uptime and the "open file descriptors" footer hint. These are omitted unless a future CLI release exposes them.

Design the CLI-calling layer as a thin shell-execution module that:
- Runs commands via `Process.run` with **argument arrays** (never a shell string).
- Parses JSON output via `JSONDecoder` into typed Swift structs (do not pass raw JSON to the client).
- Surfaces errors gracefully: tool not installed, service not started, permission denied, command timeout.
- Caches results for ~1s to dedupe concurrent requests within one poll tick.
- Keeps the previous stats snapshot in memory between ticks so CPU% can be computed.

## API Surface (Vapor endpoints)

| Endpoint                       | Method | Purpose                                              |
| ------------------------------ | ------ | ---------------------------------------------------- |
| `GET /`                        | GET    | Serves `index.html` + static assets                  |
| `GET /api/state`               | GET    | **Composite** payload: health + containers + stats (with computed CPU%) + machines + images + networks + disk usage + builder + version (one round-trip; fans out server-side) |
| `GET /api/containers/:id`      | GET    | Lazy `container inspect` for row expansion           |
| `GET /api/images/:name`        | GET    | Lazy `container image inspect` for modal             |
| `GET /api/containers/:id/logs` | GET    | **SSE** stream proxying `container logs -f <id>`     |
| `GET /api/system/logs`         | GET    | **SSE** stream proxying `container system logs -f` (optional system-log drawer) |
| `POST /api/containers/:id/stop`  | POST | `container stop <id>`                                |
| `POST /api/containers/:id/start` | POST | `container start <id>`                               |
| `POST /api/containers/:id/kill`  | POST | `container kill <id>`                                |
| `POST /api/builder/start`        | POST | `container builder start`                            |
| `POST /api/builder/stop`         | POST | `container builder stop`                             |

The composite `/api/state` endpoint is the primary poll target — clients make one request per tick, not ten, which keeps process-spawn rate predictable. Server-side, these calls run concurrently via Swift's async/await (`async let`).

## UI Layout & Features

### Header Bar

- App title: "Container · Monitor" with a small cube/VM icon (inline SVG)
- Live status badge: green dot + "System Running" or red dot + "System Stopped" (derived from `container system status` succeeding; the response itself is a health check against the API server)
- Last-refresh timestamp
- Manual refresh button + auto-refresh toggle (on/off) with an interval input (default 5s)

### Main Dashboard — Six-Panel Grid

#### 1. Containers Panel (top-left, largest)

- **Table** of all containers with columns: Name, Image, Status (colored pill: running=green, stopped=gray, created=amber), IP (from `networks[0].address`), CPU%, Memory, Arch
- Click a row → expand inline detail drawer showing:
  - Full `container stats` output (CPU%, memory usage/limit, net Rx/Tx, block I/O, PIDs)
  - Port mappings (from `container inspect`)
  - Architecture (arm64/amd64, from `container inspect`)
  - Inline **Logs** drawer: opens an SSE-streamed tail of `container logs -f <id>` with a pause/clear button
- Action buttons per row inline: Stop, Start, Kill (POST to corresponding endpoint; optimistic UI update on 2xx)
- Empty state: "No containers. Run `container run ...` to get started."

#### 2. Resource Overview (top-right, compact)

- Three stat cards in a row:
  - **Containers**: count (running / total)
  - **Memory Allocated**: sum of `resources.memoryInBytes` across running containers (labeled "allocated", not "used")
  - **Networks**: count from `container network list --format json`
- Below: a mini CPU/Memory sparkline (SVG) aggregated across running containers using the latest `container stats` snapshot.
  - **Aggregation formula**: aggregated CPU% = `Σ (cpuUsageUsec_delta_i / wall_usec_delta * 100)` over running containers `i` (do NOT divide by allocated CPUs — a 4-CPU container at saturation contributes ~400%, matching the CLI's own semantics). Memory = `Σ memoryUsageBytes`. Show the formula in a tooltip.

#### 3. Builder Panel (middle strip, full width — new)

- Card showing buildkit builder status from `container builder status --format json`:
  - State pill (running/stopped), allocated CPUs, allocated memory, builder container ID
- Inline actions: Start (`container builder start`), Stop (`container builder stop`)
- Empty/hidden state when builder has never been started

#### 4. Disk Usage Widget (right of Builder, middle strip)

- Compact summary from `container system df --format json`, broken into three rows (Images / Containers / Volumes):
  - Total count vs active count
  - Size on disk
  - Reclaimable space (with a small "Prune" button that opens a confirm dialog — `container prune` / `container image prune -a` / `container volume prune`)
- Hidden if `system df` returns empty

#### 5. Images Panel (bottom-left)

- **Card grid** of local images: name:tag, OS/arch badge, size, created date
- Search/filter input at top
- Click a card → show full `container image inspect <name> --format json` in a modal
- Progress bar for total local image storage

#### 6. Container Machines Panel (bottom-right)

- **Card list** showing each machine: name, state (running/stopped), distro image, CPU/MEM allocation
- For running machines: a small inline resource meter populated from `container machine inspect` (CPU%/memory used/limit) — best-effort if the CLI doesn't expose live stats
- Quick actions: **"Copy shell command"** button (copies `container machine run -n <name>` to clipboard; the browser cannot spawn a PTY) and **Stop** button
- Tutorial-style hint if no machines exist: "Try `container machine create alpine:3.22 --name dev`"

### Footer / System Info Bar

- System version: CLI version + API server version (both rows from `container system version --format json` array)
- macOS version (from `sw_vers -productVersion` on the backend)
- Build type + commit (from the same version payload — useful when running a dev build)
- Optional "Advanced" disclosure: system properties from `container system property list --format json` and configured DNS domains from `container system dns list --format json`
- Link to GitHub repo

## Technical Requirements

### Auto-Refresh Strategy

- Client polls `GET /api/state` every 5 seconds (configurable via the header interval input)
- Debounce: skip a tick if the previous request is still in-flight
- Pause auto-refresh when the browser tab is hidden (Page Visibility API)
- Show a subtle pulsing dot in the header when polling is active
- Server-side timeout per CLI call: 3s. On timeout, omit that section from the response and set a `warnings[]` field the client renders as a banner.

### Error Handling

- If `container` CLI is not installed → backend returns a structured error; UI shows "Install container from apple/container" with link
- If system is stopped (`container system start` not run) → UI shows "System Not Running" banner and renders last-known-good cached payload (kept in `localStorage`)
- If a specific container is deleted mid-view → it is absent from the next poll and removed from the table
- If a POST action fails → revert optimistic UI update and surface the CLI error message inline

### Security

The backend executes `container` commands based on HTTP input, so:

- **Bind to `127.0.0.1` only** — never `0.0.0.0`. Refuse to start if an explicit external bind is requested without a flag like `--allow-remote`.
- **Validate every ID** against `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` before passing to `Process`. Reject anything else with 400.
- **Use argument arrays**, never a shell string — no `sh -c`, no string interpolation into a command line.
- **No auth** is acceptable only because binding is loopback; document this assumption.

### Visual Design

- **Colors**: Deep dark background `#0a0a0f`, card surfaces `#14141f`, subtle borders `#2a2a3a`
- **Accents**: Apple-style blue `#0a84ff` (links/primary actions), green `#30d158` (running), orange `#ff9f0a` (warnings), red `#ff453a` (errors)
- **Typography**: `system-ui, -apple-system, sans-serif`; monospace (`ui-monospace`) for IDs, digests, IPs
- **Whitespace & radius**: 12px card radius, 16px padding, subtle box-shadows
- **Responsive**: 2-column grid on `>=1440px`, single column on `<900px`

## Deliverable

A single directory containing:

1. All source files for the dashboard (`Package.swift`, `Sources/`, `Resources/Public/` for static assets)
2. A `README.md` with:
   - Prerequisites: macOS 26+, Apple silicon, `container` installed and `container system start` run
   - Build: `swift build -c release`
   - Run: `swift run` or `.build/release/ContainerDashboard`
   - Open: http://127.0.0.1:8080
   - Dependency list (Vapor)
   - Screenshot (if possible)
3. A `run.sh` one-liner: `swift run || swift build && swift run`

No Docker, no external databases. First build takes ~1–2 min (Swift compilation); subsequent launches are <5s. The dashboard assumes `container` is already installed and the system service is running.

## Example JSON Shapes (verified against `container` how-to docs)

```json
// container ls --format json --all
[{
  "status": "running",
  "networks": [
    {
      "address": "192.168.64.3/24",
      "gateway": "192.168.64.1",
      "hostname": "my-web-server.test.",
      "network": "default"
    }
  ],
  "configuration": {
    "mounts": [],
    "hostname": "my-web-server",
    "id": "my-web-server",
    "resources": { "cpus": 4, "memoryInBytes": 1073741824 }
  }
}]

// container stats --format json --no-stream   (ARRAY — one entry per running container)
[
  {
    "id": "my-web-server",
    "memoryUsageBytes": 47431680,
    "memoryLimitBytes": 1073741824,
    "cpuUsageUsec": 1234567,        // cumulative microseconds — NOT a percentage
    "networkRxBytes": 1289011,
    "networkTxBytes": 876544,
    "blockReadBytes": 4718592,
    "blockWriteBytes": 2202009,
    "numProcesses": 3
  }
]

// container system version --format json   (ARRAY — CLI row always present, API server row only if reachable)
[
  { "appName": "container",            "version": "1.2.3", "buildType": "debug",   "commit": "abcdef1" },
  { "appName": "container-apiserver",  "version": "container-apiserver version 1.2.3 (build: release, commit: 1234abc)",
                                       "buildType": "release", "commit": "1234abcdef" }
]
```

**Important**: the original draft of this spec showed a Docker-style `stats` payload (`cpu_stats.cpu_usage.total_usage`, `memory_stats.usage`, `blkio_stats.io_service_bytes_recursive`, etc.). That is **not** what `container` emits. The fields are flat camelCase as shown above — model the Swift `Codable` structs accordingly.

## Open Questions (resolve before implementation)

1. ~~Confirm `container system version --format json` accepts `--format`.~~ **Resolved**: yes — documented in command-reference.md, returns an array of up to 2 component objects.
2. Confirm `container machine inspect` exposes live CPU/memory for a running machine. Current docs only describe it as "detailed information" (configuration, not runtime stats). If it does not, the machine resource meter stays blank with a "stats unavailable" tooltip — do not infer machine stats from the host-side `container stats` array (machines are not listed there).
3. Confirm the exact `container system df --format json` schema (object vs array, field names for reclaimable/active). The how-to does not show a sample; verify with a live run before modeling the struct.
4. Confirm whether `container` exposes any created/paused state besides running/stopped — the Status pill legend should match reality. The CLI reference implies stopped/running are the primary states; `created` is plausible from `container create` semantics.
5. The `buildkit` builder container appears in `container ls` output. Decide whether to filter it out of the Containers panel (to avoid double-counting with the Builder panel) or display it with a "builder" badge. Recommendation: filter it out of the Containers table and surface it only via `container builder status`.
