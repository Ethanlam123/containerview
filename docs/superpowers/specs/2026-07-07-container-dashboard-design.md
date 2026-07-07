# Container Monitor Dashboard - Design Spec

**Goal:** Build a single-page, dark-theme web dashboard that monitors and controls Apple's `container` system (Linux containers as lightweight VMs on Apple Silicon), served locally at http://127.0.0.1:8080.

**Architecture:** A Swift Vapor 4 backend wraps the `container` CLI via `Process.run` (argument arrays, never a shell string), parses JSON into typed Swift structs, and exposes a small REST + Server-Sent-Events API. A vanilla HTML + CSS + JS frontend (no framework) is served as static files, polling a composite `/api/state` endpoint every 5s and consuming one SSE stream for logs.

**Tech Stack:** Swift 6, Vapor 4, swift-testing, vanilla HTML/CSS/JS. macOS 26+, Apple silicon.

## Source Material

This spec refines `container-dashboard-prompt.v2.md`. Several schemas in that prompt diverged from the real `container` CLI v1.0.0; this spec's data models match the **verified** CLI output captured via live runs on 2026-07-07. Where this spec and the prompt conflict, this spec governs for data shapes.

---

## Verified CLI Surface (container v1.0.0)

All commands verified against the live CLI. Commands marked "JSON default" emit JSON without `--format json`; commands marked `--format json` require it.

| Purpose | Command | Shape |
| --- | --- | --- |
| Container list | `container ls --format json --all` | Array; each item `{id, configuration, status}` |
| Container stats | `container stats --format json --no-stream` | Array of flat stats objects |
| Container inspect | `container inspect <id>` | JSON default (NO `--format`); same `configuration` object as `ls` |
| System health | `container system status --format json` | Object `{status:"running"\|"stopped", ...}` |
| System version | `container system version --format json` | Array, up to 2 component objects |
| Disk usage | `container system df --format json` | **Object** `{containers, images, volumes}` |
| Builder status | `container builder status --format json` | Array; `[]` when never started |
| Builder start/stop | `container builder start` / `container builder stop` | Action (no JSON) |
| Machine list | `container machine ls --format json` | Array |
| Machine inspect | `container machine inspect <id>` | JSON default |
| Image list | `container image list --format json` | Array, nested `variants[]` |
| Image inspect | `container image inspect <name>` | JSON default; array |
| Network list | `container network list --format json` | Array |
| Logs (stream) | `container logs -f <id>` | Plain text lines (follow) |
| System properties | `container system property list --format json` | Object |
| DNS domains | `container system dns list --format json` | Array |
| Lifecycle | `container stop/start/kill <id>` | Action (take ID args) |
| Prune | `container prune` / `container image prune -a` / `container volume prune` | Action |

---

## Corrected Data Model

### `container ls --format json --all`

The prompt's example showed `status` as a string (`"status": "running"`). The real output makes `status` an **object** with a nested `state` field. Network IPs live at `status.networks[].ipv4Address`, not `networks[].address`.

```swift
struct ContainerList: Codable {
    let id: String
    let configuration: Configuration
    let status: Status

    struct Configuration: Codable {
        let image: Image
        let resources: Resources
        let publishedPorts: [PublishedPort]?
        let mounts: [Mount]?
        let platform: Platform
        let hostname: String?
    }
    struct Status: Codable {
        let state: String            // "running", "stopped", ...
        let networks: [NetStatus]?
        let startedDate: String?
    }
    struct Image: Codable {
        let descriptor: Descriptor
        struct Descriptor: Codable { let reference: String; let digest: String; let size: Int64 }
    }
    struct Resources: Codable { let cpus: Int; let memoryInBytes: Int64; let cpuOverhead: Int? }
    struct PublishedPort: Codable {
        let hostPort: Int; let containerPort: Int
        let hostAddress: String; let proto: String
    }
    struct Mount: Codable { let source: String; let destination: String; let type: MountType }
    struct Platform: Codable { let architecture: String; let os: String }
    struct NetStatus: Codable {
        let network: String; let ipv4Address: String?; let ipv6Address: String?
        let macAddress: String?; let hostname: String?
    }
    // Real JSON is a single-key object: {"virtiofs":{}} or {"bind":{...}}.
    // Decode the key as the type tag; ignore the associated value (only displayed).
    struct MountType: Codable {
        let virtiofs: [String: String]?
        let bind: [String: String]?
        var kind: String { virtiofs != nil ? "virtiofs" : (bind != nil ? "bind" : "unknown") }
    }
}
```

