# Container Monitor Dashboard - Implementation Plan

**Spec:** [`docs/superpowers/specs/2026-07-07-container-dashboard-design.md`](../specs/2026-07-07-container-dashboard-design.md)
**Stack:** Swift 6, Vapor 4, swift-testing, vanilla HTML/CSS/JS.
**Target:** macOS 26+, Apple silicon, `container` v1.0.0, served at http://127.0.0.1:8080.

This plan is the **how and in what order**. The spec is the **what**; it is not repeated here. Every phase ends with a verifiable gate (a command, a green test filter, or a manual check). Phases are ordered so the riskiest logic lands earliest and the project compiles + tests green after every phase.

---

## Ordering Rationale (read first)

The build order is driven by **where breakage hides**, not by UI top-to-bottom:

1. **Parsing breaks before anything else.** The spec's verified fixtures are the ground truth; every CLI shape was captured live. Decode them first against typed `Codable` structs. If a struct is wrong, nothing downstream matters.
2. **CPU% math is the single riskiest pure logic.** Cumulative `cpuUsageUsec` over wall-time delta, with pruning, first-sample-zero, and divide-by-zero guards. TDD it in isolation before it touches the network.
3. **The SSE logs stream is the only known-hard runtime piece** (orphaned `container logs -f` processes on disconnect). It is isolated to one phase with an explicit orphan-check gate.
4. **Builder running-shape and Machine shape are unverified** (both `[]` on the capture system). They ship defensive with a capture-during-impl step, so they never block the build.

Tests inject a `FakeCommandRunner` returning fixture bytes; no real `container` runs in the test loop.

---

## Phase 0 - Scaffold

