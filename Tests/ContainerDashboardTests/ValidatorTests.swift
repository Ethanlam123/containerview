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
