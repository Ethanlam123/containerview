# Plan: Container-Monitor as a native macOS desktop app

Status: reviewed (architect pass 2026-07-09; BLOCKER/HIGH/MEDIUM findings folded in)
Date: 2026-07-09

## Current shape

- Pure SwiftPM package, one **executable** target `ContainerDashboard` (Vapor 4 server, `@main` in `Sources/ContainerDashboard/app.swift`).
- Loopback-only HTTP server at `127.0.0.1:8080`, serves `Resources/Public/*` (vanilla HTML/CSS/JS + vendored xterm.js).
- Today the user must run `./run.sh` then open a browser. No `.app`, no window, no icon, no Dock presence.
- Port 8080 is contested on this machine (TencentMeeting) - already worked around via `CONTAINER_DASHBOARD_PORT`.

The dashboard itself is already a web app. The desktop app is **a thin native shell that owns a window and the server's lifetime**. 100% of the existing UI/server code is reused.

## The one real decision: how the server runs

| | **A. Out-of-process spawn** (recommended first) | **B. In-process server** (upgrade) |
|---|---|---|
| Server code changes | small (asset-path + port-readback + parent-watch) | large (split Sources into lib + app targets; run Vapor off the main actor) |
| Result | shell app spawns the release binary as a `Process`, kills it on quit | one process; shell calls `Server.start()` on a background thread |
| Risk | orphaned Vapor child if the app is force-killed / crashes | none - shared lifetime |
| Diff size | small (one shell file + bundler script + ~15 server lines) | medium (Package.swift restructure + Swift-6 concurrency wrangling) |
| When to take B | only if the parent-watch mitigation from Phase 2.5 proves insufficient | - |

**Go with A now.** Shortest path to a genuine double-clickable `.app`. The one real argument for B (orphan-on-crash) is addressed head-on by the parent-process watch in Phase 2.5, which likely **retires the need for B entirely**. This matches YAGNI - don't restructure a working server before there's pressure.

