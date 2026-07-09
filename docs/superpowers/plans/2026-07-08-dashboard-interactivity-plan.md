# Dashboard Interactivity - Implementation Plan

**Spec:** [`docs/superpowers/specs/2026-07-07-container-dashboard-design.md`](../specs/2026-07-07-container-dashboard-design.md)
**Prior plan:** [`docs/superpowers/plans/2026-07-07-container-dashboard-plan.md`](./2026-07-07-container-dashboard-plan.md) (Phases 0-12, read-only dashboard; Phase 11 skipped, 12 launcher/docs).
**Stack:** Swift 6, Vapor 4, swift-testing, vanilla HTML/CSS/JS.
**Target:** macOS 26+, Apple silicon, `container` v1.0.0, served at http://127.0.0.1:8080 (loopback only).

This plan extends the shipped read-only dashboard with **mutating + interactive** capability: create/run containers, pull images, and open an interactive shell into a running container. Every phase ends with a verifiable gate. The project compiles + tests green after every phase, one conventional commit per phase.

**This revision incorporates the four-subagent review (architecture, security, Swift/Vapor, plan-quality).** Review findings that changed the design are cited inline as `(review: <id>)`. The load-bearing ones: the WebSocket upgrade bypassed the Origin guard (now a blocker), the exec "no lifetime cap" claim was wrong for dirty disconnects (now heartbeat-bounded), `image pull` would false-timeout on pipe buffer (now `/dev/null`), and side-effecting commands were being deduped by the result cache (now uncached).

---

## Ordering Rationale (read first)

1. **Cache-bypass lands first, inside Phase 13.** Every existing write (`stop`/`start`/`kill`/`prune`/`builderStart`/`builderStop`) already routes through the cache-decorated runner, so a double-click within ~1s returns cached success without spawning the command `(review: architect C1)`. The new `run`/`pull` would inherit this. Phase 13 adds an uncached path and retrofits the existing writes - this is a latent bug fix, not just new-feature plumbing.
2. **Run before Pull.** The host already has local images, so `container run` can be exercised end-to-end offline. Pull then extends the image pool. Pull also needs a non-pipe output sink (it emits enough progress to overflow a pipe buffer and would false-timeout via the existing `run()`) `(review: swift C3)` - handled by a `runDiscardingOutput` variant.
3. **Validation is the security surface, and it ships with Run.** Run is the first endpoint that accepts user-supplied, free-form fields as `Process` arguments. Validators are specified around **argv-element safety** (parsed-component re-serialization; reject NUL/newline; reject leading `-`), not "shell metachars" - there is no shell `(review: security L4)`.
4. **Exec is the riskiest runtime piece, so it lands last.** It needs a host PTY, a bidirectional bridge, and a WebSocket. Unlike the GET-SSE logs case, **clean** WebSocket close is reliably detected by NIO - but **dirty** disconnects (lid close, VPN drop, NAT idle) send no FIN and leak the child, so exec is **heartbeat-bounded**, not cap-free `(review: architect H2, swift H5)`. The Origin guard does **not** cover ws upgrades today (it only checks `POST`/`DELETE`), so Phase 15 enforces Origin/`Sec-Fetch-Site` in Vapor's `shouldUpgrade` as a **blocker gate** `(review: security C1, architect H1)`.
5. **Frontend terminal last.** xterm.js is vendored (no CDN), so the build stays offline. It depends on the backend ws being correct, so it ships after.

Tests inject a `FakeCommandRunner`; no real `container` runs in the unit-test loop. Integration coverage is the per-phase manual verify steps (the prior plan took the same stance).

---

## Verified CLI Surface (interactive, captured 2026-07-08)

| Purpose | Command | Notes |
| --- | --- | --- |
| Exec into running container | `container exec -i -t <id> <cmd...>` | `-t` allocates a guest TTY; needs a host PTY on our side. No post-start resize flag/API. |
| Create + start a container | `container run <image> [args...]` | Flags: `--name -p/--publish -e/--env -v/--volume -c/--cpus -m/--memory --rm --entrypoint --arch --os --cidfile`. `-d/--detach` to run without attaching. |
| Create without starting | `container create <image> [args...]` | Same flags minus the start. Deferred (see Open Decisions). |
| Pull an image | `container image pull <ref>` | Long-running; emits progress to stdout/stderr. `-a/--arch --os --platform`. |