### `container stats --format json --no-stream`

Flat camelCase fields (NOT Docker-style nested). Matches the prompt.

```swift
struct ContainerStats: Codable {
    let id: String
    let memoryUsageBytes: Int64
    let memoryLimitBytes: Int64
    let cpuUsageUsec: Int64       // cumulative microseconds, NOT a percentage
    let networkRxBytes: Int64
    let networkTxBytes: Int64
    let blockReadBytes: Int64
    let blockWriteBytes: Int64
    let numProcesses: Int
}
```

### `container system df --format json` (resolves prompt OQ #3)

An **object** with three categories, each holding `{active, reclaimable, sizeInBytes, total}`:

```swift
struct SystemDF: Codable {
    let containers: Category
    let images: Category
    let volumes: Category
    struct Category: Codable { let active: Int; let reclaimable: Int64; let sizeInBytes: Int64; let total: Int }
}
```

### `container system status --format json`

```swift
struct SystemStatus: Codable { let status: String }  // "running" | "stopped"
```

### `container system version --format json`

Array of up to 2 component rows (CLI always present; API server row only if reachable):

```swift
struct VersionComponent: Codable {
    let appName: String    // "container" | "container-apiserver"
    let version: String
    let buildType: String  // "release" | "debug"
    let commit: String
}
```

### `container builder status --format json`

**Known limitation:** when the builder has never been started, this returns `[]`. The running-shape was not captured (would require starting a builder, a side-effecting action). The struct is modeled defensively; if the live running-shape diverges, decoding fails gracefully and the Builder panel renders "status unavailable" rather than crashing the composite poll.

```swift
// Decoded as [BuilderStatus]?; nil/empty => builder not started
struct BuilderStatus: Codable {
    // Best-effort fields; decode leniently (unknownKeys ignore)
    let state: String?
    let cpus: Int?
    let memoryInBytes: Int64?
    let containerID: String?
}
```

Decode strategy: `JSONDecoder().keyDecodingStrategy` left default; structs use optionals + a lenient configuration so unknown shapes don't throw.

### `container image list --format json`

Array; each item `{configuration, id, variants[]}`. The Images panel uses `configuration.name` (the `name:tag` reference), `configuration.creationDate`, and the **arm64 variant** for OS/arch badge + size (fall back to first variant if no arm64).

```swift
struct ImageList: Codable {
    let id: String
    let configuration: Configuration
    let variants: [Variant]
    struct Configuration: Codable {
        let name: String              // "docker.io/library/hello-world:latest"
        let creationDate: String
        let descriptor: Descriptor
        struct Descriptor: Codable { let digest: String; let size: Int64 }
    }
    struct Variant: Codable {
        let digest: String
        let size: Int64
        let platform: Platform
        struct Platform: Codable { let architecture: String; let os: String; let variant: String? }
    }
}
```

`container image inspect <name>` returns `[ImageList]` — the **same shape** as an `image list` item (verified). The image-detail endpoint reuses `ImageList`.

### `container network list --format json`

Array; each item `{configuration, id, status}`. The Resource Overview counts networks; the panel may show name + gateway.

```swift
struct NetworkList: Codable {
    let id: String
    let configuration: Configuration
    let status: Status
    struct Configuration: Codable { let name: String; let mode: String; let plugin: String; let creationDate: String }
    struct Status: Codable { let ipv4Gateway: String; let ipv4Subnet: String; let ipv6Subnet: String? }
}
```

### `container machine ls --format json` / `machine inspect` (unknown shape)

**Known limitation (same class as builder status):** the live system returned `[]` for both, so the machine object shape was not captured. `MachineList`/`MachineDetail` structs are defined during implementation against a real machine (create one with `container machine create alpine:3.22 --name dev` to capture). The Machines panel renders whatever fields decode; missing fields degrade gracefully. Do **not** block the build on this — the panel ships with config-only display and a "stats unavailable" note for live resources.

### `container inspect <id>` — reuses `ContainerList`

Verified: `container inspect <id>` returns `[ContainerList]` — the **same** `{configuration, id, status}` shape as `container ls` items. The inspect endpoint decodes into `[ContainerList]` directly. There is no separate `ContainerDetail` type.

---