**Explicitly skipped** (state them, don't build them): App Sandbox (it would break the entire premise - the app must spawn `container` and bind sockets; document "not sandboxed" instead), Sparkle auto-update, deep-link/URL scheme, a preferences pane for the env flags (`CONTAINER_DASHBOARD_PORT`, `CONTAINER_DASHBOARD_ALLOW_REMOTE`, `CONTAINERDASHBOARD_DISABLE_EXEC`, `CONTAINERDASHBOARD_ALLOW_REMOTE_BIND`). Add each only when a real need appears.

---

## Phase 1 - The WKWebView shell

Add one Swift file (AppKit, not SwiftUI - fewer layers, fine for a single full-window webview):

- `NSWindow` (titled, closable, miniaturizable, resizable), default ~1200x800, min ~960x640.
- A single `WKWebView` filling the content view. JavaScript is on by default in modern WebKit (the old `configuration.preferences.javaScriptEnabled` is deprecated); set it explicitly only if pinning behavior matters.
- `applicationDidFinishLaunching` -> create window + webview, show a "Starting server..." overlay (a styled `NSVisualEffectView` + spinner) until the server is ready.
- Load `http://127.0.0.1:<port>` once the health check passes (Phase 2). Pin `NSApp.appearance = NSAppearance(named: .darkAqua)` here so the title bar matches the dark dashboard (the chrome otherwise follows system appearance).

**Constraint (do not violate): the webview MUST load the loopback HTTP URL, never a `file://`/custom-scheme load.** `OriginGuardMiddleware` rejects cross-site `Sec-Fetch-Site` and non-loopback `Origin` on every write and on the exec WebSocket upgrade. Loading `http://127.0.0.1:<port>` yields `Origin: http://127.0.0.1:<port>` (loopback host) and `Sec-Fetch-Site: same-origin` - allowed. Any switch to a bundled-asset scheme silently 403s every POST and closes the exec WS.

**Verify:** `swiftc`-built shell (pointing at a manually-started server) opens a window, renders the dashboard, AND a write action succeeds - hit `GET /api/state` (read) and then a real write (e.g. toggle builder Start/Stop or a no-op prune of an empty category) and confirm it is not 403. A read-only check passes even with a broken Origin setup; the write check is what proves the guard is satisfied.

## Phase 2 - Server lifecycle + port

**Port selection (race-free):** Pass `CONTAINER_DASHBOARD_PORT=0` so the OS picks a free port. This retires the TencentMeeting/8080 problem entirely - the user never sees a port. The shell then learns the actually-bound port by reading it back from the server:

- Preferred: add a tiny Vapor `LifecycleHandler` in `app.swift` whose serve-time hook prints `LISTENING <port>` (resolved from `app.http.server.shared.localAddress`) to stdout once the socket is bound; the shell parses stdout for the port before loading the webview. ~6 lines, no IPC file.
- Zero-server-change fallback: the shell probes a free port by binding `127.0.0.1:0`, reading `localAddress`, closing, and reusing the number via `CONTAINER_DASHBOARD_PORT`. This has a small TOCTOU window on loopback - acceptable for a single-user local tool, but the lifecycle read-back is cleaner, so do that if any server edit is allowed.

  Note: the exact Vapor hook whose timing is *after bind and before serve blocks* needs a quick check against Vapor 4.100 at implementation (`app.lifecycle.use(...)` + the right callback). Confirm before relying on it.

- Spawn `.build/release/ContainerDashboard` with `Process`, `CONTAINER_DASHBOARD_PORT=0`, `CONTAINER_DASHBOARD_ALLOW_REMOTE` unset (loopback), `CONTAINERDASHBOARD_DISABLE_EXEC` unset (exec on, matching the default). **Always set these explicitly in the child's environment - do not inherit** the launching shell's exports (which can leak a conflicting `CONTAINER_DASHBOARD_PORT`).
- Health-poll: `GET /api/state` on a ~100 ms timer; on success, hide the overlay and load the URL. Use a **~5 s** ceiling before showing retry/error - a cold Vapor release binary plus the first `container system status` hit can exceed 2 s on this machine.
- `applicationWillTerminate` -> `process.terminate()`; if still alive after a 3 s grace, `SIGKILL` (reuse the reap pattern from `Support/SSE.swift`).

**Verify:** cold launch shows the dashboard within ~5 s; `ps aux | grep ContainerDashboard` shows the server; graceful quit (Cmd+Q / Activity Monitor "Quit") kills the server.

## Phase 2.5 - Parent-process watch (kills the orphan class)

`applicationWillTerminate` is NOT reached for every exit path: Dock "Force Quit" and `kill -9` skip it, and a shell crash never sends it. To guarantee the server dies with the shell regardless, add a self-reap to the server in `app.swift` (~5 lines on Darwin):

```swift
let parent = getppid()
let src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent, DISPATCH_PROC_EXIT, nil)
dispatch_source_set_event_handler(src) { exit(EXIT_SUCCESS) }
dispatch_source_resume(src)
```

When the parent process exits (graceful or force-kill), the kernel delivers `EXIT` to the source and the server exits cleanly. This is the cheap, correct fix for the orphan-on-crash class - and it removes the main argument for the in-process restructure in Phase 6.

**Verify:** launch the app, then Force-Quit it from the Dock; confirm the `ContainerDashboard` server process is gone within a second (no `ps` entry). Re-run against `kill -9` of the shell PID.

## Phase 3 - Prerequisite + error UX

- `which container` (or check `PATH`) at launch. If missing, the window shows a real error pane ("Apple `container` CLI not found" + install hint + a "Retry" button) instead of a blank webview or silent crash.
- Also surface server bind/loopback failure (rare now that we pick the port): capture the child's exit code and show the reason in the same error pane.

**Verify:** temporarily rename/hide `container` on PATH -> the app launches into the friendly error, not a crash.

## Phase 4 - Bundle into a real `.app`

A `build-app.sh` that assembles the bundle (no Xcode project needed - keeps the repo pure-SPM):

```
ContainerDashboard.app/
  Contents/
    Info.plist
    MacOS/
      ContainerDashboard          # the WKWebView shell binary (swiftc, links WebKit)
      ContainerDashboardServer    # the existing release binary (copied from .build/release)
    Resources/
      AppIcon.icns
      Public/                     # copy Resources/Public/* (the dashboard assets)
```

**Asset path resolution (the blocker).** `configure.swift` currently derives the public dir as `FileManager.default.currentDirectoryPath + "Resources/Public/"`. That line is CWD-dependent and **every obvious bundle CWD is wrong** (`Contents/`, `Contents/MacOS/`, `Bundle.main.bundlePath` all miss). Fix it server-side with one branch in `configure.swift`: when running in a bundled build (detect via `Bundle.main.bundleURL.pathExtension == "app"` or an explicit `CONTAINER_DASHBOARD_BUNDLED=1` marker the shell sets), resolve the public dir from `Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Public/")`; otherwise keep the existing CWD path for `swift run`. This is robust to bundle relocation and App Translocation (quarantined-DMG double-clicks run from a randomized `/private/var/folders/.../App Translocation/...` path - all paths must be `Bundle.main`-relative, never `CommandLine.arguments[0]`-relative).

**`Info.plist` keys:**

- `CFBundleName`, `CFBundleIdentifier` (e.g. `com.<you>.containerdashboard`)
- `CFBundleVersion` / `CFBundleShortVersionString`
- `CFBundleExecutable` = `ContainerDashboard` (the shell); note `CFBundleIconFile` = `AppIcon` (**no extension** when pointing at a loose `.icns` - wrong key yields a silent generic icon)
- `LSMinimumSystemVersion` = the **true** minimum that lets Apple's `container` CLI work, not the SwiftPM target floor. `Package.swift` says 14.0 but the README says "macOS 26+"; the repo is internally inconsistent. Confirm which `container` features are actually required and set this to that floor, so older users get a clean LaunchServices refusal instead of a confusing runtime failure.
- `NSHighResolutionCapable` = `true`. (`LSUIElement=false` is the default - no need to set it.)

**Executable bit:** copy the server binary with `install -m 0755` (plain `cp` under a umask can drop the x bit, and LaunchServices refuses a non-executable `CFBundleExecutable`). Assert `[ -x ... ]` in `build-app.sh`.

**Signing (local use):** sign each Mach-O then the bundle - `--deep` is deprecated and unnecessary here (no nested frameworks/helpers): `codesign --force -s - ContainerDashboard.app/Contents/MacOS/ContainerDashboardServer && codesign --force -s - ContainerDashboard.app`. This is ad-hoc; Gatekeeper prompts once, fine for personal use.

**Verify:** double-click `ContainerDashboard.app` in Finder -> Dock icon, menu bar, window with the live dashboard; assets and the xterm terminal render (the asset-path branch is the thing being exercised - a wrong branch = 404 shell with no CSS/JS).

## Phase 5 - Desktop polish

- **Menu bar:** standard app menu (About / Quit `Cmd+Q`), plus View (Reload `Cmd+R`, Hard Reload), Window (Minimize, Zoom), and "Open in Browser" that hands the loopback URL to `NSWorkspace.open`. Note this is a deliberate trade-off: the dashboard has no auth, so opening it in the user's default browser (hostile extensions, cross-site contexts) widens the attack surface vs. the captive webview. Use `os.Logger`, never `print()`.
- **Single-instance:** if launched again, focus the existing window (`NSApp.activate(activating:)` on 14+; the old `activate(ignoringOtherApps:)` is deprecated and logs a warning) instead of a second instance.
- **Window state:** persist the frame (origin + size) to `UserDefaults`, restore on next launch.
- **Lifecycle niceties:** `Cmd+W` hides/minimizes to Dock (keeps server alive) vs `Cmd+Q` truly quits. Default = `Cmd+Q` quits and tears down (simplest, matches expectation for a "local ops tool"). Document the chosen behavior.

**Verify per item:** reload works, second launch focuses the first window, window position persists across restarts.

## Phase 6 (optional, likely unnecessary after Phase 2.5) - In-process server upgrade

With the parent-process watch in place, the orphan class is gone and the main motivation for restructuring disappears. Take this **only if** you hit a concrete problem the spawn model can't handle (e.g. needing shared in-process state between shell and server). It is not a one-liner under Swift 6 strict concurrency:

- `Vapor.Application` is not `Sendable` in 4.100; `app.execute()` boots the NIO `EventLoopGroup` on the calling thread and blocks until shutdown.
- The real shape: an `@unchecked Sendable` server holder, `Task.detached(priority: .userInitiated)` for `app.execute()`, and on quit call `application.lifecycle.shutdown()` then `await application.asyncShutdown()` (else the EL group leaks).
- Split a library target `ContainerDashboardLib` (Vapor `Application` bootstrap + `configure` + routes, sans `@main`) from the executable; keep the old executable for `swift run` / CI / tests.

Treat this bullet as a **sketch**; it needs its own design pass if taken. **Verify:** single process; force-quitting leaves nothing behind; the existing test suite stays green.

## Phase 7 (optional, only if shipping publicly) - Distribution

Developer-ID sign, `notarytool` submit + wait, `stapler staple`, build a `.dmg`. Skip entirely until you actually distribute beyond your own machine.

---

## Milestone mapping

- After **Phase 4**: a real double-clickable `ContainerDashboard.app` - Dock icon, own window, no terminal, no port juggling, no browser tab. This is the "it's a macOS app" milestone.
- Phases 5-7 are polish/distribution, taken as needed.

## Suggested order

Do **1 -> 2 -> 2.5 -> 3 -> 4** as one unit (each is small and 4 needs 1-3 in place), committing per phase. That gets the real `.app`. Then stop and decide whether 5/6 are worth it.

## Review findings resolved

- **B1 (asset-path CWD) -> Phase 4:** add a bundled-build branch in `configure.swift` resolving `Resources/Public` from `Bundle.main.bundleURL`. Verified the current CWD logic; the obvious bundle CWDs are all wrong.
- **H1 (Origin guard) -> Phase 1:** webview must load the loopback HTTP URL; verify step now includes a write, not just a read.
- **H2 (free port) -> Phase 2:** use port `0` + server-reported port via a Vapor lifecycle hook (fallback: the bind-close probe). Race-free, answers the earlier open question.
- **H3 (Phase 6 sketch) -> Phase 6:** spelled out the Swift-6 reality (`@unchecked Sendable`, detached task, explicit shutdown); flagged as a sketch.
- **M1/M2 (signing, exec bit) -> Phase 4:** no `--deep`; `install -m 0755` + x-bit assertion.
- **M3 (orphan) -> Phase 2.5:** parent-process watch; likely retires Phase 6.
- **M4 (`CONTAINERDASHBOARD_ALLOW_REMOTE_BIND`) -> skipped list.**
- **M5 (min OS) -> Phase 4:** set to the true `container`-required floor; reconcile the 14-vs-26 inconsistency.
- **M6 (force-quit verify) -> Phase 2.5:** added a Force-Quit / `kill -9` verify step.
- **L1-L5, N1-N4:** folded in (always-set env, `CFBundleIconFile` no-extension, App Translocation note, deprecated WebKit/activation APIs, dark-appearance pin, 5 s ceiling).
