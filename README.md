# Container - Monitor

A real-time, local operational dashboard for Apple's [`container`](https://github.com/apple/container) project, which runs Linux containers as lightweight VMs on Apple Silicon. This is a thin control + monitoring layer that shells out to the `container` CLI over a loopback-only Vapor 4 server.

## What it shows

A single dark-theme page with six panels:

1. **Containers** - table (name, image, status pill, IP, CPU%, memory, arch) with expandable rows that reveal ports, mounts, hostname, a live SSE logs drawer, and (when exec is enabled) an interactive terminal pane. Inline Stop / Start / Kill, plus a "+ New" create-and-run modal.
2. **Resource Overview** - containers (running / total), memory allocated, networks, plus aggregated CPU% and memory sparklines.
3. **Builder** - buildkit builder state, CPUs, memory, container id, with Start / Stop.
4. **Disk Usage** - images / containers / volumes: active vs total, size, reclaimable, each with a Prune button (confirm dialog).
5. **Images** - card grid with OS/arch + size, filter input, storage bar, click for full `image inspect` modal, plus a pull-by-reference field.
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
swift run                                       # debug, default
./run.sh                                        # same, but pins CWD for assets
./run.sh --release                              # build + run the release binary
./run.sh --release --exec                       # ...with the interactive terminal enabled
.build/release/ContainerDashboard               # run a built release directly
CONTAINERDASHBOARD_ENABLE_EXEC=1 swift run      # env-var equivalent of --exec
```

Then open <http://127.0.0.1:8080>.

The server binds to **127.0.0.1 only** and refuses to start for any non-loopback address unless run with `--allow-remote` (`CONTAINER_DASHBOARD_ALLOW_REMOTE=1`). Loopback binding is why no auth is required; enabling remote access removes that guarantee and is discouraged.

### Environment variables

| Variable | Default | Effect |
| --- | --- | --- |
| `CONTAINER_DASHBOARD_PORT` | `8080` | TCP port to listen on. 8080 is heavily contested on macOS (meeting apps, dev servers); set this to run without editing source. |
| `CONTAINER_DASHBOARD_ALLOW_REMOTE` | unset | `1` permits a non-loopback bind (`run.sh --allow-remote`). Off keeps the server loopback-only. |
| `CONTAINERDASHBOARD_ENABLE_EXEC` | unset | `1` enables the interactive terminal: the `exec` WebSocket route and the Terminal button. Off returns 404 and hides the button. |
| `CONTAINERDASHBOARD_ALLOW_REMOTE_BIND` | unset | `1` lets `container run -p` bind a non-loopback host-ip. Off rewrites published ports to `127.0.0.1` and rejects an explicit non-loopback host-ip. |

## Architecture

```
Browser (poll /api/state every 5s + one SSE logs stream per open drawer
         + one WebSocket per open terminal)
  |
  |  HTTP / WebSocket, loopback only
  v
Vapor 4 server (Sources/ContainerDashboard)
  |- OriginGuardMiddleware   - DNS-rebinding / CSRF defense on writes + ws upgrades
  |- LoopbackGuard           - refuse non-loopback bind unless --allow-remote
  |- ResultCache             - ~1s TTL dedupe of concurrent reads (writes bypass)
  |- StatsTracker            - retains per-container cpuUsageUsec baseline
  |                            so CPU% can be derived between ticks
  |- ExecPool                - caps concurrent exec sessions at 8
  `- ContainerCLI            - typed wrappers over the `container` CLI
        |- ProcessCommandRunner - argument arrays only, never a shell string
        `- PTYProcessRunner     - host PTY bridge for `container exec -t`