`exec`/`run`/`pull` help text captured verbatim and filed alongside this plan.

---

## Security Model (extends the existing stance)

The shipped dashboard is loopback-only, validates every `:id`/`:name`/`:category`/image-ref at the HTTP boundary before any `Process`, uses argument arrays only (never a shell string), and guards writes with an Origin/`Sec-Fetch-Site` check. The interactive surface extends this; the deltas below are where reviewers found gaps.

- **WebSocket Origin guard (new, blocker).** `OriginGuardMiddleware.shouldBlock` short-circuits on anything that is not `POST`/`DELETE`, so a ws upgrade (`GET` + `Upgrade: websocket`) is **not** covered today `(review: security C1)`. Phase 15 enforces the check inside Vapor's `shouldUpgrade` closure (reject by completing the upgrade future with `nil`/403). The "cross-origin ws upgrade is rejected" gate is a **blocker**, not a verify-and-fallback. A pure `OriginGuard.shouldBlockWS(origin:secFetchSite:)` helper is unit-tested before the route is wired.
- **Writes bypass `ResultCache` (new).** Side-effecting commands must not be deduped. Phase 13 adds an uncached runner path and routes every write (`stop`/`start`/`kill`/`prune`/`builderStart`/`builderStop`/`run`/`pull`) through it `(review: architect C1)`.
- **`run` field validation (reframed).** Every field of `ContainerRunRequest` that reaches argv is a **validator-backed value type** - no plain `String` fields; a test reflects/asserts this invariant `(review: security M2)`. Validators target argv-element safety: parse into components, re-serialize canonically, reject NUL/newline and a leading `-` (so the value cannot be misparsed as a flag). Bound sizes: `args` <= 64 entries / 4 KB each; `env` <= 64 entries / 32 KB each `(review: security L5)`. Container **name** reuses `IDValidator.validate` directly - no new type `(review: planner M4)`. Image reuses `ImageRefValidator`.
- **Host-bind policy (new).** `container run -p` binds `0.0.0.0` by default (LAN-exposed). The dashboard rewrites a published port to **`127.0.0.1:<host>:<container>/<proto>`** unless `CONTAINERDASHBOARD_ALLOW_REMOTE_BIND=1` is set; an explicit non-loopback host-ip is rejected without that flag `(review: security M3)`. This keeps the loopback trust boundary intact.
- **`exec` (server-chosen command + opt-in).** The command is fixed (`/bin/sh`); the user's keystrokes travel PTY-master -> slave -> container stdin and **never** become a `Process` argument, so there is no host-shell injection vector `(review: security, affirmed)`. Because run + exec together can mount and read/write arbitrary host paths, exec is **opt-in**: `CONTAINERDASHBOARD_ENABLE_EXEC=1`, default off. When off, the ws route returns 404 and the UI hides the Terminal button. The residual risk from any *same-loopback* hostile origin is documented in the README `(review: security H1)`.
- **Error responses.** `runAction`/the new routes log the full CLI error server-side and return a generic message (`container run failed`) to the client; detail only in a dev mode. Today `routes.swift` echoes `\(error)` verbatim - this is tightened as part of Phase 13 `(review: security L3)`.

---

## Phase 13 - Run container (backend + frontend)

The first mutating endpoint with free-form user input. Validation + cache-bypass ship here.

