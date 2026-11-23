import Foundation
import Testing
@testable import GTopCore

struct SSHClientTests {
    @Test("Subprocess with background child holding FDs (like OpenSSH ControlPersist) returns immediately without hanging")
    func backgroundChildHoldingFDsDoesNotHang() async throws {
        let client = SSHClient()
        let start = Date()
        let result = try await client.runSubprocess(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo hello-from-ssh; (sleep 15) & exit 0"],
            stdinFilePath: nil,
            timeoutSeconds: 5.0
        )
        let elapsed = Date().timeIntervalSince(start)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""

        #expect(result.exitCode == 0)
        #expect(stdout.contains("hello-from-ssh"))
        #expect(elapsed < 2.0, "Should return immediately instead of waiting for background child (took \(elapsed)s)")
    }

    @Test("Subprocess exceeding timeout is forcefully aborted and throws SSHClientError.timeout")
    func hungSubprocessTimesOutReliably() async {
        let client = SSHClient()
        let start = Date()
        do {
            _ = try await client.runSubprocess(
                executablePath: "/bin/sleep",
                arguments: ["15"],
                stdinFilePath: nil,
                timeoutSeconds: 1.2
            )
            Issue.record("Expected SSHClientError.timeout")
        } catch let error as SSHClientError {
            if case .timeout = error {
                let elapsed = Date().timeIntervalSince(start)
                #expect(elapsed < 3.5)
            } else {
                Issue.record("Unexpected SSHClientError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