**Build**
- `Package.swift`: `swift-tools-version: 6.0`; target `ContainerDashboard` (executable) depending on `Vapor` pinned `from: "4.114.0"` (Phase 8's SSE disconnect contract needs recent NIO channel-inactive propagation; older Vapor may not cancel the stream task on client disconnect); test target `ContainerDashboardTests` depending on `ContainerDashboard` + `swift-testing`.
- `Sources/ContainerDashboard/app.swift`: `@main` entry, calls `configure(_:)`, runs Vapor bound to `127.0.0.1`, port `8080`.
- `Sources/ContainerDashboard/configure.swift`: empty `func configure(_ app: Application) throws {}` for now.

**Verify**
- `swift build` exits 0.
- `swift run` boots and serves a 404 at http://127.0.0.1:8080 (no routes yet). Kill it.

**Notes**
- Commit `Package.resolved` (this is an application, not a library) - the `.gitignore` already states this.
- **Swift 6 Sendability:** `Foundation.Process` is not `Sendable`. `ProcessCommandRunner: Sendable` must construct each `Process` *inside* the async call (local capture only), never as stored state on the runner. If the compiler still complains, scope the `Process` to a `nonisolated` helper that returns collected output. Decide the isolation strategy in Phase 2, not at code review.

---

## Phase 1 - Fixtures + Models (parsing layer)

This is the layer most likely to break. Capture once, decode forever.

**Build**
1. **Capture fixtures** from the live system into `Tests/ContainerDashboardTests/Fixtures/`. One file per CLI shape:
   - `ls.json`, `stats.json`, `system_df.json`, `version.json`, `system_status.json`, `image_list.json`, `network_list.json`, `builder_status_empty.json` (`[]`), `machine_ls_empty.json` (`[]`).
   - Capture with: `container ls --format json --all > ls.json`, etc. (see spec "Verified CLI Surface" for which need `--format json` vs JSON-default).
   - `inspect <id>` and `image inspect <name>` reuse `ls`/`image_list` shapes - no new fixtures needed.
2. **Model structs** under `Sources/ContainerDashboard/Models/` per spec "Corrected Data Model":
   - `ContainerModels.swift` - `ContainerList` (with nested `Status.state`, `NetStatus.ipv4Address`, `MountType` kind-tagged decode).
   - `SystemModels.swift` - `SystemStatus`, `VersionComponent`, `SystemDF` (object, not array), `BuilderStatus` (defensive optionals).
   - `ImageModels.swift` - `ImageList`.
   - `NetworkModels.swift` - `NetworkList`.
   - `MachineModels.swift` - placeholder `MachineList`/`MachineDetail` (see Phase 11 capture step).
3. **Lenient decoding**: structs use optionals generously; a shared `JSONDecoder` config ignores unknown keys by default. Do not set `keyDecodingStrategy`.

**TDD gate - `ModelDecodingTests`** (spec rows D1-D12)
- Write the tests first against the fixtures + assertions in the spec table.
- Run: `swift test --filter ModelDecoding`. All D1-D12 green.

**Verify**
- `swift test --filter ModelDecoding` green.
- D10 (unknown top-level key) and D11 (optional absence) pass - confirms forward-compat.

---

## Phase 2 - CommandRunner + Validators

**Build**
1. `Sources/ContainerDashboard/CLI/CommandRunner.swift`:
   - `protocol CommandRunner: Sendable` with `run(binary:args:timeout:) async throws -> Data` and `stream(binary:args:) -> AsyncThrowingStream<String, Error>`.
   - `enum CLIError: Error { case timedOut, nonZeroExit(Int), missing }`.
   - `ProcessCommandRunner`: `Process.run` with **argument arrays** (never a shell string). `run` enforces the timeout via a `Task` + `process.terminate()` race.
2. `Tests/.../FakeCommandRunner.swift`: returns canned bytes keyed by `(binary, args)`; records call counts; supports per-key throw + a `streamedLines` table for the SSE test.
3. `Sources/ContainerDashboard/Support/IDValidator.swift` - `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`.
4. `Sources/ContainerDashboard/Support/ImageRefValidator.swift` - `^[A-Za-z0-9][A-Za-z0-9/:._@-]{0,255}$` (OCI refs legitimately contain `:` `/` `@`).

**TDD gates**
- `IDValidatorTests` + `ImageRefValidatorTests` (spec V1-V13). `swift test --filter Validator` green.
- Smoke test: `ProcessCommandRunner.run(binary: "sw_vers", args: ["-productVersion"])` returns non-empty `Data` (proves the runner shells out correctly). A single happy-path test is enough; this is the one place a real process is invoked in tests.

**Verify**
- `swift test --filter Validator` green; sw_vers smoke test green.

---

## Phase 3 - StatsTracker (riskiest pure logic)

**Build**
- `Sources/ContainerDashboard/CLI/StatsTracker.swift`:
  - `actor StatsTracker { func update(_ raw: [ContainerStats], at wall: Date) -> [StatsWithCPU] }`.
  - Per-id previous `{cpuUsageUsec, wallUsec}` map.
  - Compute `cpuPercent = (cpu_now - cpu_prev) / (wallUsec_now - wallUsec_prev) * 100`.
  - First sample (no baseline) => `0.0`. Zero wall delta => `0.0` (no divide-by-zero). Clamp negative => `0.0` (clock non-monotonic).
  - Prune ids absent from the current sample (churn hygiene).

**TDD gate - `StatsTrackerTests`** (spec S1-S9)
- Write all nine scenarios first. Run: `swift test --filter StatsTracker`. Green.

**Verify**
- S1 (first sample 0%), S3 (4-core ~400%), S6 (zero delta, no crash), S8 (never negative) all pass.

---

## Phase 4 - ResultCache

**Build**
- `Sources/ContainerDashboard/CLI/ResultCache.swift`:
  - `actor ResultCache: CommandRunner` (decorator) wrapping an inner `CommandRunner`. The cache IS the runner the rest of the app talks to, so Phase 6's `StateService` gets dedupe for free without a special signature. Same `run(binary:args:timeout:)` signature; returns cached within TTL, else delegates and stores.
  - `stream(binary:args:)` passes straight through to the inner runner uncached (spec R5) - streaming calls bypass the cache entirely.
  - Wiring: `ProcessCommandRunner` is the innermost runner; `ResultCache` wraps it; `StateService`/`ContainerCLI` take `some CommandRunner` and receive the cache. This resolves the "Phase 4 builds a cache Phase 6 never uses" gap.

**TDD gate - `ResultCacheTests`** (spec R1-R5) with `FakeCommandRunner`.
- `swift test --filter ResultCache` green.

**Verify**
- R1 (dedup within TTL), R2 (refetch after TTL), R5 (stream never cached) pass.

---

## Phase 5 - ContainerCLI typed wrappers

**Build**
- `Sources/ContainerDashboard/CLI/ContainerCLI.swift`: thin async functions, each `(runner: some CommandRunner) async throws -> T`. Pure plumbing over `CommandRunner.run` + `JSONDecoder`. No business logic.
  - `ls`, `stats`, `inspect(id:)`, `systemStatus`, `version`, `systemDF`, `builderStatus`, `machines`, `machineInspect(id:)`, `images`, `imageInspect(ref:)`, `networks`, `systemProperties`, `dnsDomains`, `macosVersion` (binary `sw_vers`, parse the one line).
  - `prune(category:)` - whitelist maps to `container prune` / `container image prune -a` / `container volume prune`.
  - `logsStream(id:)` - returns the `AsyncThrowingStream` from `runner.stream` (no decode; lines are plain text).

**TDD gate - `ContainerCLIArgsTests`**
- Assert `FakeCommandRunner.recordedArgs` for every wrapper, because argument-array construction is the security boundary and `StateServiceTests` only exercises the `/api/state` subset:
  - `inspect(id:)` => `["inspect", "<id>"]` (no `--format`; JSON default).
  - `imageInspect(ref:)` => `["image", "inspect", "<ref>"]` with the **entire ref as one argv element** (e.g. `docker.io/library/hello-world:latest` is a single arg, not split on `:`/`/`).
  - `prune(.containers)` / `.images` / `.volumes` => `["prune"]` / `["image","prune","-a"]` / `["volume","prune"]`; the category is a Swift enum, so `:category` cannot smuggle a different command.
  - `stop`/`start`/`kill` => `["stop"|"start"|"kill", "<id>"]`.
  - `builderStart`/`Stop` => `["builder","start"|"stop"]`.
  - `logsStream(id:)` => `["logs","-f","<id>"]` via `stream`, not `run`.
- Run: `swift test --filter ContainerCLIArgs`. Green.

**Verify**
- `swift test --filter ContainerCLIArgs` green (every wrapper produces the exact argv; single-element refs confirmed).
- `swift build` green.

---

## Phase 6 - StateService (composition + resilience)

**Build**
- `Sources/ContainerDashboard/Service/StateService.swift`:
  - `func state(runner: some CommandRunner, tracker: StatsTracker) async -> DashboardState`. `runner` is the `ResultCache`-decorated runner from Phase 4 - that is where ~1s dedupe lives; `StateService` itself is unaware of caching.
  - Fan out via `async let` (health, ls, stats, machines, images, networks, df, builder, version, sw_vers).
  - Each `async let` wrapped in its own `do/catch` -> on throw, section becomes `nil` and a `Warning` is appended. Timeout (Phase 2's `CLIError.timedOut`) lands here.
  - Stats merged via `tracker.update(raw, at: <wall captured when stats fetch resolved>)`.
  - **Buildkit filter**: if `builderStatus` resolves a `containerID`, drop the matching container from `containers` AND from `stats` (so the Resource Overview aggregate sparkline is not inflated by the builder's own CPU/memory). Fallback: drop any container whose `image.descriptor.reference` contains `container-builder-shim/builder`, applied to both lists. If `builderStatus` is `[]` or undecodable, no filter (spec B1-B3). Add a `StateServiceTests` row asserting the builder id is absent from both `containers` and `stats`.
- `DashboardState: Content` with all optional sections + `warnings: [Warning]` (spec "StateService").

**TDD gate - `StateServiceTests`** (spec C1-C6, B1-B3) with `FakeCommandRunner` + real `StatsTracker`.
- `swift test --filter StateService` green.

**Verify**
- C2 (one section times out => `nil` + warning, rest intact), C6 (partial response still 200-shaped) pass. These prove the resilience invariant: **one broken CLI section never blanks the whole dashboard**.

---

## Phase 7 - HTTP layer + loopback guard

**Build**
- Routes in `configure.swift`, controllers under `Sources/ContainerDashboard/Controllers/`:
  - `GET /` -> serve `index.html` + static from `Resources/Public/` via Vapor `FileMiddleware`, with the public directory resolved from the **executable path** (see Phase 12) so it works under both `swift run` and the release binary.
  - `GET /api/state` -> `StateController` calls `StateService`.
  - `GET /api/containers/:id` -> `inspect` (IDValidator, 400 on mismatch).
  - `GET /api/images/inspect?name=` -> `ImageController` (ImageRefValidator; **query param** because OCI refs contain `:`/`/`).
  - `GET /api/machines/:id` -> lazy best-effort `machineInspect` (defensive decode).
  - `GET /api/system/properties`, `GET /api/system/dns` -> lazy footer feeds.
  - `POST /api/containers/:id/{stop,start,kill}` -> run lifecycle command, 2xx on success, 500 + CLI stderr on failure.
  - `POST /api/builder/{start,stop}`.
  - `POST /api/prune/:category` -> `category` whitelisted `{containers, images, volumes}`; 400 otherwise.
- **LoopbackGuard** (`Sources/ContainerDashboard/Support/LoopbackGuard.swift`): **resolve** the configured hostname (`getaddrinfo`/`CFHost`) and require *every* resolved address to be loopback (`127.0.0.0/8` or `::1`). Do NOT string-match `"127.0.0.1"` - on macOS `localhost` resolves to both `127.0.0.1` and `::1`, and a literal match would reject a legitimate loopback bind. Wire into `app.swift` before `app.run`.
- **`--allow-remote` semantics (defined exactly):** absent => bind must resolve to loopback only, else refuse to start (exit non-zero with a message). Present without a value => bind `0.0.0.0`/`::` allowed. Present with `--allow-remote <host>` => bind that host verbatim. In every remote case, print a loud warning that no auth is enabled.
- **DNS-rebinding / write-defense middleware:** loopback binding alone does not stop a hostile webpage (its DNS can resolve to `127.0.0.1`, then attacker JS POSTs `/api/containers/<id>/kill`). Reject every state-changing request (`POST`/`DELETE`) whose `Origin` header is absent or not exactly `http://127.0.0.1:8080` (also accept `http://localhost:8080`); return 403. As a second layer, reject writes whose `Sec-Fetch-Site` is `cross-site`. This is the CSRF/rebinding fix the spec's "no auth because loopback" assumption actually requires.

**TDD gate - `ControllerSecurityTests`** (Vapor `app.test(.GET/.POST, ...)`, in-process, no port)
- Bad `:id` (`foo;rm -rf /`, empty, 65 chars, leading `-`) on every `:id` route => 400.
- Bad `:category` (`bogus`) => 400; good category passes through to `prune`.
- Image-ref validator: `?name=hello world` / `?name=` / `?name=;rm` => 400.
- POST with cross-origin / absent `Origin` => 403; `Origin: http://127.0.0.1:8080` => passes.
- LoopbackGuard: `configure(hostname: "0.0.0.0")` without `--allow-remote` => fatal; with flag => allowed.
- Run: `swift test --filter ControllerSecurity`. Green.

**Verify (manual, live)**
- `swift build && swift run`.
- `curl -s http://127.0.0.1:8080/api/state | jq .warnings` is `[]` on a healthy system; sections populated.
- `curl -s 'http://127.0.0.1:8080/api/images/inspect?name=hello-world:latest' | jq` returns decoded shape.
- `curl -i -X POST http://127.0.0.1:8080/api/prune/bogus` -> 400.
- `curl -i http://127.0.0.1:8080/api/containers/'foo;rm%20-rf%20/'/stop` -> 400 (regex rejects before reaching `Process`).
- `curl -i -H 'Origin: http://evil.com' -X POST http://127.0.0.1:8080/api/containers/<id>/stop` -> 403.

---

## Phase 8 - SSE logs stream (known-hard part)

**Build**
- `Sources/ContainerDashboard/Support/SSE.swift` + `ContainerController` logs route `GET /api/containers/:id/logs`:
  - `Response.Body(stream:)` writing `data: <line>\n\n` frames.
  - **Primary disconnect signal = `StreamWriter.write` failure.** When the client closes, NIO propagates channel-inactive as a throwing error from `write`; that is version-stable in Vapor 4 (unlike task-cancellation, which depends on the NIO version pinned in Phase 0). On a throwing `write`, stop reading and tear down the child process.
  - Wrap the `container logs -f <id>` process in `withTaskCancellationHandler` as the **secondary** signal; on disconnect the continuation cancellation fires in recent Vapor. Either signal triggers teardown.
  - **Teardown = `terminate()` (SIGTERM) -> `waitUntilExit()` with a 2s grace -> if still `running`, `SIGKILL`.** SIGTERM alone may leave a `container logs -f` child lingering; the orphan check below catches TZOMBIE/leaked cases.
  - IDValidator on `:id` before anything reaches `Process`.

**Verify (the orphan check - this is the whole point of the phase)**
1. Start server, run a container, open the logs stream in a browser row:
   `curl -N http://127.0.0.1:8080/api/containers/<id>/logs` (and the in-page drawer).
2. Kill the curl / close the tab.
3. `pgrep -fl 'container logs -f'` returns **nothing**. If it returns the `container logs` PID, the cancellation wiring is wrong - fix before moving on.
4. Repeat with multiple simultaneous streams; closing one must not kill the others.

---

## Phase 9 - Frontend shell

Static files under `Resources/Public/`. No framework, no build step.

**Build**
- `index.html` - semantic shell: `<header>`, `<main>` six-panel grid, `<footer>`. Panel containers with stable IDs the JS targets.
- `styles.css` - design tokens as custom properties (spec "Visual Design"): bg `#0a0a0f`, surfaces `#14141f`, borders `#2a2a3a`, accents blue/green/orange/red; `system-ui` + `ui-monospace`; 12px radius, 16px padding, responsive 2-col `>=1440px` / 1-col `<900px`. Status pill colors: running=green, stopped=gray, other=amber.
- `api.js` - `fetchState()`, `postAction(kind, id)`, `EventSource` wrapper for the logs stream.
- `render.js` - one render fn per panel + the aggregated CPU/Memory sparkline (inline SVG path from the last N samples). Buildkit filtering on the client is unnecessary - backend already strips it from both `containers` and `stats`. Wire every spec UI element: image-panel **storage progress bar**; machines-panel **"Copy shell command"** button (`container machine run -n <name>` via `navigator.clipboard`); disk-usage **Prune button + confirm dialog** (POST `/api/prune/:category`); builder inline **Start/Stop** buttons; footer **"Advanced" disclosure** toggling `/api/system/properties` + `/api/system/dns`.
- `app.js` - polling loop on `/api/state` (default 5s), **debounce** (skip tick if a request is in-flight), **Page Visibility** pause when hidden, pulsing-dot indicator while active, **manual refresh button + last-refresh timestamp** in the header, optimistic UI on stop/start/kill/builder/prune with revert + inline error on failure, last-known-good payload cached to `localStorage` for the "System Not Running" banner.

**Note (expected degraded state until Phase 11):** on a system that actually has machines or a running builder, the Machines panel and Builder panel may render incomplete/empty between Phase 9 and the Phase 11 shape-capture. That is expected, not a bug - `MachineList`/`BuilderStatus` decode defensively and surface whatever fields they have.

**Verify (manual, against a live `container` system)**
- Dashboard loads with status badge green; Containers table populates; CPU% climbs from 0 on first poll then tracks.
- Expand a row: stats + ports + inline logs drawer stream live.
- Stop/Start/Kill buttons flip the pill optimistically and hold on success, revert on failure.
- Tab hidden -> polling pauses (DevTools network quiet); visible -> resumes.
- Throttle interval input changes the poll cadence live.
- "System Not Running" banner appears if `container system stop` is run; last-known-good renders from `localStorage`.

---

## Phase 10 - Polish + edge states

**Build**
- Empty states per panel (spec "Empty States"): Containers, Machines, Images actionable hints; Disk Usage and Builder hidden when empty.
- "container CLI not installed" structured error -> UI surfaces "Install container from apple/container" with link.
- Responsive pass at 320 / 768 / 1024 / 1440 / 1920 (no overflow, table collapses to cards on narrow).
- Keyboard: row expand + modal close on Esc; focus-visible on action buttons.

**Verify**
- With `container` uninstalled (or renamed on PATH): UI shows the install prompt, not a raw stack trace.
- `container system stop` then reload: banner + cached payload; `container system start` then wait one tick: banner clears.
- Delete a container mid-view: row disappears on the next poll, no console error.

---

## Phase 11 - Capture unknown shapes (builder running + machine)

Two shapes were `[]` on the capture system. They are not blockers; capture them opportunistically.

**Build**
- Start a builder (`container builder start`), then `container builder status --format json > Tests/.../Fixtures/builder_status_running.json`. Refine `BuilderStatus` if the running-shape diverges; keep optionals so the empty-array case still decodes.
- Create a machine (`container machine create alpine:3.22 --name dev`), then capture `machine ls` and `machine inspect` JSON. Fill in `MachineList` / `MachineDetail` fields. If `machine inspect` exposes no live CPU/memory, the meter ships "stats unavailable" (spec Known Limitation #2) - do not fabricate.

**Verify**
- New fixture decodes without throwing (add a `ModelDecodingTests` row).
- Machines panel renders real data on a system with a machine; renders the empty hint on a system without.

**If a shape cannot be captured** (no machine available, builder won't start): leave the defensive struct as-is; the panel degrades gracefully. Document the gap in `README.md` rather than blocking.

---

## Phase 12 - Deliverable packaging

**Build**
- **Static-asset path resolution** (the release-mode trap): `app.directory.publicDirectory` is cwd-relative and breaks when the release binary is launched from another directory. Resolve `Resources/Public/` relative to the executable: look up the executable URL (`URL(fileURLWithPath: CommandLine.arguments[0])` resolved via `FileManager`, or `Bundle.main.bundlePath`), walk up to find `Resources/Public/`, and set `app.directory.publicDirectory` explicitly. Fall back to cwd-relative if not found (dev mode). Without this, the "fresh clone -> release build -> serve" gate serves a 404 for `/`.
- `README.md` (spec "Deliverable"): prerequisites (macOS 26+, Apple silicon, `container` installed, `container system start` run), build (`swift build -c release`), run (`.build/release/ContainerDashboard` or `swift run`), open http://127.0.0.1:8080, Vapor dependency, the loopback/no-auth assumption + DNS-rebinding defense, known limitations carried over.
- `run.sh`:
  ```sh
  swift run || { swift build && swift run; }
  ```
  `chmod +x run.sh`.

**Verify**
- Fresh clone -> `swift build -c release` -> `.build/release/ContainerDashboard` serves the dashboard.
- `./run.sh` works from a clean `.build/`.

---

## Definition of Done

- All test filters green: `swift test` (ModelDecoding D1-D12, StatsTracker S1-S9, Validator V1-V13, ResultCache R1-R5, ContainerCLIArgs, StateService C1-C6 + B1-B3, ControllerSecurity).
- `swift build -c release` clean.
- Dashboard serves at http://127.0.0.1:8080 against a live `container` system; all six panels render; actions work; logs stream with no orphans after disconnect.
- `pgrep -fl 'container logs -f'` clean after closing every logs drawer.
- No external bind possible without `--allow-remote`; every `:id`/`:name`/`:category` rejected pre-`Process` on mismatch; cross-origin/absent-`Origin` writes rejected (DNS-rebinding defense).
- `README.md` + `run.sh` present and accurate.

---

## Out of Scope (deferred per spec)

- `GET /api/system/logs` SSE system-log drawer (YAGNI for v1; the per-container drawer covers the primary need).
- Live-CLI integration tests in CI (fixtures cover the parsing layer that breaks).
- Frontend automated tests (vanilla JS; manual verification per Phase 9/10).
- Per-container uptime / open-fd count (CLI exposes neither).