## Module Structure

### Backend (`Sources/ContainerDashboard/`)

```
app.swift                     @main; boots Vapor on 127.0.0.1:8080; loopback guard
configure.swift               route registration + middleware
CLI/
  CommandRunner.swift         protocol + ProcessCommandRunner (generic over binary)
  ContainerCLI.swift          typed wrappers: ls, stats, status, version, df,
                              builderStatus, machines, machineInspect, images,
                              imageInspect, networks, inspect, systemProperties,
                              dnsDomains, macosVersion, prune(category)
  StatsTracker.swift          actor: prev snapshot per id + CPU% computation
  ResultCache.swift           TTL cache (~1s) keyed by (binary, args) for dedup
Models/
  ContainerModels.swift       ContainerList, ContainerStats (inspect reuses ContainerList)
  SystemModels.swift          SystemStatus, VersionComponent, SystemDF, BuilderStatus
  ImageModels.swift           ImageList (image inspect reuses ImageList)
  MachineModels.swift         MachineList, MachineDetail (shape captured during impl)
  NetworkModels.swift         NetworkList
Service/
  StateService.swift          composes /api/state via async let; merges stats+CPU%;
                              per-section do/catch => warnings[]
Controllers/
  StateController.swift       GET /api/state
  ContainerController.swift   inspect + SSE logs + stop/start/kill
  ImageController.swift       GET /api/images/inspect?name=
  MachineController.swift     GET /api/machines/:id (lazy inspect, best-effort)
  SystemController.swift      GET /api/system/properties + /api/system/dns (lazy)
  BuilderController.swift     builder start/stop
  PruneController.swift       POST /api/prune/:category (category whitelisted)
Support/
  IDValidator.swift           ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ + loopback assertion
  SSE.swift                   stream `container logs -f` lines; kill child on disconnect
```

**SSE disconnect handling (known-hard part):** `Response.Body(stream:)` gives a writer whose continuation is cancelled when the client closes the connection. The SSE handler must wrap the `container logs -f` process in a `withTaskCancellationHandler` (or poll `Task.isCancelled`) and call `process.terminate()` on cancellation, otherwise orphaned `container logs -f` processes accumulate per closed tab/expanded-row. The `stream()` method on `CommandRunner` returns an `AsyncThrowingStream` whose termination feeds this cleanup.

### Frontend (`Resources/Public/`)

```
index.html                    shell: header, six-panel grid, footer
styles.css                    design tokens + components (dark theme)
api.js                        fetchState(), postAction(), SSE subscription
render.js                     render functions per panel + sparkline SVG
app.js                        polling loop, Page Visibility, debounce, modal/expand wiring
```

### Tests (`Tests/ContainerDashboardTests/`)

```
StatsTrackerTests.swift       CPU% math: first sample=0%, delta, multi-core >100%
ModelDecodingTests.swift      decode captured Fixtures/*.json through JSONDecoder
IDValidatorTests.swift        valid/invalid/reject-shell-injection cases
StateServiceTests.swift       composition + warnings[] with a fake CommandRunner
Fixtures/                     captured real CLI JSON: ls, stats, df, version, images, networks
```

---

## Key Interfaces

### CommandRunner (protocol)

Generic over binary so it runs both `container` and `sw_vers`. Two modes: one-shot (Data) and streaming (for logs/SSE).

```swift
protocol CommandRunner: Sendable {
    func run(binary: String, args: [String], timeout: Duration) async throws -> Data
    func stream(binary: String, args: [String]) -> AsyncThrowingStream<String, Error>
}
```

`ProcessCommandRunner` implements this with `Process.run` (argument arrays, no shell). `run` enforces the timeout and throws `CLIError.timedOut` on expiry. Tests inject a `FakeCommandRunner` returning fixture bytes.

### StatsTracker (actor)

Holds the previous `cpuUsageUsec` and wall-time per container id. Computes CPU% on each update:

```
cpuPercent = (cpuUsageUsec_now - cpuUsageUsec_prev) / (wallUsec_now - wallUsec_prev) * 100
```

(`wallTimeMs * 1000 = wallUsec`.) First sample after start has no baseline => 0%. A 4-CPU container at saturation reports ~400%. The backend supplies both timestamps (the CLI emits no timestamp).

```swift
actor StatsTracker {
    func update(_ raw: [ContainerStats], at wall: Date) -> [StatsWithCPU]
}
struct StatsWithCPU { let stats: ContainerStats; let cpuPercent: Double }
```