**Build - backend**
1. **Cache-bypass (first; also fixes existing writes).** Add `func runUncached(binary:args:timeout:) async throws -> Data` to `CommandRunner` (and `runDiscardingOutput` in Phase 14). `ResultCache` gains an uncached delegation. Retrofit every `ContainerCLI` write (`stop`/`start`/`kill`/`prune`/`builderStart`/`builderStop`) plus the new `run` to the uncached path. Reads keep the cache.
2. **Validators** under `Sources/ContainerDashboard/Support/` (TDD first, see gate):
   - `PortSpec` - parse `[host-ip:]host-port:container-port[/protocol]`. Ports 1-65535 (reject 0); protocol `tcp`|`udp`|`sctp` (default `tcp`); host-ip empty or a dotted-quad/bracketed-IPv6. **Re-serialize to `127.0.0.1:<host-port>:<container-port>/<proto>` by default** (host-bind policy above). Reject NUL/newline/leading `-`.
   - `EnvSpec` - `KEY=VALUE` or `KEY`. `KEY` matches `[A-Za-z_][A-Za-z0-9_]*`; VALUE rejects NUL/newline (so the assembled `KEY=VALUE` is one argv element and cannot start with `-`). Cap: 64 entries / 32 KB each.
   - `VolumeSpec` - `source:destination[:ro]` (bind) or `destination`. Reject NUL/embedded newline/leading `-`. (Note: `..` rejection is not a meaningful control here - bind sources are arbitrary host paths by design - so the host-fs exposure is stated in Security Model, not pretended-away by `..` blocking `(review: security M1)`.)
   - `MemorySpec` - `<unsigned>[K|M|G|T|P]`. Emits normalized e.g. `512M`.
   - Container name: reuse `IDValidator.validate` (no extraction `(review: planner M4)`).
3. **`ContainerRunRequest`** (`Codable`, `Sendable`) - every argv-bound field is a validator-backed type; `init(from:)` runs the validator and throws `Abort(.badRequest)` on failure. No raw `String` survives into the runner.
4. **`ContainerCLI.run(...)`** - assembles a fixed argv and delegates via `runUncached`. `--cidfile <tmp>` + `--detach`; reads the id from the cidfile (see Notes), unlinks it. Fixed ordering: `["run","--detach","--cidfile",path,"--name",name?,"-p",port*,"-e",env*,"-v",vol*,"-c",cpus?,"-m",mem?,"--rm"?, image, args*]` `(review: planner L2 - spell out, no "...")`. `--entrypoint` accepted by the backend but not exposed in the UI `(review: planner L1)`.
5. **Route** `POST /api/containers/run` - decode -> `ContainerCLI.run` -> 201 `{id}`. Origin-guarded (POST). Generic error on failure (Security Model).

**Build - frontend**
6. "New container" button. Modal: image (select local + free text), name, repeatable ports/env/volumes, cpus, memory, command args, `--rm`. Client-side validation mirrors the server validators. Submit -> `POST /api/containers/run` -> on 201 close modal + `poll(true)`; on error, surface the generic message inline (no raw stderr in the DOM).

**TDD gate**
- `RunValidatorTests`: valid + invalid per validator, including NUL/newline/leading-`-` injection rows as **separate** cases `(review: security L4, architect L5)`.
- `ContainerCLIArgsTests.run`: assert the full argv for a representative request against `FakeCommandRunner.recordedArgs` - especially that each validated port/env/volume lands as one element, `--detach` + `--cidfile` are always present, and an absent optional yields no element. Filter: `swift test --filter ContainerCLIArgsTests.run` `(review: planner H1)`.
- `RunCacheBypassTests`: a double `stop` within 1s against a throw-once `FakeCommandRunner` stub both reach the runner (i.e. writes are uncached) `(review: architect C1, planner H3)`.
- `swift test` green (75 existing + new).

**Verify**
- `swift build` green.
- Manual: `curl -XPOST localhost:8080/api/containers/run -d '{"image":"<local>","name":"smoke"}'` -> 201; `container ls` shows it. Then cleanup (see Out of Scope cleanup line).
- Origin guard: `curl -XPOST ... -H 'Origin: https://evil.tld'` rejected.
- Host-bind: a run with `ports:[{host:8080,container:80}]` publishes on `127.0.0.1`, not `0.0.0.0` (`container inspect` confirms).

**Notes**
- **`--cidfile` contract (committed, not "or re-ls"):** path is server-generated (`NSTemporaryDirectory()` + UUID + `.cid`), created `O_CREAT|O_EXCL` (no symlink planting), read synchronously after the detached run returns, unlinked, never reflected in any response `(review: architect H3, swift L1, security L2)`. Drop the racy re-`ls` fallback entirely.

---

## Phase 14 - Pull image (backend + frontend)

