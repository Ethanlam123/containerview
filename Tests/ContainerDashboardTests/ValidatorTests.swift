import Testing
import Foundation
@testable import ContainerDashboard

// MARK: - ID validator (V1-V8)

@Test func v1_simple() {
    #expect(IDValidator.validate("hermes"))
}

@Test func v2_allowed_punctuation() {
    #expect(IDValidator.validate("my-container.1_test-2"))
}

@Test func v3_maxLength_64() {
    #expect(IDValidator.validate(String(repeating: "a", count: 64)))
}

@Test func v4_tooLong_65() {
    #expect(!IDValidator.validate(String(repeating: "a", count: 65)))
}

@Test(arguments: ["", "-foo", ".foo", "_foo", " foo"])
func v5_bad_leading_or_empty(_ s: String) {
    #expect(!IDValidator.validate(s))
}

@Test(arguments: [
    "foo;rm -rf /",
    "foo$(x)",
    "foo`cat`",
    "foo|cat",
    "foo\nbar",
    "foo bar",
    "foo\tbar",
])
func v6_shell_and_control_metachars(_ s: String) {
    #expect(!IDValidator.validate(s))
}

@Test(arguments: ["foo/bar", "foo:tag", "foo@x"])
func v8_image_chars_rejected_for_ids(_ s: String) {
    // `/ : @` belong to image refs, not container IDs.
    #expect(!IDValidator.validate(s))
}

// MARK: - Image-ref validator (V9-V13)

@Test(arguments: [
    "hello-world:latest",
    "docker.io/library/hello-world:latest",
    "hello-world@sha256:abc123",
    "docker.io/library/hello-world@sha256:abc",
])
func v9_12_valid_image_refs(_ s: String) {
    #expect(ImageRefValidator.validate(s))
}

@Test(arguments: [
    "hello world",
    "foo;rm",
    "`x`",
    "/leading-slash",
    "",
])
func v13_invalid_image_refs(_ s: String) {
    #expect(!ImageRefValidator.validate(s))
}

// MARK: - Process runner smoke (one real process)

@Test func processRunner_sw_vers() async throws {
    let runner = ProcessCommandRunner()
    let data = try await runner.run(binary: "sw_vers", args: ["-productVersion"], timeout: .seconds(3))
    let v = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(v?.isEmpty == false)
    // A macOS product version has at least two dot-separated components.
    #expect((v?.split(separator: ".").count ?? 0) >= 2)
}

// MARK: - Process runner streaming (real process)

// `stream()` must yield stdout lines as they arrive (not one-shot capture) and
// stop promptly on `cancel()`. We test the generic runner directly with /bin/sh;
// this is a test-only shell string with no user input, so the "argument arrays
// only" security rule (which protects user-supplied :id from reaching a shell)
// does not apply here.

@Test func processRunner_stream_yields_lines() async throws {
    let runner = ProcessCommandRunner()
    let handle = runner.stream(binary: "/bin/sh", args: ["-c", "echo a; printf b; sleep 0.1; echo c"])
    var got: [String] = []
    for try await line in handle.lines { got.append(line) }
    // "b" has no trailing newline, so it joins the next line into "bc".
    #expect(got == ["a", "bc"])
}

@Test func processRunner_stream_cancel_stops_promptly() async throws {
    let runner = ProcessCommandRunner()
    // `exec` replaces the shell with `sleep`, so the one PID we reap IS sleep;
    // no orphaned child lingers after cancel.
    let handle = runner.stream(binary: "/bin/sh", args: ["-c", "echo a; exec sleep 30"])
    var got: [String] = []
    let elapsed = try await ContinuousClock().measure {
        for try await line in handle.lines {
            got.append(line)
            if got.count == 1 { handle.cancel() }
        }
    }
    #expect(got == ["a"])
    // poll() returns within ~250ms; reap tears down on SIGTERM well inside the
    // 2s grace. Assert headroom so a healthy cancel path fails loudly, not the
    // 30s no-cancel case.
    #expect(elapsed < .seconds(2))
}

@Test func processRunner_run_timeout_sigkills_promptly() async throws {
    let runner = ProcessCommandRunner()
    // A child that ignores SIGTERM (trap '') would hang the old waitUntilExit
    // indefinitely; the SIGKILL escalation must still bound it to ~timeout.
    let elapsed = try await ContinuousClock().measure {
        await #expect(throws: CLIError.timedOut) {
            try await runner.run(
                binary: "/bin/sh",
                args: ["-c", "trap '' TERM; sleep 30"],
                timeout: .seconds(1)
            )
        }
    }
    // 1s timeout + 20ms poll granularity + SIGKILL reaping. Far under the 30s
    // a stonewalling child would otherwise cost.
    #expect(elapsed < .seconds(3))
}