```

Every `:id` / `:name` / `:category` is validated against a strict regex before it reaches `Process`. Write actions (stop / start / kill / run / pull / builder / prune) additionally require a loopback `Origin` (or no `Origin`) and reject `Sec-Fetch-Site: cross-site`; the same check runs inside the exec WebSocket upgrade. Side-effecting commands bypass the result cache so a repeated (e.g. double-clicked) call is never turned into a cached no-op.

CPU% is computed server-side: `container stats` reports cumulative `cpuUsageUsec`, not a percentage, so the backend keeps the previous snapshot per container and derives `(dCPU / dWall) * 100`. A 4-CPU container at saturation reads ~400%, matching the CLI's own table. The first sample after start reads 0% (no baseline yet).

## API surface

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/` | GET | `index.html` + static assets |
| `/api/state` | GET | Composite payload (health, containers, stats with CPU%, machines, images, networks, disk usage, builder, version) - the primary poll target |
| `/api/capabilities` | GET | Feature flags for the frontend (`{exec: bool}`); hides the Terminal button when exec is off |
| `/api/containers/:id` | GET | Lazy `container inspect <id>` for row expansion |
| `/api/images/inspect?name=` | GET | Lazy `container image inspect <name>` for the modal |
| `/api/machines/:id` | GET | Lazy `container machine inspect <id>` |
| `/api/containers/:id/logs` | GET | SSE stream proxying `container logs -f <id>` |
| `/api/system/properties` | GET | Raw `container system property list` JSON |
| `/api/system/dns` | GET | Raw `container system dns list` JSON |
| `/api/containers/run` | POST | Create + start a container (`container run --detach`); 201 `{id}` |
| `/api/images/pull` | POST | Pull an image by reference; 202 on completion |
| `/api/containers/:id/exec` | WS | Interactive shell (`container exec -i -t <id> /bin/sh`); 404 when exec is off |
| `/api/containers/:id/{stop,start,kill}` | POST | Container lifecycle |
| `/api/builder/{start,stop}` | POST | Builder lifecycle |
| `/api/prune/:category` | POST | `containers` / `images` / `volumes` |

### Create + run

`POST /api/containers/run` decodes a JSON body into validator-backed value types (no raw `String` survives into argv) and runs `container run --detach`, recovering the new id from a server-generated `--cidfile`:

```sh
curl -XPOST localhost:8080/api/containers/run \
  -H 'Content-Type: application/json' \
  -d '{"image":"alpine:latest","name":"smoke","ports":["8080:80"],"env":["FOO=bar"],"volumes":["/abs/path:/data"]}'
# -> 201 {"id":"..."}
```

Each field is validated for argv-element safety (parsed and re-serialized; NUL / newline / a leading `-` rejected; bounded counts and sizes). Published ports are re-serialized as `127.0.0.1:<host>:<container>/<proto>` unless `CONTAINERDASHBOARD_ALLOW_REMOTE_BIND=1`; an explicit non-loopback host-ip is rejected without that flag. Decode and CLI failures return a generic reason (never the offending value or CLI stderr).

### Pull

`POST /api/images/pull` runs `container image pull <ref>` uncached with output discarded (pull emits enough progress to overflow a pipe buffer and would otherwise hang the child). Fire-to-completion with a 600 s ceiling; streaming progress over SSE is a follow-up.

```sh
curl -XPOST localhost:8080/api/images/pull \
  -H 'Content-Type: application/json' -d '{"reference":"alpine"}'
# -> 202
```

## Interactive terminal (exec)

An interactive shell into a running container, served over a WebSocket:

```
ws://127.0.0.1:8080/api/containers/<id>/exec?cols=80&rows=24
```

- **Opt-in.** Disabled by default; set `CONTAINERDASHBOARD_ENABLE_EXEC=1`. When off the route returns 404, `/api/capabilities` reports `{exec:false}`, and the frontend hides the Terminal button.
- **Fixed command.** The server always runs `container exec -i -t <id> /bin/sh`. Keystrokes travel PTY-master -> slave -> container stdin and never become a `Process` argument, so there is no host-shell injection vector.
- **Origin guard.** The same loopback-`Origin` / `Sec-Fetch-Site` check that guards writes runs inside the WebSocket upgrade; a cross-origin upgrade is rejected with 403.
- **Teardown.** A clean disconnect is reaped on `ws.onClose`. Dirty disconnects (lid close, VPN drop, NAT idle) send no FIN, so the connection is heartbeat-bounded: Vapor pings every 30 s and force-closes if no pong returns (~60 s bound), with a 30 min safety-net that closes any one session regardless. `ExecPool` caps concurrency at 8 (overflow returns a "terminal pool full" close).