**Build - backend**
1. **`runDiscardingOutput` on `CommandRunner`** - same lifecycle/SIGKILL-on-timeout as `run()`, but `standardOutput`/`standardError` go to `/dev/null` instead of a `Pipe()`. This is required: `container image pull` emits progress that overflows the pipe buffer (~16-64 KB) and would block the child on `write()`, keeping `isRunning` true until the timeout SIGKILLs a succeeding pull `(review: swift C3)`.
2. **`ContainerCLI.imagePull(_:ref:)`** - `runDiscardingOutput(binary:"container", args:["image","pull",ref], timeout:.seconds(600))`, **uncached**. Ref validated by `ImageRefValidator` at the boundary. Output discarded by design.
3. **Route** `POST /api/images/pull` `{reference}` -> 202, uncached, Origin-guarded. Generic error on failure.

**Build - frontend**
4. "Pull image" field in the images panel. Submit -> spinner -> on 202 `poll(true)`; on failure surface the generic message.

**TDD gate - `PullTests`**
- `imagePull` argv shape against `FakeCommandRunner` (`["image","pull","alpine"]`).
- `imagePull` uses the **uncached + discarding-output** path (fake records which method was called).
- A thrown `CLIError.nonZeroExit` is **not** cached (throw-once-then-succeed stub) `(review: planner H3)`.
- `swift test --filter Pull` green.

**Verify**
- `swift build`/`swift test` green.
- Manual: pull a small image (`alpine`), confirm it lands in `container image list` and the dashboard.

**Notes**
- v1 is fire-to-completion with a 600s ceiling (large first pulls can exceed 300s `(review: architect L2)`). Streaming progress over SSE is a documented follow-up.

---

## Phase 15 - Exec terminal backend (PTY bridge)

The riskiest runtime piece. Bidirectional + blocking I/O; mirrors the logs-stream GCD discipline but adds real new surface (the existing `stream()` pattern carries over for the **read** side only `(review: swift, bottom-line)`).

**Build**
0. **Pre-flight (build-breaking, do first):** add `app.webSocket("ping"){ _, ws in ws.close(promise:nil) }` and `swift build`. Confirmed by review: `app.webSocket` ships with the core `Vapor` product (no `Package.swift` change `(review: architect L4, swift L4)`). Delete the hedge once it compiles.
1. **Exec opt-in gate.** Read `CONTAINERDASHBOARD_ENABLE_EXEC` once at configure time. When unset, the ws route returns 404 and a `GET /api/capabilities` reports `{exec:false}` for the frontend. `(review: security H1)`
2. **PTY helper** `Sources/ContainerDashboard/CLI/PTY.swift`:
   - `posix_openpt(O_RDWR|O_NOCTTY)`; `grantpt`; `unlockpt`; **`ptsname_r`** (thread-safe; `ptsname` is not - two concurrent opens race its static buffer `(review: swift H3)`); `open(slave, O_RDWR|O_NOCTTY)`.
   - `setWinsize(slaveFD, rows, cols)` via `ioctl(TIOCSWINSZ)`.
   - Returns raw `Int32` `(master, slave)`; the caller is the **sole owner** of both fds. `FileHandle(fileDescriptor:)` does not own the fd on macOS, so all closes are explicit `close(fd)`.
3. **`PTYRunner` protocol (separate from `CommandRunner`)** so `FakeCommandRunner` and the existing test surface are untouched `(review: architect M1)`:
   - `func exec(binary:args:cols:rows:) -> ExecStream`
   - `ExecStream`: `output: AsyncThrowingStream<Data, Error>` (**bounded**, `bufferingNewest(64)` `(review: swift H2)`); `send: @Sendable (Data) -> Void`; `close: @Sendable () -> Void`.
   - **Single serial owner.** A dedicated `DispatchQueue(label:"exec.io")` owns `masterFD` and runs the read loop, all `write()`s, and the final `close()` `(review: swift C2)`. `send`/`close` only schedule work onto it. `close` is **idempotent** (`OSAllocatedUnfairLock<Bool>` "closed" guard `(review: architect M3)`).
   - **Parent closes the slave fd immediately after `proc.run()`** - otherwise master `read()` never EOFs on a clean shell exit `(review: swift C1)`.
   - **EOF handling:** `read` returning `0` (EOF) **or** `-1` with `errno == EIO` both end the loop; other `-1` is a real error `(review: swift M2)`.
   - **fd cleanup on spawn failure:** between `openMaster()` and the read-loop start, every throw `close()`s both fds `(review: swift M3)`.
   - `continuation.onTermination = { _ in close() }` so task-group/server-shutdown cancel reaps the child `(review: swift H4)`.
   - Spawn `container exec -i -t <id> /bin/sh` with `standardInput/Output/Error` on the slave; reap via the existing `reap()` (SIGTERM -> grace -> SIGKILL) on teardown.
