# Container - Monitor

A real-time, local operational dashboard for Apple's [`container`](https://github.com/apple/container) project, which runs Linux containers as lightweight VMs on Apple Silicon. This is a thin control + monitoring layer that shells out to the `container` CLI over a loopback-only Vapor 4 server.

## What it shows

A single dark-theme page with six panels:

1. **Containers** - table (name, image, status pill, IP, CPU%, memory, arch) with expandable rows that reveal ports, mounts, hostname, and a live SSE logs drawer. Inline Stop / Start / Kill.
2. **Resource Overview** - containers (running / total), memory allocated, networks, plus aggregated CPU% and memory sparklines.
3. **Builder** - buildkit builder state, CPUs, memory, container id, with Start / Stop.
4. **Disk Usage** - images / containers / volumes: active vs total, size, reclaimable, each with a Prune button (confirm dialog).
5. **Images** - card grid with OS/arch + size, filter input, storage bar, click for full `image inspect` modal.
6. **Container Machines** - card list with state and resources, plus "Copy shell command" (`container machine run -n <name>`).

The footer shows CLI + API-server versions, macOS version, build type, and an Advanced disclosure with system properties and DNS domains.

## Prerequisites

- macOS 26+ on Apple Silicon
- `container` installed and on `$PATH` (`container system start` run at least once)
- Swift 6 toolchain (Swift 6.0+)

## Build

```sh
swift build -c release
```

## Run

```sh
swift run                              # debug, default
./run.sh                               # same, but pins CWD for assets
./run.sh --release                     # build + run the release binary
.build/release/ContainerDashboard      # run a built release directly
```

Then open <http://127.0.0.1:8080>.

The server binds to **127.0.0.1 only** and refuses to start for any non-loopback address unless run with `--allow-remote` (`CONTAINER_DASHBOARD_ALLOW_REMOTE=1`). Loopback binding is why no auth is required; enabling remote access removes that guarantee and is discouraged.

## Architecture

```
Browser (poll /api/state every 5s + one SSE stream per open logs drawer)
  |
  |  HTTP, loopback only
  v
Vapor 4 server (Sources/ContainerDashboard)
  |- OriginGuardMiddleware   - DNS-rebinding / CSRF defense on writes
  |- LoopbackGuard           - refuse non-loopback bind unless --allow-remote
  |- ResultCache             - ~1s TTL dedupe of concurrent reads
  |- StatsTracker            - retains per-container cpuUsageUsec baseline
  |                            so CPU% can be derived between ticks
  `- ContainerCLI            - typed wrappers over the `container` CLI
        `- ProcessCommandRunner - argument arrays only, never a shell string
```

Every `:id` / `:name` / `:category` is validated against a strict regex before it reaches `Process`. Write actions (stop / start / kill / builder / prune) additionally require a loopback `Origin` (or no `Origin`) and reject `Sec-Fetch-Site: cross-site`.

CPU% is computed server-side: `container stats` reports cumulative `cpuUsageUsec`, not a percentage, so the backend keeps the previous snapshot per container and derives `(dCPU / dWall) * 100`. A 4-CPU container at saturation reads ~400%, matching the CLI's own table. The first sample after start reads 0% (no baseline yet).

## API surface

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/` | GET | `index.html` + static assets |
| `/api/state` | GET | Composite payload (health, containers, stats with CPU%, machines, images, networks, disk usage, builder, version) - the primary poll target |
| `/api/containers/:id` | GET | Lazy `container inspect <id>` for row expansion |
| `/api/images/inspect?name=` | GET | Lazy `container image inspect <name>` for the modal |
| `/api/machines/:id` | GET | Lazy `container machine inspect <id>` |
| `/api/containers/:id/logs` | GET | SSE stream proxying `container logs -f <id>` |
| `/api/system/properties` | GET | Raw `container system property list` JSON |
| `/api/system/dns` | GET | Raw `container system dns list` JSON |
| `/api/containers/:id/{stop,start,kill}` | POST | Container lifecycle |
| `/api/builder/{start,stop}` | POST | Builder lifecycle |
| `/api/prune/:category` | POST | `containers` / `images` / `volumes` |

## SSE + disconnect handling (known limitation)

Vapor 4 does not surface a per-request channel-inactive signal to a GET SSE handler, and writes to a half-closed (CLOSE_WAIT) connection keep succeeding, so the server cannot reliably detect the instant a browser tab closes. To guarantee no `container logs -f` child is orphaned, every SSE connection is capped at 120 s; on expiry the producer is reaped (SIGTERM -> grace -> SIGKILL) and `EventSource` reconnects transparently. An orphaned stream therefore lives at most ~120 s. This is the best Vapor's public API permits without a custom channel handler, which it does not expose. The implementation notes in `Sources/ContainerDashboard/Support/SSE.swift` record the investigation.

## Project layout

```
Sources/ContainerDashboard/
  app.swift              @main entry; binds loopback, runs the server
  configure.swift        middleware + service wiring
  routes.swift           endpoint registration + validators
  CLI/
    CommandRunner.swift  Process shell-out (arg arrays) + LogStream handle
    ContainerCLI.swift   typed wrappers over the `container` CLI
    StatsTracker.swift   CPU% derivation across ticks
    ResultCache.swift    TTL dedupe decorator
  Service/StateService.swift   concurrent fan-out for /api/state
  Support/
    IDValidator.swift, LoopbackGuard.swift, OriginGuardMiddleware.swift, SSE.swift
  Models/                Codable shapes modeled against captured CLI fixtures
Tests/ContainerDashboardTests/  72 swift-testing tests
Resources/Public/        index.html, styles.css, api.js, render.js, app.js
```

## Notes

- The buildkit builder VM also appears in `container ls`; the backend filters it out of both `containers` and `stats` so it does not distort the Containers panel or the sparkline.
- Per-container uptime and open-fd counts are not exposed by the CLI and are omitted.
- The Machine panel and running-builder shape render defensively against the empty-array case; richer fields populate once a machine exists.