The `wall` timestamp is captured by the caller at the moment the stats fetch completes (the CLI emits no timestamp). The actor also prunes snapshot entries for ids absent from the current sample, so container churn does not accumulate stale memory.

### StateService

Composes the composite `/api/state` payload. Every section is optional; each `async let` fan-out is wrapped in do/catch - on failure the section becomes `null` and a warning is appended.

```swift
struct DashboardState: Content {
    var health: SystemStatus?
    var containers: [ContainerList]?
    var stats: [StatsWithCPU]?
    var machines: [MachineList]?
    var images: [ImageList]?
    var networks: [NetworkList]?
    var diskUsage: SystemDF?
    var builder: [BuilderStatus]?
    var version: [VersionComponent]?
    var macosVersion: String?
    var warnings: [Warning]
}
struct Warning { let section: String; let message: String }
```

### IDValidator

Container/machine IDs are simple identifiers validated against a strict regex:

```swift
enum IDValidator {
    static let pattern = #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#
    static func validate(_ id: String) -> Bool   // false => route returns 400
}
```

Applied to every `:id` path parameter before it reaches `Process`.

### ImageRefValidator

OCI image references are NOT simple identifiers — they legitimately contain `/` (registry/namespace) and `:` (tag/digest separator), e.g. `docker.io/library/hello-world:latest`. The ID regex must not be applied to them. Because `/` also conflicts with Vapor path routing, image inspect takes the reference as a **query param** (`?name=<ref>`) and validates it separately. Since `CommandRunner` uses argument arrays (never a shell string), the threat model is path-injection and control-char injection, not shell injection:

```swift
enum ImageRefValidator {
    // Allow alphanumerics and the OCI structural chars: / : . _ - @
    // Reject whitespace, control chars, and all shell/path metacharacters.
    static let pattern = #"^[A-Za-z0-9][A-Za-z0-9/:._@-]{0,255}$"#
    static func validate(_ ref: String) -> Bool   // false => 400
}
```

Any `:` or `/` in the matched string is structural to the OCI ref and passed as a single argv element to `container image inspect`.

---

## API Surface

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `GET /` | GET | Serves `index.html` + static assets |
| `GET /api/state` | GET | Composite payload (fan-out, with `warnings[]`) |
| `GET /api/containers/:id` | GET | `container inspect <id>` (refresh/fallback) |
| `GET /api/images/inspect?name=<ref>` | GET | `container image inspect <ref>` (query param; OCI refs contain `:` and `/`) |
| `GET /api/machines/:id` | GET | `container machine inspect <id>` (lazy; best-effort decode) |
| `GET /api/system/properties` | GET | `container system property list --format json` (lazy, footer Advanced disclosure) |
| `GET /api/system/dns` | GET | `container system dns list --format json` (lazy, footer Advanced disclosure) |
| `GET /api/containers/:id/logs` | GET | SSE stream proxying `container logs -f <id>` |
| `POST /api/containers/:id/stop` | POST | `container stop <id>` |
| `POST /api/containers/:id/start` | POST | `container start <id>` |
| `POST /api/containers/:id/kill` | POST | `container kill <id>` |
| `POST /api/builder/start` | POST | `container builder start` |
| `POST /api/builder/stop` | POST | `container builder stop` |
| `POST /api/prune/:category` | POST | Prune; `category` in `{containers, images, volumes}` maps to `container prune` / `container image prune -a` / `container volume prune` |

**Validation:**
- `:id` params validated by `IDValidator` (`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`); 400 on mismatch.
- `:category` whitelisted to `{containers, images, volumes}`; 400 otherwise.
- `images/inspect?name=` is validated by a separate `ImageRefValidator` (see IDValidator section) — OCI refs legitimately contain `:` and `/`, which the ID regex must NOT reject.
- `sw_vers` and other non-`container` binaries are invoked directly by the generic `CommandRunner`; no user input reaches them.

Server-side timeout per CLI call: 3s; on timeout the section is omitted and a warning added.

---

## CPU% Computation

`container stats` reports `cpuUsageUsec` - cumulative CPU microseconds since container start, not a percentage and not per-core normalized. The `StatsTracker` actor keeps the previous snapshot per container and computes:

```
cpuPercent = (cpuUsageUsec_now - cpuUsageUsec_prev) / (wallUsec_now - wallUsec_prev) * 100
```

First sample after startup shows 0% (no baseline). A container with 4 CPUs fully saturated reports ~400% (matches the CLI's own `container stats` table).

**Sparkline aggregation:** `aggregated CPU% = sum over running containers of (cpuUsageUsec_delta_i / wallUsec_delta * 100)`. Do NOT divide by allocated CPUs. Memory aggregate = `sum(memoryUsageBytes)`. The formula is shown in a tooltip on the Resource Overview.

---

## UI Layout

### Header

- Title "Container . Monitor" with inline cube/VM SVG
- Status badge: green dot + "System Running" or red dot + "System Stopped" (from `system status`)
- Last-refresh timestamp, manual refresh button, auto-refresh toggle + interval input (default 5s)
- Pulsing dot when polling is active

### Six-Panel Grid

1. **Containers** (top-left, largest): table with Name, Image, Status pill (running=green, stopped=gray, any other state=amber), IP (`status.networks[0].ipv4Address`), CPU%, Memory, Arch. Row expand => stats detail + ports + inline logs drawer (SSE). Per-row Stop/Start/Kill buttons (optimistic UI on 2xx). Only `running` was observed in live testing; the pill maps known states and defaults unknown states to amber.
2. **Resource Overview** (top-right): stat cards (Containers running/total, Memory allocated = sum `resources.memoryInBytes`, Networks count) + mini CPU/Memory sparkline (aggregated).
3. **Builder** (middle strip): builder status pill, CPUs, memory, container ID; Start/Stop buttons. Hidden when builder never started (`[]`).
4. **Disk Usage** (middle strip): images/containers/volumes rows (total vs active, size, reclaimable) + Prune button with confirm dialog.
5. **Images** (bottom-left): card grid (name:tag, OS/arch badge, size, created) + search filter + click-for-modal inspect + storage progress bar.
6. **Container Machines** (bottom-right): card list (name, state, distro, CPU/MEM allocation) + "Copy shell command" button (`container machine run -n <name>`) + Stop. Resource meter best-effort (likely "stats unavailable").

### Empty States

Each panel renders an actionable empty state when its data is empty: Containers ("No containers. Run `container run ...`"), Machines ("Try `container machine create alpine:3.22 --name dev`"), Images ("Pull an image with `container image pull ...`"), Disk Usage (hidden entirely), Builder (hidden when `[]`).

### Footer

CLI + API server version, macOS version (`sw_vers`), build type + commit, optional "Advanced" disclosure (system properties + DNS domains), GitHub link.

### Buildkit filtering

The buildkit builder container is filtered OUT of the Containers table (it also appears in `container ls`); it surfaces only via the Builder panel's `container builder status`.

**Identification rule:** the container whose `id` matches the builder's container ID reported by `container builder status` (when non-empty). If `builder status` returns `[]` or fails to decode, no filtering is applied. As a fallback (e.g. builder running but status shape unexpected), also filter any container whose `configuration.image.descriptor.reference` contains `container-builder-shim/builder`.

---

## Auto-Refresh

- Client polls `GET /api/state` every 5s (configurable via header input)
- Debounce: skip a tick if previous request is in-flight
- Pause when tab hidden (Page Visibility API)
- Pulsing dot in header while polling active
- Server-side timeout per CLI call: 3s; on timeout omit section + add to `warnings[]`

## Error Handling

- `container` CLI not installed => backend structured error; UI shows "Install container from apple/container" with link
- System stopped => UI shows "System Not Running" banner + last-known-good cached payload from `localStorage`
- Container deleted mid-view => absent from next poll, removed from table
- POST action fails => revert optimistic UI + surface CLI error inline

## Security

- Bind to `127.0.0.1` only; refuse external bind without `--allow-remote` flag
- Validate every `:id`/`:name` against `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` => 400 on mismatch
- Argument arrays only; never `sh -c`, never string interpolation into a command line
- No auth (acceptable only because loopback); documented assumption

## Visual Design

- Background `#0a0a0f`, surfaces `#14141f`, borders `#2a2a3a`
- Accents: blue `#0a84ff`, green `#30d158`, orange `#ff9f0a`, red `#ff453a`
- Typography: `system-ui, -apple-system, sans-serif`; `ui-monospace` for IDs/IPs/digests
- 12px card radius, 16px padding, subtle box-shadows
- Responsive: 2-col on `>=1440px`, single col on `<900px`

---

## Testing Strategy (TDD)

Test framework: **swift-testing** (`import Testing`, `@Test`, `#expect`). `Package.swift` uses swift-tools-version 6.0.

`CommandRunner` is a protocol; tests inject a `FakeCommandRunner` that returns canned bytes per `(binary, args)` key and records call counts. No real `container` process is spawned in the unit-test loop. Fixtures are captured real CLI output committed under `Tests/.../Fixtures/`.

### `StatsTrackerTests` - CPU% math (the riskiest logic)

The actor holds a previous `{cpuUsageUsec, wallTime}` per container id. `update(_ raw:, at wall:)` returns `[StatsWithCPU]`.

| # | Scenario | Input | Expected |
| --- | --- | --- | --- |
| S1 | First sample, no baseline | sample A at t=0 | CPU% = 0.0 for all |
| S2 | Delta over 1s, single core 50% | A: cpu=1.0e6 @0s; B: cpu=1.5e6 @1s | 50.0% |
| S3 | 4 cores saturated | A: cpu=0 @0s; B: cpu=4.0e6 @1s | ~400.0% |
| S4 | Container removed between samples | A in sample1, absent in sample2 | no crash; pruned from tracker |
| S5 | New container appears at sample2 | only A sample1; A+B sample2 | B reports 0.0% (first sample) |
| S6 | Zero wall-time delta (same instant) | two updates at identical `Date` | 0.0%, no divide-by-zero |
| S7 | Multi-container independence | A busy, B idle | A and B get separate % from own baseline |
| S8 | CPU% never negative | cpuUsec unchanged or regression-safe | clamped >= 0.0 |
| S9 | Aggregated sparkline value | two containers | sum of per-container CPU% |

### `ModelDecodingTests` - real fixture round-trips

Each test loads `Fixtures/<name>.json` and decodes through `JSONDecoder`, then asserts specific fields (not just "didn't throw").

| # | Fixture | Key assertions |
| --- | --- | --- |
| D1 | `ls.json` | `.status.state == "running"`; `.status.networks[0].ipv4Address` set; `.configuration.resources.cpus`/`.memoryInBytes`; `.configuration.image.descriptor.reference`; `.configuration.platform.architecture == "arm64"` |
| D2 | `stats.json` | flat fields: `cpuUsageUsec`, `memoryUsageBytes`, `memoryLimitBytes`, `networkRxBytes`, `blockReadBytes`, `numProcesses` |
| D3 | `system_df.json` | object with `.containers`/`.images`/`.volumes`; each has `active`, `reclaimable`, `sizeInBytes`, `total` |
| D4 | `version.json` | array length 2; `[0].appName == "container"`; `[1].appName == "container-apiserver"` |
| D5 | `system_status.json` | `.status == "running"` |
| D6 | `image_list.json` | `[0].configuration.name` set; `variants[0].platform.architecture`; `variants[*].size` summable |
| D7 | `network_list.json` | `.configuration.name == "default"`; `.status.ipv4Gateway` set |
| D8 | `builder_status_empty.json` (`[]`) | decodes to empty array, no throw |
| D9 | `machine_ls_empty.json` (`[]`) | decodes to empty array, no throw |
| D10 | forward-compat | add unknown top-level key to `ls.json` | decodes without throwing (lenient) |
| D11 | optional absence | container with no `networks`/`publishedPorts` | those fields nil, no throw |
| D12 | mount type | `{"virtiofs":{}}` | `.type.kind == "virtiofs"` |

### `IDValidatorTests` + `ImageRefValidatorTests`

| # | Input | Validator | Expected |
| --- | --- | --- | --- |
| V1 | `"hermes"` | ID | true |
| V2 | `"my-container.1_test-2"` (allowed punctuation) | ID | true |
| V3 | 64-char id | ID | true |
| V4 | 65-char id | ID | false (overlength) |
| V5 | `""` / `"-foo"` / `".foo"` | ID | false (empty / non-alnum lead) |
| V6 | `"foo;rm -rf /"` / `"foo$(x)"` / `"foo\|cat"` | ID | false (shell metachars) |
| V7 | `"foo bar"` / `"foo\nbar"` | ID | false (whitespace/control) |
| V8 | `"foo/bar"` / `"foo:tag"` | ID | false (these belong to image refs) |
| V9 | `"hello-world:latest"` | ImageRef | true |
| V10 | `"docker.io/library/hello-world:latest"` | ImageRef | true |
| V11 | `"hello-world@sha256:abc123"` | ImageRef | true |
| V12 | `"docker.io/library/hello-world@sha256:abc"` | ImageRef | true |
| V13 | `"hello world"` / `"foo;rm"` / `` "`x`" `` / leading `/` | ImageRef | false |

### `StateServiceTests` - composition + resilience

`FakeCommandRunner` is seeded per-test to return fixtures (or throw). `StateService.state(runner:, tracker:)` returns `DashboardState`.

| # | Scenario | Expected |
| --- | --- | --- |
| C1 | all runners return fixtures | every section non-nil; `warnings` empty |
| C2 | `stats` runner throws `CLIError.timedOut` | `stats == nil`; `warnings` has `{section:"stats", ...}`; other sections intact |
| C3 | `builder status` returns `[]` bytes | `builder == []` (NOT nil, NOT a warning) |
| C4 | stats raw merged via StatsTracker | `stats: [StatsWithCPU]` with cpuPercent populated (0% on first call) |
| C5 | `sw_vers` returns "15.2.0\n" | `macosVersion == "15.2.0"` (trimmed) |
| C6 | one section failing does NOT fail the response | response still 200 with partial data + warnings |

### `ResultCacheTests` - dedup

| # | Scenario | Expected |
| --- | --- | --- |
| R1 | same `(binary, args)` twice within TTL | FakeRunner called once; second returns cached |
| R2 | same key after TTL expires | FakeRunner called twice |
| R3 | different args | both called (no false cache hit) |
| R4 | `container` vs `sw_vers` same args | both called (binary is part of key) |
| R5 | `stream()` calls are NOT cached | logs stream every time |

### `BuildkitFilterTests` (part of StateServiceTests)

| # | Scenario | Expected |
| --- | --- | --- |
| B1 | builder status returns containerID "xyz"; ls has "xyz" | "xyz" removed from containers list |
| B2 | builder status `[]` | no container filtered |
| B3 | builder status decode fails | no filtering; warning added; containers unchanged |

### Out of scope

- Live `container` process integration tests (the parsing layer is what breaks; fixtures cover it).
- Vapor HTTP-layer tests (route wiring is thin; verified by running the server).
- Frontend tests (vanilla JS; manual verification).

Integration tests against the live CLI are out of scope for the TDD loop; the parsing layer is what breaks and that is fully covered by fixtures.

---

## Known Limitations

1. **`builder status` running-shape** not captured (would require starting a builder). Decoded defensively; panel degrades to "status unavailable" if the shape diverges.
2. **Machine live stats** (`container machine inspect` may not expose CPU/memory). Resource meter shows "stats unavailable" tooltip; never inferred from host-side `container stats` (machines aren't listed there).
3. **No per-container uptime / open-fd count** - the CLI exposes neither. Omitted.
4. **`container inspect` JSON is default** (no `--format json`); the inspect endpoint calls it without the flag. `/api/state` already carries full configuration via `ls`, so inspect is a refresh/fallback, not the primary path.
5. **`GET /api/system/logs` SSE endpoint deferred (YAGNI).** The prompt offered an optional system-log drawer proxying `container system logs -f`. It is intentionally NOT built in v1 — the per-container log drawer covers the primary need. Can be added later by mirroring the container-logs SSE path.
6. **Machine-list/machine-inspect shape unknown** - both returned `[]` on the live system. `MachineList`/`MachineDetail` are captured during implementation against a real machine (`container machine create alpine:3.22 --name dev`). The lazy `GET /api/machines/:id` and the panel both decode defensively; missing fields degrade gracefully.

---

## Deliverable

A single directory containing:
1. `Package.swift`, `Sources/`, `Resources/Public/`, `Tests/`
2. `README.md` (prerequisites: macOS 26+, Apple silicon, `container` installed + `container system start` run; build: `swift build -c release`; run: `swift run` or `.build/release/ContainerDashboard`; open http://127.0.0.1:8080; Vapor dependency)
3. `run.sh`: builds if needed, then runs (avoids double-run):
   ```sh
   swift run || { swift build && swift run; }
   ```

No Docker, no external databases. First build ~1-2 min; subsequent launches <5s. Assumes `container` installed and system service running.