4. **WebSocket route** `app.webSocket("api","containers",":id","exec")`:
   - Validate `:id`. If exec disabled -> 404.
   - **`shouldUpgrade` Origin guard (blocker):** reject unless `Origin` is loopback-absent/`127.0.0.1` and `Sec-Fetch-Site != "cross-site"` via the pure `shouldBlockWS` helper `(review: security C1, architect H1)`.
   - `cols`/`rows` query parsed `Int` **fail-closed to defaults** on any parse error, then clamped (cols 20-300, rows 1-100) before `TIOCSWINSZ` `(review: security L1)`.
   - Open PTY + spawn **on `ioQueue`**, not the event loop; return from the handler immediately; early ws frames queue until ready `(review: swift M4)`.
   - `ws.onBinary`/`onText` -> `execStream.send(...)` (hops to `ioQueue`, never blocks the event loop `(review: swift H1)`).
   - **Output pump with backpressure:** `for try await chunk in output { try await ws.send(chunk).get() }`; if `send` throws (channel closed), call `close()` `(review: swift H2)`.
   - **Teardown (heartbeat-bounded, not cap-free):** `ws.onClose.whenComplete { _ in close() }` handles clean disconnects. For dirty disconnects: a ws **ping every ~30s**; if no pong within ~60s, force-close. A long safety-net timer (~30 min) calls `close()` unconditionally as a last resort `(review: architect H2, swift H5)`.
   - **Concurrency cap:** an `actor ExecPool` (cap 8) gates session creation; overflow -> 503 "terminal pool full" `(review: planner M2)`.

**TDD gate - `ExecTests`**
- `PTY.openMaster` returns two valid fds; `close` cleans up (smoke).
- Two PTYs opened concurrently yield **distinct** slave paths (`ptsname_r` race `(review: swift H3)`).
- `ExecPool`: `acquire` x N succeeds, N+1 throws `(review: planner M2)`.
- `OriginGuard.shouldBlockWS`: cross-origin/`cross-site` rejected, loopback/same-site allowed.
- `execStream` round-trip vs `/bin/sh` (test-only): send `echo hi\n`, assert output contains `hi`; `close()` reaps the child within ~2s.
- `swift test --filter Exec` green.

**Verify (gates are blockers)**
- `swift build`/`swift test` green.
- **Dirty-disconnect reap:** connect a ws client, confirm the `container exec` pid exists, `kill -9` the client (no FIN); assert the child is reaped within the heartbeat window (~60s), not the OS keepalive (~2h) `(review: architect H2, swift H5)`.
- **Cross-origin ws upgrade rejected** (the C1 fix is live).
- Exec disabled (`CONTAINERDASHBOARD_ENABLE_EXEC` unset): ws route 404s; `/api/capabilities` -> `{exec:false}`.

**Notes**
- **Post-start resize unsupported** by the CLI; initial size from query only. The frontend `onResize` handler is a documented no-op.
- **No controlling terminal for the child.** `Foundation.Process` uses `posix_spawn` with no pre-exec hook for `setsid`/`TIOCSCTTY`, so job control (`Ctrl-Z`, `fg/bg`) will not work; `Ctrl-C` still interrupts the foreground child via the slave's line discipline. Documented limitation; revisit with a small C shim only if interactive use proves insufficient `(review: swift M1)`.

---

## Phase 16 - Exec terminal frontend (xterm.js)

