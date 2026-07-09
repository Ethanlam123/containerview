// Container Monitor - native macOS shell.
//
// A thin AppKit window around the existing Vapor dashboard. It spawns the
// server binary (Contents/MacOS/ContainerDashboardServer) out-of-process on an
// ephemeral loopback port, then loads the loopback URL in a WKWebView. The
// webview MUST load http://127.0.0.1:<port> - never file:// or a custom scheme
// - so OriginGuardMiddleware sees a loopback Origin / same-origin Sec-Fetch-Site
// and allows writes and the exec WebSocket upgrade. Any other scheme silently
// 403s every POST and closes the exec WS.
//
// See docs/desktop-app-plan.md (Phases 1-5).

import Cocoa
import WebKit

// MARK: - Bootstrap

// Single-instance: if another copy of this app is already running, focus it and
// exit the new launch instead of opening a second window + second server.
let myBundleID = Bundle.main.bundleIdentifier
if let myBundleID {
    for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == myBundleID && app != NSRunningApplication.current {
        app.activate()
        exit(EXIT_SUCCESS)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)          // Dock icon + menu bar
app.appearance = NSAppearance(named: .darkAqua)  // match the dark dashboard chrome
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - Server process

private enum ServerError: LocalizedError {
    case notBundled
    var errorDescription: String? {
        switch self {
        case .notBundled: return "Server binary not found beside the app shell."
        }
    }
}

/// Owns the spawned Vapor server: clean env, port pin, stderr capture, and a
/// terminate() that SIGTERMs then force-reaps (SIGKILL) on a grace window.
final class ServerProcess {
    private let process: Process
    private let stderrPipe: Pipe
    private let stderrQueue = DispatchQueue(label: "server.stderr")
    private var stderrTail = ""
    let port: Int

    private init(process: Process, stderrPipe: Pipe, port: Int) {
        self.process = process
        self.stderrPipe = stderrPipe
        self.port = port
    }

    static func start(port: Int) throws -> ServerProcess {
        guard let serverURL = serverExecutableURL else { throw ServerError.notBundled }
        let process = Process()
        process.executableURL = serverURL
        // Always set the dashboard knobs explicitly - do not inherit, so a stale
        // exported value (e.g. CONTAINER_DASHBOARD_PORT) cannot leak into the child.
        var env = ProcessInfo.processInfo.environment
        env["CONTAINER_DASHBOARD_PORT"] = String(port)
        env["CONTAINER_DASHBOARD_BUNDLED"] = "1"
        env.removeValue(forKey: "CONTAINER_DASHBOARD_ALLOW_REMOTE")
        env.removeValue(forKey: "CONTAINERDASHBOARD_DISABLE_EXEC")
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()

        let server = ServerProcess(process: process, stderrPipe: stderrPipe, port: port)
        server.captureStderr()
        return server
    }

    var isRunning: Bool { process.isRunning }
    private var exitCode: Int32? { process.isRunning ? nil : process.terminationStatus }

    /// Diagnostics for the error pane if the server never becomes healthy.
    var diagnostics: String {
        stderrQueue.sync { stderrTail }
            + (exitCode.map { "\n(exit \($0))" } ?? "")
    }

    private func captureStderr() {
        let handle = stderrPipe.fileHandleForReading
        // ponytail: readabilityHandler keeps a 2KB tail for the error pane.
        // Fine for diagnostic volume; no need to stream to a file.
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.stderrQueue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(2000))
            }
        }
    }

    /// SIGTERM (Vapor shuts down gracefully on it). No SIGKILL fallback: when
    /// the shell exits, the server's bundled parent-watch reaps it, so a
    /// PID-reuse-prone local kill is unnecessary (parentWatch in app.swift,
    /// gated to bundled mode).
    func terminate() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Path helpers

/// The server binary sits beside the shell at Contents/MacOS/ContainerDashboardServer.
private var serverExecutableURL: URL? {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ContainerDashboardServer")
}

/// `which`: locate an executable on PATH.
private func findOnPATH(_ name: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
    }
    return nil
}

/// Bind 127.0.0.1:0, read the assigned port, close. There is a tiny TOCTOU
/// window on loopback between close and the server's bind - acceptable for a
/// single-user local tool (the spawn follows milliseconds later). Needs zero
/// server changes; a race-free variant would need server-side port readback.
private func findFreeLoopbackPort() -> Int? {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
    defer { close(s) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return nil }
    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(s, sa, &len)
        }
    }
    guard got == 0 else { return nil }
    return Int(UInt16(bigEndian: actual.sin_port))
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var server: ServerProcess?
    private var healthTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        guard findOnPATH("container") != nil else {
            presentErrorPane(
                title: "Apple `container` CLI not found",
                body: "Install Apple's `container`, run `container system start` once, then relaunch."
            )
            return
        }
        guard let port = findFreeLoopbackPort() else {
            presentErrorPane(title: "No free loopback port", body: "Could not allocate a local TCP port.")
            return
        }
        do {
            server = try ServerProcess.start(port: port)
        } catch {
            presentErrorPane(title: "Server failed to start", body: error.localizedDescription)
            return
        }
        pollHealth(port: port)
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTask?.cancel()
        server?.terminate()
    }

    // Closing the window quits the app (and reaps the server via the path
    // above). Without this, macOS keeps a windowless app alive holding the
    // port, and a relaunch hits the single-instance guard against that
    // windowless app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: health poll -> show window

    private func pollHealth(port: Int) {
        healthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let url = URL(string: "http://127.0.0.1:\(port)/api/state")!
            // 5s ceiling: a cold Vapor release binary plus the first
            // `container system status` hit can exceed 2s on this machine.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if Task.isCancelled { return }
                if await self.isReachable(url) {
                    self.showDashboard(port: port)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.presentErrorPane(
                title: "Server not responding",
                body: self.server?.diagnostics ?? "No response from the server within 5s."
            )
        }
    }

    private func isReachable(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: window + webview

    private func showDashboard(port: Int) {
        let webView = WKWebView()
        webView.autoresizingMask = [.width, .height]
        // Loopback HTTP only (see file header). OriginGuard requires it.
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)")!))
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentView = webView
        window.minSize = NSSize(width: 960, height: 640)
        window.title = "Container Monitor"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    // MARK: error pane

    private func presentErrorPane(title: String, body: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = title
        let field = NSTextField(wrappingLabelWithString: body)
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.textColor = .secondaryLabelColor
        field.alignment = .center
        let stack = NSStackView(views: [field])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    // MARK: menus

    private func installMenus() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Container Monitor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Container Monitor",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Container Monitor",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(reload(_:)), keyEquivalent: "r")
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func reload(_ sender: Any?) {
        // Reload from the server (origin stays loopback). WebKit reload() would
        // also work; a fresh URLRequest avoids any cached error page.
        if let url = webView?.url { webView?.load(URLRequest(url: url)) }
    }
}