The frontend terminal uses vendored [xterm.js](https://xtermjs.org/) UMD bundles (`@xterm/xterm` 5.5.0 + `@xterm/addon-fit` 0.10.0) committed under `Resources/Public/lib/` - no CDN at runtime. Versions and sha256 checksums are recorded in [`Resources/Public/lib/README.md`](Resources/Public/lib/README.md); ws<->term is hand-wired, so the deprecated `@xterm/addon-attach` is not vendored.

**Known limitations.** The CLI exposes no post-start resize API, so the PTY size is set once from the `cols`/`rows` query (terminal display scaling still works). `Foundation.Process` spawns via `posix_spawn` with no `setsid`/`TIOCSCTTY` hook, so job control (`Ctrl-Z`, `fg`/`bg`) does not work; `Ctrl-C` still interrupts the foreground child via the slave's line discipline.

## SSE + disconnect handling (known limitation)

Vapor 4 does not surface a per-request channel-inactive signal to a GET SSE handler, and writes to a half-closed (CLOSE_WAIT) connection keep succeeding, so the server cannot reliably detect the instant a browser tab closes. To guarantee no `container logs -f` child is orphaned, every SSE connection is capped at 120 s; on expiry the producer is reaped (SIGTERM -> grace -> SIGKILL) and `EventSource` reconnects transparently. An orphaned stream therefore lives at most ~120 s. This is the best Vapor's public API permits without a custom channel handler, which it does not expose. The implementation notes in `Sources/ContainerDashboard/Support/SSE.swift` record the investigation.

## Security posture + residual risk

The dashboard is loopback-only and validates every path parameter / image-ref / run field at the HTTP boundary before any `Process`, using argument arrays exclusively (never a shell string). Writes and the exec WebSocket upgrade require a loopback `Origin` (or none) and reject `Sec-Fetch-Site: cross-site`.

`run` (bind volumes) and `exec` (an arbitrary shell) can nonetheless mount and read/write arbitrary host paths. That capability is real, not pretended away: the loopback bind plus the Origin/`Sec-Fetch-Site` posture is what prevents a hostile website from exercising it. A malicious process already on the same loopback could still reach the server; that is the accepted residual of a no-auth, local-only tool, and why enabling `--allow-remote` is discouraged.

## Project layout

```
Sources/ContainerDashboard/
  app.swift              @main entry; binds loopback, runs the server
  configure.swift        middleware + service wiring; reads exec opt-in
  routes.swift           endpoint registration + boundary validation
  CLI/
    CommandRunner.swift  Process shell-out (arg arrays) + LogStream
    ContainerCLI.swift   typed wrappers over the `container` CLI
    PTY.swift            posix_openpt host-PTY helper
    PTYRunner.swift      PTYProcessRunner: exec bridge over a host PTY
    ExecPool.swift       actor capping concurrent exec sessions at 8
    StatsTracker.swift   CPU% derivation across ticks
    ResultCache.swift    TTL dedupe decorator (writes bypass)
  Service/StateService.swift   concurrent fan-out for /api/state
  Support/
    IDValidator.swift, LoopbackGuard.swift, OriginGuardMiddleware.swift,
    SSE.swift, RunSpecs.swift (PortSpec / EnvSpec / VolumeSpec / ...)
  Models/                Codable shapes modeled against captured CLI fixtures
Tests/ContainerDashboardTests/  113 swift-testing tests
Resources/Public/        index.html, styles.css, api.js, render.js, app.js, terminal.js
  lib/                   vendored xterm.js UMD bundles (+ README)
```

## Notes

- The buildkit builder VM also appears in `container ls`; the backend filters it out of both `containers` and `stats` so it does not distort the Containers panel or the sparkline.
- Per-container uptime and open-fd counts are not exposed by the CLI and are omitted.
- The Machine panel and running-builder shape render defensively against the empty-array case; richer fields populate once a machine exists.