**Build**
1. **Vendor** `xterm.js` core + `xterm-addon-attach` + `xterm-addon-fit` into `Resources/Public/lib/` (committed, no CDN). Record version + checksum source in `lib/README.md`.
2. **`terminal.js`:** `openTerminal(id, mountEl)` - `new Terminal({cols,rows})`, `fit()` for initial size, `WebSocket(ws://host/api/containers/<id>/exec?cols=&rows=)`, attach addon wires ws<->term. On `ws.onclose`: "disconnected" overlay + reconnect.
3. **UI:** "Terminal" button per **running** container, **hidden when `/api/capabilities` reports `exec:false`**. Opens a panel; on close `term.dispose()` + `ws.close()`.

**Verify**
- Browser: open a terminal on a running container, `ls`/`uname -a`, see output. Close drawer -> ws drops -> backend reaps (per Phase 15 gate). `Ctrl-C` interrupts a running command.
- No console errors.

**Notes**
- **CSP:** the project ships no `Content-Security-Policy` today. Either add one (`default-src 'self'; connect-src 'self' ws://127.0.0.1:8080; ...`) verified by a `curl -I` gate, or strike the CSP justification and reframe vendoring as an offline/availability property. Pick in-phase `(review: planner M3)`.
- Terminal *display* resizing (xterm) works even though the PTY size is fixed.

---

## Phase 17 - Dashboard polish (scoped)

Committed items (not a backlog `(review: planner M1)`):
- Terminal as a tab in the container detail drawer (co-locate logs + exec).
- Keyboard: `Esc` closes modal/terminal; image-search autofocus; repeatable port/env/volume rows with add/remove.
- Persist last-used create-form values in `localStorage` (existing `lastState` pattern).

---

## Phase 18 - Docs (README)

`README.md` updated (prior Phase 12 set this bar `(review: planner H2)`):
- run/pull/exec surface + example requests.
- Vendored xterm version + checksum source.
- No-post-start-resize limitation; no-job-control limitation.
- Exec teardown: `onClose` for clean, heartbeat + safety-net for dirty; the opt-in flag `CONTAINERDASHBOARD_ENABLE_EXEC`; host-bind policy `CONTAINERDASHBOARD_ALLOW_REMOTE_BIND`.
- ws route is Origin/`Sec-Fetch-Site` guarded via `shouldUpgrade`.
- Residual-risk note: run + exec can mount arbitrary host paths; the loopback + Origin posture is what prevents a hostile origin from exercising this.

**Verify:** README section headers cover the above; `run.sh --help` (if any) consistent.

---

## Open Decisions (resolved; defaults applied - override anytime)

1. **Exec flavor:** **(A) Full interactive TTY terminal** (xterm.js + PTY). *Applied.* (B was the lighter one-shot fallback.)
2. **`create` vs `run`:** **`run` only for v1** (`--detach`). `create` is a trivial follow-up.
3. **Pull progress streaming:** **fire-to-completion (600s ceiling) for v1.** SSE progress is a follow-up.
4. **Exec opt-in:** **`CONTAINERDASHBOARD_ENABLE_EXEC=1`, default off.** `(review: security H1)`
5. **Host-bind policy:** **rewrite published ports to `127.0.0.1`; remote bind only via `CONTAINERDASHBOARD_ALLOW_REMOTE_BIND=1`.** `(review: security M3)`
6. **`--entrypoint`:** **backend accepts, UI does not expose.** `(review: planner L1)`

---

## Out of Scope (v1)

- `container build` (Dockerfile) - the builder panel shows status; authoring builds is separate.
- `container cp` (file copy UI).
- Volume / network authoring UIs beyond what run needs.
- Auth / multi-user - loopback-only by design.
- Post-start terminal resize (CLI lacks the API).
- Automated integration tests against the real `container` CLI for run/pull/exec - coverage is the per-phase manual verify steps, matching the prior plan's stance `(review: planner L3)`.
- **Manual-verify cleanup:** after Phase 13/15/16 verify, remove test containers: `container ls --all --format '{{.ID}} {{.Names}}' | rg 'smoke|terminal-test' | awk '{print $1}' | xargs -r container rm -f` `(review: planner M5)`.
